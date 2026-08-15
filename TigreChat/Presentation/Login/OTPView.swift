import SwiftUI

/// Second step of SMS authentication: enter the 6-digit code in six
/// individual boxes. iOS autofills the code from the SMS via `OneTimeCode`.
struct OTPView: View {
    @State private var viewModel: OTPViewModel
    @FocusState private var focusedDigit: Int?
    let maskedPhone: String

    init(viewModel: OTPViewModel, maskedPhone: String) {
        _viewModel = State(initialValue: viewModel)
        self.maskedPhone = maskedPhone
    }

    var body: some View {
        VStack(spacing: Theme.Layout.spacing20) {
            Spacer()

            Image(systemName: viewModel.isVerified ? "checkmark.circle.fill" : "lock.shield.fill")
                .font(.system(size: 72))
                .foregroundStyle(viewModel.isVerified ? Theme.Colors.success : Theme.Colors.primary)

            Text(viewModel.isVerified ? "Number verified" : "Verification code")
                .font(Theme.Typography.title)

            if !viewModel.isVerified {
                Text("We sent a 6-digit code to \(maskedPhone)")
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            if viewModel.isVerified {
                ProgressView()
                    .tint(Theme.Colors.primary)
                Text("Connecting to your chats…")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Spacer()

            if !viewModel.isVerified {
                VStack(spacing: Theme.Layout.spacing16) {
                    if let demoCode = viewModel.demoCode {
                        Label("Demo — no backend yet. Code: \(demoCode)", systemImage: "wrench.and.screwdriver")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                    }

                    OTPDigitRow(
                        digitCount: 6,
                        code: $viewModel.code,
                        focusedDigit: $focusedDigit,
                        onComplete: {
                            Task { await viewModel.verify() }
                        }
                    )
                    .accessibilityLabel("Verification code")

                    if let error = viewModel.errorMessage {
                        Text(error)
                            .foregroundStyle(Theme.Colors.statusFailed)
                            .font(Theme.Typography.caption)
                    }

                    Button {
                        Task { await viewModel.verify() }
                    } label: {
                        if viewModel.isLoading {
                            ProgressView()
                                .tint(.white)
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Verify")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .primaryButton()
                    .disabled(!viewModel.isCodeComplete || viewModel.isLoading)

                    if viewModel.resendSecondsRemaining > 0 {
                        Text("Resend code in \(viewModel.resendSecondsRemaining)s")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(minHeight: Theme.Layout.minTouchTarget)
                    } else {
                        Button("Resend code") {
                            Task { await viewModel.resend() }
                        }
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.primary)
                        .frame(minHeight: Theme.Layout.minTouchTarget)
                        .contentShape(Rectangle())
                    }
                }
                .padding(.horizontal)
            }

            Spacer()
        }
        .task {
            await viewModel.loadDemoCode()
        }
        .navigationBarBackButtonHidden(viewModel.isVerified)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    focusedDigit = nil
                }
            }
        }
    }
}

/// Row of individual digit boxes with automatic focus advance/retreat,
/// multi-digit paste support and an `onComplete` callback when all boxes
/// are filled (WhatsApp/Telegram behavior).
struct OTPDigitRow: View {
    let digitCount: Int
    @Binding var code: String
    @FocusState.Binding var focusedDigit: Int?
    let onComplete: () -> Void

    @State private var digits: [String]

    init(digitCount: Int, code: Binding<String>, focusedDigit: FocusState<Int?>.Binding, onComplete: @escaping () -> Void) {
        self.digitCount = digitCount
        self._code = code
        self._focusedDigit = focusedDigit
        self.onComplete = onComplete
        _digits = State(initialValue: Array(repeating: "", count: digitCount))
    }

    var body: some View {
        HStack(spacing: Theme.Layout.spacing8) {
            ForEach(0..<digitCount, id: \.self) { index in
                OTPDigitField(
                    index: index,
                    digit: $digits[index],
                    focusedDigit: $focusedDigit,
                    onAdvance: { idx in
                        if idx + 1 < digitCount {
                            focusedDigit = idx + 1
                        } else {
                            focusedDigit = nil
                            syncCode()
                            onComplete()
                        }
                    },
                    onRetreat: { idx in
                        if idx > 0 {
                            focusedDigit = idx - 1
                        }
                    }
                )
            }
        }
        // External reset (e.g. the field is cleared after a wrong attempt).
        .onChange(of: code) { _, newValue in
            if newValue.isEmpty, digits.contains(where: { !$0.isEmpty }) {
                digits = Array(repeating: "", count: digitCount)
                focusedDigit = 0
            }
        }
        // Paste support: a multi-digit paste lands on the first box.
        .onChange(of: digits[0]) { _, newValue in
            guard newValue.count > 1 else { return }
            let chars = Array(newValue.filter(\.isNumber).prefix(digitCount))
            for (offset, char) in chars.enumerated() {
                digits[offset] = String(char)
            }
            focusedDigit = chars.count < digitCount ? chars.count : nil
            syncCode()
            if chars.count == digitCount {
                onComplete()
            }
        }
        .onAppear {
            focusedDigit = 0
        }
    }

    private func syncCode() {
        let joined = digits.joined()
        if joined != code {
            code = joined
        }
    }
}

/// Single digit box: 1 digit max, rounds up to 2 significant figures on
/// focus, non-digit input stripped.
private struct OTPDigitField: View {
    let index: Int
    @Binding var digit: String
    @FocusState.Binding var focusedDigit: Int?
    let onAdvance: (Int) -> Void
    let onRetreat: (Int) -> Void

    private var isFocused: Bool { focusedDigit == index }

    var body: some View {
        TextField("", text: $digit)
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            .focused($focusedDigit, equals: index)
            .multilineTextAlignment(.center)
            .font(.system(size: 28, weight: .bold, design: .rounded))
            .monospacedDigit()
            .frame(width: 52, height: 58)
            .background(
                RoundedRectangle(cornerRadius: Theme.Layout.cornerOTP, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Layout.cornerOTP, style: .continuous)
                    .stroke(
                        isFocused ? Theme.Colors.primary : Color(.separator),
                        lineWidth: isFocused ? 2 : 1
                    )
            )
            .accessibilityLabel("Digit \(index + 1) of 6")
            .onChange(of: digit) { _, newValue in
                // A multi-character value means the user pasted a code:
                // leave it untouched, the row distributes it.
                if newValue.count > 1 { return }
                digit = String(newValue.filter(\.isNumber).prefix(1))
                if !digit.isEmpty {
                    onAdvance(index)
                } else if isFocused, index > 0 {
                    // Retreat only when the user deletes in the active box —
                    // an external reset (wrong code) clears every box and
                    // must not move focus box by box.
                    onRetreat(index)
                }
            }
    }
}
