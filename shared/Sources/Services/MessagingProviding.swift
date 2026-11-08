@preconcurrency import FirebaseFirestore
import Foundation

enum MessagingError: LocalizedError {
    case missingConversation
    case conflictingMessage

    var errorDescription: String? {
        switch self {
        case .missingConversation:
            "The shared conversation is not ready yet."
        case .conflictingMessage:
            "This queued message conflicts with an existing message and could not be retried."
        }
    }
}

struct MessageReceiptPosition: Equatable, Sendable {
    let messageID: String
    let seconds: Int64
    let nanoseconds: Int32

    init(
        messageID: String,
        seconds: Int64,
        nanoseconds: Int32
    ) {
        self.messageID = messageID
        self.seconds = seconds
        self.nanoseconds = nanoseconds
    }

    init(messageID: String, timestamp: Timestamp) {
        self.init(
            messageID: messageID,
            seconds: timestamp.seconds,
            nanoseconds: timestamp.nanoseconds
        )
    }
}

enum MessageReceiptAdvancePolicy {
    static func shouldAdvance(
        from current: MessageReceiptPosition?,
        to candidate: MessageReceiptPosition
    ) -> Bool {
        guard let current else { return true }
        if candidate.seconds != current.seconds {
            return candidate.seconds > current.seconds
        }
        if candidate.nanoseconds != current.nanoseconds {
            return candidate.nanoseconds > current.nanoseconds
        }

        // Firestore implicitly uses document ID to break equal order-by values.
        return candidate.messageID > current.messageID
    }
}

struct MessageHistorySnapshot {
    let messages: [ChatMessage]
    let isFromCache: Bool
    var replyMessages: [UUID: ChatMessage] = [:]
    var reactionsAreFromCache: Bool = false
}

@MainActor
protocol MessagingProviding: AnyObject {
    /// Newest pin first; IDs are routing metadata only, never copied message contents.
    func observeMessagePins(conversationID: String, currentUserID: String,
                            onChange: @escaping (Result<[UUID], Error>) -> Void) -> ServiceObservation
    func setMessagePinned(_ pinned: Bool, conversationID: String, messageID: UUID,
                          currentUserID: String) async throws
    /// A live bounded page, independent of the conversation's visible history window.
    func observeMessagesByID(conversationID: String, currentUserID: String, messageIDs: [UUID],
                             onChange: @escaping (Result<MessageHistorySnapshot, Error>) -> Void) -> ServiceObservation

    func observeMessages(
        conversationID: String,
        currentUserID: String,
        onChange: @escaping (Result<[ChatMessage], any Error>) -> Void
    ) -> ServiceObservation

    func observeMessages(
        conversationID: String,
        currentUserID: String,
        messageLimit: Int?,
        onChange: @escaping (Result<[ChatMessage], any Error>) -> Void
    ) -> ServiceObservation

    func observeMessageHistory(
        conversationID: String,
        currentUserID: String,
        messageLimit: Int?,
        onChange: @escaping (Result<MessageHistorySnapshot, any Error>) -> Void
    ) -> ServiceObservation

    func send(
        _ message: ChatMessage,
        conversationID: String
    ) async throws -> ChatMessage

    func editMessage(
        conversationID: String,
        messageID: String,
        body: String
    ) async throws

    func unsendMessage(
        conversationID: String,
        messageID: String
    ) async throws

    func setReaction(
        conversationID: String,
        messageID: String,
        userID: String,
        emoji: String?
    ) async throws

    func observeTyping(
        conversationID: String,
        currentUserID: String,
        onChange: @escaping (Result<Bool, any Error>) -> Void
    ) -> ServiceObservation

    func setTyping(
        conversationID: String,
        userID: String,
        isTyping: Bool
    ) async throws

    func markDelivered(
        conversationID: String,
        userID: String,
        messageID: String
    ) async throws

    func markRead(
        conversationID: String,
        userID: String,
        messageID: String
    ) async throws

    // Queuing providers must invoke this synchronous hook after admission, at SDK dispatch.
    func markDelivered(conversationID: String, userID: String, messageID: String,
                       beforeDispatch: @MainActor () throws -> Void) async throws
    func markRead(conversationID: String, userID: String, messageID: String,
                  beforeDispatch: @MainActor () throws -> Void) async throws
}

extension MessagingProviding {
    // Compatibility for immediate providers. Providers adding a queue must override these.
    func markDelivered(conversationID: String, userID: String, messageID: String,
                       beforeDispatch: @MainActor () throws -> Void) async throws {
        try Task.checkCancellation()
        try beforeDispatch()
        try await markDelivered(conversationID: conversationID, userID: userID, messageID: messageID)
    }
    func markRead(conversationID: String, userID: String, messageID: String,
                  beforeDispatch: @MainActor () throws -> Void) async throws {
        try Task.checkCancellation()
        try beforeDispatch()
        try await markRead(conversationID: conversationID, userID: userID, messageID: messageID)
    }

    func observeMessageHistory(
        conversationID: String,
        currentUserID: String,
        messageLimit: Int?,
        onChange: @escaping (Result<MessageHistorySnapshot, any Error>) -> Void
    ) -> ServiceObservation {
        observeMessages(
            conversationID: conversationID,
            currentUserID: currentUserID,
            messageLimit: messageLimit
        ) { result in
            onChange(result.map {
                MessageHistorySnapshot(messages: $0, isFromCache: false)
            })
        }
    }

    func observeMessages(
        conversationID: String,
        currentUserID: String,
        messageLimit: Int?,
        onChange: @escaping (Result<[ChatMessage], any Error>) -> Void
    ) -> ServiceObservation {
        observeMessages(
            conversationID: conversationID,
            currentUserID: currentUserID,
            onChange: onChange
        )
    }
}

enum ConversationHistoryPolicy {
    static let pageSize = 100
}

@MainActor
final class LocalMessagingService: MessagingProviding {
    func observeMessages(
        conversationID: String,
        currentUserID: String,
        onChange: @escaping (Result<[ChatMessage], any Error>) -> Void
    ) -> ServiceObservation {
        ServiceObservation()
    }

    func send(
        _ message: ChatMessage,
        conversationID: String
    ) async throws -> ChatMessage {
        try await Task.sleep(for: .milliseconds(250))
        var sent = message
        sent.deliveryState = .sent
        return sent
    }

    func editMessage(
        conversationID: String,
        messageID: String,
        body: String
    ) async throws {}

    func unsendMessage(
        conversationID: String,
        messageID: String
    ) async throws {}

    func setReaction(
        conversationID: String,
        messageID: String,
        userID: String,
        emoji: String?
    ) async throws {}

    func observeTyping(
        conversationID: String,
        currentUserID: String,
        onChange: @escaping (Result<Bool, any Error>) -> Void
    ) -> ServiceObservation {
        ServiceObservation()
    }

    func setTyping(
        conversationID: String,
        userID: String,
        isTyping: Bool
    ) async throws {}

    func markDelivered(
        conversationID: String,
        userID: String,
        messageID: String
    ) async throws {}

    func markRead(
        conversationID: String,
        userID: String,
        messageID: String
    ) async throws {}
}

@MainActor
final class FirestoreMessagingService: MessagingProviding {
    private let database: Firestore
    private let receiptCommands = ReceiptCommandLane()

    init(database: Firestore = Firestore.firestore()) {
        self.database = database
    }

    func observeMessagePins(conversationID: String, currentUserID: String,
                            onChange: @escaping (Result<[UUID], Error>) -> Void) -> ServiceObservation {
        FirestoreMessagePins.observe(database: database, conversationID: conversationID, onChange: onChange)
    }

    func setMessagePinned(_ pinned: Bool, conversationID: String, messageID: UUID,
                          currentUserID: String) async throws {
        try await FirestoreMessagePins.set(pinned, database: database, conversationID: conversationID,
                                           messageID: messageID, currentUserID: currentUserID)
    }

    func observeMessagesByID(conversationID: String, currentUserID: String, messageIDs: [UUID],
                             onChange: @escaping (Result<MessageHistorySnapshot, Error>) -> Void) -> ServiceObservation {
        guard !messageIDs.isEmpty, messageIDs.count <= MessagePinningPolicy.pageSize,
              Set(messageIDs).count == messageIDs.count else {
            onChange(.failure(MessagePinningError.invalidPage)); return ServiceObservation()
        }
        return observeHistory(conversationID: conversationID, currentUserID: currentUserID,
            query: messageCollection(conversationID).whereField(FieldPath.documentID(), in: messageIDs.map(\.uuidString)),
            bounded: true, onChange: onChange)
    }

    func observeMessages(
        conversationID: String,
        currentUserID: String,
        onChange: @escaping (Result<[ChatMessage], any Error>) -> Void
    ) -> ServiceObservation {
        observeMessages(
            conversationID: conversationID,
            currentUserID: currentUserID,
            messageLimit: nil,
            onChange: onChange
        )
    }

    func observeMessages(
        conversationID: String,
        currentUserID: String,
        messageLimit: Int?,
        onChange: @escaping (Result<[ChatMessage], any Error>) -> Void
    ) -> ServiceObservation {
        observeMessageHistory(
            conversationID: conversationID,
            currentUserID: currentUserID,
            messageLimit: messageLimit
        ) { result in
            onChange(result.map(\.messages))
        }
    }

    func observeMessageHistory(
        conversationID: String,
        currentUserID: String,
        messageLimit: Int?,
        onChange: @escaping (Result<MessageHistorySnapshot, any Error>) -> Void
    ) -> ServiceObservation {
        var query: Query = messageCollection(conversationID).order(by: "createdAt")
        if let messageLimit { query = query.limit(toLast: max(1, messageLimit)) }
        return observeHistory(conversationID: conversationID, currentUserID: currentUserID,
                              query: query, bounded: messageLimit != nil, onChange: onChange)
    }

    private func observeHistory(conversationID: String, currentUserID: String, query: Query,
                                bounded: Bool,
                                onChange: @escaping (Result<MessageHistorySnapshot, Error>) -> Void) -> ServiceObservation {
        let state = FirestoreConversationObservation(
            currentUserID: currentUserID,
            onChange: onChange
        )
        let metadata = FirestoreMessageMetadataObservation(
            conversation: database.collection("conversations")
                .document(conversationID),
            bounded: bounded,
            onPending: { state.waitForReactions() },
            onAttachments: { state.update(attachments: $0) },
            onReactions: {
                state.update(reactions: $0, isFromCache: $1)
            },
            onError: { state.fail($0) }
        )
        let replies = FirestoreReplyContextObservation(
            collection: messageCollection(conversationID),
            decode: { Self.message(from: $0, currentUserID: currentUserID) },
            onChange: { state.update(replyMessages: $0) },
            onError: { state.fail($0) }
        )
        var decodedMessages: [String: ChatMessage] = [:]
        let messageRegistration = query
            .addSnapshotListener(includeMetadataChanges: true) {
                snapshot, error in
                Task { @MainActor in
                    guard !state.isCancelled else { return }
                    if let error {
                        state.fail(error)
                        return
                    }
                    guard let snapshot else { return }
                    // A metadata-only acknowledgement should not decode the
                    // entire history again. Include it for pending send state.
                    for change in snapshot.documentChanges(includeMetadataChanges: true) {
                        let id = change.document.documentID
                        if change.type == .removed {
                            decodedMessages[id] = nil
                        } else {
                            decodedMessages[id] = Self.message(
                                from: change.document,
                                currentUserID: currentUserID
                            )
                        }
                    }
                    let messages = snapshot.documents.compactMap {
                        decodedMessages[$0.documentID]
                    }
                    replies.update(messages: messages)
                    metadata.update(messageIDs: snapshot.documents.map(\.documentID))
                    state.update(
                        messages: messages,
                        isFromCache: snapshot.metadata.isFromCache
                    )
                }
            }

        let receiptRegistration = database
            .collection("conversations")
            .document(conversationID)
            .collection("readStates")
            .addSnapshotListener { snapshot, error in
                Task { @MainActor in
                    guard !state.isCancelled else { return }
                    if let error {
                        state.fail(error)
                        return
                    }
                    let receipts = snapshot?.documents.reduce(
                        into: [String: MessageReceipt]()
                    ) { result, document in
                        let data = document.data()
                        result[document.documentID] = MessageReceipt(
                            lastDeliveredMessageID: data["lastDeliveredMessageId"] as? String,
                            lastReadMessageID: data["lastReadMessageId"] as? String
                        )
                    } ?? [:]
                    state.update(receipts: receipts)
                }
            }

        return ServiceObservation {
            state.cancel()
            messageRegistration.remove()
            metadata.cancel()
            replies.cancel()
            receiptRegistration.remove()
        }
    }

    func send(
        _ message: ChatMessage,
        conversationID: String
    ) async throws -> ChatMessage {
        try LegacyContentWriteGuard.require(conversationID: conversationID, accountID: message.senderID)
        let firestoreType = firestoreType(for: message)
        var payload: [String: Any] = [
            "senderId": message.senderID,
            "clientId": message.id.uuidString,
            "type": firestoreType,
            "createdAt": FieldValue.serverTimestamp(),
        ]

        if !message.body.isEmpty {
            payload["text"] = message.body
        }
        if let replyToID = message.replyToID {
            payload["replyToId"] = replyToID.uuidString
        }
        if let delivery = message.resolvedDeliveryMode.storedValue {
            payload["delivery"] = delivery
        }
        if
            let groupID = message.attachmentGroupID,
            let groupIndex = message.attachmentGroupIndex,
            let groupCount = message.attachmentGroupCount
        {
            payload["attachmentGroupId"] = groupID.uuidString
            payload["attachmentGroupIndex"] = groupIndex
            payload["attachmentGroupCount"] = groupCount
        }

        let document = messageCollection(conversationID)
            .document(message.id.uuidString)
        do {
            try await document.setData(payload)
        } catch let writeError {
            // The write may have committed even when the client never received
            // its acknowledgement. This happens if the process is killed
            // between the Firestore commit and removing a durable Share/voice
            // item from the local outbox. Retrying the create is then rejected
            // by the immutable-message rules, so reconcile against a
            // server-confirmed document before reporting failure.
            let existing: DocumentSnapshot
            do {
                existing = try await document.getDocument(source: .server)
            } catch {
                throw writeError
            }

            guard existing.exists else {
                throw writeError
            }
            guard ExistingMessageReplayPolicy.matches(
                existing.data() ?? [:],
                attemptedMessage: message,
                firestoreType: firestoreType
            ) else {
                throw MessagingError.conflictingMessage
            }
        }

        var sent = message
        sent.deliveryState = .sent
        return sent
    }

    func editMessage(
        conversationID: String,
        messageID: String,
        body: String
    ) async throws {
        try LegacyContentWriteGuard.require(conversationID: conversationID)
        try await messageCollection(conversationID)
            .document(messageID)
            .updateData([
                "text": body,
                "type": MessageKind.forText(body).rawValue,
                "editedAt": FieldValue.serverTimestamp(),
            ])
    }

    func unsendMessage(
        conversationID: String,
        messageID: String
    ) async throws {
        try LegacyContentWriteGuard.require(conversationID: conversationID)
        try await messageCollection(conversationID)
            .document(messageID)
            .updateData([
                "text": "",
                "deletedAt": FieldValue.serverTimestamp(),
            ])
    }

    func setReaction(
        conversationID: String,
        messageID: String,
        userID: String,
        emoji: String?
    ) async throws {
        try LegacyContentWriteGuard.require(conversationID: conversationID, accountID: userID)
        let document = database
            .collection("conversations")
            .document(conversationID)
            .collection("reactions")
            .document("\(messageID)--\(userID)")

        if let emoji {
            try await document.setData([
                "messageId": messageID,
                "userId": userID,
                "emoji": emoji,
                "updatedAt": FieldValue.serverTimestamp(),
            ])
        } else {
            try await document.delete()
        }
    }

    func observeTyping(
        conversationID: String,
        currentUserID: String,
        onChange: @escaping (Result<Bool, any Error>) -> Void
    ) -> ServiceObservation {
        let state = FirestoreTypingObservation(onChange: onChange)
        let registration = database
            .collection("conversations")
            .document(conversationID)
            .collection("typing")
            .addSnapshotListener { snapshot, error in
                Task { @MainActor in
                    if let error {
                        onChange(.failure(error))
                        return
                    }

                    let activeUntil = snapshot?.documents.compactMap { document in
                        guard document.documentID != currentUserID else {
                            return nil
                        }
                        let data = document.data()
                        guard data["isTyping"] as? Bool == true else {
                            return nil
                        }
                        return (data["expiresAt"] as? Timestamp)?.dateValue()
                    }
                    .filter { $0 > .now }
                    .max()
                    state.update(activeUntil: activeUntil)
                }
            }

        return ServiceObservation {
            registration.remove()
            state.cancel()
        }
    }

    func setTyping(
        conversationID: String,
        userID: String,
        isTyping: Bool
    ) async throws {
        let document = database
            .collection("conversations")
            .document(conversationID)
            .collection("typing")
            .document(userID)

        if isTyping {
            try await document.setData([
                "userId": userID,
                "isTyping": true,
                "updatedAt": FieldValue.serverTimestamp(),
                "expiresAt": Timestamp(
                    date: .now.addingTimeInterval(Self.typingLifetime)
                ),
            ])
        } else {
            try await document.delete()
        }
    }

    func markDelivered(
        conversationID: String,
        userID: String,
        messageID: String
    ) async throws {
        try await markDelivered(conversationID: conversationID, userID: userID, messageID: messageID, beforeDispatch: {})
    }

    func markDelivered(conversationID: String, userID: String, messageID: String,
                       beforeDispatch: @MainActor () throws -> Void) async throws {
        try await receiptCommands.perform(conversationID: conversationID, userID: userID) {
            try beforeDispatch()
            try await Self.advanceReceipt(
                database: self.database,
                conversationID: conversationID,
                userID: userID,
                messageID: messageID,
                field: .delivered
            )
        }
    }

    func markRead(
        conversationID: String,
        userID: String,
        messageID: String
    ) async throws {
        try await markRead(conversationID: conversationID, userID: userID, messageID: messageID, beforeDispatch: {})
    }

    func markRead(conversationID: String, userID: String, messageID: String,
                  beforeDispatch: @MainActor () throws -> Void) async throws {
        try await receiptCommands.perform(conversationID: conversationID, userID: userID) {
            try beforeDispatch()
            try await Self.advanceReceipt(
                database: self.database,
                conversationID: conversationID,
                userID: userID,
                messageID: messageID,
                field: .read
            )
        }
    }

    private static let typingLifetime: TimeInterval = 12

    private enum ReceiptField: Sendable {
        case delivered
        case read

        var messageID: String {
            switch self {
            case .delivered:
                "lastDeliveredMessageId"
            case .read:
                "lastReadMessageId"
            }
        }

        var timestamp: String {
            switch self {
            case .delivered:
                "lastDeliveredAt"
            case .read:
                "lastReadAt"
            }
        }
    }

    nonisolated private static func advanceReceipt(
        database: Firestore,
        conversationID: String,
        userID: String,
        messageID: String,
        field: ReceiptField
    ) async throws {
        let conversation = database
            .collection("conversations")
            .document(conversationID)
        let messages = conversation.collection("messages")
        let candidateDocument = messages.document(messageID)
        let receipt = conversation.collection("readStates").document(userID)

        _ = try await database.runTransaction { transaction, errorPointer in
            do {
                let candidateSnapshot = try transaction.getDocument(
                    candidateDocument
                )
                guard
                    candidateSnapshot.exists,
                    let candidateTimestamp =
                        candidateSnapshot.data()?["createdAt"] as? Timestamp
                else {
                    throw ReceiptAdvanceError.messageUnavailable
                }
                let candidate = MessageReceiptPosition(
                    messageID: messageID,
                    timestamp: candidateTimestamp
                )

                let receiptSnapshot = try transaction.getDocument(receipt)
                let currentMessageID =
                    receiptSnapshot.data()?[field.messageID] as? String
                let current: MessageReceiptPosition?
                if
                    let currentMessageID,
                    currentMessageID != messageID
                {
                    let currentSnapshot = try transaction.getDocument(
                        messages.document(currentMessageID)
                    )
                    if
                        currentSnapshot.exists,
                        let currentTimestamp =
                            currentSnapshot.data()?["createdAt"] as? Timestamp
                    {
                        current = MessageReceiptPosition(
                            messageID: currentMessageID,
                            timestamp: currentTimestamp
                        )
                    } else {
                        current = nil
                    }
                } else if currentMessageID == messageID {
                    current = candidate
                } else {
                    current = nil
                }

                guard MessageReceiptAdvancePolicy.shouldAdvance(
                    from: current,
                    to: candidate
                ) else {
                    return false
                }

                transaction.setData(
                    [
                        "userId": userID,
                        field.messageID: messageID,
                        field.timestamp: FieldValue.serverTimestamp(),
                    ],
                    forDocument: receipt,
                    merge: true
                )
                return true
            } catch let error as NSError {
                errorPointer?.pointee = error
                return nil
            }
        }
    }

    private func messageCollection(_ conversationID: String) -> CollectionReference {
        database
            .collection("conversations")
            .document(conversationID)
            .collection("messages")
    }

    private func firestoreType(for message: ChatMessage) -> String {
        switch message.kind {
        case .text:
            return MessageKind.forText(message.body).rawValue
        case .link:
            return "link"
        case .attachment:
            switch message.attachment?.type {
            case .image:
                return "image"
            case .video:
                return "video"
            default:
                return "file"
            }
        case .voice:
            return "audio"
        case .liveLocation:
            return "location"
        }
    }

    private static func message(
        from document: QueryDocumentSnapshot,
        currentUserID: String
    ) -> ChatMessage? {
        let data = document.data()
        guard
            let senderID = data["senderId"] as? String,
            let identifier = UUID(uuidString: document.documentID)
                ?? (data["clientId"] as? String).flatMap(UUID.init(uuidString:))
        else {
            return nil
        }

        let type = data["type"] as? String ?? "text"
        let body: String
        if data["deletedAt"] is Timestamp {
            body = "Message unsent"
        } else {
            body = data["text"] as? String ?? ""
        }

        return ChatMessage(
            id: identifier,
            senderID: senderID,
            kind: messageKind(for: type),
            body: body,
            createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? .now,
            editedAt: (data["editedAt"] as? Timestamp)?.dateValue(),
            deletedAt: (data["deletedAt"] as? Timestamp)?.dateValue(),
            deliveryState: senderID == currentUserID
                ? (document.metadata.hasPendingWrites ? .sending : .sent)
                : .delivered,
            replyToID: (data["replyToId"] as? String)
                .flatMap(UUID.init(uuidString:)),
            attachment: MessageAttachmentHydration.provisionalContent(
                messageID: identifier,
                firestoreType: type
            ),
            attachmentGroupID: (data["attachmentGroupId"] as? String)
                .flatMap(UUID.init(uuidString:)),
            attachmentGroupIndex:
                (data["attachmentGroupIndex"] as? NSNumber)?.intValue,
            attachmentGroupCount:
                (data["attachmentGroupCount"] as? NSNumber)?.intValue,
            deliveryMode: MessageDeliveryMode(
                storedValue: data["delivery"]
            ).storedValue == nil ? nil : .quiet
        )
    }

    private static func messageKind(for firestoreType: String) -> MessageKind {
        switch firestoreType {
        case "link":
            return .link
        case "image", "video", "file":
            return .attachment
        case "audio":
            return .voice
        case "location":
            return .liveLocation
        default:
            return .text
        }
    }

}

private enum ReceiptAdvanceError: LocalizedError {
    case messageUnavailable

    var errorDescription: String? {
        "The message is not available for a receipt."
    }
}

enum ExistingMessageReplayPolicy {
    static func matches(
        _ existing: [String: Any],
        attemptedMessage: ChatMessage,
        firestoreType: String
    ) -> Bool {
        guard
            existing["senderId"] as? String == attemptedMessage.senderID,
            existing["clientId"] as? String
                == attemptedMessage.id.uuidString
        else {
            return false
        }

        // Once the logical message has been edited or unsent, its current
        // content should win over the stale outbox payload. The immutable
        // sender/client identity still proves it is the same message.
        if existing["editedAt"] != nil || existing["deletedAt"] != nil {
            return true
        }

        let expectedText = attemptedMessage.body.isEmpty
            ? nil
            : attemptedMessage.body
        let existingGroupID = existing["attachmentGroupId"] as? String
        let existingGroupIndex =
            (existing["attachmentGroupIndex"] as? NSNumber)?.intValue
        let existingGroupCount =
            (existing["attachmentGroupCount"] as? NSNumber)?.intValue
        let existingDelivery = MessageDeliveryMode(
            storedValue: existing["delivery"]
        )
        return existing["type"] as? String == firestoreType
            && existing["text"] as? String == expectedText
            && existing["replyToId"] as? String
                == attemptedMessage.replyToID?.uuidString
            && existingGroupID
                == attemptedMessage.attachmentGroupID?.uuidString
            && existingGroupIndex
                == attemptedMessage.attachmentGroupIndex
            && existingGroupCount
                == attemptedMessage.attachmentGroupCount
            && existingDelivery == attemptedMessage.resolvedDeliveryMode
    }
}

@MainActor
private final class FirestoreConversationObservation {
    private var messages: [ChatMessage] = []
    private var replyMessages: [UUID: ChatMessage] = [:]
    private var attachments: [String: AttachmentContent] = [:]
    private var reactions: [String: [String: String]] = [:]
    private var receipts: [String: MessageReceipt] = [:]
    private(set) var isCancelled = false
    private var messagesAreFromCache = true
    private var reactionsAreFromCache = true
    private var hasReceivedMessages = false
    private var hasReceivedReactions = false
    private var hydrationGeneration = 0
    private var hydrationTask: Task<[ChatMessage]?, Never>?
    private let currentUserID: String
    private let onChange: (Result<MessageHistorySnapshot, any Error>) -> Void

    init(
        currentUserID: String,
        onChange: @escaping (Result<MessageHistorySnapshot, any Error>) -> Void
    ) {
        self.currentUserID = currentUserID
        self.onChange = onChange
    }

    func update(messages: [ChatMessage], isFromCache: Bool) {
        guard !hasReceivedMessages || self.messages != messages
            || messagesAreFromCache != isFromCache else { return }
        self.messages = messages
        messagesAreFromCache = isFromCache
        hasReceivedMessages = true
        emit()
    }

    func update(attachments: [String: AttachmentContent]) {
        guard self.attachments != attachments else { return }
        self.attachments = attachments
        emit()
    }

    func update(reactions: [String: [String: String]], isFromCache: Bool) {
        guard !hasReceivedReactions || self.reactions != reactions
            || reactionsAreFromCache != isFromCache else { return }
        self.reactions = reactions
        reactionsAreFromCache = isFromCache
        hasReceivedReactions = true
        emit()
    }

    func update(receipts: [String: MessageReceipt]) {
        guard self.receipts != receipts else { return }
        self.receipts = receipts
        emit()
    }

    func update(replyMessages: [UUID: ChatMessage]) {
        guard self.replyMessages != replyMessages else { return }
        self.replyMessages = replyMessages
        emit()
    }

    func waitForReactions() {
        hasReceivedReactions = false
        hydrationGeneration += 1
        hydrationTask?.cancel()
    }

    func fail(_ error: any Error) {
        guard !isCancelled else { return }
        onChange(.failure(error))
    }

    func cancel() {
        isCancelled = true
        hydrationGeneration += 1
        hydrationTask?.cancel()
    }

    private func emit() {
        guard !isCancelled, hasReceivedMessages, hasReceivedReactions else { return }
        hydrationGeneration += 1
        let generation = hydrationGeneration
        hydrationTask?.cancel()

        let messages = messages
        let isFromCache = messagesAreFromCache
        let reactionsAreFromCache = reactionsAreFromCache
        let replyMessages = replyMessages
        let attachments = attachments
        let reactions = reactions
        let receipts = receipts
        let currentUserID = currentUserID
        let task = Task.detached(priority: .userInitiated) {
            FirestoreMessageHydration.hydrate(
                messages: messages,
                attachments: attachments,
                reactions: reactions,
                receipts: receipts,
                currentUserID: currentUserID
            )
        }
        hydrationTask = task

        Task { @MainActor [weak self] in
            guard
                let hydrated = await task.value,
                !task.isCancelled,
                let self,
                self.hydrationGeneration == generation
            else {
                return
            }
            self.onChange(.success(MessageHistorySnapshot(
                messages: hydrated,
                isFromCache: isFromCache,
                replyMessages: replyMessages,
                reactionsAreFromCache: reactionsAreFromCache
            )))
        }
    }
}

enum FirestoreMessageHydration {
    static func hydrate(
        messages: [ChatMessage],
        attachments: [String: AttachmentContent],
        reactions: [String: [String: String]],
        receipts: [String: MessageReceipt],
        currentUserID: String
    ) -> [ChatMessage]? {
        let partnerReceipt = receipts.first {
            $0.key != currentUserID
        }?.value
        let indexes = Dictionary(
            uniqueKeysWithValues: messages.enumerated().map {
                ($0.element.id.uuidString, $0.offset)
            }
        )
        var hydrated: [ChatMessage] = []
        hydrated.reserveCapacity(messages.count)

        for message in messages {
            guard !Task.isCancelled else { return nil }
            var updated = message
            if message.kind == .attachment || message.kind == .voice {
                updated.attachment = MessageAttachmentHydration.content(
                    for: message,
                    availableAttachments: attachments
                )
            }
            updated.reactions = reactions[message.id.uuidString] ?? [:]

            if
                message.senderID == currentUserID,
                message.deliveryState != .sending
            {
                updated.deliveryState = partnerReceipt?.deliveryState(
                    for: message.id.uuidString,
                    messageIndexes: indexes,
                    fallback: .sent
                ) ?? .sent
            }
            hydrated.append(updated)
        }
        return hydrated
    }
}

@MainActor
private final class FirestoreTypingObservation {
    private let onChange: (Result<Bool, any Error>) -> Void
    private var expirationTask: Task<Void, Never>?

    init(onChange: @escaping (Result<Bool, any Error>) -> Void) {
        self.onChange = onChange
    }

    func update(activeUntil: Date?) {
        expirationTask?.cancel()
        guard let activeUntil, activeUntil > .now else {
            onChange(.success(false))
            return
        }

        onChange(.success(true))
        let delay = max(0, activeUntil.timeIntervalSinceNow)
        expirationTask = Task { [weak self] in
            try? await Task.sleep(
                for: .milliseconds(Int(delay * 1_000))
            )
            guard !Task.isCancelled else { return }
            self?.onChange(.success(false))
        }
    }

    func cancel() {
        expirationTask?.cancel()
        expirationTask = nil
    }
}
