import SwiftUI

/// First step of SMS authentication (WhatsApp/Telegram style): enter the
/// phone number. The JID will derive from this number once the backend
/// provisions the account on ejabberd.
struct PhoneLoginView: View {
    @State private var viewModel: PhoneLoginViewModel
    @State private var showOTP = false
    @State private var showManualLogin = false
    @FocusState private var isPhoneFieldFocused: Bool

    /// Classic JID/password login, kept reachable until SMS auth is live.
    let manualLogin: LoginView
    /// Called after the OTP is verified (backend wiring still pending).
    let onVerified: () -> Void

    init(viewModel: PhoneLoginViewModel, manualLogin: LoginView, onVerified: @escaping () -> Void) {
        _viewModel = State(initialValue: viewModel)
        self.manualLogin = manualLogin
        self.onVerified = onVerified
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.Layout.spacing20) {
                Spacer()

                Image(systemName: "message.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.tint)

                Text("TigreChat")
                    .font(Theme.Typography.largeTitle)

                Text("Enter your phone number to get started")
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

                HStack(spacing: Theme.Layout.spacing8) {
                    Menu {
                        ForEach(CountryCode.allCases) { country in
                            Button {
                                viewModel.selectedCountry = country
                            } label: {
                                Text("\(country.name)  \(country.prefix)")
                            }
                        }
                    } label: {
                        Text(viewModel.selectedCountry.prefix)
                            .font(Theme.Typography.headline)
                            .monospacedDigit()
                            .frame(minWidth: 72, minHeight: Theme.Layout.minTouchTarget)
                            .capsuleField()
                    }
                    .accessibilityLabel(
                        "Country code: \(viewModel.selectedCountry.name) \(viewModel.selectedCountry.prefix)"
                    )

                    TextField("Phone number", text: $viewModel.phoneNumber)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                        .autocorrectionDisabled()
                        .focused($isPhoneFieldFocused)
                        .frame(minHeight: Theme.Layout.minTouchTarget)
                        .capsuleField()
                        .onChange(of: viewModel.phoneNumber) { _, newValue in
                            let filtered = String(newValue.filter(\.isNumber).prefix(15))
                            if filtered != newValue {
                                viewModel.phoneNumber = filtered
                            }
                        }
                }
                .padding(.horizontal)

                if let error = viewModel.errorMessage {
                    Text(error)
                        .foregroundStyle(Theme.Colors.statusFailed)
                        .font(Theme.Typography.caption)
                }

                Button {
                    Task {
                        await viewModel.requestCode()
                        if viewModel.generatedCode != nil {
                            showOTP = true
                        }
                    }
                } label: {
                    if viewModel.isLoading {
                        ProgressView()
                            .tint(.white)
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Continue")
                            .frame(maxWidth: .infinity)
                    }
                }
                .primaryButton()
                .padding(.horizontal)
                .disabled(viewModel.isLoading || viewModel.fullNumber.count < 8)

                Button("Already have an account? Connect manually") {
                    showManualLogin = true
                }
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
                .frame(minHeight: Theme.Layout.minTouchTarget)
                .contentShape(Rectangle())
                .padding(.top, Theme.Layout.spacing8)

                Spacer()
            }
            .navigationDestination(isPresented: $showOTP) {
                OTPView(
                    viewModel: OTPViewModel(
                        expectedCode: viewModel.generatedCode,
                        resendCode: {
                            await viewModel.requestCode()
                            return viewModel.generatedCode
                        }
                    ),
                    maskedPhone: viewModel.maskedPhone ?? viewModel.fullNumber,
                    onVerified: onVerified
                )
            }
            .sheet(isPresented: $showManualLogin) {
                manualLogin
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        isPhoneFieldFocused = false
                    }
                }
            }
        }
    }
}
