import Foundation
import SwiftData

/// MainActor-confined: ModelContext is not Sendable, so Apple's documented
/// pattern is to confine it to the main actor for UI-bound persistence.
@MainActor
final class XMPPGroupRepository: GroupRepository {
    private let mucManager: XMPPMUCManager
    private let modelContext: ModelContext

    init(mucManager: XMPPMUCManager, modelContainer: ModelContainer) {
        self.mucManager = mucManager
        self.modelContext = ModelContext(modelContainer)
    }

    func createRoom(name: String, subject: String?) async throws -> GroupRoom {
        let domain = "conference.local"
        let roomJID = "\(name.lowercased().replacingOccurrences(of: " ", with: "_"))@\(domain)"
        try await mucManager.joinRoom(jid: roomJID, nickname: name)
        let room = GroupRoom(jid: roomJID, name: name, subject: subject)
        return room
    }

    func joinRoom(jid: String, nickname: String) async throws {
        try await mucManager.joinRoom(jid: jid, nickname: nickname)
    }

    func leaveRoom(jid: String) async throws {
        try await mucManager.leaveRoom(jid: jid, nickname: "")
    }

    func fetchRooms() async throws -> [GroupRoom] {
        let descriptor = FetchDescriptor<ConversationEntity>(
            predicate: #Predicate { $0.isGroup == true }
        )
        let entities = try modelContext.fetch(descriptor)
        return entities.map { GroupRoom(jid: $0.jid, name: $0.title) }
    }

    func fetchOccupants(roomJID: String) async throws -> [Occupant] {
        []
    }

    func configureRoom(jid: String, configuration: [String: String]) async throws {
    }
}
