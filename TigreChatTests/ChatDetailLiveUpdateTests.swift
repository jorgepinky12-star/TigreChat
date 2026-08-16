//
//  ChatDetailLiveUpdateTests.swift
//  TigreChatTests
//
//  Prueba del fix "el chat privado no se actualiza en vivo": el stack
//  completo (XMPPClient + XMPPMessageRepository + ChatDetailViewModel)
//  se conecta como jorge@ims-brz.z17.cu y deja el chat con jorge2 ABIERTO.
//  Un emisor externo (python como jorge2) envía un token; la vista debe
//  mostrarlo SIN ninguna recarga manual: solo el listener del stream
//  (observeMessages) puede haber refrescado `viewModel.messages`.
//
//  Antes del fix, un mensaje entrante con el chat abierto solo aparecía
//  al salir y volver a entrar (el detalle no escuchaba messageStream).
//

import Foundation
import SwiftData
import XCTest
@testable import TigreChat

@MainActor
final class ChatDetailLiveUpdateTests: XCTestCase {

    /// Token único que el emisor externo (python como jorge2) debe enviar.
    private static let expectedToken = "LIVE-UPDATE-20260815A"

    private static let jid = "jorge@ims-brz.z17.cu"
    private static let password = "s0mePass"
    private static let server = "ims-brz.z17.cu"
    private static let port = 5222
    /// La conversación abierta en el cliente de jorge es el chat con jorge2.
    private static let chatJID = "jorge2@ims-brz.z17.cu"

    private var client: XMPPClient?

    override func tearDown() async throws {
        await client?.disconnect()
        client = nil
        try await super.tearDown()
    }

    func testOpenChatUpdatesLiveFromExternalSender() async throws {
        let client = XMPPClient()
        self.client = client
        await client.setup(host: Self.server, port: Self.port)

        do {
            try await client.connect()
            try await client.authenticate(jid: Self.jid, password: Self.password)
        } catch {
            return XCTFail("jorge NO pudo conectarse/autenticar: \(error.localizedDescription)")
        }
        print("[live-upd] jorge autenticado OK; chat abierto con \(Self.chatJID)")

        // Contenedor en memoria: la prueba no toca el store real del dispositivo.
        let schema = Schema([MessageEntity.self, ConversationEntity.self, ContactEntity.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let repo = XMPPMessageRepository(client: client, modelContainer: container)
        print("[live-upd] repositorio listo")

        let viewModel = ChatDetailViewModel(
            conversation: Conversation(jid: Self.chatJID, title: "jorge2"),
            messageRepository: repo,
            sendMessageUseCase: SendMessageUseCase(messageRepository: repo),
            markAsReadUseCase: MarkAsReadUseCase(messageRepository: repo)
        )
        print("[live-upd] viewModel listo")

        // Carga inicial + arranque del listener en vivo (como hace ChatDetailView).
        viewModel.observeMessages()
        await viewModel.loadMessages()
        print("[live-upd] carga inicial: \(viewModel.messages.count) mensajes")

        // A partir de aquí NO se vuelve a llamar a loadMessages: si el token
        // aparece en `messages`, solo pudo ser por observeMessages().
        let deadline = Date().addingTimeInterval(150)
        var lastHeartbeat = Date()
        var found: Message?
        while Date() < deadline {
            if let match = viewModel.messages.first(where: { $0.text == Self.expectedToken }) {
                found = match
                break
            }
            if Date().timeIntervalSince(lastHeartbeat) > 5 {
                lastHeartbeat = Date()
                print("[live-upd] latido: \(viewModel.messages.count) mensajes a las \(Date().timeIntervalSince1970)")
            }
            try? await Task.sleep(for: .milliseconds(500))
        }

        guard let found else {
            return XCTFail("El chat abierto NO mostró '\(Self.expectedToken)' en vivo en 150s (llega al reentrar = bug reintroducido)")
        }
        XCTAssertFalse(found.isOutgoing, "jorge recibe el mensaje de jorge2, no un eco propio")
        XCTAssertEqual(found.conversationId, Self.chatJID, "El mensaje debe vivir en la conversación abierta (jid desnudo)")
        print("[live-upd] EN VIVO: \(found.text) conversationId=\(found.conversationId) outgoing=\(found.isOutgoing)")
    }
}