import Foundation

@MainActor
final class MockWebRTCEngine: WebRTCEngineProtocol {
    weak var delegate: WebRTCEngineDelegate?
    private var isConnected = false

    func createOffer() async throws -> SessionDescription {
        try await Task.sleep(nanoseconds: 500_000_000)
        return SessionDescription(sdp: mockSDP, type: .offer)
    }

    func createAnswer(for remoteSDP: SessionDescription) async throws -> SessionDescription {
        try await Task.sleep(nanoseconds: 500_000_000)
        return SessionDescription(sdp: mockSDP, type: .answer)
    }

    func setRemoteDescription(_ sdp: SessionDescription) async throws {
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    func addICECandidate(_ candidate: ICECandidate) async throws {
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    func startCaptureLocalVideo() async {}
    func stopCapture() async {}
    func muteAudio(_ muted: Bool) {}
    func muteVideo(_ muted: Bool) {}
    func switchCamera() {}

    func disconnect() {
        isConnected = false
        delegate?.didDisconnectCall()
    }

    func simulateIncomingCall() {
        Task { [weak self] in
            guard let self else { return }
            self.delegate?.didGenerateLocalOffer(SessionDescription(sdp: self.mockSDP, type: .offer))
        }
    }

    func simulateConnection() {
        isConnected = true
        delegate?.didConnectCall()
    }

    private let mockSDP = """
    v=0
    o=- 0 0 IN IP4 127.0.0.1
    s=-
    t=0 0
    m=audio 9 UDP/TLS/RTP/SAVPF 111
    c=IN IP4 0.0.0.0
    a=rtpmap:111 opus/48000/2
    """
}
