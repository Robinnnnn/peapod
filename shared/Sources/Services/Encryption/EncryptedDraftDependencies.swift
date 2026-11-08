import Foundation

/// Local endpoint draft persistence is separate from encrypted cloud transport. The default
/// retains production App Group behavior; explicit test composition never touches that queue.
@MainActor
struct EncryptedDraftDependencies {
    let enqueue: ([PendingShare], String, String) throws -> Void
    let load: (String) throws -> [PendingShare]
    let acknowledge: (Set<UUID>, String) throws -> Void
    static let native = Self(enqueue: {
        try PendingShareStore.enqueueProtectedDrafts($0, accountID: $1, conversationID: $2)
    }, load: { try PendingShareStore.pendingItems(for: $0) }, acknowledge: {
        _ = try PendingShareStore.acknowledgeProcessed($0, accountID: $1)
    })
}
