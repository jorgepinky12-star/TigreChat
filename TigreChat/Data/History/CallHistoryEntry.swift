import Foundation
import SwiftData

/// Estados terminales del historial (REQ-HIST-002): TODAS las llamadas se
/// registran con su estado; las no respondidas llevan duración 0.
enum CallStatus: String, Sendable {
    case answered
    case unanswered    // timbre agotado (timeout 30s)
    case missed        // no disponible / app en segundo plano (fase-2 PushKit)
    case busy
    case declined
    case failed
}

/// Entrada de historial, una por llamada Jingle (merge por sid, REQ-HIST-003).
///
/// D8 del diseño: relación unidireccional a `ConversationEntity`
/// (`deleteRule: .nullify`, `inverse: nil` — iOS 26 permite relación sin
/// inversa y sin tocar el modelo existente). `direction` y `status` se
/// guardan como raw Strings y se exponen a través de enums puente
/// (patrón `MessageEntity`).
@Model
final class CallHistoryEntry {
    /// Jingle session id, único: las transiciones de UNA llamada
    /// (ringing→connected→ended) actualizan esta misma fila.
    @Attribute(.unique) var sid: String
    var jid: String
    var directionRaw: String
    var statusRaw: String
    var duration: TimeInterval
    var timestamp: Date
    var isVideo: Bool
    @Relationship(deleteRule: .nullify, inverse: nil) var conversation: ConversationEntity?

    init(
        sid: String,
        jid: String,
        direction: CallDirection,
        status: CallStatus,
        duration: TimeInterval = 0,
        timestamp: Date = .now,
        isVideo: Bool = false,
        conversation: ConversationEntity? = nil
    ) {
        self.sid = sid
        self.jid = jid
        self.directionRaw = direction.rawValue
        self.statusRaw = status.rawValue
        self.duration = duration
        self.timestamp = timestamp
        self.isVideo = isVideo
        self.conversation = conversation
    }

    var direction: CallDirection {
        get { CallDirection(rawValue: directionRaw) ?? .incoming }
        set { directionRaw = newValue.rawValue }
    }

    var status: CallStatus {
        get { CallStatus(rawValue: statusRaw) ?? .failed }
        set { statusRaw = newValue.rawValue }
    }
}