import Foundation

struct User: Identifiable, Hashable, Sendable {
    let id: String
    let jid: String
    var displayName: String
    var avatarURL: URL?
    var status: PresenceStatus
    var statusText: String

    init(jid: String, displayName: String = "", avatarURL: URL? = nil, status: PresenceStatus = .offline, statusText: String = "") {
        self.id = jid
        self.jid = jid
        self.displayName = displayName.isEmpty ? jid.components(separatedBy: "@").first ?? jid : displayName
        self.avatarURL = avatarURL
        self.status = status
        self.statusText = statusText
    }
}

enum PresenceStatus: String, Sendable {
    case online
    case away
    case busy
    case offline
    case unknown
}
