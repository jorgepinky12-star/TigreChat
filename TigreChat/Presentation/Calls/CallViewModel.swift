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
    private var timerTask: Task<Void, Never>?

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
        timerTask?.cancel()
        // Task hereda el aislamiento @MainActor, así que `duration` se
        // actualiza en el actor sin sincronización adicional.
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let start = self.call?.startTime else { continue }
                self.duration = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
    }

    isolated deinit {
        timerTask?.cancel()
    }

    var formattedDuration: String {
        let total = Int(duration)
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
