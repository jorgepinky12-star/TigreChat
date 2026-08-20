import Foundation

struct Call: Identifiable, Hashable, Sendable {
    let id: String
    let jid: String
    let direction: CallDirection
    var state: CallState
    var isVideo: Bool
    var duration: TimeInterval
    var startTime: Date?

    init(id: String = UUID().uuidString, jid: String, direction: CallDirection, isVideo: Bool = false) {
        self.id = id
        self.jid = jid
        self.direction = direction
        self.state = .dialing
        self.isVideo = isVideo
        self.duration = 0
        self.startTime = nil
    }
}

enum CallDirection: String, Sendable {
    case incoming
    case outgoing
}

enum CallState: String, Sendable {
    case dialing
    case ringing
    case connecting
    case connected
    case reconnecting
    /// TOFU (REQ-JINGLE-011): primer contacto con el JID, la huella DTLS
    /// remota aún no está verificada. La llamada queda en pausa hasta que
    /// el usuario acepta la huella (`acceptFingerprint`) o se rechaza.
    case needsVerification
    case ended
    case failed
    case missed
}

enum CallEndReason: Sendable {
    case localHangup
    case remoteHangup
    case declined
    case busy
    case timeout
    case error
    case unknown
}

struct CallMetrics: Sendable {
    var audioLevel: Float
    var packetLoss: Float
    var jitter: Double
    var rtt: Double
}
