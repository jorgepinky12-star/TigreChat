import Foundation
import CryptoKit
import Security
import UIKit

@MainActor final class KeyManager {
    private let service: String
    private let identityTag = "identity"
    private let signedPreKeyTag = "signedprekey"
    private let preKeyPrefix = "prekey"

    private(set) var deviceId: UInt32
    private(set) var identityKeyPair: IdentityKeyPair?
    private(set) var signedPreKey: SignedPreKey?
    private(set) var preKeys: [PreKey] = []

    /// - Parameter deviceId: override para tests (dos dispositivos en un mismo
    ///   proceso); por defecto deriva uno estable del hardware.
    /// - Parameter service: servicio Keychain (los tests lo aíslan por
    ///   dispositivo para no colisionar identidad/prekeys).
    init(deviceId: UInt32? = nil, service: String = "com.tigrechat.omemo") {
        self.service = service
        self.deviceId = deviceId ?? Self.makeStableDeviceId()
        loadOrCreateKeys()
    }

    /// Deriva un deviceId estable entre launches. `hashValue` es aleatorio por
    /// proceso, así que NO se puede usar aquí: un deviceId inestable invalidaría
    /// las sesiones OMEMO del servidor en cada arranque.
    private static func makeStableDeviceId() -> UInt32 {
        guard let vendorId = UIDevice.current.identifierForVendor else {
            return UInt32.random(in: 0..<1_000_000)
        }
        // FNV-1a de 32 bits sobre el UUID: determinista y repartido.
        var hash: UInt32 = 2_166_136_261
        for byte in vendorId.uuidString.utf8 {
            hash ^= UInt32(byte)
            hash &*= 16_777_619
        }
        return hash % 1_000_000
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
        // El wire format OMEMO (SignalProtocolSwift/protobuf y el resto del
        // ecosistema: libsignal, smack-omemo) transporta los ids como int32:
        // un id >= Int32.max desborda y crashea el decode del receptor
        // (PendingPreKey: `Int32(signedPreKeyId)`). Rango 1...Int32.max.
        let id = UInt32.random(in: 1...UInt32(Int32.max))
        let keyAgreementKey = CryptoKit.Curve25519.KeyAgreement.PrivateKey()
        // La identidad se genera en init; este fallback cubre llamadas
        // defensivas (p.ej. rotateSignedPreKey) sin identidad previa.
        let identity = identityKeyPair ?? createIdentity()

        // XEdDSA (curve25519_sign de libsignal), NO Ed25519 de CryptoKit: los
        // clientes OMEMO (Conversations, smack-omemo) verifican la firma del
        // signed prekey convirtiendo la X25519 pública a Edwards; una firma
        // Ed25519 estándar no pasa esa verificación.
        let publicData = keyAgreementKey.publicKey.rawRepresentation
        var random = Data(count: Curve25519.signatureLength)
        random.withUnsafeMutableBytes {
            _ = SecRandomCopyBytes(kSecRandomDefault, Curve25519.signatureLength, $0.baseAddress!)
        }
        if let signature = try? Curve25519.signature(for: publicData, privateKey: identity.privateKey, randomData: random) {
            return SignedPreKey(
                id: id,
                publicKey: publicData,
                privateKey: keyAgreementKey.rawRepresentation,
                signature: signature
            )
        }
        // Inalcanzable con una clave Curve25519 válida: nunca crashear.
        assertionFailure("No se pudo firmar la signed prekey")
        return SignedPreKey(
            id: id,
            publicKey: publicData,
            privateKey: keyAgreementKey.rawRepresentation,
            signature: Data()
        )
    }

    private func createIdentity() -> IdentityKeyPair {
        let key = generateIdentityKey()
        identityKeyPair = key
        saveIdentityKey(key)
        return key
    }

    private func generatePreKeys(count: Int) -> [PreKey] {
        (0..<count).map { _ in
            // Mismo contrato int32 que generateSignedPreKey: ids en 1...Int32.max
            // (0 reserva el "sin prekey" en el wire format).
            let id = UInt32.random(in: 1...UInt32(Int32.max))
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
}
