@preconcurrency import FirebaseFirestore
import Foundation

enum ConversationReplyContext {
    static func missingTargetIDs(in messages: [ChatMessage]) -> [String] {
        var known = Set(messages.map(\.id))
        return messages.compactMap { message in
            guard let target = message.replyToID, known.insert(target).inserted else {
                return nil
            }
            return target.uuidString
        }
    }
}

/// A recent reply can quote an older message without loading all intervening
/// history. There is at most one extra target per message in the live window.
@MainActor
final class FirestoreReplyContextObservation {
    private let collection: CollectionReference
    private let decode: (QueryDocumentSnapshot) -> ChatMessage?
    private let onChange: ([UUID: ChatMessage]) -> Void
    private let onError: (any Error) -> Void
    private var plan = MessageMetadataQueryPlan()
    private var registrations: [UUID: ListenerRegistration] = [:]
    private var contexts: [UUID: [UUID: ChatMessage]] = [:]
    private var cancelled = false

    init(
        collection: CollectionReference,
        decode: @escaping (QueryDocumentSnapshot) -> ChatMessage?,
        onChange: @escaping ([UUID: ChatMessage]) -> Void,
        onError: @escaping (any Error) -> Void
    ) {
        self.collection = collection
        self.decode = decode
        self.onChange = onChange
        self.onError = onError
    }

    func update(messages: [ChatMessage]) {
        guard !cancelled else { return }
        let previous = plan.batches
        plan.update(messageIDs: ConversationReplyContext.missingTargetIDs(in: messages))
        guard previous != plan.batches else { return }
        let active = Set(plan.batches.map(\.id))
        for id in Array(registrations.keys) where !active.contains(id) {
            registrations.removeValue(forKey: id)?.remove()
            contexts[id] = nil
        }
        for batch in plan.batches where registrations[batch.id] == nil {
            registrations[batch.id] = collection
                .whereField(FieldPath.documentID(), in: batch.messageIDs)
                .addSnapshotListener { [weak self] snapshot, error in
                    Task { @MainActor in
                        guard let self, !self.cancelled,
                            self.registrations[batch.id] != nil else { return }
                        if let error {
                            self.onError(error)
                            return
                        }
                        let messages = snapshot?.documents.compactMap(self.decode) ?? []
                        self.contexts[batch.id] = Dictionary(
                            messages.map { ($0.id, $0) },
                            uniquingKeysWith: { _, latest in latest }
                        )
                        self.publish()
                    }
                }
        }
        publish()
    }

    func cancel() {
        cancelled = true
        registrations.values.forEach { $0.remove() }
        registrations.removeAll()
        contexts.removeAll()
    }

    private func publish() {
        onChange(contexts.values.reduce(into: [:]) { result, batch in
            result.merge(batch) { _, latest in latest }
        })
    }
}
