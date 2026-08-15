import Foundation

@MainActor
@Observable
final class OTPViewModel {
    var code = ""
    var isLoading = false
    var errorMessage: String?
    private(set) var isVerified = false

    /// Demo-only: the code shown in the banner while there is no backend.
    /// Always nil once `ToDusAuthService` is active (banner disappears).
    private(set) var demoCode: String?

    /// Telegram-style cooldown before the next resend.
    private(set) var resendSecondsRemaining = 0
    let resendCooldown = 30
    private var resendTask: Task<Void, Never>?

    private let service: AuthService
    private let phone: String
    private let onVerified: (AuthCredentials) async throws -> Void

    init(service: AuthService, phone: String, onVerified: @escaping (AuthCredentials) async throws -> Void) {
        self.service = service
        self.phone = phone
        self.onVerified = onVerified
    }

    var isCodeComplete: Bool { code.count == 6 }

    /// Pulls the demo banner code from the service (no-op with a real backend).
    func loadDemoCode() async {
        demoCode = await service.demoCode
    }

    func verify() async {
        guard isCodeComplete, !isLoading, !isVerified else { return }
        isLoading = true
        errorMessage = nil

        do {
            let credentials = try await service.verify(code: code)
            isVerified = true
            do {
                try await onVerified(credentials)
            } catch {
                // La verificación fue correcta pero la conexión XMPP falló:
                // volver al estado editable y mostrar el error real.
                isVerified = false
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? String(localized: "Could not connect to the chat server. Try again.")
                code = ""
            }
        } catch {
            // WhatsApp/Telegram UX: clear the field so the user can retype
            // from scratch after a wrong attempt.
            errorMessage = (error as? SMSAuthError)?.errorDescription
                ?? String(localized: "Something went wrong. Try again.")
            code = ""
        }
        isLoading = false
    }

    func resend() async {
        guard resendSecondsRemaining == 0 else { return }
        do {
            try await service.requestCode(phone: phone)
            demoCode = await service.demoCode
        } catch {
            errorMessage = (error as? SMSAuthError)?.errorDescription
                ?? "Could not resend the code. Try again."
        }
        startResendCountdown()
    }

    isolated deinit {
        resendTask?.cancel()
    }

    private func startResendCountdown() {
        resendTask?.cancel()
        resendSecondsRemaining = resendCooldown
        resendTask = Task { [weak self] in
            while let self, self.resendSecondsRemaining > 0, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self.resendSecondsRemaining -= 1
            }
        }
    }
}
