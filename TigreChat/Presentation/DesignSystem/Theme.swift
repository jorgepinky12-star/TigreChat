import SwiftUI
import UIKit

/// Minimal design system: a single red accent over system neutrals.
/// Every color is adaptive — light and dark variants are resolved
/// automatically from the system's appearance (no manual mode switching).
enum Theme {
    enum Colors {
        // MARK: - Accent (single red, both modes)

        /// Primary accent. Light: deep red; dark: wine/burgundy so it keeps
        /// sufficient contrast (>= 4.5:1 with white text) on dark surfaces.
        static let primary = adaptive(
            light: Color(red: 0.87, green: 0.20, blue: 0.18),
            dark: Color(red: 0.66, green: 0.16, blue: 0.21)
        )

        /// Deeper red for pressed/read states. In dark mode it lifts to a
        /// brighter wine so status marks stay visible.
        static let primaryDark = adaptive(
            light: Color(red: 0.70, green: 0.11, blue: 0.10),
            dark: Color(red: 0.85, green: 0.30, blue: 0.36)
        )

        /// Soft red for secondary surfaces (containers, selected fills).
        static let primaryLight = adaptive(
            light: Color(red: 0.95, green: 0.59, blue: 0.57),
            dark: Color(red: 0.40, green: 0.10, blue: 0.14)
        )

        static let primaryContainer = adaptive(
            light: Color(red: 1.0, green: 0.92, blue: 0.92),
            dark: Color(red: 0.30, green: 0.08, blue: 0.12)
        )

        // MARK: - Bubbles

        /// Outgoing bubbles always carry white text, so the fill goes darker
        /// (deep wine) in dark mode instead of lighter.
        static let outgoingBubble = adaptive(
            light: primary,
            dark: Color(red: 0.48, green: 0.11, blue: 0.15)
        )

        /// System fill adapts automatically.
        static let incomingBubble = Color(.systemFill)
        static let incomingText = Color.primary

        // MARK: - Components

        static let unreadBadge = primary
        static let sendButton = primary
        static let attachmentButton = primary
        static let addButton = primary
        static let inputField = Color(.systemFill)

        // MARK: - Message status

        static let statusSent = primary.opacity(0.6)
        static let statusDelivered = primary
        static let statusRead = primaryDark
        static let statusFailed = Color(.systemRed)
        static let statusSending = Color.secondary

        // MARK: - Semantic

        static let encrypted = Color(.systemGreen)
        static let online = Color(.systemGreen)
        static let offline = primary

        static let destructive = Color(.systemRed)
        static let success = Color(.systemGreen)

        // MARK: - Avatars

        static let avatarColors: [Color] = [
            primary,
            .orange, .pink, .purple, .indigo,
            .blue, .teal, .mint, .green, .yellow
        ]

        /// Builds a color that resolves per the system appearance.
        private static func adaptive(light: Color, dark: Color) -> Color {
            Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
            })
        }
    }

    enum Layout {
        static let avatar: CGFloat = 48
        static let avatarLarge: CGFloat = 80
        static let avatarSmall: CGFloat = 32

        static let cornerMessage: CGFloat = 24
        static let cornerCard: CGFloat = 20
        static let cornerButton: CGFloat = 16
        static let cornerOTP: CGFloat = 16

        static let spacing2: CGFloat = 2
        static let spacing4: CGFloat = 4
        static let spacing6: CGFloat = 6
        static let spacing8: CGFloat = 8
        static let spacing12: CGFloat = 12
        static let spacing16: CGFloat = 16
        static let spacing20: CGFloat = 20
        static let spacing24: CGFloat = 24
        static let spacing40: CGFloat = 40
        static let spacing60: CGFloat = 60

        static let minTouchTarget: CGFloat = 44
    }

    enum Typography {
        static var largeTitle: Font { .largeTitle.bold() }
        static var title: Font { .title.bold() }
        static var title2: Font { .title2.bold() }
        static var headline: Font { .headline }
        static var body: Font { .body }
        static var subheadline: Font { .subheadline }
        static var caption: Font { .caption }
        static var caption2: Font { .caption2 }
        static var captionBold: Font { .caption.bold() }
    }
}
