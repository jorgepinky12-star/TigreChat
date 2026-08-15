import Foundation
import CryptoKit
import Security

/// Módulo OMEMO (XEP-0384) de TigreChat.
///
/// Encriptado y desencriptado de mensajes 1:1 interoperable con el ecosistema
/// libsignal (Conversations, smack-omemo):
/// - la session key del mensaje se cifra por dispositivo (`<key rid>`),
/// - el `<payload>` es el mensaje cifrado con AES-256-GCM,
/// - las sesiones son X3DH + Double Ratchet de SignalProtocolKit.
actor OMEMOModule {
    private let connection: XMPPConnection
    let sessionManager: OMEMOSessionManager
    let keyManager: KeyManager
    private var dispatcher: IQDispatcher?
    private var idCounter: UInt32 = 0

    init(connection: XMPPConnection, keyManager: KeyManager) {
        self.connection = connection
        self.keyManager = keyManager
        self.sessionManager = OMEMOSessionManager()
    }

    /// Conecta las respuestas IQ (PEP bundle/device list) al dispatcher del
    /// cliente. Se llama al autenticar, igual que `XMPPMAMManager.attach`.
    func attach(dispatcher: IQDispatcher) {
        self.dispatcher = dispatcher
    }

    var localDeviceId: UInt32 {
        get async { await keyManager.deviceId }
    }

    private func bareJID(_ jid: String) -> String {
        jid.components(separatedBy: "/").first ?? jid
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
        let ids = devices.isEmpty ? [deviceId] : devices
        var devicesXML = ""
        for dev in ids {
            devicesXML += "<device id='\(dev)'/>"
        }
        let xml = "<iq id='\(id)' type='set'><pubsub xmlns='http://jabber.org/protocol/pubsub'><publish node='urn:xmpp:omemo:0:devices'><item><list xmlns='urn:xmpp:omemo:0'>\(devicesXML)</list></item></publish></pubsub></iq>"
        try await connection.send(string: xml)
    }

    // MARK: - Peer Discovery (PEP)

    /// Pide la lista de dispositivos OMEMO publicados por el contacto.
    func fetchDeviceList(jid: String) async throws -> [UInt32] {
        guard let dispatcher else { throw OMEMOError.notReady }
        let id = nextID()
        let xml = """
        <iq id='\(id)' to='\(bareJID(jid).xmlEscaped)' type='get'>
          <pubsub xmlns='http://jabber.org/protocol/pubsub'>
            <items node='urn:xmpp:omemo:0:devices'/>
          </pubsub>
        </iq>
        """
        try await connection.send(string: xml)
        let response = try await dispatcher.wait(for: id, timeout: 10)
        guard let root = OMEMOXMLElement.parse(response.rawXML),
              let list = root.firstDescendant(named: "list") else { return [] }
        return list.children
            .filter { $0.name == "device" }
            .compactMap { $0.attribute("id").flatMap(UInt32.init) }
    }

    /// Pide el bundle (claves públicas) de un dispositivo concreto.
    /// Devuelve nil cuando el dispositivo no tiene bundle publicado.
    func fetchBundle(jid: String, deviceId: UInt32) async throws -> OMEMOBundle? {
        guard let dispatcher else { throw OMEMOError.notReady }
        let id = nextID()
        let xml = """
        <iq id='\(id)' to='\(bareJID(jid).xmlEscaped)' type='get'>
          <pubsub xmlns='http://jabber.org/protocol/pubsub'>
            <items node='urn:xmpp:omemo:0:bundles:\(deviceId)'/>
          </pubsub>
        </iq>
        """
        try await connection.send(string: xml)
        let response = try await dispatcher.wait(for: id, timeout: 10)
        guard let root = OMEMOXMLElement.parse(response.rawXML),
              let bundleNode = root.firstDescendant(named: "bundle"),
              let identity = bundleNode.firstChild(named: "identityKey")?.text,
              let identityData = Data(base64Encoded: identity.trimmingCharacters(in: .whitespacesAndNewlines)),
              let spkNode = bundleNode.firstChild(named: "signedPreKeyPublic"),
              let spkData = Data(base64Encoded: spkNode.text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let sigNode = bundleNode.firstChild(named: "signedPreKeySignature"),
              let sigData = Data(base64Encoded: sigNode.text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let spkId = spkNode.attribute("signedPreKeyId").flatMap(UInt32.init) else {
            return nil
        }

        let prekeys = (bundleNode.firstChild(named: "prekeys")?.children ?? [])
            .filter { $0.name == "preKeyPublic" }
            .compactMap { node -> PreKeyPublic? in
                guard let id = node.attribute("preKeyId").flatMap(UInt32.init),
                      let key = Data(base64Encoded: node.text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
                return PreKeyPublic(id: id, publicKey: key)
            }

        return OMEMOBundle(
            deviceId: deviceId,
            identityKey: identityData,
            signedPreKey: SignedPreKeyPublic(id: spkId, publicKey: spkData, signature: sigData),
            preKeys: prekeys
        )
    }

    // MARK: - Message Encryption (XEP-0384)

    /// Cifra un mensaje para TODOS los dispositivos del contacto y devuelve el
    /// elemento `<encrypted xmlns='urn:xmpp:omemo:0'>...</encrypted>` listo
    /// para insertar en un `<message>`.
    func encryptOutgoingMessage(text: String, to jid: String) async throws -> String {
        let bare = bareJID(jid)
        let sid = await keyManager.deviceId

        let devices = try await fetchDeviceList(jid: bare).filter { $0 != sid }
        guard !devices.isEmpty else { throw OMEMOError.noDevices }

        // 1. Session key aleatoria + IV del payload (AES-256-GCM).
        let sessionKey = randomBytes(32)
        let iv = randomBytes(12)

        // 2. Payload: mensaje cifrado con la session key.
        let sealed = try AES.GCM.seal(
            Data(text.utf8),
            using: SymmetricKey(data: sessionKey),
            nonce: AES.GCM.Nonce(data: iv)
        )
        let payload = sealed.ciphertext + sealed.tag
        let ivB64 = iv.base64EncodedString()

        // 3. Session key cifrada por dispositivo (X3DH o ratchet existente).
        var keysXML = ""
        for device in devices {
            do {
                if !(await sessionManager.hasSession(jid: bare, deviceId: device)) {
                    guard let bundle = try await fetchBundle(jid: bare, deviceId: device) else { continue }
                    try await sessionManager.processBundle(bundle, jid: bare)
                }
                let cipher = try await sessionManager.encryptSessionKey(sessionKey, jid: bare, deviceId: device)
                let prekeyAttr = cipher.type == .preKey ? " prekey='true'" : ""
                keysXML += "<key rid='\(device)'\(prekeyAttr)><iv>\(ivB64)</iv>\(cipher.data.base64EncodedString())</key>"
            } catch {
                // Dispositivo sin bundle válido o sesión fallida: se omite.
                // Si ninguno acepta, abajo se lanza OMEMOError.noSessions.
                continue
            }
        }
        guard !keysXML.isEmpty else { throw OMEMOError.noSessions }

        return """
        <encrypted xmlns='urn:xmpp:omemo:0'>
          <header sid='\(sid)'>
            \(keysXML)
          </header>
          <payload>\(payload.base64EncodedString())</payload>
        </encrypted>
        """
    }

    /// Descifra un `<encrypted>` entrante: busca el `<key rid>` de NUESTRO
    /// dispositivo, abre la session key con la sesión Signal (estableciéndola
    /// si es un prekey message) y abre el payload con AES-256-GCM.
    func decryptIncomingMessage(from jid: String, omemoXML: String) async throws -> String {
        guard let root = OMEMOXMLElement.parse(omemoXML),
              let header = root.firstChild(named: "header"),
              let sid = header.attribute("sid").flatMap(UInt32.init),
              let payloadNode = root.firstChild(named: "payload") else {
            throw OMEMOError.invalidPayload
        }

        let myDeviceId = await keyManager.deviceId
        guard let keyNode = header.children.first(where: {
            $0.name == "key" && $0.attribute("rid").flatMap(UInt32.init) == myDeviceId
        }) else {
            // Sin clave para nuestro dispositivo (p. ej. lista cambiada).
            throw OMEMOError.messageNotForThisDevice
        }
        guard let ivText = keyNode.firstChild(named: "iv")?.text,
              let iv = Data(base64Encoded: ivText),
              let cipherData = Data(base64Encoded: keyNode.text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let payloadData = Data(base64Encoded: payloadNode.text.trimmingCharacters(in: .whitespacesAndNewlines)),
              payloadData.count >= 16 else {
            throw OMEMOError.invalidPayload
        }

        // 1. Abre la session key con SignalProtocolKit (prekey → X3DH).
        let cipherMessage = try CipherTextMessage(from: cipherData)
        let sessionKey = try await sessionManager.decryptSessionKey(
            cipherMessage,
            jid: bareJID(jid),
            deviceId: sid
        )

        // 2. Abre el payload con AES-256-GCM.
        let nonce = try AES.GCM.Nonce(data: iv)
        let box = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: payloadData.dropLast(16),
            tag: payloadData.suffix(16)
        )
        let plaintext = try AES.GCM.open(box, using: SymmetricKey(data: sessionKey))
        guard let text = String(data: plaintext, encoding: .utf8) else {
            throw OMEMOError.decryptionFailed(nil)
        }
        return text
    }

    // MARK: - Helpers

    private func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    private func nextID() -> String {
        idCounter += 1
        return "om\(idCounter)"
    }
}

enum OMEMOError: Error, Sendable {
    case noSession
    case decryptionFailed(String?)
    case invalidBundle
    case sessionBuildFailed(String)
    case encryptionFailed(String)
    case untrustedIdentity
    case noDevices
    case noSessions
    case invalidPayload
    case messageNotForThisDevice
    case notReady
}

extension OMEMOError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .noSession: return "No OMEMO session"
        case .decryptionFailed(let detail): return detail.map { "OMEMO decryption failed: \($0)" } ?? "OMEMO decryption failed"
        case .invalidBundle: return "Invalid OMEMO bundle"
        case .sessionBuildFailed(let detail): return "Could not build OMEMO session: \(detail)"
        case .encryptionFailed(let detail): return "OMEMO encryption failed: \(detail)"
        case .untrustedIdentity: return "Untrusted OMEMO identity"
        case .noDevices: return "Contact has no OMEMO devices"
        case .noSessions: return "No OMEMO device accepted the message"
        case .invalidPayload: return "Invalid OMEMO payload"
        case .messageNotForThisDevice: return "OMEMO message has no key for this device"
        case .notReady: return "OMEMO module not attached"
        }
    }
}