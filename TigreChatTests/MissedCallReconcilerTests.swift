//
//  MissedCallReconcilerTests.swift
//  TigreChatTests
//
//  T-VOIPCALLS-061 (RED→GREEN): tests del reconciliador de llamadas
//  perdidas. Fixtures MAM (no requiere servidor). REQ-HIST-004.
//

import XCTest
import SwiftData
@testable import TigreChat

@MainActor
final class MissedCallReconcilerTests: XCTestCase {

    private var container: ModelContainer!
    private var historyStore: CallHistoryStore!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: CallHistoryEntry.self,
            configurations: config
        )
        historyStore = CallHistoryStore(modelContainer: container)
    }

    // REQ-HIST-004: entradas MAM → upsert filas missed

    func testReconcileUpsertsMissedCalls() async throws {
        let mam = MockMAM(entries: [
            MAMJingleEntry(sid: "m1", from: "ana@z17.cu", timestamp: Date(), direction: .incoming),
            MAMJingleEntry(sid: "m2", from: "bob@z17.cu", timestamp: Date(), direction: .incoming),
        ])
        let reconciler = MissedCallReconciler(historyStore: historyStore, mam: mam)

        let count = try await reconciler.reconcile(since: Date.distantPast)
        XCTAssertEqual(count, 2, "Debe upsertar 2 llamadas perdidas")
        XCTAssertEqual(historyStore.entry(sid: "m1")?.status, .missed)
        XCTAssertEqual(historyStore.entry(sid: "m2")?.status, .missed)
    }

    // REQ-HIST-004: dedupe por sid

    func testReconcileDeduplicatesBySID() async throws {
        // Pre-existe una fila con sid "m1".
        _ = try? await historyStore.upsert(
            sid: "m1", jid: "ana@z17.cu", direction: .incoming,
            status: .answered, duration: 30, isVideo: false
        )

        let mam = MockMAM(entries: [
            MAMJingleEntry(sid: "m1", from: "ana@z17.cu", timestamp: Date(), direction: .incoming),
            MAMJingleEntry(sid: "m3", from: "carlos@z17.cu", timestamp: Date(), direction: .incoming),
        ])
        let reconciler = MissedCallReconciler(historyStore: historyStore, mam: mam)

        let count = try await reconciler.reconcile(since: Date.distantPast)
        XCTAssertEqual(count, 1, "Solo m3 es nueva; m1 ya existía")
        XCTAssertEqual(historyStore.entry(sid: "m1")?.status, .answered, "m1 no debe cambiar")
        XCTAssertEqual(historyStore.entry(sid: "m3")?.status, .missed)
    }

    // MAM vacío → 0 upserts

    func testReconcileWithEmptyMAM() async throws {
        let mam = MockMAM(entries: [])
        let reconciler = MissedCallReconciler(historyStore: historyStore, mam: mam)

        let count = try await reconciler.reconcile(since: Date())
        XCTAssertEqual(count, 0)
    }
}

// MARK: - Mock MAM

private struct MockMAM: MAMQuerying {
    let entries: [MAMJingleEntry]
    func fetchMissedJingles(since: Date) async throws -> [MAMJingleEntry] { entries }
}
