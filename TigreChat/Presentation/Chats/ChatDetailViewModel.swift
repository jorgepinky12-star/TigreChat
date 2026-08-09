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

        try? await chatStateManager?.notifyActive(to: conversation.jid)

        do {
            let message = try await sendMessageUseCase.execute(text: text, to: conversation.jid)
            messages.append(message)
        } catch {
            let failedMessage = Message(
                conversationId: conversation.jid,
                senderJID: "",
                text: text,
                isOutgoing: true,
                status: .failed
            )
            messages.append(failedMessage)
        }
    }

    func sendAttachment(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        let mimeType = item.supportedContentTypes.first?.preferredMIMEType ?? "application/octet-stream"
        let fileName = "photo_\(Date().timeIntervalSince1970).jpg"

        do {
            let message = try await sendFileUseCase?.execute(data: data, fileName: fileName, mimeType: mimeType, to: conversation.jid)
            if let message { messages.append(message) }
        } catch {
            let failedMessage = Message(
                conversationId: conversation.jid,
                senderJID: "",
                text: "Failed to send attachment",
                isOutgoing: true,
                status: .failed
            )
            messages.append(failedMessage)
        }
    }

    func markAsRead() async {
        try? await markAsReadUseCase.execute(conversationId: conversation.jid)
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
