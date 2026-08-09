import SwiftUI

extension View {
    func primaryButton() -> some View {
        self.buttonStyle(.borderedProminent)
            .tint(Theme.Colors.primary)
    }

    func outgoingBubble() -> some View {
        self.foregroundStyle(.white)
            .padding(.horizontal, Theme.Layout.spacing12)
            .padding(.vertical, Theme.Layout.spacing8)
            .background(Theme.Colors.outgoingBubble)
            .clipShape(.rect(cornerRadius: Theme.Layout.cornerMessage))
    }

    func incomingBubble() -> some View {
        self.foregroundStyle(Theme.Colors.incomingText)
            .padding(.horizontal, Theme.Layout.spacing12)
            .padding(.vertical, Theme.Layout.spacing8)
            .background(Theme.Colors.incomingBubble)
            .clipShape(.rect(cornerRadius: Theme.Layout.cornerMessage))
    }

    func unreadBadge() -> some View {
        self
            .font(Theme.Typography.captionBold)
            .foregroundStyle(.white)
            .padding(.horizontal, Theme.Layout.spacing8)
            .padding(.vertical, Theme.Layout.spacing4)
            .background(Theme.Colors.unreadBadge)
            .clipShape(.capsule)
    }

    func capsuleField() -> some View {
        self
            .padding(.horizontal, Theme.Layout.spacing12)
            .padding(.vertical, Theme.Layout.spacing8)
            .background(Theme.Colors.inputField)
            .clipShape(.capsule)
    }

    func statusIcon() -> some View {
        self.font(Theme.Typography.caption2)
    }
}
