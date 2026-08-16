import Foundation
import Observation
import os
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
    /// Mensaje al que se está respondiendo (barra de reply sobre el input).
    private(set) var replyingTo: Message?
    /// Presencia del contacto 1:1 derivada del presenceStream del cliente
    /// ("En línea" / "Desconectado" en la cabecera del detalle).
    private(set) var isContactOnline = false

    let conversation: Conversation
    private let messageRepository: MessageRepository
    private let sendMessageUseCase: SendMessageUseCase
    private let markAsReadUseCase: MarkAsReadUseCase
    private let sendFileUseCase: SendFileUseCase?
    private let chatStateManager: XMPPChatStateManager?
    private var typingListenerTask: Task<Void, Never>?
    private var messageListenerTask: Task<Void, Never>?
    private var livePollTask: Task<Void, Never>?
    private var presenceListenerTask: Task<Void, Never>?

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
            os_log("[Detail] loadMessages jid=%{public}@ -> %d msgs", log: xmppLog, type: .debug, conversation.jid, messages.count)
        } catch {
            messages = []
            os_log("[Detail] loadMessages FAILED jid=%{public}@ err=%{public}@", log: xmppLog, type: .error, conversation.jid, String(describing: error))
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
        // La barra de reply se descarta tras encolar el envío: el texto ya
        // viaja en el mensaje, la referencia no hace falta en la vista.
        clearReply()
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

    /// Limpia el contador local de no leídos y, si hay cliente, avisa al
    /// contacto (XEP-0333) de que ya leímos lo último que nos envió: el id del
    /// último mensaje entrante implica todos los anteriores. Solo 1:1; en
    /// grupos los markers no aplican.
    func markAsRead(client: XMPPClient? = nil) async {
        try? await markAsReadUseCase.execute(conversationId: conversation.jid)
        guard let client, !conversation.isGroup else { return }
        if let latestIncoming = messages.filter({ !$0.isOutgoing }).last {
            try? await client.sendReadMarker(to: conversation.jid, for: latestIncoming.id)
        }
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

    /// Marca el mensaje como destino de la barra de reply del input.
    func setReplyTarget(_ message: Message) {
        replyingTo = message
    }

    /// Descarta la respuesta en curso (X de la barra o tras enviar).
    func clearReply() {
        replyingTo = nil
    }

    /// Observa la presencia del contacto 1:1 para la línea de estado de la
    /// cabecera. Patrón idéntico a observeTyping: un solo Task guardado en la
    /// instancia; al ser @MainActor el VM, el Task hereda la isolación y
    /// escribe isContactOnline en el actor correcto.
    func observePresence(from client: XMPPClient) {
        guard presenceListenerTask == nil else { return }
        presenceListenerTask = Task { [weak self] in
            guard let self else { return }
            for await stanza in client.presenceStream {
                // El from llega con recurso ("user@domain/resource"): se
                // compara contra el JID desnudo de la conversación.
                let sender = stanza.from?.split(separator: "/").first.map(String.init) ?? ""
                guard sender == conversation.jid else { continue }
                isContactOnline = stanza.type != "unavailable"
            }
        }
    }

    /// Mantiene el chat abierto en vivo: ante cualquier evento del stream
    /// (mensaje entrante, eco de envío, receipt, retracción) recarga esta
    /// conversación. Antes el detalle solo refrescaba en `.task` y tras
    /// enviar, por lo que había que salir y volver a entrar para ver cambios.
    func observeMessages() {
        guard messageListenerTask == nil else { return }
        messageListenerTask = Task { [weak self] in
            guard let self else { return }
            for await _ in messageRepository.messageStream {
                os_log("[Detail] stream event -> reload", log: xmppLog, type: .debug)
                await loadMessages()
            }
        }
    }

    /// Red de seguridad determinista: mientras el chat está abierto, recarga
    /// la conversación desde el store cada pocos segundos. Aunque el evento
    /// del stream se perdiera por cualquier causa (ciclo de vida de la vista,
    /// buffering, entrega en curso), un mensaje entrante aparece en segundos
    /// sin tener que salir y volver a entrar. La recarga es un fetch local
    /// barato e idempotente; el listener del stream sigue como vía rápida.
    func startLivePolling(interval: Duration = .seconds(3)) {
        guard livePollTask == nil else { return }
        livePollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { break }
                await loadMessages()
            }
        }
    }

    isolated deinit {
        typingListenerTask?.cancel()
        messageListenerTask?.cancel()
        livePollTask?.cancel()
        presenceListenerTask?.cancel()
    }
}
