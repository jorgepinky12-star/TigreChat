//
//  MissedCallProbeTests.swift
//  TigreChatTests
//
//  T-VOIPCALLS-060 (PROBE, opt-in): verifica si el servidor archiva
//  IQs jingle perdidos via MAM. Auto-skip sin env vars. NUNCA en gate.
//
//  Env vars requeridas:
//    TIGRE_OMEMO_TEST_JID      — JID completo (user@dominio/recurso)
//    TIGRE_OMEMO_TEST_PASSWORD  — contraseña
//

import XCTest
@testable import TigreChat

@MainActor
final class MissedCallProbeTests: XCTestCase {

    func testProbeServerArchivesMissedCallIQ() async throws {
        // Auto-skip si no hay credenciales.
        guard let jid = ProcessInfo.processInfo.environment["TIGRE_OMEMO_TEST_JID"],
              let password = ProcessInfo.processInfo.environment["TIGRE_OMEMO_TEST_PASSWORD"],
              !jid.isEmpty, !password.isEmpty
        else {
            throw XCTSkip("TIGRE_OMEMO_TEST_JID / TIGRE_OMEMO_TEST_PASSWORD no definidas; probe omitido")
        }

        // Fase 1: verificar que MAM query funciona (conexión + query básico).
        // Esto es un probe binario: PASS = servidor archiva, FAIL = no archiva.
        // El resultado se documenta en el verify report.
        let client = XMPPClient()
        do {
            try await client.connect()
        } catch {
            throw XCTSkip("Conexión fallida (infra/servidor): \(error.localizedDescription)")
        }

        // TODO: implementar MAM query para verificar archivado de IQs jingle.
        // Por ahora, el probe documenta que la infraestructura está disponible.
        XCTFail("Probe incompleto: implementar MAM query para verificar archivado")

        await client.disconnect()
    }
}
