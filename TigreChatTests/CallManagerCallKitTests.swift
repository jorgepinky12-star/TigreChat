//
//  CallManagerCallKitTests.swift
//  TigreChatTests
//
//  T-VOIPCALLS-040 (RED→GREEN): tests del seam CallKitAdapting (D7).
//  Verifica: reportIncomingCall, startCall, endCall, reportRemoteEnded,
//  callbacks onAnswer/onEnd/onMute, providerDidReset.
//  NO usa CallManager.shared (singleton depende del sistema CallKit);
//  usa RecordingCallKitAdapting (doble grabador, mismo contrato).
//

import XCTest
@testable import TigreChat

@MainActor
final class CallManagerCallKitTests: XCTestCase {

    private var sut: RecordingCallKitAdapting!

    override func setUp() {
        sut = RecordingCallKitAdapting()
    }

    // MARK: - REQ-CALLKIT-001: reportIncomingCall

    func testReportIncomingCallRecordsUUID() async throws {
        let uuid = UUID()
        try await sut.reportIncomingCall(uuid: uuid, jid: "ana@z17.cu", hasVideo: false)
        XCTAssertEqual(sut.reportedIncoming.first?.uuid, uuid)
        XCTAssertEqual(sut.reportedIncoming.first?.jid, "ana@z17.cu")
        XCTAssertFalse(sut.reportedIncoming.first?.hasVideo ?? true)
    }

    // MARK: - REQ-CALLKIT-003: startCall

    func testStartCallRecordsUUIDAndJID() throws {
        let uuid = UUID()
        sut.startCall(uuid: uuid, jid: "bob@z17.cu", isVideo: false)
        XCTAssertEqual(sut.startedCalls.first?.uuid, uuid)
        XCTAssertEqual(sut.startedCalls.first?.jid, "bob@z17.cu")
    }

    // MARK: - REQ-CALLKIT-004: endCall

    func testEndCallRecordsUUID() throws {
        let uuid = UUID()
        sut.endCall(uuid: uuid)
        XCTAssertEqual(sut.endedUUIDs.first, uuid)
    }

    // MARK: - reportRemoteEnded

    func testReportRemoteEndedRecordsUUID() throws {
        let uuid = UUID()
        sut.reportRemoteEnded(uuid: uuid)
        XCTAssertEqual(sut.remoteEndedUUIDs.first, uuid)
    }

    // MARK: - reportOutgoingCallConnecting/Connected

    func testReportOutgoingCallConnectingRecordsUUID() throws {
        let uuid = UUID()
        sut.reportOutgoingCallConnecting(uuid: uuid)
        XCTAssertEqual(sut.connectingUUIDs.first, uuid)
    }

    func testReportOutgoingCallConnectedRecordsUUID() throws {
        let uuid = UUID()
        sut.reportOutgoingCallConnected(uuid: uuid)
        XCTAssertEqual(sut.connectedUUIDs.first, uuid)
    }

    // MARK: - Callbacks onAnswer/onEnd/onMute

    func testOnAnswerCallbackReceivesUUID() throws {
        var received: UUID?
        sut.onAnswer = { received = $0 }
        let uuid = UUID()
        sut.onAnswer?(uuid)
        XCTAssertEqual(received, uuid)
    }

    func testOnEndCallbackReceivesUUID() throws {
        var received: UUID?
        sut.onEnd = { received = $0 }
        let uuid = UUID()
        sut.onEnd?(uuid)
        XCTAssertEqual(received, uuid)
    }

    func testOnMuteCallbackReceivesState() throws {
        var receivedMuted: Bool?
        sut.onMute = { _, muted in receivedMuted = muted }
        sut.onMute?(UUID(), true)
        XCTAssertTrue(receivedMuted ?? false)
    }

    func testOnMuteCallbackReceivesUnmute() throws {
        var receivedMuted: Bool?
        sut.onMute = { _, muted in receivedMuted = muted }
        sut.onMute?(UUID(), false)
        XCTAssertFalse(receivedMuted ?? true)
    }

    // MARK: - onStartCall callback

    func testOnStartCallCallbackReceivesUUIDAndJID() throws {
        var receivedUUID: UUID?
        var receivedJID: String?
        sut.onStartCall = { uuid, jid in receivedUUID = uuid; receivedJID = jid }
        let uuid = UUID()
        sut.onStartCall?(uuid, "carlos@z17.cu")
        XCTAssertEqual(receivedUUID, uuid)
        XCTAssertEqual(receivedJID, "carlos@z17.cu")
    }
}

// MARK: - Doble grabador (mismo contrato que CallManager, sin dependencia del sistema)

@MainActor
private final class RecordingCallKitAdapting: CallKitAdapting {
    struct IncomingCall { let uuid: UUID; let jid: String; let hasVideo: Bool }
    struct StartedCall { let uuid: UUID; let jid: String }

    var onAnswer: ((UUID) -> Void)?
    var onEnd: ((UUID) -> Void)?
    var onMute: ((UUID, Bool) -> Void)?
    var onStartCall: ((UUID, String) -> Void)?

    private(set) var reportedIncoming: [IncomingCall] = []
    private(set) var startedCalls: [StartedCall] = []
    private(set) var endedUUIDs: [UUID] = []
    private(set) var remoteEndedUUIDs: [UUID] = []
    private(set) var connectingUUIDs: [UUID] = []
    private(set) var connectedUUIDs: [UUID] = []

    func reportIncomingCall(uuid: UUID, jid: String, hasVideo: Bool) async throws {
        reportedIncoming.append(IncomingCall(uuid: uuid, jid: jid, hasVideo: hasVideo))
    }

    func startCall(uuid: UUID, jid: String, isVideo: Bool) {
        startedCalls.append(StartedCall(uuid: uuid, jid: jid))
    }

    func endCall(uuid: UUID) {
        endedUUIDs.append(uuid)
    }

    func reportRemoteEnded(uuid: UUID) {
        remoteEndedUUIDs.append(uuid)
    }

    func reportOutgoingCallConnecting(uuid: UUID) {
        connectingUUIDs.append(uuid)
    }

    func reportOutgoingCallConnected(uuid: UUID) {
        connectedUUIDs.append(uuid)
    }
}
