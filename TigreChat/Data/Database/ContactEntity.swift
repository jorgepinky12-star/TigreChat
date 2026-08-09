import Foundation
import SwiftData

@Model
final class ContactEntity {
    @Attribute(.unique) var jid: String
    var displayName: String
    var avatarURL: URL?
    var statusRaw: String
    var statusText: String
    var isPending: Bool

    var presenceStatus: PresenceStatus {
        get { PresenceStatus(rawValue: statusRaw) ?? .offline }
        set { statusRaw = newValue.rawValue }
    }

    init(jid: String, displayName: String = "", avatarURL: URL? = nil, status: PresenceStatus = .offline, statusText: String = "", isPending: Bool = false) {
        self.jid = jid
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.statusRaw = status.rawValue
        self.statusText = statusText
        self.isPending = isPending
    }

    convenience init(from user: User) {
        self.init(
            jid: user.jid,
            displayName: user.displayName,
            avatarURL: user.avatarURL,
            status: user.status,
            statusText: user.statusText
        )
    }

    func toDomain() -> User {
        User(
            jid: jid,
            displayName: displayName,
            avatarURL: avatarURL,
            status: presenceStatus,
            statusText: statusText
        )
    }
}
