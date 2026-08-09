import SwiftUI

struct TypingIndicator: View {
    let isTyping: Bool
    let username: String?

    var body: some View {
        if isTyping {
            HStack(spacing: Theme.Layout.spacing4) {
                animatedDots
                if let username {
                    Text("\(username) typing...")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, Theme.Layout.spacing4)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var animatedDots: some View {
        HStack(spacing: 3) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Theme.Colors.statusSent)
                    .frame(width: 5, height: 5)
                    .opacity(isTyping ? 0.4 : 0)
                    .animation(
                        .easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.2),
                        value: isTyping
                    )
            }
        }
    }
}
