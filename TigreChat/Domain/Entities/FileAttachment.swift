import Foundation

struct FileAttachment: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let mimeType: String
    let size: Int
    var thumbnailURL: URL?
    var fileName: String
    var isImage: Bool { mimeType.hasPrefix("image/") }
    var isAudio: Bool { mimeType.hasPrefix("audio/") }
    var isVideo: Bool { mimeType.hasPrefix("video/") }
}

struct FileUploadSlot: Sendable {
    let uploadURL: URL
    let getURL: URL
    let headers: [String: String]
}
