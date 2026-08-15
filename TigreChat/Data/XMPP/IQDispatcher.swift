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

    /// Respuestas `result`/`error` que llegaron antes de que su emisor
    /// registrara la espera. La carrera real: `send()` → respuesta del
    /// servidor → `deliver()` corren en el receive loop ANTES de que el
    /// actor del cliente llegue a `wait()`, y la respuesta se descartaba
    /// como "unmatched". Con redes rápidas (simulador/localhost) eso rompía
    /// el bind justo después del SASL.
    private var earlyResponses: [String: IQStanza] = [:]
    private var earlyOrder: [String] = []
    private let earlyCapacity = 32

    /// Registra una espera para el `id` dado. La respuesta (o un error) se
    /// entrega cuando `deliver(_:)` recibe el stanza correspondiente, o expira
    /// con `XMPPError.timedOut` si no llega dentro de `timeout`.
    func wait(for id: String, timeout: TimeInterval) async throws -> IQStanza {
        // La respuesta pudo llegar antes de esta llamada (carrera tras el
        // envío): consumirla directamente en vez de esperar 10 s en vano.
        if let early = earlyResponses.removeValue(forKey: id) {
            earlyOrder.removeAll { $0 == id }
            return early
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<IQStanza, any Error>) in
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
            // Nadie esperaba todavía. Si es una respuesta (no un push),
            // retenerla brevemente por si el emisor registra su espera justo
            // después del envío; si es un push, se devuelve sin guardar.
            if !id.isEmpty, stanza.type == .result || stanza.type == .error {
                if earlyResponses[id] == nil {
                    earlyOrder.append(id)
                    if earlyOrder.count > earlyCapacity {
                        let evicted = earlyOrder.removeFirst()
                        earlyResponses.removeValue(forKey: evicted)
                    }
                }
                earlyResponses[id] = stanza
            }
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
        earlyResponses.removeAll()
        earlyOrder.removeAll()
    }

    private func timeout(id: String) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.continuation.resume(throwing: XMPPError.timedOut)
    }
}
