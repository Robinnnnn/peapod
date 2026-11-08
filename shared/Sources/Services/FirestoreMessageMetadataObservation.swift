@preconcurrency import FirebaseFirestore
import Foundation

/// Keeps unchanged query batches alive as the recent-message window moves.
/// Firestore permits at most 30 values in a single `in` query.
struct MessageMetadataQueryPlan {
    struct Batch: Equatable {
        let id: UUID
        let messageIDs: [String]
    }

    private(set) var batches: [Batch] = []

    mutating func update(messageIDs: [String]) {
        let activeIDs = Set(messageIDs)
        batches = batches.compactMap { batch in
            let remaining = batch.messageIDs.filter { activeIDs.contains($0) }
            guard !remaining.isEmpty else { return nil }
            return remaining == batch.messageIDs
                ? batch : Batch(id: UUID(), messageIDs: remaining)
        }
        var assigned = Set(batches.flatMap(\.messageIDs))
        var pending = messageIDs.filter { assigned.insert($0).inserted }
        for index in batches.indices where !pending.isEmpty {
            let batch = batches[index]
            let additions = Array(pending.prefix(30 - batch.messageIDs.count))
            guard !additions.isEmpty else { continue }
            batches[index] = Batch(
                id: UUID(), messageIDs: batch.messageIDs + additions
            )
            pending.removeFirst(additions.count)
        }
        while !pending.isEmpty {
            let ids = Array(pending.prefix(30))
            batches.append(Batch(id: UUID(), messageIDs: ids))
            pending.removeFirst(ids.count)
        }
    }
}

/// Metadata follows the visible history window, rather than downloading every
/// attachment and reaction before the first conversation frame can appear.
@MainActor
final class FirestoreMessageMetadataObservation {
    private let conversation: DocumentReference
    private let bounded: Bool
    private let onPending: () -> Void
    private let onAttachments: ([String: AttachmentContent]) -> Void
    private let onReactions: ([String: [String: String]], Bool) -> Void
    private let onError: (any Error) -> Void
    private var plan = MessageMetadataQueryPlan()
    private var registrations: [UUID: [ListenerRegistration]] = [:]
    private var attachments: [UUID: [String: AttachmentContent]] = [:]
    private var reactions: [UUID: [String: [String: String]]] = [:]
    private var reactionCacheStates: [UUID: Bool] = [:]
    private var cancelled = false
    private var unboundedStarted = false

    init(
        conversation: DocumentReference,
        bounded: Bool,
        onPending: @escaping () -> Void,
        onAttachments: @escaping ([String: AttachmentContent]) -> Void,
        onReactions: @escaping ([String: [String: String]], Bool) -> Void,
        onError: @escaping (any Error) -> Void
    ) {
        self.conversation = conversation
        self.bounded = bounded
        self.onPending = onPending
        self.onAttachments = onAttachments
        self.onReactions = onReactions
        self.onError = onError
    }

    func update(messageIDs: [String]) {
        guard !cancelled else { return }
        if !bounded {
            guard !unboundedStarted else { return }
            unboundedStarted = true
            onPending()
            startBatch(id: UUID(), messageIDs: nil)
            return
        }

        let previous = plan.batches
        plan.update(messageIDs: messageIDs)
        guard plan.batches != previous else {
            if plan.batches.isEmpty { onReactions([:], false) }
            return
        }
        onPending()
        let active = Set(plan.batches.map(\.id))
        for id in Array(registrations.keys) where !active.contains(id) {
            registrations.removeValue(forKey: id)?.forEach { $0.remove() }
            attachments[id] = nil
            reactions[id] = nil
            reactionCacheStates[id] = nil
        }
        for batch in plan.batches where registrations[batch.id] == nil {
            startBatch(id: batch.id, messageIDs: batch.messageIDs)
        }
        publishAttachments()
        publishReactionsIfReady()
    }

    func cancel() {
        cancelled = true
        for listeners in registrations.values {
            listeners.forEach { $0.remove() }
        }
        registrations.removeAll()
        attachments.removeAll()
        reactions.removeAll()
        reactionCacheStates.removeAll()
    }

    private func startBatch(id: UUID, messageIDs: [String]?) {
        var attachmentQuery: Query = conversation.collection("attachments")
        var reactionQuery: Query = conversation.collection("reactions")
        if let messageIDs {
            attachmentQuery = attachmentQuery.whereField("messageId", in: messageIDs)
            reactionQuery = reactionQuery.whereField("messageId", in: messageIDs)
        }
        // Register the token first: queued callbacks from replaced queries must
        // never publish an empty/old reaction baseline into the new window.
        registrations[id] = []
        let attachmentListener = attachmentQuery.addSnapshotListener { [weak self] snapshot, error in
            Task { @MainActor in
                guard let self, !self.cancelled, self.registrations[id] != nil else { return }
                if let error {
                    self.onError(error)
                    return
                }
                self.attachments[id] = snapshot?.documents.reduce(into: [:]) { result, document in
                    let data = document.data()
                    guard
                        let messageID = data["messageId"] as? String,
                        let storagePath = data["storagePath"] as? String,
                        let fileName = data["fileName"] as? String,
                        let contentType = data["contentType"] as? String
                    else { return }
                    let type: AttachmentType
                    if contentType.hasPrefix("image/") { type = .image }
                    else if contentType.hasPrefix("video/") { type = .video }
                    else if contentType.hasPrefix("audio/") { type = .audio }
                    else { type = .file }
                    result[messageID] = AttachmentContent(
                        id: document.documentID,
                        type: type,
                        storagePath: storagePath,
                        fileName: fileName,
                        contentType: contentType,
                        byteSize: (data["byteSize"] as? NSNumber)?.int64Value ?? 0,
                        audioDurationMilliseconds: (data["audioDurationMs"] as? NSNumber)?.intValue
                    )
                } ?? [:]
                self.publishAttachments()
            }
        }
        let reactionListener = reactionQuery.addSnapshotListener(includeMetadataChanges: true) { [weak self] snapshot, error in
            Task { @MainActor in
                guard let self, !self.cancelled, self.registrations[id] != nil else { return }
                if let error {
                    self.onError(error)
                    return
                }
                guard let snapshot else { return }
                self.reactionCacheStates[id] = snapshot.metadata.isFromCache
                self.reactions[id] = snapshot.documents.reduce(into: [:]) { result, document in
                    let data = document.data()
                    guard
                        let messageID = data["messageId"] as? String,
                        let userID = data["userId"] as? String,
                        let emoji = data["emoji"] as? String
                    else { return }
                    result[messageID, default: [:]][userID] = emoji
                }
                self.publishReactionsIfReady()
            }
        }
        registrations[id] = [attachmentListener, reactionListener]
    }

    private func publishAttachments() {
        // Keep hydrated photos in place while a changed batch is being
        // replaced; publishing a partial dictionary flashes placeholders.
        guard registrations.keys.allSatisfy({ attachments[$0] != nil }) else { return }
        onAttachments(attachments.values.reduce(into: [:]) { result, batch in
            result.merge(batch) { _, new in new }
        })
    }

    private func publishReactionsIfReady() {
        guard registrations.keys.allSatisfy({ reactions[$0] != nil }) else { return }
        let isFromCache = registrations.keys.contains {
            reactionCacheStates[$0] != false
        }
        onReactions(
            reactions.values.reduce(into: [:]) { result, batch in
                result.merge(batch) { _, new in new }
            },
            isFromCache
        )
    }
}
