import Foundation

@MainActor
@Observable
final class OTPViewModel {
    var code = ""
    var isLoading = false
    var errorMessage: String?
    private(set) var isVerified = false

    /// Code the user must match. Demo-only until the backend exists.
    var expectedCode: String?
    /// Invoked on resend; returns the fresh code (nil if unavailable).
    private let resendCode: () async -> String?

    /// Telegram-style cooldown before the next resend.
    private(set) var resendSecondsRemaining = 0
    let resendCooldown = 30
    private var resendTask: Task<Void, Never>?

    init(expectedCode: String?, resendCode: @escaping () async -> String?) {
        self.expectedCode = expectedCode
        self.resendCode = resendCode
    }

    var isCodeComplete: Bool { code.count == 6 }

    func verify() async {
        guard isCodeComplete, !isLoading, !isVerified else { return }
        guard let expected = expectedCode else {
            errorMessage = "No code was requested"
            return
        }
        isLoading = true
        errorMessage = nil

        // TODO(backend): POST /v1/auth/verify { "phone": ..., "code": ... }
        // The server validates against the hashed OTP (attempts + expiry).
        try? await Task.sleep(for: .milliseconds(600))
        if constantTimeEquals(expected, code) {
            isVerified = true
        } else {
            // WhatsApp/Telegram UX: clear the field so the user can retype
            // from scratch after a wrong attempt.
            errorMessage = "Incorrect code. Try again."
            code = ""
        }
        isLoading = false
    }

    func resend() async {
        guard resendSecondsRemaining == 0 else { return }
        if let newCode = await resendCode() {
            expectedCode = newCode
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

    /// Constant-time string comparison so response timing does not leak
    /// information about the digits (defense in depth; the real check
    /// happens server-side anyway).
    private func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a.utf8, b.utf8) {
            diff |= x ^ y
        }
        return diff == 0
    }
}
