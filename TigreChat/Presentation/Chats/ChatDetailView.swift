import SwiftUI
import PhotosUI

struct ChatDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: ChatDetailViewModel
    /// Alerta de llamadas: aún no hay cables a Jingle, solo aviso.
    @State private var showCallAlert = false
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
            // Barra de respuesta: se desliza entre el divider y el input.
            if let reply = viewModel.replyingTo {
                replyPreviewBar(for: reply)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            inputBar
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.replyingTo != nil)
        // El título queda como respaldo accesible; el principal del toolbar
        // (avatar + nombre + estado) lo sustituye visualmente.
        .navigationTitle(viewModel.conversation.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    HStack(spacing: Theme.Layout.spacing4) {
                        Image(systemName: "chevron.left")
                    }
                    .foregroundStyle(Theme.Colors.primary)
                }
                .accessibilityLabel("Volver a chats")
            }
            ToolbarItem(placement: .principal) {
                header
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: Theme.Layout.spacing12) {
                    // El candado OMEMO se conserva tal cual (XEP-0384 toggle).
                    Button {
                        Task { await viewModel.setOMEMOEnabled(!viewModel.omemoEnabled) }
                    } label: {
                        Image(systemName: viewModel.omemoEnabled ? "lock" : "lock.open")
                            .foregroundStyle(viewModel.omemoEnabled ? Theme.Colors.sendButton : .secondary)
                    }
                    .accessibilityLabel(viewModel.omemoEnabled
                        ? "Cifrado OMEMO activado"
                        : "Cifrado OMEMO desactivado")

                    callButton(systemImage: "video", label: "Llamada de video")
                    callButton(systemImage: "phone", label: "Llamada")
                }
            }
        }
        // El tab bar lo controla la pila (ChatListView/GroupsView según path):
        // el detalle siempre se muestra sin tab bar.
        .task {
            // Los observadores en vivo se adjuntan PRIMERO, sin awaits delante:
            // si un fetch o envío local se quedara colgado, el chat abierto
            // seguiría recibiendo eventos del stream (antes se adjuntaban al
            // final y cualquier await previo podía dejarlo mudo).
            viewModel.observeMessages()
            if let client {
                viewModel.observeTyping(from: client)
                viewModel.observePresence(from: client)
            }
            await viewModel.loadMessages()
            await viewModel.markAsRead(client: client)
            // Los grupos no entran en el catch-up global MAM: se trae el
            // historial de la sala al abrir.
            await viewModel.loadGroupHistoryIfNeeded()
            // Red de seguridad: refresco periódico mientras el chat está
            // abierto; el mensaje entrante aparece solo aunque el evento
            // del stream no llegara (ver startLivePolling).
            viewModel.startLivePolling()
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
        // Llamadas aún sin cable a Jingle: solo aviso.
        .alert("Llamadas próximamente", isPresented: $showCallAlert) {
            Button("OK", role: .cancel) {}
        }
    }

    /// Cabecera central: avatar con punto de presencia, título y línea de
    /// estado (escribiendo > en línea > desconectado). En grupos solo avatar
    /// + título, sin presencia ni estado.
    private var header: some View {
        HStack(spacing: Theme.Layout.spacing8) {
            ZStack(alignment: .bottomTrailing) {
                AvatarView(name: viewModel.conversation.title, size: 36)
                // Punto de presencia solo en chats 1:1, no en grupos.
                if !viewModel.conversation.isGroup, viewModel.isContactOnline {
                    Circle()
                        .fill(Theme.Colors.online)
                        .frame(width: 10, height: 10)
                        // Borde del color de la barra para recortar el punto
                        // sobre el avatar.
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                }
            }
            VStack(alignment: .leading, spacing: Theme.Layout.spacing2) {
                Text(viewModel.conversation.title)
                    .font(Theme.Typography.headline)
                    .lineLimit(1)
                // Línea de estado solo en chats 1:1, no en grupos.
                if !viewModel.conversation.isGroup {
                    Text(statusLine)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        // VoiceOver: la cabecera se lee como un solo elemento.
        .accessibilityElement(children: .combine)
    }

    private var statusLine: String {
        if viewModel.isOtherTyping { return "escribiendo…" }
        if viewModel.isContactOnline { return "En línea" }
        return "Desconectado"
    }

    /// Botón circular de llamada (video/telefonía): círculo visual de 32pt
    /// sobre un área táctil de 44pt (mínimo HIG), ícono acento del proyecto,
    /// mismo patrón visual para ambos.
    private func callButton(systemImage: String, label: String) -> some View {
        Button {
            showCallAlert = true
        } label: {
            Image(systemName: systemImage)
                .font(Theme.Typography.subheadline)
                .foregroundStyle(Theme.Colors.primary)
                .frame(width: 32, height: 32)
                .background(Theme.Colors.inputField, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Theme.Layout.spacing4) {
                    let messages = viewModel.messages
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        // Píldora de fecha cuando cambia el día (y siempre
                        // antes del primer mensaje).
                        if index == 0 || !Calendar.current.isDate(message.timestamp, inSameDayAs: messages[index - 1].timestamp) {
                            dayDivider(for: message.timestamp)
                        }
                        ChatBubble(message: message, onRetract: {
                            Task { await viewModel.retract(message) }
                        }, onReply: { target in
                            viewModel.setReplyTarget(target)
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
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: viewModel.messages.count) { _, _ in
                if let last = viewModel.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    /// Píldora centrada "Hoy" / "Ayer" / fecha completa entre días distintos.
    private func dayDivider(for timestamp: Date) -> some View {
        let dayStart = Calendar.current.startOfDay(for: timestamp)
        return Text(timestamp.chatDateDivider())
            .font(Theme.Typography.caption)
            .foregroundStyle(.primary)
            .padding(.horizontal, Theme.Layout.spacing12)
            .padding(.vertical, Theme.Layout.spacing4)
            .background(Theme.Colors.inputField)
            .clipShape(.capsule)
            .frame(maxWidth: .infinity)
            .id("divider-\(dayStart.timeIntervalSince1970)")
    }

    /// Barra de respuesta sobre el input: a quién se responde y el texto.
    private func replyPreviewBar(for reply: Message) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Layout.spacing8) {
                VStack(alignment: .leading, spacing: Theme.Layout.spacing2) {
                    Text("Respondiendo a \(viewModel.conversation.title)")
                        .font(Theme.Typography.captionBold)
                        .foregroundStyle(Theme.Colors.primary)
                        .lineLimit(1)
                    Text(reply.text)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    viewModel.clearReply()
                } label: {
                    Image(systemName: "xmark")
                        .font(Theme.Typography.captionBold)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Cancelar respuesta")
            }
            .padding(.horizontal)
            .padding(.vertical, Theme.Layout.spacing8)
            .background(.regularMaterial)
            Divider()
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

            TextField("Mensaje", text: $viewModel.draftText, axis: .vertical)
                .textFieldStyle(.plain)
                .capsuleField()
                .overlay(alignment: .trailing) {
                    // Micrófono solo visual dentro del campo cuando está vacío.
                    if draftIsEmpty {
                        Image(systemName: "mic")
                            .font(Theme.Typography.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.trailing, Theme.Layout.spacing12)
                            .allowsHitTesting(false)
                    }
                }
                .onChange(of: viewModel.draftText) { _, _ in
                    Task { await viewModel.notifyTyping() }
                }

            // Campo vacío → micrófono circular decorativo; con texto → enviar.
            if draftIsEmpty {
                Circle()
                    .fill(Theme.Colors.inputField)
                    .frame(width: 32, height: 32)
                    .overlay {
                        Image(systemName: "mic")
                            .font(Theme.Typography.subheadline)
                            .foregroundStyle(.secondary)
                    }
            } else {
                Button {
                    Task { await viewModel.sendMessage() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Theme.Colors.sendButton)
                        // Área táctil de 44pt centrando el glifo (mínimo HIG).
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Enviar mensaje")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, Theme.Layout.spacing8)
        .background(.regularMaterial)
    }

    private var draftIsEmpty: Bool {
        viewModel.draftText.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
