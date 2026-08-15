import Foundation

/// Backend contract for SMS authentication (toDus-style flow: reserve the
/// phone number, receive a 6-digit code, verify it and get back the XMPP
/// credentials the backend provisioned on the IM server).
///
/// The app never knows the transport details (JSON, protobuf, endpoints...):
/// swap `AuthServiceFactory` when the real backend lands and only
/// `AuthServiceConfig` has to change.
protocol AuthService: Sendable {
    /// Requests a code for `phone` (E.164, e.g. "+5511912345678"). The
    /// backend decides whether the number is new or existing and sends the
    /// code through its delivery channel.
    func requestCode(phone: String) async throws

    /// Verifies `code` and returns the provisioned ejabberd credentials.
    /// Throws `SMSAuthError` on wrong code, rate limit, network failure...
    func verify(code: String) async throws -> AuthCredentials

    /// Demo-only: the code shown in the UI banner while there is no backend.
    /// Always nil with a real backend (banner disappears automatically).
    var demoCode: String? { get async }
}

/// Credentials returned after the OTP is verified: the XMPP account the
/// backend provisioned, ready to feed `XMPPAuthRepository`.
struct AuthCredentials: Sendable, Codable {
    var jid: String
    var password: String
    /// True when the code was verified locally (demo mode, no backend).
    /// The app keeps the flow view-only in that case.
    var isDemo = false
}

/// HTTP/validation errors, mapped from the backend contract (toDus-style).
enum SMSAuthError: LocalizedError, Equatable {
    case invalidCode
    case banned
    case rateLimited
    case certificate
    case network
    case backend(Int)

    var errorDescription: String? {
        switch self {
        case .invalidCode: return String(localized: "Incorrect code. Try again.")
        case .banned: return String(localized: "This number is not allowed.")
        case .rateLimited: return String(localized: "Too many attempts. Try again later.")
        case .certificate: return String(localized: "Could not verify the server certificate.")
        case .network: return String(localized: "Network error. Check your connection and try again.")
        case .backend(let code): return String(localized: "Server error (\(code)). Try again.")
        }
    }
}

/// Single place that describes the SMS backend.
///
/// When the real backend exists, change ONLY this configuration (base URL
/// and endpoint paths) and flip `AuthServiceFactory.useDemo` to `false`.
/// Nothing else in the app needs to know.
struct AuthServiceConfig: Sendable {
    var baseURL: URL
    var reservePath: String
    var registerPath: String
    /// Domain used to build the JID from the verified number: `<digits>@domain`.
    var xmppDomain: String
}

enum AuthServiceFactory {
    /// TODO(backend): the real backend is still pending. It will mirror the
    /// toDus protocol (reserve -> SMS -> register), JSON over HTTPS.
    /// Point this at the real host when it exists.
    static let config = AuthServiceConfig(
        baseURL: URL(string: "https://auth.example.invalid")!,
        reservePath: "v2/auth/users.reserve",
        registerPath: "v2/auth/users.register",
        xmppDomain: "ims-brz.z17.cu"
    )

    /// Demo until the backend exists: codes are generated locally and shown
    /// in a banner; nothing is sent over the network. Flip to `false` when
    /// the backend is live — that is the only switch needed.
    static let useDemo = true

    static func make() -> AuthService {
        useDemo ? DemoAuthService(config: config) : ToDusAuthService(config: config)
    }
}
