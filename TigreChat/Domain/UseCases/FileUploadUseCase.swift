import Foundation

struct SendFileUseCase: Sendable {
    private let fileRepository: FileRepository
    private let messageRepository: MessageRepository

    init(fileRepository: FileRepository, messageRepository: MessageRepository) {
        self.fileRepository = fileRepository
        self.messageRepository = messageRepository
    }

    func execute(data: Data, fileName: String, mimeType: String, to jid: String) async throws -> Message {
        let slot = try await fileRepository.requestUploadSlot(fileName: fileName, fileSize: data.count, mimeType: mimeType)
        let url = try await fileRepository.uploadFile(data: data, slot: slot)
        let message = Message(
            conversationId: jid,
            senderJID: "",
            text: url.absoluteString,
            isOutgoing: true,
            status: .sent,
            type: .file
        )
        try await messageRepository.send(message: message)
        return message
    }
}
