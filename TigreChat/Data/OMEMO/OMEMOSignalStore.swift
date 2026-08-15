import Foundation
import Security

/// Dirección Signal de un dispositivo remoto: (bare JID, deviceId).
struct OMEMOAddress: Hashable, CustomStringConvertible {
    let jid: String
    let deviceId: UInt32

    var description: String {
        "\(jid) (\(deviceId))"
    }
}

/// Implementación de `KeyStore` (SignalProtocolSwift) sobre los MISMO items de
/// Keychain que `KeyManager` publica al servidor:
///
/// - identidad: `identity`          = private key Curve25519 raw (32 bytes)
/// - signed prekey: `signedprekey`  = id (4 LE) + private (32) + signature (64)
/// - prekeys: `prekey`              = [id (4 LE) + private (32)]... repetidos
///
/// Sesiones y identidades remotas usan items propios:
/// - `sigsession_<jid>_<dev>`       = SessionRecord protobuf (Signal_Record)
/// - `sigidentity_<jid>_<dev>`      = public key remota raw (32 bytes)
///
/// Al compartir los blobs con `KeyManager`, el publish del bundle y el consumo
/// de prekeys del protocolo quedan en el mismo estado sin doble persistencia.
final class OMEMOSignalStore: KeyStore, @unchecked Sendable {
    typealias Address = OMEMOAddress
    typealias IdentityKeyStoreType = OMEMOIdentityKeyStore
    typealias SessionStoreType = OMEMOSessionDataStore

    var identityKeyStore: OMEMOIdentityKeyStore
    var preKeyStore: PreKeyStore
    var signedPreKeyStore: SignedPreKeyStore
    var sessionStore: OMEMOSessionDataStore

    /// El `service` Keychain y el dominio UserDefaults se inyectan para que los
    /// tests puedan simular DOS dispositivos OMEMO en el mismo proceso sin
    /// colisionar identidad/prekeys/sesiones.
    init(service: String = KeychainBlobs.service, userDefaults: UserDefaults = .standard) {
        identityKeyStore = OMEMOIdentityKeyStore(service: service)
        preKeyStore = OMEMOPreKeyStore(service: service, userDefaults: userDefaults)
        signedPreKeyStore = OMEMOSignedPreKeyStore(service: service, userDefaults: userDefaults)
        sessionStore = OMEMOSessionDataStore(service: service)
    }
}

// MARK: - Identity

final class OMEMOIdentityKeyStore: IdentityKeyStore, @unchecked Sendable {
    typealias Address = OMEMOAddress

    private let service: String
    private let identityTag = "identity"

    init(service: String = KeychainBlobs.service) {
        self.service = service
    }

    func getIdentityKeyData() throws -> Data {
        guard let privateData = KeychainBlobs.load(tag: identityTag, service: service) else {
            throw SignalError(.storageError, "No local identity key")
        }
        guard let publicData = try? Curve25519.publicKey(for: privateData) else {
            throw SignalError(.storageError, "Invalid local identity key")
        }
        let pair = KeyPair(
            publicKey: try PublicKey(from: publicData),
            privateKey: try PrivateKey(from: privateData)
        )
        return try pair.protoData()
    }

    func identity(for address: Address) throws -> Data? {
        KeychainBlobs.load(tag: Self.remoteTag(for: address), service: service)
    }

    func store(identity: Data?, for address: Address) throws {
        let tag = Self.remoteTag(for: address)
        if let identity {
            KeychainBlobs.save(data: identity, tag: tag, service: service)
        } else {
            KeychainBlobs.delete(tag: tag, service: service)
        }
    }

    private static func remoteTag(for address: Address) -> String {
        "sigidentity_\(address.jid)_\(address.deviceId)"
    }
}

// MARK: - Prekeys

final class OMEMOPreKeyStore: PreKeyStore, @unchecked Sendable {
    private let service: String
    private let userDefaults: UserDefaults
    private let preKeyTag = "prekey"
    private let lastIdKey = "omemo_prekey_last_id"

    init(service: String = KeychainBlobs.service, userDefaults: UserDefaults = .standard) {
        self.service = service
        self.userDefaults = userDefaults
    }

    func preKey(for id: UInt32) throws -> Data {
        guard let entry = loadPreKeys().first(where: { $0.id == id }) else {
            throw SignalError(.invalidId, "No prekey for id \(id)")
        }
        let pair = KeyPair(
            publicKey: try PublicKey(from: entry.publicKey),
            privateKey: try PrivateKey(from: entry.privateKey)
        )
        return try SessionPreKey(id: id, keyPair: pair).protoData()
    }

    func store(preKey: Data, for id: UInt32) throws {
        var keys = loadPreKeys()
        guard let record = try? SessionPreKey(from: preKey) else {
            throw SignalError(.storageError, "Invalid prekey record")
        }
        keys.removeAll { $0.id == id }
        keys.append(PreKeyEntry(id: id, publicKey: record.keyPair.publicKey.data, privateKey: record.keyPair.privateKey.data))
        savePreKeys(keys)
    }

    func containsPreKey(for id: UInt32) -> Bool {
        loadPreKeys().contains { $0.id == id }
    }

    func removePreKey(for id: UInt32) throws {
        var keys = loadPreKeys()
        keys.removeAll { $0.id == id }
        savePreKeys(keys)
    }

    var lastId: UInt32 {
        get { UInt32(userDefaults.integer(forKey: lastIdKey)) }
        set { userDefaults.set(newValue, forKey: lastIdKey) }
    }

    private struct PreKeyEntry {
        let id: UInt32
        let publicKey: Data
        let privateKey: Data
    }

    private func loadPreKeys() -> [PreKeyEntry] {
        guard let data = KeychainBlobs.load(tag: preKeyTag, service: service) else { return [] }
        var entries: [PreKeyEntry] = []
        var offset = 0
        while offset + 36 <= data.count {
            let id = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self) }
            offset += MemoryLayout<UInt32>.size
            let privateData = Data(data[offset..<offset + 32])
            offset += 32
            guard let publicData = try? Curve25519.publicKey(for: privateData) else { continue }
            entries.append(PreKeyEntry(id: id, publicKey: publicData, privateKey: privateData))
        }
        return entries
    }

    private func savePreKeys(_ keys: [PreKeyEntry]) {
        var data = Data()
        for key in keys {
            data.append(withUnsafeBytes(of: key.id) { Data($0) })
            data.append(key.privateKey)
        }
        KeychainBlobs.save(data: data, tag: preKeyTag, service: service)
    }
}

// MARK: - Signed prekey

final class OMEMOSignedPreKeyStore: SignedPreKeyStore, @unchecked Sendable {
    private let service: String
    private let userDefaults: UserDefaults
    private let signedPreKeyTag = "signedprekey"
    private let lastIdKey = "omemo_spk_last_id"

    init(service: String = KeychainBlobs.service, userDefaults: UserDefaults = .standard) {
        self.service = service
        self.userDefaults = userDefaults
    }

    func signedPreKey(for id: UInt32) throws -> Data {
        guard let entry = loadSignedPreKey(), entry.id == id else {
            throw SignalError(.invalidId, "No signed prekey for id \(id)")
        }
        let pair = KeyPair(
            publicKey: try PublicKey(from: entry.publicKey),
            privateKey: try PrivateKey(from: entry.privateKey)
        )
        return try SessionSignedPreKey(id: entry.id, timestamp: 0, keyPair: pair, signature: entry.signature).protoData()
    }

    func store(signedPreKey: Data, for id: UInt32) throws {
        guard let record = try? SessionSignedPreKey(from: signedPreKey) else {
            throw SignalError(.storageError, "Invalid signed prekey record")
        }
        saveSignedPreKey(id: id, publicKey: record.keyPair.publicKey.data, privateKey: record.keyPair.privateKey.data, signature: record.publicKey.signature)
    }

    func containsSignedPreKey(for id: UInt32) throws -> Bool {
        loadSignedPreKey()?.id == id
    }

    func removeSignedPreKey(for id: UInt32) throws {
        if loadSignedPreKey()?.id == id {
            KeychainBlobs.delete(tag: signedPreKeyTag, service: service)
        }
    }

    func allIds() throws -> [UInt32] {
        loadSignedPreKey().map { [$0.id] } ?? []
    }

    var lastId: UInt32 {
        get { UInt32(userDefaults.integer(forKey: lastIdKey)) }
        set { userDefaults.set(newValue, forKey: lastIdKey) }
    }

    private struct SignedPreKeyEntry {
        let id: UInt32
        let publicKey: Data
        let privateKey: Data
        let signature: Data
    }

    private func loadSignedPreKey() -> SignedPreKeyEntry? {
        guard let data = KeychainBlobs.load(tag: signedPreKeyTag, service: service), data.count >= 4 + 32 + 64 else { return nil }
        let id = data.withUnsafeBytes { $0.load(as: UInt32.self) }
        let privateData = Data(data[4..<36])
        let signature = Data(data[36..<100])
        guard let publicData = try? Curve25519.publicKey(for: privateData) else { return nil }
        return SignedPreKeyEntry(id: id, publicKey: publicData, privateKey: privateData, signature: signature)
    }

    private func saveSignedPreKey(id: UInt32, publicKey: Data, privateKey: Data, signature: Data) {
        var data = Data()
        data.append(withUnsafeBytes(of: id) { Data($0) })
        data.append(privateKey)
        data.append(signature)
        KeychainBlobs.save(data: data, tag: signedPreKeyTag, service: service)
    }
}

// MARK: - Sessions

final class OMEMOSessionDataStore: SessionStore, @unchecked Sendable {
    typealias Address = OMEMOAddress

    private let service: String

    init(service: String = KeychainBlobs.service) {
        self.service = service
    }

    func loadSession(for address: Address) throws -> Data? {
        KeychainBlobs.load(tag: Self.tag(for: address), service: service)
    }

    func store(session: Data, for address: Address) throws {
        KeychainBlobs.save(data: session, tag: Self.tag(for: address), service: service)
    }

    func containsSession(for address: Address) -> Bool {
        KeychainBlobs.load(tag: Self.tag(for: address), service: service) != nil
    }

    func deleteSession(for address: Address) throws {
        KeychainBlobs.delete(tag: Self.tag(for: address), service: service)
    }

    private static func tag(for address: Address) -> String {
        "sigsession_\(address.jid)_\(address.deviceId)"
    }
}

// MARK: - Keychain primitives (mismo service que KeyManager)

enum KeychainBlobs {
    static let service = "com.tigrechat.omemo"

    static func save(data: Data, tag: String, service: String = Self.service) {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tag,
        ]
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let updates: [String: Any] = [kSecValueData as String: data]
            SecItemUpdate(baseQuery as CFDictionary, updates as CFDictionary)
        }
    }

    static func load(tag: String, service: String = Self.service) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tag,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return status == errSecSuccess ? result as? Data : nil
    }

    static func delete(tag: String, service: String = Self.service) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tag,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
