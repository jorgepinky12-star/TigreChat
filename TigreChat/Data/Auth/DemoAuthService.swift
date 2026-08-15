import Foundation

/// Local stand-in for the SMS backend while it does not exist: generates the
/// code with the CSPRNG, exposes it for the demo banner and validates it with
/// a constant-time comparison. Nothing leaves the device.
///
/// Returns `AuthCredentials.isDemo = true` so the app keeps the flow in demo
/// mode: the router seeds a local roster (`DemoRosterSeeder`) and navigates to
/// the chat list without touching the network. When the real backend lands,
/// `AuthServiceFactory.useDemo = false` replaces this whole actor with
/// `ToDusAuthService` — no other code changes.
actor DemoAuthService: AuthService {
    private let config: AuthServiceConfig
    private var phone = ""
    private(set) var expectedCode: String?

    init(config: AuthServiceConfig) {
        self.config = config
    }

    var demoCode: String? { expectedCode }

    // MARK: - AuthService

    func requestCode(phone: String) async throws {
        self.phone = phone
        expectedCode = OTPCodeGenerator.generate()
    }

    func verify(code: String) async throws -> AuthCredentials {
        guard let expectedCode, constantTimeEquals(expectedCode, code) else {
            throw SMSAuthError.invalidCode
        }
        // DEMO (temporary): no backend provisioning yet, and the real server
        // has no roster for this account, so don't attempt a real connection —
        // the router seeds a local demo roster instead. Resume the real path
        // (which now works: IQDispatcher early-response buffer, connection
        // strategies) by flipping `isDemo` back to false with real
        // credentials, e.g.:
        //   jid: "jorge@ims-brz.z17.cu", password: "s0mePass", isDemo: false
        return AuthCredentials(
            jid: "jorge@ims-brz.z17.cu",
            password: "s0mePass",
            isDemo: true
        )
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
