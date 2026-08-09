import Foundation
import Security

/// Generates 6-digit OTP codes using the system CSPRNG (`SecRandomCopyBytes`).
///
/// NOTE: in production the code is generated and hashed server-side (never
/// stored in plain text, TTL + attempts + rate limit). This client-side
/// generator only feeds the login/OTP views until the SMS backend exists —
/// see the `TODO(backend)` markers in the auth flow.
enum OTPCodeGenerator {
    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 4)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess {
            let value = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
            return String(format: "%06d", abs(value) % 1_000_000)
        }
        // Fallback for the extremely rare CSPRNG failure: Darwin's
        // SystemRandomNumberGenerator is backed by arc4random_buf.
        return String(format: "%06d", Int.random(in: 0..<1_000_000))
    }
}
