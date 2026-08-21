import Foundation
import SwiftData

/// Contrato de almacenamiento TOFU: consulta y persistencia por JID
/// (REQ-JINGLE-011). El repositorio de llamadas (actor) lo consume con
/// `await` — el store es MainActor aislando el ModelContext.
@MainActor
protocol FingerprintStoring: Sendable {
    /// Huella aceptada para el JID, o `nil` si es el primer contacto.
    func storedFingerprint(for jid: String) -> String?
    /// Persiste (o actualiza) la huella aceptada para el JID.
    func store(_ fingerprint: String, for jid: String) throws
}

@MainActor
final class FingerprintStore: FingerprintStoring {
    private let context: ModelContext

    init(modelContainer: ModelContainer) {
        context = modelContainer.mainContext
    }

    init(modelContext: ModelContext) {
        context = modelContext
    }

    func storedFingerprint(for jid: String) -> String? {
        let descriptor = FetchDescriptor<FingerprintEntity>(
            predicate: #Predicate { $0.jid == jid }
        )
        return (try? context.fetch(descriptor))?.first?.fingerprint
    }

    func store(_ fingerprint: String, for jid: String) throws {
        let descriptor = FetchDescriptor<FingerprintEntity>(
            predicate: #Predicate { $0.jid == jid }
        )
        if let existing = try? context.fetch(descriptor).first {
            existing.fingerprint = fingerprint
            existing.lastSeen = .now
        } else {
            context.insert(FingerprintEntity(jid: jid, fingerprint: fingerprint))
        }
        try context.save()
    }
}