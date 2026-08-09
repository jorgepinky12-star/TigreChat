import Foundation

enum MessageError: Error, Sendable {
    case sendFailed(String)
    case notConnected
    case messageNotFound
}

@MainActor
protocol MessageRepository: Sendable {
    func send(message: Message) async throws
    func loadMessages(conversationId: String, before: Date?, limit: Int) async throws -> [Message]
    func loadConversations() async throws -> [Conversation]
    func markAsRead(conversationId: String) async throws
}
