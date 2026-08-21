import Foundation
import SwiftData

/// Huella DTLS-SRTP aceptada por contacto (TOFU, REQ-JINGLE-011).
///
/// D4 del diseño: las huellas son datos de confianza PÚBLICOS (derivan de
/// claves públicas DTLS), no secretos — el store SwiftData del sandbox de la
/// app protege la integridad del ancla igual que la verificación de identidad
/// OMEMO. Por eso van aquí y NO en el Keychain.
@Model
final class FingerprintEntity {
    /// JID del contacto: un contacto tiene UNA huella aceptada (upsert por jid
    /// en el store).
    var jid: String
    /// Valor normalizado (hex compacto, mayúsculas — igual que el parser Jingle).
    var fingerprint: String
    var firstSeen: Date
    var lastSeen: Date

    init(jid: String, fingerprint: String, firstSeen: Date = .now, lastSeen: Date = .now) {
        self.jid = jid
        self.fingerprint = fingerprint
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}