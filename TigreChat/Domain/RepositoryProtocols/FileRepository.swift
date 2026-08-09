import Foundation

enum FileError: Error, Sendable {
    case uploadFailed(String)
    case slotRequestFailed(String)
    case fileTooLarge(Int)
    case notConnected
}

protocol FileRepository: Sendable {
    func requestUploadSlot(fileName: String, fileSize: Int, mimeType: String) async throws -> FileUploadSlot
    func uploadFile(data: Data, slot: FileUploadSlot) async throws -> URL
    func uploadFile(from url: URL, slot: FileUploadSlot) async throws -> URL
}
