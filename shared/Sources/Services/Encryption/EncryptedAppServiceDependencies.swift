@preconcurrency import FirebaseAuth
@preconcurrency import FirebaseFirestore
import Foundation
import MinesE2EE

/// Raw server projections remain untrusted: EncryptedAppServices validates them.
struct EncryptedConversationUpdate {
    let data: [String: Any]?
    let isFromCache: Bool
}

@MainActor
struct EncryptedAccountResources {
    let pairingClient: SecurePairingClient?
    let readCapsule: @MainActor (KeyScope) async throws -> StoredConversationCapsule?
    let makeSession: @MainActor (StoredConversationCapsule, @escaping @MainActor () -> Bool) -> SecureConversationSession
    let confirmPending: @MainActor (StoredConversationCapsule, [String: Any], @escaping @MainActor () -> Bool) async throws -> Void
    let invalidate: @MainActor () -> Void
}

@MainActor
struct EncryptedContentResources {
    let messages: EncryptedMessagingService
    let attachments: EncryptedAttachmentService
    let resolver: EncryptedAttachmentResolver
    let locations: EncryptedLocationService?
}

/// Internal composition seam. Production uses native(); tests must provide every
/// boundary explicitly, including protected state, and never initialize Firebase defaults.
@MainActor
struct EncryptedAppServiceDependencies {
    let currentUID: @MainActor () -> String?
    let rootDirectory: @MainActor () throws -> URL
    let sharedState: @MainActor () throws -> SharedConversationStateStore
    let readProfile: @MainActor (String) async throws -> [String: Any]?
    let readConversation: @MainActor (String) async throws -> [String: Any]?
    let observeConversation: @MainActor (String, @escaping @MainActor (Result<EncryptedConversationUpdate, Error>) -> Void) -> ServiceObservation
    let observeAuth: @MainActor (@escaping @MainActor (String?) -> Void) -> ServiceObservation
    let makeAccount: @MainActor (String, URL, @escaping @MainActor () -> Bool) throws -> EncryptedAccountResources
    let makeContent: @MainActor (SecureConversationSession, DurableCiphertextOutbox, URL, any MessagingProviding) throws -> EncryptedContentResources
    let sweepMedia: @MainActor () throws -> Void
    let developmentPairingEnabled: Bool

    static func native(auth: Auth, database: Firestore) -> Self {
        Self(currentUID: { auth.currentUser?.uid }, rootDirectory: {
            guard let directory = AppGroup.containerURL else { throw EncryptedMessagingError.inactiveSession }
            return directory.appendingPathComponent("E2EE", isDirectory: true)
        }, sharedState: {
            guard let directory = AppGroup.containerURL else { throw PendingShareStoreError.appGroupUnavailable }
            return SharedConversationStateStore(rootDirectory: directory.appendingPathComponent("E2EE/SharedState", isDirectory: true),
                                                defaults: UserDefaults(suiteName: AppGroup.identifier))
        }, readProfile: { id in
            try await database.collection("users").document(id).getDocument(source: .server).data()
        }, readConversation: { id in
            try await database.collection("conversations").document(id).getDocument(source: .server).data()
        }, observeConversation: { id, callback in
            let registration = database.collection("conversations").document(id).addSnapshotListener { snapshot, error in
                Task { @MainActor in
                    if let error { callback(.failure(error)) }
                    else if let snapshot { callback(.success(EncryptedConversationUpdate(data: snapshot.data(), isFromCache: snapshot.metadata.isFromCache))) }
                }
            }
            return ServiceObservation { registration.remove() }
        }, observeAuth: { callback in
            let handle = auth.addStateDidChangeListener { _, user in
                // Preserve the event identity before hopping actors: currentUser may
                // already have switched away and back by the time the task executes.
                let observedUID = user?.uid
                Task { @MainActor in callback(observedUID) }
            }
            return ServiceObservation { auth.removeStateDidChangeListener(handle) }
        }, makeAccount: { id, root, current in
            let namespace = try ConversationKeychainNamespace(productionAccessGroup: EncryptedAppServices.keychainAccessGroup)
            let capsules = ConversationCapsuleStore(namespace: namespace)
            let relay = FirebaseSecurePairingTransport(accountID: id, auth: auth, firestore: database)
            do {
                let client = try SecurePairingClient(localAccountID: id, accessGroup: EncryptedAppServices.keychainAccessGroup,
                    coordinationDirectory: root.appendingPathComponent("Pairing", isDirectory: true), transport: relay,
                    currentSession: current, invalidateTransport: { relay.invalidate() })
                return EncryptedAccountResources(pairingClient: client, readCapsule: { try await capsules.readCapsule(scope: $0) },
                    makeSession: { capsule, current in
                        SecureConversationSession(capsule: capsule, pinnedReader: PinnedConversationCapsuleReader(store: capsules, expectedCapsule: capsule),
                                                  isCurrentSession: current)
                    }, confirmPending: { capsule, data, openingCurrent in
                        guard let handle = client.pendingHandle,
                              SecureConversationSession.same(handle.conversationID, capsule.conversationID) else { return }
                        guard let inviteID = data["pairingInviteId"] as? String else { throw EncryptedMessagingError.untrustedConversation }
                        let digest = try SecurePairingWire.decodeDigest(data["pairingGrantDigest"])
                        guard try await relay.confirmActiveConversation(conversationID: capsule.conversationID,
                            creatorID: capsule.creatorID, recipientID: capsule.recipientID, keyEpoch: capsule.keyEpoch,
                            inviteID: inviteID, grantDigest: digest) else { throw EncryptedMessagingError.untrustedConversation }
                        guard openingCurrent() else { throw EncryptedMessagingError.inactiveSession }
                        // The facade's own generation predicate rejects stale completion.
                        await client.restoreCompleted(assignment: try SecurePairingActiveAssignment(localAccountID: id,
                            conversationID: capsule.conversationID, keyEpoch: capsule.keyEpoch, creatorID: capsule.creatorID,
                            recipientID: capsule.recipientID, isActive: true, protocolID: capsule.suite, inviteID: inviteID, grantDigest: digest))
                    }, invalidate: { relay.invalidate() })
            } catch { relay.invalidate(); throw error }
        }, makeContent: { session, outbox, root, metadata in
            let blobs = FirebaseEncryptedBlobStore(session: session, database: database)
            let photoCache = PersistentPhotoCiphertextCache(directory: root.appendingPathComponent("PhotoCiphertextCache", isDirectory: true))
            let transport = FirestoreEncryptedMessagingTransport(session: session, database: database,
                uploadAttachment: { context, id, bytes in try await blobs.upload(bytes: bytes, attachmentID: id, context: context) })
            let messages = EncryptedMessagingService(session: session, outbox: outbox, transport: transport, metadata: metadata)
            return try EncryptedContentResources(messages: messages,
                attachments: EncryptedAttachmentService(session: session, blobs: blobs,
                    restorePendingAttachment: { try await messages.restorePendingAttachment(messageID: $0) },
                    ciphertextCache: photoCache),
                resolver: EncryptedAttachmentResolver(session: session, blobs: blobs,
                    ciphertextCache: photoCache),
                locations: EncryptedLocationService(session: session, database: database,
                    revisionStore: EncryptedLocationRevisionFileStore(directory: root.appendingPathComponent("LocationRevisions", isDirectory: true))))
        }, sweepMedia: { _ = try EncryptedMediaTemporaryStore(root: FileManager.default.temporaryDirectory) },
             developmentPairingEnabled: EncryptedAppServices.nativeEncryptionRequired)
    }
}
