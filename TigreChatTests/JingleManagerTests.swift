//
//  JingleManagerTests.swift
//  TigreChatTests
//
//  T-014 RED: despacho por action, timeout de timbre (30s), busy en 2ª
//  llamada, initiator local correcto, transport-info con candidato real
//  y limpieza de sesión tras terminate. REQ-JINGLE-001: malformed ignorado.
//

import XCTest
@testable import TigreChat

/// Transport de grabación: captura todo lo enviado, sin red.
private final class RecordingTransport: JingleTransport, @unchecked Sendable {
    private let queue = DispatchQueue(label: "test.transport")
    private var items: [String] = []

    var sent: [String] {
        queue.sync { items }
    }

    func send(string: String) async throws {
        queue.sync { items.append(string) }
    }
}

private let incomingInitiateAudio = """
<iq to='jorge@z17.cu/phone' id='in1' type='set'>
  <jingle xmlns='urn:xmpp:jingle:1' action='session-initiate' initiator='ana@z17.cu/phonemac' sid='call-999'>
    <content creator='initiator' name='audio'>
      <description xmlns='urn:xmpp:jingle:apps:rtp:1' media='audio'>
        <payload-type id='96' name='opus' clockrate='48000'/>
      </description>
      <security xmlns='urn:xmpp:jingle:apps:dtls:0'>
        <fingerprint hash='sha-256'>A5:8B:0C:0B:39:E7:9F:B5:04:5A:2B:BC:D6:43:0E:EF:88:E8:09:DB:75:90:A3:63:63:EF:A5:9F:A9:06:7C:44</fingerprint>
        <setup>actpass</setup>
      </security>
    </content>
  </jingle>
</iq>
"""

@MainActor
final class JingleManagerTests: XCTestCase {

    /// Crea un manager con transport de grabación y timeout corto para
    /// que los tests del timbre no esperen 30s reales.
    private func makeManager(
        transport: RecordingTransport,
        ringTimeout: Duration = .seconds(30)
    ) -> JingleManager {
        JingleManager(
            connection: transport,
            ringTimeout: ringTimeout
        )
    }

    /// Consume el stream según se van produciendo eventos.
    private func collector(_ stream: AsyncStream<(sid: String, initiator: String, stanza: JingleStanza)>)
        -> AsyncStream<(sid: String, initiator: String, stanza: JingleStanza)> {
        stream
    }

    // MARK: - session-initiate entrante

    func testDispatchSessionInitiateEmitsIncomingCall() async throws {
        let transport = RecordingTransport()
        let manager = makeManager(transport: transport)
        var iterator = manager.incomingCallStream.makeAsyncIterator()

        await manager.handleJingleStanza(xml: incomingInitiateAudio)

        let maybeEvent = await iterator.next()
        let event = try XCTUnwrap(maybeEvent)
        XCTAssertEqual(event.sid, "call-999")
        XCTAssertEqual(event.initiator, "ana@z17.cu/phonemac")
        XCTAssertEqual(event.stanza.action, .sessionInitiate)
        XCTAssertEqual(event.stanza.contents.first?.payloadTypes.first?.name, "opus")
        // No se envió nada al recibir una llamada (solo al contestarla).
        XCTAssertTrue(transport.sent.isEmpty)
    }

    // MARK: - session-accept cancela el timeout de timbre

    func testSessionAcceptCancelsRingTimeout() async throws {
        let transport = RecordingTransport()
        let manager = makeManager(transport: transport, ringTimeout: .milliseconds(400))
        var iterator = manager.incomingCallStream.makeAsyncIterator()

        await manager.handleJingleStanza(xml: incomingInitiateAudio)
        _ = await iterator.next() // el initiate

        let accept = """
        <iq to='ana@z17.cu/phonemac' id='in2' type='set'>
          <jingle xmlns='urn:xmpp:jingle:1' action='session-accept' initiator='jorge@z17.cu/phone' sid='call-999'>
            <content creator='responder' name='audio'>
              <description xmlns='urn:xmpp:jingle:apps:rtp:1' media='audio'>
                <payload-type id='96' name='opus' clockrate='48000'/>
              </description>
              <security xmlns='urn:xmpp:jingle:apps:dtls:0'>
                <fingerprint hash='sha-256'>B8:9C:0C:0B:39:E7:9F:B5:04:5A:2B:BC:D6:43:0E:EF:88:E8:09:DB:75:90:A3:63:63:EF:A5:9F:A9:06:7C:44</fingerprint>
                <setup>active</setup>
              </security>
            </content>
          </jingle>
        </iq>
        """
        await manager.handleJingleStanza(xml: accept)
        _ = await iterator.next() // el accept

        // Si el timer hubiera quedado vivo, a los 400ms habría enviado
        // terminate(timeout). Esperamos más que eso y verificamos que no.
        try? await Task.sleep(for: .milliseconds(700))
        XCTAssertFalse(transport.sent.contains { $0.contains("action='session-terminate'") })
    }

    // MARK: - timeout de timbre (30s nominal, corto en test)

    func testRingTimeoutSendsTerminateAndEmitsUnanswered() async throws {
        let transport = RecordingTransport()
        let manager = makeManager(transport: transport, ringTimeout: .milliseconds(300))
        var iterator = manager.incomingCallStream.makeAsyncIterator()

        try await manager.sendSessionInitiate(
            localJID: "jorge@z17.cu/phone",
            to: "ana@z17.cu/phonemac",
            sid: "call-500",
            sdp: Self.offerSDP,
            fingerprint: "A5:8B:0C:0B:39:E7:9F:B5:04:5A:2B:BC:D6:43:0E:EF:88:E8:09:DB:75:90:A3:63:63:EF:A5:9F:A9:06:7C:44",
            isVideo: false
        )

        try? await Task.sleep(for: .milliseconds(800))

        XCTAssertTrue(transport.sent.contains { $0.contains("action='session-terminate'") && $0.contains("<timeout/>") })

        let maybeEvent = await iterator.next()
        let event = try XCTUnwrap(maybeEvent)
        XCTAssertEqual(event.stanza.action, .sessionTerminate)
        XCTAssertEqual(event.stanza.terminateReason, "timeout")
        XCTAssertEqual(event.sid, "call-500")
    }

    // MARK: - busy: rechazo de 2ª llamada entrante

    func testBusyRejectsSecondIncomingCall() async throws {
        let transport = RecordingTransport()
        let manager = makeManager(transport: transport)
        var iterator = manager.incomingCallStream.makeAsyncIterator()

        await manager.handleJingleStanza(xml: incomingInitiateAudio)
        _ = await iterator.next() // llamada A: entra

        let second = incomingInitiateAudio.replacingOccurrences(of: "call-999", with: "call-998")
        await manager.handleJingleStanza(xml: second)

        let maybeBusy = await iterator.next()
        let busyEvent = try XCTUnwrap(maybeBusy)
        XCTAssertEqual(busyEvent.sid, "call-998")
        XCTAssertEqual(busyEvent.stanza.action, .sessionTerminate)
        XCTAssertEqual(busyEvent.stanza.terminateReason, "busy")
        XCTAssertTrue(transport.sent.contains {
            $0.contains("action='session-terminate'") && $0.contains("sid='call-998'") && $0.contains("<busy/>")
        })
        // La llamada A sigue viva (su sesión no se tocó).
        XCTAssertFalse(transport.sent.contains { $0.contains("sid='call-999'") })
    }

    // MARK: - session-initiate saliente: initiator local, payload y fingerprint

    func testSessionInitiateXMLCarriesLocalInitiatorAndPayload() async throws {
        let transport = RecordingTransport()
        let manager = makeManager(transport: transport)

        try await manager.sendSessionInitiate(
            localJID: "jorge@z17.cu/phone",
            to: "ana@z17.cu/phonemac",
            sid: "call-777",
            sdp: Self.offerSDP,
            fingerprint: "A5:8B:0C:0B:39:E7:9F:B5:04:5A:2B:BC:D6:43:0E:EF:88:E8:09:DB:75:90:A3:63:63:EF:A5:9F:A9:06:7C:44",
            isVideo: false
        )

        let xml = try XCTUnwrap(transport.sent.first)
        XCTAssertTrue(xml.contains("action='session-initiate'"))
        XCTAssertTrue(xml.contains("initiator='jorge@z17.cu/phone'"))
        XCTAssertTrue(xml.contains("to='ana@z17.cu/phonemac'"))
        XCTAssertTrue(xml.contains("sid='call-777'"))
        XCTAssertTrue(xml.contains("<payload-type id='96' name='opus' clockrate='48000'/>"))
        XCTAssertTrue(xml.contains("fingerprint hash='sha-256'"))
        XCTAssertTrue(xml.contains("A58B0C0B39E79FB5"))
        // Fase 1: nunca un candidate placeholder 0.0.0.0:9 en la oferta.
        XCTAssertFalse(xml.contains("0.0.0.0:9"))
    }

    // MARK: - transport-info con candidato real

    func testTransportInfoCarriesRealCandidate() async throws {
        let transport = RecordingTransport()
        let manager = makeManager(transport: transport)

        let candidate = JingleCandidate(
            component: 1,
            foundation: "3",
            generation: 0,
            id: "x8v7w6u5",
            ip: "192.0.2.3",
            network: 1,
            port: 45664,
            priority: 1694498815,
            protocol: "udp",
            type: "srflx"
        )
        try await manager.sendTransportInfo(
            to: "ana@z17.cu/phonemac",
            sid: "call-777",
            candidate: candidate,
            creator: "initiator",
            name: "audio"
        )

        let xml = try XCTUnwrap(transport.sent.first)
        XCTAssertTrue(xml.contains("action='transport-info'"))
        XCTAssertTrue(xml.contains("ip='192.0.2.3'"))
        XCTAssertTrue(xml.contains("port='45664'"))
        XCTAssertTrue(xml.contains("type='srflx'"))
        XCTAssertFalse(xml.contains("0.0.0.0:9"))
    }

    // MARK: - terminate limpia la sesión (permite reusar el sid)

    func testTerminateCleansUpSessionAllowingSidReuse() async throws {
        let transport = RecordingTransport()
        let manager = makeManager(transport: transport)
        var iterator = manager.incomingCallStream.makeAsyncIterator()

        await manager.handleJingleStanza(xml: incomingInitiateAudio)
        _ = await iterator.next()

        let terminate = """
        <iq to='ana@z17.cu/phonemac' id='in3' type='set'>
          <jingle xmlns='urn:xmpp:jingle:1' action='session-terminate' initiator='jorge@z17.cu/phone' sid='call-999'>
            <reason><success/></reason>
          </jingle>
        </iq>
        """
        await manager.handleJingleStanza(xml: terminate)
        _ = await iterator.next()

        // Tras el terminate, el sid queda libre: una nueva llamada con el
        // mismo sid no debe ser rechazada como busy.
        await manager.handleJingleStanza(xml: incomingInitiateAudio)
        let maybeEvent = await iterator.next()
        let event = try XCTUnwrap(maybeEvent)
        XCTAssertEqual(event.stanza.action, .sessionInitiate)
    }

    // MARK: - malformed se ignora sin efectos (REQ-JINGLE-001)

    func testMalformedStanzaIgnoredWithoutSideEffects() async throws {
        let transport = RecordingTransport()
        let manager = makeManager(transport: transport)
        var iterator = manager.incomingCallStream.makeAsyncIterator()

        await manager.handleJingleStanza(xml: "esto no es xml")
        await manager.handleJingleStanza(xml: "<iq><message/></iq>")
        await manager.handleJingleStanza(xml: """
        <iq to='x' id='y' type='set'>
          <jingle xmlns='urn:xmpp:jingle:1' action='dance' sid='s'/>
        </iq>
        """)

        XCTAssertTrue(transport.sent.isEmpty)
        // Sin eventos emitidos: el stream queda vacío (no se puede hacer
        // next() porque nunca finaliza; la ausencia de sends + no-crash
        // es la señal de REQ-JINGLE-001).
        _ = iterator
    }

    // MARK: - sendSessionAccept / sendSessionTerminate

    func testSendSessionAcceptEmitsActionAndAnswerSDP() async throws {
        let transport = RecordingTransport()
        let manager = makeManager(transport: transport)

        // Contexto real de una llamada: primero el initiate (crea la sesión).
        try await manager.sendSessionInitiate(
            localJID: "jorge@z17.cu/phone",
            to: "ana@z17.cu/phonemac",
            sid: "call-777",
            sdp: Self.offerSDP,
            fingerprint: "A58B0C0B39E79FB5045A2BBCD6430EEF88E809DB7590A36363EFA59FA9067C44",
            isVideo: false
        )
        try await manager.sendSessionAccept(
            localJID: "jorge@z17.cu/phone",
            to: "ana@z17.cu/phonemac",
            sid: "call-777",
            sdp: Self.answerSDP,
            fingerprint: "B89C0C0B39E79FB5"
        )

        let xml = try XCTUnwrap(transport.sent.last)
        XCTAssertTrue(xml.contains("action='session-accept'"))
        XCTAssertTrue(xml.contains("sid='call-777'"))
        XCTAssertTrue(xml.contains("<payload-type id='0' name='PCMU' clockrate='8000'/>"))
        XCTAssertFalse(xml.contains("0.0.0.0:9"))
    }

    func testSendSessionTerminateSerializesReason() async throws {
        let transport = RecordingTransport()
        let manager = makeManager(transport: transport)

        try await manager.sendSessionTerminate(to: "ana@z17.cu/phonemac", sid: "call-777", reason: "decline")

        let xml = try XCTUnwrap(transport.sent.first)
        XCTAssertTrue(xml.contains("action='session-terminate'"))
        XCTAssertTrue(xml.contains("<decline/>"))
    }

    // MARK: - SDP de oferta/respuesta para los tests

    private static let offerSDP = """
    v=0
    o=- 2890844526 2890844526 IN IP4 127.0.0.1
    s=-
    t=0 0
    m=audio 9 UDP/TLS/RTP/SAVPF 96
    c=IN IP4 0.0.0.0
    a=rtpmap:96 opus/48000
    a=fingerprint:sha-256 A5:8B:0C:0B:39:E7:9F:B5:04:5A:2B:BC:D6:43:0E:EF:88:E8:09:DB:75:90:A3:63:63:EF:A5:9F:A9:06:7C:44
    a=setup:actpass
    """

    private static let answerSDP = """
    v=0
    o=- 2890844527 2890844527 IN IP4 127.0.0.1
    s=-
    t=0 0
    m=audio 9 UDP/TLS/RTP/SAVPF 0
    c=IN IP4 0.0.0.0
    a=rtpmap:0 PCMU/8000
    a=fingerprint:sha-256 B8:9C:0C:0B:39:E7:9F:B5:04:5A:2B:BC:D6:43:0E:EF:88:E8:09:DB:75:90:A3:63:63:EF:A5:9F:A9:06:7C:44
    a=setup:active
    """
}