import XCTest
import SwiftData
@testable import TigreChat

/// Reproduce a nivel de unidad el escenario reportado: con el chat abierto,
/// un mensaje entrante debe repintar la conversación (el VM recibe el evento
/// del stream del repositorio y recarga). Si el observador del detalle y el
/// stream del repo no entregan el evento, `viewModel.messages` queda sin el
/// mensaje — el fallo visible ("no llega hasta que salgo y entro").
@MainActor
final class ChatDetailLiveUpdateUnitTests: XCTestCase {

    private func makeRepository() async throws -> (XMPPMessageRepository, XMPPClient) {
        let client = XMPPClient()
        await client.setup(host: "127.0.0.1", port: 1, useDirectTLS: false, domain: "offline.test")
        let container = try ModelContainer(
            for: MessageEntity.self, ConversationEntity.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let repo = XMPPMessageRepository(client: client, modelContainer: container)
        return (repo, client)
    }

    private func makeViewModel(repo: XMPPMessageRepository) -> ChatDetailViewModel {
        ChatDetailViewModel(
            conversation: Conversation(jid: "jorge2@ims-brz.z17.cu", title: "jorge2"),
            messageRepository: repo,
            sendMessageUseCase: SendMessageUseCase(messageRepository: repo),
            markAsReadUseCase: MarkAsReadUseCase(messageRepository: repo),
            sendFileUseCase: nil,
            chatStateManager: nil
        )
    }

    /// El mensaje insertado (incluso aunque el envío falle por estar offline)
    /// debe generar un evento que el VM del chat abierto consume y repinta.
    func testInsertedMessageRepaintsOpenChat() async throws {
        let (repo, _) = try await makeRepository()
        let vm = makeViewModel(repo: repo)

        await vm.loadMessages()
        XCTAssertTrue(vm.messages.isEmpty)

        vm.observeMessages()

        let message = Message(
            id: "live-msg-1",
            conversationId: "jorge2@ims-brz.z17.cu",
            senderJID: "jorge2@ims-brz.z17.cu",
            text: "Hola desde el test",
            timestamp: Date(),
            isOutgoing: false,
            status: .delivered
        )
        // El repo persiste ANTES de intentar enviar: aunque `send` falle
        // (sin conexión), el evento del stream ya se emitió.
        _ = try? await repo.send(message: message)

        // Poll breve: el listener del VM es asíncrono.
        let deadline = Date().addingTimeInterval(3)
        while vm.messages.isEmpty && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertFalse(vm.messages.isEmpty, "El chat abierto debe repintar con el mensaje insertado")
        XCTAssertEqual(vm.messages.last?.id, "live-msg-1")
        XCTAssertEqual(vm.messages.last?.text, "Hola desde el test")
    }

    /// La red de seguridad (startLivePolling) repinta el chat abierto aunque
    /// el evento del stream no llegara: recarga periódica desde el store.
    func testLivePollingRepaintsOpenChat() async throws {
        let (repo, _) = try await makeRepository()
        let vm = makeViewModel(repo: repo)
        await vm.loadMessages()
        XCTAssertTrue(vm.messages.isEmpty)

        // Intervalo corto para que el test sea rápido.
        vm.startLivePolling(interval: .milliseconds(100))

        _ = try? await repo.send(message: Message(
            id: "poll-msg-1",
            conversationId: "jorge2@ims-brz.z17.cu",
            senderJID: "jorge2@ims-brz.z17.cu",
            text: "Llega por polling",
            timestamp: Date(),
            isOutgoing: false,
            status: .delivered
        ))

        let deadline = Date().addingTimeInterval(3)
        while vm.messages.isEmpty && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(vm.messages.last?.text, "Llega por polling",
                       "El polling debe traer el mensaje aunque el evento no llegara")
    }

    /// La carga recoge los mensajes más recientes (el nuevo primero en el
    /// store, sin límite 50 truncando lo recién llegado).
    func testLoadMessagesIncludesNewestAfterInsert() async throws {
        let (repo, _) = try await makeRepository()
        let vm = makeViewModel(repo: repo)
        await vm.loadMessages()
        XCTAssertTrue(vm.messages.isEmpty)

        _ = try? await repo.send(message: Message(
            id: "live-msg-2",
            conversationId: "jorge2@ims-brz.z17.cu",
            senderJID: "jorge2@ims-brz.z17.cu",
            text: "Segundo",
            timestamp: Date(),
            isOutgoing: false,
            status: .delivered
        ))

        // Prueba directa de la carga: sin observador, la recarga explícita
        // debe traer el mensaje recién insertado (el sort por timestamp pone
        // el más reciente al final de la lista para mostrar).
        await vm.loadMessages()
        XCTAssertEqual(vm.messages.last?.id, "live-msg-2")
        XCTAssertEqual(vm.messages.last?.text, "Segundo")
    }
}