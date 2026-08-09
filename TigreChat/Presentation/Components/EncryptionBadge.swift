import SwiftUI

struct EncryptionBadge: View {
    var body: some View {
        Image(systemName: "lock.fill")
            .font(Theme.Typography.caption2)
            .foregroundStyle(Theme.Colors.encrypted)
    }
}

#Preview {
    EncryptionBadge()
}
