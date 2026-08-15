import Foundation
import os

let xmppLog = OSLog(subsystem: "com.tigrechat", category: "XMPP")

@MainActor
@Observable
final class LoginViewModel {
    var server: String = "ims-brz.z17.cu"
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
        await XMPPConnectionStrategies.resolve(server: server, domain: domain)
    }

    func login() async {
        guard !jid.isEmpty, !password.isEmpty else {
            errorMessage = String(localized: "Please enter JID and password")
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

        errorMessage = String(localized: "Could not connect to \(domain). Check your server address and try again.")
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
