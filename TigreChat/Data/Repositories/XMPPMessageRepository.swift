import Foundation
import SwiftData

/// MainActor-confined: ModelContext is not Sendable, so Apple's documented
/// pattern is to confine it to the main actor for UI-bound persistence.
@MainActor
final class XMPPMessageRepository: MessageRepository {
    private let client: XMPPClient
    private let modelContext: ModelContext
    private let messageContinuation: AsyncStream<Message>.Continuation
    let messageStream: AsyncStream<Message>

    init(client: XMPPClient, modelContainer: ModelContainer) {
        self.client = client
        self.modelContext = ModelContext(modelContainer)
        var cont: AsyncStream<Message>.Continuation!
        let stream = AsyncStream<Message> { continuation in
            cont = continuation
        }
        messageContinuation = cont
        messageStream = stream
        startListening()
        startStatusListening()
        startRetractionListening()
        startOutboxListening()
    }

    private func startStatusListening() {
        Task { [weak self] in
            guard let self else { return }
            // WU4: receipts (XEP-0184) y markers (XEP-0333) actualizan estados.
            for await update in await client.statusUpdateStream {
                await applyStatusUpdate(update.id, update.status)
            }
        }
    }

    private func applyStatusUpdate(_ id: String, _ status: MessageStatus) async {
        let fetch = FetchDescriptor<MessageEntity>(
            predicate: #Predicate { $0.id == id }
        )
        if let entity = try? modelContext.fetch(fetch).first {
            entity.status = status
            try? modelContext.save()
            messageContinuation.yield(entity.toDomain())
        }
    }

    private func startListening() {
        Task { [weak self] in
            guard let self else { return }
            for await message in await client.messageStream {
                await insertMessage(message, incrementUnread: true)
            }
        }
    }

    /// Inserta con dedupe por id: los ecos de carbons (XEP-0280) de un mensaje
    /// propio ya persistido llegan con el mismo id y deben ignorarse.
    private func insertMessage(_ message: Message, incrementUnread: Bool) async {
        let targetID = message.id
        let fetch = FetchDescriptor<MessageEntity>(
            predicate: #Predicate { $0.id == targetID }
        )
        if (try? modelContext.fetch(fetch).first) != nil { return }
        modelContext.insert(MessageEntity(from: message))
        try? modelContext.save()
        updateConversationPreview(message, incrementUnread: incrementUnread)
        messageContinuation.yield(message)
    }

    private func updateConversationPreview(_ message: Message, incrementUnread: Bool = true) {
        let preview = message.attachment.map { $0.displayFileName } ?? message.text
        // La conversación SIEMPRE se identifica por el JID desnudo: el
        // /resource (dispositivo) no debe duplicar la lista ni el historial.
        // (Antes se usaba `senderJID`, que conserva el /resource, con lo que
        // cada dispositivo del contacto creaba una conversación repetida.)
        let jid = bareJID(message.conversationId)
        let fetch = FetchDescriptor<ConversationEntity>(
            predicate: #Predicate { $0.jid == jid }
        )
        if let existing = try? modelContext.fetch(fetch).first {
            existing.lastMessage = preview
            existing.lastTimestamp = message.timestamp
            if incrementUnread, !message.isOutgoing { existing.unreadCount += 1 }
        } else {
            let conv = ConversationEntity(
                jid: jid,
                title: jid.components(separatedBy: "@").first ?? jid,
                lastMessage: preview,
                lastTimestamp: message.timestamp,
                unreadCount: (incrementUnread && !message.isOutgoing) ? 1 : 0
            )
            modelContext.insert(conv)
        }
        try? modelContext.save()
    }

    @discardableResult
    func send(message: Message) async throws -> Bool {
        // Fase A (XEP-0384): solo se cifran mensajes de texto en conversaciones
        // con OMEMO activado; los adjuntos (oob) se envían sin cifrar.
        let conversationJID = message.conversationId
        let conversation = try? modelContext.fetch(
            FetchDescriptor<ConversationEntity>(predicate: #Predicate { $0.jid == conversationJID })
        ).first
        let shouldEncrypt = conversation?.omemoEnabled == true && message.attachment == nil
        // Se persiste ANTES de enviar: si el envío falla por desconexión, el
        // mensaje queda como `.pending` (outbox) y se reintenta al reconectar.
        let entity = MessageEntity(from: message)
        entity.isEncrypted = shouldEncrypt
        modelContext.insert(entity)
        do {
            try await sendOnce(entity: entity, omemo: shouldEncrypt)
            entity.status = .sent
            try modelContext.save()
        } catch {
            entity.status = .pending
            try? modelContext.save()
            throw error
        }
        return entity.isEncrypted
    }

    /// Envía un mensaje; si OMEMO falla (contacto sin dispositivos, sesión no
    /// formable o servidor sin soporte PEP), se reenvía SIN cifrar y se marca
    /// `isEncrypted = false` (XEP-0384 §4.5 permite degradar con notificación
    /// al usuario, como hace Conversations). Un fallo de transporte (desconexión)
    /// no degrada nada: el envío en claro también falla y el mensaje queda
    /// `.pending` para el outbox.
    private func sendOnce(entity: MessageEntity, omemo: Bool) async throws {
        do {
            try await client.sendMessage(
                id: entity.id,
                body: entity.text,
                to: entity.conversationId,
                oobURL: entity.attachmentURL,
                omemo: omemo
            )
        } catch {
            guard omemo, entity.attachmentURL == nil else { throw error }
            entity.isEncrypted = false
            try await client.sendMessage(
                id: entity.id,
                body: entity.text,
                to: entity.conversationId,
                oobURL: entity.attachmentURL,
                omemo: false
            )
        }
    }

    /// Reintenta los mensajes `.pending` (enviados durante una desconexión).
    /// Se dispara cada vez que el cliente autentica (arranque y reconexión).
    func flushPendingOutbox() async {
        let pending = (try? modelContext.fetch(
            FetchDescriptor<MessageEntity>(predicate: #Predicate { $0.statusRaw == "pending" })
        )) ?? []
        for entity in pending {
            do {
                try await client.sendMessage(
                    id: entity.id,
                    body: entity.text,
                    to: entity.conversationId,
                    oobURL: entity.attachmentURL,
                    omemo: entity.isEncrypted
                )
                entity.status = .sent
                try? modelContext.save()
                messageContinuation.yield(entity.toDomain())
            } catch {
                // Sigue pendiente; se reintentará en la próxima reconexión.
            }
        }
    }

    /// Outbox + catch-up: tras autenticar, reenvía pendientes y trae la
    /// última página del archivo global (cubre lo que llegó estando offline).
    private func startOutboxListening() {
        Task { [weak self] in
            guard let self else { return }
            for await isAuthenticated in await client.authStateStream {
                if isAuthenticated {
                    await self.flushPendingOutbox()
                    try? await self.syncRecentMessages(limit: 20)
                }
            }
        }
    }

    func loadMessages(conversationId: String, before: Date? = nil, limit: Int = 50) async throws -> [Message] {
        var predicate: Predicate<MessageEntity>?
        if let before {
            predicate = #Predicate { $0.conversationId == conversationId && $0.timestamp < before }
        } else {
            predicate = #Predicate { $0.conversationId == conversationId }
        }
        var descriptor = FetchDescriptor<MessageEntity>(predicate: predicate, sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        descriptor.fetchLimit = limit
        let entities = try modelContext.fetch(descriptor)
        return entities.reversed().map { $0.toDomain() }
    }

    func loadConversations() async throws -> [Conversation] {
        try? syncRosterConversations()
        await normalizeLegacyConversationData()
        let descriptor = FetchDescriptor<ConversationEntity>(
            sortBy: [SortDescriptor(\.lastTimestamp, order: .reverse)]
        )
        let entities = try modelContext.fetch(descriptor)
        return entities.map { $0.toDomain() }
    }

    /// Normaliza un JID a su forma desnuda (sin `/resource`). En 1:1 y MUC el
    /// recurso solo identifica el dispositivo/nick del remitente, nunca la
    /// conversación; por eso las claves de conversación van siempre en bare.
    private func bareJID(_ jid: String) -> String {
        guard jid.contains("@") else { return jid }
        return jid.components(separatedBy: "/").first ?? jid
    }

    /// Migración de datos viejos (idempotente): antes del fix de IDs, los
    /// mensajes y conversaciones podían guardar el JID con `/resource`, lo que
    /// (1) pintaba el mismo contacto varias veces en la lista de chats y
    /// (2) dejaba el historial "vacío" al abrir la conversación, porque
    /// `loadMessages` matchea el JID desnudo exacto. Esta pasada reescribe los
    /// `conversationId` a su forma desnuda y fusiona las conversaciones
    /// repetidas en una sola.
    func normalizeLegacyConversationData() async {
        let allMessages = (try? modelContext.fetch(FetchDescriptor<MessageEntity>())) ?? []
        var changed = false
        for entity in allMessages {
            let bare = bareJID(entity.conversationId)
            if bare != entity.conversationId {
                entity.conversationId = bare
                changed = true
            }
        }

        let allConversations = (try? modelContext.fetch(FetchDescriptor<ConversationEntity>())) ?? []
        var byBare: [String: [ConversationEntity]] = [:]
        for conv in allConversations {
            byBare[bareJID(conv.jid), default: []].append(conv)
        }
        for (bare, group) in byBare where group.count > 1 {
            // Base: la que ya usa el JID desnudo si existe; si no, la primera.
            guard let base = group.first(where: { $0.jid == bare }) ?? group.first else { continue }
            var latest = base.lastTimestamp ?? .distantPast
            var lastMessage = base.lastMessage
            var unread = base.unreadCount
            for conv in group where conv !== base {
                if let ts = conv.lastTimestamp, ts > latest {
                    latest = ts
                    lastMessage = conv.lastMessage
                }
                unread = max(unread, conv.unreadCount)
                if conv.isGroup { base.isGroup = true }
                if conv.omemoEnabled { base.omemoEnabled = true }
                if base.title.isEmpty { base.title = conv.title }
                modelContext.delete(conv)
            }
            if base.jid != bare { base.jid = bare }
            base.lastTimestamp = latest == .distantPast ? nil : latest
            base.lastMessage = lastMessage
            base.unreadCount = unread
            changed = true
        }

        if changed { try? modelContext.save() }
    }

    /// Garantiza que todo contacto real del roster tenga su conversación en
    /// la lista de chats. `XMPPContactRepository` ya las crea al recibir el
    /// roster; este merge defensivo cubre arranques donde el roster llegó
    /// antes de que este repositorio hiciera su primer fetch.
    private func syncRosterConversations() {
        let contacts = (try? modelContext.fetch(FetchDescriptor<ContactEntity>())) ?? []
        for contact in contacts where !contact.isPending {
            let targetJID = contact.jid
            let fetch = FetchDescriptor<ConversationEntity>(
                predicate: #Predicate { $0.jid == targetJID }
            )
            if (try? modelContext.fetch(fetch).first) == nil {
                let title = contact.displayName.isEmpty
                    ? (contact.jid.components(separatedBy: "@").first ?? contact.jid)
                    : contact.displayName
                modelContext.insert(ConversationEntity(jid: contact.jid, title: title))
            }
        }
        try? modelContext.save()
    }

    func markAsRead(conversationId: String) async throws {
        let fetch = FetchDescriptor<ConversationEntity>(
            predicate: #Predicate { $0.jid == conversationId }
        )
        if let entity = try modelContext.fetch(fetch).first {
            entity.unreadCount = 0
            try modelContext.save()
        }
    }

    /// XEP-0384: activa/desactiva el cifrado OMEMO de una conversación. Si la
    /// conversación aún no existe (chat iniciado sin mensajes previos), se crea.
    func setOMEMOEnabled(_ enabled: Bool, forConversation jid: String) async throws {
        let fetch = FetchDescriptor<ConversationEntity>(
            predicate: #Predicate { $0.jid == jid }
        )
        let entity: ConversationEntity
        if let existing = try? modelContext.fetch(fetch).first {
            entity = existing
        } else {
            entity = ConversationEntity(
                jid: jid,
                title: jid.components(separatedBy: "@").first ?? jid
            )
            modelContext.insert(entity)
        }
        entity.omemoEnabled = enabled
        try modelContext.save()
    }

    /// XEP-0313 catch-up (como el pull-to-refresh del cliente Android): trae la
    /// página más reciente del archivo global, inserta mensajes nuevos con
    /// dedupe por id y NO incrementa el contador de no leídos (son mensajes
    /// históricos, no notificaciones recién llegadas).
    func syncRecentMessages(limit: Int = 20) async throws {
        let messages = try await client.syncRecentMessages(limit: limit)
        for message in messages where !isTombstoned(message.id) {
            let targetID = message.id
            let fetch = FetchDescriptor<MessageEntity>(
                predicate: #Predicate { $0.id == targetID }
            )
            if (try? modelContext.fetch(fetch).first) != nil { continue }
            modelContext.insert(MessageEntity(from: message))
            updateConversationPreview(message, incrementUnread: false)
        }
        try? modelContext.save()
    }

    /// XEP-0313: historial de sala MUC (grupos). Trae la última página del
    /// archivo de la sala y la inserta con dedupe por id, sin tocar el
    /// contador de no leídos.
    func syncGroupHistory(roomJID: String, limit: Int = 50) async throws {
        let messages = try await client.syncMUCArchive(jid: roomJID, limit: limit)
        for message in messages where !isTombstoned(message.id) {
            let targetID = message.id
            let fetch = FetchDescriptor<MessageEntity>(
                predicate: #Predicate { $0.id == targetID }
            )
            if (try? modelContext.fetch(fetch).first) != nil { continue }
            modelContext.insert(MessageEntity(from: message))
            updateGroupConversationPreview(message)
        }
        try? modelContext.save()
    }

    /// Actualiza la preview SOLO si la conversación de la sala ya existe (los
    /// mensajes MUC entrantes usan senderJID `nick@room/resource`, que no debe
    /// crear conversaciones espurias).
    private func updateGroupConversationPreview(_ message: Message) {
        let jid = message.conversationId
        let fetch = FetchDescriptor<ConversationEntity>(
            predicate: #Predicate { $0.jid == jid }
        )
        if let existing = try? modelContext.fetch(fetch).first {
            existing.lastMessage = message.text
            existing.lastTimestamp = message.timestamp
            try? modelContext.save()
        }
    }

    // MARK: - Retracción (XEP-0424)

    /// Tombstones de ids retractados: evitan que un mensaje borrado "vuelva a
    /// la vida" desde el archivo MAM en la próxima sincronización.
    private static let retractedIDsKey = "retracted_message_ids"

    private func startRetractionListening() {
        Task { [weak self] in
            guard let self else { return }
            for await retractedID in await client.retractionStream {
                await self.handleRetraction(retractedID)
            }
        }
    }

    private func handleRetraction(_ id: String) async {
        let fetch = FetchDescriptor<MessageEntity>(
            predicate: #Predicate { $0.id == id }
        )
        if let entity = try? modelContext.fetch(fetch).first {
            let conversationId = entity.conversationId
            modelContext.delete(entity)
            try? modelContext.save()
            await refreshConversationPreviewIfNeeded(conversationId: conversationId)
        }
        addTombstone(id)
    }

    private func refreshConversationPreviewIfNeeded(conversationId: String) async {
        let convFetch = FetchDescriptor<ConversationEntity>(
            predicate: #Predicate { $0.jid == conversationId }
        )
        guard let conv = try? modelContext.fetch(convFetch).first else { return }
        let msgFetch = FetchDescriptor<MessageEntity>(
            predicate: #Predicate { $0.conversationId == conversationId },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        if let latest = try? modelContext.fetch(msgFetch).first {
            conv.lastMessage = latest.text
            conv.lastTimestamp = latest.timestamp
        } else {
            conv.lastMessage = ""
        }
        try? modelContext.save()
    }

    private func addTombstone(_ id: String) {
        var ids = UserDefaults.standard.stringArray(forKey: Self.retractedIDsKey) ?? []
        if !ids.contains(id) {
            ids.append(id)
            UserDefaults.standard.set(ids, forKey: Self.retractedIDsKey)
        }
    }

    private func isTombstoned(_ id: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: Self.retractedIDsKey) ?? []).contains(id)
    }

    /// Retracta un mensaje propio: avisa al servidor, borra local e inscribe
    /// el tombstone para que no reaparezca desde el archivo.
    func retract(messageID: String, conversationJID: String) async throws {
        try await client.sendRetraction(for: messageID, to: conversationJID)
        let fetch = FetchDescriptor<MessageEntity>(
            predicate: #Predicate { $0.id == messageID }
        )
        if let entity = try? modelContext.fetch(fetch).first {
            modelContext.delete(entity)
            try? modelContext.save()
        }
        addTombstone(messageID)
    }
}
