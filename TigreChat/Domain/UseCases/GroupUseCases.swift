import Foundation

struct CreateGroupUseCase: Sendable {
    private let groupRepository: GroupRepository

    init(groupRepository: GroupRepository) { self.groupRepository = groupRepository }

    func execute(name: String, subject: String? = nil) async throws -> GroupRoom {
        try await groupRepository.createRoom(name: name, subject: subject)
    }
}

struct JoinGroupUseCase: Sendable {
    private let groupRepository: GroupRepository

    init(groupRepository: GroupRepository) { self.groupRepository = groupRepository }

    func execute(roomJID: String, nickname: String) async throws {
        try await groupRepository.joinRoom(jid: roomJID, nickname: nickname)
    }
}

struct FetchGroupsUseCase: Sendable {
    private let groupRepository: GroupRepository

    init(groupRepository: GroupRepository) { self.groupRepository = groupRepository }

    func execute() async throws -> [GroupRoom] {
        try await groupRepository.fetchRooms()
    }
}
