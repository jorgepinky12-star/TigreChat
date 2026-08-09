import Foundation
import Observation

@MainActor
@Observable
final class ChatListViewModel {
    private(set) var conversations: [Conversation] = []
    private(set) var isLoading = false
    var searchText = ""
    var showNewChat = false
    var showNewGroup = false
    private(set) var isConnected = false

    var filteredConversations: [Conversation] {
        guard !searchText.isEmpty else { return conversations }
        return conversations.filter { $0.title.localizedStandardContains(searchText) }
    }

    let messageRepository: XMPPMessageRepository
    let sendFileUseCase: SendFileUseCase?
    let xmppClient: XMPPClient

    private let loadConversations: LoadConversationsUseCase
    private let authRepository: AuthRepository
    private let groupRepository: GroupRepository?
    private var messageListenerTask: Task<Void, Never>?

    init(
        loadConversations: LoadConversationsUseCase,
        messageRepository: XMPPMessageRepository,
        authRepository: AuthRepository,
        groupRepository: GroupRepository? = nil,
        sendFileUseCase: SendFileUseCase? = nil,
        xmppClient: XMPPClient
    ) {
        self.loadConversations = loadConversations
        self.messageRepository = messageRepository
        self.authRepository = authRepository
        self.groupRepository = groupRepository
        self.sendFileUseCase = sendFileUseCase
        self.xmppClient = xmppClient
    }

    func loadConversations() async {
        isLoading = true
        isConnected = await xmppClient.isAuthenticated
        do {
            conversations = try await loadConversations.execute()
            conversations.sort { ($0.lastTimestamp ?? .distantPast) > ($1.lastTimestamp ?? .distantPast) }
        } catch {
            conversations = []
        }
        isLoading = false
    }

    func listenToMessages() {
        guard messageListenerTask == nil else { return }
        messageListenerTask = Task { [weak self] in
            guard let self else { return }
            for await _ in messageRepository.messageStream {
                await loadConversations()
            }
        }
    }

    func startChat(with jid: String) {
        if !conversations.contains(where: { $0.jid == jid }) {
            let conv = Conversation(jid: jid, title: jid)
            conversations.insert(conv, at: 0)
        }
    }

    isolated deinit {
        messageListenerTask?.cancel()
    }

    func createGroup(name: String, subject: String?) async {
        do {
            let room = try await groupRepository?.createRoom(name: name, subject: subject)
            if let room {
                let conv = Conversation(jid: room.jid, title: room.name, isGroup: true)
                conversations.insert(conv, at: 0)
            }
        } catch {}
    }

    func logout() async {
        await authRepository.disconnect()
    }
}
