//
//  JingleStanza.swift
//  TigreChat
//
//  Modelo de datos Jingle (XEP-0166), RTP description (XEP-0167),
//  DTLS-SRTP security (XEP-0320) e ICE-UDP transport (XEP-0176).
//
//  Fase 1: llamadas de audio con session-initiate/accept/terminate
//  y transport-info. video/session-info quedan como no-op en el manager.
//

import Foundation

/// Acciones Jingle del namespace `urn:xmpp:jingle:1`.
enum JingleAction: String, CaseIterable, Sendable {
    case sessionInitiate = "session-initiate"
    case sessionAccept = "session-accept"
    case sessionTerminate = "session-terminate"
    case transportInfo = "transport-info"
    case transportReplace = "transport-replace"
    case sessionInfo = "session-info"
}

/// Elemento `<jingle/>` ya interpretado. `contents` refleja los
/// `<content/>` recibidos; el repo decide cuáles procesar.
struct JingleStanza: Sendable, Equatable {
    let action: JingleAction
    let sid: String
    let initiator: String?
    let responder: String?
    let terminateReason: String?
    let contents: [JingleContent]
}

/// Un `<content/>` con su description RTP, security DTLS y transport ICE.
struct JingleContent: Sendable, Equatable {
    let creator: String?
    let name: String?
    let media: String?
    let payloadTypes: [PayloadType]
    let fingerprint: DTLSFingerprint?
    let candidates: [JingleCandidate]
}

/// `<payload-type/>` dentro de la description XEP-0167.
struct PayloadType: Sendable, Equatable {
    let id: Int
    let name: String
    let clockrate: Int
    let channels: Int?
}

/// `<fingerprint/>` + `<setup/>` dentro de `<security/>` XEP-0320.
struct DTLSFingerprint: Sendable, Equatable {
    let hash: String
    /// Valor normalizado: sin espacios ni saltos de línea, en mayúsculas.
    let value: String
    let setup: String
}

/// `<candidate/>` del transport ICE-UDP (XEP-0176).
struct JingleCandidate: Sendable, Equatable {
    let component: Int
    let foundation: String
    let generation: Int
    let id: String
    let ip: String
    let network: Int
    let port: Int
    let priority: Int
    let `protocol`: String
    let type: String
}

/// Abstracción del parser: el manager despacha stanzas parseadas.
protocol JingleParsing: Sendable {
    func parse(_ rawXML: String) throws -> JingleStanza
}

/// Errores de parseo. El manager los trata en silencio siguiendo
/// REQ-JINGLE-001 (malformed se ignora sin mutar estado).
enum JingleParseError: Error, Sendable, Equatable {
    case missingJingle
    case missingAction
    case unknownAction(String)
    case malformed(String)
}

/// Abstracción de envío para que el manager sea testeable sin red.
protocol JingleTransport: Sendable {
    func send(string: String) async throws
}

extension XMPPConnection: JingleTransport {}