import Foundation

struct StartCallUseCase: Sendable {
    private let callRepository: CallRepository

    init(callRepository: CallRepository) { self.callRepository = callRepository }

    func execute(jid: String, isVideo: Bool) async throws -> Call {
        try await callRepository.startCall(jid: jid, isVideo: isVideo)
    }
}

struct AcceptCallUseCase: Sendable {
    private let callRepository: CallRepository

    init(callRepository: CallRepository) { self.callRepository = callRepository }

    func execute(_ call: Call) async throws {
        try await callRepository.acceptCall(call)
    }
}

struct EndCallUseCase: Sendable {
    private let callRepository: CallRepository

    init(callRepository: CallRepository) { self.callRepository = callRepository }

    func execute(_ call: Call) async throws {
        try await callRepository.endCall(call)
    }
}
