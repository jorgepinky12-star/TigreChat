import Foundation

/// Orquestador de llamadas VoIP (fase 1): única autoridad de estado de llamada.
///
/// Enlaza los tres dominios:
/// - `JingleManager` (actor M1): stanzas entrantes/salientes, timbre y timeout.
/// - `WebRTCEngineProtocol` (media, MainActor): oferta/respuesta, ICE, DTLS.
/// - `CallKitAdapting` (UI del sistema, seam D7): timbre y colgado saliente.
/// - `CallHistoryStore` + `FingerprintStore` (SwiftData, MainActor):
///   REQ-HIST (toda llamada con su estado final) y REQ-JINGLE-011 (TOFU).
///
/// Corre en su propio actor: la orquestación no bloquea la UI y salta a
/// MainActor solo para media/CallKit/persistencia. La regresión M2 arregla
/// los 10 bugs del esqueleto (bug 01: un solo stream, nunca `finish()`;
/// bug 02: UUID 1:1 con el sid; bug 08: un único initiate por llamada;
/// candidatos reales; fingerprint gate antes de media; engine fresco tras
/// terminate; toggleVideo sin efectos).
actor XMPPCallRepository: CallRepository {
    private let jingleManager: JingleManager
    private let webRTC: any WebRTCEngineProtocol
    private let callKit: any CallKitAdapting
    private let historyStore: CallHistoryStore
    private let fingerprintStore: FingerprintStore
    private let localJIDProvider: @Sendable () async -> String?

    private(set) var currentCall: Call?
    private var activeUUID: UUID?
    /// SDP remoto (oferta entrante) pendiente para `acceptCall`.
    private var pendingRemoteSDP: String?
    /// Pausa TOFU: la huella del primer contacto esperando verificación.
    private var pendingIncoming: PendingIncoming?
    private var listenerTask: Task<Void, Never>?

    private struct PendingIncoming {
        let sid: String
        let jid: String // bare JID
        let remoteOfferSDP: String
        let fingerprint: String
        let uuid: UUID
    }

    private var callContinuation: AsyncStream<Call>.Continuation?
    nonisolated let callStateStream: AsyncStream<Call>

    init(
        jingleManager: JingleManager,
        webRTC: any WebRTCEngineProtocol,
        callKit: any CallKitAdapting,
        historyStore: CallHistoryStore,
        fingerprintStore: FingerprintStore,
        localJIDProvider: @escaping @Sendable () async -> String?
    ) {
        self.jingleManager = jingleManager
        self.webRTC = webRTC
        self.callKit = callKit
        self.historyStore = historyStore
        self.fingerprintStore = fingerprintStore
        self.localJIDProvider = localJIDProvider
        var cont: AsyncStream<Call>.Continuation?
        callStateStream = AsyncStream { continuation in cont = continuation }
        callContinuation = cont
    }

    func setup() async {
        await MainActor.run {
            webRTC.delegate = self

            callKit.onAnswer = { [weak self] _ in
                Task { [weak self] in await self?.handleAccept() }
            }

            callKit.onEnd = { [weak self] _ in
                Task { [weak self] in await self?.handleEnd() }
            }

            callKit.onMute = { [weak self] _, muted in
                Task { [weak self] in await self?.webRTC.muteAudio(muted) }
            }

            // bug 08: el único camino de llamada saliente es startCall(jid:isVideo:);
            // onStartCall queda sin cablear para no duplicar session-initiate.
            callKit.onStartCall = nil
        }

        listenerTask = Task { [weak self] in
            await self?.listenForIncomingJingle()
        }
    }

    // MARK: - Stream de eventos Jingle (única cola de orquestación)

    private func listenForIncomingJingle() async {
        for await event in jingleManager.incomingCallStream {
            switch event.stanza.action {
            case .sessionInitiate:
                await handleIncomingInitiate(event)
            case .sessionAccept:
                await handleRemoteAccept(event)
            case .sessionTerminate:
                await handleRemoteTerminate(event)
            case .transportInfo:
                await handleIncomingCandidate(event)
            case .sessionInfo, .transportReplace:
                break // fase 1: no-op
            }
        }
    }

    // MARK: - Entrante (session-initiate)

    private func handleIncomingInitiate(_ event: (sid: String, initiator: String, stanza: JingleStanza)) async {
        guard let content = event.stanza.contents.first else { return }
        let remoteOffer = (try? JingleSDPMapper().sdp(from: content, type: .offer).sdp) ?? ""
        let bare = bareJID(event.initiator)

        // REQ-JINGLE-011: sin huella → fail closed.
        guard let presented = content.fingerprint?.value, !presented.isEmpty else {
            await blockIncoming(event: event, bare: bare)
            return
        }

        let stored = await fingerprintStore.storedFingerprint(for: bare)
        guard let stored else {
            // TOFU: primer contacto → pausa de verificación, sin ring ni media.
            // El id del Call ES el sid del wire (igual que en el ring): los
            // guards de candidate/terminate/accept comparan call.id == sid.
            var pending = Call(id: event.sid, jid: bare, direction: .incoming, isVideo: false)
            pending.state = .needsVerification
            currentCall = pending
            pendingIncoming = PendingIncoming(
                sid: event.sid,
                jid: bare,
                remoteOfferSDP: remoteOffer,
                fingerprint: presented,
                uuid: UUID()
            )
            callContinuation?.yield(pending)
            return
        }

        // Huella conocida pero distinta → hard block (security-error), sin media.
        guard stored == presented else {
            await blockIncoming(event: event, bare: bare)
            return
        }

        // Huella verificada: el gate está abierto ANTES de tocar media.
        await ringIncoming(event: event, remoteOfferSDP: remoteOffer, bare: bare)
    }

    private func ringIncoming(event: (sid: String, initiator: String, stanza: JingleStanza), remoteOfferSDP: String, bare: String) async {
        // id = sid del wire: `handleIncomingCandidate`/`handleRemoteTerminate`
        // comparan `call.id == event.sid` (bug M4: el Call se creaba con UUID
        // aleatorio y el candidate entrante nunca llegaba al engine).
        var call = Call(id: event.sid, jid: bare, direction: .incoming, isVideo: false)
        call.state = .ringing
        currentCall = call
        pendingRemoteSDP = remoteOfferSDP

        let uuid = UUID()
        activeUUID = uuid
        try? await webRTC.setRemoteDescription(SessionDescription(sdp: remoteOfferSDP, type: .offer))
        try? await callKit.reportIncomingCall(uuid: uuid, jid: bare, hasVideo: false)
        callContinuation?.yield(call)
    }

    /// Fail-closed: huella ausente o mismatch → terminate(security-error),
    /// historial `failed`, sin ring ni media.
    private func blockIncoming(event: (sid: String, initiator: String, stanza: JingleStanza), bare: String) async {
        try? await jingleManager.sendSessionTerminate(to: event.initiator, sid: event.sid, reason: "security-error")
        var blocked = Call(jid: bare, direction: .incoming, isVideo: false)
        blocked.state = .failed
        _ = try? await historyStore.upsert(
            sid: event.sid, jid: bare, direction: .incoming, status: .failed, isVideo: false
        )
        callContinuation?.yield(blocked)
    }

    // MARK: - Session-accept remoto (respuesta saliente)

    private func handleRemoteAccept(_ event: (sid: String, initiator: String, stanza: JingleStanza)) async {
        guard let call = currentCall, call.id == event.sid else { return }
        if let content = event.stanza.contents.first,
           let remoteAnswer = try? JingleSDPMapper().sdp(from: content, type: .answer) {
            try? await webRTC.setRemoteDescription(remoteAnswer)
        }
        var updated = call
        updated.state = .connecting
        currentCall = updated
        callContinuation?.yield(updated)
    }

    // MARK: - Session-terminate (remoto / sintético busy-timeout)

    private func handleRemoteTerminate(_ event: (sid: String, initiator: String, stanza: JingleStanza)) async {
        let reason = event.stanza.terminateReason

        // Evento sintético de una sesión que no es la activa: busy de la
        // 2ª llamada entrante → solo historial, sin tocar la llamada activa.
        guard let call = currentCall, call.id == event.sid else {
            if reason == "busy" {
                _ = try? await historyStore.upsert(
                    sid: event.sid,
                    jid: bareJID(event.initiator),
                    direction: .incoming,
                    status: .busy,
                    isVideo: false
                )
            }
            return
        }

        currentCall = nil
        activeUUID = nil
        pendingRemoteSDP = nil

        var terminal = call
        var status: CallStatus = .unanswered
        switch reason {
        case "decline":
            terminal.state = .ended
            status = .declined
        case "timeout":
            terminal.state = .missed
            status = .unanswered
        default:
            terminal.state = .ended
            if let start = call.startTime {
                terminal.duration = Date().timeIntervalSince(start)
                status = .answered
            }
        }

        _ = try? await historyStore.upsert(
            sid: call.id,
            jid: bareJID(call.jid),
            direction: call.direction,
            status: status,
            duration: terminal.duration,
            isVideo: call.isVideo
        )
        await MainActor.run { self.webRTC.disconnect() }
        callContinuation?.yield(terminal)
    }

    // MARK: - transport-info entrante → engine (candidato real)

    private func handleIncomingCandidate(_ event: (sid: String, initiator: String, stanza: JingleStanza)) async {
        guard let call = currentCall, call.id == event.sid else { return }
        guard let candidate = event.stanza.contents.first?.candidates.first else { return }
        let ice = ICECandidate(
            sdp: "candidate:\(candidate.foundation) \(candidate.component) \(candidate.protocol) \(candidate.priority) \(candidate.ip) \(candidate.port) typ \(candidate.type)",
            sdpMLineIndex: 0,
            sdpMid: "audio"
        )
        try? await webRTC.addICECandidate(ice)
    }

    // MARK: - Saliente

    func startCall(jid: String, isVideo: Bool) async throws -> Call {
        guard currentCall == nil else { throw CallError.busy }

        var call = Call(jid: jid, direction: .outgoing, isVideo: isVideo)
        call.state = .dialing
        currentCall = call

        let uuid = UUID()
        activeUUID = uuid

        // Oferta real ANTES de emitir: el session-initiate lleva el SDP y
        // la huella DTLS del engine (bug 08: un único camino, un único iq).
        let offer = try await webRTC.createOffer()
        let localFP = await webRTC.localDTLSFingerprint() ?? ""
        try await jingleManager.sendSessionInitiate(
            localJID: await localJIDProvider() ?? "",
            to: jid,
            sid: call.id,
            sdp: offer.sdp,
            fingerprint: localFP,
            isVideo: isVideo
        )

        await MainActor.run {
            self.callKit.startCall(uuid: uuid, jid: jid, isVideo: isVideo)
            self.callKit.reportOutgoingCallConnecting(uuid: uuid)
        }

        call.state = .ringing
        currentCall = call
        callContinuation?.yield(call)
        return call
    }

    func acceptCall(_ call: Call) async throws {
        guard currentCall?.id == call.id else { throw CallError.notConnected }
        var updated = call
        updated.state = .connecting
        currentCall = updated

        let localFP = await webRTC.localDTLSFingerprint() ?? ""
        let answer = try await webRTC.createAnswer(for: SessionDescription(sdp: pendingRemoteSDP ?? "", type: .offer))
        try await jingleManager.sendSessionAccept(
            localJID: await localJIDProvider() ?? "",
            to: call.jid,
            sid: call.id,
            sdp: answer.sdp,
            fingerprint: localFP
        )
        callContinuation?.yield(updated)
    }

    func endCall(_ call: Call) async throws {
        guard currentCall?.id == call.id else { return }
        try? await jingleManager.sendSessionTerminate(to: call.jid, sid: call.id, reason: "success")

        // Teardown con currentCall ya liberado: `didDisconnectCall` del motor
        // no debe re-procesar el fin de llamada (doblemente).
        currentCall = nil
        pendingRemoteSDP = nil
        await MainActor.run { self.webRTC.disconnect() }
        let uuid = activeUUID
        activeUUID = nil
        if let uuid {
            await MainActor.run { self.callKit.endCall(uuid: uuid) }
        }

        var terminal = call
        terminal.state = .ended
        let status: CallStatus = call.startTime != nil ? .answered : .unanswered
        if let start = call.startTime {
            terminal.duration = Date().timeIntervalSince(start)
        }
        _ = try? await historyStore.upsert(
            sid: call.id,
            jid: bareJID(call.jid),
            direction: call.direction,
            status: status,
            duration: terminal.duration,
            isVideo: call.isVideo
        )
        callContinuation?.yield(terminal)
    }

    func rejectCall(_ call: Call) async throws {
        guard currentCall?.id == call.id else { return }
        try? await jingleManager.sendSessionTerminate(to: call.jid, sid: call.id, reason: "decline")
        currentCall = nil
        pendingRemoteSDP = nil
        await MainActor.run { self.webRTC.disconnect() }
        let uuid = activeUUID
        activeUUID = nil
        if let uuid {
            await MainActor.run { self.callKit.endCall(uuid: uuid) }
        }

        var terminal = call
        terminal.state = .ended
        _ = try? await historyStore.upsert(
            sid: call.id,
            jid: bareJID(call.jid),
            direction: call.direction,
            status: .declined,
            isVideo: call.isVideo
        )
        callContinuation?.yield(terminal)
    }

    func muteCall(_ muted: Bool) async throws {
        await MainActor.run { self.webRTC.muteAudio(muted) }
    }

    // REQ-MEDIA-005: el video es fase 2 — sin efectos, sin renegociación.
    func toggleVideo() async throws {}

    func switchCamera() async throws {
        await MainActor.run { self.webRTC.switchCamera() }
    }

    // MARK: - Verificación TOFU (REQ-JINGLE-011)

    /// El usuario aceptó la huella del primer contacto: se persiste y la
    /// llamada en pausa comienza a sonar (el gate se abrió antes de media).
    func acceptFingerprint() async throws {
        guard let pending = pendingIncoming else { return }
        pendingIncoming = nil
        try await fingerprintStore.store(pending.fingerprint, for: pending.jid)

        pendingRemoteSDP = pending.remoteOfferSDP
        try? await webRTC.setRemoteDescription(SessionDescription(sdp: pending.remoteOfferSDP, type: .offer))

        // Mismo contrato que ringIncoming: id = sid del wire.
        var call = Call(id: pending.sid, jid: pending.jid, direction: .incoming, isVideo: false)
        call.state = .ringing
        currentCall = call
        activeUUID = pending.uuid
        try? await callKit.reportIncomingCall(uuid: pending.uuid, jid: pending.jid, hasVideo: false)
        callContinuation?.yield(call)
    }

    // MARK: - Callbacks CallKit

    private func handleAccept() async {
        guard let call = currentCall else { return }
        try? await acceptCall(call)
    }

    private func handleEnd() async {
        guard let call = currentCall else { return }
        try? await endCall(call)
    }

    // MARK: - Helpers

    private func bareJID(_ jid: String) -> String {
        guard let slash = jid.firstIndex(of: "/") else { return jid }
        return String(jid[..<slash])
    }
}

// MARK: - WebRTCEngineDelegate

extension XMPPCallRepository: WebRTCEngineDelegate {
    nonisolated func didGenerateLocalOffer(_ sdp: SessionDescription) {}

    nonisolated func didGenerateLocalAnswer(_ sdp: SessionDescription) {}

    /// Candidato ICE local → remotо vía transport-info (REQ-MEDIA-003).
    nonisolated func didReceiveICECandidate(_ candidate: ICECandidate) {
        Task { await self.forwardLocalCandidate(candidate) }
    }

    nonisolated func didConnectCall() {
        Task { await self.handleCallConnected() }
    }

    nonisolated func didDisconnectCall() {
        Task { await self.handleCallDisconnected() }
    }

    nonisolated func didFailWithError(_ error: Error) {
        Task { await self.handleCallFailed(error) }
    }

    private func forwardLocalCandidate(_ candidate: ICECandidate) async {
        guard let call = currentCall, let parsed = parseCandidateLine(candidate.sdp) else { return }
        try? await jingleManager.sendTransportInfo(
            to: call.jid,
            sid: call.id,
            candidate: parsed,
            creator: "initiator",
            name: "audio"
        )
    }

    private func handleCallConnected() async {
        guard var call = currentCall else { return }
        call.state = .connected
        call.startTime = Date()
        currentCall = call
        if call.direction == .outgoing {
            // bug 02: el UUID reportado a CallKit es el MISMO de la llamada
            // iniciada (startCall) — nunca se inventa uno nuevo aquí.
            guard let uuid = activeUUID else { return }
            await MainActor.run { self.callKit.reportOutgoingCallConnected(uuid: uuid) }
        }
        callContinuation?.yield(call)
    }

    private func handleCallDisconnected() async {
        guard let call = currentCall, call.state != .ended else { return }
        currentCall = nil
        activeUUID = nil
        pendingRemoteSDP = nil

        var terminal = call
        terminal.state = .ended
        let status: CallStatus = call.startTime != nil ? .answered : .unanswered
        if let start = call.startTime {
            terminal.duration = Date().timeIntervalSince(start)
        }
        _ = try? await historyStore.upsert(
            sid: call.id,
            jid: bareJID(call.jid),
            direction: call.direction,
            status: status,
            duration: terminal.duration,
            isVideo: call.isVideo
        )
        callContinuation?.yield(terminal)
    }

    private func handleCallFailed(_ error: Error) async {
        guard let call = currentCall else { return }
        currentCall = nil
        activeUUID = nil
        pendingRemoteSDP = nil

        var terminal = call
        terminal.state = .failed
        _ = try? await historyStore.upsert(
            sid: call.id,
            jid: bareJID(call.jid),
            direction: call.direction,
            status: .failed,
            isVideo: call.isVideo
        )
        callContinuation?.yield(terminal)
    }

    /// Parsea una línea ICE (`candidate:<foundation> <component> <protocol>
    /// <priority> <ip> <port> typ <type>`) al modelo Jingle (XEP-0176).
    private func parseCandidateLine(_ sdp: String) -> JingleCandidate? {
        let parts = sdp.split(separator: " ").map(String.init)
        guard parts.count >= 6, parts[0].hasPrefix("candidate:") else { return nil }
        var type = "host"
        if let idx = parts.firstIndex(of: "typ"), idx + 1 < parts.count {
            type = parts[idx + 1]
        }
        return JingleCandidate(
            component: Int(parts[1]) ?? 1,
            foundation: String(parts[0].dropFirst("candidate:".count)),
            generation: 0,
            id: UUID().uuidString,
            ip: parts[4],
            network: 1,
            port: Int(parts[5]) ?? 0,
            priority: Int(parts[3]) ?? 0,
            protocol: parts[2],
            type: type
        )
    }
}