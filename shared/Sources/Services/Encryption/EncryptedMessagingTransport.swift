import Foundation
import MinesE2EE

struct EncryptedMessageRecord: Sendable {
    let context: RecordContext
    let ciphertext: Data
    let createdAt: Date
    let editedAt: Date?
    let deletedAt: Date?
    let hasPendingWrites: Bool
}
/// Rejection means the transaction definitely performed no write. The current record is still
/// untrusted ciphertext until the service authenticates it. Timeouts/read errors never use it.
enum EncryptedMessagePublishOutcome: Sendable {
    case published(EncryptedMessageRecord)
    case revisionRejected(EncryptedMessageRecord)
}

struct EncryptedReactionRecord: Sendable {
    let context: RecordContext
    let targetMessageID: String
    let ciphertext: Data
}
struct EncryptedHistoryRecords: Sendable {
    let messages: [EncryptedMessageRecord]
    let reactions: [EncryptedReactionRecord]
    let receipts: [String: MessageReceipt]
    let isFromCache: Bool
    let reactionsAreFromCache: Bool
}

/// Contains only opaque ciphertext and validated routing metadata. Implementations must preserve
/// prepared bytes during transaction retries and never store decrypted fields in public documents.
@MainActor
protocol EncryptedMessagingTransport: AnyObject {
    func observeHistory(conversationID: String, limit: Int,
                        onChange: @escaping (Result<EncryptedHistoryRecords, Error>) -> Void) -> ServiceObservation
    func observeWindow(conversationID: String, request: MessageHistoryWindowRequest,
                       onChange: @escaping (Result<EncryptedHistoryWindowRecords, Error>) -> Void) -> ServiceObservation
    func observeMessagesByID(conversationID: String, messageIDs: [String],
                             onChange: @escaping (Result<EncryptedHistoryRecords, Error>) -> Void) -> ServiceObservation
    func historyPage(conversationID: String, before: MessageHistoryCursor?, count: Int) async throws -> EncryptedHistoryPageRecords
    func message(conversationID: String, recordID: String) async throws -> EncryptedMessageRecord?
    func publish(_ pending: PendingOutboxRecord, deliveryMode: ContentDeliveryMode) async throws -> EncryptedMessageRecord
    func publishPrepared(_ pending: PendingOutboxRecord, deliveryMode: ContentDeliveryMode) async throws -> EncryptedMessagePublishOutcome
    func unsend(context: RecordContext) async throws
    func reaction(conversationID: String, recordID: String) async throws -> EncryptedReactionRecord?
    func publishReaction(_ record: EncryptedReactionRecord) async throws
}

struct EncryptedHistoryWindowRecords: Sendable {
    let records: EncryptedHistoryRecords
    let positions: [String: MessageHistoryCursor]
    let hasOlder: Bool
    let hasNewer: Bool
    let isRecentWindow: Bool
}
struct EncryptedHistoryPageRecords: Sendable {
    let messages: [EncryptedMessageRecord]
    let positions: [String: MessageHistoryCursor]
    let hasOlder: Bool
}

extension EncryptedMessagingTransport {
    func observeMessagesByID(conversationID: String, messageIDs: [String],
                             onChange: @escaping (Result<EncryptedHistoryRecords, Error>) -> Void) -> ServiceObservation {
        onChange(.failure(EncryptedMessagingError.historyLimit)); return ServiceObservation()
    }
    func publishPrepared(_ pending: PendingOutboxRecord, deliveryMode: ContentDeliveryMode) async throws -> EncryptedMessagePublishOutcome {
        .published(try await publish(pending, deliveryMode: deliveryMode))
    }
    // Existing focused test transports remain valid; window tests implement these explicitly.
    func observeWindow(conversationID: String, request: MessageHistoryWindowRequest,
                       onChange: @escaping (Result<EncryptedHistoryWindowRecords, Error>) -> Void) -> ServiceObservation {
        onChange(.failure(EncryptedMessagingError.historyLimit)); return ServiceObservation()
    }
    func historyPage(conversationID: String, before: MessageHistoryCursor?, count: Int) async throws -> EncryptedHistoryPageRecords {
        throw EncryptedMessagingError.historyLimit
    }
}
