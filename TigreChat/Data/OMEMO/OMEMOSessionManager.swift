import Foundation

actor OMEMOSessionManager {
    private let keyManager: KeyManager
    private var sessions: [String: [UInt32: OMEMOSessionState]] = [:]

    init(keyManager: KeyManager) {
        self.keyManager = keyManager
    }

    func getOrCreateSession(
        jid: String,
        deviceId: UInt32,
        bobIdentityKey: Data,
        bobSignedPreKey: Data,
        bobRatchetKey: Data,
        bobOneTimePreKey: Data?
    ) async throws -> OMEMOSessionState {
        if let existing = sessions[jid]?[deviceId] {
            return existing
        }
        if let saved = await keyManager.loadSession(jid: jid, deviceId: deviceId) {
            sessions[jid, default: [:]][deviceId] = saved
            return saved
        }

        guard let myIdentity = await keyManager.identityKeyPair,
              let mySignedPreKey = await keyManager.signedPreKey else {
            throw OMEMOError.noSession
        }

        let (sharedSecret, ad) = try await X3DH.aliceInitiate(
            myIdentityKey: myIdentity.privateKey,
            mySignedPreKeyPrivate: mySignedPreKey.privateKey,
            myOneTimePreKeyPrivate: nil,
            bobIdentityKey: bobIdentityKey,
            bobSignedPreKey: bobSignedPreKey,
            bobOneTimePreKey: bobOneTimePreKey
        )

        let state = try await DoubleRatchet.initializeAsAlice(
            sharedSecret: sharedSecret,
            bobSignedPreKey: bobSignedPreKey,
            bobRatchetKey: bobRatchetKey
        )

        let session = OMEMOSessionState(
            jid: jid,
            deviceId: deviceId,
            rootKey: state.rootKey,
            sendingChainKey: state.sendingChainKey,
            receivingChainKey: state.receivingChainKey,
            sendingDHKeyPair: state.sendingDHKeyPair,
            receivingDHPublicKey: state.receivingDHPublicKey,
            sendingChainIndex: state.sendingChainIndex,
            receivingChainIndex: state.receivingChainIndex
        )

        sessions[jid, default: [:]][deviceId] = session
        await keyManager.saveSession(jid: jid, deviceId: deviceId, state: session)
        return session
    }

    func encryptMessage(plaintext: String, jid: String, deviceId: UInt32) async throws -> EncryptedPayload {
        guard let session = sessions[jid]?[deviceId] else {
            throw OMEMOError.noSession
        }

        let plaintextData = Data(plaintext.utf8)
        let ad = Data("OMEMO Message".utf8)

        var rs = session.toRatchetState()
        let (ciphertext, ratchetKey) = try await DoubleRatchet.encrypt(
            state: &rs,
            plaintext: plaintextData,
            ad: ad
        )

        let newSession = OMEMOSessionState.fromRatchetState(rs, jid: jid, deviceId: deviceId)
        sessions[jid]?[deviceId] = newSession
        await keyManager.saveSession(jid: jid, deviceId: deviceId, state: newSession)

        let iv = newSession.sendingChainKey.prefix(12)
        return EncryptedPayload(
            iv: Data(iv),
            ciphertext: ciphertext.dropLast(16),
            authTag: ciphertext.suffix(16),
            senderDeviceId: await keyManager.deviceId,
            senderIdentityKey: (await keyManager.identityKeyPair)?.publicKey ?? Data(),
            receiverIdentityKey: Data(),
            preKeyId: nil,
            signedPreKeyId: 0,
            ratchetKey: ratchetKey,
            isPreKeyMessage: false
        )
    }

    func decryptMessage(payload: EncryptedPayload, jid: String) async throws -> String {
        guard let session = sessions[jid]?[payload.senderDeviceId] else {
            throw OMEMOError.noSession
        }

        let ad = Data("OMEMO Message".utf8)
        let ciphertext = payload.ciphertext + payload.authTag

        var rs = session.toRatchetState()
        let plaintext = try await DoubleRatchet.decrypt(
            state: &rs,
            ciphertext: ciphertext,
            ratchetKey: payload.ratchetKey,
            ad: ad
        )

        let newSession = OMEMOSessionState.fromRatchetState(rs, jid: jid, deviceId: payload.senderDeviceId)
        sessions[jid]?[payload.senderDeviceId] = newSession
        await keyManager.saveSession(jid: jid, deviceId: payload.senderDeviceId, state: newSession)

        guard let text = String(data: plaintext, encoding: .utf8) else {
            throw OMEMOError.decryptionFailed
        }
        return text
    }

    func removeSession(jid: String, deviceId: UInt32) async {
        sessions[jid]?.removeValue(forKey: deviceId)
        await keyManager.deleteSession(jid: jid, deviceId: deviceId)
    }
}

private extension OMEMOSessionState {
    func toRatchetState() -> DoubleRatchet.RatchetState {
        DoubleRatchet.RatchetState(
            rootKey: rootKey,
            sendingChainKey: sendingChainKey,
            receivingChainKey: receivingChainKey,
            sendingDHKeyPair: sendingDHKeyPair ?? DHKeyPair(publicKey: Data(), privateKey: Data()),
            receivingDHPublicKey: receivingDHPublicKey,
            sendingChainIndex: sendingChainIndex,
            receivingChainIndex: receivingChainIndex,
            previousSendingChainKey: nil
        )
    }

    static func fromRatchetState(_ state: DoubleRatchet.RatchetState, jid: String, deviceId: UInt32) -> OMEMOSessionState {
        OMEMOSessionState(
            jid: jid,
            deviceId: deviceId,
            rootKey: state.rootKey,
            sendingChainKey: state.sendingChainKey,
            receivingChainKey: state.receivingChainKey,
            sendingDHKeyPair: state.sendingDHKeyPair,
            receivingDHPublicKey: state.receivingDHPublicKey,
            sendingChainIndex: state.sendingChainIndex,
            receivingChainIndex: state.receivingChainIndex
        )
    }
}
