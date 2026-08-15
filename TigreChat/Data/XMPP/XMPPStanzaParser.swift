import Foundation
import os

struct StreamFeatures: Sendable {
    var startTLSRequired: Bool = false
    var startTLSAvailable: Bool = false
    var saslMechanisms: [String] = []
    var bindAvailable: Bool = false
    var sessionAvailable: Bool = false
}

actor XMPPStanzaParser {
    private var buffer = ""
    private var currentDepth = 0
    private var stanzaCallback: (@Sendable (XMPPStanza) -> Void)?

    func setStanzaCallback(_ callback: @Sendable @escaping (XMPPStanza) -> Void) {
        stanzaCallback = callback
    }

    func reset() {
        buffer = ""
        currentDepth = 0
    }

    func appendData(_ data: Data) {
        guard let string = String(data: data, encoding: .utf8) else {
            os_log("[Parser] appendData(%d): <no utf8>", log: connLog, type: .debug, data.count)
            return
        }
        os_log("[Parser] appendData(%d): %{public}s", log: connLog, type: .debug, data.count, String(string.prefix(300)))
        buffer += string
        processBuffer()
    }

    private func processBuffer() {
        while let stanza = extractNextStanza() {
            if let parsed = parseStanza(stanza) {
                os_log("[Parser] stanza -> %{public}s", log: connLog, type: .debug, describe(parsed))
                stanzaCallback?(parsed)
            } else {
                os_log("[Parser] stanza dropped: %{public}s", log: connLog, type: .debug, String(stanza.prefix(120)))
            }
        }
    }

    private func describe(_ stanza: XMPPStanza) -> String {
        switch stanza {
        case .streamOpen: return "streamOpen"
        case .streamClose: return "streamClose"
        case .streamFeatures: return "streamFeatures"
        case .starttls: return "starttls"
        case .proceed: return "proceed"
        case .challenge: return "challenge"
        case .success: return "success"
        case .failure: return "failure"
        case .message: return "message"
        case .presence: return "presence"
        case .iq: return "iq"
        case .streamError: return "streamError"
        case .unknown: return "unknown"
        }
    }

    private func extractNextStanza() -> String? {
        if buffer.hasPrefix("<?xml") {
            if let range = buffer.range(of: "?>") {
                let xmlDecl = String(buffer[..<range.upperBound])
                buffer = String(buffer[range.upperBound...])
                return xmlDecl
            }
            return nil
        }

        if buffer.hasPrefix("<stream:stream") || buffer.hasPrefix("<stream ") {
            if let range = buffer.range(of: ">") {
                let tag = String(buffer[...range.lowerBound])
                if tag.hasSuffix("/>") || true {
                    let result = String(buffer[..<range.upperBound])
                    buffer = String(buffer[range.upperBound...])
                    return result
                }
            }
            return nil
        }

        if buffer.hasPrefix("</stream:stream>") {
            buffer = String(buffer.dropFirst("</stream:stream>".count))
            return "</stream:stream>"
        }

        var depth = 0
        var i = buffer.startIndex
        var startTagStart: String.Index?

        while i < buffer.endIndex {
            if buffer[i] == "<" {
                if startTagStart == nil { startTagStart = i }
                let rest = buffer[i...]
                if rest.hasPrefix("</") {
                    if let closeBracket = buffer[i...].firstIndex(of: ">") {
                        depth -= 1
                        if depth == 0, let start = startTagStart {
                            let end = buffer.index(after: closeBracket)
                            let stanza = String(buffer[start..<end])
                            buffer = String(buffer[end...])
                            return stanza
                        }
                        i = buffer.index(after: closeBracket)
                        continue
                    }
                } else if rest.hasPrefix("<?xml") {
                    if let end = buffer[i...].range(of: "?>") {
                        i = end.upperBound
                        continue
                    }
                    return nil
                } else if rest.hasPrefix("<!--") {
                    if let end = buffer[i...].range(of: "-->") {
                        i = end.upperBound
                        startTagStart = nil
                        continue
                    }
                    return nil
                } else if let closeBracket = buffer[i...].firstIndex(of: ">") {
                    let tag = buffer[i...closeBracket]
                    if tag.hasSuffix("/>") {
                        if depth == 0 {
                            let end = buffer.index(after: closeBracket)
                            let stanza = String(buffer[..<end])
                            buffer = String(buffer[end...])
                            return stanza
                        }
                        i = buffer.index(after: closeBracket)
                        continue
                    } else {
                        depth += 1
                        i = buffer.index(after: closeBracket)
                        continue
                    }
                }
            }
            i = buffer.index(after: i)
        }
        return nil
    }

    private func parseStanza(_ xml: String) -> XMPPStanza? {
        if xml.hasPrefix("<?xml") {
            return nil
        }
        if xml.hasPrefix("<stream:stream") || xml.hasPrefix("<stream ") {
            let attrs = extractAttributes(from: xml)
            return .streamOpen(StreamOpen.from(attributes: attrs) ?? StreamOpen(to: "", version: "1.0"))
        }
        if xml == "</stream:stream>" {
            return .streamClose
        }
        if xml.hasPrefix("<starttls") {
            return .starttls
        }
        if xml.hasPrefix("<proceed") {
            return .proceed
        }
        if xml.hasPrefix("<challenge") {
            let text = extractText(from: xml)
            return .challenge(text)
        }
        if xml.hasPrefix("<success") {
            let text = extractText(from: xml)
            return .success(text)
        }
        if xml.hasPrefix("<failure") {
            let text = extractText(from: xml)
            return .failure(text)
        }
        if xml.hasPrefix("<message ") {
            return parseMessage(xml)
        }
        if xml.hasPrefix("<presence") {
            return parsePresence(xml)
        }
        if xml.hasPrefix("<iq ") {
            return parseIQ(xml)
        }
        if xml.hasPrefix("<stream:features") {
            let features = parseStreamFeatures(xml)
            return .streamFeatures(features)
        }
        if xml.hasPrefix("<stream:error") {
            let text = extractText(from: xml)
            return .streamError(text)
        }
        return .unknown(xml)
    }

    private func parseStreamFeatures(_ xml: String) -> StreamFeatures {
        var features = StreamFeatures()

        if xml.contains("<starttls") {
            if xml.contains("<required/>") || xml.contains("<required />") {
                features.startTLSRequired = true
            } else {
                features.startTLSAvailable = true
            }
        }

        if let mechanismsRange = xml.range(of: "<mechanisms"),
           let mechanismsCloseRange = xml[mechanismsRange.lowerBound...].range(of: "</mechanisms>") {
            let mechanismsXML = String(xml[mechanismsRange.lowerBound..<mechanismsCloseRange.lowerBound])
            var searchStart = mechanismsXML.startIndex
            while let tagRange = mechanismsXML[searchStart...].range(of: "<mechanism>") {
                let afterOpen = mechanismsXML[tagRange.upperBound...]
                if let closeRange = afterOpen.range(of: "</mechanism>") {
                    let mechanism = String(afterOpen[..<closeRange.lowerBound])
                    features.saslMechanisms.append(mechanism)
                    searchStart = closeRange.upperBound
                } else {
                    break
                }
            }
        }

        if xml.contains("<bind") {
            features.bindAvailable = true
        }
        if xml.contains("<session") {
            features.sessionAvailable = true
        }

        return features
    }

    private func parseMessage(_ xml: String) -> XMPPStanza {
        let attrs = extractAttributes(from: xml)
        let body = extractFirstTag(xml, tag: "body")
        let thread = extractFirstTag(xml, tag: "thread")
        let delay = extractDelayTimestamp(from: xml)
        let stanza = MessageStanza(
            id: attrs["id"] ?? UUID().uuidString,
            from: attrs["from"],
            to: attrs["to"] ?? "",
            type: attrs["type"] ?? "chat",
            body: body,
            thread: thread,
            timestamp: delay ?? Date(),
            rawXML: xml,
            delay: delay,
            hasReceiptRequest: xml.contains("urn:xmpp:receipts") && xml.contains("<request"),
            receiptID: extractReceiptID(from: xml),
            marker: extractMarker(from: xml),
            oobURL: OOBParser.extractURL(from: xml)
        )
        return .message(stanza)
    }

    private func parsePresence(_ xml: String) -> XMPPStanza {
        let attrs = extractAttributes(from: xml)
        let show = extractFirstTag(xml, tag: "show")
        let status = extractFirstTag(xml, tag: "status")
        let stanza = PresenceStanza(
            from: attrs["from"],
            to: attrs["to"],
            type: attrs["type"],
            show: show,
            status: status
        )
        return .presence(stanza)
    }

    private func parseIQ(_ xml: String) -> XMPPStanza {
        let attrs = extractAttributes(from: xml)
        let type = IQType(rawValue: attrs["type"] ?? "get") ?? .get
        let payload: IQPayload?
        if let (xmlns, children) = extractQuery(from: xml) {
            payload = .query(xmlns: xmlns, children: children)
        } else if let jingle = extractElement(xml, element: "jingle") {
            payload = .custom(xml: jingle)
        } else {
            payload = nil
        }
        let stanza = IQStanza(
            id: attrs["id"] ?? UUID().uuidString,
            from: attrs["from"],
            to: attrs["to"],
            type: type,
            payload: payload,
            rawXML: xml
        )
        return .iq(stanza)
    }

    private func extractAttributes(from xml: String) -> [String: String] {
        var attrs: [String: String] = [:]
        let pattern = try? NSRegularExpression(pattern: "([\\w:.-]+)\\s*=\\s*(?:'([^']*)'|\"([^\"]*)\")")

        // SÓLO los atributos del elemento raíz: la regex global sobre todo el
        // XML pisaría el id del `<iq>` con ids anidados (p. ej. el `id` de un
        // `<item id='...'>` dentro de un result de pubsub).
        let rootTag: String
        if let close = xml.firstIndex(of: ">") {
            rootTag = String(xml[..<close])
        } else {
            rootTag = xml
        }
        let nsRange = NSRange(rootTag.startIndex..<rootTag.endIndex, in: rootTag)
        pattern?.enumerateMatches(in: rootTag, range: nsRange) { match, _, _ in
            // OJO: NO filtrar por numberOfRanges — con 3 grupos de captura un
            // match real reporta 4 ranges (match completo + grupos), y el
            // guard `== 3` anterior dejaba `attrs` SIEMPRE vacío, rompiendo
            // todos los stanzas entrantes (id/from/type perdidos).
            guard let match else { return }
            let key = String(rootTag[Range(match.range(at: 1), in: rootTag)!])
            let singleQuoted = match.range(at: 2).location != NSNotFound ? String(rootTag[Range(match.range(at: 2), in: rootTag)!]) : nil
            let doubleQuoted = match.range(at: 3).location != NSNotFound ? String(rootTag[Range(match.range(at: 3), in: rootTag)!]) : nil
            attrs[key] = singleQuoted ?? doubleQuoted
        }
        return attrs
    }

    private func extractText(from xml: String) -> String {
        guard let start = xml.firstIndex(of: ">"),
              let end = xml.lastIndex(of: "<"),
              start < end else { return "" }
        return String(xml[xml.index(after: start)..<end])
    }

    private func extractFirstTag(_ xml: String, tag: String) -> String? {
        guard let openStart = xml.range(of: "<\(tag)") else { return nil }
        guard let openEnd = xml[openStart.lowerBound...].range(of: ">") else { return nil }
        let afterOpen = xml[openEnd.upperBound...]
        let closeTag = "</\(tag)>"
        guard let closeRange = afterOpen.range(of: closeTag) else { return nil }
        return String(afterOpen[..<closeRange.lowerBound])
    }

    // MARK: - XEP-0203 Delayed Delivery

    /// Extrae el timestamp `stamp` de `<delay xmlns='urn:xmpp:delay' stamp='...'/>`.
    private func extractDelayTimestamp(from xml: String) -> Date? {
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

    // MARK: - XEP-0184 Message Delivery Receipts

    /// Extrae el `id` de `<received xmlns='urn:xmpp:receipts' id='...'/>`.
    private func extractReceiptID(from xml: String) -> String? {
        guard xml.contains("urn:xmpp:receipts"),
              let open = xml.range(of: "<received"),
              let close = xml[open.upperBound...].range(of: ">") else { return nil }
        let tag = String(xml[open.lowerBound..<close.upperBound])
        guard let idRange = tag.range(of: "id='") ?? tag.range(of: "id=\"") else { return nil }
        let after = tag[idRange.upperBound...]
        guard let end = after.firstIndex(of: "'") ?? after.firstIndex(of: "\"") else { return nil }
        return String(after[..<end])
    }

    // MARK: - XEP-0333 Chat Markers

    /// Extrae `<marker xmlns='urn:xmpp:chat-markers:0'><kind id='...'/></marker>`.
    private func extractMarker(from xml: String) -> MessageMarker? {
        guard xml.contains("urn:xmpp:chat-markers:0") else { return nil }
        for kind in ["read", "displayed", "acknowledged", "received", "gone"] {
            guard let open = xml.range(of: "<\(kind)"),
                  let close = xml[open.upperBound...].range(of: ">") else { continue }
            let tag = String(xml[open.lowerBound..<close.upperBound])
            guard let idRange = tag.range(of: "id='") ?? tag.range(of: "id=\"") else { return nil }
            let after = tag[idRange.upperBound...]
            guard let end = after.firstIndex(of: "'") ?? after.firstIndex(of: "\"") else { return nil }
            return MessageMarker(kind: kind, id: String(after[..<end]))
        }
        return nil
    }

    // MARK: - IQ payload extraction

    /// Extrae `<query xmlns='...'>children</query>` (o self-closing) de un IQ.
    private func extractQuery(from xml: String) -> (xmlns: String, children: String)? {
        guard let open = xml.range(of: "<query") else { return nil }
        let afterOpen = xml[open.upperBound...]
        guard let close = afterOpen.range(of: ">") else { return nil }
        let tag = String(xml[open.lowerBound..<close.upperBound])

        let xmlns: String
        if let nsRange = tag.range(of: "xmlns='") {
            let after = tag[nsRange.upperBound...]
            guard let end = after.firstIndex(of: "'") else { return nil }
            xmlns = String(after[..<end])
        } else if let nsRange = tag.range(of: "xmlns=\"") {
            let after = tag[nsRange.upperBound...]
            guard let end = after.firstIndex(of: "\"") else { return nil }
            xmlns = String(after[..<end])
        } else {
            return nil
        }

        let tagEnd = close.upperBound
        if xml[open.lowerBound..<tagEnd].hasSuffix("/>") {
            return (xmlns, "")
        }
        guard let closeTag = xml[tagEnd...].range(of: "</query>") else { return (xmlns, "") }
        return (xmlns, String(xml[tagEnd..<closeTag.lowerBound]))
    }

    /// Extrae un elemento completo (p. ej. `<jingle>...</jingle>`) del XML.
    private func extractElement(_ xml: String, element: String) -> String? {
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
}
