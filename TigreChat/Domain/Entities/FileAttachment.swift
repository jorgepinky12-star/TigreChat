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
    /// Nombre para mostrar: cae al nombre del archivo remoto si viene vacío.
    var displayFileName: String {
        fileName.isEmpty ? url.lastPathComponent : fileName
    }
}

struct FileUploadSlot: Sendable {
    let uploadURL: URL
    let getURL: URL
    let headers: [String: String]
}
