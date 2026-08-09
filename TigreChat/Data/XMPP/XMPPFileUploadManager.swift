import Foundation

actor XMPPFileUploadManager {
    private let connection: XMPPConnection
    private var idCounter: UInt32 = 0
    private let urlSession: URLSession

    init(connection: XMPPConnection) {
        self.connection = connection
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 300
        urlSession = URLSession(configuration: config)
    }

    func requestUploadSlot(domain: String, fileName: String, fileSize: Int, mimeType: String) async throws -> FileUploadSlot {
        let id = nextID()
        let uploadDomain = "upload.\(domain)"
        let url = URL(string: "https://\(uploadDomain)/upload/\(fileName)")!
        let getURL = URL(string: "https://\(uploadDomain)/get/\(fileName)")!
        return FileUploadSlot(uploadURL: url, getURL: getURL, headers: ["Content-Type": mimeType])
    }

    func uploadFile(data: Data, slot: FileUploadSlot) async throws -> URL {
        var request = URLRequest(url: slot.uploadURL)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        for (key, value) in slot.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (_, response) = try await urlSession.upload(for: request, from: data)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw FileError.uploadFailed("Server returned error")
        }
        return slot.getURL
    }

    func uploadFile(from url: URL, slot: FileUploadSlot) async throws -> URL {
        let data = try Data(contentsOf: url)
        return try await uploadFile(data: data, slot: slot)
    }

    private func nextID() -> String {
        idCounter += 1
        return "fu\(idCounter)"
    }
}
