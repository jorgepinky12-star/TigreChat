import Foundation

actor XMPPCallRepository: CallRepository {
    private let jingleManager: JingleManager
    private let webRTC: WebRTCEngineProtocol
    private let callKit: CallManager

    private(set) var currentCall: Call?
    private var callContinuation: AsyncStream<Call>.Continuation?
    nonisolated let callStateStream: AsyncStream<Call>

    init(jingleManager: JingleManager, webRTC: WebRTCEngineProtocol, callKit: CallManager) {
        self.jingleManager = jingleManager
        self.webRTC = webRTC
        self.callKit = callKit
        var cont: AsyncStream<Call>.Continuation?
        callStateStream = AsyncStream { continuation in cont = continuation }
        callContinuation = cont
    }

    func setup() async {
        await MainActor.run {
            webRTC.delegate = self

            callKit.onAnswer = { [weak self] uuid in
                Task { [weak self] in await self?.handleAccept() }
            }

            callKit.onEnd = { [weak self] uuid in
                Task { [weak self] in await self?.handleEnd() }
            }

            callKit.onMute = { [weak self] uuid, muted in
                Task { [weak self] in await self?.webRTC.muteAudio(muted) }
            }

            callKit.onStartCall = { [weak self] uuid, jid in
                Task { [weak self] in await self?.handleOutgoingCallStarted(jid: jid) }
            }
        }

        await listenForIncomingJingle()
    }

    private func listenForIncomingJingle() async {
        for await (sid, initiator, sdp) in jingleManager.incomingCallStream {
            let call = Call(jid: initiator, direction: .incoming, isVideo: sdp.contains("video"))
            currentCall = call
            await MainActor.run {
                callKit.onAnswer = { [weak self] _ in
                    Task { [weak self] in await self?.handleAccept() }
                }
            }
            try? await callKit.reportIncomingCall(uuid: UUID(), jid: initiator, hasVideo: call.isVideo)
            callContinuation?.yield(call)
        }
    }

    func startCall(jid: String, isVideo: Bool) async throws -> Call {
        let call = Call(jid: jid, direction: .outgoing, isVideo: isVideo)
        currentCall = call
        let uuid = UUID()

        try await jingleManager.sendSessionInitiate(to: jid, sid: call.id, sdp: "", isVideo: isVideo)

        await MainActor.run {
            callKit.startCall(uuid: uuid, jid: jid, isVideo: isVideo)
            callKit.reportOutgoingCallConnecting(uuid: uuid)
            callKit.onAnswer = nil
            callKit.onEnd = { [weak self] _ in
                Task { [weak self] in await self?.handleEnd() }
            }
            callKit.onMute = { [weak self] _, muted in
                Task { [weak self] in await self?.webRTC.muteAudio(muted) }
            }
        }

        var updatedCall = call
        updatedCall.state = .ringing
        currentCall = updatedCall
        callContinuation?.yield(updatedCall)
        return updatedCall
    }

    func acceptCall(_ call: Call) async throws {
        var updated = call
        updated.state = .connecting
        currentCall = updated

        let sdp = try await webRTC.createAnswer(for: SessionDescription(sdp: "", type: .offer))
        try await jingleManager.sendSessionAccept(to: call.jid, sid: call.id, sdp: sdp.sdp)
        await MainActor.run { callKit.reportOutgoingCallConnected(uuid: UUID()) }

        updated.state = .connected
        updated.startTime = Date()
        currentCall = updated
        callContinuation?.yield(updated)
    }

    func endCall(_ call: Call) async throws {
        guard currentCall?.id == call.id else { return }
        try await jingleManager.sendSessionTerminate(to: call.jid, sid: call.id)
        await MainActor.run { webRTC.disconnect() }
        await MainActor.run { callKit.endCall() }

        var updated = call
        updated.state = .ended
        if let start = updated.startTime {
            updated.duration = Date().timeIntervalSince(start)
        }
        currentCall = nil
        callContinuation?.yield(updated)
        callContinuation?.finish()
    }

    func rejectCall(_ call: Call) async throws {
        try await jingleManager.sendSessionTerminate(to: call.jid, sid: call.id, reason: "decline")
        var updated = call
        updated.state = .missed
        currentCall = nil
        callContinuation?.yield(updated)
    }

    func muteCall(_ muted: Bool) async throws {
        await MainActor.run { webRTC.muteAudio(muted) }
    }

    func toggleVideo() async throws {}
    func switchCamera() async throws {
        await MainActor.run { webRTC.switchCamera() }
    }

    private func handleAccept() async {
        guard let call = currentCall else { return }
        try? await acceptCall(call)
    }

    private func handleEnd() async {
        guard let call = currentCall else { return }
        try? await endCall(call)
    }

    private func handleOutgoingCallStarted(jid: String) async {
        let call = Call(jid: jid, direction: .outgoing)
        currentCall = call
        try? await jingleManager.sendSessionInitiate(to: jid, sid: call.id, sdp: "", isVideo: false)
    }
}

extension XMPPCallRepository: WebRTCEngineDelegate {
    nonisolated func didGenerateLocalOffer(_ sdp: SessionDescription) {}
    nonisolated func didGenerateLocalAnswer(_ sdp: SessionDescription) {}
    nonisolated func didReceiveICECandidate(_ candidate: ICECandidate) {}
    nonisolated func didConnectCall() {
        Task { await handleCallConnected() }
    }
    nonisolated func didDisconnectCall() {
        Task { await handleCallDisconnected() }
    }
    nonisolated func didFailWithError(_ error: Error) {
        Task { await handleCallFailed(error) }
    }

    private func handleCallConnected() {
        guard var call = currentCall else { return }
        call.state = .connected
        call.startTime = Date()
        currentCall = call
        callContinuation?.yield(call)
    }

    private func handleCallDisconnected() {
        guard var call = currentCall else { return }
        call.state = .ended
        currentCall = nil
        callContinuation?.yield(call)
    }

    private func handleCallFailed(_ error: Error) {
        guard var call = currentCall else { return }
        call.state = .failed
        currentCall = nil
        callContinuation?.yield(call)
    }
}
