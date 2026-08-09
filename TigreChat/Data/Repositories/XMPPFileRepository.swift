import Foundation

actor XMPPFileRepository: FileRepository {
    private let uploadManager: XMPPFileUploadManager
    private let domain: String

    init(uploadManager: XMPPFileUploadManager, domain: String) {
        self.uploadManager = uploadManager
        self.domain = domain
    }

    func requestUploadSlot(fileName: String, fileSize: Int, mimeType: String) async throws -> FileUploadSlot {
        try await uploadManager.requestUploadSlot(domain: domain, fileName: fileName, fileSize: fileSize, mimeType: mimeType)
    }

    func uploadFile(data: Data, slot: FileUploadSlot) async throws -> URL {
        try await uploadManager.uploadFile(data: data, slot: slot)
    }

    func uploadFile(from url: URL, slot: FileUploadSlot) async throws -> URL {
        try await uploadManager.uploadFile(from: url, slot: slot)
    }
}
