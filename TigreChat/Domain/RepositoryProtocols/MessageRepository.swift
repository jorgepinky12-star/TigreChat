import Foundation

enum MessageError: Error, Sendable {
    case sendFailed(String)
    case notConnected
    case messageNotFound
}

@MainActor
protocol MessageRepository: Sendable {
    /// Envía un mensaje y devuelve si salió realmente cifrado (false si se
    /// degradó a texto plano porque OMEMO no pudo cifrar).
    @discardableResult
    func send(message: Message) async throws -> Bool
    func loadMessages(conversationId: String, before: Date?, limit: Int) async throws -> [Message]
    func loadConversations() async throws -> [Conversation]
    func markAsRead(conversationId: String) async throws
    /// XEP-0313: historial de una sala MUC (grupos). No incrementa no leídos.
    func syncGroupHistory(roomJID: String, limit: Int) async throws
    /// XEP-0424: retracta un mensaje propio en todos los dispositivos.
    func retract(messageID: String, conversationJID: String) async throws
    /// XEP-0384: activa/desactiva el cifrado OMEMO de una conversación.
    func setOMEMOEnabled(_ enabled: Bool, forConversation jid: String) async throws
}
