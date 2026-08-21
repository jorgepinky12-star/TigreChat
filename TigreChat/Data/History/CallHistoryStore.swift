import Foundation
import SwiftData

/// Historial de llamadas por JID, con merge por sid (REQ-HIST-003).
///
/// MainActor: el `ModelContext` no es Sendable; todo acceso queda confinado
/// al actor principal. El repositorio de llamadas (actor) escribe con
/// `try await historyStore.upsert(...)` — los hops respetan la regla
/// ModelContext/MainActor sin traspasar el modelo a otro dominio.
@MainActor
final class CallHistoryStore {
    private let context: ModelContext

    init(modelContainer: ModelContainer) {
        context = modelContainer.mainContext
    }

    init(modelContext: ModelContext) {
        context = modelContext
    }

    /// INSERT-or-UPDATE por sid: si la llamada ya tiene fila (p. ej. se
    /// registró al empezar), la actualiza con el estado final — nunca duplica.
    func upsert(
        sid: String,
        jid: String,
        direction: CallDirection,
        status: CallStatus,
        duration: TimeInterval = 0,
        timestamp: Date = .now,
        isVideo: Bool = false,
        conversation: ConversationEntity? = nil
    ) throws {
        let descriptor = FetchDescriptor<CallHistoryEntry>(
            predicate: #Predicate { $0.sid == sid }
        )
        let entry: CallHistoryEntry
        if let existing = try context.fetch(descriptor).first {
            entry = existing
            entry.jid = jid
            entry.directionRaw = direction.rawValue
            entry.statusRaw = status.rawValue
            entry.duration = duration
            entry.timestamp = timestamp
            entry.isVideo = isVideo
            entry.conversation = conversation
        } else {
            entry = CallHistoryEntry(
                sid: sid, jid: jid, direction: direction, status: status,
                duration: duration, timestamp: timestamp, isVideo: isVideo,
                conversation: conversation
            )
            context.insert(entry)
        }
        try context.save()
    }

    /// Entradas de un contacto, más recientes primero (para la sección de
    /// historial de la vista de chat, M5).
    func entries(for jid: String) -> [CallHistoryEntry] {
        let descriptor = FetchDescriptor<CallHistoryEntry>(
            predicate: #Predicate { $0.jid == jid },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func entry(sid: String) -> CallHistoryEntry? {
        let descriptor = FetchDescriptor<CallHistoryEntry>(
            predicate: #Predicate { $0.sid == sid }
        )
        return try? context.fetch(descriptor).first
    }
}