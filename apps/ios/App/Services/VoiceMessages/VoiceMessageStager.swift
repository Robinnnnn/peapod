import Foundation

struct VoiceMessageStager {
    typealias StageOperation = (VoiceMessageDraft) throws -> PendingShare
    typealias EnqueueOperation = ([PendingShare]) throws -> Void
    typealias DiscardOperation = ([PendingShare]) -> Void
    typealias PendingItemsOperation = () throws -> [PendingShare]

    private let stage: StageOperation
    private let enqueue: EnqueueOperation
    private let discard: DiscardOperation
    private let pendingItems: PendingItemsOperation
    private let activeConversationID: () -> String?
    private let removeSource: (URL) throws -> Void
    private let discardPersistedDraft: (VoiceMessageDraft) -> Void

    init(
        draftStore: VoiceMessageDraftStore = VoiceMessageDraftStore(),
        enqueue: EnqueueOperation? = nil,
        pendingItems: PendingItemsOperation? = nil
    ) {
        stage = { draft in
            try PendingShareStore.stageFile(
                from: draft.fileURL,
                kind: .file,
                suggestedName: draft.suggestedFileName,
                contentTypeIdentifier: VoiceMessageDraft.contentTypeIdentifier
            )
        }
        self.enqueue = enqueue ?? PendingShareStore.enqueue
        discard = PendingShareStore.discardStagedFiles
        self.pendingItems = pendingItems ?? PendingShareStore.pendingItems
        activeConversationID = {
            SharedConversationStore.activeConversationID
        }
        removeSource = { try FileManager.default.removeItem(at: $0) }
        discardPersistedDraft = draftStore.remove
    }

    init(
        stage: @escaping StageOperation,
        enqueue: @escaping EnqueueOperation,
        discard: @escaping DiscardOperation = { _ in },
        pendingItems: @escaping PendingItemsOperation = { [] },
        activeConversationID: @escaping () -> String?,
        removeSource: @escaping (URL) throws -> Void = {
            try FileManager.default.removeItem(at: $0)
        },
        discardPersistedDraft: @escaping (VoiceMessageDraft) -> Void = { _ in }
    ) {
        self.stage = stage
        self.enqueue = enqueue
        self.discard = discard
        self.pendingItems = pendingItems
        self.activeConversationID = activeConversationID
        self.removeSource = removeSource
        self.discardPersistedDraft = discardPersistedDraft
    }

    /// Copies the completed recording into the durable App Group outbox.
    ///
    /// The outbox entry is enqueued before the temporary source is deleted, so
    /// a terminated app can retry the upload on its next launch.
    func stageAndEnqueue(_ draft: VoiceMessageDraft) throws -> StagedVoiceMessage {
        guard FileManager.default.fileExists(atPath: draft.fileURL.path) else {
            throw VoiceMessageError.missingRecording
        }
        guard draft.byteSize > 0 else {
            throw VoiceMessageError.emptyRecording
        }
        guard
            let conversationID = PendingShare.normalizedConversationID(
                activeConversationID()
            )
        else {
            throw PendingShareStoreError.missingConversationTarget
        }

        if let queued = try pendingItems().first(where: { $0.id == draft.id }) {
            guard queued.targetConversationID == conversationID else {
                throw PendingShareStoreError.missingConversationTarget
            }
            try? removeSource(draft.fileURL)
            discardPersistedDraft(draft)
            return StagedVoiceMessage(
                pendingShare: queued,
                duration: queued.voiceMessageDuration ?? draft.duration,
                byteSize: draft.byteSize
            )
        }

        let stagedShare = try stage(draft)
        let scopedShare = try stagedShare.scopedToConversation(conversationID)
        let share = PendingShare(
            id: draft.id,
            kind: scopedShare.kind,
            text: scopedShare.text,
            conversationID: conversationID,
            conversationOwnerID: scopedShare.conversationOwnerID,
            localFileName: scopedShare.localFileName,
            originalFileName: scopedShare.originalFileName,
            contentTypeIdentifier: scopedShare.contentTypeIdentifier,
            createdAt: draft.createdAt
        ).markingAsVoiceMessage(
            duration: draft.duration
        )
        do {
            try enqueue([share])
        } catch {
            discard([share])
            throw error
        }

        try? removeSource(draft.fileURL)
        discardPersistedDraft(draft)
        return StagedVoiceMessage(
            pendingShare: share,
            duration: draft.duration,
            byteSize: draft.byteSize
        )
    }
}
