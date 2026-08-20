//
//  XMPPCallRepositoryTests.swift
//  TigreChatTests
//
//  T-VOIPCALLS-020 RED: orquestación del repositorio contra la API real del
//  JingleManager (transporte grabado) + MockWebRTCEngine.
//
//  Regresión de los 10 bugs del esqueleto:
//  - bug 01: callStateStream NUNCA finaliza entre llamadas (REQ-JINGLE-010)
//  - bug 02: el UUID de CallKit es el MISMO en start/connecting/connected
//  - bug 08: exactamente UN session-initiate por llamada (REQ-JINGLE-009)
//  - REQ-JINGLE-006: busy de 2ª llamada registrado en historial
//  - REQ-JINGLE-005: ring timeout → unanswered (duración 0)
//  - decline → historial declined
//  - REQ-JINGLE-011: fingerprint gate ANTES de media (TOFU + mismatch hard block)
//  - REQ-MEDIA-007: reuse con engine fresco tras terminate
//  - REQ-MEDIA-005: toggleVideo sin efectos
//

import XCTest
import SwiftData
@testable import TigreChat

// MARK: - Dobles de test

/// Transporte de grabación (sin red), mismo patrón que JingleManagerTests.
private final class RecordingTransport: JingleTransport, @unchecked Sendable {
    private let queue = DispatchQueue(label: "test.repo.transport")
    private var items: [String] = []

    var sent: [String] {
        queue.sync { items }
    }

    func send(string: String) async throws {
        queue.sync { items.append(string) }
    }
}

/// Registra las acciones CallKit sin sistema (seam D7).
@MainActor
private final class RecordingCallKitAdapting: CallKitAdapting {
    var onAnswer: ((UUID) -> Void)?
    var onEnd: ((UUID) -> Void)?
    var onMute: ((UUID, Bool) -> Void)?
    var onStartCall: ((UUID, String) -> Void)?

    private(set) var reportedIncoming: [(uuid: UUID, jid: String, hasVideo: Bool)] = []
    private(set) var startedCalls: [(uuid: UUID, jid: String, isVideo: Bool)] = []
    private(set) var endedCalls: [UUID] = []
    private(set) var remoteEndedCalls: [UUID] = []
    private(set) var connectedCalls: [UUID] = []

    func reportIncomingCall(uuid: UUID, jid: String, hasVideo: Bool) async throws {
        reportedIncoming.append((uuid, jid, hasVideo))
    }

    func startCall(uuid: UUID, jid: String, isVideo: Bool) {
        startedCalls.append((uuid, jid, isVideo))
    }

    func endCall(uuid: UUID) {
        endedCalls.append(uuid)
    }

    func reportRemoteEnded(uuid: UUID) {
        remoteEndedCalls.append(uuid)
    }

    func reportOutgoingCallConnecting(uuid: UUID) {}

    func reportOutgoingCallConnected(uuid: UUID) {
        connectedCalls.append(uuid)
    }
}

// MARK: - Suite

@MainActor
final class XMPPCallRepositoryTests: XCTestCase {

    private var transport: RecordingTransport!
    private var manager: JingleManager!
    private var engine: MockWebRTCEngine!
    private var callKit: RecordingCallKitAdapting!
    private var historyStore: CallHistoryStore!
    private var fingerprintStore: FingerprintStore!

    override func setUp() async throws {
        transport = RecordingTransport()
        manager = JingleManager(connection: transport, ringTimeout: .seconds(30))
        engine = MockWebRTCEngine()
        callKit = RecordingCallKitAdapting()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: CallHistoryEntry.self, FingerprintEntity.self, ConversationEntity.self,
            configurations: config
        )
        historyStore = CallHistoryStore(modelContainer: container)
        fingerprintStore = FingerprintStore(modelContainer: container)
    }

    private func makeRepo(ringTimeout: Duration = .seconds(30)) -> XMPPCallRepository {
        manager = JingleManager(connection: transport, ringTimeout: ringTimeout)
        let repo = XMPPCallRepository(
            jingleManager: manager,
            webRTC: engine,
            callKit: callKit,
            historyStore: historyStore,
            fingerprintStore: fingerprintStore,
            localJIDProvider: { "jorge@z17.cu/phone" }
        )
        return repo
    }

    // MARK: - Fixtures

    private let fpAna = "A58B0C0B39E79FB5045A2BBCD6430EEF88E809DB7590A36363EFA59FA9067C44"
    private let fpAna2 = "B89C0C0B39E79FB5045A2BBCD6430EEF88E809DB7590A36363EFA59FA9067C44"

    private func initiateXML(sid: String, fingerprint: String, from: String = "ana@z17.cu/phonemac") -> String {
        """
        <iq to='jorge@z17.cu/phone' id='in1' type='set'>
          <jingle xmlns='urn:xmpp:jingle:1' action='session-initiate' initiator='\(from)' sid='\(sid)'>
            <content creator='initiator' name='audio'>
              <description xmlns='urn:xmpp:jingle:apps:rtp:1' media='audio'>
                <payload-type id='96' name='opus' clockrate='48000'/>
              </description>
              <security xmlns='urn:xmpp:jingle:apps:dtls:0'>
                <fingerprint hash='sha-256'>\(fingerprint)</fingerprint>
                <setup>actpass</setup>
              </security>
            </content>
          </jingle>
        </iq>
        """
    }

    private func initiateXMLWithoutFingerprint(sid: String) -> String {
        """
        <iq to='jorge@z17.cu/phone' id='in1' type='set'>
          <jingle xmlns='urn:xmpp:jingle:1' action='session-initiate' initiator='ana@z17.cu/phonemac' sid='\(sid)'>
            <content creator='initiator' name='audio'>
              <description xmlns='urn:xmpp:jingle:apps:rtp:1' media='audio'>
                <payload-type id='96' name='opus' clockrate='48000'/>
              </description>
            </content>
          </jingle>
        </iq>
        """
    }

    private func acceptXML(sid: String, fingerprint: String = "B89C0C0B39E79FB5045A2BBCD6430EEF88E809DB7590A36363EFA59FA9067C44") -> String {
        """
        <iq to='jorge@z17.cu/phone' id='in2' type='set'>
          <jingle xmlns='urn:xmpp:jingle:1' action='session-accept' initiator='ana@z17.cu/phonemac' sid='\(sid)'>
            <content creator='responder' name='audio'>
              <description xmlns='urn:xmpp:jingle:apps:rtp:1' media='audio'>
                <payload-type id='96' name='opus' clockrate='48000'/>
              </description>
              <security xmlns='urn:xmpp:jingle:apps:dtls:0'>
                <fingerprint hash='sha-256'>\(fingerprint)</fingerprint>
                <setup>active</setup>
              </security>
            </content>
          </jingle>
        </iq>
        """
    }

    private func terminateXML(sid: String, reason: String, from: String = "ana@z17.cu/phonemac") -> String {
        """
        <iq to='jorge@z17.cu/phone' id='in3' type='set'>
          <jingle xmlns='urn:xmpp:jingle:1' action='session-terminate' initiator='\(from)' sid='\(sid)'>
            <reason><\(reason)/></reason>
          </jingle>
        </iq>
        """
    }

    private func transportInfoXML(sid: String, ip: String = "192.0.2.55", port: Int = 45664) -> String {
        """
        <iq to='jorge@z17.cu/phone' id='in4' type='set'>
          <jingle xmlns='urn:xmpp:jingle:1' action='transport-info' initiator='ana@z17.cu/phonemac' sid='\(sid)'>
            <content creator='initiator' name='audio'>
              <transport xmlns='urn:xmpp:jingle:transports:ice-udp:1'>
                <candidate component='1' foundation='3' generation='0' id='x8v7w6u5' ip='\(ip)' network='1' port='\(port)' priority='1694498815' protocol='udp' type='srflx'/>
              </transport>
            </content>
          </jingle>
        </iq>
        """
    }

    // MARK: - bug 01 + REQ-JINGLE-010: un solo stream para varias llamadas

    func testSixStatesFlowOnOneStreamWithoutFinish() async throws {
        let repo = makeRepo()
        await repo.setup()
        var iterator = repo.callStateStream.makeAsyncIterator()

        // Llama 1: outgoing → accept → connected → remote hangup.
        let call1 = try await repo.startCall(jid: "ana@z17.cu", isVideo: false)
        let first = await iterator.next()
        let ringing1 = try XCTUnwrap(first)
        XCTAssertEqual(ringing1.state, .ringing)

        await manager.handleJingleStanza(xml: acceptXML(sid: call1.id))
        let second = await iterator.next()
        let connecting = try XCTUnwrap(second)
        XCTAssertEqual(connecting.state, .connecting)

        engine.simulateConnection()
        let third = await iterator.next()
        let connected = try XCTUnwrap(third)
        XCTAssertEqual(connected.state, .connected)

        await manager.handleJingleStanza(xml: terminateXML(sid: call1.id, reason: "success"))
        let fourth = await iterator.next()
        let ended1 = try XCTUnwrap(fourth)
        XCTAssertEqual(ended1.state, .ended)

        // El stream NO finalizó tras la llamada 1: la llamada 2 fluye por él.
        let call2 = try await repo.startCall(jid: "bob@z17.cu", isVideo: false)
        let fifth = await iterator.next()
        let ringing2 = try XCTUnwrap(fifth)
        XCTAssertEqual(ringing2.state, .ringing)

        try await repo.endCall(call2)
        let sixth = await iterator.next()
        let ended2 = try XCTUnwrap(sixth)
        XCTAssertEqual(ended2.state, .ended)

        // Y el currentCall quedó libre tras el fin (REQ-JINGLE-008).
        let current = await repo.currentCall
        XCTAssertNil(current)
    }

    // MARK: - bug 08 + REQ-JINGLE-009: un único initiate por llamada

    func testSingleInitiatePerCallAndLocalBusyRejectsSecond() async throws {
        let repo = makeRepo()
        await repo.setup()

        _ = try await repo.startCall(jid: "ana@z17.cu", isVideo: false)
        let initiateCount = transport.sent.filter { $0.contains("action='session-initiate'") }.count
        XCTAssertEqual(initiateCount, 1, "Debe emitirse exactamente UN session-initiate")

        // Segunda llamada con la primera activa → error local busy (REQ-JINGLE-008).
        do {
            _ = try await repo.startCall(jid: "bob@z17.cu", isVideo: false)
            XCTFail("startCall no debe permitir una segunda llamada activa")
        } catch let error as CallError {
            guard case .busy = error else {
                return XCTFail("Error esperado: busy, obtenido \(error)")
            }
        }
        let afterSecond = transport.sent.filter { $0.contains("action='session-initiate'") }.count
        XCTAssertEqual(afterSecond, 1, "La segunda llamada no debe emitir initiate")
    }

    // MARK: - bug 08: initiator = JID local en el XML de salida

    func testOutgoingInitiateUsesLocalJIDAsInitiator() async throws {
        let repo = makeRepo()
        await repo.setup()

        _ = try await repo.startCall(jid: "ana@z17.cu", isVideo: false)
        let initiate = try XCTUnwrap(
            transport.sent.first { $0.contains("action='session-initiate'") },
            "Debe existir un session-initiate saliente"
        )
        XCTAssertTrue(
            initiate.contains("initiator='jorge@z17.cu/phone'"),
            "El initiate debe llevar el JID local como initiator (nunca vacío ni el remoto): \(initiate)"
        )
    }

    // MARK: - bug 02 + REQ-CALLKIT-003: UUID estable 1:1 sid↔UUID

    func testConnectedUUIDEqualsStartedUUID() async throws {
        let repo = makeRepo()
        await repo.setup()
        var iterator = repo.callStateStream.makeAsyncIterator()

        let call = try await repo.startCall(jid: "ana@z17.cu", isVideo: false)
        let ringing = await iterator.next()
        _ = try XCTUnwrap(ringing) // .ringing
        let startedUUID = try XCTUnwrap(callKit.startedCalls.first?.uuid)

        await manager.handleJingleStanza(xml: acceptXML(sid: call.id))
        let connectingEvent = await iterator.next()
        let connecting = try XCTUnwrap(connectingEvent)
        XCTAssertEqual(connecting.state, .connecting)
        engine.simulateConnection()
        let connectedEvent = await iterator.next()
        let connected = try XCTUnwrap(connectedEvent)
        XCTAssertEqual(connected.state, .connected)

        // El connected se reporta con el MISMO uuid, nunca uno nuevo.
        // (El consumo determinista de los eventos del stream garantiza que
        // el actor del repo ya procesó didConnectCall antes del assert.)
        XCTAssertEqual(callKit.connectedCalls, [startedUUID])
        // Y hasVideo=false en fase 1 (REQ-CALLKIT-004/REQ-MEDIA-005).
        XCTAssertEqual(callKit.startedCalls.first?.isVideo, false)
    }

    // MARK: - REQ-JINGLE-006: busy (2ª llamada entrante) → historial busy

    func testBusySecondIncomingCallRecordedAndActiveUntouched() async throws {
        let repo = makeRepo()
        await repo.setup()
        var iterator = repo.callStateStream.makeAsyncIterator()

        // Llamada A entrante (con huella ya conocida → suena directamente).
        try fingerprintStore.store(fpAna, for: "ana@z17.cu")
        await manager.handleJingleStanza(xml: initiateXML(sid: "call-a", fingerprint: fpAna))
        let first = await iterator.next()
        let ringing = try XCTUnwrap(first)
        XCTAssertEqual(ringing.state, .ringing)

        // Llamada B entrante: el manager responde busy y emite el evento sintético.
        await manager.handleJingleStanza(xml: initiateXML(sid: "call-b", fingerprint: fpAna, from: "bob@z17.cu/phonemac"))

        // El repo registra busy en historial para B sin tocar la llamada A.
        let busyEntry = try XCTUnwrap(historyStore.entry(sid: "call-b"))
        XCTAssertEqual(busyEntry.status, .busy)
        XCTAssertNil(historyStore.entry(sid: "call-a"), "A no debe registrarse (sigue viva en ringing)")
        let active = await repo.currentCall
        XCTAssertEqual(active?.state, .ringing, "La llamada A sigue viva")
        // Ninguna fila duplicada por sid B.
        XCTAssertEqual(historyStore.entries(for: "bob@z17.cu").filter { $0.sid == "call-b" }.count, 1)
    }

    // MARK: - REQ-JINGLE-005: ring timeout → unanswered (duración 0)

    func testRingTimeoutEndsUnansweredWithZeroDuration() async throws {
        let repo = makeRepo(ringTimeout: .milliseconds(200))
        await repo.setup()
        var iterator = repo.callStateStream.makeAsyncIterator()

        let call = try await repo.startCall(jid: "ana@z17.cu", isVideo: false)
        let first = await iterator.next()
        _ = try XCTUnwrap(first) // .ringing

        try? await Task.sleep(for: .milliseconds(600))

        let second = await iterator.next()
        let terminal = try XCTUnwrap(second)
        XCTAssertEqual(terminal.state, .missed)
        XCTAssertEqual(terminal.duration, 0, accuracy: 0.001)

        let entry = try XCTUnwrap(historyStore.entry(sid: call.id))
        XCTAssertEqual(entry.status, .unanswered)
        XCTAssertEqual(entry.duration, 0, accuracy: 0.001)
        XCTAssertTrue(transport.sent.contains { $0.contains("action='session-terminate'") && $0.contains("<timeout/>") })
    }

    // MARK: - decline → historial declined

    func testRemoteDeclineMapsToDeclinedHistory() async throws {
        let repo = makeRepo()
        await repo.setup()
        var iterator = repo.callStateStream.makeAsyncIterator()

        let call = try await repo.startCall(jid: "ana@z17.cu", isVideo: false)
        let first = await iterator.next()
        _ = try XCTUnwrap(first) // .ringing

        await manager.handleJingleStanza(xml: terminateXML(sid: call.id, reason: "decline"))

        let second = await iterator.next()
        let terminal = try XCTUnwrap(second)
        XCTAssertEqual(terminal.state, .ended)
        let entry = try XCTUnwrap(historyStore.entry(sid: call.id))
        XCTAssertEqual(entry.status, .declined)
        XCTAssertEqual(entry.duration, 0, accuracy: 0.001)
    }

    // MARK: - REQ-JINGLE-011: fingerprint gate ANTES de media

    func testTOFUFirstContactPausesUntilVerified() async throws {
        let repo = makeRepo()
        await repo.setup()
        var iterator = repo.callStateStream.makeAsyncIterator()

        // Primer contacto: sin huella almacenada → .needsVerification, SIN ring.
        await manager.handleJingleStanza(xml: initiateXML(sid: "call-tofu", fingerprint: fpAna))
        let first = await iterator.next()
        let pending = try XCTUnwrap(first)
        XCTAssertEqual(pending.state, .needsVerification)
        XCTAssertTrue(callKit.reportedIncoming.isEmpty, "No debe sonar hasta verificar (gate antes de media)")
        XCTAssertTrue(engine.remoteSDPs.isEmpty, "Nada de media antes del gate")

        // Aceptar la verificación persiste la huella y deja sonar la llamada.
        try await repo.acceptFingerprint()
        let second = await iterator.next()
        let ringing = try XCTUnwrap(second)
        XCTAssertEqual(ringing.state, .ringing)
        XCTAssertEqual(callKit.reportedIncoming.count, 1)
        XCTAssertEqual(callKit.reportedIncoming.first?.hasVideo, false)
        XCTAssertEqual(fingerprintStore.storedFingerprint(for: "ana@z17.cu"), fpAna)
        // La media solo arranca DESPUÉS del gate abierto (REQ-MEDIA-003/004).
        XCTAssertEqual(engine.remoteSDPs.count, 1, "La oferta entrante se aplica solo tras verificar la huella")
    }

    func testFingerprintMismatchHardBlocksWithoutMedia() async throws {
        let repo = makeRepo()
        await repo.setup()
        var iterator = repo.callStateStream.makeAsyncIterator()

        // Huella conocida F1; la llamada presenta F2 ≠ F1 → hard block.
        try fingerprintStore.store(fpAna, for: "ana@z17.cu")
        await manager.handleJingleStanza(xml: initiateXML(sid: "call-mismatch", fingerprint: fpAna2))

        let first = await iterator.next()
        let blocked = try XCTUnwrap(first)
        XCTAssertEqual(blocked.state, .failed)
        XCTAssertTrue(callKit.reportedIncoming.isEmpty, "Sin ring en mismatch")
        XCTAssertTrue(engine.remoteSDPs.isEmpty, "Sin media en mismatch")
        XCTAssertTrue(
            transport.sent.contains { $0.contains("action='session-terminate'") && $0.contains("<security-error/>") },
            "El mismatch debe terminar con security-error"
        )
    }

    func testIncomingWithoutFingerprintFailsClosed() async throws {
        let repo = makeRepo()
        await repo.setup()
        var iterator = repo.callStateStream.makeAsyncIterator()

        await manager.handleJingleStanza(xml: initiateXMLWithoutFingerprint(sid: "call-no-fp"))

        let first = await iterator.next()
        let blocked = try XCTUnwrap(first)
        XCTAssertEqual(blocked.state, .failed)
        XCTAssertTrue(callKit.reportedIncoming.isEmpty)
        XCTAssertTrue(transport.sent.contains { $0.contains("<security-error/>") }, "Sin huella → fail closed (security-error)")
    }

    // MARK: - REQ-MEDIA-003: transport-info entrante → engine (candidato real)

    func testIncomingTransportInfoFeedsRealCandidateToEngine() async throws {
        let repo = makeRepo()
        await repo.setup()
        var iterator = repo.callStateStream.makeAsyncIterator()

        try fingerprintStore.store(fpAna, for: "ana@z17.cu")
        await manager.handleJingleStanza(xml: initiateXML(sid: "call-ti", fingerprint: fpAna))
        let first = await iterator.next()
        _ = try XCTUnwrap(first) // .ringing

        await manager.handleJingleStanza(xml: transportInfoXML(sid: "call-ti"))

        // El candidato real (no 0.0.0.0:9) llegó al engine.
        let candidate = try XCTUnwrap(engine.addedCandidates.first)
        XCTAssertTrue(candidate.sdp.contains("192.0.2.55"))
        XCTAssertTrue(candidate.sdp.contains("45664"))
        XCTAssertFalse(candidate.sdp.contains("0.0.0.0"))
        // Y la oferta entrante real (no "") se aplicó al engine (REQ-MEDIA-003).
        XCTAssertEqual(engine.remoteSDPs.count, 1, "El SDP entrante se aplica antes de recibir candidatos")
    }

    // MARK: - bug 04: candidato local real → transport-info (nunca 0.0.0.0:9)

    func testOutgoingCandidateForwardsRealTransportInfo() async throws {
        let repo = makeRepo()
        await repo.setup()
        var iterator = repo.callStateStream.makeAsyncIterator()

        let call = try await repo.startCall(jid: "ana@z17.cu", isVideo: false)
        let ringing = await iterator.next()
        _ = try XCTUnwrap(ringing) // .ringing

        // El engine genera un candidato host REAL (ip/puerto concretos).
        engine.simulateLocalCandidate()
        let transportInfoEvent = await waitForTransportInfo()
        let transportInfo = try XCTUnwrap(
            transportInfoEvent,
            "El candidato local debe reenviarse como transport-info al remoto"
        )
        XCTAssertTrue(transportInfo.contains("action='transport-info'"))
        XCTAssertTrue(transportInfo.contains("ip='192.0.2.10'"), transportInfo)
        XCTAssertTrue(transportInfo.contains("port='45664'"), transportInfo)
        XCTAssertFalse(transportInfo.contains("0.0.0.0"), "Nunca un placeholder 0.0.0.0:9")
        XCTAssertTrue(transportInfo.contains("sid='\(call.id)'"))
    }

    /// Espera (con plazo) a que aparezca un transport-info saliente en el
    /// transporte grabado. El envío ocurre en el actor del repo vía el
    /// delegate del engine; no hay evento de stream que consumir, así que
    /// el poll con deadline es la espera determinista equivalente.
    private func waitForTransportInfo(timeout: TimeInterval = 3) async -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let item = transport.sent.first(where: { $0.contains("action='transport-info'") }) {
                return item
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return nil
    }

    // MARK: - REQ-MEDIA-007: reuse tras terminate con engine fresco

    func testReuseAfterTerminateNegotiatesFreshOffer() async throws {
        let repo = makeRepo()
        await repo.setup()
        var iterator = repo.callStateStream.makeAsyncIterator()

        // Llama 1 completa (outgoing → accept → connected → remote hangup).
        let call1 = try await repo.startCall(jid: "ana@z17.cu", isVideo: false)
        let ringing1 = await iterator.next()
        _ = try XCTUnwrap(ringing1) // .ringing
        await manager.handleJingleStanza(xml: acceptXML(sid: call1.id))
        let connecting1 = await iterator.next()
        _ = try XCTUnwrap(connecting1) // .connecting
        engine.simulateConnection()
        let connectedEvent = await iterator.next()
        let connected1 = try XCTUnwrap(connectedEvent)
        XCTAssertEqual(connected1.state, .connected)
        await manager.handleJingleStanza(xml: terminateXML(sid: call1.id, reason: "success"))
        let endedEvent = await iterator.next()
        let ended1 = try XCTUnwrap(endedEvent)
        XCTAssertEqual(ended1.state, .ended)
        // El teardown se completó antes del evento terminal (consumido arriba),
        // así el assert de abajo es determinista y no corre contra el actor.
        XCTAssertEqual(engine.disconnectCount, 1, "El engine se derriba al terminar la llamada 1")

        // Llama 2: el engine negocia fresco (nueva oferta), sin estado stale.
        let offersBefore = engine.offerCount
        let call2 = try await repo.startCall(jid: "bob@z17.cu", isVideo: false)
        XCTAssertEqual(engine.offerCount, offersBefore + 1, "La llamada 2 debe crear una oferta nueva")
        XCTAssertEqual(engine.disconnectCount, 1, "El teardown de la llamada 2 aún no ocurrió")
        XCTAssertNotEqual(call2.id, call1.id, "Cada llamada usa un sid nuevo")

        try await repo.endCall(call2)
        XCTAssertEqual(engine.disconnectCount, 2)
    }

    // MARK: - REQ-MEDIA-005: toggleVideo sin efectos (bug 09)

    func testToggleVideoHasNoSideEffects() async throws {
        let repo = makeRepo()
        await repo.setup()
        var iterator = repo.callStateStream.makeAsyncIterator()

        let call = try await repo.startCall(jid: "ana@z17.cu", isVideo: false)
        let first = await iterator.next()
        _ = try XCTUnwrap(first) // .ringing
        await manager.handleJingleStanza(xml: acceptXML(sid: call.id))
        engine.simulateConnection()
        let second = await iterator.next()
        _ = try XCTUnwrap(second) // .connected

        let remoteSDPsBefore = engine.remoteSDPs.count
        try await repo.toggleVideo()
        try await repo.switchCamera()

        XCTAssertEqual(engine.videoCaptureCount, 0, "Ninguna captura de video en fase 1")
        XCTAssertEqual(engine.remoteSDPs.count, remoteSDPsBefore, "Ninguna renegociación por toggle")
        let active = await repo.currentCall
        XCTAssertEqual(active?.state, .connected, "La llamada sigue activa y de audio")
    }
}