import Foundation

/// Prepares one voice attachment for the existing durable PendingShare outbox.
/// This is an atomic handoff policy, not another upload or network-delivery queue.
@MainActor
struct MacVoiceMessageHandoff {
    let scope: MacVoiceMessageDraftStore.Scope
    let isCurrent: () -> Bool
    let stage: (VoiceMessageDraft) throws -> PendingShare
    let pendingItems: () throws -> [PendingShare]
    let enqueue: ([PendingShare]) throws -> Void
    let discard: ([PendingShare]) -> Void

    func stageAndEnqueue(_ draft: VoiceMessageDraft) throws -> PendingShare {
        guard isCurrent() else { throw PendingShareStoreError.accountMismatch }
        if let existing = try pendingItems().first(where: { $0.id == draft.id }) {
            try validate(existing)
            guard existing.isVoiceMessage, isCurrent() else { throw PendingShareStoreError.accountMismatch }
            return existing
        }
        let staged = try stage(draft)
        do {
            try validate(staged)
            let share = PendingShare(id: draft.id, kind: staged.kind, text: nil,
                conversationID: scope.conversationID, conversationOwnerID: scope.accountID,
                localFileName: staged.localFileName, originalFileName: staged.originalFileName,
                contentTypeIdentifier: staged.contentTypeIdentifier, createdAt: draft.createdAt)
                .markingAsVoiceMessage(duration: draft.duration)
            guard isCurrent() else { throw PendingShareStoreError.accountMismatch }
            try enqueue([share])
            return share
        } catch {
            discard([staged])
            throw error
        }
    }

    private func validate(_ share: PendingShare) throws {
        try AttachmentDraftDependencies.validateProvenance(share, accountID: scope.accountID,
            conversationID: scope.conversationID, requiresBound: true)
    }
}
