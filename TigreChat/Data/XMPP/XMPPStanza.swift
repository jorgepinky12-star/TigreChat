import Foundation

enum XMPPStanza: Sendable {
    case message(MessageStanza)
    case presence(PresenceStanza)
    case iq(IQStanza)
    case streamOpen(StreamOpen)
    case streamClose
    case streamFeatures(StreamFeatures)
    case streamError(String)
    case starttls
    case proceed
    case failure(String)
    case challenge(String)
    case success(String)
    case unknown(String)

    var xml: String {
        switch self {
        case .message(let m): return m.xml
        case .presence(let p): return p.xml
        case .iq(let i): return i.xml
        case .streamOpen(let s): return s.xml
        case .streamClose: return "</stream:stream>"
        case .starttls: return "<starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>"
        case .proceed: return "<proceed xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>"
        case .failure(let text): return "<failure xmlns='urn:ietf:params:xml:ns:xmpp-sasl'><text>\(text)</text></failure>"
        case .challenge(let data): return "<challenge xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>\(data)</challenge>"
        case .success(let data): return "<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>\(data)</success>"
        case .streamFeatures: return ""
        case .streamError(let text): return "<stream:error><text>\(text)</text></stream:error>"
        case .unknown(let xml): return xml
        }
    }
}

struct StreamOpen: Sendable {
    let to: String
    let version: String

    var xml: String {
        "<?xml version='1.0'?><stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' to='\(to)' version='\(version)'>"
    }

    static func from(attributes: [String: String]) -> StreamOpen? {
        guard let to = attributes["to"] else { return nil }
        return StreamOpen(to: to, version: attributes["version"] ?? "1.0")
    }
}

struct MessageStanza: Sendable {
    let id: String
    let from: String?
    let to: String
    let type: String
    let body: String?
    let thread: String?
    let timestamp: Date?
    let rawXML: String
    /// XEP-0203: fecha real de envío cuando el servidor entrega con retraso
    /// (offline, MAM, etc.).
    let delay: Date?
    /// XEP-0184: el remitente pide confirmación de entrega.
    let hasReceiptRequest: Bool
    /// XEP-0184: id del mensaje cuyo `received` recibimos.
    let receiptID: String?
    /// XEP-0333: marker de chat (read/displayed/...).
    let marker: MessageMarker?
    /// XEP-0066: URL de adjunto Out-of-Band (`<x xmlns='jabber:x:oob'><url>`).
    let oobURL: String?

    var xml: String { rawXML }
}

/// XEP-0333 Chat Markers: `read`, `displayed`, `acknowledged`, `received`, `gone`.
struct MessageMarker: Sendable {
    let kind: String
    let id: String
}

struct PresenceStanza: Sendable {
    let from: String?
    let to: String?
    let type: String?
    let show: String?
    let status: String?

    var xml: String {
        var xml = "<presence"
        if let from { xml += " from='\(from)'" }
        if let to { xml += " to='\(to)'" }
        if let type { xml += " type='\(type)'" }
        xml += ">"
        if let show { xml += "<show>\(show)</show>" }
        if let status { xml += "<status>\(status.xmlEscaped)</status>" }
        xml += "</presence>"
        return xml
    }

    static var available: PresenceStanza {
        PresenceStanza(from: nil, to: nil, type: nil, show: nil, status: nil)
    }
}

struct IQStanza: Sendable {
    let id: String
    let from: String?
    let to: String?
    let type: IQType
    let payload: IQPayload?
    let rawXML: String

    var xml: String {
        var xml = "<iq id='\(id)' type='\(type.rawValue)'"
        if let from { xml += " from='\(from)'" }
        if let to { xml += " to='\(to)'" }
        xml += ">"
        if let payload { xml += payload.xml }
        xml += "</iq>"
        return xml
    }

    static func rosterGet(id: String) -> IQStanza {
        IQStanza(id: id, from: nil, to: nil, type: .get, payload: .query(xmlns: "jabber:iq:roster", children: ""), rawXML: "")
    }

    static func bind(id: String, resource: String) -> IQStanza {
        IQStanza(id: id, from: nil, to: nil, type: .set, payload: .bind(resource: resource), rawXML: "")
    }

    static func session(id: String) -> IQStanza {
        IQStanza(id: id, from: nil, to: nil, type: .set, payload: .session, rawXML: "")
    }
}

enum IQType: String, Sendable {
    case get
    case set
    case result
    case error
}

enum IQPayload: Sendable {
    case query(xmlns: String, children: String)
    case bind(resource: String)
    case session
    case custom(xml: String)

    var xml: String {
        switch self {
        case .query(let xmlns, let children):
            return "<query xmlns='\(xmlns)'>\(children)</query>"
        case .bind(let resource):
            return "<bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'><resource>\(resource)</resource></bind>"
        case .session:
            return "<session xmlns='urn:ietf:params:xml:ns:xmpp-session'/>"
        case .custom(let xml):
            return xml
        }
    }
}

extension String {
    var xmlEscaped: String {
        self.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - Roster (RFC 6121)

/// Item del roster tal como lo envía el servidor.
struct RosterItem: Sendable {
    let jid: String
    let name: String?
    let subscription: String
    let ask: String?
    let groups: [String]

    /// true cuando el contacto aún no ha aceptado la suscripción mutua.
    var isPending: Bool {
        subscription == "none" && !(ask ?? "").isEmpty
    }

    init(jid: String, name: String? = nil, subscription: String = "none", ask: String? = nil, groups: [String] = []) {
        self.jid = jid
        self.name = name
        self.subscription = subscription
        self.ask = ask
        self.groups = groups
    }
}

/// Extrae los `<item>` del roster desde el XML de un IQ (result o push).
enum RosterParser {
    static func parseItems(from xml: String) -> [RosterItem] {
        guard let queryStart = xml.range(of: "<query"), let queryEnd = xml.range(of: "</query>") else {
            return []
        }
        let queryXML = xml[queryStart.lowerBound..<queryEnd.lowerBound]

        var items: [RosterItem] = []
        let attrRegex = try? NSRegularExpression(pattern: "([\\w:.-]+)\\s*=\\s*(?:'([^']*)'|\"([^\"]*)\")")
        var searchStart = queryXML.startIndex
        while let itemRange = queryXML[searchStart...].range(of: "<item ") {
            let itemStart = itemRange.lowerBound
            let remainder = queryXML[itemRange.upperBound...]
            guard let close = remainder.range(of: ">") else { break }
            let tagXML = String(queryXML[itemStart..<close.upperBound])

            var attrs: [String: String] = [:]
            let nsRange = NSRange(tagXML.startIndex..<tagXML.endIndex, in: tagXML)
            attrRegex?.enumerateMatches(in: tagXML, range: nsRange) { match, _, _ in
                guard let match, match.numberOfRanges == 3 else { return }
                let key = String(tagXML[Range(match.range(at: 1), in: tagXML)!])
                let single = match.range(at: 2).location != NSNotFound ? String(tagXML[Range(match.range(at: 2), in: tagXML)!]) : nil
                let double = match.range(at: 3).location != NSNotFound ? String(tagXML[Range(match.range(at: 3), in: tagXML)!]) : nil
                attrs[key] = single ?? double
            }

            guard let jid = attrs["jid"] else {
                searchStart = close.upperBound
                continue
            }
            items.append(RosterItem(
                jid: jid,
                name: attrs["name"],
                subscription: attrs["subscription"] ?? "none",
                ask: attrs["ask"]
            ))
            searchStart = close.upperBound
        }
        return items
    }

    /// Extrae el atributo `ver` (XEP-0237 / RFC 6121 §2.6) del `<query
    /// xmlns='jabber:iq:roster'>` de la respuesta. nil cuando el servidor no
    /// envió versión (first request / roster no versionado).
    static func parseVersion(from xml: String) -> String? {
        guard let queryStart = xml.range(of: "<query") else { return nil }
        guard let tagEnd = xml[queryStart.upperBound...].range(of: ">") else { return nil }
        let tag = String(xml[queryStart.lowerBound..<tagEnd.upperBound])
        guard let vRange = tag.range(of: "ver='") ?? tag.range(of: "ver=\"") else { return nil }
        let after = tag[vRange.upperBound...]
        guard let end = after.firstIndex(of: "'") ?? after.firstIndex(of: "\"") else { return nil }
        let ver = String(after[..<end])
        return ver.isEmpty ? nil : ver
    }
}

// MARK: - Adjuntos entrantes (XEP-0066 oob + HTTP Upload)

/// XEP-0066 Out-of-Band Data: extrae la URL de
/// `<x xmlns='jabber:x:oob'><url>…</url></x>`.
enum OOBParser {
    static func extractURL(from xml: String) -> String? {
        guard xml.contains("jabber:x:oob"), let open = xml.range(of: "<url") else { return nil }
        let afterOpen = xml[open.upperBound...]
        guard let close = afterOpen.range(of: ">") else { return nil }
        let contentStart = close.upperBound
        guard let closeTag = xml[contentStart...].range(of: "</url>") else { return nil }
        let url = String(xml[contentStart..<closeTag.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return url.isEmpty ? nil : url
    }
}

/// Detecta adjuntos en un `<message>` y construye un `FileAttachment`.
/// Fuentes: XEP-0066 oob, o bien un body que sea URL de HTTP Upload
/// (XEP-0363, como manda el cliente Android).
enum AttachmentParser {
    static func parse(from xml: String, body: String) -> FileAttachment? {
        let urlString = OOBParser.extractURL(from: xml) ?? bodyURL(body)
        guard let urlString, let url = URL(string: urlString) else { return nil }
        return FileAttachment(
            id: UUID().uuidString,
            url: url,
            mimeType: mimeTypeFor(url),
            size: 0,
            fileName: url.lastPathComponent
        )
    }

    /// Heurística de HTTP Upload: URL absoluta cuyo path contiene `/upload/`
    /// o `/get/` (o el host empieza por `upload.`/`get.`).
    private static func bodyURL(_ body: String) -> String? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        let path = url.path.lowercased()
        let host = url.host?.lowercased() ?? ""
        if path.contains("/upload/") || path.contains("/get/") || host.hasPrefix("upload.") || host.hasPrefix("get.") {
            return trimmed
        }
        return nil
    }

    private static func mimeTypeFor(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "heic", "heif": "image/heic"
        case "mp4", "m4v": "video/mp4"
        case "mov": "video/quicktime"
        case "mp3": "audio/mpeg"
        case "m4a": "audio/mp4"
        case "aac": "audio/aac"
        case "ogg", "opus": "audio/ogg"
        case "wav": "audio/wav"
        case "pdf": "application/pdf"
        default: "application/octet-stream"
        }
    }
}

// MARK: - Carbons (XEP-0280) & Retraction (XEP-0424)

/// Extrae el mensaje reenviado por Message Carbons (`<sent>`/`<received>` con
/// `<forwarded>`). Devuelve nil si el XML no es un eco de carbons.
enum CarbonParser {
    static func parse(from xml: String) -> Message? {
        guard xml.contains("urn:xmpp:carbons:2") else { return nil }
        let isSent = xml.contains("<sent")
        guard let forwarded = extractElement(xml, element: "forwarded") else { return nil }
        guard let msgXML = extractElement(forwarded, element: "message") else { return nil }
        let attrs = extractAttributes(from: msgXML)
        let from = attrs["from"] ?? ""
        let to = attrs["to"] ?? ""
        let type = attrs["type"] ?? "chat"
        let id = attrs["id"] ?? UUID().uuidString
        // `sent` = yo envié desde otro dispositivo (outgoing hacia `to`);
        // `received` = me llegó a otro dispositivo (incoming desde `from`).
        let conversationID = type == "groupchat"
            ? from.components(separatedBy: "/").first ?? from
            : (isSent ? (to.components(separatedBy: "/").first ?? to) : from)
        let body = extractFirstTag(msgXML, tag: "body") ?? ""
        let attachment = AttachmentParser.parse(from: msgXML, body: body)
        return Message(
            id: id,
            conversationId: conversationID,
            senderJID: from,
            text: body,
            timestamp: extractDelayTimestamp(from: msgXML) ?? Date(),
            isOutgoing: isSent,
            status: .delivered,
            type: attachment == nil ? .text : .file,
            attachment: attachment
        )
    }

    // MARK: - XML helpers (mismo estilo que XMPPMAMManager)

    private static func extractAttributes(from xml: String) -> [String: String] {
        var attributes: [String: String] = [:]
        let pattern = "([a-zA-Z0-9_:-]+)='([^']*)'"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return attributes }
        let range = NSRange(location: 0, length: (xml as NSString).length)
        regex.enumerateMatches(in: xml, range: range) { match, _, _ in
            guard let match,
                  let keyRange = Range(match.range(at: 1), in: xml),
                  let valueRange = Range(match.range(at: 2), in: xml) else { return }
            attributes[String(xml[keyRange])] = String(xml[valueRange])
        }
        return attributes
    }

    private static func extractFirstTag(_ xml: String, tag: String) -> String? {
        guard let openStart = xml.range(of: "<\(tag)") else { return nil }
        guard let openEnd = xml[openStart.lowerBound...].range(of: ">") else { return nil }
        let afterOpen = xml[openEnd.upperBound...]
        guard let closeRange = afterOpen.range(of: "</\(tag)>") else { return nil }
        return String(afterOpen[..<closeRange.lowerBound])
    }

    /// Extrae un elemento completo (p. ej. `<forwarded>...</forwarded>`) del XML.
    private static func extractElement(_ xml: String, element: String) -> String? {
        guard let open = xml.range(of: "<\(element)") else { return nil }
        let afterOpen = xml[open.upperBound...]
        guard let close = afterOpen.range(of: ">") else { return nil }
        let tagEnd = close.upperBound
        let fullStart = open.lowerBound
        if xml[fullStart..<tagEnd].hasSuffix("/>") {
            return String(xml[fullStart..<tagEnd])
        }
        guard let closeTag = xml[tagEnd...].range(of: "</\(element)>") else { return nil }
        return String(xml[fullStart..<closeTag.upperBound])
    }

    /// XEP-0203: timestamp de entrega real del mensaje reenviado.
    private static func extractDelayTimestamp(from xml: String) -> Date? {
        guard xml.contains("urn:xmpp:delay") || xml.contains("jabber:x:delay"),
              let open = xml.range(of: "<delay"),
              let close = xml[open.upperBound...].range(of: ">") else { return nil }
        let tag = String(xml[open.lowerBound..<close.upperBound])
        guard let stampRange = tag.range(of: "stamp='") ?? tag.range(of: "stamp=\"") else { return nil }
        let after = tag[stampRange.upperBound...]
        guard let end = after.firstIndex(of: "'") ?? after.firstIndex(of: "\"") else { return nil }
        let stamp = String(after[..<end])

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: stamp) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: stamp)
    }
}

/// Extrae el `id` del mensaje original de una retracción (XEP-0424):
/// `<retracted xmlns='urn:xmpp:message-retract:1' id='original-id'/>` (server)
/// o `<retract ...>` (cliente).
enum RetractionParser {
    static func parseID(from xml: String) -> String? {
        guard let open = xml.range(of: "<retracted") ?? xml.range(of: "<retract") else { return nil }
        guard let tagEnd = xml[open.upperBound...].range(of: ">") else { return nil }
        let tag = String(xml[open.lowerBound..<tagEnd.upperBound])
        guard let idRange = tag.range(of: "id='") ?? tag.range(of: "id=\"") else { return nil }
        let after = tag[idRange.upperBound...]
        guard let end = after.firstIndex(of: "'") ?? after.firstIndex(of: "\"") else { return nil }
        let id = String(after[..<end])
        return id.isEmpty ? nil : id
    }
}
