import SwiftUI
import SwiftData

@main
struct TigreChatApp: App {
    let deps = Dependencies()

    var body: some Scene {
        WindowGroup {
            AppRouter()
                .environment(\.dependencies, deps)
                .tint(Theme.Colors.primary)
        }
        .modelContainer(deps.modelContainer)
    }
}
