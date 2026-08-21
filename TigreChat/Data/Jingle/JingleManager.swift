//
//  JingleManager.swift
//  TigreChat
//
//  Máquina de estados Jingle: despacha stanzas entrantes por action
//  (XEP-0166), serializa stanzas salientes con payload RTP (XEP-0167),
//  fingerprint DTLS (XEP-0320) y candidatos ICE reales (XEP-0176).
//
//  Fase 1:
//  - Llamadas de audio: session-initiate / session-accept / session-terminate.
//  - transport-info con el candidato real del engine local.
//  - Timeout de timbre (30s) → terminate(timeout) + evento sintético
//    "unanswered" para el repo.
//  - Ocupado: una segunda llamada entrante se rechaza con busy.
//  - session-info / transport-replace: no-op.
//
//  REQ-JINGLE-001: stanzas malformadas o de sesión desconocida se ignoran
//  en silencio sin mutar estado.
//

import Foundation

enum JingleState: Sendable {
    case pending
    case active
    case ended
}

/// Sesión Jingle viva. `initiator` es el JID que disparó la llamada
/// (remoto en entrantes, local en salientes); `remoteJID` es siempre
/// el par al que hay que responder/terminar.
struct JingleSession: Sendable {
    let sid: String
    let initiator: String
    let responder: String?
    let remoteJID: String
    var state: JingleState
}

enum JingleSendError: Error, Sendable {
    case sessionAlreadyExists
    case unknownSession
}

/// Dependencia de espera inyectable para el timeout de timbre.
typealias JingleSleeper = @Sendable (Duration) async throws -> Void

actor JingleManager {
    private let connection: any JingleTransport
    private let parser: any JingleParsing
    private let mapper: JingleSDPMapper
    private let sleeper: JingleSleeper
    private let ringTimeout: Duration

    private var sessions: [String: JingleSession] = [:]
    private var ringTimers: [String: Task<Void, Never>] = [:]
    private var idCounter: UInt32 = 0

    private var incomingContinuation: AsyncStream<(sid: String, initiator: String, stanza: JingleStanza)>.Continuation?
    nonisolated let incomingCallStream: AsyncStream<(sid: String, initiator: String, stanza: JingleStanza)>

    init(
        connection: any JingleTransport,
        parser: any JingleParsing = JingleXMLParser(),
        mapper: JingleSDPMapper = JingleSDPMapper(),
        sleeper: @escaping JingleSleeper = { try await Task.sleep(for: $0) },
        ringTimeout: Duration = .seconds(30)
    ) {
        self.connection = connection
        self.parser = parser
        self.mapper = mapper
        self.sleeper = sleeper
        self.ringTimeout = ringTimeout
        var cont: AsyncStream<(sid: String, initiator: String, stanza: JingleStanza)>.Continuation?
        // Buffered: el consumidor (repo) procesa un evento mientras el manager
        // puede emitir el siguiente (ráfaga initiate + transport-info/busy);
        // con unbuffered el yield se descarta cuando el escucha está ocupado
        // y el evento se pierde en silencio (run M4: candidate que no llega al
        // engine, busy que no llega al historial).
        incomingCallStream = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            cont = continuation
        }
        incomingContinuation = cont
    }

    // MARK: - Entrante

    /// Único punto de entrada para stanzas Jingle (llamado por XMPPClient
    /// cuando el IQ trae el namespace jingle). REQ-JINGLE-001.
    func handleJingleStanza(xml: String) async {
        let stanza: JingleStanza
        do {
            stanza = try parser.parse(xml)
        } catch {
            return // malformed: ignorar en silencio
        }
        switch stanza.action {
        case .sessionInitiate:
            await handleSessionInitiate(stanza)
        case .sessionAccept:
            await handleSessionAccept(stanza)
        case .sessionTerminate:
            await handleSessionTerminate(stanza)
        case .transportInfo:
            await handleTransportInfo(stanza)
        case .sessionInfo, .transportReplace:
            break // fase 1: no-op
        }
    }

    private func handleSessionInitiate(_ stanza: JingleStanza) async {
        guard let initiator = stanza.initiator, !stanza.sid.isEmpty else { return }
        let sid = stanza.sid
        // Duplicado de una sesión ya registrada: ignorar.
        guard sessions[sid] == nil else { return }
        // Ocupado: ya hay una llamada en curso (entrante o saliente).
        if !sessions.isEmpty {
            try? await sendSessionTerminate(to: initiator, sid: sid, reason: "busy")
            incomingContinuation?.yield((
                sid,
                initiator,
                JingleStanza(action: .sessionTerminate, sid: sid, initiator: initiator, responder: nil, terminateReason: "busy", contents: [])
            ))
            return
        }
        sessions[sid] = JingleSession(sid: sid, initiator: initiator, responder: nil, remoteJID: initiator, state: .pending)
        armRingTimer(sid: sid, initiator: initiator)
        incomingContinuation?.yield((sid, initiator, stanza))
    }

    private func handleSessionAccept(_ stanza: JingleStanza) async {
        guard let initiator = stanza.initiator, !stanza.sid.isEmpty else { return }
        let sid = stanza.sid
        cancelRingTimer(sid: sid)
        sessions[sid]?.state = .active
        incomingContinuation?.yield((sid, initiator, stanza))
    }

    private func handleSessionTerminate(_ stanza: JingleStanza) async {
        let sid = stanza.sid
        cancelRingTimer(sid: sid)
        guard let session = sessions.removeValue(forKey: sid) else { return }
        incomingContinuation?.yield((sid, session.initiator, stanza))
    }

    private func handleTransportInfo(_ stanza: JingleStanza) async {
        guard let initiator = stanza.initiator, !stanza.sid.isEmpty else { return }
        guard sessions[stanza.sid] != nil else { return }
        incomingContinuation?.yield((stanza.sid, initiator, stanza))
    }

    // MARK: - Saliente

    func sendSessionInitiate(
        localJID: String,
        to jid: String,
        sid: String,
        sdp: String,
        fingerprint: String,
        isVideo: Bool
    ) async throws {
        guard sessions[sid] == nil else { throw JingleSendError.sessionAlreadyExists }
        let media = isVideo ? "video" : "audio"
        let content = try mapper.content(
            from: SessionDescription(sdp: sdp, type: .offer),
            creator: "initiator",
            name: media
        )
        sessions[sid] = JingleSession(sid: sid, initiator: localJID, responder: nil, remoteJID: jid, state: .pending)
        armRingTimer(sid: sid, initiator: localJID)
        let body = contentXML(content, fallbackFingerprint: fingerprint, fallbackSetup: "actpass")
        try await sendIQ(action: .sessionInitiate, to: jid, sid: sid, initiator: localJID, body: body)
    }

    func sendSessionAccept(
        localJID: String,
        to jid: String,
        sid: String,
        sdp: String,
        fingerprint: String
    ) async throws {
        guard sessions[sid] != nil else { throw JingleSendError.unknownSession }
        let content = try mapper.content(
            from: SessionDescription(sdp: sdp, type: .answer),
            creator: "responder",
            name: contentName(from: sdp)
        )
        cancelRingTimer(sid: sid)
        sessions[sid]?.state = .active
        let body = contentXML(content, fallbackFingerprint: fingerprint, fallbackSetup: "active")
        try await sendIQ(action: .sessionAccept, to: jid, sid: sid, initiator: localJID, body: body)
    }

    func sendSessionTerminate(to jid: String, sid: String, reason: String) async throws {
        cancelRingTimer(sid: sid)
        sessions[sid]?.state = .ended
        sessions.removeValue(forKey: sid)
        let body = "      <reason><\(reason)/></reason>"
        try await sendIQ(action: .sessionTerminate, to: jid, sid: sid, body: body)
    }

    /// Envía el candidato REAL (ip/puerto del engine), nunca un placeholder.
    func sendTransportInfo(to jid: String, sid: String, candidate: JingleCandidate, creator: String, name: String) async throws {
        let body = """
            <content creator='\(creator)' name='\(name)'>
              <transport xmlns='urn:xmpp:jingle:transports:ice-udp:1'>
                <candidate component='\(candidate.component)' foundation='\(candidate.foundation)' generation='\(candidate.generation)' id='\(candidate.id)' ip='\(candidate.ip)' network='\(candidate.network)' port='\(candidate.port)' priority='\(candidate.priority)' protocol='\(candidate.protocol)' type='\(candidate.type)'/>
              </transport>
            </content>
        """
        try await sendIQ(action: .transportInfo, to: jid, sid: sid, body: body)
    }

    func sendSessionInfo(to jid: String, sid: String) async throws {
        try await sendIQ(action: .sessionInfo, to: jid, sid: sid)
    }

    /// Mantiene la API pública existente: extrae el SDP de una stanza.
    func extractSDP(from jingleXML: String) -> String? {
        guard let stanza = try? parser.parse(jingleXML),
              let content = stanza.contents.first else { return nil }
        return try? mapper.sdp(from: content, type: .offer).sdp
    }

    // MARK: - Timbre / timeout

    private func armRingTimer(sid: String, initiator: String) {
        cancelRingTimer(sid: sid)
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.sleeper(self.ringTimeout)
            } catch {
                return // cancelado (accept o terminate)
            }
            await self.ringTimeoutFired(sid: sid, initiator: initiator)
        }
        ringTimers[sid] = task
    }

    private func cancelRingTimer(sid: String) {
        ringTimers[sid]?.cancel()
        ringTimers[sid] = nil
    }

    private func ringTimeoutFired(sid: String, initiator: String) async {
        guard let session = sessions[sid], session.state == .pending else { return }
        sessions.removeValue(forKey: sid)
        ringTimers[sid] = nil
        try? await sendSessionTerminate(to: session.remoteJID, sid: sid, reason: "timeout")
        incomingContinuation?.yield((
            sid,
            initiator,
            JingleStanza(action: .sessionTerminate, sid: sid, initiator: initiator, responder: nil, terminateReason: "timeout", contents: [])
        ))
    }

    // MARK: - Serialización

    private func sendIQ(
        action: JingleAction,
        to jid: String,
        sid: String,
        initiator: String? = nil,
        body: String = ""
    ) async throws {
        let id = nextID()
        let initiatorAttr = initiator.map { " initiator='\($0.xmlEscaped)'" } ?? ""
        let xml = """
        <iq id='\(id)' to='\(jid.xmlEscaped)' type='set'>
          <jingle xmlns='urn:xmpp:jingle:1' action='\(action.rawValue)' sid='\(sid)'\(initiatorAttr)>
        \(body)
          </jingle>
        </iq>
        """
        try await connection.send(string: xml)
    }

    /// Serializa un `<content/>` con description RTP, security DTLS y
    /// transport ICE vacío (los candidatos viajan aparte).
    private func contentXML(_ content: JingleContent, fallbackFingerprint: String, fallbackSetup: String) -> String {
        let creator = content.creator ?? "initiator"
        let name = content.name ?? content.media ?? "audio"
        var xml = "    <content creator='\(creator)' name='\(name)'>"
        if let media = content.media {
            xml += "\n      <description xmlns='urn:xmpp:jingle:apps:rtp:1' media='\(media)'>"
            for pt in content.payloadTypes {
                xml += "\n        <payload-type id='\(pt.id)' name='\(pt.name)' clockrate='\(pt.clockrate)'"
                if let channels = pt.channels {
                    xml += " channels='\(channels)'"
                }
                xml += "/>"
            }
            xml += "\n      </description>"
        }
        let hash = content.fingerprint?.hash ?? "sha-256"
        let value = content.fingerprint?.value ?? fallbackFingerprint
        let setup = (content.fingerprint?.setup.isEmpty != false) ? fallbackSetup : content.fingerprint!.setup
        if !value.isEmpty {
            xml += "\n      <security xmlns='urn:xmpp:jingle:apps:dtls:0'>"
            xml += "\n        <fingerprint hash='\(hash)'>\(value)</fingerprint>"
            xml += "\n        <setup>\(setup)</setup>"
            xml += "\n      </security>"
        }
        xml += "\n      <transport xmlns='urn:xmpp:jingle:transports:ice-udp:1'/>"
        xml += "\n    </content>"
        return xml
    }

    /// Nombre del content (audio/video) derivado del SDP.
    private func contentName(from sdp: String) -> String {
        for line in sdp.components(separatedBy: .newlines) where line.hasPrefix("m=") {
            let parts = line.components(separatedBy: " ")
            if parts.count >= 2 { return String(parts[0].dropFirst(2)) }
        }
        return "audio"
    }

    private func nextID() -> String {
        idCounter += 1
        return "jcl\(idCounter)"
    }
}