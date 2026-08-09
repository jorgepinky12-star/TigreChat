import SwiftUI

struct MessageAttachmentView: View {
    let url: URL
    let mimeType: String

    var body: some View {
        Group {
            if mimeType.hasPrefix("image/") {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit()
                        .clipShape(.rect(cornerRadius: Theme.Layout.cornerCard))
                } placeholder: {
                    ProgressView()
                        .tint(Theme.Colors.primary)
                        .frame(height: 150)
                }
            } else {
                HStack(spacing: Theme.Layout.spacing8) {
                    Image(systemName: iconName)
                        .font(.title2)
                        .foregroundStyle(Theme.Colors.primary)
                    VStack(alignment: .leading) {
                        Text(url.lastPathComponent)
                            .font(Theme.Typography.caption)
                            .lineLimit(1)
                        Text(mimeType)
                            .font(Theme.Typography.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .background(.fill.quaternary)
                .clipShape(.rect(cornerRadius: Theme.Layout.cornerCard))
            }
        }
    }

    private var iconName: String {
        switch mimeType {
        case let mime where mime.hasPrefix("audio/"): "music.note"
        case let mime where mime.hasPrefix("video/"): "film"
        case let mime where mime.hasPrefix("application/pdf"): "doc.richtext"
        default: "doc"
        }
    }
}
