@preconcurrency import FirebaseFirestore
import Foundation

@MainActor
protocol ConnectionLocationProviding: AnyObject {
    /// Production providers require Core Location before sharing can be
    /// enabled. Local and demo providers synthesize deterministic points.
    var requiresDeviceLocation: Bool { get }

    func observe(
        conversationID: String,
        onChange: @escaping (
            Result<ConnectionLocationSnapshot, any Error>
        ) -> Void
    ) -> ServiceObservation

    func setSharingEnabled(
        _ isEnabled: Bool,
        conversationID: String,
        userID: String
    ) async throws
}

@MainActor
final class LocalConnectionLocationService: ConnectionLocationProviding {
    let requiresDeviceLocation = false

    private var snapshot = ConnectionLocationSnapshot.empty
    private var observers:
        [UUID: (Result<ConnectionLocationSnapshot, any Error>) -> Void] = [:]

    func observe(
        conversationID: String,
        onChange: @escaping (
            Result<ConnectionLocationSnapshot, any Error>
        ) -> Void
    ) -> ServiceObservation {
        let identifier = UUID()
        observers[identifier] = onChange
        onChange(.success(snapshot))
        return ServiceObservation { [weak self] in
            self?.observers[identifier] = nil
        }
    }

    func setSharingEnabled(
        _ isEnabled: Bool,
        conversationID: String,
        userID: String
    ) async throws {
        if isEnabled {
            snapshot.sharingUserIDs.insert(userID)
        } else {
            snapshot.sharingUserIDs.remove(userID)
            snapshot.latestPoints[userID] = nil
        }
        emit()
    }

    private func emit() {
        for observer in observers.values {
            observer(.success(snapshot))
        }
    }
}


@MainActor
final class FirestoreConnectionLocationService:
    ConnectionLocationProviding
{
    let requiresDeviceLocation = true
    private let database: Firestore

    init(database: Firestore = Firestore.firestore()) {
        self.database = database
    }

    func observe(
        conversationID: String,
        onChange: @escaping (
            Result<ConnectionLocationSnapshot, any Error>
        ) -> Void
    ) -> ServiceObservation {
        let observation = ConnectionLocationObservation(onChange: onChange)
        let conversation = database
            .collection("conversations")
            .document(conversationID)

        let sharingRegistration = conversation
            .collection("locationSharing")
            .addSnapshotListener { snapshot, error in
                Task { @MainActor in
                    if let error {
                        onChange(.failure(error))
                        return
                    }
                    let sharingUserIDs = Set(
                        snapshot?.documents.compactMap { document in
                            document.data()["isSharing"] as? Bool == true
                                ? document.documentID
                                : nil
                        } ?? []
                    )
                    observation.update(sharingUserIDs: sharingUserIDs)
                }
            }

        let pointRegistration = conversation
            .collection("locations")
            .addSnapshotListener { snapshot, error in
                Task { @MainActor in
                    if let error {
                        onChange(.failure(error))
                        return
                    }
                    let points = snapshot?.documents.reduce(
                        into: [String: LiveLocationPoint]()
                    ) { result, document in
                        let data = document.data()
                        guard
                            let latitude = data["latitude"] as? Double,
                            let longitude = data["longitude"] as? Double,
                            let accuracy =
                                data["horizontalAccuracy"] as? Double
                        else {
                            return
                        }
                        result[document.documentID] = LiveLocationPoint(
                            latitude: latitude,
                            longitude: longitude,
                            horizontalAccuracy: accuracy,
                            recordedAt:
                                (
                                    data["recordedAt"] as? Timestamp
                                    ?? data["updatedAt"] as? Timestamp
                                )?.dateValue() ?? .now
                        )
                    } ?? [:]
                    observation.update(points: points)
                }
            }

        return ServiceObservation {
            sharingRegistration.remove()
            pointRegistration.remove()
        }
    }

    func setSharingEnabled(
        _ isEnabled: Bool,
        conversationID: String,
        userID: String
    ) async throws {
        let conversation = database
            .collection("conversations")
            .document(conversationID)
        let sharing = conversation
            .collection("locationSharing")
            .document(userID)
        let point = conversation.collection("locations").document(userID)

        let batch = database.batch()
        batch.setData(
            [
                "userId": userID,
                "isSharing": isEnabled,
                "updatedAt": FieldValue.serverTimestamp(),
            ],
            forDocument: sharing
        )
        if !isEnabled {
            batch.deleteDocument(point)
        }
        try await batch.commit()
    }
}

@MainActor
private final class ConnectionLocationObservation {
    private var sharingUserIDs: Set<String> = []
    private var points: [String: LiveLocationPoint] = [:]
    private var hasSharingSnapshot = false
    private var hasPointSnapshot = false
    private let onChange: (
        Result<ConnectionLocationSnapshot, any Error>
    ) -> Void

    init(
        onChange: @escaping (
            Result<ConnectionLocationSnapshot, any Error>
        ) -> Void
    ) {
        self.onChange = onChange
    }

    func update(sharingUserIDs: Set<String>) {
        self.sharingUserIDs = sharingUserIDs
        hasSharingSnapshot = true
        emit()
    }

    func update(points: [String: LiveLocationPoint]) {
        self.points = points
        hasPointSnapshot = true
        emit()
    }

    private func emit() {
        guard hasSharingSnapshot, hasPointSnapshot else { return }
        onChange(
            .success(
                ConnectionLocationSnapshot(
                    sharingUserIDs: sharingUserIDs,
                    latestPoints: points
                )
            )
        )
    }
}
