//
//  TURNConfig.swift
//  TigreChat
//
//  T-VOIPCALLS-052 (GREEN): configuración TURN/STUN para WebRTC.
//  Host/port en UserDefaults, username/password en Keychain.
//  REQ-CONFIG-002 (host-only sin credenciales = rollback limpio).
//

import Foundation

/// Estado de la configuración TURN.
enum TURNConfigStatus: Sendable, Equatable {
    case hostOnly          // sin credenciales TURN — solo candidatos host/srflx
    case ready             // credenciales TURN completas
    case failed(String)    // configuración inválida

    static func == (lhs: TURNConfigStatus, rhs: TURNConfigStatus) -> Bool {
        switch (lhs, rhs) {
        case (.hostOnly, .hostOnly), (.ready, .ready): return true
        case (.failed(let a), .failed(let b)): return a == b
        default: return false
        }
    }
}

/// Configuración TURN/STUN inyectable al engine WebRTC.
struct TURNConfig: Sendable {
    let stunHost: String
    let stunPort: UInt16
    let turnHost: String?
    let turnPort: UInt16?
    let username: String?
    let credential: String?

    var status: TURNConfigStatus {
        guard let turnHost, let turnPort, let username, let credential,
              !turnHost.isEmpty, !username.isEmpty, !credential.isEmpty else {
            return .hostOnly
        }
        return .ready
    }

    /// Servidor STUN siempre presente (candidatos host/srflx).
    var stunURL: String { "stun:\(stunHost):\(stunPort)" }

    /// Servidor TURN solo si hay credenciales.
    var turnURL: String? {
        guard case .ready = status, let turnHost, let turnPort else { return nil }
        return "turn:\(turnHost):\(turnPort)"
    }

    static let defaultHostOnly = TURNConfig(
        stunHost: "stun.l.google.com",
        stunPort: 19302,
        turnHost: nil,
        turnPort: nil,
        username: nil,
        credential: nil
    )
}

/// Almacén persistente de credenciales TURN.
@MainActor
final class TURNCredentialStore {
    private let defaults: UserDefaults
    private let service = "com.tigrechat.turn"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - UserDefaults (host/port)

    var turnHost: String? {
        get { defaults.string(forKey: "turn_host") }
        set { defaults.set(newValue, forKey: "turn_host") }
    }

    var turnPort: UInt16? {
        get { defaults.object(forKey: "turn_port") as? UInt16 }
        set { defaults.set(newValue, forKey: "turn_port") }
    }

    var stunHost: String {
        get { defaults.string(forKey: "stun_host") ?? "stun.l.google.com" }
        set { defaults.set(newValue, forKey: "stun_host") }
    }

    var stunPort: UInt16 {
        get { defaults.object(forKey: "stun_port") as? UInt16 ?? 19302 }
        set { defaults.set(newValue, forKey: "stun_port") }
    }

    // MARK: - Keychain (username/password)

    var username: String? {
        get { loadFromKeychain(key: "username") }
        set {
            if let newValue { saveToKeychain(key: "username", value: newValue) }
            else { deleteFromKeychain(key: "username") }
        }
    }

    var credential: String? {
        get { loadFromKeychain(key: "credential") }
        set {
            if let newValue { saveToKeychain(key: "credential", value: newValue) }
            else { deleteFromKeychain(key: "credential") }
        }
    }

    // MARK: - API

    func loadConfig() -> TURNConfig {
        TURNConfig(
            stunHost: stunHost,
            stunPort: stunPort,
            turnHost: turnHost,
            turnPort: turnPort,
            username: username,
            credential: credential
        )
    }

    func clear() {
        turnHost = nil
        turnPort = nil
        username = nil
        credential = nil
        defaults.removeObject(forKey: "turn_host")
        defaults.removeObject(forKey: "turn_port")
    }

    // MARK: - Keychain helpers

    private func saveToKeychain(key: String, value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)

        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(attrs as CFDictionary, nil)
    }

    private func loadFromKeychain(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteFromKeychain(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
