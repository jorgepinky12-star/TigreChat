import Foundation

enum AuthError: Error, Sendable {
    case invalidCredentials
    case connectionFailed
    case serverError(String)
    case notConnected
    case saslError(String)
    case tlsError(String)
}

protocol AuthRepository: Sendable {
    func connect(server: String, port: Int, useTLS: Bool, domain: String) async throws
    func authenticate(jid: String, password: String) async throws
    func disconnect() async
    func register(jid: String, password: String) async throws
    /// Reanuda la última sesión guardada (Keychain + config persistida).
    func autoLogin() async throws -> Bool
    /// Desconecta y borra las credenciales guardadas.
    func logout() async
}
