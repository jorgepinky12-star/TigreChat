import Foundation
import os

/// Lista de estrategias de conexión probadas en orden (LoginViewModel y el
/// flujo OTP demo comparten esta lógica): servidor explícito, resolución SRV
/// y fallbacks de puertos/TLS habituales. La primera que conecta gana.
enum XMPPConnectionStrategies {
    /// Devuelve las candidatas de `(host, port, useDirectTLS)` para un
    /// dominio, de la más específica a la más genérica.
    static func resolve(server: String, domain: String) async -> [(host: String, port: Int, useTLS: Bool)] {
        var strategies: [(String, Int, Bool)] = []

        // Servidor explícito: conectar directo al puerto XMPP estándar
        // (5222, STARTTLS negociado in-band) primero.
        if !server.isEmpty {
            strategies.append((server, 5222, false))
        }

        do {
            let resolver = XMPPSRVResolver()
            let (record, service) = try await resolver.resolve(domain: domain)
            let isDirectTLS = service == .xmppsClient
            os_log("[XMPP] SRV: %{public}s:%d (service=%{public}s, prio=%d)",
                   log: xmppLog, type: .info, record.host, record.port, service.rawValue, record.priority)
            strategies.append((record.host, record.port, isDirectTLS))
        } catch {
            os_log("[XMPP] SRV failed: %{public}s", log: xmppLog, type: .error, String(describing: error))
        }

        strategies.append(("xmpps.\(domain)", 443, true))
        strategies.append((domain, 5223, true))
        strategies.append((domain, 5222, false))
        strategies.append((domain, 443, true))

        return strategies
    }
}
