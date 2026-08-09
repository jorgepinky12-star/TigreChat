import Foundation

actor XMPPMUCManager {
    private let connection: XMPPConnection
    private var joinedRooms: Set<String> = []
    private var idCounter: UInt32 = 0

    init(connection: XMPPConnection) {
        self.connection = connection
    }

    var rooms: [String] { Array(joinedRooms) }

    func joinRoom(jid: String, nickname: String) async throws {
        let roomJID = "\(jid)/\(nickname)"
        let presence = """
        <presence to='\(roomJID.xmlEscaped)'>
          <x xmlns='http://jabber.org/protocol/muc'/>
        </presence>
        """
        try await connection.send(string: presence)
        joinedRooms.insert(jid)
    }

    func leaveRoom(jid: String, nickname: String) async throws {
        let roomJID = "\(jid)/\(nickname)"
        let presence = "<presence to='\(roomJID.xmlEscaped)' type='unavailable'/>"
        try await connection.send(string: presence)
        joinedRooms.remove(jid)
    }

    func sendGroupMessage(roomJID: String, body: String) async throws {
        let id = nextID()
        let xml = "<message id='\(id)' to='\(roomJID.xmlEscaped)' type='groupchat'><body>\(body.xmlEscaped)</body></message>"
        try await connection.send(string: xml)
    }

    private func nextID() -> String {
        idCounter += 1
        return "muc\(idCounter)"
    }
}
