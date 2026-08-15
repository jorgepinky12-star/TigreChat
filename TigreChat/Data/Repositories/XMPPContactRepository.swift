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
            // Cada contacto real del roster también aparece como conversación
            // en la lista de chats, aunque todavía no haya mensajes.
            if !item.isPending {
                ensureConversation(for: item)
            }
        }
        try? modelContext.save()
        let contacts = (try? modelContext.fetch(FetchDescriptor<ContactEntity>())) ?? []
        contactContinuation.yield(contacts.map { $0.toDomain() })
    }

    /// Crea (o actualiza el título) de la conversación de un contacto del
    /// roster. Evita duplicados gracias al atributo `.unique` de `jid`.
    private func ensureConversation(for item: RosterItem) {
        let targetJID = item.jid
        let fetch = FetchDescriptor<ConversationEntity>(
            predicate: #Predicate { $0.jid == targetJID }
        )
        if let existing = try? modelContext.fetch(fetch).first {
            if let name = item.name, !name.isEmpty, existing.title != name {
                existing.title = name
            }
        } else {
            let title = item.name?.isEmpty == false
                ? item.name!
                : (item.jid.components(separatedBy: "@").first ?? item.jid)
            modelContext.insert(ConversationEntity(jid: item.jid, title: title))
        }
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
            } else if let mode = presence.show, ["away", "xa", "dnd"].contains(mode) {
                // Paridad con el cliente Android: away/xa/dnd → AWAY.
                entity.presenceStatus = .away
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
