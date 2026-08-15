import Foundation
import Observation
import PhotosUI
import SwiftUI

@MainActor
@Observable
final class ChatDetailViewModel {
    private(set) var messages: [Message] = []
    private(set) var isLoading = false
    var draftText = ""
    var isOtherTyping = false
    var typingUsername: String?
    var selectedAttachment: PhotosPickerItem?
    var showAttachmentPicker = false
    /// Aviso del último envío (desconexión o degradación a texto plano).
    var sendError: String?
    /// XEP-0384: estado del cifrado de la conversación (persistido).
    var omemoEnabled: Bool

    let conversation: Conversation
    private let messageRepository: MessageRepository
    private let sendMessageUseCase: SendMessageUseCase
    private let markAsReadUseCase: MarkAsReadUseCase
    private let sendFileUseCase: SendFileUseCase?
    private let chatStateManager: XMPPChatStateManager?
    private var typingListenerTask: Task<Void, Never>?

    init(
        conversation: Conversation,
        messageRepository: MessageRepository,
        sendMessageUseCase: SendMessageUseCase,
        markAsReadUseCase: MarkAsReadUseCase,
        sendFileUseCase: SendFileUseCase? = nil,
        chatStateManager: XMPPChatStateManager? = nil
    ) {
        self.conversation = conversation
        self.messageRepository = messageRepository
        self.sendMessageUseCase = sendMessageUseCase
        self.markAsReadUseCase = markAsReadUseCase
        self.sendFileUseCase = sendFileUseCase
        self.chatStateManager = chatStateManager
        self.omemoEnabled = conversation.omemoEnabled
    }

    func loadMessages() async {
        isLoading = true
        do {
            messages = try await messageRepository.loadMessages(conversationId: conversation.jid, before: nil, limit: 50)
        } catch {
            messages = []
        }
        isLoading = false
    }

    func sendMessage() async {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draftText = ""
        sendError = nil

        try? await chatStateManager?.notifyActive(to: conversation.jid)

        // El repositorio persiste `.pending` si el envío falla por desconexión
        // (se reintenta al reconectar) y degrada a texto plano si OMEMO no
        // puede cifrar; ambos casos se comunican al usuario aquí abajo.
        do {
            let wasSentEncrypted = try await sendMessageUseCase.execute(text: text, to: conversation.jid)
            if omemoEnabled && !wasSentEncrypted {
                sendError = "El contacto no tiene dispositivos OMEMO o el cifrado falló. El mensaje se envió sin cifrar."
            }
        } catch {
            sendError = "Sin conexión con el servidor: el mensaje quedó pendiente y se enviará al reconectar."
        }
        // Recarga desde el store para reflejar el estado real (.sent/.pending).
        await loadMessages()
    }

    func sendAttachment(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        let mimeType = item.supportedContentTypes.first?.preferredMIMEType ?? "application/octet-stream"
        let fileName = "photo_\(Date().timeIntervalSince1970).jpg"

        _ = try? await sendFileUseCase?.execute(data: data, fileName: fileName, mimeType: mimeType, to: conversation.jid)
        await loadMessages()
    }

    /// XEP-0424: retracta un mensaje propio en todos los dispositivos.
    func retract(_ message: Message) async {
        try? await messageRepository.retract(messageID: message.id, conversationJID: conversation.jid)
        messages.removeAll { $0.id == message.id }
        await loadMessages()
    }

    func markAsRead() async {
        try? await markAsReadUseCase.execute(conversationId: conversation.jid)
    }

    /// XEP-0384: persiste el nuevo estado del cifrado de la conversación.
    func setOMEMOEnabled(_ enabled: Bool) async {
        omemoEnabled = enabled
        try? await messageRepository.setOMEMOEnabled(enabled, forConversation: conversation.jid)
    }

    /// XEP-0313: carga el historial de la sala al abrir un grupo (los MUC no
    /// reciben el catch-up global como los 1:1).
    func loadGroupHistoryIfNeeded() async {
        guard conversation.isGroup else { return }
        try? await messageRepository.syncGroupHistory(roomJID: conversation.jid, limit: 50)
        await loadMessages()
    }

    func notifyTyping() async {
        try? await chatStateManager?.sendComposing(to: conversation.jid)
    }

    func observeTyping(from client: XMPPClient) {
        guard typingListenerTask == nil else { return }
        typingListenerTask = Task { [weak self] in
            guard let self else { return }
            for await (jid, state) in client.chatStateStream {
                let sender = jid.components(separatedBy: "/").first ?? jid
                guard sender == conversation.jid else { continue }
                isOtherTyping = state == "composing"
                if isOtherTyping {
                    typingUsername = jid.components(separatedBy: "/").last
                }
            }
        }
    }

    isolated deinit {
        typingListenerTask?.cancel()
    }
}
