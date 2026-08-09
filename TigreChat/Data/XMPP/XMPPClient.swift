import Foundation
import CommonCrypto
import Network
import os

actor XMPPClient {
    nonisolated let connection: XMPPConnection
    private let parser: XMPPStanzaParser
    private(set) var isAuthenticated = false
    private(set) var currentJID: String?
    private var idCounter: UInt32 = 0
    private var serverHost: String = ""
    private var serverDomain: String = ""
    private var serverPort: Int = 5222
    private var useDirectTLS: Bool = false

    private var messageContinuation: AsyncStream<Message>.Continuation?
    let messageStream: AsyncStream<Message>

    private var presenceContinuation: AsyncStream<PresenceStanza>.Continuation?
    let presenceStream: AsyncStream<PresenceStanza>

    private var saslContinuation: CheckedContinuation<String, any Error>?
    private var authSuccessContinuation: CheckedContinuation<Void, any Error>?

    private var featuresContinuation: CheckedContinuation<StreamFeatures, any Error>?
    private var lastStreamFeatures: StreamFeatures?

    let iqDispatcher = IQDispatcher()

    let mucManager: XMPPMUCManager
    let mamManager: XMPPMAMManager
    let fileUploadManager: XMPPFileUploadManager
    let chatStateManager: XMPPChatStateManager
    let jingleManager: JingleManager
    private(set) var omemoModule: OMEMOModule?

    private var chatStateContinuation: AsyncStream<(jid: String, state: String)>.Continuation?
    let chatStateStream: AsyncStream<(jid: String, state: String)>

    private var rosterContinuation: AsyncStream<[RosterItem]>.Continuation?
    /// Publica el roster completo (fetch) y los cambios (push) del servidor.
    let rosterStream: AsyncStream<[RosterItem]>

    private var mamMessageContinuation: AsyncStream<MessageStanza>.Continuation?
    /// Resultados MAM (XEP-0313) que consume `XMPPMAMManager`.
    let mamMessageStream: AsyncStream<MessageStanza>

    private var statusUpdateContinuation: AsyncStream<(id: String, status: MessageStatus)>.Continuation?
    /// Actualizaciones de estado de mensajes (receipts XEP-0184, markers XEP-0333).
    let statusUpdateStream: AsyncStream<(id: String, status: MessageStatus)>

    private var authStateContinuation: AsyncStream<Bool>.Continuation?
    /// Emite `true` tras autenticar y `false` al desconectar.
    let authStateStream: AsyncStream<Bool>

    // MARK: - Reconnect (XEP-0198 no soportado aún: reconexión con backoff)

    private var lastJID: String?
    private var lastPassword: String?
    private var shouldAutoReconnect = false
    private var pathMonitor: NWPathMonitor?
    private let reconnectQueue = DispatchQueue(label: "com.tigrechat.reconnect")

    init() {
        connection = XMPPConnection()
        parser = XMPPStanzaParser()
        var msgCont: AsyncStream<Message>.Continuation?
        messageStream = AsyncStream { continuation in msgCont = continuation }
        messageContinuation = msgCont
        var presCont: AsyncStream<PresenceStanza>.Continuation?
        presenceStream = AsyncStream { continuation in presCont = continuation }
        presenceContinuation = presCont
        var csCont: AsyncStream<(jid: String, state: String)>.Continuation?
        chatStateStream = AsyncStream { continuation in csCont = continuation }
        chatStateContinuation = csCont
        var rosterCont: AsyncStream<[RosterItem]>.Continuation?
        rosterStream = AsyncStream { continuation in rosterCont = continuation }
        rosterContinuation = rosterCont
        var mamCont: AsyncStream<MessageStanza>.Continuation?
        mamMessageStream = AsyncStream { continuation in mamCont = continuation }
        mamMessageContinuation = mamCont
        var statusCont: AsyncStream<(id: String, status: MessageStatus)>.Continuation?
        statusUpdateStream = AsyncStream { continuation in statusCont = continuation }
        statusUpdateContinuation = statusCont
        var authCont: AsyncStream<Bool>.Continuation?
        authStateStream = AsyncStream { continuation in authCont = continuation }
        authStateContinuation = authCont

        mucManager = XMPPMUCManager(connection: connection)
        mamManager = XMPPMAMManager(connection: connection)
        fileUploadManager = XMPPFileUploadManager(connection: connection)
        chatStateManager = XMPPChatStateManager(connection: connection)
        jingleManager = JingleManager(connection: connection)
        Task { [weak self] in
            guard let self else { return }
            await self.mamManager.attach(dispatcher: self.iqDispatcher, resultStream: self.mamMessageStream)
        }

        Task { [weak self] in
            guard let self else { return }
            await parser.setStanzaCallback { [weak self] stanza in
                Task { [weak self] in await self?.handleStanza(stanza) }
            }
            for await data in await connection.receiveStream {
                await parser.appendData(data)
            }
        }
    }

    func setup(host: String, port: Int = 5222, useDirectTLS: Bool = false, domain: String? = nil) {
        serverHost = host
        serverPort = port
        self.useDirectTLS = useDirectTLS
        if let domain {
            serverDomain = domain
        } else if serverDomain.isEmpty {
            serverDomain = host
        }
    }

    func connect() async throws {
        try await connection.connect(host: serverHost, port: serverPort, useTLS: useDirectTLS)
        try await sendStreamOpen()
        lastStreamFeatures = try await waitForFeatures(timeout: 10)

        if !useDirectTLS, let features = lastStreamFeatures {
            if features.startTLSRequired || features.startTLSAvailable {
                os_log("[Client] STARTTLS available, reconnecting with DirectTLS on same port", log: xmppLog, type: .info)
                await connection.disconnect()
                try await Task.sleep(nanoseconds: 200_000_000)
                useDirectTLS = true
                try await connection.connect(host: serverHost, port: serverPort, useTLS: true)
                await parser.reset()
                try await sendStreamOpen()
                lastStreamFeatures = try await waitForFeatures(timeout: 10)
            }
        }
    }

    private func sendStreamOpen() async throws {
        let xml = "<?xml version='1.0'?><stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' to='\(serverDomain)' version='1.0'>"
        try await connection.send(string: xml)
    }

    func authenticate(jid: String, password: String) async throws {
        let parts = jid.components(separatedBy: "@")
        guard parts.count == 2 else { throw XMPPError.authFailed("Invalid JID format") }
        serverDomain = parts[1]

        try await performSASLAuth(username: parts[0], password: password, features: lastStreamFeatures)
        await parser.reset()
        lastStreamFeatures = nil
        try await sendStreamOpen()
        lastStreamFeatures = try await waitForFeatures(timeout: 10)

        if lastStreamFeatures?.bindAvailable == true {
            try await bindResource()
        }
        try await sendInitialPresence()

        if lastStreamFeatures?.sessionAvailable == true {
            try? await bindSession()
        }
        _ = try? await requestRoster()

        currentJID = jid
        isAuthenticated = true
        lastJID = jid
        lastPassword = password
        authStateContinuation?.yield(true)
        if pathMonitor == nil {
            startReconnectMonitoring()
        }
    }

    private func performSASLAuth(username: String, password: String, features: StreamFeatures?) async throws {
        let mechanisms = features?.saslMechanisms ?? []
        let mechanism: String
        if mechanisms.contains("SCRAM-SHA-256") {
            mechanism = "SCRAM-SHA-256"
        } else if mechanisms.contains("SCRAM-SHA-1") {
            mechanism = "SCRAM-SHA-1"
        } else if mechanisms.contains("PLAIN") {
            mechanism = "PLAIN"
        } else {
            mechanism = "SCRAM-SHA-1"
        }

        if mechanism == "PLAIN" {
            let authPayload = "\u{0}\(username)\u{0}\(password)"
            let encoded = Data(authPayload.utf8).base64EncodedString()
            let authStanza = "<auth xmlns='urn:ietf:params:xml:ns:xmpp-sasl' mechanism='PLAIN'>\(encoded)</auth>"
            try await connection.send(string: authStanza)
            try await waitForAuthSuccess(timeout: 10)
            return
        }

        let nonce = generateNonce()
        let clientFirst = "n,,n=\(username),r=\(nonce)"
        let clientFirstBare = String(clientFirst.dropFirst(3))

        let authPayload = Data(clientFirst.utf8).base64EncodedString()
        let authStanza = "<auth xmlns='urn:ietf:params:xml:ns:xmpp-sasl' mechanism='\(mechanism)'>\(authPayload)</auth>"
        try await connection.send(string: authStanza)

        guard let serverFirstB64 = try await waitForChallenge(timeout: 10) else {
            throw XMPPError.saslError("No challenge received from server")
        }

        guard let serverFirstData = Data(base64Encoded: serverFirstB64),
              let serverFirst = String(data: serverFirstData, encoding: .utf8) else {
            throw XMPPError.saslError("Invalid server challenge")
        }

        let parsed = parseServerFirst(serverFirst)
        let saltedPassword = deriveKey(password: password, salt: parsed.salt, iterations: parsed.iterations, mechanism: mechanism)

        let clientKey = hmac(key: saltedPassword, data: "Client Key", mechanism: mechanism)
        let storedKey = hash(data: clientKey, mechanism: mechanism)
        let authMessage = "\(clientFirstBare),\(serverFirst),c=biws,r=\(parsed.serverNonce)"
        let clientSignature = hmac(key: storedKey, data: authMessage, mechanism: mechanism)
        let proof = xorData(clientKey, clientSignature)
        let clientFinal = "c=biws,r=\(parsed.serverNonce),p=\(proof.base64EncodedString())"

        let responsePayload = Data(clientFinal.utf8).base64EncodedString()
        let responseStanza = "<response xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>\(responsePayload)</response>"
        try await connection.send(string: responseStanza)

        try await waitForAuthSuccess(timeout: 10)
    }

    private func waitForChallenge(timeout: TimeInterval) async throws -> String? {
        try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask { [weak self] in
                guard let self else { return nil }
                return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
                    Task { [weak self] in
                        await self?.setSASLContinuation(continuation)
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw XMPPError.timedOut
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func waitForAuthSuccess(timeout: TimeInterval) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                guard let self else { throw XMPPError.authFailed("Client deallocated") }
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    Task { [weak self] in
                        await self?.setAuthSuccessContinuation(continuation)
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw XMPPError.timedOut
            }
            try await group.next()!
            group.cancelAll()
        }
    }

    private func waitForFeatures(timeout: TimeInterval) async throws -> StreamFeatures? {
        try await withThrowingTaskGroup(of: StreamFeatures?.self) { group in
            group.addTask { [weak self] in
                guard let self else { return nil }
                return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<StreamFeatures, any Error>) in
                    Task { [weak self] in
                        await self?.setFeaturesContinuation(continuation)
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// Espera la respuesta IQ para el id dado. El `IQDispatcher` correlaciona
    /// por id, permitiendo múltiples peticiones IQ concurrentes.
    private func waitForIQResult(id: String, timeout: TimeInterval) async throws -> IQStanza {
        try await iqDispatcher.wait(for: id, timeout: timeout)
    }

    private func setSASLContinuation(_ continuation: CheckedContinuation<String, any Error>) {
        saslContinuation = continuation
    }

    private func setAuthSuccessContinuation(_ continuation: CheckedContinuation<Void, any Error>) {
        authSuccessContinuation = continuation
    }

    private func setFeaturesContinuation(_ continuation: CheckedContinuation<StreamFeatures, any Error>) {
        featuresContinuation = continuation
    }

    private func bindResource() async throws {
        let id = nextID()
        let resource = "TigreChat-" + String(id.suffix(4))
        let xml = "<iq id='\(id)' type='set'><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'><resource>\(resource)</resource></bind></iq>"
        try await connection.send(string: xml)
        _ = try await waitForIQResult(id: id, timeout: 10)
    }

    private func bindSession() async throws {
        let id = nextID()
        let xml = "<iq id='\(id)' type='set'><session xmlns='urn:ietf:params:xml:ns:xmpp-session'/></iq>"
        try await connection.send(string: xml)
        _ = try await waitForIQResult(id: id, timeout: 10)
    }

    /// Pide el roster al servidor (RFC 6121). Devuelve los items parseados y
    /// los publica en `rosterStream`.
    private func requestRoster() async throws -> [RosterItem] {
        let id = nextID()
        let xml = "<iq id='\(id)' type='get'><query xmlns='jabber:iq:roster'/></iq>"
        try await connection.send(string: xml)
        let result = try await waitForIQResult(id: id, timeout: 10)
        let items = RosterParser.parseItems(from: result.rawXML)
        rosterContinuation?.yield(items)
        return items
    }

    private func sendInitialPresence() async throws {
        try await connection.send(string: "<presence/>")
    }

    func sendMessage(body: String, to jid: String) async throws {
        let id = nextID()
        // XEP-0184: pedimos confirmación de entrega al destinatario.
        let xml = "<message id='\(id)' to='\(jid)' type='chat'><body>\(body.xmlEscaped)</body><request xmlns='urn:xmpp:receipts'/></message>"
        try await connection.send(string: xml)
    }

    func sendGroupchatMessage(body: String, to roomJID: String) async throws {
        try await mucManager.sendGroupMessage(roomJID: roomJID, body: body)
    }

    func setOMEMOModule(_ module: OMEMOModule) {
        omemoModule = module
    }

    func disconnect() async {
        shouldAutoReconnect = false
        stopReconnectMonitoring()
        isAuthenticated = false
        currentJID = nil
        lastStreamFeatures = nil
        authStateContinuation?.yield(false)
        await iqDispatcher.cancelAll(reason: XMPPError.notConnected)
        await connection.disconnect()
        // NOTA: los AsyncStream del cliente NO se terminan aquí. Los listeners
        // de los repositorios sobreviven a reconexiones; terminarlos los mataba
        // permanentemente (bug de reconexión).
    }

    private let chatStateTypes: Set<String> = ["composing", "paused", "active", "inactive", "gone"]

    private func handleStanza(_ stanza: XMPPStanza) async {
        switch stanza {
        case .streamOpen:
            break

        case .streamFeatures(let features):
            lastStreamFeatures = features
            featuresContinuation?.resume(returning: features)
            featuresContinuation = nil

        case .message(let msgStanza):
            let from = msgStanza.from ?? ""
            let conversationId = msgStanza.type == "groupchat"
                ? (from.components(separatedBy: "/").first ?? from)
                : from

            // MAM (XEP-0313): los resultados del archivo NO son mensajes para la
            // UI; los consume XMPPMAMManager para el catch-up.
            if msgStanza.xml.contains("urn:xmpp:mam:2") {
                mamMessageContinuation?.yield(msgStanza)
                return
            }

            // XEP-0184: confirmación de entrega entrante para un mensaje nuestro.
            if let receiptID = msgStanza.receiptID {
                statusUpdateContinuation?.yield((receiptID, .delivered))
            }
            // XEP-0333: marker de lectura entrante.
            if let marker = msgStanza.marker {
                let status: MessageStatus = marker.kind == "read" ? .read : .delivered
                statusUpdateContinuation?.yield((marker.id, status))
            }

            if msgStanza.xml.contains("urn:xmpp:omemo:0") {
                await handleOMEMOMessage(stanza: msgStanza, from: from, conversationId: conversationId)
            } else if let body = msgStanza.body {
                let message = Message(
                    id: msgStanza.id,
                    conversationId: conversationId,
                    senderJID: from,
                    text: body,
                    timestamp: msgStanza.timestamp ?? Date(),
                    isOutgoing: false,
                    status: .delivered
                )
                messageContinuation?.yield(message)
            }

            // XEP-0184: acuse automático de entrega (solo a contactos, no a ecos propios).
            if msgStanza.hasReceiptRequest, from != currentJID {
                try? await sendReceipt(to: from, for: msgStanza.id)
            }

            if chatStateTypes.contains(msgStanza.type) {
                chatStateContinuation?.yield((from, msgStanza.type))
            }

        case .presence(let presStanza):
            let from = presStanza.from ?? ""
            if from.contains("@muc.") || from.contains("@conference.") {
            }
            presenceContinuation?.yield(presStanza)

        case .challenge(let data):
            saslContinuation?.resume(returning: data)
            saslContinuation = nil

        case .success:
            authSuccessContinuation?.resume()
            authSuccessContinuation = nil

        case .failure(let text):
            saslContinuation.map { $0.resume(throwing: XMPPError.saslError(text)); saslContinuation = nil }
            if authSuccessContinuation != nil {
                authSuccessContinuation?.resume(throwing: XMPPError.authFailed(text))
                authSuccessContinuation = nil
            }
            if featuresContinuation != nil {
                featuresContinuation?.resume(throwing: XMPPError.authFailed(text))
                featuresContinuation = nil
            }

        case .iq(let iqStanza):
            // Primero intenta resolver una petición local pendiente por id.
            // Si nadie la esperaba, es un push no solicitado (roster push, Jingle...).
            if let unmatched = await iqDispatcher.deliver(iqStanza) {
                await handleUnsolicitedIQ(unmatched)
            }

        default:
            break
        }
    }

    /// Maneja IQ entrantes que no responden a ninguna petición local.
    private func handleUnsolicitedIQ(_ stanza: IQStanza) async {
        // MAM (XEP-0313): cierre de una query de archivo (IQ result con <fin>).
        if stanza.rawXML.contains("urn:xmpp:mam:2") {
            await mamManager.handleResult(iqID: stanza.id)
            return
        }
        // Jingle: session-initiate/accept/terminate entrantes
        if stanza.rawXML.contains("urn:xmpp:jingle:1") {
            await jingleManager.handleJingleStanza(xml: stanza.rawXML)
            return
        }
        // Roster push (RFC 6121 §2.1.6): el servidor notifica cambios de roster
        if stanza.type == .set, stanza.rawXML.contains("jabber:iq:roster") {
            let items = RosterParser.parseItems(from: stanza.rawXML)
            rosterContinuation?.yield(items)
            // Confirmar el push
            let id = nextID()
            let xml = "<iq id='\(id)' type='result' to='\(stanza.from ?? "")'/>"
            try? await connection.send(string: xml)
        }
    }

    private func handleOMEMOMessage(stanza: MessageStanza, from: String, conversationId: String) async {
        guard let module = omemoModule else { return }
        do {
            let plaintext = try await module.decryptIncomingMessage(from: from, omemoXML: stanza.xml)
            let message = Message(
                id: stanza.id,
                conversationId: conversationId,
                senderJID: from,
                text: plaintext,
                timestamp: stanza.timestamp ?? Date(),
                isOutgoing: false,
                status: .delivered,
                isEncrypted: true
            )
            messageContinuation?.yield(message)
        } catch {
            let message = Message(
                id: stanza.id,
                conversationId: conversationId,
                senderJID: from,
                text: "[Decryption failed: \(error.localizedDescription)]",
                timestamp: stanza.timestamp ?? Date(),
                isOutgoing: false,
                status: .failed,
                isEncrypted: true
            )
            messageContinuation?.yield(message)
        }
    }

    // MARK: - Receipts & Markers

    /// Envía un `received` (XEP-0184) confirmando un mensaje entrante.
    func sendReceipt(to jid: String, for messageID: String) async throws {
        let id = nextID()
        let xml = "<message id='\(id)' to='\(jid)' type='chat'><received xmlns='urn:xmpp:receipts' id='\(messageID)'/></message>"
        try await connection.send(string: xml)
    }

    /// Envía un marker `read` (XEP-0333) para un mensaje.
    func sendReadMarker(to jid: String, for messageID: String) async throws {
        let id = nextID()
        let xml = "<message id='\(id)' to='\(jid)' type='chat'><marker xmlns='urn:xmpp:chat-markers:0'><read id='\(messageID)'/></marker></message>"
        try await connection.send(string: xml)
    }

    // MARK: - Reconnect

    /// Vigila el estado de red; si hay conectividad y la sesión se cerró
    /// inesperadamente, reintenta conectar con backoff exponencial.
    private func startReconnectMonitoring() {
        shouldAutoReconnect = true
        stopReconnectMonitoring()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self, path.status == .satisfied else { return }
            Task { await self.reconnectIfNeeded() }
        }
        monitor.start(queue: reconnectQueue)
        pathMonitor = monitor
    }

    private func stopReconnectMonitoring() {
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    private func reconnectIfNeeded() async {
        guard shouldAutoReconnect, !isAuthenticated,
              let jid = lastJID, let password = lastPassword else { return }
        var delay: UInt64 = 1_000_000_000
        for attempt in 0..<5 {
            guard shouldAutoReconnect, !isAuthenticated else { return }
            do {
                try await connect()
                try await authenticate(jid: jid, password: password)
                if isAuthenticated { return }
            } catch {
                os_log("[Client] Reconnect attempt %d failed: %@",
                       log: xmppLog, type: .error, attempt, error.localizedDescription)
            }
            try? await Task.sleep(nanoseconds: delay)
            delay = min(delay * 2, 30_000_000_000)
        }
    }

    private func nextID() -> String {
        idCounter += 1
        return "tc\(idCounter)"
    }

    private func generateNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, 24, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: ".")
    }

    private func parseServerFirst(_ response: String) -> (salt: Data, iterations: Int, serverNonce: String) {
        var saltStr = ""
        var iterations = 4096
        var nonce = ""
        for part in response.components(separatedBy: ",") {
            if part.hasPrefix("s=") { saltStr = String(part.dropFirst(2)) }
            if part.hasPrefix("i=") { iterations = Int(String(part.dropFirst(2))) ?? 4096 }
            if part.hasPrefix("r=") { nonce = String(part.dropFirst(2)) }
        }
        return (Data(base64Encoded: saltStr) ?? Data(), iterations, nonce)
    }

    private func deriveKey(password: String, salt: Data, iterations: Int, mechanism: String) -> Data {
        let keyLength: Int
        let algorithm: CCPseudoRandomAlgorithm
        if mechanism == "SCRAM-SHA-256" {
            keyLength = 32
            algorithm = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256)
        } else {
            keyLength = 20
            algorithm = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1)
        }

        var derivedKey = [UInt8](repeating: 0, count: keyLength)
        let passwordData = Data(password.utf8)
        passwordData.withUnsafeBytes { pwPtr in
            salt.withUnsafeBytes { saltPtr in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pwPtr.baseAddress?.assumingMemoryBound(to: Int8.self),
                    passwordData.count,
                    saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    salt.count,
                    algorithm,
                    UInt32(iterations),
                    &derivedKey,
                    derivedKey.count
                )
            }
        }
        return Data(derivedKey)
    }

    private func hmac(key: Data, data: String, mechanism: String) -> Data {
        var mac = CCHmacContext()
        let algorithm: CCHmacAlgorithm
        if mechanism == "SCRAM-SHA-256" {
            algorithm = CCHmacAlgorithm(kCCHmacAlgSHA256)
        } else {
            algorithm = CCHmacAlgorithm(kCCHmacAlgSHA1)
        }
        key.withUnsafeBytes { keyPtr in
            CCHmacInit(&mac, algorithm, keyPtr.baseAddress, key.count)
        }
        Data(data.utf8).withUnsafeBytes { dataPtr in
            CCHmacUpdate(&mac, dataPtr.baseAddress, data.count)
        }
        let digestLength: Int
        if mechanism == "SCRAM-SHA-256" {
            digestLength = Int(CC_SHA256_DIGEST_LENGTH)
        } else {
            digestLength = Int(CC_SHA1_DIGEST_LENGTH)
        }
        var result = [UInt8](repeating: 0, count: digestLength)
        CCHmacFinal(&mac, &result)
        return Data(result)
    }

    private func hash(data: Data, mechanism: String) -> Data {
        if mechanism == "SCRAM-SHA-256" {
            var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            data.withUnsafeBytes { ptr in
                CC_SHA256(ptr.baseAddress, CC_LONG(data.count), &digest)
            }
            return Data(digest)
        } else {
            var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
            data.withUnsafeBytes { ptr in
                CC_SHA1(ptr.baseAddress, CC_LONG(data.count), &digest)
            }
            return Data(digest)
        }
    }

    private func xorData(_ a: Data, _ b: Data) -> Data {
        Data(zip(a, b).map { $0 ^ $1 })
    }
}

enum XMPPError: Error, Sendable {
    case saslError(String)
    case connectionError(String)
    case authFailed(String)
    case invalidXML(String)
    case notConnected
    case tlsFailed(String)
    case timedOut
    case tlsRequired
    case iqError(String)
}

extension XMPPError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .saslError(let text): return "SASL error: \(text)"
        case .connectionError(let text): return "Connection: \(text)"
        case .authFailed(let text): return "Auth failed: \(text)"
        case .invalidXML(let text): return "Invalid XML: \(text)"
        case .notConnected: return "Not connected"
        case .tlsFailed(let text): return "TLS failed: \(text)"
        case .timedOut: return "Auth timed out"
        case .tlsRequired: return "Server requires TLS, retrying with DirectTLS"
        case .iqError(let text): return "IQ error: \(text)"
        }
    }
}