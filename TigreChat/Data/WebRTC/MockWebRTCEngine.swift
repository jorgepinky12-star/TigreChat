import Foundation

@MainActor
final class MockWebRTCEngine: WebRTCEngineProtocol {
    weak var delegate: WebRTCEngineDelegate?
    private var isConnected = false

    // MARK: - Grabaciones para los tests de orquestación (M2)

    private(set) var offerCount = 0
    private(set) var disconnectCount = 0
    private(set) var videoCaptureCount = 0
    private(set) var addedCandidates: [ICECandidate] = []
    private(set) var remoteSDPs: [String] = []

    /// Huella DTLS simulada (hex canónico, 64 dígitos).
    let testFingerprint = "9A8B7C6D5E4F3A2B1C0D9E8F7A6B5C4D3E2F1A0B9C8D7E6F5A4B3C2D1E0F"

    func localDTLSFingerprint() async -> String? {
        testFingerprint
    }

    func createOffer() async throws -> SessionDescription {
        offerCount += 1
        try await Task.sleep(nanoseconds: 500_000_000)
        return SessionDescription(sdp: mockSDP, type: .offer)
    }

    func createAnswer(for remoteSDP: SessionDescription) async throws -> SessionDescription {
        try await Task.sleep(nanoseconds: 500_000_000)
        return SessionDescription(sdp: mockSDP, type: .answer)
    }

    func setRemoteDescription(_ sdp: SessionDescription) async throws {
        remoteSDPs.append(sdp.sdp)
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    func addICECandidate(_ candidate: ICECandidate) async throws {
        addedCandidates.append(candidate)
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    func startCaptureLocalVideo() async {
        videoCaptureCount += 1
    }

    func stopCapture() async {}
    func muteAudio(_ muted: Bool) {}
    func muteVideo(_ muted: Bool) {}
    func switchCamera() {}

    func disconnect() {
        disconnectCount += 1
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

    /// Emite un candidato ICE local REAL (ip/puerto concretos) por el
    /// delegate — el repo debe reenviarlo como transport-info (bug 04),
    /// nunca un placeholder 0.0.0.0:9.
    func simulateLocalCandidate() {
        Task { [weak self] in
            guard let self else { return }
            let sdp = "candidate:1234567890 1 udp 1694498815 192.0.2.10 45664 typ host"
            self.delegate?.didReceiveICECandidate(
                ICECandidate(sdp: sdp, sdpMLineIndex: 0, sdpMid: "audio")
            )
        }
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