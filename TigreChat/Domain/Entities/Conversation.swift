import Foundation

struct Conversation: Identifiable, Hashable, Sendable {
    let id: String
    let jid: String
    var title: String
    var avatarURL: URL?
    var lastMessage: String?
    var lastTimestamp: Date?
    var unreadCount: Int
    var isGroup: Bool
    var participants: [User]
    var isMuted: Bool

    init(
        jid: String,
        title: String = "",
        avatarURL: URL? = nil,
        lastMessage: String? = nil,
        lastTimestamp: Date? = nil,
        unreadCount: Int = 0,
        isGroup: Bool = false,
        participants: [User] = [],
        isMuted: Bool = false
    ) {
        self.id = jid
        self.jid = jid
        self.title = title.isEmpty ? jid.components(separatedBy: "@").first ?? jid : title
        self.avatarURL = avatarURL
        self.lastMessage = lastMessage
        self.lastTimestamp = lastTimestamp
        self.unreadCount = unreadCount
        self.isGroup = isGroup
        self.participants = participants
        self.isMuted = isMuted
    }
}
