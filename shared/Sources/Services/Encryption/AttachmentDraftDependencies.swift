import Foundation

/// Endpoint staging is independently injectable from cloud encryption and queue persistence.
/// Closures are not evaluated when native defaults are constructed.
@MainActor
struct AttachmentDraftDependencies {
    struct DataInput { let bytes: Data; let kind: PendingShare.Kind; let suggestedName: String?; let preferredExtension: String?; let contentTypeIdentifier: String? }
    struct FileInput { let url: URL; let kind: PendingShare.Kind; let suggestedName: String?; let contentTypeIdentifier: String? }
    let stageData: (DataInput, SecureConversationResetTarget) throws -> PendingShare
    let stageFile: (FileInput, SecureConversationResetTarget) throws -> PendingShare
    let resolve: (PendingShare) throws -> URL
    let discard: ([PendingShare]) -> Void
    static func validateProvenance(_ share: PendingShare, accountID: String, conversationID: String, requiresBound: Bool) throws {
        if let original = share.targetConversationID, !original.utf8.elementsEqual(conversationID.utf8) { throw PendingShareStoreError.accountMismatch }
        if let original = share.conversationOwnerID, !original.utf8.elementsEqual(accountID.utf8) { throw PendingShareStoreError.accountMismatch }
        if requiresBound, share.targetConversationID == nil || share.conversationOwnerID == nil { throw PendingShareStoreError.accountMismatch }
    }
    static let native = Self(stageData: { input, _ in
        try PendingShareStore.stageData(input.bytes, kind: input.kind, suggestedName: input.suggestedName,
            preferredExtension: input.preferredExtension, contentTypeIdentifier: input.contentTypeIdentifier)
    }, stageFile: { input, _ in
        try PendingShareStore.stageFile(from: input.url, kind: input.kind, suggestedName: input.suggestedName,
            contentTypeIdentifier: input.contentTypeIdentifier)
    }, resolve: PendingShareStore.stagedFileURL, discard: PendingShareStore.discardStagedFiles)
}
