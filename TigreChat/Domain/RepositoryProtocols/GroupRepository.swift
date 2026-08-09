import Foundation

enum GroupError: Error, Sendable {
    case joinFailed(String)
    case creationFailed(String)
    case notFound
    case notConnected
}

@MainActor
protocol GroupRepository: Sendable {
    func createRoom(name: String, subject: String?) async throws -> GroupRoom
    func joinRoom(jid: String, nickname: String) async throws
    func leaveRoom(jid: String) async throws
    func fetchRooms() async throws -> [GroupRoom]
    func fetchOccupants(roomJID: String) async throws -> [Occupant]
    func configureRoom(jid: String, configuration: [String: String]) async throws
}
