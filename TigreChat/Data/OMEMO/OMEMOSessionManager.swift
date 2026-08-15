import Foundation

/// `CipherTextMessage` (vendor) transporta solo valores Sendable (`CipherTextType`,
/// `Data`) pero no declara la conformidad (misma regla para `CipherTextType`,
/// enum de raw value): se declara `@unchecked` aquí porque no hay estado mutable.
extension CipherTextMessage: @unchecked Sendable {}

/// Gestión de sesiones OMEMO (XEP-0384) sobre el SignalProtocolKit vendored.
///
/// Sustituye al ratchet custom: X3DH + Double Ratchet ahora son los de
/// SignalProtocolSwift (wire-compatible con libsignal / Conversations /
/// smack-omemo). El estado vive en `OMEMOSignalStore` (Keychain).
actor OMEMOSessionManager {
    private let store: OMEMOSignalStore

    /// El store se inyecta para que los tests simulen dos dispositivos con
    /// Keychain/UserDefaults aislados; en producción se usa el por defecto.
    init(store: OMEMOSignalStore = OMEMOSignalStore()) {
        self.store = store
    }

    /// true si ya hay sesión establecida con el dispositivo remoto.
    func hasSession(jid: String, deviceId: UInt32) -> Bool {
        store.sessionStore.containsSession(for: OMEMOAddress(jid: jid, deviceId: deviceId))
    }

    /// Establece una sesión X3DH desde el bundle PEP del dispositivo remoto.
    /// Valida la firma del signed prekey contra la identidad remota (TOFU:
    /// la primera identidad vista se acepta y se memoriza).
    func processBundle(_ bundle: OMEMOBundle, jid: String) throws {
        let address = OMEMOAddress(jid: jid, deviceId: bundle.deviceId)
        guard let signedPreKey = try? PublicKey(from: bundle.signedPreKey.publicKey),
              let identity = try? PublicKey(from: bundle.identityKey) else {
            throw OMEMOError.invalidBundle
        }

        let preKeyPublic = try bundle.preKeys.first.map { try PublicKey(from: $0.publicKey) }
        let preKeyId = bundle.preKeys.first?.id ?? 0

        let spkBundle = SessionPreKeyBundle(
            preKeyId: preKeyId,
            preKeyPublic: preKeyPublic,
            signedPreKeyId: bundle.signedPreKey.id,
            signedPreKeyPublic: signedPreKey,
            signedPreKeySignature: bundle.signedPreKey.signature,
            identityKey: identity
        )

        do {
            try SessionCipher(store: store, remoteAddress: address).process(preKeyBundle: spkBundle)
        } catch {
            throw OMEMOError.sessionBuildFailed(error.localizedDescription)
        }
    }

    /// Cifra la session key del mensaje para un dispositivo concreto. Devuelve
    /// un `CipherTextMessage` (`.preKey` la primera vez, `.signal` después).
    func encryptSessionKey(_ key: Data, jid: String, deviceId: UInt32) throws -> CipherTextMessage {
        let address = OMEMOAddress(jid: jid, deviceId: deviceId)
        do {
            return try SessionCipher(store: store, remoteAddress: address).encrypt(key)
        } catch {
            throw OMEMOError.encryptionFailed(error.localizedDescription)
        }
    }

    /// Descifra la session key de un `<key>` entrante. Un `.preKey` establece
    /// la sesión X3DH al vuelo (y consume el one-time prekey local usado).
    func decryptSessionKey(_ message: CipherTextMessage, jid: String, deviceId: UInt32) throws -> Data {
        let address = OMEMOAddress(jid: jid, deviceId: deviceId)
        do {
            return try SessionCipher(store: store, remoteAddress: address).decrypt(message)
        } catch let error as SignalError where error.type == .untrustedIdentity {
            throw OMEMOError.untrustedIdentity
        } catch {
            throw OMEMOError.decryptionFailed(error.localizedDescription)
        }
    }

    func removeSession(jid: String, deviceId: UInt32) {
        try? store.sessionStore.deleteSession(for: OMEMOAddress(jid: jid, deviceId: deviceId))
    }
}
