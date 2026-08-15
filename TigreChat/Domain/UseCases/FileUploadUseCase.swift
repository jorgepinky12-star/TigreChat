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
        let attachment = FileAttachment(
            id: UUID().uuidString,
            url: url,
            mimeType: mimeType,
            size: data.count,
            fileName: fileName
        )
        let message = Message(
            conversationId: jid,
            senderJID: "",
            text: url.absoluteString,
            isOutgoing: true,
            status: .sent,
            type: attachment.isImage ? .image : (attachment.isAudio ? .audio : .file),
            attachment: attachment
        )
        try await messageRepository.send(message: message)
        return message
    }
}
