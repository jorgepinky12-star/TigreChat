import Foundation

struct IdentityKeyPair: Sendable {
    let publicKey: Data
    let privateKey: Data
}

struct SignedPreKey: Sendable {
    let id: UInt32
    let publicKey: Data
    let privateKey: Data
    let signature: Data
}

struct PreKey: Sendable {
    let id: UInt32
    let publicKey: Data
    let privateKey: Data
}

struct OMEMOBundle: Sendable {
    let deviceId: UInt32
    let identityKey: Data
    let signedPreKey: SignedPreKeyPublic
    let preKeys: [PreKeyPublic]
}

struct SignedPreKeyPublic: Sendable {
    let id: UInt32
    let publicKey: Data
    let signature: Data
}

struct PreKeyPublic: Sendable {
    let id: UInt32
    let publicKey: Data
}

struct OMEMOSessionState: Codable, Sendable {
    let jid: String
    let deviceId: UInt32
    var rootKey: Data
    var sendingChainKey: Data
    var receivingChainKey: Data?
    var sendingDHKeyPair: DHKeyPair?
    var receivingDHPublicKey: Data?
    var sendingChainIndex: UInt32
    var receivingChainIndex: UInt32
}

struct DHKeyPair: Codable, Sendable {
    let publicKey: Data
    let privateKey: Data
}

struct EncryptedPayload: Sendable {
    let iv: Data
    let ciphertext: Data
    let authTag: Data
    let senderDeviceId: UInt32
    let senderIdentityKey: Data
    let receiverIdentityKey: Data
    let preKeyId: UInt32?
    let signedPreKeyId: UInt32
    let ratchetKey: Data
    let isPreKeyMessage: Bool
}

/// Modelo de verificación de identidad (huella) de un contacto.
struct FingerprintInfo: Sendable {
    let jid: String
    let fingerprint: String
    let isVerified: Bool

    var formatted: String {
        fingerprint.chunked(every: 8).joined(separator: " ")
    }
}

extension String {
    func chunked(every length: Int) -> [String] {
        stride(from: 0, to: count, by: length).map {
            let start = index(startIndex, offsetBy: $0)
            let end = index(start, offsetBy: min(length, count - $0))
            return String(self[start..<end])
        }
    }
}
