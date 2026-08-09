import SwiftUI

struct AppRouter: View {
    @State private var isLoggedIn = false
    @Environment(\.dependencies) private var deps

    var body: some View {
        Group {
            if isLoggedIn {
                ChatListView(
                    viewModel: deps.makeChatListViewModel(),
                    isLoggedIn: $isLoggedIn
                )
            } else {
                PhoneLoginView(
                    viewModel: PhoneLoginViewModel(),
                    manualLogin: LoginView(
                        viewModel: deps.makeLoginViewModel(),
                        onLoginSuccess: { isLoggedIn = true }
                    ),
                    onVerified: {
                        // TODO(backend): once the SMS service exists, this hook
                        // provisions the account (JID derived from the verified
                        // number), stores credentials in the Keychain and sets
                        // isLoggedIn = true. Today the flow is view-only.
                    }
                )
                .transition(.opacity)
            }
        }
        .animation(.default, value: isLoggedIn)
    }
}
