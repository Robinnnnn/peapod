import CryptoKit
import Foundation
import MinesE2EE

enum EncryptedMessageNotificationPolicy {
    static func deliveryMode(for payload: ConversationMessagePayload) -> ContentDeliveryMode {
        // Group membership stays inside the authenticated ciphertext. Derive the
        // existing public quiet marker on every flush, including durable retries,
        // without changing the sender's delivery choice or the encrypted payload.
        if let group = payload.photoGroup, group.index > 0 { return .quiet }
        return payload.deliveryMode
    }
}

/// Counts only, with no decrypted content/account/record IDs. Superseded edits were cancelled
/// locally after a definite authenticated conflict; this never reports them as delivered.
struct EncryptedRetryConflictSummary: LocalizedError, Sendable {
    let publishedMessages: Int
    let supersededEdits: Int
    let blockedMessages: Int
    var errorDescription: String? {
        "\(supersededEdits) queued edits were superseded; \(blockedMessages) messages still conflict. Other pending messages were retried."
    }
}
private struct ConfirmedMessageRevisionRejection: LocalizedError, Sendable {
    let current: EncryptedMessageRecord
    var errorDescription: String? { "This message conflicts with an existing encrypted revision." }
}

@MainActor
final class EncryptedMessagingService: MessageHistoryWindowProviding {
    static let maximumHistoryMessages = 1000
    static let maximumReplyContexts = 100
    let session: SecureConversationSession
    private let outbox: DurableCiphertextOutbox
    private let transport: any EncryptedMessagingTransport
    private let metadata: any MessagingProviding
    private var invalidation: ServiceObservation?
    private var observations: [UUID: ServiceObservation] = [:]
    private var busy: Set<Data> = []
    private var operationWaiters: [Data: [UUID: CheckedContinuation<Void, Never>]] = [:]
    private var preparedReactions: [Data: (EncryptedReactionRecord, ReactionPayload)] = [:]
    private var preparedUnsend: [Data: RecordContext] = [:]
    // Bounded RAM-only replay/equivocation fingerprints. Evicted identities and process restarts
    // have no rollback guarantee; no lifetime/full-history protection is claimed.
    private var seen: [Data: (RecordContext, Data)] = [:]
    private var seenUse: [Data: Int] = [:]
    private var seenRecordIDs: [Data: Data] = [:]
    private var seenClock = 0
    private var seenOwners: [UUID: Set<Data>] = [:]

    init(session: SecureConversationSession, outbox: DurableCiphertextOutbox,
         transport: any EncryptedMessagingTransport, metadata: any MessagingProviding) {
        self.session = session; self.outbox = outbox; self.transport = transport; self.metadata = metadata
        invalidation = session.observeInvalidation { [weak self] in
            guard let self else { return }
            let waiting = self.operationWaiters.values.flatMap { $0.values }
            self.operationWaiters.removeAll()
            waiting.forEach { $0.resume() }
            let observations = Array(self.observations.values)
            self.observations.removeAll()
            observations.forEach { $0.cancel() }
             self.preparedReactions.removeAll(); self.preparedUnsend.removeAll(); self.seen.removeAll(); self.seenUse.removeAll(); self.seenRecordIDs.removeAll(); self.seenOwners.removeAll()
        }
    }

    private var scope: OutboxScope {
        get throws { try OutboxScope(accountID: session.capsule.localAccountID, conversationID: session.capsule.conversationID, keyEpoch: session.capsule.keyEpoch) }
    }
    private func begin(conversationID: String, recordID: String) throws -> Data {
        try session.requireActive(conversationID: conversationID)
        let id = Data(recordID.utf8)
        guard busy.insert(id).inserted else { throw EncryptedMessagingError.conflictingRecord }
        return id
    }
    // A local draft replay can meet a background drain of the same durable record.
    // Wait for that operation, then perform the original authenticated comparison.
    private func beginAfterCurrentOperation(conversationID: String, recordID: String) async throws -> Data {
        let id = Data(recordID.utf8)
        while busy.contains(id) {
            try session.requireActive(conversationID: conversationID)
            try Task.checkCancellation()
            guard operationWaiters.values.reduce(0, { $0 + $1.count }) < 32 else {
                throw EncryptedMessagingError.historyLimit
            }
            let waiterID = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    operationWaiters[id, default: [:]][waiterID] = continuation
                    if Task.isCancelled { cancelOperationWaiter(id, waiterID: waiterID) }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.cancelOperationWaiter(id, waiterID: waiterID) }
            }
        }
        try Task.checkCancellation()
        return try begin(conversationID: conversationID, recordID: recordID)
    }
    private func cancelOperationWaiter(_ id: Data, waiterID: UUID) {
        operationWaiters[id]?.removeValue(forKey: waiterID)?.resume()
        if operationWaiters[id]?.isEmpty == true { operationWaiters[id] = nil }
    }
    private func finishOperation(_ id: Data) {
        busy.remove(id)
        operationWaiters.removeValue(forKey: id)?.values.forEach { $0.resume() }
    }
    private func loadPending(_ id: String) async throws -> PendingOutboxRecord? {
        let scope = try scope; let outbox = outbox
        return try await session.performKeyOperation { try outbox.load(scope: scope, recordID: id, epochKey: $0) }
    }
    private func decode(_ record: EncryptedMessageRecord) async throws -> ConversationMessagePayload {
        try session.validate(record.context)
        guard record.context.kind == .message, record.deletedAt == nil, !record.ciphertext.isEmpty else { throw EncryptedMessagingError.invalidRecord }
        return try await session.performKeyOperation {
            try ConversationMessageCipher.open(record.ciphertext, expectedContext: record.context, epochKey: $0)
        }
    }
    private func checkSeen(context: RecordContext, bytes: Data) throws {
        let identity = Data(context.kind.rawValue.utf8) + Data([0]) + Data(context.recordID.utf8)
        let fingerprint = Data(SHA256.hash(data: bytes))
        if let old = seen[identity] {
            guard old.0.senderID.utf8.elementsEqual(context.senderID.utf8), context.revision >= old.0.revision,
                  context.revision != old.0.revision || (old.0 == context && old.1 == fingerprint) else {
                throw EncryptedMessagingError.conflictingRecord
            }
        }
        if seen[identity] == nil, seen.count >= 4000 {
            let protected = seenOwners.values.reduce(into: Set<Data>()) { $0.formUnion($1) }
            let pendingIDs = Set(try outbox.pendingRecordIDs(scope: scope).map { Data($0.utf8) })
            guard let victim = seen.keys.filter({ identity in
                guard !protected.contains(identity), let recordID = seenRecordIDs[identity] else { return false }
                return !busy.contains(recordID) && !pendingIDs.contains(recordID) && preparedUnsend[recordID] == nil && preparedReactions[recordID] == nil
            }).min(by: { (seenUse[$0] ?? 0) < (seenUse[$1] ?? 0) }) else { throw EncryptedMessagingError.historyLimit }
            seen[victim] = nil; seenUse[victim] = nil; seenRecordIDs[victim] = nil
        }
        seen[identity] = (context, fingerprint); seenRecordIDs[identity] = Data(context.recordID.utf8)
        seenClock &+= 1; seenUse[identity] = seenClock
    }

    private func seenIdentity(_ context: RecordContext) -> Data {
        Data(context.kind.rawValue.utf8) + Data([0]) + Data(context.recordID.utf8)
    }
    private func validatePosition(_ position: MessageHistoryCursor, context: RecordContext) throws {
        try session.requireActive(conversationID: position.conversationID, accountID: position.accountID)
        guard position.keyEpoch == context.keyEpoch, position.messageID.utf8.elementsEqual(context.recordID.utf8) else { throw EncryptedMessagingError.invalidRecord }
    }
    private func less(_ lhs: MessageHistoryCursor, _ rhs: MessageHistoryCursor) -> Bool {
        if lhs.seconds != rhs.seconds { return lhs.seconds < rhs.seconds }
        if lhs.nanoseconds != rhs.nanoseconds { return lhs.nanoseconds < rhs.nanoseconds }
        return lhs.messageID < rhs.messageID // Canonical ASCII UUIDs only.
    }
    private func validatePage(_ records: [EncryptedMessageRecord], positions: [String: MessageHistoryCursor], before: MessageHistoryCursor? = nil) throws {
        guard records.count <= MessageHistoryBounds.windowSize, positions.count == records.count else { throw EncryptedMessagingError.historyLimit }
        var ids = Set<Data>(); var previous: MessageHistoryCursor?
        for record in records {
            try session.validate(record.context)
            guard record.context.kind == .message, ids.insert(Data(record.context.recordID.utf8)).inserted,
                  let position = positions[record.context.recordID] else { throw EncryptedMessagingError.invalidRecord }
            try validatePosition(position, context: record.context)
            if let previous, !less(previous, position) { throw EncryptedMessagingError.invalidRecord }
            if let before, !less(position, before) { throw EncryptedMessagingError.invalidRecord }
            previous = position
        }
    }
    private func openPayloads(_ records: [EncryptedMessageRecord]) async throws -> [ConversationMessagePayload?] {
        for record in records {
            try session.validate(record.context)
            if record.deletedAt != nil {
                guard record.context.kind == .message, record.context.revision > 1, record.ciphertext.isEmpty else { throw EncryptedMessagingError.invalidRecord }
            } else if record.ciphertext.isEmpty { throw EncryptedMessagingError.invalidRecord }
        }
        return try await session.performKeyOperation { key in
            try records.map { record in
                guard record.deletedAt == nil else { return nil }
                return try ConversationMessageCipher.open(record.ciphertext, expectedContext: record.context, epochKey: key)
            }
        }
    }
    private func appMessage(_ record: EncryptedMessageRecord, payload: ConversationMessagePayload?, register: Bool) throws -> ChatMessage {
        if let payload { return try EncryptedMessageBridge.message(from: payload, record: record, session: session, registerAttachment: register) }
        return ChatMessage(id: try Self.uuid(record.context.recordID), senderID: record.context.senderID, kind: .text,
                           body: "", createdAt: record.createdAt, deletedAt: record.deletedAt, deliveryState: .sent)
    }
    private func decodeWindow(_ records: EncryptedHistoryRecords, owner: UUID, current: () -> Bool) async throws -> MessageHistorySnapshot {
        guard records.messages.count <= MessageHistoryBounds.windowSize, records.reactions.count <= records.messages.count * 2 else { throw EncryptedMessagingError.historyLimit }
        let payloads = try await openPayloads(records.messages)
        guard current() else { throw CancellationError() }
        var messages = try zip(records.messages, payloads).map { try appMessage($0.0, payload: $0.1, register: false) }
        guard Set(messages.map(\.id)).count == messages.count else { throw EncryptedMessagingError.invalidRecord }
        let indexes = Dictionary(uniqueKeysWithValues: messages.enumerated().map { ($0.element.id.uuidString.lowercased(), $0.offset) })
        var reactionValues: [UUID: [String: String]] = [:]
        for record in records.reactions { try session.validate(record.context); guard indexes[record.targetMessageID] != nil else { throw EncryptedMessagingError.invalidRecord } }
        let reactionPayloads = try await session.performKeyOperation { key in
            try records.reactions.map { try ReactionCipher.open($0.ciphertext, expectedContext: $0.context, expectedTargetMessageID: $0.targetMessageID, epochKey: key) }
        }
        guard current() else { throw CancellationError() }
        var reactionIDs = Set<Data>()
        for (record, payload) in zip(records.reactions, reactionPayloads) {
            guard reactionIDs.insert(seenIdentity(record.context)).inserted else { throw EncryptedMessagingError.invalidRecord }
            if let emoji = payload.emoji { reactionValues[try Self.uuid(payload.targetMessageID), default: [:]][record.context.senderID] = emoji }
        }
        let peer = SecureConversationSession.same(session.capsule.localAccountID, session.capsule.creatorID) ? session.capsule.recipientID : session.capsule.creatorID
        let receipt = records.receipts.first { SecureConversationSession.same($0.key, peer) }?.value
        for index in messages.indices {
            messages[index].reactions = reactionValues[messages[index].id] ?? [:]
            messages[index].deliveryState = receipt?.deliveryState(for: messages[index].id.uuidString.lowercased(), messageIndexes: indexes, fallback: messages[index].deliveryState) ?? messages[index].deliveryState
        }
        let replyIDs = Set(messages.compactMap(\.replyToID)).subtracting(Set(messages.map(\.id)))
        guard replyIDs.count <= MessageHistoryBounds.windowSize else { throw EncryptedMessagingError.historyLimit }
        var replyRecords: [EncryptedMessageRecord] = []
        for id in replyIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            let record = try await transport.message(conversationID: session.capsule.conversationID, recordID: id.uuidString.lowercased())
            try session.requireActive(); guard current() else { throw CancellationError() }
            if let record, record.deletedAt == nil {
                guard record.context.recordID.utf8.elementsEqual(id.uuidString.lowercased().utf8) else { throw EncryptedMessagingError.invalidRecord }
                replyRecords.append(record)
            }
        }
        let replyPayloads = try await openPayloads(replyRecords)
        guard current() else { throw CancellationError() }
        let oldSeenOwner = seenOwners[owner]
        let newSeenOwner = Set((records.messages + replyRecords).map { seenIdentity($0.context) } + records.reactions.map { seenIdentity($0.context) })
        seenOwners[owner] = (oldSeenOwner ?? []).union(newSeenOwner)
        do {
            for record in records.messages + replyRecords { try checkSeen(context: record.context, bytes: record.ciphertext) }
            for record in records.reactions { try checkSeen(context: record.context, bytes: record.ciphertext) }
            let descriptors = zip(records.messages + replyRecords, payloads + replyPayloads).compactMap { record, payload in
                payload?.attachment.map { (metadata: $0, context: record.context) }
            }
            try session.replaceHistoryAttachmentMetadata(ownerID: owner, entries: descriptors)
            seenOwners[owner] = newSeenOwner
        } catch { seenOwners[owner] = oldSeenOwner; throw error }
        let replies = try Dictionary(uniqueKeysWithValues: zip(replyRecords, replyPayloads).map {
            (try Self.uuid($0.0.context.recordID), try appMessage($0.0, payload: $0.1, register: false))
        })
        return MessageHistorySnapshot(messages: messages, isFromCache: records.isFromCache, replyMessages: replies, reactionsAreFromCache: records.reactionsAreFromCache)
    }

    func observeMessagePins(conversationID: String, currentUserID: String,
                            onChange: @escaping (Result<[UUID], Error>) -> Void) -> ServiceObservation {
        do { try session.requireActive(conversationID: conversationID, accountID: currentUserID) }
        catch { onChange(.failure(error)); return ServiceObservation() }
        let id = UUID()
        let source = metadata.observeMessagePins(conversationID: conversationID, currentUserID: currentUserID) { [weak self] result in
            guard let self, (try? self.session.requireActive()) != nil else { return }
            onChange(result)
        }
        let observation = ServiceObservation { [weak self] in source.cancel(); self?.observations[id] = nil }
        observations[id] = observation
        return observation
    }

    func setMessagePinned(_ pinned: Bool, conversationID: String, messageID: UUID,
                          currentUserID: String) async throws {
        try session.requireActive(conversationID: conversationID, accountID: currentUserID)
        if pinned {
            guard let record = try await transport.message(conversationID: conversationID,
                    recordID: messageID.uuidString.lowercased()), !record.hasPendingWrites else {
                throw EncryptedMessagingError.invalidRecord
            }
            try session.requireActive()
            guard record.context.recordID == messageID.uuidString.lowercased() else { throw EncryptedMessagingError.invalidRecord }
            _ = try await decode(record)
        }
        try session.requireActive()
        try await metadata.setMessagePinned(pinned, conversationID: conversationID,
                                            messageID: messageID, currentUserID: currentUserID)
        try session.requireActive()
    }

    func observeMessagesByID(conversationID: String, currentUserID: String, messageIDs: [UUID],
                             onChange: @escaping (Result<MessageHistorySnapshot, Error>) -> Void) -> ServiceObservation {
        let id = UUID(); let state = EncryptedHistoryTaskState()
        do {
            try session.requireActive(conversationID: conversationID, accountID: currentUserID)
            guard !messageIDs.isEmpty, messageIDs.count <= MessagePinningPolicy.pageSize,
                  Set(messageIDs).count == messageIDs.count, seenOwners.count < 4 else { throw MessagePinningError.invalidPage }
            seenOwners[id] = []
        } catch { onChange(.failure(error)); return ServiceObservation() }
        let allowed = Set(messageIDs.map { $0.uuidString.lowercased() })
        let source = transport.observeMessagesByID(conversationID: conversationID, messageIDs: messageIDs.map { $0.uuidString.lowercased() }) { [weak self] result in
            guard let self, !state.cancelled else { return }
            state.generation += 1; let generation = state.generation; state.task?.cancel()
            state.task = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let records = try result.get()
                    guard records.messages.count <= allowed.count,
                          records.messages.allSatisfy({ allowed.contains($0.context.recordID) }) else {
                        throw EncryptedMessagingError.invalidRecord
                    }
                    let history = try await self.decodeWindow(records, owner: id, current: { state.isCurrent(generation) })
                    try self.session.requireActive(); guard state.isCurrent(generation) else { return }
                    onChange(.success(history))
                } catch {
                    guard state.isCurrent(generation), (try? self.session.requireActive()) != nil else { return }
                    // Failed authentication must release prior attachment descriptors too.
                    self.session.releaseAttachmentMetadata(ownerID: id)
                    onChange(.failure(error))
                }
            }
        }
        let observation = ServiceObservation { [weak self] in
            state.cancel(); source.cancel(); self?.observations[id] = nil; self?.seenOwners[id] = nil
            self?.session.releaseAttachmentMetadata(ownerID: id)
        }
        observations[id] = observation
        return observation
    }

    func supportsHistoryWindows(conversationID: String) throws -> Bool { try session.requireActive(conversationID: conversationID); return true }
    func observeHistoryWindow(conversationID: String, currentUserID: String, request: MessageHistoryWindowRequest,
                              onChange: @escaping (Result<MessageHistoryWindowSnapshot, Error>) -> Void) -> ServiceObservation {
        let id = UUID(); let state = EncryptedHistoryTaskState()
        do {
            try session.requireActive(conversationID: conversationID, accountID: currentUserID)
            guard (1...MessageHistoryBounds.windowSize).contains(request.count), seenOwners.count < 4 else { throw EncryptedMessagingError.historyLimit }
            switch request { case .before(let position, _), .after(let position, _):
                try session.requireActive(conversationID: position.conversationID, accountID: position.accountID)
                guard position.keyEpoch == session.capsule.keyEpoch else { throw EncryptedMessagingError.untrustedConversation }
            default: break }
            seenOwners[id] = []
        } catch { onChange(.failure(error)); return ServiceObservation() }
        let source = transport.observeWindow(conversationID: conversationID, request: request) { [weak self] result in
            guard let self, !state.cancelled else { return }
            state.generation += 1; let generation = state.generation; state.task?.cancel()
            state.task = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let page = try result.get()
                    guard page.records.messages.count <= request.count else { throw EncryptedMessagingError.historyLimit }
                    try self.validatePage(page.records.messages, positions: page.positions)
                    let history = try await self.decodeWindow(page.records, owner: id, current: { state.isCurrent(generation) })
                    try self.session.requireActive(); guard state.isCurrent(generation) else { return }
                    let positions = try Dictionary(uniqueKeysWithValues: page.positions.map { (try Self.uuid($0.key), $0.value) })
                    onChange(.success(MessageHistoryWindowSnapshot(history: history, positions: positions, hasOlder: page.hasOlder, hasNewer: page.hasNewer, isRecentWindow: page.isRecentWindow)))
                } catch {
                    guard state.isCurrent(generation), (try? self.session.requireActive()) != nil else { return }
                    onChange(.failure(error))
                }
            }
        }
        let observation = ServiceObservation { [weak self] in
            state.cancel(); source.cancel(); self?.observations[id] = nil; self?.seenOwners[id] = nil; self?.session.releaseAttachmentMetadata(ownerID: id)
        }
        observations[id] = observation; return observation
    }

    func searchHistory(conversationID: String, currentUserID: String, query: String,
                       continuation: MessageHistorySearchContinuation?,
                       onChange: @escaping (Result<MessageHistorySearchSnapshot, Error>) -> Void) -> ServiceObservation {
        let id = UUID(); let state = EncryptedHistoryTaskState()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines); let queryBytes = Data(query.utf8)
        do {
            try session.requireActive(conversationID: conversationID, accountID: currentUserID)
            guard !queryBytes.isEmpty, queryBytes.count <= MessageHistoryBounds.queryBytes, seenOwners.count < 4 else { throw EncryptedMessagingError.historyLimit }
            if let continuation {
                guard continuation.queryBytes == queryBytes else { throw EncryptedMessagingError.invalidRecord }
                try session.requireActive(conversationID: continuation.cursor.conversationID, accountID: continuation.cursor.accountID)
                guard continuation.cursor.keyEpoch == session.capsule.keyEpoch else { throw EncryptedMessagingError.untrustedConversation }
            }
            seenOwners[id] = []
        } catch { onChange(.failure(error)); return ServiceObservation() }
        state.task = Task { @MainActor [weak self] in
            guard let self else { return }
            var before = continuation?.cursor; var matches: [ChatMessage] = []; var ids = Set<UUID>(); var scanned = 0
            var descriptors: [(metadata: PrivateAttachment, context: RecordContext)] = []
            do {
                while !state.cancelled, !Task.isCancelled {
                    let page = try await self.transport.historyPage(conversationID: conversationID, before: before, count: MessageHistoryBounds.pageSize)
                    try self.session.requireActive(); guard state.isCurrent(0) else { return }
                    guard page.messages.count <= MessageHistoryBounds.pageSize, !page.messages.isEmpty || !page.hasOlder else { throw EncryptedMessagingError.invalidRecord }
                    try self.validatePage(page.messages, positions: page.positions, before: before)
                    let payloads = try await self.openPayloads(page.messages)
                    guard state.isCurrent(0) else { return }
                    for index in page.messages.indices.reversed() {
                        let record = page.messages[index]; let payload = payloads[index]
                        try self.checkSeen(context: record.context, bytes: record.ciphertext)
                        scanned += 1
                        let message = try self.appMessage(record, payload: payload, register: false)
                        if message.matchesSearch(query), !ids.contains(message.id) {
                            let additions = payload?.attachment.map { [(metadata: $0, context: record.context)] } ?? []
                            let candidateDescriptors = descriptors + additions
                            try self.session.replaceHistoryAttachmentMetadata(ownerID: id, entries: candidateDescriptors)
                            descriptors = candidateDescriptors; matches.append(message); ids.insert(message.id)
                            self.seenOwners[id, default: []].insert(self.seenIdentity(record.context))
                        }
                        if matches.count == MessageHistoryBounds.searchResults {
                            guard let cursor = page.positions[record.context.recordID] else { throw EncryptedMessagingError.invalidRecord }
                            let more = index > 0 || page.hasOlder
                            onChange(.success(MessageHistorySearchSnapshot(messages: Array(matches.reversed()), scannedCount: scanned, isComplete: !more,
                                continuation: more ? MessageHistorySearchContinuation(cursor: cursor, queryBytes: queryBytes) : nil)))
                            return
                        }
                    }
                    try self.session.requireActive(); guard state.isCurrent(0) else { return }
                    onChange(.success(MessageHistorySearchSnapshot(messages: Array(matches.reversed()), scannedCount: scanned, isComplete: !page.hasOlder, continuation: nil)))
                    guard page.hasOlder, let oldest = page.messages.first, let cursor = page.positions[oldest.context.recordID] else { return }
                    before = cursor
                }
            } catch {
                guard state.isCurrent(0), (try? self.session.requireActive()) != nil else { return }
                onChange(.failure(error))
            }
        }
        let observation = ServiceObservation { [weak self] in
            state.cancel(); self?.observations[id] = nil; self?.seenOwners[id] = nil; self?.session.releaseAttachmentMetadata(ownerID: id)
        }
        observations[id] = observation; return observation
    }

    func observeMessages(conversationID: String, currentUserID: String,
                         onChange: @escaping (Result<[ChatMessage], Error>) -> Void) -> ServiceObservation {
        observeMessages(conversationID: conversationID, currentUserID: currentUserID, messageLimit: nil, onChange: onChange)
    }
    func observeMessages(conversationID: String, currentUserID: String, messageLimit: Int?,
                         onChange: @escaping (Result<[ChatMessage], Error>) -> Void) -> ServiceObservation {
        observeMessageHistory(conversationID: conversationID, currentUserID: currentUserID, messageLimit: messageLimit) {
            onChange($0.map(\.messages))
        }
    }
    func observeMessageHistory(conversationID: String, currentUserID: String, messageLimit: Int?,
                               onChange: @escaping (Result<MessageHistorySnapshot, Error>) -> Void) -> ServiceObservation {
        do { try session.requireActive(conversationID: conversationID, accountID: currentUserID) }
        catch { onChange(.failure(error)); return ServiceObservation() }
        let limit = messageLimit ?? MessageHistoryBounds.pageSize
        guard (1...Self.maximumHistoryMessages).contains(limit) else {
            onChange(.failure(EncryptedMessagingError.historyLimit)); return ServiceObservation()
        }
        let id = UUID()
        let state = EncryptedHistoryTaskState()
        let source = transport.observeHistory(conversationID: conversationID, limit: limit) { [weak self] result in
            guard let self, !state.cancelled else { return }
            state.generation += 1
            let generation = state.generation
            state.task?.cancel()
            state.task = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try self.session.requireActive()
                    let records = try result.get()
                    guard records.messages.count <= limit, records.reactions.count <= limit * 2 else { throw EncryptedMessagingError.historyLimit }
                    var messages: [ChatMessage] = []
                    for record in records.messages {
                        try self.session.validate(record.context)
                        var message: ChatMessage
                        if let deleted = record.deletedAt {
                            guard record.context.kind == .message, record.context.revision > 1, record.ciphertext.isEmpty else { throw EncryptedMessagingError.invalidRecord }
                            message = ChatMessage(id: try Self.uuid(record.context.recordID), senderID: record.context.senderID,
                                                  kind: .text, body: "", createdAt: record.createdAt, deletedAt: deleted,
                                                  deliveryState: .sent)
                        } else {
                            let payload = try await self.decode(record)
                            guard state.isCurrent(generation) else { return }
                            message = try EncryptedMessageBridge.message(from: payload, record: record, session: self.session)
                        }
                        guard state.isCurrent(generation) else { return }
                        try self.checkSeen(context: record.context, bytes: record.ciphertext)
                        messages.append(message)
                    }
                    guard Set(messages.map(\.id)).count == messages.count else { throw EncryptedMessagingError.invalidRecord }
                    let indexes = Dictionary(uniqueKeysWithValues: messages.enumerated().map { ($0.element.id.uuidString.lowercased(), $0.offset) })
                    var reactionValues: [UUID: [String: String]] = [:]
                    for reaction in records.reactions {
                        try self.session.validate(reaction.context)
                        guard indexes[reaction.targetMessageID] != nil else { throw EncryptedMessagingError.invalidRecord }
                        let payload = try await self.session.performKeyOperation {
                            try ReactionCipher.open(reaction.ciphertext, expectedContext: reaction.context,
                                                    expectedTargetMessageID: reaction.targetMessageID, epochKey: $0)
                        }
                        guard state.isCurrent(generation) else { return }
                        try self.checkSeen(context: reaction.context, bytes: reaction.ciphertext)
                        if let emoji = payload.emoji { reactionValues[try Self.uuid(payload.targetMessageID), default: [:]][reaction.context.senderID] = emoji }
                    }
                    let peer = self.session.capsule.localAccountID.utf8.elementsEqual(self.session.capsule.creatorID.utf8)
                        ? self.session.capsule.recipientID : self.session.capsule.creatorID
                    let receipt = records.receipts.first { SecureConversationSession.same($0.key, peer) }?.value
                    for index in messages.indices {
                        messages[index].reactions = reactionValues[messages[index].id] ?? [:]
                        messages[index].deliveryState = receipt?.deliveryState(for: messages[index].id.uuidString.lowercased(), messageIndexes: indexes,
                                                                             fallback: messages[index].deliveryState) ?? messages[index].deliveryState
                    }
                    let visible = Set(messages.map(\.id))
                    let replyIDs = Set(messages.compactMap(\.replyToID)).subtracting(visible)
                    guard replyIDs.count <= Self.maximumReplyContexts else { throw EncryptedMessagingError.historyLimit }
                    var replies: [UUID: ChatMessage] = [:]
                    for replyID in replyIDs {
                        let record = try await self.transport.message(conversationID: conversationID, recordID: replyID.uuidString.lowercased())
                        try self.session.requireActive()
                        guard state.isCurrent(generation) else { return }
                        if let record, record.deletedAt == nil {
                            guard record.context.recordID.utf8.elementsEqual(replyID.uuidString.lowercased().utf8) else { throw EncryptedMessagingError.invalidRecord }
                            let payload = try await self.decode(record)
                            guard state.isCurrent(generation) else { return }
                            try self.checkSeen(context: record.context, bytes: record.ciphertext)
                            replies[replyID] = try EncryptedMessageBridge.message(from: payload, record: record, session: self.session)
                        }
                    }
                    try self.session.requireActive()
                    guard state.isCurrent(generation) else { return }
                    onChange(.success(MessageHistorySnapshot(messages: messages, isFromCache: records.isFromCache,
                                                             replyMessages: replies, reactionsAreFromCache: records.reactionsAreFromCache)))
                } catch {
                    guard state.isCurrent(generation), (try? self.session.requireActive()) != nil else { return }
                    onChange(.failure(error))
                }
            }
        }
        let observation = ServiceObservation { [weak self] in state.cancel(); source.cancel(); self?.observations[id] = nil }
        observations[id] = observation
        return observation
    }

    func send(_ message: ChatMessage, conversationID: String) async throws -> ChatMessage {
        let id = message.id.uuidString.lowercased()
        let operation = try await beginAfterCurrentOperation(conversationID: conversationID, recordID: id)
        defer { finishOperation(operation) }
        guard SecureConversationSession.same(message.senderID, session.capsule.localAccountID) else { throw EncryptedMessagingError.untrustedConversation }
        let context = try session.context(recordID: id)
        let expected = try EncryptedMessageBridge.payload(from: message, context: context, session: session)
        let pending: PendingOutboxRecord
        if let existing = try await loadPending(id) {
            guard existing.context == context else { throw EncryptedMessagingError.conflictingRecord }
            let decoded = try await session.performKeyOperation {
                try ConversationMessageCipher.open(existing.envelope, expectedContext: existing.context, epochKey: $0)
            }
            guard decoded == expected else { throw EncryptedMessagingError.conflictingRecord }
            pending = existing
        } else {
            if let revision = try outbox.acknowledgedRevision(scope: scope, recordID: id) {
                guard let record = try await transport.message(conversationID: conversationID, recordID: id) else { throw EncryptedMessagingError.conflictingRecord }
                try session.requireActive()
                let payload = try await decode(record)
                guard revision == 1, record.context == context, payload == expected else { throw EncryptedMessagingError.conflictingRecord }
                return try EncryptedMessageBridge.message(from: payload, record: record, session: session)
            }
            let attachments = try [session.sealedAttachment(for: context), session.sealedPhotoPreview(for: context)].compactMap { $0 } + session.sealedPhotoRenditions(for: context)
            if expected.attachment != nil, attachments.isEmpty { throw EncryptedMessagingError.missingAttachment }
            let outbox = outbox; let scope = try scope
            do {
                pending = try await session.performKeyOperation { key in
                    let bytes = try ConversationMessageCipher.seal(expected, context: context, epochKey: key)
                    return try outbox.enqueueForDelivery(envelope: bytes, attachments: attachments,
                        context: context, scope: scope, epochKey: key)
                }
            } catch E2EEError.revisionConflict {
                // Acknowledged ledger entries deliberately retain the digest. Never regenerate a
                // network retry: verify the existing remote authenticated payload instead.
                guard let record = try await transport.message(conversationID: conversationID, recordID: id) else { throw EncryptedMessagingError.conflictingRecord }
                try session.requireActive()
                let payload = try await decode(record)
                guard record.context == context, payload == expected else { throw EncryptedMessagingError.conflictingRecord }
                return try EncryptedMessageBridge.message(from: payload, record: record, session: session)
            }
        }
        // The exact bytes are durable now. Retry restores them from SQLite; the session
        // need not retain a second large attachment while the network is unavailable.
        session.releaseSealedAttachment(for: pending.context)
        let record = try await flush(pending)
        return try EncryptedMessageBridge.message(from: expected, record: record, session: session)
    }

    /// Restores the original random descriptor/blob before an attachment draft is prepared again.
    /// Call before sealing/upload staging; a restarted session must not create a replacement key.
    func restorePendingAttachment(messageID: UUID) async throws -> AttachmentContent? {
        let id = messageID.uuidString.lowercased()
        guard let pending = try await loadPending(id) else {
            guard let acknowledged = try outbox.acknowledgedRevision(scope: scope, recordID: id) else { return nil }
            guard acknowledged == 1, let record = try await transport.message(conversationID: session.capsule.conversationID, recordID: id) else { throw EncryptedMessagingError.conflictingRecord }
            try session.requireActive()
            let payload = try await decode(record)
            guard record.context.revision == acknowledged, SecureConversationSession.same(record.context.senderID, session.capsule.localAccountID), payload.attachment != nil else { throw EncryptedMessagingError.conflictingRecord }
            return try EncryptedMessageBridge.message(from: payload, record: record, session: session).attachment
        }
        let payload = try await session.performKeyOperation {
            try ConversationMessageCipher.open(pending.envelope, expectedContext: pending.context, epochKey: $0)
        }
        guard let metadata = payload.attachment else { return nil }
        let previewID = PhotoPreviewCipher.attachmentID(for: metadata, context: pending.context)
        let preview = pending.attachments.first(where: { $0.attachmentID == previewID })
        var renditions: [PhotoRendition: Data] = [:]
        for rendition in PhotoRendition.allCases {
            let id = PhotoRenditionCipher.attachmentID(for: metadata, context: pending.context, rendition: rendition)
            renditions[rendition] = pending.attachments.first(where: { $0.attachmentID == id })?.bytes
        }
        guard let blob = pending.attachments.first(where: { $0.attachmentID.utf8.elementsEqual(metadata.attachmentID.utf8) }), pending.attachments.count == 1 + (preview == nil ? 0 : 1) + renditions.count else {
            throw EncryptedMessagingError.missingAttachment
        }
        try session.registerAttachment(metadata, context: pending.context, sealedBytes: blob.bytes, previewBytes: preview?.bytes, renditionBytes: renditions)
        let record = EncryptedMessageRecord(context: pending.context, ciphertext: pending.envelope, createdAt: .now,
                                            editedAt: nil, deletedAt: nil, hasPendingWrites: true)
        return try EncryptedMessageBridge.message(from: payload, record: record, session: session).attachment
    }

    /// Background replay never rebases an old edit over another device's newer intent.
    /// Definite authenticated edit conflicts are retired distinctly from acknowledgements;
    /// blocked create collisions stay pending. Drain unrelated rows before reporting counts.
    func retryPendingMessages() async throws {
        try session.requireActive()
        let ids = try outbox.pendingRecordIDs(scope: scope)
        var published = 0; var superseded = 0; var blocked = 0
        for id in ids {
            let operation = try await beginAfterCurrentOperation(conversationID: session.capsule.conversationID, recordID: id)
            defer { finishOperation(operation) }
            guard let pending = try await loadPending(id) else { continue }
            do { _ = try await flush(pending); published += 1 }
            catch let rejection as ConfirmedMessageRevisionRejection {
                _ = try await authenticatedConflict(pending: pending, remote: rejection.current)
                if pending.context.revision > 1, pending.attachments.isEmpty {
                    let payload = try await pendingPayload(pending)
                    guard [.text, .link].contains(payload.kind), payload.attachment == nil else { throw EncryptedMessagingError.unsupportedEdit }
                    if try outbox.retireSupersededEdit(matching: pending.acknowledgement) {
                        superseded += 1; session.releaseSealedAttachment(for: pending.context)
                    } else { blocked += 1 }
                } else { blocked += 1 }
            }
        }
        if superseded > 0 || blocked > 0 {
            throw EncryptedRetryConflictSummary(publishedMessages: published, supersededEdits: superseded, blockedMessages: blocked)
        }
    }
    private func pendingPayload(_ pending: PendingOutboxRecord) async throws -> ConversationMessagePayload {
        try await session.performKeyOperation { try ConversationMessageCipher.open(pending.envelope, expectedContext: pending.context, epochKey: $0) }
    }
    private func flush(_ pending: PendingOutboxRecord) async throws -> EncryptedMessageRecord {
        try session.validate(pending.context)
        let payload = try await pendingPayload(pending)
        try session.requireActive()
        let outcome = try await transport.publishPrepared(pending, deliveryMode: EncryptedMessageNotificationPolicy.deliveryMode(for: payload))
        try session.requireActive()
        let record: EncryptedMessageRecord
        switch outcome {
        case .published(let value): record = value
        case .revisionRejected(let current):
            // Another writer may have published these same exact bytes after our no-write CAS.
            // A fresh server-only identical record meets the original intent without resealing.
            guard !current.hasPendingWrites, current.context == pending.context, current.ciphertext == pending.envelope, current.deletedAt == nil else {
                throw ConfirmedMessageRevisionRejection(current: current)
            }
            record = current
        }
        guard record.context == pending.context, record.ciphertext == pending.envelope, record.deletedAt == nil else { throw EncryptedMessagingError.conflictingRecord }
        _ = try outbox.acknowledge(pending.acknowledgement)
        session.releaseSealedAttachment(for: pending.context)
        return record
    }
    private func authenticatedConflict(pending: PendingOutboxRecord, remote: EncryptedMessageRecord) async throws -> ConversationMessagePayload? {
        try session.validate(remote.context)
        guard remote.context.kind == .message, !remote.hasPendingWrites,
              SecureConversationSession.same(remote.context.senderID, session.capsule.localAccountID),
              SecureConversationSession.same(remote.context.senderID, pending.context.senderID),
              SecureConversationSession.same(remote.context.recordID, pending.context.recordID),
              remote.context.revision >= pending.context.revision else { throw EncryptedMessagingError.untrustedConversation }
        if remote.deletedAt != nil {
            // Deletion is an existing server-authorized public tombstone, not an AEAD message.
            // It establishes unavailability only, never proves delivery of the discarded intent.
            guard remote.ciphertext.isEmpty, remote.context.revision > 1 else { throw EncryptedMessagingError.invalidRecord }
            return nil
        }
        return try await decode(remote)
    }
    private func prepareEdit(base: EncryptedMessageRecord, payload: ConversationMessagePayload, desiredBody: String,
                             replacing: OutboxAcknowledgement? = nil) async throws -> PendingOutboxRecord {
        guard SecureConversationSession.same(base.context.senderID, session.capsule.localAccountID), base.deletedAt == nil,
              [.text, .link].contains(payload.kind), payload.attachment == nil,
              base.context.revision < 9_007_199_254_740_991 else { throw EncryptedMessagingError.unsupportedEdit }
        let context = try session.context(recordID: base.context.recordID, revision: base.context.revision + 1)
        // Change only the explicit body; latest authenticated reply/group/delivery fields win.
        let edited = try ConversationMessagePayload(kind: payload.kind, body: desiredBody, replyToID: payload.replyToID,
            photoGroup: payload.photoGroup, legacyLocation: payload.legacyLocation, deliveryMode: payload.deliveryMode)
        let scope = try scope; let outbox = outbox
        return try await session.performKeyOperation { key in
            let bytes = try ConversationMessageCipher.seal(edited, context: context, epochKey: key)
            if let replacing {
                _ = try outbox.supersedePendingEdit(matching: replacing, with: OutboxEnqueueRequest(envelope: bytes, context: context), epochKey: key)
            } else { _ = try outbox.enqueue(envelope: bytes, context: context, scope: scope, epochKey: key) }
            guard let pending = try outbox.load(scope: scope, recordID: context.recordID, epochKey: key) else { throw EncryptedMessagingError.conflictingRecord }
            return pending
        }
    }

    func editMessage(conversationID: String, messageID: String, body: String) async throws {
        let id = try Self.uuid(messageID).uuidString.lowercased()
        let operation = try begin(conversationID: conversationID, recordID: id); defer { finishOperation(operation) }
        // Validate the desired body before attempting delivery of any older uncertain intent.
        _ = try ConversationMessagePayload(kind: .text, body: body)
        var candidate: PendingOutboxRecord
        if let pending = try await loadPending(id) {
            let payload = try await pendingPayload(pending)
            guard pending.context.revision > 1, [.text, .link].contains(payload.kind), payload.attachment == nil, pending.attachments.isEmpty else { throw EncryptedMessagingError.conflictingRecord }
            candidate = pending
        } else {
            guard let record = try await transport.message(conversationID: conversationID, recordID: id) else { throw EncryptedMessagingError.invalidRecord }
            try session.requireActive()
            guard record.context.recordID.utf8.elementsEqual(id.utf8), !record.hasPendingWrites else { throw EncryptedMessagingError.invalidRecord }
            let payload = try await decode(record)
            guard SecureConversationSession.same(record.context.senderID, session.capsule.localAccountID), [.text, .link].contains(payload.kind) else { throw EncryptedMessagingError.unsupportedEdit }
            if payload.body == body { return }
            candidate = try await prepareEdit(base: record, payload: payload, desiredBody: body)
        }
        var rebased = false
        while true {
            do {
                let published = try await flush(candidate)
                let current = try await pendingPayload(candidate)
                if current.body == body { return }
                // A prior uncertain intent was confirmed. Admit this latest explicit intent only
                // after that exact delivery, instead of resealing while its outcome was unknown.
                candidate = try await prepareEdit(base: published, payload: current, desiredBody: body)
            } catch let rejection as ConfirmedMessageRevisionRejection {
                let latest = try await authenticatedConflict(pending: candidate, remote: rejection.current)
                guard !rebased else { throw EncryptedMessagingError.conflictingRecord }
                guard let latest, [.text, .link].contains(latest.kind), latest.attachment == nil else {
                    guard try outbox.retireSupersededEdit(matching: candidate.acknowledgement) else { throw OutboxError.pendingChanged }
                    throw EncryptedMessagingError.messageNoLongerEditable
                }
                if latest.body == body {
                    guard try outbox.retireSupersededEdit(matching: candidate.acknowledgement) else { throw OutboxError.pendingChanged }
                    return // Desired body is already authenticated remotely; not a local ack.
                }
                candidate = try await prepareEdit(base: rejection.current, payload: latest, desiredBody: body, replacing: candidate.acknowledgement)
                rebased = true
            }
        }
    }

    func unsendMessage(conversationID: String, messageID: String) async throws {
        let id = try Self.uuid(messageID).uuidString.lowercased()
        let operation = try begin(conversationID: conversationID, recordID: id); defer { finishOperation(operation) }
        guard try await loadPending(id) == nil else { throw EncryptedMessagingError.conflictingRecord }
        let context: RecordContext
        if let prepared = preparedUnsend[operation] { context = prepared }
        else {
            guard let record = try await transport.message(conversationID: conversationID, recordID: id) else { throw EncryptedMessagingError.invalidRecord }
            try session.requireActive()
            guard record.context.recordID.utf8.elementsEqual(id.utf8), SecureConversationSession.same(record.context.senderID, session.capsule.localAccountID) else { throw EncryptedMessagingError.untrustedConversation }
            if record.deletedAt != nil { return }
            _ = try await decode(record)
            context = try session.context(recordID: id, revision: record.context.revision + 1)
            preparedUnsend[operation] = context
        }
        _ = try await session.performKeyOperation { _ in true }
        try await transport.unsend(context: context)
        try session.requireActive(); preparedUnsend[operation] = nil
    }

    func setReaction(conversationID: String, messageID: String, userID: String, emoji: String?) async throws {
        try session.requireActive(conversationID: conversationID, accountID: userID)
        let target = try Self.uuid(messageID).uuidString.lowercased()
        let id = try ReactionCipher.recordID(targetMessageID: target, senderID: session.capsule.localAccountID)
        let operation = try begin(conversationID: conversationID, recordID: id); defer { finishOperation(operation) }
        let payload = try ReactionPayload(targetMessageID: target, emoji: emoji)
        let prepared: EncryptedReactionRecord
        if let old = preparedReactions[operation] {
            guard old.1 == payload else { throw EncryptedMessagingError.conflictingRecord }; prepared = old.0
        } else {
            guard let message = try await transport.message(conversationID: conversationID, recordID: target), message.deletedAt == nil else { throw EncryptedMessagingError.invalidRecord }
            try session.requireActive()
            guard message.context.recordID.utf8.elementsEqual(target.utf8) else { throw EncryptedMessagingError.invalidRecord }
            _ = try await decode(message)
            let old = try await transport.reaction(conversationID: conversationID, recordID: id)
            try session.requireActive()
            if let old {
                try session.validate(old.context)
                guard old.context.recordID.utf8.elementsEqual(id.utf8), old.context.senderID.utf8.elementsEqual(session.capsule.localAccountID.utf8) else { throw EncryptedMessagingError.invalidRecord }
                let decoded = try await session.performKeyOperation { try ReactionCipher.open(old.ciphertext, expectedContext: old.context, expectedTargetMessageID: target, epochKey: $0) }
                if decoded == payload { return }
            }
            let context = try session.context(recordID: id, kind: .reaction, revision: (old?.context.revision ?? 0) + 1)
            let bytes = try await session.performKeyOperation { try ReactionCipher.seal(payload, context: context, expectedTargetMessageID: target, epochKey: $0) }
            prepared = EncryptedReactionRecord(context: context, targetMessageID: target, ciphertext: bytes)
            guard preparedReactions.count < 2000 else { throw EncryptedMessagingError.historyLimit }
            preparedReactions[operation] = (prepared, payload)
        }
        _ = try await session.performKeyOperation { _ in true }
        try await transport.publishReaction(prepared)
        try session.requireActive(); preparedReactions[operation] = nil
    }

    func observeTyping(conversationID: String, currentUserID: String, onChange: @escaping (Result<Bool, Error>) -> Void) -> ServiceObservation {
        do { try session.requireActive(conversationID: conversationID, accountID: currentUserID) }
        catch { onChange(.failure(error)); return ServiceObservation() }
        let id = UUID()
        let source = metadata.observeTyping(conversationID: conversationID, currentUserID: currentUserID) { [weak self] result in
            guard let self, (try? self.session.requireActive()) != nil else { return }; onChange(result)
        }
        let observation = ServiceObservation { [weak self] in source.cancel(); self?.observations[id] = nil }
        observations[id] = observation; return observation
    }
    func setTyping(conversationID: String, userID: String, isTyping: Bool) async throws {
        try session.requireActive(conversationID: conversationID, accountID: userID)
        try await metadata.setTyping(conversationID: conversationID, userID: userID, isTyping: isTyping)
        try session.requireActive()
    }
    func markDelivered(conversationID: String, userID: String, messageID: String) async throws {
        try await markDelivered(conversationID: conversationID, userID: userID, messageID: messageID, beforeDispatch: {})
    }
    func markDelivered(conversationID: String, userID: String, messageID: String,
                       beforeDispatch: @MainActor () throws -> Void) async throws {
        let session = session
        try session.requireActive(conversationID: conversationID, accountID: userID)
        try await metadata.markDelivered(conversationID: conversationID, userID: userID, messageID: try Self.uuid(messageID).uuidString.lowercased()) {
            try beforeDispatch()
            try session.requireActive(conversationID: conversationID, accountID: userID)
        }
        try session.requireActive()
    }
    func markRead(conversationID: String, userID: String, messageID: String) async throws {
        try await markRead(conversationID: conversationID, userID: userID, messageID: messageID, beforeDispatch: {})
    }
    func markRead(conversationID: String, userID: String, messageID: String,
                  beforeDispatch: @MainActor () throws -> Void) async throws {
        let session = session
        try session.requireActive(conversationID: conversationID, accountID: userID)
        try await metadata.markRead(conversationID: conversationID, userID: userID, messageID: try Self.uuid(messageID).uuidString.lowercased()) {
            try beforeDispatch()
            try session.requireActive(conversationID: conversationID, accountID: userID)
        }
        try session.requireActive()
    }
    private static func uuid(_ value: String) throws -> UUID {
        guard let id = UUID(uuidString: value), id.uuidString.lowercased() == value.lowercased(), value.utf8.count == 36 else { throw EncryptedMessagingError.invalidRecord }
        return id
    }
}

@MainActor
private final class EncryptedHistoryTaskState {
    var cancelled = false
    var generation = 0
    var task: Task<Void, Never>?
    func isCurrent(_ generation: Int) -> Bool { !cancelled && !Task.isCancelled && self.generation == generation }
    func cancel() { cancelled = true; task?.cancel(); task = nil }
}
