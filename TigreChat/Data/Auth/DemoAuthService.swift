import Foundation

/// Local stand-in for the SMS backend while it does not exist: generates the
/// code with the CSPRNG, exposes it for the demo banner and validates it with
/// a constant-time comparison. Nothing leaves the device.
///
/// Returns the demo account's real credentials (`jorge@ims-brz.z17.cu`) so the
/// router connects to the actual IM server through the normal path. When the
/// real backend lands, `AuthServiceFactory.useDemo = false` replaces this
/// whole actor with `ToDusAuthService` — no other code changes.
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
        // DEMO (temporary): no backend provisioning yet, so the app connects
        // to the real IM server with the demo account's credentials (the
        // integration pipeline works end-to-end: strategies, STARTTLS,
        // SCRAM, bind, roster, OMEMO). The real backend will return the
        // provisioned account here instead.
        return AuthCredentials(
            jid: "jorge@ims-brz.z17.cu",
            password: "s0mePass",
            isDemo: false
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
