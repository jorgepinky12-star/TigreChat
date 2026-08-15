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
    var attachmentURL: String?
    var attachmentMimeType: String?
    var attachmentFileName: String?
    var attachmentSize: Int?
    var isEncrypted: Bool = false

    var status: MessageStatus {
        get { MessageStatus(rawValue: statusRaw) ?? .sent }
        set { statusRaw = newValue.rawValue }
    }

    var type: MessageType {
        get { MessageType(rawValue: typeRaw) ?? .text }
        set { typeRaw = newValue.rawValue }
    }

    init(id: String, conversationId: String, senderJID: String, text: String, timestamp: Date, isOutgoing: Bool, status: MessageStatus, type: MessageType, attachmentURL: String? = nil, attachmentMimeType: String? = nil, attachmentFileName: String? = nil, attachmentSize: Int? = nil, isEncrypted: Bool = false) {
        self.id = id
        self.conversationId = conversationId
        self.senderJID = senderJID
        self.text = text
        self.timestamp = timestamp
        self.isOutgoing = isOutgoing
        self.statusRaw = status.rawValue
        self.typeRaw = type.rawValue
        self.attachmentURL = attachmentURL
        self.attachmentMimeType = attachmentMimeType
        self.attachmentFileName = attachmentFileName
        self.attachmentSize = attachmentSize
        self.isEncrypted = isEncrypted
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
            type: message.type,
            attachmentURL: message.attachment?.url.absoluteString,
            attachmentMimeType: message.attachment?.mimeType,
            attachmentFileName: message.attachment?.displayFileName,
            attachmentSize: message.attachment?.size,
            isEncrypted: message.isEncrypted
        )
    }

    func toDomain() -> Message {
        var attachment: FileAttachment?
        if let attachmentURL, let url = URL(string: attachmentURL) {
            attachment = FileAttachment(
                id: id,
                url: url,
                mimeType: attachmentMimeType ?? "application/octet-stream",
                size: attachmentSize ?? 0,
                fileName: attachmentFileName ?? url.lastPathComponent
            )
        }
        return Message(
            id: id,
            conversationId: conversationId,
            senderJID: senderJID,
            text: text,
            timestamp: timestamp,
            isOutgoing: isOutgoing,
            status: status,
            type: type,
            isEncrypted: isEncrypted,
            attachment: attachment
        )
    }
}
