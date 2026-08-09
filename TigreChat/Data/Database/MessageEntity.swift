import Foundation
import SwiftData

@Model
final class MessageEntity {
    @Attribute(.unique) var id: String
    var conversationId: String
    var senderJID: String
    var text: String
    var timestamp: Date
    var isOutgoing: Bool
    var statusRaw: String
    var typeRaw: String

    var status: MessageStatus {
        get { MessageStatus(rawValue: statusRaw) ?? .sent }
        set { statusRaw = newValue.rawValue }
    }

    var type: MessageType {
        get { MessageType(rawValue: typeRaw) ?? .text }
        set { typeRaw = newValue.rawValue }
    }

    init(id: String, conversationId: String, senderJID: String, text: String, timestamp: Date, isOutgoing: Bool, status: MessageStatus, type: MessageType) {
        self.id = id
        self.conversationId = conversationId
        self.senderJID = senderJID
        self.text = text
        self.timestamp = timestamp
        self.isOutgoing = isOutgoing
        self.statusRaw = status.rawValue
        self.typeRaw = type.rawValue
    }

    convenience init(from message: Message) {
        self.init(
            id: message.id,
            conversationId: message.conversationId,
            senderJID: message.senderJID,
            text: message.text,
            timestamp: message.timestamp,
            isOutgoing: message.isOutgoing,
            status: message.status,
            type: message.type
        )
    }

    func toDomain() -> Message {
        Message(
            id: id,
            conversationId: conversationId,
            senderJID: senderJID,
            text: text,
            timestamp: timestamp,
            isOutgoing: isOutgoing,
            status: status,
            type: type
        )
    }
}
