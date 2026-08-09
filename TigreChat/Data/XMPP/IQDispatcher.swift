import Foundation

/// Correlaciona respuestas IQ por `id` de stanza para permitir múltiples
/// peticiones IQ concurrentes (roster, MAM, disco, PEP, HTTP upload, ...)
/// sin pisarse. Reemplaza el patrón anterior de una única continuation
/// global que solo soportaba una petición a la vez.
actor IQDispatcher {
    private struct Pending {
        let continuation: CheckedContinuation<IQStanza, any Error>
        let timeoutTask: Task<Void, Never>?
    }

    private var pending: [String: Pending] = [:]

    /// Registra una espera para el `id` dado. La respuesta (o un error) se
    /// entrega cuando `deliver(_:)` recibe el stanza correspondiente, o expira
    /// con `XMPPError.timedOut` si no llega dentro de `timeout`.
    func wait(for id: String, timeout: TimeInterval) async throws -> IQStanza {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<IQStanza, any Error>) in
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self else { return }
                await self.timeout(id: id)
            }
            // Duplicado de id (teóricamente imposible con nextID): resuelve el
            // anterior para no dejar continuations colgadas.
            if let previous = pending[id] {
                previous.timeoutTask?.cancel()
                previous.continuation.resume(throwing: XMPPError.timedOut)
            }
            pending[id] = Pending(continuation: continuation, timeoutTask: timeoutTask)
        }
    }

    /// Entrega un stanza IQ entrante. Si alguien esperaba ese `id`, resuelve su
    /// continuation y devuelve `nil` (consumido). Si nadie lo esperaba, devuelve
    /// el stanza tal cual para que el cliente lo trate como push no solicitado
    /// (roster push, Jingle, etc.).
    @discardableResult
    func deliver(_ stanza: IQStanza) -> IQStanza? {
        let id = stanza.id
        guard !id.isEmpty, let entry = pending.removeValue(forKey: id) else {
            return stanza
        }
        entry.timeoutTask?.cancel()
        switch stanza.type {
        case .result:
            entry.continuation.resume(returning: stanza)
        case .error:
            entry.continuation.resume(throwing: XMPPError.iqError(stanza.rawXML))
        case .get, .set:
            // Petición entrante con id coincidente con una espera local:
            // no es una respuesta, devolver como push.
            entry.continuation.resume(throwing: XMPPError.iqError("Unexpected IQ \(stanza.type.rawValue) for pending id"))
        }
        return nil
    }

    /// Cancela todas las esperas pendientes (p. ej. al desconectar).
    func cancelAll(reason: any Error) {
        for (_, entry) in pending {
            entry.timeoutTask?.cancel()
            entry.continuation.resume(throwing: reason)
        }
        pending.removeAll()
    }

    private func timeout(id: String) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.continuation.resume(throwing: XMPPError.timedOut)
    }
}
