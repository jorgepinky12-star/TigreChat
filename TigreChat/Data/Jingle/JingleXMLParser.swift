//
//  JingleXMLParser.swift
//  TigreChat
//
//  Parser XML real de stanzas Jingle: valida namespace `urn:xmpp:jingle:1`,
//  interpreta action/sid/initiator/responder y extrae description RTP
//  (XEP-0167), fingerprint DTLS (XEP-0320) y candidates ICE (XEP-0176).
//
//  El fingerprint se normaliza (sin espacios, mayúsculas) para poder
//  compararlo contra el certificado local derivado del DTLS-SRTP.

import Foundation

struct JingleXMLParser: JingleParsing {

    func parse(_ rawXML: String) throws -> JingleStanza {
        guard let root = OMEMOXMLElement.parse(rawXML) else {
            throw JingleParseError.malformed("xml inválido")
        }
        guard let jingle = root.name == "jingle" ? root : root.firstDescendant(named: "jingle") else {
            throw JingleParseError.missingJingle
        }
        guard jingle.attribute("xmlns") == "urn:xmpp:jingle:1" else {
            throw JingleParseError.malformed("namespace no jingle")
        }
        guard let actionRaw = jingle.attribute("action") else {
            throw JingleParseError.missingAction
        }
        guard let action = JingleAction(rawValue: actionRaw) else {
            throw JingleParseError.unknownAction(actionRaw)
        }
        let sid = jingle.attribute("sid") ?? ""
        let reason = jingle.firstChild(named: "reason")?.children.first?.name
        let contents = jingle.children
            .filter { $0.name == "content" }
            .map(parseContent)
        return JingleStanza(
            action: action,
            sid: sid,
            initiator: jingle.attribute("initiator"),
            responder: jingle.attribute("responder"),
            terminateReason: reason,
            contents: contents
        )
    }

    private func parseContent(_ content: OMEMOXMLElement) -> JingleContent {
        let description = content.firstChild(named: "description")
        let media = description?.attribute("media")
        let payloadTypes = description?.children
            .filter { $0.name == "payload-type" }
            .compactMap { pt -> PayloadType? in
                guard let id = pt.attribute("id").flatMap(Int.init),
                      let name = pt.attribute("name"),
                      let clockrate = pt.attribute("clockrate").flatMap(Int.init) else {
                    return nil
                }
                return PayloadType(
                    id: id,
                    name: name,
                    clockrate: clockrate,
                    channels: pt.attribute("channels").flatMap(Int.init)
                )
            } ?? []

        let security = content.firstChild(named: "security")
        let fingerprint: DTLSFingerprint? = if let fp = security?.firstChild(named: "fingerprint"),
            let hash = fp.attribute("hash"), !hash.isEmpty {
            DTLSFingerprint(
                hash: hash,
                value: Self.normalizedFingerprint(fp.text),
                setup: security?.firstChild(named: "setup")?.text ?? ""
            )
        } else {
            nil
        }

        let candidates = content.firstChild(named: "transport")?.children
            .filter { $0.name == "candidate" }
            .compactMap { c -> JingleCandidate? in
                guard let component = c.attribute("component").flatMap(Int.init),
                      let foundation = c.attribute("foundation"),
                      let generation = c.attribute("generation").flatMap(Int.init),
                      let id = c.attribute("id"),
                      let ip = c.attribute("ip"),
                      let network = c.attribute("network").flatMap(Int.init),
                      let port = c.attribute("port").flatMap(Int.init),
                      let priority = c.attribute("priority").flatMap(Int.init),
                      let proto = c.attribute("protocol"),
                      let type = c.attribute("type") else {
                    return nil
                }
                return JingleCandidate(
                    component: component,
                    foundation: foundation,
                    generation: generation,
                    id: id,
                    ip: ip,
                    network: network,
                    port: port,
                    priority: priority,
                    protocol: proto,
                    type: type
                )
            } ?? []

        return JingleContent(
            creator: content.attribute("creator"),
            name: content.attribute("name"),
            media: media,
            payloadTypes: payloadTypes,
            fingerprint: fingerprint,
            candidates: candidates
        )
    }

    /// Normaliza un fingerprint DTLS a forma canónica: solo dígitos hex,
    /// en mayúsculas, sin separadores (espacios, dos puntos ni guiones).
    /// Es la base de comparación estable contra el fingerprint local
    /// derivado del DTLS-SRTP (formato RFC 4572 es independiente de
    /// separadores y de mayúsculas).
    static func normalizedFingerprint(_ raw: String) -> String {
        raw.uppercased().filter { $0.isHexDigit }
    }
}