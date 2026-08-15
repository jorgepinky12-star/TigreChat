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
    /// Adjunto (imagen/audio/video/archivo): nil para mensajes de texto.
    var attachment: FileAttachment?

    init(
        id: String = UUID().uuidString,
        conversationId: String,
        senderJID: String,
        text: String,
        timestamp: Date = Date(),
        isOutgoing: Bool,
        status: MessageStatus = .sending,
        type: MessageType = .text,
        isEncrypted: Bool = false,
        attachment: FileAttachment? = nil
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
        self.attachment = attachment
    }
}

enum MessageStatus: String, Sendable {
    case sending
    case sent
    case delivered
    case read
    case failed
    /// Persistido localmente tras un envío fallido por desconexión; se
    /// reintenta al reconectar (outbox).
    case pending
}

enum MessageType: String, Sendable {
    case text
    case image
    case audio
    case file
    case system
}
