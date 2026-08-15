import SwiftData
import SwiftUI
import os

struct AppRouter: View {
    @State private var isLoggedIn = false
    @Environment(\.dependencies) private var deps

    var body: some View {
        Group {
            if isLoggedIn {
                MainTabView(
                    viewModel: deps.makeChatListViewModel(),
                    isLoggedIn: $isLoggedIn
                )
            } else {
                PhoneLoginView(
                    viewModel: PhoneLoginViewModel(service: AuthServiceFactory.make()),
                    manualLogin: LoginView(
                        viewModel: deps.makeLoginViewModel(),
                        onLoginSuccess: { isLoggedIn = true }
                    ),
                    onVerified: { credentials in
                        try await provisionAndConnect(credentials)
                    }
                )
                .transition(.opacity)
            }
        }
        .animation(.default, value: isLoggedIn)
    }

    /// After the OTP is verified the backend has provisioned an ejabberd
    /// account for the phone number: connect to the IM server with those
    /// credentials (they are persisted in the Keychain by the repository),
    /// then enter the chat list. Demo mode uses the demo account's stored
    /// credentials (`jorge@ims-brz.z17.cu`) through the same real path.
    private func provisionAndConnect(_ credentials: AuthCredentials) async throws {
        let domain = credentials.jid.split(separator: "@").last.map(String.init)
            ?? AuthServiceFactory.config.xmppDomain
        // Misma lógica de estrategias que el login manual (SRV + fallbacks de
        // puertos/TLS): la primera que conecta gana.
        let strategies = await XMPPConnectionStrategies.resolve(server: domain, domain: domain)
        os_log("[Auth] SMS login: %d strategies to try", log: xmppLog, type: .info, strategies.count)

        for (i, (host, port, useTLS)) in strategies.enumerated() {
            os_log("[Auth] SMS login strategy %d/%d: %{public}s:%d (TLS: %d)",
                   log: xmppLog, type: .info, i + 1, strategies.count, host, port, useTLS)
            do {
                try await deps.authRepository.connect(server: host, port: port, useTLS: useTLS, domain: domain)
                try await deps.authRepository.authenticate(jid: credentials.jid, password: credentials.password)
                os_log("[Auth] SMS login connected as %{public}@", log: xmppLog, type: .info,
                       String(credentials.jid.prefix(4)) + "•••@...")
                isLoggedIn = true
                return
            } catch {
                os_log("[Auth] SMS login strategy %d failed: %{public}s",
                       log: xmppLog, type: .error, i + 1, String(describing: error))
                await deps.authRepository.disconnect()
            }
        }
        throw NSError(
            domain: "TigreChat.Auth",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: String(localized: "Could not connect to \(domain). Try again.")]
        )
    }
}
