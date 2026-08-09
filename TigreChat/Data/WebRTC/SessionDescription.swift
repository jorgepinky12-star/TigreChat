import Foundation

struct SessionDescription: Sendable {
    let sdp: String
    let type: SDPType

    init(sdp: String, type: SDPType) {
        self.sdp = sdp
        self.type = type
    }
}

enum SDPType: String, Sendable {
    case offer
    case answer
    case pranswer
    case rollback

    var jingleAction: JingleAction? {
        switch self {
        case .offer: return .sessionInitiate
        case .answer: return .sessionAccept
        default: return nil
        }
    }
}

struct ICECandidate: Sendable {
    let sdp: String
    let sdpMLineIndex: Int32
    let sdpMid: String

    init(sdp: String, sdpMLineIndex: Int32, sdpMid: String) {
        self.sdp = sdp
        self.sdpMLineIndex = sdpMLineIndex
        self.sdpMid = sdpMid
    }
}

protocol WebRTCEngineDelegate: AnyObject, Sendable {
    func didGenerateLocalOffer(_ sdp: SessionDescription)
    func didGenerateLocalAnswer(_ sdp: SessionDescription)
    func didReceiveICECandidate(_ candidate: ICECandidate)
    func didConnectCall()
    func didDisconnectCall()
    func didFailWithError(_ error: Error)
}

@MainActor
protocol WebRTCEngineProtocol: AnyObject, Sendable {
    var delegate: WebRTCEngineDelegate? { get set }

    func createOffer() async throws -> SessionDescription
    func createAnswer(for remoteSDP: SessionDescription) async throws -> SessionDescription
    func setRemoteDescription(_ sdp: SessionDescription) async throws
    func addICECandidate(_ candidate: ICECandidate) async throws
    func startCaptureLocalVideo() async
    func stopCapture() async
    func muteAudio(_ muted: Bool)
    func muteVideo(_ muted: Bool)
    func switchCamera()
    func disconnect()
}
