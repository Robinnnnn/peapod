@preconcurrency import FirebaseFirestore
import Foundation

/// Shared conversation metadata only. Message bodies and attachment descriptors never enter this collection.
@MainActor
enum FirestoreMessagePins {
    static func observe(database: Firestore, conversationID: String,
                        onChange: @escaping (Result<[UUID], Error>) -> Void) -> ServiceObservation {
        let state = FirestoreMessagePinsObservation()
        let registration = database.collection("conversations").document(conversationID)
            .collection("pins").order(by: "pinnedAt", descending: true)
            .addSnapshotListener(includeMetadataChanges: true) { snapshot, error in
                Task { @MainActor in
                    guard !state.cancelled else { return }
                    do {
                        if let error { throw error }
                        guard let snapshot else { return }
                        var ids: [UUID] = []
                        for document in snapshot.documents {
                            let data = document.data(with: .estimate)
                            guard Set(data.keys) == ["messageId", "pinnedBy", "pinnedAt"],
                                  data["messageId"] as? String == document.documentID,
                                  let id = UUID(uuidString: document.documentID),
                                  let actor = data["pinnedBy"] as? String, !actor.isEmpty,
                                  data["pinnedAt"] is Timestamp else { throw MessagePinningError.invalidPage }
                            ids.append(id)
                        }
                        guard Set(ids).count == ids.count else { throw MessagePinningError.invalidPage }
                        onChange(.success(ids))
                    } catch { onChange(.failure(error)) }
                }
            }
        return ServiceObservation { state.cancelled = true; registration.remove() }
    }

    static func set(_ pinned: Bool, database: Firestore, conversationID: String,
                    messageID: UUID, currentUserID: String) async throws {
        let conversation = database.collection("conversations").document(conversationID)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            database.runTransaction({ transaction, errorPointer in
                do {
                    let routing = try transaction.getDocument(conversation).data() ?? [:]
                    guard (routing["status"] as? String ?? "active") == "active",
                          let members = routing["members"] as? [String], members.contains(currentUserID) else {
                        throw MessagePinningError.unavailable
                    }
                    // Retained plaintext messages use UUID.uuidString; encrypted records require lowercase UUIDs.
                    let id = routing["encryption"] as? String == "mines-e2ee-v1"
                        ? messageID.uuidString.lowercased() : messageID.uuidString
                    let pin = conversation.collection("pins").document(id)
                    if pinned {
                        let target = try transaction.getDocument(conversation.collection("messages").document(id))
                        let existing = try transaction.getDocument(pin)
                        guard let data = target.data(), data["deletedAt"] == nil || data["deletedAt"] is NSNull else {
                            throw MessagePinningError.unavailable
                        }
                        // A repeat from either participant preserves the original actor and timestamp.
                        if !existing.exists {
                            transaction.setData(["messageId": id, "pinnedBy": currentUserID,
                                                 "pinnedAt": FieldValue.serverTimestamp()], forDocument: pin)
                        }
                    } else {
                        transaction.deleteDocument(pin)
                    }
                    return true
                } catch { errorPointer?.pointee = error as NSError; return nil }
            }) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}

@MainActor
private final class FirestoreMessagePinsObservation {
    var cancelled = false
}
