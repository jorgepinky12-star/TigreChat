import Foundation
import SwiftData

@Model
final class ConversationEntity {
    @Attribute(.unique) var jid: String
    var title: String
    var avatarURL: URL?
    var lastMessage: String?
    var lastTimestamp: Date?
    var unreadCount: Int
    var isGroup: Bool
    var isMuted: Bool
    @Relationship var messages: [MessageEntity]?

    init(jid: String, title: String, avatarURL: URL? = nil, lastMessage: String? = nil, lastTimestamp: Date? = nil, unreadCount: Int = 0, isGroup: Bool = false, isMuted: Bool = false) {
        self.jid = jid
        self.title = title
        self.avatarURL = avatarURL
        self.lastMessage = lastMessage
        self.lastTimestamp = lastTimestamp
        self.unreadCount = unreadCount
        self.isGroup = isGroup
        self.isMuted = isMuted
    }

    convenience init(from conversation: Conversation) {
        self.init(
            jid: conversation.jid,
            title: conversation.title,
            avatarURL: conversation.avatarURL,
            lastMessage: conversation.lastMessage,
            lastTimestamp: conversation.lastTimestamp,
            unreadCount: conversation.unreadCount,
            isGroup: conversation.isGroup,
            isMuted: conversation.isMuted
        )
    }

    func toDomain() -> Conversation {
        Conversation(
            jid: jid,
            title: title,
            avatarURL: avatarURL,
            lastMessage: lastMessage,
            lastTimestamp: lastTimestamp,
            unreadCount: unreadCount,
            isGroup: isGroup,
            participants: [],
            isMuted: isMuted
        )
    }
}
