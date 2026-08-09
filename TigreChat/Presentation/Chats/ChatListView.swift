import SwiftUI

struct ChatListView: View {
    @State private var viewModel: ChatListViewModel
    @Binding var isLoggedIn: Bool

    init(viewModel: ChatListViewModel, isLoggedIn: Binding<Bool>) {
        _viewModel = State(initialValue: viewModel)
        _isLoggedIn = isLoggedIn
    }

    var body: some View {
        NavigationStack {
            List {
                if viewModel.filteredConversations.isEmpty && !viewModel.isLoading {
                    ContentUnavailableView(
                        "No conversations",
                        systemImage: "message",
                        description: Text("Start a new chat to begin messaging")
                    )
                }
                ForEach(viewModel.filteredConversations) { conversation in
                    NavigationLink(value: conversation) {
                        ConversationRow(conversation: conversation)
                    }
                }
            }
            .searchable(text: $viewModel.searchText)
            .navigationTitle("Chats")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    ConnectionStatusBar(isConnected: viewModel.isConnected)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            viewModel.showNewChat = true
                        } label: {
                            Label("New Chat", systemImage: "person.circle")
                        }
                        Button {
                            viewModel.showNewGroup = true
                        } label: {
                            Label("New Group", systemImage: "person.2.circle")
                        }
                        Button(role: .destructive) {
                            Task {
                                await viewModel.logout()
                                isLoggedIn = false
                            }
                        } label: {
                            Label("Disconnect", systemImage: "power")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .navigationDestination(for: Conversation.self) { conversation in
                ChatDetailView(
                    conversation: conversation,
                    messageRepository: viewModel.messageRepository as MessageRepository,
                    sendFileUseCase: viewModel.sendFileUseCase,
                    client: viewModel.xmppClient
                )
            }
            .sheet(isPresented: $viewModel.showNewChat) {
                NewChatView(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.showNewGroup) {
                NewGroupView(viewModel: viewModel)
            }
            .task {
                await viewModel.loadConversations()
                viewModel.listenToMessages()
            }
        }
    }
}

struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(name: conversation.title, size: 48)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    HStack(spacing: 6) {
                        if conversation.isGroup {
                            Image(systemName: "person.2")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(conversation.title)
                            .font(.headline)
                            .lineLimit(1)
                    }
                    Spacer()
                    if let timestamp = conversation.lastTimestamp {
                        Text(timestamp, style: .time)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let lastMessage = conversation.lastMessage {
                    Text(lastMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if conversation.unreadCount > 0 {
                Text("\(conversation.unreadCount)")
                    .unreadBadge()
            }
        }
        .padding(.vertical, 4)
    }
}

struct NewChatView: View {
    let viewModel: ChatListViewModel
    @State private var jid = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("Contact JID (user@domain)", text: $jid)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                Button("Start Chat") {
                    viewModel.startChat(with: jid)
                    dismiss()
                }
                .disabled(jid.isEmpty)
            }
            .navigationTitle("New Chat")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

struct NewGroupView: View {
    let viewModel: ChatListViewModel
    @State private var name = ""
    @State private var subject = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("Group Name", text: $name)
                TextField("Subject (optional)", text: $subject)
                Button("Create Group") {
                    Task { await viewModel.createGroup(name: name, subject: subject.isEmpty ? nil : subject) }
                    dismiss()
                }
                .disabled(name.isEmpty)
            }
            .navigationTitle("New Group")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
