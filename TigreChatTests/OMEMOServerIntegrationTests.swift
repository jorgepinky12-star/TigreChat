//
//  OMEMOServerIntegrationTests.swift
//  TigreChatTests
//
//  Prueba de integración OMEMO (XEP-0384) contra un servidor real: DOS
//  dispositivos de la MISMA cuenta autenticados a la vez. Cada uno publica su
//  bundle al autenticar; el test republica la lista de dispositivos MERGED y
//  verifica que un mensaje cifrado por el dispositivo A llega descifrado al
//  dispositivo B a través del servidor (PEP + routing + carbons).
//
//  Credenciales por environment (el test se omite si faltan):
//    TIGRE_OMEMO_TEST_JID     (obligatoria)
//    TIGRE_OMEMO_TEST_PASSWORD (obligatoria)
//    TIGRE_OMEMO_SERVER       (default "ims-brz.z17.cu")
//    TIGRE_OMEMO_PORT         (default 5222)
//
//  Fallos de la fase de CONEXIÓN (DNS/socket/TLS/auth) se omiten como
//  infraestructura; un mensaje que nunca llega es un error real.
//

import Foundation
import XCTest
@testable import TigreChat

@MainActor
final class OMEMOServerIntegrationTests: XCTestCase {

    // MARK: - Configuración

    private static let defaultServer = "ims-brz.z17.cu"

    private var clientA: XMPPClient?
    private var clientB: XMPPClient?

    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func tearDown() async throws {
        await clientA?.disconnect()
        clientA = nil
        await clientB?.disconnect()
        clientB = nil
        try await super.tearDown()
    }

    // MARK: - Prueba

    /// Dos dispositivos de la misma cuenta: A cifra "hola cifrado ..." para el
    /// JID desnudo; B lo recibe por `messageStream` y lo entrega DESCIFRADO.
    func testTwoDevicesSameAccountEndToEnd() async throws {
        guard let jid = env["TIGRE_OMEMO_TEST_JID"], !jid.isEmpty,
              let password = env["TIGRE_OMEMO_TEST_PASSWORD"], !password.isEmpty else {
            throw XCTSkip("TIGRE_OMEMO_TEST_JID / TIGRE_OMEMO_TEST_PASSWORD no definidas; test de integración OMEMO omitido")
        }
        let host = env["TIGRE_OMEMO_SERVER"] ?? Self.defaultServer
        let port = env["TIGRE_OMEMO_PORT"].flatMap(Int.init) ?? 5222

        // 1-2. Dispositivo A y dispositivo B (deviceIds fijos para que la
        //      sesión del servidor sea estable entre ejecuciones).
        //
        // AMBOS usan el servicio Keychain por defecto (de forma deliberada):
        // `OMEMOModule` construye su `sessionManager` con el store por defecto
        // y la capa Signal exige que la identidad local del store coincida con
        // la identidad publicada en el bundle (blob compartido con KeyManager).
        // En un simulador de pruebas esto es aceptable: A y B comparten un
        // registro de identidad, pero cada uno conserva sus propios prekeys.
        let clientA = XMPPClient()
        self.clientA = clientA
        await clientA.setup(host: host, port: port)
        let keyManagerA = KeyManager(deviceId: 1001)
        let moduleA = OMEMOModule(connection: clientA.connection, keyManager: keyManagerA)
        await clientA.setOMEMOModule(moduleA)

        let clientB = XMPPClient()
        self.clientB = clientB
        await clientB.setup(host: host, port: port)
        let keyManagerB = KeyManager(deviceId: 1002)
        let moduleB = OMEMOModule(connection: clientB.connection, keyManager: keyManagerB)
        await clientB.setOMEMOModule(moduleB)

        // Fase de conexión: DNS/socket/TLS/auth fallidos se tratan como
        // infraestructura (mismo espíritu que TLSNegotiationTests).
        do {
            try await clientA.connect()
            try await clientA.authenticate(jid: jid, password: password)
            try await clientB.connect()
            try await clientB.authenticate(jid: jid, password: password)
        } catch {
            throw XCTSkip("Fase de conexión fallida (infra/servidor): \(error.localizedDescription)")
        }

        // 3. Cada authenticate() publicó su propia lista (la última sobrescribe
        //    el nodo PEP): republicar la lista MERGED con ambos deviceIds. Los
        //    bundles ya se publicaron dentro de authenticate(); no repetir.
        do {
            try await moduleB.publishDeviceList(devices: [
                await moduleA.localDeviceId,
                await moduleB.localDeviceId,
            ])
        } catch {
            throw XCTSkip("El servidor no aceptó el publish PEP (OMEMO no soportado): \(error.localizedDescription)")
        }

        // 4-5. A envía el mensaje cifrado; B espera la llegada. El waiter se
        //      arma ANTES del envío (con buffer unbounded basta, pero empezar
        //      antes evita depender de la política de buffering).
        let sentText = "hola cifrado \(UUID().uuidString.prefix(6).lowercased())"
        let streamB = await clientB.messageStream

        // El publish PEP puede tardar un instante en ser visible: reintentos
        // acotados SOLO para `.noDevices`; el resto de fallos es error real.
        var sent = false
        for attempt in 1...3 {
            do {
                try await clientA.sendMessage(body: sentText, to: jid, omemo: true)
                sent = true
                break
            } catch let error as OMEMOError {
                guard case .noDevices = error, attempt < 3 else {
                    return XCTFail("Fallo OMEMO al enviar: \(error.localizedDescription)")
                }
                print("[omemo-int] intento \(attempt): lista de dispositivos aún vacía; reintento")
                try await Task.sleep(for: .seconds(2))
            } catch {
                return XCTFail("Fallo de red al enviar: \(error.localizedDescription)")
            }
        }
        guard sent else {
            return XCTFail("No se pudo enviar el mensaje OMEMO")
        }

        // 6. Llegó (o no): ausencia de mensaje tras el timeout = error real.
        guard let received = await waitForMessage(
            on: streamB,
            matching: { $0.text == sentText },
            timeout: 30
        ) else {
            return XCTFail("El dispositivo B no recibió '\(sentText)' en 30s")
        }
        XCTAssertEqual(received.text, sentText, "B debe entregar el texto descifrado")
        XCTAssertTrue(received.isEncrypted, "El mensaje recibido debe marcarse como cifrado")
        XCTAssertFalse(received.isOutgoing, "B recibe el mensaje de A, no un eco propio")
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