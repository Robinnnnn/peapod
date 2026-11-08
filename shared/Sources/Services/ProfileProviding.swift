@preconcurrency import FirebaseFirestore
import Foundation
#if canImport(UIKit)
import UIKit
#endif

@MainActor
protocol ProfileProviding: AnyObject {
    func saveProfile(_ person: Person) async throws
    func saveDeviceToken(_ token: String, userID: String) async throws
    func removeDeviceRegistration(userID: String) async throws

    func observeConversationID(
        for userID: String,
        onChange: @escaping (Result<String?, any Error>) -> Void
    ) -> ServiceObservation

    func fetchPartner(
        conversationID: String,
        currentUserID: String
    ) async throws -> Person
}

@MainActor
final class LocalProfileService: ProfileProviding {
    func saveProfile(_ person: Person) async throws {}
    func saveDeviceToken(_ token: String, userID: String) async throws {}
    func removeDeviceRegistration(userID: String) async throws {}

    func observeConversationID(
        for userID: String,
        onChange: @escaping (Result<String?, any Error>) -> Void
    ) -> ServiceObservation {
        ServiceObservation()
    }

    func fetchPartner(
        conversationID: String,
        currentUserID: String
    ) async throws -> Person {
        Person(id: "partner", displayName: "Your person", initials: "YP")
    }
}

@MainActor
final class FirebaseProfileService: ProfileProviding {
    private let database: Firestore

    init(database: Firestore = Firestore.firestore()) {
        self.database = database
    }

    func saveProfile(_ person: Person) async throws {
        let reference = database.collection("users").document(person.id)
        let snapshot = try await reference.getDocument()

        if snapshot.exists {
            try await reference.setData(
                [
                    "displayName": person.displayName,
                    "updatedAt": FieldValue.serverTimestamp(),
                ],
                merge: true
            )
        } else {
            try await reference.setData([
                "displayName": person.displayName,
                "createdAt": FieldValue.serverTimestamp(),
            ])
        }
    }

    func saveDeviceToken(_ token: String, userID: String) async throws {
        let reference = database
            .collection("users")
            .document(userID)
            .collection("devices")
            .document(DeviceIdentity.identifier)
        let snapshot = try await reference.getDocument()

        var data: [String: Any] = [
            "token": token,
            "platform": DeviceIdentity.platform.rawValue,
            "updatedAt": FieldValue.serverTimestamp(),
        ]
        if !snapshot.exists {
            data["createdAt"] = FieldValue.serverTimestamp()
        }
        try await reference.setData(data, merge: snapshot.exists)
    }

    func removeDeviceRegistration(userID: String) async throws {
        try await database
            .collection("users")
            .document(userID)
            .collection("devices")
            .document(DeviceIdentity.identifier)
            .delete()
    }

    func observeConversationID(
        for userID: String,
        onChange: @escaping (Result<String?, any Error>) -> Void
    ) -> ServiceObservation {
        let registration = database
            .collection("users")
            .document(userID)
            .addSnapshotListener(includeMetadataChanges: true) { snapshot, error in
                Task { @MainActor in
                    if let error {
                        onChange(.failure(error))
                        return
                    }

                    // A missing local document only means this account has
                    // not been cached yet. Wait for the server before
                    // treating that as an absent/deleted assignment.
                    guard let snapshot else { return }
                    if snapshot.metadata.isFromCache, !snapshot.exists {
                        return
                    }

                    let conversationID = snapshot
                        .data()?["activeConversationId"] as? String
                    onChange(.success(conversationID))
                }
            }

        return ServiceObservation {
            registration.remove()
        }
    }

    func fetchPartner(
        conversationID: String,
        currentUserID: String
    ) async throws -> Person {
        let conversation = try await database
            .collection("conversations")
            .document(conversationID)
            .getDocument()

        guard
            let members = conversation.data()?["members"] as? [String],
            let partnerID = members.first(where: { $0 != currentUserID })
        else {
            throw ProfileError.partnerNotFound
        }

        let partner = try await database
            .collection("users")
            .document(partnerID)
            .getDocument()
        return try PartnerProfileIdentity.resolvedPerson(
            id: partnerID, displayName: partner.data()?["displayName"] as? String
        )
    }
}

enum PartnerProfileIdentity {
    static func resolvedPerson(id: String, displayName: String?) throws -> Person {
        guard let displayName,
              !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProfileError.partnerNotFound
        }
        return Person(id: id, displayName: displayName, initials: Person.initials(for: displayName))
    }
}

extension ProfileProviding {
    func removeDeviceRegistration(userID: String) async throws {}
}

@MainActor
private enum DeviceIdentity {
    private static let defaultsKey = "mines.device-identity"

    static var platform: ClientPlatform {
#if os(macOS)
        .macOS
#else
        .iOS
#endif
    }

    static var identifier: String {
#if canImport(UIKit)
        if let vendorID = UIDevice.current.identifierForVendor?.uuidString {
            return vendorID
        }
#endif
        if let saved = UserDefaults.standard.string(forKey: defaultsKey) {
            return saved
        }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: defaultsKey)
        return created
    }
}

enum ProfileError: LocalizedError {
    case partnerNotFound

    var errorDescription: String? {
        "The other person in this conversation could not be found."
    }
}
