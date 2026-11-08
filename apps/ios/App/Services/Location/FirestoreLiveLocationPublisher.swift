@preconcurrency import FirebaseFirestore
import Foundation

enum LiveLocationRemoteCleanupPolicy {
    static func deletesPreciseLocation(
        after reason: LiveLocationStopReason
    ) -> Bool {
        switch reason {
        case .stoppedByUser,
             .expired,
             .authorizationDenied,
             .locationUnavailable:
            true
        }
    }
}

final class FirestoreLiveLocationPublisher: LiveLocationPublishing, @unchecked Sendable {
    private let document: DocumentReference
    private let conversationID: String
    private let userID: String

    init(
        conversationID: String,
        userID: String,
        database: Firestore = Firestore.firestore()
    ) {
        self.conversationID = conversationID; self.userID = userID
        document = database
            .collection("conversations")
            .document(conversationID)
            .collection("locations")
            .document(userID)
    }

    @MainActor func publishLatest(
        _ point: LiveLocationPoint,
        for session: LiveLocationSession
    ) async throws {
        try LegacyContentWriteGuard.require(conversationID: conversationID, accountID: userID)
        let data: [String: Any] = [
            "userId": document.documentID,
            "latitude": point.latitude,
            "longitude": point.longitude,
            "horizontalAccuracy": point.horizontalAccuracy,
            "recordedAt": Timestamp(date: point.recordedAt),
            "updatedAt": FieldValue.serverTimestamp(),
        ]
        try await document.setData(data)
    }

    func finish(
        _ session: LiveLocationSession,
        reason: LiveLocationStopReason
    ) async {
        if LiveLocationRemoteCleanupPolicy.deletesPreciseLocation(after: reason) {
            try? await document.delete()
        }
    }
}
