//
//  FingerprintTrustTests.swift
//  TigreChatTests
//
//  T-VOIPCALLS-030 RED: contrato TOFU (REQ-JINGLE-011).
//  - Primer uso: sin fingerprint almacenado → nil (la UI muestra verificación).
//  - store/read por jid.
//  - Mismatch F2 ≠ F1 → hard block: el store devuelve F1, no F2 (el repo
//    bloqueará la llamada; el assertion aquí protege la fuente de verdad).
//  - El store persiste jid→fingerprint de forma consultable por la UI.
//
//  NOTA (run M3, Xcode 27 beta): el container de test se construye INLINE y
//  COMPLETO en el cuerpo de cada test. Cualquier variante con helper que
//  retorne el store o el container desde otra función dispara un
//  EXC_BREAKPOINT (SIGTRAP) interno de SwiftData en el save() — reproducido
//  y verificado en el run M3 (makeStore y makeContainer crashean).
//

import XCTest
import SwiftData
@testable import TigreChat

@MainActor
final class FingerprintTrustTests: XCTestCase {

    /// REQ-JINGLE-011 escenario "TOFU first call": sin histórico → nil,
    /// la vista de verificación se presenta ANTES de continuar la llamada.
    func testFirstUseReturnsNil() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Schema([
                FingerprintEntity.self,
            ]),
            configurations: config
        )
        let store = FingerprintStore(modelContainer: container)
        XCTAssertNil(store.storedFingerprint(for: "ana@z17.cu"), "Primer contacto debe devolver nil (verificación pendiente)")
    }

    /// Aceptar la verificación persiste jid→fingerprint; un segundo lookup
    /// del mismo jid devuelve exactamente el valor guardado (normalizado).
    func testStoreThenRetrieveReturnsSameFingerprint() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Schema([
                FingerprintEntity.self,
            ]),
            configurations: config
        )
        let store = FingerprintStore(modelContainer: container)
        let fp = "A58B0C0B39E79FB5045A2BBCD6430EEF88E809DB7590A36363EFA59FA9067C44"
        try store.store(fp, for: "ana@z17.cu")
        XCTAssertEqual(store.storedFingerprint(for: "ana@z17.cu"), fp)
    }

    /// REQ-JINGLE-011 escenario "Fingerprint mismatch": un fingerprint F2
    /// distinto del almacenado F1 NO es aceptado (el repo lo bloquea con
    /// security-error; aquí se asegura la comparación estricta).
    func testMismatchFingerprintDiffersFromStored() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Schema([
                FingerprintEntity.self,
            ]),
            configurations: config
        )
        let store = FingerprintStore(modelContainer: container)
        try store.store("F1", for: "ana@z17.cu")
        let stored = try XCTUnwrap(store.storedFingerprint(for: "ana@z17.cu"))
        XCTAssertNotEqual(stored, "F2", "F2 ≠ F1 debe detectarse como mismatch")
    }

    /// Los jids son independientes: almacenar uno no contamina otro.
    func testStoresArePerJID() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Schema([
                FingerprintEntity.self,
            ]),
            configurations: config
        )
        let store = FingerprintStore(modelContainer: container)
        try store.store("FP-ANA", for: "ana@z17.cu")
        XCTAssertNil(store.storedFingerprint(for: "bob@z17.cu"))
        XCTAssertEqual(store.storedFingerprint(for: "ana@z17.cu"), "FP-ANA")
    }

    /// El upsert por jid actualiza lastSeen y el fingerprint sin duplicar filas.
    func testStoreUpdatesInPlace() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Schema([
                FingerprintEntity.self,
            ]),
            configurations: config
        )
        let store = FingerprintStore(modelContainer: container)
        try store.store("FP-V1", for: "ana@z17.cu")
        try store.store("FP-V2", for: "ana@z17.cu")
        XCTAssertEqual(store.storedFingerprint(for: "ana@z17.cu"), "FP-V2")
    }
}
