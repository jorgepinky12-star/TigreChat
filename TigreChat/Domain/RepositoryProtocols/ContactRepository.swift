import Foundation

enum ContactError: Error, Sendable {
    case fetchFailed(String)
    case notFound
}

@MainActor
protocol ContactRepository: Sendable {
    func fetchContacts() async throws -> [User]
    func addContact(jid: String, name: String?) async throws
    func removeContact(jid: String) async throws
}
