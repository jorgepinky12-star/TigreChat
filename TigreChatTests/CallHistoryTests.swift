//
//  CallHistoryTests.swift
//  TigreChatTests
//
//  T-VOIPCALLS-032 RED: historial SwiftData (REQ-HIST-001/002/003).
//  - Los 6 estados terminales se registran con su fila propia.
//  - answered con duración ≈45; los no-answered con duración 0.
//  - Merge por sid: una llamada con varias transiciones → UNA sola fila.
//  - El historial persiste tras "relaunch" (nuevo container sobre el mismo store).
//  - La relación unidireccional a Conversation se guarda y recupera.
//

import XCTest
import SwiftData
@testable import TigreChat

@MainActor
final class CallHistoryTests: XCTestCase {

    private func makeContainer(_ config: ModelConfiguration) throws -> ModelContainer {
        try ModelContainer(
            // ConversationEntity tiene `@Relationship messages: [MessageEntity]?`,
            // así que el cierre de entidades alcanzables exige MessageEntity.
            for: CallHistoryEntry.self, ConversationEntity.self, MessageEntity.self,
            configurations: config
        )
    }

    /// REQ-HIST-002: TODOS los estados terminales se registran; los que no
    /// fueron respondidos llevan duration 0 (decisión de producto).
    func testSixTerminalStatusesRecordedWithDuration() throws {
        let container = try makeContainer(ModelConfiguration(isStoredInMemoryOnly: true))
        let store = CallHistoryStore(modelContainer: container)

        try store.upsert(sid: "s1", jid: "ana@z17.cu", direction: .incoming, status: .answered, duration: 45)
        try store.upsert(sid: "s2", jid: "ana@z17.cu", direction: .outgoing, status: .unanswered)
        try store.upsert(sid: "s3", jid: "bob@z17.cu", direction: .outgoing, status: .busy)
        try store.upsert(sid: "s4", jid: "bob@z17.cu", direction: .incoming, status: .declined)
        try store.upsert(sid: "s5", jid: "bob@z17.cu", direction: .incoming, status: .missed)
        try store.upsert(sid: "s6", jid: "bob@z17.cu", direction: .outgoing, status: .failed)

        let answered = try XCTUnwrap(store.entry(sid: "s1"))
        XCTAssertEqual(answered.status, .answered)
        XCTAssertEqual(answered.direction, .incoming)
        XCTAssertEqual(answered.duration, 45, accuracy: 0.5)

        let expected: [(String, CallStatus)] = [
            ("s2", .unanswered), ("s3", .busy), ("s4", .declined), ("s5", .missed), ("s6", .failed),
        ]
        for (sid, status) in expected {
            let entry = try XCTUnwrap(store.entry(sid: sid), "Falta la fila \(sid)")
            XCTAssertEqual(entry.status, status)
            XCTAssertEqual(entry.duration, 0, accuracy: 0.001, "duration debe ser 0 para no-answered (\(sid))")
        }
    }

    /// REQ-HIST-003: las transiciones de UNA llamada (ringing→connected→ended)
    /// actualizan la MISMA fila, nunca crean duplicados por sid.
    func testMergeBySidYieldsSingleRow() throws {
        let container = try makeContainer(ModelConfiguration(isStoredInMemoryOnly: true))
        let store = CallHistoryStore(modelContainer: container)

        try store.upsert(sid: "call-1", jid: "ana@z17.cu", direction: .incoming, status: .unanswered)
        try store.upsert(sid: "call-1", jid: "ana@z17.cu", direction: .incoming, status: .answered, duration: 12)

        let entries = store.entries(for: "ana@z17.cu")
        XCTAssertEqual(entries.count, 1, "Debe existir UNA fila por sid")
        XCTAssertEqual(entries.first?.status, .answered)
        XCTAssertEqual(try XCTUnwrap(entries.first).duration, 12, accuracy: 0.5)
    }

    /// REQ-HIST-004 escenario "History survives relaunch": abrir un NUEVO
    /// container sobre el mismo store devuelve las filas grabadas antes.
    func testHistorySurvivesRelaunch() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("callhistory-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = try makeContainer(ModelConfiguration(url: url))
        let store1 = CallHistoryStore(modelContainer: first)
        try store1.upsert(sid: "call-9", jid: "ana@z17.cu", direction: .outgoing, status: .answered, duration: 30)

        // "Relaunch": nuevo proceso/container sobre el mismo archivo.
        let second = try makeContainer(ModelConfiguration(url: url))
        let store2 = CallHistoryStore(modelContainer: second)
        let entry = try XCTUnwrap(store2.entry(sid: "call-9"))
        XCTAssertEqual(entry.status, .answered)
        XCTAssertEqual(entry.direction, .outgoing)
        XCTAssertEqual(entry.duration, 30, accuracy: 0.5)
    }

    /// REQ-HIST-001: el historial se enlaza con la Conversation vía
    /// relación unidireccional (inverse nil, deleteRule .nullify).
    func testEntryLinksToConversation() throws {
        let container = try makeContainer(ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let conversation = ConversationEntity(jid: "ana@z17.cu", title: "Ana")
        context.insert(conversation)
        try context.save()

        let store = CallHistoryStore(modelContainer: container)
        try store.upsert(
            sid: "call-1", jid: "ana@z17.cu", direction: .incoming,
            status: .answered, duration: 5, conversation: conversation
        )

        let entry = try XCTUnwrap(store.entry(sid: "call-1"))
        XCTAssertEqual(entry.conversation?.jid, "ana@z17.cu")
    }
}