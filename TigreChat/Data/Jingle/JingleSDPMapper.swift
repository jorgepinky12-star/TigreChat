//
//  JingleSDPMapper.swift
//  TigreChat
//
//  Mapeo bidireccional JingleContent ⇄ SessionDescription.
//
//  Fase 1: las credenciales ICE son constantes compartidas (ufrag/pwd
//  fijos e iguales en ambos extremos) — el intercambio real de hielo
//  llega por transport-info. Los candidates NO se vuelcan al SDP inicial:
//  viajan como stanzas transport-info separadas.

import Foundation

struct JingleSDPMapper: Sendable {

    /// Credenciales ICE fase 1: fijas e idénticas en ambos extremos para
    /// que el par funcione sin negociación real de ufrag/pwd.
    static let iceUsernameFragment = "tigrechat"
    static let icePassword = "tigrechat1234567890abcdef"

    enum MappingError: Error, Sendable, Equatable {
        /// Falta description RTP usable (media vacío o sin payload-types).
        case missingDescription
        /// Línea SDP que no se pudo interpretar.
        case malformedSDP(String)
    }

    /// JingleContent → SDP (offer o answer). En fase 1 siempre genera
    /// `m=<media> 9 UDP/TLS/RTP/SAVPF` con puerto placeholder 9 — el puerto
    /// real llega por transport-info, nunca "0.0.0.0:9" como candidate real.
    func sdp(from content: JingleContent, type: SDPType) throws -> SessionDescription {
        guard let media = content.media, !media.isEmpty, !content.payloadTypes.isEmpty else {
            throw MappingError.missingDescription
        }
        let ids = content.payloadTypes.map { String($0.id) }.joined(separator: " ")
        var lines = [
            "v=0",
            "o=- 2890844526 2890844526 IN IP4 127.0.0.1",
            "s=-",
            "t=0 0",
            "m=\(media) 9 UDP/TLS/RTP/SAVPF \(ids)",
            "c=IN IP4 0.0.0.0",
        ]
        for pt in content.payloadTypes {
            var rtpmap = "a=rtpmap:\(pt.id) \(pt.name)/\(pt.clockrate)"
            if let channels = pt.channels {
                rtpmap += "/\(channels)"
            }
            lines.append(rtpmap)
        }
        if let fingerprint = content.fingerprint {
            lines.append("a=fingerprint:\(fingerprint.hash) \(fingerprint.value)")
            let setup = fingerprint.setup.isEmpty ? "actpass" : fingerprint.setup
            lines.append("a=setup:\(setup)")
        }
        lines.append("a=ice-ufrag:\(Self.iceUsernameFragment)")
        lines.append("a=ice-pwd:\(Self.icePassword)")
        return SessionDescription(sdp: lines.joined(separator: "\r\n") + "\r\n", type: type)
    }

    /// SDP → JingleContent (para reenviar la oferta/respuesta local como
    /// stanza Jingle). Los candidates del transport se añaden aparte.
    func content(from session: SessionDescription, creator: String, name: String) throws -> JingleContent {
        var media: String?
        var payloadTypes: [PayloadType] = []
        var fingerprint: DTLSFingerprint?

        for rawLine in session.sdp.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("m=") {
                let parts = line.components(separatedBy: " ")
                guard parts.count >= 3 else { throw MappingError.malformedSDP(line) }
                // "m=<media> <puerto> <proto> …": media es la parte 0 sin el prefijo.
                media = String(parts[0].dropFirst(2))
            } else if line.hasPrefix("a=rtpmap:") {
                guard let fields = Self.parseRtpmap(String(line.dropFirst("a=rtpmap:".count))) else { continue }
                payloadTypes.append(fields)
            } else if line.hasPrefix("a=fingerprint:") {
                let body = String(line.dropFirst("a=fingerprint:".count))
                let parts = body.components(separatedBy: " ")
                if parts.count >= 2 {
                    fingerprint = DTLSFingerprint(
                        hash: parts[0],
                        value: JingleXMLParser.normalizedFingerprint(parts.dropFirst().joined(separator: " ")),
                        setup: fingerprint?.setup ?? ""
                    )
                }
            } else if line.hasPrefix("a=setup:") {
                let setup = String(line.dropFirst("a=setup:".count))
                if let fp = fingerprint {
                    fingerprint = DTLSFingerprint(hash: fp.hash, value: fp.value, setup: setup)
                }
            }
        }

        guard let resolvedMedia = media else { throw MappingError.missingDescription }
        return JingleContent(
            creator: creator,
            name: name,
            media: resolvedMedia,
            payloadTypes: payloadTypes,
            fingerprint: fingerprint,
            candidates: []
        )
    }

    /// "96 opus/48000/2" → PayloadType. `nil` si no es interpretable.
    private static func parseRtpmap(_ body: String) -> PayloadType? {
        let parts = body.components(separatedBy: " ")
        guard parts.count == 2, let id = Int(parts[0]) else { return nil }
        let codec = parts[1].components(separatedBy: "/")
        guard codec.count >= 2, let clockrate = Int(codec[1]) else { return nil }
        let channels = codec.count > 2 ? Int(codec[2]) : nil
        return PayloadType(id: id, name: codec[0], clockrate: clockrate, channels: channels)
    }
}