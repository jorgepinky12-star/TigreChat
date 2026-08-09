import Foundation
import CryptoKit

actor OMEMOModule {
    private let connection: XMPPConnection
    let sessionManager: OMEMOSessionManager
    let keyManager: KeyManager
    private var idCounter: UInt32 = 0

    init(connection: XMPPConnection, keyManager: KeyManager) {
        self.connection = connection
        self.keyManager = keyManager
        self.sessionManager = OMEMOSessionManager(keyManager: keyManager)
    }

    // MARK: - Bundle Publishing (PEP)

    func publishBundle() async throws {
        let id = nextID()
        guard let ik = await keyManager.identityKeyPair,
              let spk = await keyManager.signedPreKey else { return }
        let preKeys = await keyManager.preKeys.prefix(20)

        let ikB64 = ik.publicKey.base64EncodedString()
        let spkB64 = spk.publicKey.base64EncodedString()
        let sigB64 = spk.signature.base64EncodedString()

        let deviceId = await keyManager.deviceId
        var xml = """
        <iq id='\(id)' type='set'>
          <pubsub xmlns='http://jabber.org/protocol/pubsub'>
            <publish node='urn:xmpp:omemo:0:bundles:\(deviceId)'>
              <item>
                <bundle xmlns='urn:xmpp:omemo:0'>
                  <signedPreKeyPublic signedPreKeyId='\(spk.id)'>\(spkB64)</signedPreKeyPublic>
                  <signedPreKeySignature>\(sigB64)</signedPreKeySignature>
                  <identityKey>\(ikB64)</identityKey>
                  <prekeys>
        """
        for pk in preKeys {
            let pkB64 = pk.publicKey.base64EncodedString()
            xml += "<preKeyPublic preKeyId='\(pk.id)'>\(pkB64)</preKeyPublic>"
        }
        xml += """
                  </prekeys>
                </bundle>
              </item>
            </publish>
          </pubsub>
        </iq>
        """
        try await connection.send(string: xml)
    }

    func publishDeviceList(devices: [UInt32]) async throws {
        let id = nextID()
        let deviceId = await keyManager.deviceId
        let xml = "<iq id='\(id)' type='set'><pubsub xmlns='http://jabber.org/protocol/pubsub'><publish node='urn:xmpp:omemo:0:devices'><item><list xmlns='urn:xmpp:omemo:0'><device id='\(deviceId)'/></list></item></publish></pubsub></iq>"
        try await connection.send(string: xml)
    }

    // MARK: - Message Encryption

    func encryptOutgoingMessage(text: String, to jid: String) async throws -> (encryptedXML: String, deviceId: UInt32) {
        let deviceId = await keyManager.deviceId
        guard let ik = await keyManager.identityKeyPair,
              let spk = await keyManager.signedPreKey else {
            throw OMEMOError.noSession
        }

        let payload = try await sessionManager.encryptMessage(
            plaintext: text,
            jid: jid,
            deviceId: deviceId
        )

        let ivB64 = payload.iv.base64EncodedString()
        let cipherB64 = payload.ciphertext.base64EncodedString()
        let ratchetB64 = payload.ratchetKey.base64EncodedString()
        let ikB64 = ik.publicKey.base64EncodedString()

        let headerXML = """
        <header sid='\(payload.senderDeviceId)'>
          <key rid='\(deviceId)'>
            <iv>\(ivB64)</iv>
            <no-cast/>
          </key>
          <forward>
            <key rid='\(deviceId)'>
              \(cipherB64)
            </key>
            <iv>\(ivB64)</iv>
          </forward>
        </header>
        """

        let xml = """
        <encrypted xmlns='urn:xmpp:omemo:0'>
          \(headerXML)
          <payload>\(cipherB64)</payload>
        </encrypted>
        """
        return (xml, deviceId)
    }

    func decryptIncomingMessage(from jid: String, omemoXML: String) async throws -> String {
        let payload = try parseOMEMOPayload(omemoXML)
        return try await sessionManager.decryptMessage(payload: payload, jid: jid)
    }

    // MARK: - Bundle Fetching

    func fetchBundle(jid: String, deviceId: UInt32) async throws -> OMEMOBundle? {
        let id = nextID()
        let xml = """
        <iq id='\(id)' to='\(jid.xmlEscaped)' type='get'>
          <pubsub xmlns='http://jabber.org/protocol/pubsub'>
            <items node='urn:xmpp:omemo:0:bundles:\(deviceId)'/>
          </pubsub>
        </iq>
        """
        try await connection.send(string: xml)
        return nil
    }

    // MARK: - Parsing

    func parseOMEMOPayload(_ xml: String) throws -> EncryptedPayload {
        let iv = extractBase64(xml, tag: "iv")
        let ciphertext = extractBase64(xml, tag: "payload")
        let ratchetKey = Data()

        guard let ivData = Data(base64Encoded: iv),
              let cipherData = Data(base64Encoded: ciphertext) else {
            throw OMEMOError.decryptionFailed
        }

        return EncryptedPayload(
            iv: ivData,
            ciphertext: cipherData,
            authTag: Data(),
            senderDeviceId: 0,
            senderIdentityKey: Data(),
            receiverIdentityKey: Data(),
            preKeyId: nil,
            signedPreKeyId: 0,
            ratchetKey: ratchetKey,
            isPreKeyMessage: false
        )
    }

    private func extractBase64(_ xml: String, tag: String) -> String {
        guard let open = xml.range(of: "<\(tag)>"),
              let close = xml.range(of: "</\(tag)>"),
              open.upperBound < close.lowerBound else { return "" }
        return String(xml[open.upperBound..<close.lowerBound])
    }

    private func nextID() -> String {
        idCounter += 1
        return "om\(idCounter)"
    }
}


