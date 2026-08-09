import Foundation

struct GroupRoom: Identifiable, Hashable, Sendable {
    let id: String
    let jid: String
    var name: String
    var subject: String?
    var occupantsCount: Int
    var role: OccupantRole
    var affiliation: Affiliation
    var isBookmarked: Bool

    init(jid: String, name: String = "", subject: String? = nil, occupantsCount: Int = 0, role: OccupantRole = .participant, affiliation: Affiliation = .member, isBookmarked: Bool = false) {
        self.id = jid
        self.jid = jid
        self.name = name.isEmpty ? jid.components(separatedBy: "@").first ?? jid : name
        self.subject = subject
        self.occupantsCount = occupantsCount
        self.role = role
        self.affiliation = affiliation
        self.isBookmarked = isBookmarked
    }
}

enum OccupantRole: String, Sendable {
    case moderator
    case participant
    case visitor
    case none
}

enum Affiliation: String, Sendable {
    case owner
    case admin
    case member
    case outcast
    case none
}

struct Occupant: Identifiable, Hashable, Sendable {
    let id: String
    let jid: String
    let roomJID: String
    let nickname: String
    var role: OccupantRole
    var affiliation: Affiliation
}
