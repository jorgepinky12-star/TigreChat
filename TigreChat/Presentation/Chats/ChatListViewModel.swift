import Foundation
import Observation
import os

@MainActor
@Observable
final class ChatListViewModel {
    private static let logger = Logger(subsystem: "com.tigrechat", category: "ChatList")
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
    /// Último catch-up MAM: se limita a uno cada 2 s para que los eventos del
    /// stream (cada mensaje entrante/eco) no disparen un fetch MAM por red por
    /// evento (y, con el yield de duplicados, no se convierta en un bucle de
    /// sync que satura el main actor y retrasa el repintado del chat abierto).
    private var lastMAMSync = Date.distantPast

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
            // El roster se pide durante el auth pero se procesa de forma
            // asíncrona: si la primera carga ocurre antes de que llegue,
            // reintentamos una vez breve en vez de mostrar lista vacía.
            if conversations.isEmpty, isConnected {
                try? await Task.sleep(for: .milliseconds(500))
                conversations = try await loadConversations.execute()
            }
            conversations.sort { ($0.lastTimestamp ?? .distantPast) > ($1.lastTimestamp ?? .distantPast) }
            // Catch-up XEP-0313: con conexión, trae los mensajes archivados
            // recientes (dedupe por id, sin tocar no leídos). En demo/offline
            // falla silencioso (try?).
            if isConnected, Date().timeIntervalSince(lastMAMSync) > 2 {
                lastMAMSync = Date()
                try? await messageRepository.syncRecentMessages()
                conversations = try await loadConversations.execute()
                conversations.sort { ($0.lastTimestamp ?? .distantPast) > ($1.lastTimestamp ?? .distantPast) }
            }
        } catch {
            Self.logger.error("loadConversations failed: \(error, privacy: .public)")
            conversations = []
        }
        isLoading = false
    }

    func listenToMessages() {
        guard messageListenerTask == nil else { return }
        messageListenerTask = Task { [weak self] in
            guard let self else { return }
            for await _ in messageRepository.messageStream {
                os_log("[List] stream event -> reload", log: xmppLog, type: .debug)
                await loadConversations()
            }
        }
    }

    /// Refresco manual (pull-to-refresh): catch-up MAM + recarga de la lista.
    func refreshMessages() async {
        try? await messageRepository.syncRecentMessages()
        await loadConversations()
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
        } catch {
            Self.logger.error("createGroup failed: \(error, privacy: .public)")
        }
    }

    func logout() async {
        await authRepository.disconnect()
    }
}
