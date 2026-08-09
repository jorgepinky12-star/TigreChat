import Foundation
import CryptoKit
import Security
import UIKit

@MainActor final class KeyManager {
    private let service = "com.tigrechat.omemo"
    private let identityTag = "identity"
    private let signedPreKeyTag = "signedprekey"
    private let preKeyPrefix = "prekey"
    private let sessionPrefix = "session"

    private(set) var deviceId: UInt32
    private(set) var identityKeyPair: IdentityKeyPair?
    private(set) var signedPreKey: SignedPreKey?
    private(set) var preKeys: [PreKey] = []

    init() {
        deviceId = UInt32(abs(UIDevice.current.identifierForVendor?.hashValue ?? Int.random(in: 0..<Int.max)) % 1_000_000)
        identityKeyPair = nil
        loadOrCreateKeys()
    }

    // MARK: - Key Generation

    private func loadOrCreateKeys() {
        if let existing = loadIdentityKey() {
            identityKeyPair = existing
        } else {
            let newKeys = generateIdentityKey()
            saveIdentityKey(newKeys)
            identityKeyPair = newKeys
        }

        if let existing = loadSignedPreKey() {
            signedPreKey = existing
        } else {
            let newKey = generateSignedPreKey()
            saveSignedPreKey(newKey)
            signedPreKey = newKey
        }

        preKeys = loadPreKeys()
        if preKeys.isEmpty {
            preKeys = generatePreKeys(count: 100)
            savePreKeys(preKeys)
        }
    }

    func rotateSignedPreKey() {
        let newKey = generateSignedPreKey()
        saveSignedPreKey(newKey)
        signedPreKey = newKey
    }

    func consumePreKey(id: UInt32) -> PreKey? {
        guard let index = preKeys.firstIndex(where: { $0.id == id }) else { return nil }
        let key = preKeys.remove(at: index)
        savePreKeys(preKeys)
        return key
    }

    // MARK: - Key Generation Primitives

    private func generateIdentityKey() -> IdentityKeyPair {
        let privateKey = CryptoKit.Curve25519.KeyAgreement.PrivateKey()
        let publicKeyData = privateKey.publicKey.rawRepresentation
        let privateKeyData = privateKey.rawRepresentation
        return IdentityKeyPair(publicKey: publicKeyData, privateKey: privateKeyData)
    }

    private func generateSignedPreKey() -> SignedPreKey {
        let id = UInt32.random(in: 0..<UInt32.max)
        let keyAgreementKey = CryptoKit.Curve25519.KeyAgreement.PrivateKey()
        let signingKey = try? CryptoKit.Curve25519.Signing.PrivateKey(rawRepresentation: identityKeyPair!.privateKey)
        let signature = try! signingKey!.signature(for: keyAgreementKey.publicKey.rawRepresentation)
        return SignedPreKey(
            id: id,
            publicKey: keyAgreementKey.publicKey.rawRepresentation,
            privateKey: keyAgreementKey.rawRepresentation,
            signature: signature
        )
    }

    private func generatePreKeys(count: Int) -> [PreKey] {
        (0..<count).map { _ in
            let id = UInt32.random(in: 0..<UInt32.max)
            let key = CryptoKit.Curve25519.KeyAgreement.PrivateKey()
            return PreKey(id: id, publicKey: key.publicKey.rawRepresentation, privateKey: key.rawRepresentation)
        }
    }

    // MARK: - Keychain Storage

    private func saveIdentityKey(_ key: IdentityKeyPair) {
        saveKeychain(data: key.privateKey, tag: identityTag)
    }

    private func loadIdentityKey() -> IdentityKeyPair? {
        guard let privateData = loadKeychain(tag: identityTag) else { return nil }
        guard let privateKey = try? CryptoKit.Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateData) else { return nil }
        return IdentityKeyPair(publicKey: privateKey.publicKey.rawRepresentation, privateKey: privateData)
    }

    private func saveSignedPreKey(_ key: SignedPreKey) {
        var data = Data()
        data.append(withUnsafeBytes(of: key.id) { Data($0) })
        data.append(key.privateKey)
        data.append(key.signature)
        saveKeychain(data: data, tag: signedPreKeyTag)
    }

    private func loadSignedPreKey() -> SignedPreKey? {
        guard let data = loadKeychain(tag: signedPreKeyTag) else { return nil }
        var offset = 0
        let id = data.withUnsafeBytes { $0.load(as: UInt32.self) }
        offset += MemoryLayout<UInt32>.size
        let privateKeyData = data[offset..<offset+32]
        offset += 32
        let signature = data[offset..<offset+64]
        guard let publicKey = try? CryptoKit.Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyData) else { return nil }
        return SignedPreKey(id: id, publicKey: publicKey.publicKey.rawRepresentation, privateKey: privateKeyData, signature: Data(signature))
    }

    private func savePreKeys(_ keys: [PreKey]) {
        var data = Data()
        for key in keys {
            data.append(withUnsafeBytes(of: key.id) { Data($0) })
            data.append(key.privateKey)
        }
        saveKeychain(data: data, tag: preKeyPrefix)
    }

    private func loadPreKeys() -> [PreKey] {
        guard let data = loadKeychain(tag: preKeyPrefix) else { return [] }
        var keys: [PreKey] = []
        var offset = 0
        while offset + 36 <= data.count {
            let id = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self) }
            offset += MemoryLayout<UInt32>.size
            let privateKeyData = data[offset..<offset+32]
            offset += 32
            guard let publicKey = try? CryptoKit.Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyData) else { continue }
            keys.append(PreKey(id: id, publicKey: publicKey.publicKey.rawRepresentation, privateKey: Data(privateKeyData)))
        }
        return keys
    }

    // MARK: - Session Storage

    func saveSession(jid: String, deviceId: UInt32, state: OMEMOSessionState) {
        let data = try? JSONEncoder().encode(state)
        saveKeychain(data: data ?? Data(), tag: "\(sessionPrefix)_\(jid)_\(deviceId)")
    }

    func loadSession(jid: String, deviceId: UInt32) -> OMEMOSessionState? {
        guard let data = loadKeychain(tag: "\(sessionPrefix)_\(jid)_\(deviceId)") else { return nil }
        return try? JSONDecoder().decode(OMEMOSessionState.self, from: data)
    }

    func deleteSession(jid: String, deviceId: UInt32) {
        deleteKeychain(tag: "\(sessionPrefix)_\(jid)_\(deviceId)")
    }

    // MARK: - Keychain Primitives

    private func saveKeychain(data: Data, tag: String) {
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

    private func loadKeychain(tag: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tag,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            return nil
        }
    }

    private func deleteKeychain(tag: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tag,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
