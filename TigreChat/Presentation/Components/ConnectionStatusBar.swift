import SwiftUI

struct ConnectionStatusBar: View {
    let isConnected: Bool

    var body: some View {
        HStack(spacing: Theme.Layout.spacing6) {
            Circle()
                .fill(isConnected ? Theme.Colors.online : Theme.Colors.offline)
                .frame(width: 8, height: 8)
            Text(isConnected ? "Connected" : "Disconnected")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Theme.Layout.spacing12)
        .padding(.vertical, Theme.Layout.spacing4)
        .background(.fill.quaternary)
        .clipShape(.capsule)
    }
}
