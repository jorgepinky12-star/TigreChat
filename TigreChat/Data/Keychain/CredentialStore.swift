import Foundation
import Security

/// Almacén de credenciales: contraseña en el Keychain, configuración de
/// conexión (no sensible) en UserDefaults.
struct CredentialStore {
    static let service = "com.tigrechat.credentials"
    static let lastJIDKey = "tigrechat.lastJID"
    static let serverConfigKey = "tigrechat.serverConfig"

    // MARK: - Password (Keychain)

    func savePassword(_ password: String, for jid: String) {
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: jid,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    func loadPassword(for jid: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: jid,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func deletePassword(for jid: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: jid,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Last JID

    var lastJID: String? {
        UserDefaults.standard.string(forKey: Self.lastJIDKey)
    }

    func saveLastJID(_ jid: String) {
        UserDefaults.standard.set(jid, forKey: Self.lastJIDKey)
    }

    func clearLastJID() {
        UserDefaults.standard.removeObject(forKey: Self.lastJIDKey)
    }

    // MARK: - Server config (no sensible)

    func saveServerConfig(_ config: ServerConfig) {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Self.serverConfigKey)
        }
    }

    func loadServerConfig() -> ServerConfig? {
        guard let data = UserDefaults.standard.data(forKey: Self.serverConfigKey) else { return nil }
        return try? JSONDecoder().decode(ServerConfig.self, from: data)
    }
}

/// Configuración de conexión persistida (no sensible -> UserDefaults).
struct ServerConfig: Codable, Sendable {
    var host: String
    var port: Int
    var useTLS: Bool
    var domain: String
}
