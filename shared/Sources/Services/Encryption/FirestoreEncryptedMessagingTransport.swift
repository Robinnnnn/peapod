@preconcurrency import FirebaseFirestore
import CoreFoundation
import Foundation
import MinesE2EE

@MainActor
final class FirestoreEncryptedMessagingTransport: EncryptedMessagingTransport {
    typealias AttachmentUploader = @MainActor (RecordContext, String, Data) async throws -> Void
    private let database: Firestore
    private let session: SecureConversationSession
    private let uploadAttachment: AttachmentUploader?
    init(session: SecureConversationSession, database: Firestore = Firestore.firestore(), uploadAttachment: AttachmentUploader? = nil) {
        self.session = session; self.database = database; self.uploadAttachment = uploadAttachment
    }
    private func conversation(_ id: String) -> DocumentReference { database.collection("conversations").document(id) }

    func message(conversationID: String, recordID: String) async throws -> EncryptedMessageRecord? {
        try session.requireActive(conversationID: conversationID)
        let document = try await conversation(conversationID).collection("messages").document(recordID).getDocument(source: .server)
        try session.requireActive()
        guard document.exists else { return nil }
        let record = try Self.messageRecord(id: recordID, data: document.data(with: .estimate) ?? [:], conversationID: conversationID,
                                            pending: document.metadata.hasPendingWrites)
        try session.validate(record.context); return record
    }
    func reaction(conversationID: String, recordID: String) async throws -> EncryptedReactionRecord? {
        try session.requireActive(conversationID: conversationID)
        let document = try await conversation(conversationID).collection("reactions").document(recordID).getDocument(source: .server)
        try session.requireActive()
        guard document.exists else { return nil }
        let record = try Self.reactionRecord(id: recordID, data: document.data() ?? [:], conversationID: conversationID)
        try session.validate(record.context); return record
    }

    func publish(_ pending: PendingOutboxRecord, deliveryMode: ContentDeliveryMode) async throws -> EncryptedMessageRecord {
        switch try await publishPrepared(pending, deliveryMode: deliveryMode) {
        case .published(let record): return record
        case .revisionRejected: throw EncryptedMessagingError.conflictingRecord
        }
    }
    func publishPrepared(_ pending: PendingOutboxRecord, deliveryMode: ContentDeliveryMode) async throws -> EncryptedMessagePublishOutcome {
        try session.validate(pending.context)
        guard pending.context.kind == .message, SecureConversationSession.same(pending.context.senderID, session.capsule.localAccountID) else { throw EncryptedMessagingError.untrustedConversation }
        for attachment in pending.attachments {
            guard let uploadAttachment else { throw EncryptedMessagingError.missingAttachment }
            try session.requireActive()
            try await uploadAttachment(pending.context, attachment.attachmentID, attachment.bytes)
            try session.requireActive()
        }
        let context = pending.context; let bytes = pending.envelope
        // The durable message remains the identity of a retry. Prepare an optional preview
        // once outside the transaction callback, and never replace an existing create's
        // preview when those exact message bytes were already committed by an earlier try.
        let preview: Data?
        if context.revision == 1, deliveryMode != .quiet {
            preview = try await session.performKeyOperation { key in
                let payload = try ConversationMessageCipher.open(bytes, expectedContext: context, epochKey: key)
                return try NotificationPreviewCipher.seal(payload, context: context, epochKey: key)
            }
        } else { preview = nil }
        let quiet = deliveryMode == .quiet
        let reference = conversation(context.conversationID).collection("messages").document(context.recordID)
        let previewReference = conversation(context.conversationID).collection("notificationPreviews").document(context.recordID)
        try session.requireActive()
        let accepted = try await runPublishTransaction { @Sendable transaction, errorPointer in
            do {
                let existing = try transaction.getDocument(reference)
                if existing.exists {
                    let old = try Self.messageRecord(id: context.recordID, data: existing.data() ?? [:], conversationID: context.conversationID)
                    if old.context == context, old.ciphertext == bytes, old.deletedAt == nil { return true }
                    guard old.context.senderID.utf8.elementsEqual(context.senderID.utf8), old.context.keyEpoch == context.keyEpoch else { throw EncryptedMessagingError.untrustedConversation }
                    guard old.deletedAt == nil, context.revision == old.context.revision + 1 else { return false }
                    transaction.updateData(["ciphertext": bytes, "revision": Int64(context.revision), "editedAt": FieldValue.serverTimestamp()], forDocument: reference)
                } else {
                    guard context.revision == 1 else { throw EncryptedMessagingError.conflictingRecord }
                    var payload: [String: Any] = ["senderId": context.senderID, "clientId": context.recordID, "type": "encrypted",
                                         "encryption": StoredConversationCapsule.contentSuite, "keyEpoch": Int64(context.keyEpoch),
                                         "revision": Int64(context.revision), "ciphertext": bytes,
                                         "createdAt": FieldValue.serverTimestamp()]
                    if quiet { payload["delivery"] = "quiet" }
                    transaction.setData(payload, forDocument: reference)
                    if let preview {
                        // A sidecar preserves the strict message schema understood by older
                        // encrypted clients. Its creation is atomic with this exact message.
                        transaction.setData(["senderId": context.senderID, "encryption": StoredConversationCapsule.contentSuite,
                            "keyEpoch": Int64(context.keyEpoch), "revision": Int64(context.revision), "ciphertext": preview],
                            forDocument: previewReference)
                    }
                }
                return true
            } catch { errorPointer?.pointee = error as NSError; return nil }
        }
        try session.requireActive()
        guard let record = try await message(conversationID: context.conversationID, recordID: context.recordID) else { throw EncryptedMessagingError.invalidRecord }
        if !accepted {
            guard !record.hasPendingWrites else { throw EncryptedMessagingError.conflictingRecord }
            return .revisionRejected(record)
        }
        // This write may have succeeded before a later competing edit. A changed post-commit
        // fetch is ambiguous for this intent: retain its exact bytes, never call it CAS rejection.
        guard record.context == context, record.ciphertext == bytes, record.deletedAt == nil else { throw EncryptedMessagingError.conflictingRecord }
        return .published(record)
    }
    func unsend(context: RecordContext) async throws {
        try session.validate(context)
        guard context.kind == .message, SecureConversationSession.same(context.senderID, session.capsule.localAccountID) else { throw EncryptedMessagingError.untrustedConversation }
        let reference = conversation(context.conversationID).collection("messages").document(context.recordID)
        let previewReference = conversation(context.conversationID).collection("notificationPreviews").document(context.recordID)
        try await runTransaction { @Sendable transaction, errorPointer in
            do {
                let existing = try transaction.getDocument(reference)
                guard existing.exists else { throw EncryptedMessagingError.invalidRecord }
                let old = try Self.messageRecord(id: context.recordID, data: existing.data() ?? [:], conversationID: context.conversationID)
                if old.context == context, old.deletedAt != nil, old.ciphertext.isEmpty { return true }
                guard old.deletedAt == nil, old.context.senderID.utf8.elementsEqual(context.senderID.utf8),
                      old.context.keyEpoch == context.keyEpoch, context.revision == old.context.revision + 1 else { throw EncryptedMessagingError.conflictingRecord }
                let preview = try transaction.getDocument(previewReference)
                transaction.updateData(["ciphertext": Data(), "revision": Int64(context.revision), "deletedAt": FieldValue.serverTimestamp()], forDocument: reference)
                if preview.exists { transaction.deleteDocument(previewReference) }
                return true
            } catch { errorPointer?.pointee = error as NSError; return nil }
        }
        try session.requireActive()
    }
    func publishReaction(_ record: EncryptedReactionRecord) async throws {
        try session.validate(record.context)
        guard record.context.kind == .reaction, record.context.senderID.utf8.elementsEqual(session.capsule.localAccountID.utf8),
              record.context.recordID == (try ReactionCipher.recordID(targetMessageID: record.targetMessageID, senderID: record.context.senderID)),
              !record.ciphertext.isEmpty, record.ciphertext.count <= 4096 else { throw EncryptedMessagingError.invalidRecord }
        let context = record.context; let bytes = record.ciphertext; let target = record.targetMessageID
        let reference = conversation(context.conversationID).collection("reactions").document(context.recordID)
        try await runTransaction { @Sendable transaction, errorPointer in
            do {
                let existing = try transaction.getDocument(reference)
                if existing.exists {
                    let old = try Self.reactionRecord(id: context.recordID, data: existing.data() ?? [:], conversationID: context.conversationID)
                    if old.context == context, old.ciphertext == bytes, old.targetMessageID.utf8.elementsEqual(target.utf8) { return true }
                    guard old.context.senderID.utf8.elementsEqual(context.senderID.utf8), old.context.keyEpoch == context.keyEpoch,
                          old.targetMessageID.utf8.elementsEqual(target.utf8), context.revision == old.context.revision + 1 else { throw EncryptedMessagingError.conflictingRecord }
                } else if context.revision != 1 { throw EncryptedMessagingError.conflictingRecord }
                transaction.setData(["messageId": target, "userId": context.senderID, "encryption": StoredConversationCapsule.contentSuite,
                                     "keyEpoch": Int64(context.keyEpoch), "revision": Int64(context.revision), "ciphertext": bytes,
                                     "updatedAt": FieldValue.serverTimestamp()], forDocument: reference)
                return true
            } catch { errorPointer?.pointee = error as NSError; return nil }
        }
        try session.requireActive()
    }

    private func runPublishTransaction(_ operation: @escaping @Sendable (Transaction, NSErrorPointer) -> Any?) async throws -> Bool {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            database.runTransaction(operation) { result, error in
                if let error { continuation.resume(throwing: error) }
                else if let accepted = result as? Bool { continuation.resume(returning: accepted) }
                else { continuation.resume(throwing: EncryptedMessagingError.invalidRecord) }
            }
        }
    }

    private func runTransaction(_ operation: @escaping @Sendable (Transaction, NSErrorPointer) -> Any?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            database.runTransaction(operation) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    func observeHistory(conversationID: String, limit: Int,
                        onChange: @escaping (Result<EncryptedHistoryRecords, Error>) -> Void) -> ServiceObservation {
        do { try session.requireActive(conversationID: conversationID) }
        catch { onChange(.failure(error)); return ServiceObservation() }
        guard (1...EncryptedMessagingService.maximumHistoryMessages).contains(limit) else { onChange(.failure(EncryptedMessagingError.historyLimit)); return ServiceObservation() }
        return observeRecords(conversationID: conversationID,
            query: conversation(conversationID).collection("messages").order(by: "createdAt").limit(toLast: limit),
            limit: limit, onChange: onChange)
    }

    func observeMessagesByID(conversationID: String, messageIDs: [String],
                             onChange: @escaping (Result<EncryptedHistoryRecords, Error>) -> Void) -> ServiceObservation {
        do {
            try session.requireActive(conversationID: conversationID)
            guard !messageIDs.isEmpty, messageIDs.count <= MessagePinningPolicy.pageSize,
                  Set(messageIDs).count == messageIDs.count else { throw MessagePinningError.invalidPage }
            for id in messageIDs { try Self.uuid(id) }
        } catch { onChange(.failure(error)); return ServiceObservation() }
        return observeRecords(conversationID: conversationID,
            query: conversation(conversationID).collection("messages").whereField(FieldPath.documentID(), in: messageIDs),
            limit: messageIDs.count, onChange: onChange)
    }

    private func observeRecords(conversationID: String, query: Query, limit: Int,
                                onChange: @escaping (Result<EncryptedHistoryRecords, Error>) -> Void) -> ServiceObservation {
        let state = FirestoreEncryptedHistoryState(session: session, limit: limit, onChange: onChange)
        let reference = conversation(conversationID)
        let messages = query
            .addSnapshotListener(includeMetadataChanges: true) { snapshot, error in
                Task { @MainActor in
                    guard !state.cancelled else { return }
                    do {
                        try state.session.requireActive()
                        if let error { throw error }
                        guard let snapshot else { return }
                        guard snapshot.documents.count <= limit else { throw EncryptedMessagingError.historyLimit }
                        let records = try snapshot.documents.map {
                            try Self.messageRecord(id: $0.documentID, data: $0.data(with: .estimate), conversationID: conversationID,
                                                   pending: $0.metadata.hasPendingWrites)
                        }
                        for record in records { try state.session.validate(record.context) }
                        state.messages = records; state.messagesFromCache = snapshot.metadata.isFromCache
                        state.bindReactions(collection: reference.collection("reactions"), conversationID: conversationID)
                    } catch { state.fail(error) }
                }
            }
        let receipts = reference.collection("readStates").limit(to: 3).addSnapshotListener { snapshot, error in
            Task { @MainActor in
                guard !state.cancelled else { return }
                do {
                    try state.session.requireActive()
                    if let error { throw error }
                    guard let snapshot else { return }
                    guard snapshot.documents.count <= 2 else { throw EncryptedMessagingError.invalidRecord }
                    var receipts: [String: MessageReceipt] = [:]
                    for document in snapshot.documents {
                        guard [state.session.capsule.creatorID, state.session.capsule.recipientID].contains(where: { $0.utf8.elementsEqual(document.documentID.utf8) }) else { throw EncryptedMessagingError.invalidRecord }
                        let data = document.data()
                        let delivered = try Self.receiptID(data["lastDeliveredMessageId"])
                        let read = try Self.receiptID(data["lastReadMessageId"])
                        receipts[document.documentID] = MessageReceipt(lastDeliveredMessageID: delivered, lastReadMessageID: read)
                    }
                    state.receipts = receipts; state.emit()
                } catch { state.fail(error) }
            }
        }
        return ServiceObservation { state.cancel(); messages.remove(); receipts.remove() }
    }

    private func validateCursor(_ cursor: MessageHistoryCursor) throws {
        try session.requireActive(conversationID: cursor.conversationID, accountID: cursor.accountID)
        guard cursor.keyEpoch == session.capsule.keyEpoch else { throw EncryptedMessagingError.untrustedConversation }
    }
    private func cursor(id: String, data: [String: Any], conversationID: String) throws -> MessageHistoryCursor {
        guard let timestamp = data["createdAt"] as? Timestamp else { throw EncryptedMessagingError.invalidRecord }
        return try MessageHistoryCursor(accountID: session.capsule.localAccountID, conversationID: conversationID,
            keyEpoch: session.capsule.keyEpoch, seconds: timestamp.seconds, nanoseconds: timestamp.nanoseconds, messageID: id)
    }
    private func cursorValues(_ cursor: MessageHistoryCursor) -> [Any] {
        [Timestamp(seconds: cursor.seconds, nanoseconds: cursor.nanoseconds), cursor.messageID]
    }
    private func orderedMessages(_ conversationID: String) -> Query {
        conversation(conversationID).collection("messages").order(by: "createdAt").order(by: FieldPath.documentID())
    }

    func historyPage(conversationID: String, before: MessageHistoryCursor?, count: Int) async throws -> EncryptedHistoryPageRecords {
        try session.requireActive(conversationID: conversationID)
        guard (1...MessageHistoryBounds.pageSize).contains(count) else { throw EncryptedMessagingError.historyLimit }
        var query = orderedMessages(conversationID)
        if let before { try validateCursor(before); query = query.end(before: cursorValues(before)) }
        let snapshot = try await query.limit(toLast: count + 1).getDocuments(source: .server)
        try session.requireActive()
        guard snapshot.documents.count <= count + 1 else { throw EncryptedMessagingError.historyLimit }
        let documents = Array(snapshot.documents.suffix(count))
        var records: [EncryptedMessageRecord] = []; var positions: [String: MessageHistoryCursor] = [:]
        for document in documents {
            let data = document.data(with: .estimate)
            let record = try Self.messageRecord(id: document.documentID, data: data, conversationID: conversationID, pending: document.metadata.hasPendingWrites)
            try session.validate(record.context); records.append(record)
            positions[document.documentID] = try cursor(id: document.documentID, data: data, conversationID: conversationID)
        }
        return EncryptedHistoryPageRecords(messages: records, positions: positions, hasOlder: snapshot.documents.count > count)
    }

    func observeWindow(conversationID: String, request: MessageHistoryWindowRequest,
                       onChange: @escaping (Result<EncryptedHistoryWindowRecords, Error>) -> Void) -> ServiceObservation {
        let control = FirestoreEncryptedWindowControl()
        do {
            try session.requireActive(conversationID: conversationID)
            guard (1...MessageHistoryBounds.windowSize).contains(request.count) else { throw EncryptedMessagingError.historyLimit }
            switch request { case .before(let cursor, _), .after(let cursor, _): try validateCursor(cursor); default: break }
        } catch { onChange(.failure(error)); return ServiceObservation() }
        let bounds = FirestoreEncryptedWindowBounds()
        let state = FirestoreEncryptedHistoryState(session: session, limit: request.count) { records in
            guard !control.cancelled else { return }
            onChange(records.map { EncryptedHistoryWindowRecords(records: $0, positions: bounds.positions,
                hasOlder: bounds.hasOlder, hasNewer: bounds.hasNewer, isRecentWindow: bounds.recent) })
        }
        control.cancelState = { state.cancel() }
        let reference = conversation(conversationID)
        // Receipts are bounded separately from paged messages.
        let receipts = reference.collection("readStates").limit(to: 3).addSnapshotListener { snapshot, error in
            Task { @MainActor in
                guard !control.cancelled else { return }
                do {
                    try state.session.requireActive()
                    if let error { throw error }; guard let snapshot else { return }
                    guard snapshot.documents.count <= 2 else { throw EncryptedMessagingError.invalidRecord }
                    var values: [String: MessageReceipt] = [:]
                    for document in snapshot.documents {
                        guard [state.session.capsule.creatorID, state.session.capsule.recipientID].contains(where: { $0.utf8.elementsEqual(document.documentID.utf8) }) else { throw EncryptedMessagingError.invalidRecord }
                        let data = document.data()
                        values[document.documentID] = MessageReceipt(lastDeliveredMessageID: try Self.receiptID(data["lastDeliveredMessageId"]), lastReadMessageID: try Self.receiptID(data["lastReadMessageId"]))
                    }
                    state.receipts = values; state.emit()
                } catch { state.fail(error) }
            }
        }
        control.registrations.append(receipts)
        func bind(_ query: Query, count: Int, part: Int, parts: Int, trimStart: Bool, older: Bool, newer: Bool, recent: Bool) {
            let listener = query.addSnapshotListener(includeMetadataChanges: true) { [weak self] snapshot, error in
                Task { @MainActor in
                    guard let self, !control.cancelled else { return }
                    do {
                        try state.session.requireActive()
                        if let error { throw error }; guard let snapshot else { return }
                        guard snapshot.documents.count <= count + 1 else { throw EncryptedMessagingError.historyLimit }
                        let documents = trimStart ? Array(snapshot.documents.suffix(count)) : Array(snapshot.documents.prefix(count))
                        var messages: [EncryptedMessageRecord] = []; var positions: [String: MessageHistoryCursor] = [:]
                        for document in documents {
                            let data = document.data(with: .estimate)
                            let record = try Self.messageRecord(id: document.documentID, data: data, conversationID: conversationID, pending: document.metadata.hasPendingWrites)
                            try state.session.validate(record.context); messages.append(record)
                            positions[document.documentID] = try self.cursor(id: document.documentID, data: data, conversationID: conversationID)
                        }
                        bounds.parts[part] = (messages, positions, snapshot.metadata.isFromCache)
                        if part == 0 { bounds.hasOlder = older || (trimStart && snapshot.documents.count > count) }
                        if part == parts - 1 { bounds.hasNewer = newer || (!trimStart && snapshot.documents.count > count) }
                        bounds.recent = recent
                        guard bounds.parts.count == parts else { return }
                        let ordered = (0..<parts).compactMap { bounds.parts[$0] }
                        state.messages = ordered.flatMap { $0.0 }
                        state.messagesFromCache = ordered.contains { $0.2 }
                        bounds.positions = ordered.reduce(into: [:]) { $0.merge($1.1, uniquingKeysWith: { first, _ in first }) }
                        state.bindReactions(collection: reference.collection("reactions"), conversationID: conversationID)
                    } catch { state.fail(error) }
                }
            }
            control.registrations.append(listener)
        }
        switch request {
        case .recent(let count):
            bind(orderedMessages(conversationID).limit(toLast: count + 1), count: count, part: 0, parts: 1, trimStart: true, older: false, newer: false, recent: true)
        case .before(let cursor, let count):
            bind(orderedMessages(conversationID).end(before: cursorValues(cursor)).limit(toLast: count + 1), count: count, part: 0, parts: 1, trimStart: true, older: false, newer: true, recent: false)
        case .after(let cursor, let count):
            bind(orderedMessages(conversationID).start(after: cursorValues(cursor)).limit(to: count + 1), count: count, part: 0, parts: 1, trimStart: false, older: true, newer: false, recent: false)
        case .around(let id, let count):
            control.task = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let document = try await reference.collection("messages").document(id.uuidString.lowercased()).getDocument(source: .server)
                    try self.session.requireActive()
                    guard !control.cancelled, !Task.isCancelled else { return }
                    guard document.exists else { throw EncryptedMessagingError.invalidRecord }
                    let position = try self.cursor(id: document.documentID, data: document.data() ?? [:], conversationID: conversationID)
                    let left = count / 2; let right = count - left
                    bind(self.orderedMessages(conversationID).end(before: self.cursorValues(position)).limit(toLast: left + 1), count: left, part: 0, parts: 2, trimStart: true, older: false, newer: false, recent: false)
                    bind(self.orderedMessages(conversationID).start(at: self.cursorValues(position)).limit(to: right + 1), count: right, part: 1, parts: 2, trimStart: false, older: false, newer: false, recent: false)
                } catch { if !control.cancelled { state.fail(error) } }
            }
        }
        return ServiceObservation { control.cancel() }
    }

    nonisolated static func messageRecord(id: String, data: [String: Any], conversationID: String, pending: Bool = false) throws -> EncryptedMessageRecord {
        try uuid(id)
        let allowed: Set<String> = ["senderId", "clientId", "type", "encryption", "keyEpoch", "revision", "ciphertext", "createdAt", "editedAt", "deletedAt", "delivery"]
        guard Set(data.keys).isSubset(of: allowed), data["type"] as? String == "encrypted",
              data["encryption"] as? String == StoredConversationCapsule.contentSuite,
              let client = data["clientId"] as? String, client.utf8.elementsEqual(id.utf8),
              let sender = data["senderId"] as? String, !sender.isEmpty, sender.utf8.count <= 256,
              data["delivery"] == nil || data["delivery"] as? String == "quiet",
              let ciphertext = data["ciphertext"] as? Data, ciphertext.count <= 69_632 else { throw EncryptedMessagingError.invalidRecord }
        let epoch = try integer(data["keyEpoch"], maximum: UInt64(UInt32.max))
        let revision = try integer(data["revision"], maximum: 9_007_199_254_740_991)
        let context = try RecordContext(conversationID: conversationID, recordID: id, senderID: sender, keyEpoch: UInt32(epoch), revision: revision)
        let created = try requiredDate(data["createdAt"])
        let edited = try optionalDate(data["editedAt"])
        let deleted = try optionalDate(data["deletedAt"])
        guard (deleted == nil) == !ciphertext.isEmpty, deleted == nil || revision > 1 else { throw EncryptedMessagingError.invalidRecord }
        return EncryptedMessageRecord(context: context, ciphertext: ciphertext, createdAt: created, editedAt: edited, deletedAt: deleted, hasPendingWrites: pending)
    }
    nonisolated static func reactionRecord(id: String, data: [String: Any], conversationID: String) throws -> EncryptedReactionRecord {
        let allowed: Set<String> = ["messageId", "userId", "encryption", "keyEpoch", "revision", "ciphertext", "updatedAt"]
        guard Set(data.keys).isSubset(of: allowed), data["encryption"] as? String == StoredConversationCapsule.contentSuite,
              let target = data["messageId"] as? String, let sender = data["userId"] as? String,
              let ciphertext = data["ciphertext"] as? Data, !ciphertext.isEmpty, ciphertext.count <= 4096 else { throw EncryptedMessagingError.invalidRecord }
        try uuid(target)
        guard id.utf8.elementsEqual(try ReactionCipher.recordID(targetMessageID: target, senderID: sender).utf8) else { throw EncryptedMessagingError.invalidRecord }
        _ = try requiredDate(data["updatedAt"])
        let context = try RecordContext(conversationID: conversationID, recordID: id, senderID: sender, kind: .reaction,
                                        keyEpoch: UInt32(integer(data["keyEpoch"], maximum: UInt64(UInt32.max))),
                                        revision: integer(data["revision"], maximum: 9_007_199_254_740_991))
        return EncryptedReactionRecord(context: context, targetMessageID: target, ciphertext: ciphertext)
    }
    nonisolated static func integer(_ value: Any?, maximum: UInt64) throws -> UInt64 {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              String(cString: number.objCType) != "d", String(cString: number.objCType) != "f",
              let result = UInt64(number.stringValue), result > 0, result <= maximum else { throw EncryptedMessagingError.invalidRecord }
        return result
    }
    nonisolated private static func requiredDate(_ value: Any?) throws -> Date {
        guard let timestamp = value as? Timestamp else { throw EncryptedMessagingError.invalidRecord }
        let date = timestamp.dateValue()
        guard date.timeIntervalSince1970.isFinite, date.timeIntervalSince1970 >= 0,
              date.timeIntervalSince1970 <= Double(ContentLimits.maximumTimestampMilliseconds) / 1000 else { throw EncryptedMessagingError.invalidRecord }
        return date
    }
    nonisolated private static func optionalDate(_ value: Any?) throws -> Date? {
        guard let value, !(value is NSNull) else { return nil }; return try requiredDate(value)
    }
    nonisolated private static func receiptID(_ value: Any?) throws -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard let id = value as? String else { throw EncryptedMessagingError.invalidRecord }; try uuid(id); return id
    }
    nonisolated private static func uuid(_ value: String) throws {
        guard let id = UUID(uuidString: value), id.uuidString.lowercased() == value, value.utf8.count == 36 else { throw EncryptedMessagingError.invalidRecord }
    }
}

@MainActor
private final class FirestoreEncryptedHistoryState {
    let session: SecureConversationSession
    let limit: Int
    private let onChange: (Result<EncryptedHistoryRecords, Error>) -> Void
    var cancelled = false
    var messages: [EncryptedMessageRecord]?
    var messagesFromCache = false
    var receipts: [String: MessageReceipt]?
    private var ids: [String] = []
    private var reactions: [Int: [EncryptedReactionRecord]] = [:]
    private var reactionCaches: [Int: Bool] = [:]
    private var registrations: [ListenerRegistration] = []
    private var generation = 0
    init(session: SecureConversationSession, limit: Int, onChange: @escaping (Result<EncryptedHistoryRecords, Error>) -> Void) {
        self.session = session; self.limit = limit; self.onChange = onChange
    }
    func bindReactions(collection: CollectionReference, conversationID: String) {
        let next = messages?.map { $0.context.recordID } ?? []
        guard next != ids else { emit(); return }
        generation += 1; let current = generation
        registrations.forEach { $0.remove() }; registrations.removeAll(); reactions.removeAll(); reactionCaches.removeAll(); ids = next
        for start in stride(from: 0, to: next.count, by: 30) {
            let batch = Array(next[start..<min(start + 30, next.count)])
            let registration = collection.whereField("messageId", in: batch).limit(to: batch.count * 2 + 1)
                .addSnapshotListener(includeMetadataChanges: true) { [weak self] snapshot, error in
                    Task { @MainActor in
                        guard let self, !self.cancelled, self.generation == current else { return }
                        do {
                            try self.session.requireActive()
                            if let error { throw error }; guard let snapshot else { return }
                            guard snapshot.documents.count <= batch.count * 2 else { throw EncryptedMessagingError.historyLimit }
                            let values = try snapshot.documents.map {
                                try FirestoreEncryptedMessagingTransport.reactionRecord(id: $0.documentID, data: $0.data(with: .estimate), conversationID: conversationID)
                            }
                            for value in values { try self.session.validate(value.context) }
                            self.reactions[start] = values; self.reactionCaches[start] = snapshot.metadata.isFromCache; self.emit()
                        } catch { self.fail(error) }
                    }
                }
            registrations.append(registration)
        }
        emit()
    }
    func emit() {
        guard !cancelled, let messages, let receipts, reactions.count == registrations.count,
              (try? session.requireActive()) != nil else { return }
        onChange(.success(EncryptedHistoryRecords(messages: messages, reactions: reactions.keys.sorted().flatMap { reactions[$0] ?? [] },
                                                  receipts: receipts, isFromCache: messagesFromCache,
                                                  reactionsAreFromCache: reactionCaches.values.contains(true))))
    }
    func fail(_ error: Error) { guard !cancelled, (try? session.requireActive()) != nil else { return }; onChange(.failure(error)) }
    func cancel() { cancelled = true; registrations.forEach { $0.remove() }; registrations.removeAll(); messages = nil; receipts = nil; reactions.removeAll() }
}

@MainActor
private final class FirestoreEncryptedWindowControl {
    var cancelled = false
    var task: Task<Void, Never>?
    var registrations: [ListenerRegistration] = []
    var cancelState: (() -> Void)?
    func cancel() { cancelled = true; task?.cancel(); registrations.forEach { $0.remove() }; registrations.removeAll(); cancelState?(); cancelState = nil }
}
@MainActor
private final class FirestoreEncryptedWindowBounds {
    var positions: [String: MessageHistoryCursor] = [:]
    var parts: [Int: ([EncryptedMessageRecord], [String: MessageHistoryCursor], Bool)] = [:]
    var hasOlder = false
    var hasNewer = false
    var recent = false
}
