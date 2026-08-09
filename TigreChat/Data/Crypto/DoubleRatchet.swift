import Foundation
import CryptoKit

actor DoubleRatchet {
    struct RatchetState: Sendable {
        var rootKey: Data
        var sendingChainKey: Data
        var receivingChainKey: Data?
        var sendingDHKeyPair: DHKeyPair
        var receivingDHPublicKey: Data?
        var sendingChainIndex: UInt32 = 0
        var receivingChainIndex: UInt32 = 0
        var previousSendingChainKey: Data?
    }

    static func initializeAsAlice(sharedSecret: Data, bobSignedPreKey: Data, bobRatchetKey: Data) async throws -> RatchetState {
        let dhRoot = sharedSecret
        let aliceDH = CryptoKit.Curve25519.KeyAgreement.PrivateKey()
        let aliceDHPublic = aliceDH.publicKey.rawRepresentation
        let bobRatchetPub = try CryptoKit.Curve25519.KeyAgreement.PublicKey(rawRepresentation: bobRatchetKey)

        let sharedSecret = try aliceDH.sharedSecretFromKeyAgreement(with: bobRatchetPub)
        let sharedSecretData = sharedSecret.withUnsafeBytes { Data($0) }
        let rootKey = deriveKey(secret: dhRoot, salt: "OMEMO Root".data(using: .utf8)!, info: "OMEMO Root Key")
        let chainKey = deriveKey(secret: sharedSecretData, salt: rootKey, info: "OMEMO Chain Key")

        return RatchetState(
            rootKey: rootKey,
            sendingChainKey: chainKey,
            receivingChainKey: nil,
            sendingDHKeyPair: DHKeyPair(publicKey: aliceDHPublic, privateKey: aliceDH.rawRepresentation),
            receivingDHPublicKey: bobRatchetKey
        )
    }

    static func initializeAsBob(sharedSecret: Data, aliceRatchetKey: Data, bobRatchetKey: CryptoKit.Curve25519.KeyAgreement.PrivateKey) async throws -> RatchetState {
        let aliceRatchetPub = try CryptoKit.Curve25519.KeyAgreement.PublicKey(rawRepresentation: aliceRatchetKey)
        let sharedSecret = try bobRatchetKey.sharedSecretFromKeyAgreement(with: aliceRatchetPub)
        let sharedSecretData = sharedSecret.withUnsafeBytes { Data($0) }
        let rootKey = deriveKey(secret: sharedSecretData, salt: "OMEMO Root".data(using: .utf8)!, info: "OMEMO Root Key")
        let chainKey = deriveKey(secret: sharedSecretData, salt: rootKey, info: "OMEMO Chain Key")

        return RatchetState(
            rootKey: rootKey,
            sendingChainKey: Data(),
            receivingChainKey: chainKey,
            sendingDHKeyPair: DHKeyPair(publicKey: Data(), privateKey: Data()),
            receivingDHPublicKey: aliceRatchetKey
        )
    }

    static func encrypt(state: inout RatchetState, plaintext: Data, ad: Data) async throws -> (ciphertext: Data, ratchetKey: Data) {
        let messageKey = deriveKey(secret: state.sendingChainKey, salt: "OMEMO Message".data(using: .utf8)!, info: "OMEMO Msg Key")
        state.sendingChainKey = deriveKey(secret: state.sendingChainKey, salt: "OMEMO Chain".data(using: .utf8)!, info: "OMEMO Next Chain")

        let iv = messageKey[..<12]
        let encryptionKey = messageKey[12..<44]
        let symKey = SymmetricKey(data: encryptionKey)
        let nonce = try AES.GCM.Nonce(data: iv)

        let sealed = try AES.GCM.seal(plaintext, using: symKey, nonce: nonce, authenticating: ad)
        state.sendingChainIndex += 1

        return (sealed.ciphertext + sealed.tag, state.sendingDHKeyPair.publicKey)
    }

    static func decrypt(state: inout RatchetState, ciphertext: Data, ratchetKey: Data, ad: Data) async throws -> Data {
        if ratchetKey != state.receivingDHPublicKey {
            try await performDHRatchet(state: &state, ratchetKey: ratchetKey)
        }

        guard let chainKey = state.receivingChainKey else {
            throw OMEMOError.missingChainKey
        }

        let messageKey = deriveKey(secret: chainKey, salt: "OMEMO Message".data(using: .utf8)!, info: "OMEMO Msg Key")
        state.receivingChainKey = deriveKey(secret: chainKey, salt: "OMEMO Chain".data(using: .utf8)!, info: "OMEMO Next Chain")

        let iv = messageKey[..<12]
        let encryptionKey = messageKey[12..<44]
        let symKey = SymmetricKey(data: encryptionKey)

        guard ciphertext.count >= 16 else { throw OMEMOError.decryptionFailed }
        let tag = ciphertext.suffix(16)
        let encrypted = ciphertext.dropLast(16)
        let nonce = try AES.GCM.Nonce(data: iv)

        let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: encrypted, tag: tag)
        let decrypted = try AES.GCM.open(sealed, using: symKey, authenticating: ad)

        state.receivingChainIndex += 1
        return decrypted
    }

    private static func performDHRatchet(state: inout RatchetState, ratchetKey: Data) async throws {
        guard let receivingDH = state.receivingDHPublicKey else {
            throw OMEMOError.missingDHKey
        }

        let dhReceiverPriv = try CryptoKit.Curve25519.KeyAgreement.PrivateKey(rawRepresentation: state.sendingDHKeyPair.privateKey)
        let dhSenderPub = try CryptoKit.Curve25519.KeyAgreement.PublicKey(rawRepresentation: ratchetKey)

        let shared1 = try dhReceiverPriv.sharedSecretFromKeyAgreement(with: dhSenderPub)
        let shared1Data = shared1.withUnsafeBytes { Data($0) }
        let rootKey1 = deriveKey(secret: shared1Data, salt: state.rootKey, info: "OMEMO Ratchet Root")

        let newSendingKey = CryptoKit.Curve25519.KeyAgreement.PrivateKey()
        let newSendingPub = newSendingKey.publicKey.rawRepresentation
        let shared2 = try newSendingKey.sharedSecretFromKeyAgreement(with: dhSenderPub)
        let shared2Data = shared2.withUnsafeBytes { Data($0) }
        let rootKey2 = deriveKey(secret: shared2Data, salt: rootKey1, info: "OMEMO Ratchet Root2")
        let chainKey = deriveKey(secret: rootKey1, salt: rootKey2, info: "OMEMO Ratchet Chain")

        state.previousSendingChainKey = state.sendingChainKey
        state.rootKey = rootKey2
        state.receivingChainKey = chainKey
        state.receivingDHPublicKey = ratchetKey
        state.sendingDHKeyPair = DHKeyPair(publicKey: newSendingPub, privateKey: newSendingKey.rawRepresentation)
        state.receivingChainIndex = 0
    }

    static func deriveKey(secret: Data, salt: Data, info: String) -> Data {
        let derived = CryptoKit.HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: salt,
            info: info.data(using: .utf8)!,
            outputByteCount: 44
        )
        return derived.withUnsafeBytes { Data($0) }
    }
}

enum OMEMOError: Error, Sendable {
    case missingChainKey
    case missingDHKey
    case decryptionFailed
    case encryptionFailed
    case invalidKey
    case noSession
}
