import Foundation

actor XMPPAuthRepository: AuthRepository {
    private let client: XMPPClient
    private let credentialStore = CredentialStore()
    private(set) var isAuthenticated = false
    private(set) var currentJID: String?
    private var host: String = ""
    private var port: Int = 5222
    private var useTLS: Bool = false
    private var domain: String = ""
    private var savedPassword: String = ""

    private var savedJID: String? {
        credentialStore.lastJID
    }

    init(client: XMPPClient) {
        self.client = client
    }

    func connect(server: String, port: Int, useTLS: Bool, domain: String) async throws {
        host = server
        self.port = port
        self.useTLS = useTLS
        self.domain = domain
        credentialStore.saveServerConfig(ServerConfig(host: server, port: port, useTLS: useTLS, domain: domain))
        await client.setup(host: server, port: port, useDirectTLS: useTLS, domain: domain)
        try await client.connect()
    }

    func authenticate(jid: String, password: String) async throws {
        try await client.authenticate(jid: jid, password: password)
        isAuthenticated = true
        currentJID = jid
        savedPassword = password
        credentialStore.savePassword(password, for: jid)
        credentialStore.saveLastJID(jid)
    }

    func disconnect() async {
        await client.disconnect()
        isAuthenticated = false
        currentJID = nil
    }

    func register(jid: String, password: String) async throws {
        await client.setup(host: host, port: port, useDirectTLS: useTLS, domain: domain)
        try await client.connect()
        try await client.authenticate(jid: jid, password: password)
        isAuthenticated = true
        currentJID = jid
        savedPassword = password
        credentialStore.savePassword(password, for: jid)
        credentialStore.saveLastJID(jid)
    }

    func reconnect() async throws {
        guard let jid = currentJID else { return }
        isAuthenticated = false
        try await connect(server: host, port: port, useTLS: useTLS, domain: domain)
        try await authenticate(jid: jid, password: savedPassword)
    }

    /// Reanuda la última sesión guardada (config + credenciales del Keychain).
    func autoLogin() async throws -> Bool {
        guard let jid = savedJID,
              let password = credentialStore.loadPassword(for: jid) else { return false }
        let config = credentialStore.loadServerConfig() ?? ServerConfig(
            host: jid.components(separatedBy: "@").last ?? "",
            port: 5222,
            useTLS: false,
            domain: jid.components(separatedBy: "@").last ?? ""
        )
        try await connect(server: config.host, port: config.port, useTLS: config.useTLS, domain: config.domain)
        try await authenticate(jid: jid, password: password)
        return true
    }

    func logout() async {
        if let jid = currentJID {
            credentialStore.deletePassword(for: jid)
        }
        credentialStore.clearLastJID()
        await disconnect()
    }
}
