//
//  Jorge2ReceptionTests.swift
//  TigreChatTests
//
//  Prueba de RECEPCIÓN del usuario jorge2 contra el servidor real:
//  la app (stack completo XMPPClient) se conecta como
//  jorge2@ims-brz.z17.cu / s0mePass y espera UN mensaje de jorge
//  enviado desde un cliente externo (scripts del diagnóstico).
//
//  Es exactamente el pipeline que usa la UI (connect -> authenticate ->
//  messageStream); si este test recibe el mensaje, la app de jorge2
//  también debe recibirlo en vivo. Un mensaje que nunca llega es el
//  error real que estamos cazando.
//
//  Sincronización: la prueba espera hasta `waitBudget` segundos a que
//  llegue un mensaje cuyo body contenga `expectedToken`. El disparador
//  externo (python como jorge) envía ese texto mientras el test corre.
//

import Foundation
import XCTest
@testable import TigreChat

@MainActor
final class Jorge2ReceptionTests: XCTestCase {

    // MARK: - Configuración

    /// Token único que el disparador externo debe enviar como body.
    private static let expectedToken = "J2RECV-TEST-20260815A"

    private static let jid = "jorge2@ims-brz.z17.cu"
    private static let password = "s0mePass"
    private static let server = "ims-brz.z17.cu"
    private static let port = 5222

    private var client: XMPPClient?

    override func tearDown() async throws {
        await client?.disconnect()
        client = nil
        try await super.tearDown()
    }

    // MARK: - Prueba

    func testJorge2ReceivesFromExternalJorge() async throws {
        let client = XMPPClient()
        self.client = client
        await client.setup(host: Self.server, port: Self.port)

        // Fase de conexión: DNS/socket/TLS/auth. Un fallo AQUÍ ya es
        // diagnóstico: la app de jorge2 tampoco podría conectarse.
        do {
            try await client.connect()
            try await client.authenticate(jid: Self.jid, password: Self.password)
        } catch {
            return XCTFail("jorge2 NO pudo conectarse/autenticar: \(error.localizedDescription)")
        }
        print("[j2-recv] jorge2 autenticado OK; esperando \(Self.expectedToken)")

        let stream = await client.messageStream

        guard let received = await waitForMessage(
            on: stream,
            matching: { $0.text == Self.expectedToken },
            timeout: 180
        ) else {
            return XCTFail("jorge2 NO recibió '\(Self.expectedToken)' del emisor externo en 180s")
        }
        XCTAssertEqual(received.text, Self.expectedToken, "El body debe coincidir con el token")
        XCTAssertFalse(received.isOutgoing, "jorge2 recibe el mensaje de jorge, no un eco propio")
        print("[j2-recv] RECIBIDO: \(received.text) encrypted=\(received.isEncrypted)")
    }

    // MARK: - Helpers

    /// Espera en `stream` hasta que `predicate` haga match o se agote el
    /// timeout. Si el waiter se cancela por timeout se devuelve nil.
    private func waitForMessage(
        on stream: AsyncStream<Message>,
        matching predicate: @escaping (Message) -> Bool,
        timeout: TimeInterval
    ) async -> Message? {
        let waiter = Task<Message?, Never> {
            for await message in stream {
                if predicate(message) { return message }
            }
            return nil
        }
        let timeoutTask = Task<Void, Never> {
            try? await Task.sleep(for: .seconds(timeout))
            waiter.cancel()
        }
        defer { timeoutTask.cancel() }
        return await waiter.value
    }
}