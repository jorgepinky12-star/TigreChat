import SwiftUI

struct AvatarView: View {
    let name: String
    var size: CGFloat = Theme.Layout.avatar
    var url: URL? = nil

    private var initials: String {
        name.split(separator: " ").prefix(2).compactMap { $0.first.map { String($0) } }.joined()
            .uppercased()
    }

    private var color: Color {
        let index = abs(name.hashValue) % Theme.Colors.avatarColors.count
        return Theme.Colors.avatarColors[index]
    }

    var body: some View {
        if let url {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                placeholderView
            }
            .frame(width: size, height: size)
            .clipShape(.circle)
        } else {
            placeholderView
        }
    }

    private var placeholderView: some View {
        Text(initials)
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient)
            .clipShape(.circle)
    }
}
