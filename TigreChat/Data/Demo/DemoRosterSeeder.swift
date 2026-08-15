import Foundation
import SwiftData

/// Seeds a local demo roster (contacts + conversations + messages) for
/// exercising the chat UI without a server connection.
///
/// TEMPORARY: kept as a local utility. The demo login now connects to the
/// real IM server with the demo account (`jorge@ims-brz.z17.cu`) and the
/// server roster arrives through the normal XMPP path, so the router no
/// longer calls this seeder. Remove once the SMS backend lands.
@MainActor
final class DemoRosterSeeder {
    private let modelContext: ModelContext

    init(modelContainer: ModelContainer) {
        modelContext = ModelContext(modelContainer)
    }

    /// Seeds the demo data once. Safe to call repeatedly: if conversations
    /// already exist it does nothing.
    func seedIfNeeded() {
        let existing = (try? modelContext.fetchCount(FetchDescriptor<ConversationEntity>())) ?? 0
        guard existing == 0 else { return }

        let now = Date()
        seedConversation(
            jid: "maria@ims-brz.z17.cu",
            title: "María",
            lastMessage: "¿Viste el partido anoche?",
            lastTimestamp: now.addingTimeInterval(-5 * 60),
            unreadCount: 2,
            messages: [
                ("jorge@ims-brz.z17.cu", "¡Hola María! ¿Qué tal todo?", now.addingTimeInterval(-50 * 60), true),
                ("maria@ims-brz.z17.cu", "¿Viste el partido anoche?", now.addingTimeInterval(-5 * 60), false)
            ]
        )
        seedConversation(
            jid: "carlos@ims-brz.z17.cu",
            title: "Carlos",
            lastMessage: "El deploy quedó listo",
            lastTimestamp: now.addingTimeInterval(-62 * 60),
            unreadCount: 0,
            messages: [
                ("carlos@ims-brz.z17.cu", "¿Revisaste el PR de la semana?", now.addingTimeInterval(-80 * 60), false),
                ("jorge@ims-brz.z17.cu", "Sí, todo bien", now.addingTimeInterval(-70 * 60), true),
                ("carlos@ims-brz.z17.cu", "El deploy quedó listo", now.addingTimeInterval(-62 * 60), false)
            ]
        )
        seedConversation(
            jid: "tigres@muc.ims-brz.z17.cu",
            title: "Grupo Tigres",
            lastMessage: "Nueva reunión el viernes",
            lastTimestamp: now.addingTimeInterval(-3 * 3600),
            unreadCount: 5,
            isGroup: true,
            messages: [
                ("andres@ims-brz.z17.cu", "¿Alguien vio los resultados?", now.addingTimeInterval(-4 * 3600), false),
                ("lucia@ims-brz.z17.cu", "Yo, buen partido", now.addingTimeInterval(-3.5 * 3600), false),
                ("andres@ims-brz.z17.cu", "Nueva reunión el viernes", now.addingTimeInterval(-3 * 3600), false)
            ]
        )
        seedConversation(
            jid: "lucia@ims-brz.z17.cu",
            title: "Lucía",
            lastMessage: "Te mando las fotos del viaje",
            lastTimestamp: now.addingTimeInterval(-26 * 3600),
            unreadCount: 1,
            messages: [
                ("lucia@ims-brz.z17.cu", "Te mando las fotos del viaje", now.addingTimeInterval(-26 * 3600), false)
            ]
        )
        seedConversation(
            jid: "andres@ims-brz.z17.cu",
            title: "Andrés",
            lastMessage: "Quedamos mañana a las 8",
            lastTimestamp: now.addingTimeInterval(-2 * 86400),
            unreadCount: 0,
            messages: [
                ("andres@ims-brz.z17.cu", "Quedamos mañana a las 8", now.addingTimeInterval(-2 * 86400), false),
                ("jorge@ims-brz.z17.cu", "Perfecto, nos vemos", now.addingTimeInterval(-2 * 86400 + 600), true)
            ]
        )

        try? modelContext.save()
    }

    private func seedConversation(
        jid: String,
        title: String,
        lastMessage: String,
        lastTimestamp: Date,
        unreadCount: Int = 0,
        isGroup: Bool = false,
        messages: [(sender: String, text: String, timestamp: Date, outgoing: Bool)]
    ) {
        let contact = ContactEntity(
            jid: jid,
            displayName: title,
            status: isGroup ? .offline : .online,
            statusText: isGroup ? "" : "demo"
        )
        modelContext.insert(contact)

        let conversation = ConversationEntity(
            jid: jid,
            title: title,
            lastMessage: lastMessage,
            lastTimestamp: lastTimestamp,
            unreadCount: unreadCount,
            isGroup: isGroup
        )
        modelContext.insert(conversation)

        for (sender, text, timestamp, outgoing) in messages {
            modelContext.insert(MessageEntity(
                id: UUID().uuidString,
                conversationId: jid,
                senderJID: sender,
                text: text,
                timestamp: timestamp,
                isOutgoing: outgoing,
                status: .delivered,
                type: .text
            ))
        }
    }
}