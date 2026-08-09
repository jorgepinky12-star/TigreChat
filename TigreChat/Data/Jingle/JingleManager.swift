import Foundation

enum JingleAction: String, Sendable {
    case sessionInitiate = "session-initiate"
    case sessionAccept = "session-accept"
    case sessionTerminate = "session-terminate"
    case transportInfo = "transport-info"
    case transportReplace = "transport-replace"
    case sessionInfo = "session-info"

    var stanzaType: String {
        switch self {
        case .sessionInitiate, .sessionAccept: return "set"
        case .sessionTerminate: return "set"
        case .transportInfo: return "set"
        default: return "set"
        }
    }
}

struct JingleSession: Sendable {
    let sid: String
    let initiator: String
    let responder: String?
    var action: JingleAction
    var state: JingleState
}

enum JingleState: Sendable {
    case pending
    case active
    case ended
}

actor JingleManager {
    private let connection: XMPPConnection
    private var sessions: [String: JingleSession] = [:]
    private var idCounter: UInt32 = 0

    private var incomingCallContinuation: AsyncStream<(sid: String, initiator: String, sdp: String)>.Continuation?
    let incomingCallStream: AsyncStream<(sid: String, initiator: String, sdp: String)>

    init(connection: XMPPConnection) {
        self.connection = connection
        var cont: AsyncStream<(sid: String, initiator: String, sdp: String)>.Continuation?
        incomingCallStream = AsyncStream { continuation in cont = continuation }
        incomingCallContinuation = cont
    }

    func sendSessionInitiate(to jid: String, sid: String, sdp: String, isVideo: Bool) async throws {
        let media = isVideo ? "video" : "audio"
        let id = nextID()
        let xml = """
        <iq id='\(id)' to='\(jid.xmlEscaped)' type='set'>
          <jingle xmlns='urn:xmpp:jingle:1' action='session-initiate' sid='\(sid)' initiator='\(jid.xmlEscaped)'>
            <content creator='initiator' name='\(media)'>
              <description xmlns='urn:xmpp:jingle:apps:rtp:1' media='\(media)'>
                <payload-type id='96' name='opus' clockrate='48000'/>
                <payload-type id='97' name='VP8' clockrate='90000'/>
              </description>
              <transport xmlns='urn:xmpp:jingle:transports:ice-udp:1'/>
            </content>
          </jingle>
        </iq>
        """
        try await connection.send(string: xml)
    }

    func sendSessionAccept(to jid: String, sid: String, sdp: String) async throws {
        let id = nextID()
        let xml = """
        <iq id='\(id)' to='\(jid.xmlEscaped)' type='set'>
          <jingle xmlns='urn:xmpp:jingle:1' action='session-accept' sid='\(sid)' initiator='\(jid.xmlEscaped)'>
            <content creator='responder' name='audio'>
              <description xmlns='urn:xmpp:jingle:apps:rtp:1' media='audio'/>
              <transport xmlns='urn:xmpp:jingle:transports:ice-udp:1'/>
            </content>
          </jingle>
        </iq>
        """
        try await connection.send(string: xml)
    }

    func sendSessionTerminate(to jid: String, sid: String, reason: String = "success") async throws {
        let id = nextID()
        let xml = """
        <iq id='\(id)' to='\(jid.xmlEscaped)' type='set'>
          <jingle xmlns='urn:xmpp:jingle:1' action='session-terminate' sid='\(sid)'>
            <reason><\(reason)/></reason>
          </jingle>
        </iq>
        """
        try await connection.send(string: xml)
    }

    func sendTransportInfo(to jid: String, sid: String, candidate: ICECandidate) async throws {
        let id = nextID()
        let xml = """
        <iq id='\(id)' to='\(jid.xmlEscaped)' type='set'>
          <jingle xmlns='urn:xmpp:jingle:1' action='transport-info' sid='\(sid)'>
            <content creator='initiator' name='audio'>
              <transport xmlns='urn:xmpp:jingle:transports:ice-udp:1'>
                <candidate component='1' foundation='1' generation='0' id='\(candidate.sdpMid)' ip='0.0.0.0' network='1' port='9' priority='0' protocol='udp' type='host'/>
              </transport>
            </content>
          </jingle>
        </iq>
        """
        try await connection.send(string: xml)
    }

    func extractSDP(from jingleXML: String) -> String {
        ""
    }

    func handleJingleStanza(xml: String) {
        if xml.contains("action='session-initiate'") {
            if let sid = extractAttr(xml, "sid"),
               let initiator = extractAttr(xml, "initiator") {
                incomingCallContinuation?.yield((sid, initiator, xml))
            }
        }
    }

    private func extractAttr(_ xml: String, _ attr: String) -> String? {
        guard let range = xml.range(of: "\(attr)='") else { return nil }
        let remainder = xml[range.upperBound...]
        guard let end = remainder.range(of: "'") else { return nil }
        return String(remainder[..<end.lowerBound])
    }

    private func nextID() -> String {
        idCounter += 1
        return "j\(idCounter)"
    }
}
