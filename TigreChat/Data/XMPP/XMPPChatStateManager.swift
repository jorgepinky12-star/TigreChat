import Foundation

actor XMPPChatStateManager {
    enum ChatState: String, Sendable {
        case active
        case composing
        case paused
        case inactive
        case gone
    }

    private let connection: XMPPConnection
    private var debounceTasks: [String: Task<Void, Never>] = [:]
    private var lastState: [String: ChatState] = [:]

    init(connection: XMPPConnection) {
        self.connection = connection
    }

    func sendState(_ state: ChatState, to jid: String) async throws {
        if let last = lastState[jid], last == state { return }
        lastState[jid] = state
        let xml = "<message to='\(jid.xmlEscaped)' type='chat'><\(state.rawValue) xmlns='http://jabber.org/protocol/chatstates'/></message>"
        try await connection.send(string: xml)
    }

    func sendComposing(to jid: String) async throws {
        debounceTasks[jid]?.cancel()
        debounceTasks[jid] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled else { return }
            try? await sendState(.paused, to: jid)
        }
        try await sendState(.composing, to: jid)
    }

    func notifyActive(to jid: String) async throws {
        debounceTasks[jid]?.cancel()
        try await sendState(.active, to: jid)
    }
}
