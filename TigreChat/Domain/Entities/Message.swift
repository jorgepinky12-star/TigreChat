import Foundation

struct Message: Identifiable, Hashable, Sendable {
    let id: String
    let conversationId: String
    let senderJID: String
    let text: String
    let timestamp: Date
    let isOutgoing: Bool
    var status: MessageStatus
    var type: MessageType
    var isEncrypted: Bool

    init(
        id: String = UUID().uuidString,
        conversationId: String,
        senderJID: String,
        text: String,
        timestamp: Date = Date(),
        isOutgoing: Bool,
        status: MessageStatus = .sending,
        type: MessageType = .text,
        isEncrypted: Bool = false
    ) {
        self.id = id
        self.conversationId = conversationId
        self.senderJID = senderJID
        self.text = text
        self.timestamp = timestamp
        self.isOutgoing = isOutgoing
        self.status = status
        self.type = type
        self.isEncrypted = isEncrypted
    }
}

enum MessageStatus: String, Sendable {
    case sending
    case sent
    case delivered
    case read
    case failed
}

enum MessageType: String, Sendable {
    case text
    case image
    case file
    case system
}
