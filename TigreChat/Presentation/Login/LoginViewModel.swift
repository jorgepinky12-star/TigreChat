import Foundation
import os

let xmppLog = OSLog(subsystem: "com.tigrechat", category: "XMPP")

@MainActor
@Observable
final class LoginViewModel {
    var server: String = "ims-bzr.z17.cu"
    var jid: String = ""
    var password: String = ""
    var isLoading = false
    var errorMessage: String?
    var isLoggedIn = false

    private let authRepository: AuthRepository
    private let xmppClient: XMPPClient

    init(authRepository: AuthRepository, xmppClient: XMPPClient) {
        self.authRepository = authRepository
        self.xmppClient = xmppClient
    }

    private func resolveConnectionStrategies(_ domain: String) async -> [(host: String, port: Int, useTLS: Bool)] {
        var strategies: [(String, Int, Bool)] = []

        // Explicit server configured: connect directly to that host on the
        // standard XMPP client port (5222, STARTTLS negotiated in-band) first.
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

    func login() async {
        guard !jid.isEmpty, !password.isEmpty else {
            errorMessage = "Please enter JID and password"
            return
        }
        isLoading = true
        errorMessage = nil

        let domain = server.isEmpty ? String(jid.split(separator: "@").last ?? "") : server
        os_log("[XMPP] Starting login for %{public}s on domain %{public}s",
               log: xmppLog, type: .info, jid, domain)
        let strategies = await resolveConnectionStrategies(domain)
        os_log("[XMPP] %d strategies to try", log: xmppLog, type: .info, strategies.count)

        for (i, (host, port, useTLS)) in strategies.enumerated() {
            os_log("[XMPP] Strategy %d/%d: %{public}s:%d (TLS: %d)",
                   log: xmppLog, type: .info, i + 1, strategies.count, host, port, useTLS)
            do {
                try await authRepository.connect(server: host, port: port, useTLS: useTLS, domain: domain)
                os_log("[XMPP] Connected. Authenticating...", log: xmppLog, type: .info)
                try await authRepository.authenticate(jid: jid, password: password)
                os_log("[XMPP] Authenticated successfully!", log: xmppLog, type: .info)
                isLoggedIn = true
                isLoading = false
                return
            } catch {
                os_log("[XMPP] Strategy %d failed: %{public}s",
                       log: xmppLog, type: .error, i + 1, String(describing: error))
                await authRepository.disconnect()
            }
        }

        errorMessage = "Could not connect to \(domain). Check your server address and try again."
        isLoading = false
    }

    func logout() async {
        await authRepository.logout()
        isLoggedIn = false
        jid = ""
        password = ""
    }

    /// Reanuda automáticamente la última sesión guardada en el Keychain.
    func autoLogin() async {
        guard !isLoading, !isLoggedIn else { return }
        isLoading = true
        errorMessage = nil
        do {
            let restored = try await authRepository.autoLogin()
            if restored {
                isLoggedIn = true
                os_log("[XMPP] Auto-login restored session", log: xmppLog, type: .info)
            }
        } catch {
            os_log("[XMPP] Auto-login failed: %{public}s", log: xmppLog, type: .error, String(describing: error))
            errorMessage = nil
        }
        isLoading = false
    }
}
