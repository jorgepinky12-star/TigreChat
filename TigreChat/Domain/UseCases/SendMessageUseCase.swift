import Foundation

struct SendMessageUseCase: Sendable {
    private let messageRepository: MessageRepository

    init(messageRepository: MessageRepository) {
        self.messageRepository = messageRepository
    }

    func execute(text: String, to jid: String) async throws -> Message {
        let message = Message(
            conversationId: jid,
            senderJID: "",
            text: text,
            isOutgoing: true,
            status: .sending
        )
        try await messageRepository.send(message: message)
        return message
    }
}
