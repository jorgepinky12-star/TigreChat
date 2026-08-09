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
}
