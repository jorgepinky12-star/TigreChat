import Foundation

enum CallError: Error, Sendable {
    case initiationFailed(String)
    case notConnected
    case busy
    case timeout
    case unsupported
}

protocol CallRepository: Sendable {
    var callStateStream: AsyncStream<Call> { get }

    func startCall(jid: String, isVideo: Bool) async throws -> Call
    func acceptCall(_ call: Call) async throws
    func endCall(_ call: Call) async throws
    func rejectCall(_ call: Call) async throws
    func muteCall(_ muted: Bool) async throws
    func toggleVideo() async throws
    func switchCamera() async throws
}
