import Foundation
import SwiftUI
import SwiftData

@MainActor
final class Dependencies {
    let modelContainer: ModelContainer
    let xmppClient: XMPPClient
    let authRepository: XMPPAuthRepository
    let messageRepository: XMPPMessageRepository
    let contactRepository: XMPPContactRepository
    let groupRepository: XMPPGroupRepository
    let fileRepository: XMPPFileRepository
    let callManager: CallManager
    let webRTCEngine: MockWebRTCEngine
    let callRepository: XMPPCallRepository
    let historyStore: CallHistoryStore
    let fingerprintStore: FingerprintStore
    let keyManager: KeyManager
    let omemoModule: OMEMOModule

    nonisolated init() {
        let schema = Schema([
            MessageEntity.self,
            ConversationEntity.self,
            ContactEntity.self,
            // M3 (voip-calls): entidades aditivas, sin migración — solo se
            // añaden tipos nuevos; los modelos existentes quedan intactos.
            CallHistoryEntry.self,
            FingerprintEntity.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        let container: ModelContainer
        do {
            container = try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
        modelContainer = container

        let client = XMPPClient()
        xmppClient = client
        authRepository = XMPPAuthRepository(client: client)
        fileRepository = XMPPFileRepository(uploadManager: client.fileUploadManager, domain: "")

        // CallManager, MockWebRTCEngine and the SwiftData repositories are
        // MainActor-isolated (Apple: ModelContext is not Sendable; confine it
        // to the main actor for UI-bound persistence). Dependencies() is only
        // created as an EnvironmentValues default from a View context, which
        // runs on the main actor, so the assumption is safe.
        let (cm, engine, msgRepo, contactRepo, groupRepo, callHistoryStore, fpStore) = MainActor.assumeIsolated {
            (
                CallManager(),
                MockWebRTCEngine(),
                XMPPMessageRepository(client: client, modelContainer: container),
                XMPPContactRepository(client: client, modelContainer: container),
                XMPPGroupRepository(mucManager: client.mucManager, modelContainer: container),
                CallHistoryStore(modelContainer: container),
                FingerprintStore(modelContainer: container)
            )
        }
        callManager = cm
        webRTCEngine = engine
        messageRepository = msgRepo
        contactRepository = contactRepo
        groupRepository = groupRepo
        historyStore = callHistoryStore
        fingerprintStore = fpStore
        callRepository = XMPPCallRepository(
            jingleManager: client.jingleManager,
            webRTC: engine,
            callKit: cm,
            historyStore: callHistoryStore,
            fingerprintStore: fpStore,
            localJIDProvider: { await client.currentJID }
        )

        let km = MainActor.assumeIsolated { KeyManager() }
        keyManager = km
        let omemo = OMEMOModule(connection: client.connection, keyManager: km)
        omemoModule = omemo

        Task {
            await client.setOMEMOModule(omemo)
            await callRepository.setup()
        }
    }

    var sendMessageUseCase: SendMessageUseCase {
        SendMessageUseCase(messageRepository: messageRepository)
    }

    var loadConversationsUseCase: LoadConversationsUseCase {
        LoadConversationsUseCase(messageRepository: messageRepository)
    }

    var loadMessagesUseCase: LoadMessagesUseCase {
        LoadMessagesUseCase(messageRepository: messageRepository)
    }

    var markAsReadUseCase: MarkAsReadUseCase {
        MarkAsReadUseCase(messageRepository: messageRepository)
    }

    var sendFileUseCase: SendFileUseCase {
        SendFileUseCase(fileRepository: fileRepository, messageRepository: messageRepository)
    }

    var createGroupUseCase: CreateGroupUseCase {
        CreateGroupUseCase(groupRepository: groupRepository)
    }

    var joinGroupUseCase: JoinGroupUseCase {
        JoinGroupUseCase(groupRepository: groupRepository)
    }

    var startCallUseCase: StartCallUseCase {
        StartCallUseCase(callRepository: callRepository)
    }

    var acceptCallUseCase: AcceptCallUseCase {
        AcceptCallUseCase(callRepository: callRepository)
    }

    var endCallUseCase: EndCallUseCase {
        EndCallUseCase(callRepository: callRepository)
    }

    func makeLoginViewModel() -> LoginViewModel {
        LoginViewModel(authRepository: authRepository, xmppClient: xmppClient)
    }

    func makeChatListViewModel() -> ChatListViewModel {
        ChatListViewModel(
            loadConversations: loadConversationsUseCase,
            messageRepository: messageRepository,
            authRepository: authRepository,
            groupRepository: groupRepository,
            sendFileUseCase: sendFileUseCase,
            xmppClient: xmppClient
        )
    }

    func makeCallViewModel() -> CallViewModel {
        CallViewModel(callRepository: callRepository)
    }
}

extension EnvironmentValues {
    @Entry var dependencies: Dependencies = Dependencies()
    @Entry var callRepository: XMPPCallRepository? = nil
}
