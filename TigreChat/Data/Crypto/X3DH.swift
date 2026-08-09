import Foundation
import CryptoKit

actor X3DH {
    static func aliceInitiate(
        myIdentityKey: Data,
        mySignedPreKeyPrivate: Data,
        myOneTimePreKeyPrivate: Data?,
        bobIdentityKey: Data,
        bobSignedPreKey: Data,
        bobOneTimePreKey: Data?
    ) async throws -> (sharedSecret: Data, associatedData: Data) {
        let myIdentity = try CryptoKit.Curve25519.KeyAgreement.PrivateKey(rawRepresentation: myIdentityKey)
        let mySignedPreKey = try CryptoKit.Curve25519.KeyAgreement.PrivateKey(rawRepresentation: mySignedPreKeyPrivate)

        let bobIdentityPub = try CryptoKit.Curve25519.KeyAgreement.PublicKey(rawRepresentation: bobIdentityKey)
        let bobSignedPreKeyPub = try CryptoKit.Curve25519.KeyAgreement.PublicKey(rawRepresentation: bobSignedPreKey)

        var sharedSecret = concatDH(
            try myIdentity.sharedSecretFromKeyAgreement(with: bobSignedPreKeyPub),
            try mySignedPreKey.sharedSecretFromKeyAgreement(with: bobIdentityPub),
            try mySignedPreKey.sharedSecretFromKeyAgreement(with: bobSignedPreKeyPub)
        )

        if let bobOTPKData = bobOneTimePreKey {
            let bobOTPK = try CryptoKit.Curve25519.KeyAgreement.PublicKey(rawRepresentation: bobOTPKData)
            sharedSecret += sharedSecretData(try mySignedPreKey.sharedSecretFromKeyAgreement(with: bobOTPK))
        }

        let ad = myIdentity.publicKey.rawRepresentation + bobIdentityPub.rawRepresentation
        let derived = deriveSharedSecret(sharedSecret)

        return (derived, ad)
    }

    static func bobRespond(
        myIdentityKey: Data,
        mySignedPreKey: CryptoKit.Curve25519.KeyAgreement.PrivateKey,
        myOneTimePreKey: CryptoKit.Curve25519.KeyAgreement.PrivateKey?,
        aliceIdentityKey: Data,
        aliceSignedPreKey: Data
    ) async throws -> (sharedSecret: Data, associatedData: Data) {
        let myIdentity = try CryptoKit.Curve25519.KeyAgreement.PrivateKey(rawRepresentation: myIdentityKey)
        let aliceIdentityPub = try CryptoKit.Curve25519.KeyAgreement.PublicKey(rawRepresentation: aliceIdentityKey)
        let aliceSignedPreKeyPub = try CryptoKit.Curve25519.KeyAgreement.PublicKey(rawRepresentation: aliceSignedPreKey)

        var sharedSecret = concatDH(
            try mySignedPreKey.sharedSecretFromKeyAgreement(with: aliceIdentityPub),
            try myIdentity.sharedSecretFromKeyAgreement(with: aliceSignedPreKeyPub),
            try mySignedPreKey.sharedSecretFromKeyAgreement(with: aliceSignedPreKeyPub)
        )

        if let otpk = myOneTimePreKey {
            sharedSecret += sharedSecretData(try otpk.sharedSecretFromKeyAgreement(with: aliceSignedPreKeyPub))
        }

        let ad = aliceIdentityPub.rawRepresentation + myIdentity.publicKey.rawRepresentation
        let derived = deriveSharedSecret(sharedSecret)

        return (derived, ad)
    }

    private static func concatDH(_ dh1: SharedSecret, _ dh2: SharedSecret, _ dh3: SharedSecret) -> Data {
        sharedSecretData(dh1) + sharedSecretData(dh2) + sharedSecretData(dh3)
    }

    private static func sharedSecretData(_ secret: SharedSecret) -> Data {
        secret.withUnsafeBytes { Data($0) }
    }

    private static func deriveSharedSecret(_ secret: Data) -> Data {
        let derived = CryptoKit.HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: "OMEMO X3DH".data(using: .utf8)!,
            info: "OMEMO Shared Secret".data(using: .utf8)!,
            outputByteCount: 32
        )
        return derived.withUnsafeBytes { Data($0) }
    }
}
