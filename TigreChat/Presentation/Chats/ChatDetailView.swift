import SwiftUI
import PhotosUI

struct ChatDetailView: View {
    @State private var viewModel: ChatDetailViewModel
    let client: XMPPClient?

    init(conversation: Conversation, messageRepository: MessageRepository, sendFileUseCase: SendFileUseCase? = nil, client: XMPPClient? = nil) {
        let loadMessages = LoadMessagesUseCase(messageRepository: messageRepository)
        let sendMessage = SendMessageUseCase(messageRepository: messageRepository)
        let markAsRead = MarkAsReadUseCase(messageRepository: messageRepository)
        _viewModel = State(initialValue: ChatDetailViewModel(
            conversation: conversation,
            messageRepository: messageRepository,
            sendMessageUseCase: sendMessage,
            markAsReadUseCase: markAsRead,
            sendFileUseCase: sendFileUseCase,
            chatStateManager: client?.chatStateManager
        ))
        self.client = client
    }

    var body: some View {
        VStack(spacing: 0) {
            TypingIndicator(isTyping: viewModel.isOtherTyping, username: viewModel.typingUsername)
            messageList
            Divider()
            inputBar
        }
        .navigationTitle(viewModel.conversation.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await viewModel.setOMEMOEnabled(!viewModel.omemoEnabled) }
                } label: {
                    Image(systemName: viewModel.omemoEnabled ? "lock" : "lock.open")
                        .foregroundStyle(viewModel.omemoEnabled ? Theme.Colors.sendButton : .secondary)
                }
                .accessibilityLabel(viewModel.omemoEnabled
                    ? "Cifrado OMEMO activado"
                    : "Cifrado OMEMO desactivado")
            }
        }
        // El tab bar lo controla la pila (ChatListView/GroupsView según path):
        // el detalle siempre se muestra sin tab bar.
        .task {
            await viewModel.loadMessages()
            await viewModel.markAsRead()
            // Los grupos no entran en el catch-up global MAM: se trae el
            // historial de la sala al abrir.
            await viewModel.loadGroupHistoryIfNeeded()
            if let client { viewModel.observeTyping(from: client) }
        }
        .photosPicker(isPresented: $viewModel.showAttachmentPicker,
                     selection: $viewModel.selectedAttachment,
                     matching: .any(of: [.images, .videos]))
        .onChange(of: viewModel.selectedAttachment) { _, item in
            guard let item else { return }
            Task { await viewModel.sendAttachment(item) }
            viewModel.selectedAttachment = nil
        }
        // Aviso del último envío: desconexión (queda pendiente) o degradación
        // a texto plano porque OMEMO no pudo cifrar.
        .alert("Aviso de envío", isPresented: Binding(
            get: { viewModel.sendError != nil },
            set: { if !$0 { viewModel.sendError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.sendError ?? "")
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Theme.Layout.spacing4) {
                    ForEach(viewModel.messages) { message in
                        ChatBubble(message: message, onRetract: {
                            Task { await viewModel.retract(message) }
                        })
                            .id(message.id)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, Theme.Layout.spacing8)
            }
            .refreshable {
                await viewModel.loadMessages()
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                if let last = viewModel.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: Theme.Layout.spacing8) {
            Button {
                viewModel.showAttachmentPicker = true
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.Colors.attachmentButton)
            }

            TextField("Message", text: $viewModel.draftText, axis: .vertical)
                .textFieldStyle(.plain)
                .capsuleField()
                .onChange(of: viewModel.draftText) { _, _ in
                    Task { await viewModel.notifyTyping() }
                }

            Button {
                Task { await viewModel.sendMessage() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(viewModel.draftText.trimmingCharacters(in: .whitespaces).isEmpty
                        ? .secondary : Theme.Colors.sendButton)
            }
            .disabled(viewModel.draftText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, Theme.Layout.spacing8)
        .background(.regularMaterial)
    }
}
