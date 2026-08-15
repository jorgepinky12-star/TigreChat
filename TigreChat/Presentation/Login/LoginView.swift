import SwiftUI

struct LoginView: View {
    @State private var viewModel: LoginViewModel
    let onLoginSuccess: () -> Void

    init(viewModel: LoginViewModel, onLoginSuccess: @escaping () -> Void) {
        _viewModel = State(initialValue: viewModel)
        self.onLoginSuccess = onLoginSuccess
    }

    var body: some View {
        VStack(spacing: Theme.Layout.spacing20) {
            Spacer()

            Image(systemName: "message.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.tint)

            Text("TigreChat")
                .font(Theme.Typography.largeTitle)

            Text("Connect to your XMPP server")
                .font(Theme.Typography.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            VStack(spacing: Theme.Layout.spacing16) {
                TextField("Server (optional)", text: $viewModel.server)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .textFieldStyle(.roundedBorder)

                TextField("JID (user@domain)", text: $viewModel.jid)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.emailAddress)

                SecureField("Password", text: $viewModel.password)
                    .textContentType(.password)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal)

            if let error = viewModel.errorMessage {
                Text(error)
                    .foregroundStyle(Theme.Colors.statusFailed)
                    .font(Theme.Typography.caption)
            }

            Button {
                Task { await viewModel.login() }
            } label: {
                if viewModel.isLoading {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Connect")
                        .frame(maxWidth: .infinity)
                }
            }
            .primaryButton()
            .padding(.horizontal)
            .disabled(viewModel.isLoading)

            Spacer()
        }
        .onChange(of: viewModel.isLoggedIn) { _, loggedIn in
            if loggedIn { onLoginSuccess() }
        }
        .task {
            // WU6: reanudar la última sesión guardada en el Keychain.
            await viewModel.autoLogin()
        }
    }
}
