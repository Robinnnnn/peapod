import Foundation

/// A routing position, not authenticated creation time or proof of complete cloud history.
/// Scope prevents accidental reuse across accounts/conversations. UUID breaks timestamp ties.
struct MessageHistoryCursor: Equatable, Sendable {
    let accountID: String
    let conversationID: String
    let keyEpoch: UInt32
    let seconds: Int64
    let nanoseconds: Int32
    let messageID: String
    init(accountID: String, conversationID: String, keyEpoch: UInt32, seconds: Int64,
         nanoseconds: Int32, messageID: String) throws {
        guard !accountID.isEmpty, accountID.utf8.count <= 256,
              !conversationID.isEmpty, conversationID.utf8.count <= 512, keyEpoch > 0,
              seconds >= 0, seconds <= 253_402_300_799, (0..<1_000_000_000).contains(nanoseconds),
              let uuid = UUID(uuidString: messageID), uuid.uuidString.lowercased() == messageID else {
            throw EncryptedMessagingError.invalidRecord
        }
        self.accountID = accountID; self.conversationID = conversationID; self.keyEpoch = keyEpoch
        self.seconds = seconds; self.nanoseconds = nanoseconds; self.messageID = messageID
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.accountID.utf8.elementsEqual(rhs.accountID.utf8) && lhs.conversationID.utf8.elementsEqual(rhs.conversationID.utf8)
            && lhs.keyEpoch == rhs.keyEpoch && lhs.seconds == rhs.seconds && lhs.nanoseconds == rhs.nanoseconds
            && lhs.messageID.utf8.elementsEqual(rhs.messageID.utf8)
    }
}

enum MessageHistoryWindowRequest: Sendable {
    case recent(count: Int = 100)
    case before(MessageHistoryCursor, count: Int = 300)
    case after(MessageHistoryCursor, count: Int = 300)
    case around(messageID: UUID, count: Int = 300)
    var count: Int {
        switch self { case .recent(let n), .before(_, let n), .after(_, let n), .around(_, let n): return n }
    }
}

struct MessageHistoryWindowSnapshot {
    let history: MessageHistorySnapshot
    /// One cursor per visible record; includes tombstones. Never construct it from Date precision.
    let positions: [UUID: MessageHistoryCursor]
    let hasOlder: Bool
    let hasNewer: Bool
    let isRecentWindow: Bool
    var oldest: MessageHistoryCursor? { history.messages.first.flatMap { positions[$0.id] } }
    var newest: MessageHistoryCursor? { history.messages.last.flatMap { positions[$0.id] } }
    /// Slide by 100 while retaining up to 200 overlapping rows, so a scroll anchor can survive.
    var olderRequest: MessageHistoryWindowRequest? {
        guard hasOlder, !history.messages.isEmpty else { return nil }
        if isRecentWindow, history.messages.count < MessageHistoryBounds.windowSize {
            return .recent(count: min(MessageHistoryBounds.windowSize, history.messages.count + MessageHistoryBounds.pageSize))
        }
        let index = max(0, history.messages.count - MessageHistoryBounds.pageSize)
        guard let cursor = positions[history.messages[index].id] else { return nil }
        return .before(cursor, count: MessageHistoryBounds.windowSize)
    }
    var newerRequest: MessageHistoryWindowRequest? {
        guard hasNewer, !history.messages.isEmpty else { return nil }
        let index = min(MessageHistoryBounds.pageSize - 1, history.messages.count - 1)
        guard let cursor = positions[history.messages[index].id] else { return nil }
        return .after(cursor, count: MessageHistoryBounds.windowSize)
    }
}

struct MessageHistorySearchContinuation: Sendable {
    let cursor: MessageHistoryCursor
    /// Exact trimmed UTF8 query, bound to this continuation. Local transient state only.
    let queryBytes: Data
}
struct MessageHistorySearchSnapshot {
    let messages: [ChatMessage]
    let scannedCount: Int
    let isComplete: Bool
    /// Non-nil when the bounded result page fills; caller can load the next result page.
    let continuation: MessageHistorySearchContinuation?
}
enum MessageHistoryBounds {
    static let pageSize = 100
    static let windowSize = 300
    static let searchResults = 100
    static let queryBytes = 512
}

@MainActor
protocol MessageHistoryWindowProviding: MessagingProviding {
    /// Router returns false for legacy/demo providers; their existing API remains available.
    func supportsHistoryWindows(conversationID: String) throws -> Bool
    func observeHistoryWindow(conversationID: String, currentUserID: String, request: MessageHistoryWindowRequest,
                              onChange: @escaping (Result<MessageHistoryWindowSnapshot, Error>) -> Void) -> ServiceObservation
    /// Streams one bounded result page while scanning older encrypted pages locally. A full result
    /// page has a continuation unless the server page ends there; no silent truncation or unbounded retained plaintext.
    func searchHistory(conversationID: String, currentUserID: String, query: String,
                       continuation: MessageHistorySearchContinuation?,
                       onChange: @escaping (Result<MessageHistorySearchSnapshot, Error>) -> Void) -> ServiceObservation
}
