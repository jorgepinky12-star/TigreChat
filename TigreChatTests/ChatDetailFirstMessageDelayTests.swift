//
//  ChatDetailFirstMessageDelayTests.swift
//  TigreChatTests
//
//  Diagnóstico del reporte: "B manda un mensaje y no aparece en el chat de A;
//  al mandar otro, aparecen los dos".
//
//  Topología IDÉNTICA a la app: listener de ChatDetail (observeMessages) +
//  listener de ChatList (loadConversations por cada evento, que dispara
//  syncRecentMessages MAM). El propio test abre una segunda conexión como
//  jorge2 y envía M1 y, 10 segundos después, M2. Registra la línea de tiempo
//  de aparición en el STORE (repo.loadMessages) y en la VISTA
//  (viewModel.messages) para localizar dónde se pierde el primer mensaje.
//

import Foundation
import SwiftData
import XCTest
@testable import TigreChat

@MainActor
final class ChatDetailFirstMessageDelayTests: XCTestCase {

    private static let jid = "jorge@ims-brz.z17.cu"
    private static let password = "s0mePass"
    private static let server = "ims-brz.z17.cu"
    private static let port = 5222
    private static let chatJID = "jorge2@ims-brz.z17.cu"

    private static let token1 = "FIRST-MSG-DIAG-1"
    private static let token2 = "SECOND-MSG-DIAG-2"

    private var clientA: XMPPClient?
    private var clientB: XMPPClient?

    override func tearDown() async throws {
        await clientB?.disconnect()
        clientB = nil
        await clientA?.disconnect()
        clientA = nil
        try await super.tearDown()
    }

    func testFirstMessageShowsBeforeSecondArrives() async throws {
        // --- Receptor: jorge (usuario A) ---
        let clientA = XMPPClient()
        self.clientA = clientA
        await clientA.setup(host: Self.server, port: Self.port)
        try await clientA.connect()
        try await clientA.authenticate(jid: Self.jid, password: Self.password)
        print("[first-msg] jorge autenticado")

        let schema = Schema([MessageEntity.self, ConversationEntity.self, ContactEntity.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let repo = XMPPMessageRepository(client: clientA, modelContainer: container)

        let viewModel = ChatDetailViewModel(
            conversation: Conversation(jid: Self.chatJID, title: "jorge2"),
            messageRepository: repo,
            sendMessageUseCase: SendMessageUseCase(messageRepository: repo),
            markAsReadUseCase: MarkAsReadUseCase(messageRepository: repo)
        )
        viewModel.observeMessages()
        await viewModel.loadMessages()
        print("[first-msg] VM listo; iniciales: \(viewModel.messages.count)")

        // Listener tipo ChatListViewModel.listenToMessages: en la app real
        // está activo mientras el chat está abierto (sync MAM por evento).
        let chatListTask = Task { [weak repo] in
            guard let repo else { return }
            for await _ in repo.messageStream {
                try? await repo.syncRecentMessages(limit: 20)
                _ = try? await repo.loadConversations()
            }
        }

        // --- Emisor: jorge2 (usuario B) en otra conexión ---
        let clientB = XMPPClient()
        self.clientB = clientB
        await clientB.setup(host: Self.server, port: Self.port)
        try await clientB.connect()
        try await clientB.authenticate(jid: "jorge2@\(Self.server)", password: Self.password)
        print("[first-msg] jorge2 autenticado")

        // M1 y, 10s después, M2 (sin OMEMO: mensajes de texto planos).
        let id1 = "diag-1-\(Int(Date().timeIntervalSince1970))"
        let id2 = "diag-2-\(Int(Date().timeIntervalSince1970))"
        try await clientB.sendMessage(id: id1, body: Self.token1, to: Self.jid)
        print("[first-msg] >>> M1 enviado (\(id1))")
        try? await Task.sleep(for: .seconds(10))
        try await clientB.sendMessage(id: id2, body: Self.token2, to: Self.jid)
        print("[first-msg] >>> M2 enviado (\(id2))")

        // --- Línea de tiempo ---
        let deadline = Date().addingTimeInterval(60)
        var view1At: Date?
        var view2At: Date?
        var store1At: Date?
        var store2At: Date?
        while Date() < deadline && (view1At == nil || view2At == nil) {
            let vmTexts = viewModel.messages.map(\.text)
            let storeMessages = (try? await repo.loadMessages(conversationId: Self.chatJID)) ?? []
            let storeTexts = storeMessages.map(\.text)
            let now = Date()
            if view1At == nil, vmTexts.contains(Self.token1) { view1At = now }
            if view2At == nil, vmTexts.contains(Self.token2) { view2At = now }
            if store1At == nil, storeTexts.contains(Self.token1) { store1At = now }
            if store2At == nil, storeTexts.contains(Self.token2) { store2At = now }
            print("[first-msg] t=\(Int(now.timeIntervalSince1970)) VM:\(vmTexts) STORE:\(storeTexts)")
            try? await Task.sleep(for: .milliseconds(300))
        }
        chatListTask.cancel()

        print("[first-msg] === RESUMEN ===")
        print("[first-msg] store1At=\(String(describing: store1At?.timeIntervalSince1970)) view1At=\(String(describing: view1At?.timeIntervalSince1970))")
        print("[first-msg] store2At=\(String(describing: store2At?.timeIntervalSince1970)) view2At=\(String(describing: view2At?.timeIntervalSince1970))")

        if store1At == nil {
            return XCTFail("M1 nunca llegó al store — el problema está en la llegada (red/parser/dedupe)")
        }
        if store2At == nil || view2At == nil {
            return XCTFail("M2 no llegó/completó — escenario no reproducible en esta corrida")
        }
        guard let view1At, let store1At else {
            return XCTFail("Faltan marcas de M1 en la vista")
        }
        XCTAssertLessThan(view1At, view2At!, "BUG REPRODUCIDO: M1 apareció en la vista SOLO después de llegar M2 (estaba en el store en t=\(store1At.timeIntervalSince1970))")
        XCTAssertLessThanOrEqual(view1At.timeIntervalSince(store1At), 5, "M1 estuvo en el store antes de aparecer en la vista — pérdida de notificación al UI")
        print("[first-msg] OK: M1 visible en vivo antes de M2")
    }
}