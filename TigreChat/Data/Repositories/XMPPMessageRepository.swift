import Foundation
import SwiftData

/// MainActor-confined: ModelContext is not Sendable, so Apple's documented
/// pattern is to confine it to the main actor for UI-bound persistence.
@MainActor
final class XMPPMessageRepository: MessageRepository {
    private let client: XMPPClient
    private let modelContext: ModelContext
    private let messageContinuation: AsyncStream<Message>.Continuation
    let messageStream: AsyncStream<Message>

    init(client: XMPPClient, modelContainer: ModelContainer) {
        self.client = client
        self.modelContext = ModelContext(modelContainer)
        var cont: AsyncStream<Message>.Continuation!
        let stream = AsyncStream<Message> { continuation in
            cont = continuation
        }
        messageContinuation = cont
        messageStream = stream
        startListening()
        startStatusListening()
    }

    private func startStatusListening() {
        Task { [weak self] in
            guard let self else { return }
            // WU4: receipts (XEP-0184) y markers (XEP-0333) actualizan estados.
            for await update in await client.statusUpdateStream {
                await applyStatusUpdate(update.id, update.status)
            }
        }
    }

    private func applyStatusUpdate(_ id: String, _ status: MessageStatus) async {
        let fetch = FetchDescriptor<MessageEntity>(
            predicate: #Predicate { $0.id == id }
        )
        if let entity = try? modelContext.fetch(fetch).first {
            entity.status = status
            try? modelContext.save()
            messageContinuation.yield(entity.toDomain())
        }
    }

    private func startListening() {
        Task { [weak self] in
            guard let self else { return }
            for await message in await client.messageStream {
                let entity = MessageEntity(from: message)
                modelContext.insert(entity)
                try? modelContext.save()
                await updateConversationPreview(message)
                messageContinuation.yield(message)
            }
        }
    }

    private func updateConversationPreview(_ message: Message) {
        let jid = message.isOutgoing ? message.conversationId : message.senderJID
        let fetch = FetchDescriptor<ConversationEntity>(
            predicate: #Predicate { $0.jid == jid }
        )
        if let existing = try? modelContext.fetch(fetch).first {
            existing.lastMessage = message.text
            existing.lastTimestamp = message.timestamp
            if !message.isOutgoing { existing.unreadCount += 1 }
        } else {
            let conv = ConversationEntity(
                jid: jid,
                title: jid.components(separatedBy: "@").first ?? jid,
                lastMessage: message.text,
                lastTimestamp: message.timestamp,
                unreadCount: message.isOutgoing ? 0 : 1
            )
            modelContext.insert(conv)
        }
        try? modelContext.save()
    }

    func send(message: Message) async throws {
        try await client.sendMessage(body: message.text, to: message.conversationId)
        let entity = MessageEntity(from: message)
        modelContext.insert(entity)
        try modelContext.save()
    }

    func loadMessages(conversationId: String, before: Date? = nil, limit: Int = 50) async throws -> [Message] {
        var predicate: Predicate<MessageEntity>?
        if let before {
            predicate = #Predicate { $0.conversationId == conversationId && $0.timestamp < before }
        } else {
            predicate = #Predicate { $0.conversationId == conversationId }
        }
        var descriptor = FetchDescriptor<MessageEntity>(predicate: predicate, sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        descriptor.fetchLimit = limit
        let entities = try modelContext.fetch(descriptor)
        return entities.reversed().map { $0.toDomain() }
    }

    func loadConversations() async throws -> [Conversation] {
        let descriptor = FetchDescriptor<ConversationEntity>(
            sortBy: [SortDescriptor(\.lastTimestamp, order: .reverse)]
        )
        let entities = try modelContext.fetch(descriptor)
        return entities.map { $0.toDomain() }
    }

    func markAsRead(conversationId: String) async throws {
        let fetch = FetchDescriptor<ConversationEntity>(
            predicate: #Predicate { $0.jid == conversationId }
        )
        if let entity = try modelContext.fetch(fetch).first {
            entity.unreadCount = 0
            try modelContext.save()
        }
    }
}
