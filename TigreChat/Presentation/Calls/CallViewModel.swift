import Foundation
import Observation

@MainActor
@Observable
final class CallViewModel {
    private(set) var call: Call?
    private(set) var isMuted = false
    private(set) var isSpeakerOn = false
    private(set) var isVideoEnabled = false
    private(set) var duration: TimeInterval = 0
    nonisolated(unsafe) private var timer: Timer?

    let callRepository: CallRepository

    init(callRepository: CallRepository) {
        self.callRepository = callRepository
        observeCall()
    }

    private func observeCall() {
        Task { [weak self] in
            guard let self else { return }
            for await updatedCall in callRepository.callStateStream {
                call = updatedCall
                if updatedCall.state == .connected, updatedCall.startTime != nil {
                    startTimer()
                }
                if updatedCall.state == .ended || updatedCall.state == .failed || updatedCall.state == .missed {
                    stopTimer()
                }
            }
        }
    }

    func startCall(jid: String, isVideo: Bool) async {
        do {
            call = try await callRepository.startCall(jid: jid, isVideo: isVideo)
            isVideoEnabled = isVideo
        } catch {
            call = Call(jid: jid, direction: .outgoing)
            call?.state = .failed
        }
    }

    func acceptCall(_ call: Call) async {
        try? await callRepository.acceptCall(call)
    }

    func endCall() async {
        guard let call else { return }
        try? await callRepository.endCall(call)
    }

    func rejectCall() async {
        guard let call else { return }
        try? await callRepository.rejectCall(call)
    }

    func toggleMute() {
        isMuted.toggle()
        Task { try? await callRepository.muteCall(isMuted) }
    }

    func toggleSpeaker() {
        isSpeakerOn.toggle()
    }

    func toggleVideo() {
        isVideoEnabled.toggle()
        Task { try? await callRepository.toggleVideo() }
    }

    func switchCamera() {
        Task { try? await callRepository.switchCamera() }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let start = self.call?.startTime else { return }
                self.duration = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    deinit { timer?.invalidate() }

    var formattedDuration: String {
        let total = Int(duration)
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
