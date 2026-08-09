import SwiftUI
import UIKit

struct ChatBubble: View {
    let message: Message

    var body: some View {
        HStack {
            if message.isOutgoing { Spacer(minLength: Theme.Layout.spacing60) }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: Theme.Layout.spacing2) {
                Text(message.text)
                    .foregroundStyle(message.isOutgoing ? .white : Theme.Colors.incomingText)
                    .padding(.horizontal, Theme.Layout.spacing12)
                    .padding(.vertical, Theme.Layout.spacing8)
                    .background(message.isOutgoing ? Theme.Colors.outgoingBubble : Theme.Colors.incomingBubble)
                    .clipShape(.rect(cornerRadius: Theme.Layout.cornerMessage))
                    .overlay(alignment: message.isOutgoing ? .bottomTrailing : .bottomLeading) {
                        Image(systemName: "triangle.fill")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(message.isOutgoing ? Theme.Colors.outgoingBubble : Theme.Colors.incomingBubble)
                            .rotationEffect(.degrees(message.isOutgoing ? -45 : 45))
                            .offset(x: message.isOutgoing ? 6 : -6, y: 4)
                    }

                HStack(spacing: Theme.Layout.spacing4) {
                    if message.isEncrypted {
                        EncryptionBadge()
                    }

                    Text(message.timestamp, style: .time)
                        .font(Theme.Typography.caption2)
                        .foregroundStyle(.secondary)

                    if message.isOutgoing {
                        statusIcon
                    }
                }
                .padding(.horizontal, Theme.Layout.spacing4)
            }

            if !message.isOutgoing { Spacer(minLength: Theme.Layout.spacing60) }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch message.status {
        case .sending:
            Image(systemName: "clock")
                .statusIcon()
                .foregroundStyle(Theme.Colors.statusSending)
        case .sent:
            Image(systemName: "checkmark")
                .statusIcon()
                .foregroundStyle(Theme.Colors.statusSent)
        case .delivered:
            Image(systemName: "checkmark.circle")
                .statusIcon()
                .foregroundStyle(Theme.Colors.statusDelivered)
        case .read:
            Image(systemName: "checkmark.circle.fill")
                .statusIcon()
                .foregroundStyle(Theme.Colors.statusRead)
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .statusIcon()
                .foregroundStyle(Theme.Colors.statusFailed)
        }
    }
}
