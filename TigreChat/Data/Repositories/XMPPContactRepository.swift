import Foundation
import SwiftData

/// MainActor-confined: ModelContext is not Sendable, so Apple's documented
/// pattern is to confine it to the main actor for UI-bound persistence.
@MainActor
final class XMPPContactRepository: ContactRepository {
    private let client: XMPPClient
    private let modelContext: ModelContext
    private let contactContinuation: AsyncStream<[User]>.Continuation
    let contactStream: AsyncStream<[User]>

    private var lastRosterVersion: String = ""

    init(client: XMPPClient, modelContainer: ModelContainer) {
        self.client = client
        self.modelContext = ModelContext(modelContainer)
        var cont: AsyncStream<[User]>.Continuation!
        let stream = AsyncStream<[User]> { continuation in
            cont = continuation
        }
        contactContinuation = cont
        contactStream = stream
        startPresenceListening()
        startRosterListening()
    }

    // MARK: - Roster (WU2: persistir contacto real del servidor)

    private func startRosterListening() {
        Task { [weak self] in
            guard let self else { return }
            for await items in await client.rosterStream {
                await handleRoster(items)
            }
        }
    }

    private func handleRoster(_ items: [RosterItem]) async {
        for item in items {
            let targetJID = item.jid
            let fetch = FetchDescriptor<ContactEntity>(
                predicate: #Predicate { $0.jid == targetJID }
            )
            if let entity = try? modelContext.fetch(fetch).first {
                if let name = item.name, !name.isEmpty {
                    entity.displayName = name
                }
                entity.isPending = item.isPending
            } else {
                let entity = ContactEntity(
                    jid: item.jid,
                    displayName: item.name ?? "",
                    isPending: item.isPending
                )
                modelContext.insert(entity)
            }
        }
        try? modelContext.save()
        let contacts = (try? modelContext.fetch(FetchDescriptor<ContactEntity>())) ?? []
        contactContinuation.yield(contacts.map { $0.toDomain() })
    }

    private func startPresenceListening() {
        Task { [weak self] in
            guard let self else { return }
            for await presence in await client.presenceStream {
                await handlePresence(presence)
            }
        }
    }

    private func handlePresence(_ presence: PresenceStanza) async {
        guard let from = presence.from else { return }
        let jid = from.components(separatedBy: "/").first ?? from
        let fetch = FetchDescriptor<ContactEntity>(
            predicate: #Predicate { $0.jid == jid }
        )
        if let entity = try? modelContext.fetch(fetch).first {
            if presence.type == "unavailable" {
                entity.presenceStatus = .offline
            } else {
                entity.presenceStatus = .online
            }
            if let status = presence.status {
                entity.statusText = status
            }
            try? modelContext.save()
            let contacts = (try? modelContext.fetch(FetchDescriptor<ContactEntity>())) ?? []
            contactContinuation.yield(contacts.map { $0.toDomain() })
        }
    }

    func fetchContacts() async throws -> [User] {
        let descriptor = FetchDescriptor<ContactEntity>()
        let entities = try modelContext.fetch(descriptor)
        return entities.map { $0.toDomain() }
    }

    func addContact(jid: String, name: String?) async throws {
        let entity = ContactEntity(jid: jid, displayName: name ?? "")
        modelContext.insert(entity)
        try modelContext.save()
    }

    func removeContact(jid: String) async throws {
        let fetch = FetchDescriptor<ContactEntity>(
            predicate: #Predicate { $0.jid == jid }
        )
        if let entity = try modelContext.fetch(fetch).first {
            modelContext.delete(entity)
            try modelContext.save()
        }
    }
}
