import Foundation

/// Every operation resolves a service from the verified current conversation.
/// Keeping this facade stable lets existing model dependencies survive pairing,
/// account switches, key readiness changes, and conversation replacement.
@MainActor
final class EncryptedMessagingRouter: MessageHistoryWindowProviding {
    private let services: EncryptedAppServices
    init(_ services: EncryptedAppServices) { self.services = services }
    func observeMessagePins(conversationID: String, currentUserID: String,
                            onChange: @escaping (Result<[UUID], Error>) -> Void) -> ServiceObservation {
        do { return try services.messaging(for: conversationID).observeMessagePins(
            conversationID: conversationID, currentUserID: currentUserID, onChange: onChange)
        } catch { onChange(.failure(error)); return ServiceObservation() }
    }
    func setMessagePinned(_ pinned: Bool, conversationID: String, messageID: UUID,
                          currentUserID: String) async throws {
        try await services.messaging(for: conversationID).setMessagePinned(pinned,
            conversationID: conversationID, messageID: messageID, currentUserID: currentUserID)
    }
    func observeMessagesByID(conversationID: String, currentUserID: String, messageIDs: [UUID],
                             onChange: @escaping (Result<MessageHistorySnapshot, Error>) -> Void) -> ServiceObservation {
        do { return try services.messaging(for: conversationID).observeMessagesByID(
            conversationID: conversationID, currentUserID: currentUserID, messageIDs: messageIDs, onChange: onChange)
        } catch { onChange(.failure(error)); return ServiceObservation() }
    }
    func observeMessages(conversationID: String, currentUserID: String,
        onChange: @escaping (Result<[ChatMessage], any Error>) -> Void) -> ServiceObservation {
        observeMessages(conversationID: conversationID, currentUserID: currentUserID, messageLimit: nil, onChange: onChange)
    }
    func observeMessages(conversationID: String, currentUserID: String, messageLimit: Int?,
        onChange: @escaping (Result<[ChatMessage], any Error>) -> Void) -> ServiceObservation {
        observeMessageHistory(conversationID: conversationID, currentUserID: currentUserID, messageLimit: messageLimit) {
            onChange($0.map(\.messages))
        }
    }
    func observeMessageHistory(conversationID: String, currentUserID: String, messageLimit: Int?,
        onChange: @escaping (Result<MessageHistorySnapshot, any Error>) -> Void) -> ServiceObservation {
        do { return try services.messaging(for: conversationID).observeMessageHistory(
            conversationID: conversationID, currentUserID: currentUserID, messageLimit: messageLimit, onChange: onChange)
        } catch { onChange(.failure(error)); return ServiceObservation() }
    }
    func supportsHistoryWindows(conversationID: String) throws -> Bool {
        let service = try services.messaging(for: conversationID)
        return try (service as? any MessageHistoryWindowProviding)?.supportsHistoryWindows(conversationID: conversationID) ?? false
    }
    func observeHistoryWindow(conversationID: String, currentUserID: String, request: MessageHistoryWindowRequest,
                              onChange: @escaping (Result<MessageHistoryWindowSnapshot, Error>) -> Void) -> ServiceObservation {
        do {
            guard let service = try services.messaging(for: conversationID) as? any MessageHistoryWindowProviding else { throw EncryptedMessagingError.historyLimit }
            return service.observeHistoryWindow(conversationID: conversationID, currentUserID: currentUserID, request: request, onChange: onChange)
        } catch { onChange(.failure(error)); return ServiceObservation() }
    }
    func searchHistory(conversationID: String, currentUserID: String, query: String, continuation: MessageHistorySearchContinuation?,
                       onChange: @escaping (Result<MessageHistorySearchSnapshot, Error>) -> Void) -> ServiceObservation {
        do {
            guard let service = try services.messaging(for: conversationID) as? any MessageHistoryWindowProviding else { throw EncryptedMessagingError.historyLimit }
            return service.searchHistory(conversationID: conversationID, currentUserID: currentUserID, query: query, continuation: continuation, onChange: onChange)
        } catch { onChange(.failure(error)); return ServiceObservation() }
    }
    func send(_ message: ChatMessage, conversationID: String) async throws -> ChatMessage {
        try await services.messaging(for: conversationID).send(message, conversationID: conversationID)
    }
    func editMessage(conversationID: String, messageID: String, body: String) async throws {
        try await services.messaging(for: conversationID).editMessage(conversationID: conversationID, messageID: messageID, body: body)
    }
    func unsendMessage(conversationID: String, messageID: String) async throws {
        try await services.messaging(for: conversationID).unsendMessage(conversationID: conversationID, messageID: messageID)
    }
    func setReaction(conversationID: String, messageID: String, userID: String, emoji: String?) async throws {
        try await services.messaging(for: conversationID).setReaction(conversationID: conversationID, messageID: messageID, userID: userID, emoji: emoji)
    }
    func observeTyping(conversationID: String, currentUserID: String,
        onChange: @escaping (Result<Bool, any Error>) -> Void) -> ServiceObservation {
        do { return try services.messaging(for: conversationID).observeTyping(
            conversationID: conversationID, currentUserID: currentUserID, onChange: onChange)
        } catch { onChange(.failure(error)); return ServiceObservation() }
    }
    func setTyping(conversationID: String, userID: String, isTyping: Bool) async throws {
        try await services.messaging(for: conversationID).setTyping(conversationID: conversationID, userID: userID, isTyping: isTyping)
    }
    func markDelivered(conversationID: String, userID: String, messageID: String) async throws {
        try await services.messaging(for: conversationID).markDelivered(conversationID: conversationID, userID: userID, messageID: messageID)
    }
    func markRead(conversationID: String, userID: String, messageID: String) async throws {
        try await services.messaging(for: conversationID).markRead(conversationID: conversationID, userID: userID, messageID: messageID)
    }
}

@MainActor
final class EncryptedAttachmentRouter: AttachmentProviding {
    private let services: EncryptedAppServices
    init(_ services: EncryptedAppServices) { self.services = services }
    func upload(_ share: PendingShare, messageID: UUID, conversationID: String, ownerID: String) async throws -> AttachmentContent {
        try await services.attachments(for: conversationID).upload(share, messageID: messageID,
            conversationID: conversationID, ownerID: ownerID)
    }
}

#if os(iOS)
@MainActor
final class EncryptedLocationRouter: ConnectionLocationProviding {
    private let services: EncryptedAppServices
    private let legacy: any ConnectionLocationProviding
    init(_ services: EncryptedAppServices, legacy: any ConnectionLocationProviding) {
        self.services = services; self.legacy = legacy
    }
    var requiresDeviceLocation: Bool { true }
    private func provider(_ conversationID: String) throws -> any ConnectionLocationProviding {
        _ = try services.messaging(for: conversationID)
        if let locations = services.locations { return locations }
        return legacy
    }
    func observe(conversationID: String, onChange: @escaping (Result<ConnectionLocationSnapshot, any Error>) -> Void) -> ServiceObservation {
        do { return try provider(conversationID).observe(conversationID: conversationID, onChange: onChange) }
        catch { onChange(.failure(error)); return ServiceObservation() }
    }
    func setSharingEnabled(_ isEnabled: Bool, conversationID: String, userID: String) async throws {
        try await provider(conversationID).setSharingEnabled(isEnabled, conversationID: conversationID, userID: userID)
    }
}
#endif
