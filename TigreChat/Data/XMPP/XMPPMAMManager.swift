import Foundation
import os

/// XEP-0313 Message Archive Management.
///
/// El cliente rutea los `<message>` con `urn:xmpp:mam:2` hacia `resultStream`;
/// este actor los acumula por `queryid` y entrega `[Message]` cuando el IQ
/// `result` de cierre de la query (con `<fin>`) llega vía `IQDispatcher`.
actor XMPPMAMManager {
    private let connection: XMPPConnection
    private var idCounter: UInt32 = 0
    private var iqIDToQueryID: [String: String] = [:]
    private var pendingQueries: [String: PendingQuery] = [:]
    private var consumeTask: Task<Void, Never>?
    private var dispatcher: IQDispatcher?

    private struct PendingQuery {
        var messages: [Message] = []
    }

    init(connection: XMPPConnection) {
        self.connection = connection
    }

    isolated deinit {
        consumeTask?.cancel()
    }

    /// Conecta el stream de resultados MAM del cliente y arranca el consumidor.
    func attach(dispatcher: IQDispatcher, resultStream: AsyncStream<MessageStanza>) {
        self.dispatcher = dispatcher
        guard consumeTask == nil else { return }
        consumeTask = Task { [weak self] in
            guard let self else { return }
            for await stanza in resultStream {
                await self.consume(stanza)
            }
        }
    }

    private func consume(_ stanza: MessageStanza) {
        guard let queryID = extractQueryID(from: stanza.xml),
              var pending = pendingQueries[queryID] else { return }
        guard let message = extractMessage(from: stanza.xml) else { return }
        pending.messages.append(message)
        pendingQueries[queryID] = pending
    }

    /// Cierra una query pendiente cuando el servidor responde con el IQ fin.
    func handleResult(iqID: String) {
        guard let queryID = iqIDToQueryID.removeValue(forKey: iqID) else { return }
        pendingQueries.removeValue(forKey: queryID)
    }

    /// Pide el archivo de un contacto (pagina atrás). `pageID` es el RSM
    /// `first` de la página anterior; si es nil, empieza por la más reciente.
    func requestArchive(jid: String, localJID: String, before: Date? = nil, pageID: String? = nil, limit: Int = 50) async throws -> [Message] {
        setLocalJID(localJID)
        let id = nextID()
        let queryID = UUID().uuidString

        var xml = """
        <iq id='\(id)' type='set'>
          <query xmlns='urn:xmpp:mam:2' queryid='\(queryID)'>
            <x xmlns='jabber:x:data' type='submit'>
              <field var='FORM_TYPE' type='hidden'>
                <value>urn:xmpp:mam:2</value>
              </field>
              <field var='with'>
                <value>\(escapeXML(jid))</value>
              </field>
        """
        if let before {
            xml += """
              <field var='end'>
                <value>\(formatTimestamp(before))</value>
              </field>
            """
        }
        xml += """
            </x>
            <set xmlns='http://jabber.org/protocol/rsm'>
              <max>\(limit)</max>
        """
        if let pageID {
            xml += """
              <before>\(escapeXML(pageID))</before>
            """
        } else if before == nil {
            // Sin filtro temporal: pedimos la página final (los más recientes),
            // igual que el historial de la app de Android.
            xml += """
              <before/>
            """
        }
        xml += """
            </set>
          </query>
        </iq>
        """

        iqIDToQueryID[id] = queryID
        pendingQueries[queryID] = PendingQuery()
        try await connection.send(string: xml)

        // Espera el cierre de la query (IQ result con <fin>) o el timeout.
        let finID = id
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [dispatcher] in
                guard let dispatcher else { throw XMPPError.notConnected }
                _ = try await dispatcher.wait(for: finID, timeout: 30)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 31_000_000_000)
                throw XMPPError.timedOut
            }
            do {
                try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                throw error
            }
        }

        let messages = pendingQueries.removeValue(forKey: queryID)?.messages ?? []
        iqIDToQueryID.removeValue(forKey: id)
        return messages
    }

    /// Pide la página MÁS RECIENTE del archivo global (sin filtro `with`,
    /// XEP-0313) — equivalente a `queryMostRecentPage(null, 20)` del cliente
    /// Android: RSM `<before/>` (página final) + `<max>`. Usado para el
    /// catch-up de mensajes al refrescar la lista de chats.
    func requestRecentGlobal(localJID: String, limit: Int = 20) async throws -> [Message] {
        setLocalJID(localJID)
        let id = nextID()
        let queryID = UUID().uuidString

        let xml = """
        <iq id='\(id)' type='set'>
          <query xmlns='urn:xmpp:mam:2' queryid='\(queryID)'>
            <x xmlns='jabber:x:data' type='submit'>
              <field var='FORM_TYPE' type='hidden'>
                <value>urn:xmpp:mam:2</value>
              </field>
            </x>
            <set xmlns='http://jabber.org/protocol/rsm'>
              <max>\(limit)</max>
              <before/>
            </set>
          </query>
        </iq>
        """

        iqIDToQueryID[id] = queryID
        pendingQueries[queryID] = PendingQuery()
        try await connection.send(string: xml)

        // Espera el cierre de la query (IQ result con <fin>) o el timeout.
        let finID = id
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [dispatcher] in
                guard let dispatcher else { throw XMPPError.notConnected }
                _ = try await dispatcher.wait(for: finID, timeout: 30)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 31_000_000_000)
                throw XMPPError.timedOut
            }
            do {
                try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                throw error
            }
        }

        let messages = pendingQueries.removeValue(forKey: queryID)?.messages ?? []
        iqIDToQueryID.removeValue(forKey: id)
        return messages
    }

    // MARK: - Parsing helpers

    /// Extrae el `queryid` de un `<result xmlns='urn:xmpp:mam:2' queryid='...'>`.
    private func extractQueryID(from xml: String) -> String? {
        guard let open = xml.range(of: "<result") else { return nil }
        let tagEnd = xml[open.upperBound...].range(of: ">")?.upperBound
        guard let tagEnd else { return nil }
        let tag = String(xml[open.lowerBound..<tagEnd])
        guard let range = tag.range(of: "queryid='") ?? tag.range(of: "queryid=\"") else { return nil }
        let after = tag[range.upperBound...]
        guard let end = after.firstIndex(of: "'") ?? after.firstIndex(of: "\"") else { return nil }
        return String(after[..<end])
    }

    /// Extrae el `<message>` real dentro de `<forwarded>` y lo convierte a `Message`.
    private func extractMessage(from xml: String) -> Message? {
        guard let forwarded = extractElement(xml, element: "forwarded") else { return nil }
        guard let msgXML = extractElement(forwarded, element: "message") else { return nil }

        let attrs = extractAttributes(from: msgXML)
        let body = extractFirstTag(msgXML, tag: "body") ?? ""
        let from = attrs["from"] ?? ""
        let to = attrs["to"] ?? ""
        let id = attrs["id"] ?? UUID().uuidString
        let type = attrs["type"] ?? "chat"
        // Saliente si el REMITENTE es nuestro JID (from): en el archivo del
        // remitente ejabberd omite `to` o lo pone con resource, por lo que
        // comparar `to == localJID` (el criterio anterior) marcaba los
        // mensajes propios como entrantes → "eco" de tu propio texto en el
        // catch-up (XEP-0313 mostrar los salientes como si te respondieran).
        let fromBare = from.components(separatedBy: "/").first ?? from
        let isOutgoing = fromBare == localJID
        let conversationId: String
        if type == "groupchat" {
            conversationId = fromBare
        } else if isOutgoing {
            conversationId = to.components(separatedBy: "/").first ?? to
        } else {
            conversationId = fromBare
        }
        let delay = extractDelayTimestamp(from: msgXML)
        let attachment = AttachmentParser.parse(from: msgXML, body: body)

        return Message(
            id: id,
            conversationId: conversationId,
            senderJID: from,
            text: body,
            timestamp: delay ?? Date(),
            isOutgoing: isOutgoing,
            status: .delivered,
            type: attachment == nil ? .text : .file,
            attachment: attachment
        )
    }

    private var localJID: String = ""

    func setLocalJID(_ jid: String) {
        localJID = jid
    }

    private func extractAttributes(from xml: String) -> [String: String] {
        var attributes: [String: String] = [:]
        let pattern = "([a-zA-Z0-9_:-]+)='([^']*)'"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return attributes }
        // Solo la ETIQUETA RAÍZ: ejabberd inyecta en el mensaje archivado los
        // elementos `<archived id='...'>` y `<stanza-id id='...'>` con el id del
        // archivo (16 dígitos). Si se barre el XML completo, esos `id` anidados
        // sobrescriben el id real del mensaje y el deduplicado por id del
        // catch-up MAM falla → cada sync reinserta mensajes duplicados
        // (tanto salientes como entrantes).
        guard let tagEnd = xml.firstIndex(of: ">") else { return attributes }
        let openTag = String(xml[xml.startIndex..<tagEnd])
        let range = NSRange(location: 0, length: (openTag as NSString).length)
        regex.enumerateMatches(in: openTag, range: range) { match, _, _ in
            guard let match,
                  let keyRange = Range(match.range(at: 1), in: openTag),
                  let valueRange = Range(match.range(at: 2), in: openTag) else { return }
            attributes[String(openTag[keyRange])] = String(openTag[valueRange])
        }
        return attributes
    }

    private func extractFirstTag(_ xml: String, tag: String) -> String? {
        guard let openStart = xml.range(of: "<\(tag)") else { return nil }
        guard let openEnd = xml[openStart.lowerBound...].range(of: ">") else { return nil }
        let afterOpen = xml[openEnd.upperBound...]
        guard let closeRange = afterOpen.range(of: "</\(tag)>") else { return nil }
        return String(afterOpen[..<closeRange.lowerBound])
    }

    /// Extrae un elemento completo (p. ej. `<forwarded>...</forwarded>`) del XML.
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

    /// XEP-0203: timestamp de entrega real del mensaje archivado.
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

    private func escapeXML(_ string: String) -> String {
        string.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func formatTimestamp(_ date: Date) -> String {
        ISO8601DateFormatter.string(from: date, timeZone: .current, formatOptions: [.withInternetDateTime, .withFractionalSeconds])
    }

    private func nextID() -> String {
        idCounter += 1
        return "mam\(idCounter)"
    }
}
