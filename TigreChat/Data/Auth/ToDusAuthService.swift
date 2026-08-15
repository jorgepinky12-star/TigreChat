import Foundation
import os
import Security

/// Real backend client speaking the toDus-style protocol over HTTPS/JSON:
///
///   POST {base}/{reservePath}   body { "username": "<digits>", "clientToken": "<150 alnum>" }
///                               -> 200 empty (the server sends the code)
///   POST {base}/{registerPath}  body { "username": "<digits>", "clientToken": "<same>", "code": "<6 digits>" }
///                               -> { "passwd": "...", "protoUserReserve": { "username": ... } }
///
/// `username` is the phone number WITHOUT the "+" (e.g. "5511912345678").
/// The `clientToken` must be identical across reserve and register; it is
/// generated cryptographically when the code is requested and reused on
/// verify (same contract as toDus).
actor ToDusAuthService: AuthService {
    private let config: AuthServiceConfig
    private var username = ""
    private var clientToken = ""

    private static let log = OSLog(subsystem: "com.tigrechat", category: "Auth")

    init(config: AuthServiceConfig) {
        self.config = config
    }

    var demoCode: String? { nil }

    // MARK: - AuthService

    func requestCode(phone: String) async throws {
        username = phone.filter(\.isNumber)
        clientToken = Self.generateClientToken()
        os_log("[Auth] reserve %{public}@ (%d)", log: Self.log, type: .info,
               String(username.prefix(4)) + "•••", username.count)
        let body = ReserveRequest(username: username, clientToken: clientToken)
        try await post(path: config.reservePath, body: body)
    }

    func verify(code: String) async throws -> AuthCredentials {
        let body = RegisterRequest(username: username, clientToken: clientToken, code: code)
        let response: RegisterResponse = try await post(path: config.registerPath, body: body)
        let accountName = response.protoUserReserve?.username ?? username
        let credentials = AuthCredentials(
            jid: "\(accountName)@\(config.xmppDomain)",
            password: response.passwd
        )
        os_log("[Auth] register OK for %{public}@", log: Self.log, type: .info,
               String(accountName.prefix(4)) + "•••")
        return credentials
    }

    // MARK: - Transport

    private struct ReserveRequest: Encodable {
        let username: String
        let clientToken: String
    }

    private struct RegisterRequest: Encodable {
        let username: String
        let clientToken: String
        let code: String
    }

    private struct RegisterResponse: Decodable {
        let passwd: String
        let protoUserReserve: UserReserve?

        struct UserReserve: Decodable {
            let username: String?
            let alias: String?
            let pictureUrl: String?
            let description: String?
            let version: Int?
            let toDusId: String?
        }
    }

    private func post<Body: Encodable>(path: String, body: Body) async throws {
        var request = makeRequest(path: path)
        request.httpBody = try JSONEncoder().encode(body)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SMSAuthError.network }
        try Self.throwIfNeeded(http.statusCode)
    }

    private func post<Body: Encodable, Response: Decodable>(path: String, body: Body) async throws -> Response {
        var request = makeRequest(path: path)
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SMSAuthError.network }
        try Self.throwIfNeeded(http.statusCode)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func makeRequest(path: String) -> URLRequest {
        var request = URLRequest(url: config.baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        return request
    }

    /// Maps the backend status codes to SMSAuthError (toDus contract):
    /// 404 -> wrong code, 418 -> banned, 429 -> rate limited,
    /// 508 -> certificate problem, anything else -> server error.
    private static func throwIfNeeded(_ status: Int) throws {
        switch status {
        case 200..<300: return
        case 404: throw SMSAuthError.invalidCode
        case 418: throw SMSAuthError.banned
        case 429: throw SMSAuthError.rateLimited
        case 508: throw SMSAuthError.certificate
        default: throw SMSAuthError.backend(status)
        }
    }

    // MARK: - clientToken (toDus contract: 150 alphanumeric chars)

    private static func generateClientToken() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var bytes = [UInt8](repeating: 0, count: 150)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            // Never expected; keeps the flow alive if the RNG fails.
            return String((0..<150).map { _ in alphabet.randomElement()! })
        }
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }
}
