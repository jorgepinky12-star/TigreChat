//
//  MissedCallReconciler.swift
//  TigreChat
//
//  T-VOIPCALLS-062 (GREEN): reconciliador de llamadas perdidas.
//  Consulta MAM (XEP-0313) tras reconectar, upsert por sid en
//  CallHistoryStore, dedupe. REQ-HIST-004.
//

import Foundation

/// Entrada MAM de un IQ jingle perdido.
struct MAMJingleEntry: Sendable {
    let sid: String
    let from: String      // bare JID del iniciador
    let timestamp: Date
    let direction: CallDirection
}

/// Protocolo para consultas MAM (inyectable, testeable).
protocol MAMQuerying: Sendable {
    func fetchMissedJingles(since: Date) async throws -> [MAMJingleEntry]
}

/// Reconciliador de llamadas perdidas: al reconectar, consulta MAM
/// y upserta filas `missed` que el usuario no vio (ring abatido
/// por backgrounding o desconexión).
@MainActor
final class MissedCallReconciler {
    private let historyStore: CallHistoryStore
    private let mam: MAMQuerying

    init(historyStore: CallHistoryStore, mam: MAMQuerying) {
        self.historyStore = historyStore
        self.mam = mam
    }

    /// Reconcila llamadas perdidas desde `since` hasta ahora.
    /// Retorna el número de filas upsertadas (deduplicadas por sid).
    @discardableResult
    func reconcile(since: Date) async throws -> Int {
        let entries = try await mam.fetchMissedJingles(since: since)
        var upserted = 0
        for entry in entries {
            // Dedupe: si ya existe una fila con ese sid, no sobrescribir.
            let existing = historyStore.entry(sid: entry.sid)
            guard existing == nil else { continue }

            _ = try? await historyStore.upsert(
                sid: entry.sid,
                jid: entry.from,
                direction: entry.direction,
                status: .missed,
                isVideo: false
            )
            upserted += 1
        }
        return upserted
    }
}
