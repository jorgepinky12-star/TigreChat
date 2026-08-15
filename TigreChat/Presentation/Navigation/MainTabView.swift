import SwiftUI

/// Root view after login: bottom tab bar with the four main sections
/// (Messages, Groups, Calls, Settings) and the shared chat state.
struct MainTabView: View {
    @Binding var isLoggedIn: Bool
    @State private var viewModel: ChatListViewModel

    init(viewModel: ChatListViewModel, isLoggedIn: Binding<Bool>) {
        _viewModel = State(initialValue: viewModel)
        _isLoggedIn = isLoggedIn
    }

    var body: some View {
        TabView {
            ChatListView(viewModel: viewModel, isLoggedIn: $isLoggedIn)
                .tabItem { Label("Messages", systemImage: "message.fill") }
            GroupsView(viewModel: viewModel)
                .tabItem { Label("Groups", systemImage: "person.2.fill") }
            CallsView()
                .tabItem { Label("Calls", systemImage: "phone.fill") }
            SettingsView(isLoggedIn: $isLoggedIn)
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
    }
}

/// Group conversations from the shared roster, mirroring ChatListView.
struct GroupsView: View {
    @State private var viewModel: ChatListViewModel
    /// Pila de navegación: controla la visibilidad del tab bar (raíz visible,
    /// detalle de grupo oculto).
    @State private var path: [Conversation] = []

    init(viewModel: ChatListViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if viewModel.conversations.filter(\.isGroup).isEmpty && !viewModel.isLoading {
                    ContentUnavailableView(
                        "No groups",
                        systemImage: "person.2",
                        description: Text("Groups you join will appear here")
                    )
                }
                ForEach(viewModel.conversations.filter(\.isGroup)) { conversation in
                    NavigationLink(value: conversation) {
                        ConversationRow(conversation: conversation)
                    }
                }
            }
            .navigationTitle("Groups")
            .navigationDestination(for: Conversation.self) { conversation in
                ChatDetailView(
                    conversation: conversation,
                    messageRepository: viewModel.messageRepository as MessageRepository,
                    sendFileUseCase: viewModel.sendFileUseCase,
                    client: viewModel.xmppClient
                )
            }
            .task {
                await viewModel.loadConversations()
                viewModel.listenToMessages()
            }
        }
        // Mismo dueño único de la visibilidad que en Messages: raíz visible,
        // detalle de grupo oculto, reaparece junto con el pop.
        .toolbar(path.isEmpty ? .visible : .hidden, for: .tabBar)
    }
}

/// Placeholder for the calls history; the active call screen lives in
/// Presentation/Calls once a call is in progress.
struct CallsView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "No Calls",
                systemImage: "phone",
                description: Text("Your recent calls will appear here")
            )
            .navigationTitle("Calls")
        }
    }
}

/// Minimal settings: account info and sign-out. Grows as the app ships
/// prefs (notifications, privacy, appearance…).
struct SettingsView: View {
    @Binding var isLoggedIn: Bool
    @Environment(\.dependencies) private var deps

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    LabeledContent("Account", value: "Demo")
                }
                Section {
                    Button("Disconnect", role: .destructive) {
                        Task {
                            await deps.authRepository.disconnect()
                            isLoggedIn = false
                        }
                    }
                }
                Section("About") {
                    LabeledContent(
                        "Version",
                        value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
                    )
                }
            }
            .navigationTitle("Settings")
        }
    }
}