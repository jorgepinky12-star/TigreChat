import Foundation

struct LoadConversationsUseCase: Sendable {
    private let messageRepository: MessageRepository

    init(messageRepository: MessageRepository) {
        self.messageRepository = messageRepository
    }

    func execute() async throws -> [Conversation] {
        try await messageRepository.loadConversations()
    }
}

struct LoadMessagesUseCase: Sendable {
    private let messageRepository: MessageRepository

    init(messageRepository: MessageRepository) {
        self.messageRepository = messageRepository
    }

    func execute(conversationId: String, limit: Int = 50) async throws -> [Message] {
        try await messageRepository.loadMessages(conversationId: conversationId, before: nil, limit: limit)
    }
}

struct MarkAsReadUseCase: Sendable {
    private let messageRepository: MessageRepository

    init(messageRepository: MessageRepository) {
        self.messageRepository = messageRepository
    }

    func execute(conversationId: String) async throws {
        try await messageRepository.markAsRead(conversationId: conversationId)
    }
}
