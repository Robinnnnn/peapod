@preconcurrency import FirebaseAuth
@preconcurrency import FirebaseFirestore
import CryptoKit
import Foundation
import MinesE2EE
import Observation

/// App-session composition. Firebase routing is confirmed before selecting any
/// content service, and the native capsule supplies all cryptographic trust.
@MainActor @Observable
final class EncryptedAppServices {
    static var keychainAccessGroup: String {
        get throws { try BuildIdentity.configuration().e2eeKeychainAccessGroup }
    }
    private(set) var pairingClient: SecurePairingClient?
    private(set) var requiresSecurePairing = false
    var needsFreshEncryptedConversation: Bool { freshEncryptedConversationID != nil }
    private var freshEncryptedConversationID: String?
    private(set) var resolver: EncryptedAttachmentResolver?
    private(set) var locations: EncryptedLocationService?
    private(set) var session: SecureConversationSession?
    private(set) var contentErrorMessage: String?
    private(set) var accountInvalidationID = UUID()
    private(set) var resetCheckpoint: SecureResetCheckpoint?
    private(set) var resetErrorMessage: String?
    private(set) var resetRecoveryBlocked = false
    private(set) var verifiedConversationDeletionID: String?
    @ObservationIgnored private let dependencies: EncryptedAppServiceDependencies
    @ObservationIgnored private let legacyMessaging: any MessagingProviding
    @ObservationIgnored private let legacyAttachments: any AttachmentProviding
    @ObservationIgnored private let drafts: EncryptedDraftDependencies
    @ObservationIgnored private var accountID: String?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var openGeneration = UUID()
    @ObservationIgnored private var resources: EncryptedAccountResources?
    @ObservationIgnored private var authObservation: ServiceObservation?
    @ObservationIgnored private var encryptedMessaging: EncryptedMessagingService?
    @ObservationIgnored private var encryptedAttachments: EncryptedAttachmentService?
    @ObservationIgnored private var outbox: DurableCiphertextOutbox?
    @ObservationIgnored private var legacyConversationID: String?
    @ObservationIgnored private var assignmentObservation: ServiceObservation?
    @ObservationIgnored private var contentInvalidation: ServiceObservation?
    @ObservationIgnored private var root: URL?
    @ObservationIgnored private var resetOperation: UUID?
    @ObservationIgnored private var contentConversationID: String?
    @ObservationIgnored private var openingConversationID: String?
    @ObservationIgnored private var knownConversationMembers: [Data: Set<Data>] = [:]

    convenience init(auth: Auth = .auth(), database: Firestore = .firestore(),
         legacyMessaging: any MessagingProviding = FirestoreMessagingService(),
         legacyAttachments: any AttachmentProviding = FirebaseAttachmentService()) {
        self.init(dependencies: .native(auth: auth, database: database),
                  legacyMessaging: legacyMessaging, legacyAttachments: legacyAttachments)
    }
    init(dependencies: EncryptedAppServiceDependencies, legacyMessaging: any MessagingProviding,
         legacyAttachments: any AttachmentProviding, drafts: EncryptedDraftDependencies = .native) {
        self.dependencies = dependencies
        self.legacyMessaging = legacyMessaging; self.legacyAttachments = legacyAttachments
        self.drafts = drafts
        authObservation = dependencies.observeAuth { [weak self] observedUID in
            guard let self, let id = self.accountID else { return }
            if observedUID.map({ SecureConversationSession.same($0, id) }) != true || !self.isCurrent(id, self.generation) {
                self.invalidate()
                self.accountInvalidationID = UUID()
                // Invalidation cancels content observers first; publish a safe signal
                // separately so app models also clear already decrypted message rows.
                self.contentErrorMessage = "The account session changed. Please reopen the secure conversation."
            }
        }
    }
    // Trusted build policy, not a server eligibility flag. A fresh device must never
    // accept a plaintext downgrade while its synchronizable capsule is still arriving.
    static let nativeEncryptionRequired = SharedConversationStore.encryptionRequiredByBuild
    func beginAccountSession(_ id: String) throws {
        if let accountID, SecureConversationSession.same(accountID, id), resources != nil, isCurrent(id, generation) { return }
        invalidate()
        guard let current = dependencies.currentUID(), SecureConversationSession.same(current, id) else {
            throw EncryptedMessagingError.inactiveSession
        }
        var initialized = false
        defer { if !initialized { invalidate() } }
        accountID = id; generation = UUID()
        let pinnedGeneration = generation
        let directory = try dependencies.rootDirectory()
        root = directory
        do {
            resetCheckpoint = try resetStore(id, directory).load()
            resetRecoveryBlocked = resetCheckpoint != nil
        } catch {
            // Keep the authenticated session visible but fail closed until the exact
            // durable checkpoint becomes readable. Never treat a decode/OS error as nil.
            resetCheckpoint = nil; resetRecoveryBlocked = true
            resetErrorMessage = "Saved reset recovery could not be read. Retry cleanup before making a new connection."
        }
        resources = try dependencies.makeAccount(id, directory, { [weak self] in self?.isCurrent(id, pinnedGeneration) == true })
        pairingClient = resources?.pairingClient
        if resetRecoveryBlocked { pairingClient?.blockForConversationReset() }
        requiresSecurePairing = try dependencies.developmentPairingEnabled || secureFloor(for: id)
        try dependencies.sweepMedia()
        initialized = true
    }
    func refreshAccountRequirements() async throws {
        guard let id = accountID else { throw EncryptedMessagingError.inactiveSession }
        let pinned = generation
        let profile = try await dependencies.readProfile(id)
        try requireCurrent(id, pinned)
        requiresSecurePairing = try requiresSecurePairing || dependencies.developmentPairingEnabled || secureFloor(for: id) || profile?["e2eeRequired"] as? Bool == true
        if requiresSecurePairing { try persistSecureFloor(for: id) }
    }
    func openConversation(_ conversationID: String) async throws {
        guard !resetRecoveryBlocked else { throw SecureResetError.pendingReset }
        guard let id = accountID else { throw EncryptedMessagingError.inactiveSession }
        let pinned = generation, opening = UUID()
        openGeneration = opening
        closeContent()
        openingConversationID = conversationID
        defer { if openGeneration == opening { openingConversationID = nil } }
        contentErrorMessage = nil
        // A polling retry must retain the verified reason while network reads
        // are in flight. Scope it to this exact conversation, never a new route.
        if freshEncryptedConversationID.map({ !SecureConversationSession.same($0, conversationID) }) == true {
            freshEncryptedConversationID = nil
        }
        guard let root else { throw EncryptedMessagingError.inactiveSession }
        let openingOutbox = try DurableCiphertextOutbox(directory: root.appendingPathComponent("Outbox", isDirectory: true), limits: .production)
        defer { if outbox !== openingOutbox { openingOutbox.close() } }
        guard try !openingOutbox.isConversationClosed(accountID: id, conversationID: conversationID) else {
            throw OutboxError.closedConversation
        }
        // Service selection independently enforces the account's protocol floor.
        let profile = try await dependencies.readProfile(id)
        try requireCurrent(id, pinned)
        guard openGeneration == opening,
              (profile?["activeConversationId"] as? String).map({ SecureConversationSession.same($0, conversationID) }) == true else {
            throw EncryptedMessagingError.untrustedConversation
        }
        requiresSecurePairing = try requiresSecurePairing || secureFloor(for: id)
            || profile?["e2eeRequired"] as? Bool == true
        if requiresSecurePairing { try persistSecureFloor(for: id) }
        let record = try await dependencies.readConversation(conversationID)
        try requireCurrent(id, pinned)
        guard openGeneration == opening, let data = record,
              data["status"] as? String == "active", let members = data["members"] as? [String],
              members.count == 2, members.contains(where: { SecureConversationSession.same($0, id) }) else {
            throw EncryptedMessagingError.untrustedConversation
        }
        knownConversationMembers[Data(conversationID.utf8)] = Set(members.map { Data($0.utf8) })
        if data["encryption"] == nil {
            guard data["keyEpoch"] == nil else { throw EncryptedMessagingError.untrustedConversation }
            // Protocol-floor accounts cannot quietly reopen a downgraded server assignment.
            guard !requiresSecurePairing else {
                freshEncryptedConversationID = conversationID
                throw EncryptedMessagingError.untrustedConversation
            }
            if UUID(uuidString: conversationID)?.uuidString.lowercased() == conversationID, let resources {
                let known = try await resources.readCapsule(KeyScope(accountID: id, conversationID: conversationID, epoch: 1))
                try requireCurrent(id, pinned)
                guard known == nil, openGeneration == opening else { throw EncryptedMessagingError.untrustedConversation }
            }
            closeContent()
            try dependencies.sharedState().publish(SharedConversationTarget(accountID: id,
                conversationID: conversationID, mode: .legacy, members: members))
            legacyConversationID = conversationID; contentConversationID = conversationID
            return
        }
        guard data["encryption"] as? String == "mines-e2ee-v1", let resources,
              try SecurePairingWire.integer(data["keyEpoch"]) == 1 else { throw EncryptedMessagingError.untrustedConversation }
        requiresSecurePairing = true
        try persistSecureFloor(for: id)
        freshEncryptedConversationID = nil
        let scope = KeyScope(accountID: id, conversationID: conversationID, epoch: 1)
        guard let capsule = try await resources.readCapsule(scope) else { throw EncryptedMessagingError.keyNotReady }
        try requireCurrent(id, pinned)
        guard openGeneration == opening else { throw EncryptedMessagingError.inactiveSession }
        try await resources.confirmPending(capsule, data, { [weak self] in
            self?.isCurrent(id, pinned) == true && self?.openGeneration == opening
        })
        try requireCurrent(id, pinned)
        guard openGeneration == opening else { throw EncryptedMessagingError.inactiveSession }
        let currentSession = resources.makeSession(capsule, { [weak self] in
            self?.isCurrent(id, pinned) == true && self?.openGeneration == opening
        })
        defer { if session !== currentSession { currentSession.invalidate() } }
        try await currentSession.activate(serverBinding: SecureConversationBinding(conversationID: conversationID,
            encryption: "mines-e2ee-v1", keyEpoch: 1, members: members, isActive: true))
        _ = try await currentSession.performKeyOperation { _ in true }
        try requireCurrent(id, pinned)
        guard openGeneration == opening else { currentSession.invalidate(); throw EncryptedMessagingError.inactiveSession }
        closeContent()
        let store = openingOutbox
        let content = try dependencies.makeContent(currentSession, store, root, legacyMessaging)
        try requireCurrent(id, pinned)
        guard openGeneration == opening else { throw EncryptedMessagingError.inactiveSession }
        try dependencies.sharedState().publish(SharedConversationTarget(accountID: id,
            conversationID: conversationID, mode: .encrypted, keyEpoch: 1, members: members))
        contentConversationID = conversationID
        session = currentSession; outbox = store; encryptedMessaging = content.messages
        contentInvalidation = currentSession.observeInvalidation { [weak self] in
            guard let self, self.openGeneration == opening else { return }
            self.cancelOpeningConversation()
            self.contentErrorMessage = "The secure conversation is unavailable. Please reopen it to retry."
        }
        encryptedAttachments = content.attachments; resolver = content.resolver
        locations = content.locations
        assignmentObservation = dependencies.observeConversation(conversationID) { [weak self, weak currentSession] result in
            guard let self, self.isCurrent(id, pinned), self.openGeneration == opening else { return }
            guard case let .success(update) = result else { currentSession?.invalidate(); return }
            guard !update.isFromCache else { return }
            guard let latest = update.data else {
                self.verifiedConversationDeletionID = conversationID
                currentSession?.invalidate(); return
            }
            let latestMembers = (latest["members"] as? [String] ?? []).map { Data($0.utf8) }
            if latest["status"] as? String == "deleting" {
                guard latestMembers.count == 2, Set(latestMembers) == Set(members.map { Data($0.utf8) }) else {
                    currentSession?.invalidate(); return
                }
                self.verifiedConversationDeletionID = conversationID
                do { try self.closeConversation(conversationID, deleted: true) }
                catch { self.contentErrorMessage = "The conversation closed, but its pending queue could not be cleared."; currentSession?.invalidate() }
                return
            }
            if latest["status"] as? String != "active" || latest["encryption"] as? String != "mines-e2ee-v1"
                || (try? SecurePairingWire.integer(latest["keyEpoch"])) != 1
                || Set(latestMembers) != Set(members.map { Data($0.utf8) }) || latestMembers.count != 2 {
                currentSession?.invalidate()
            }
        }
    }

    func cancelOpeningConversation() {
        openingConversationID = nil
        openGeneration = UUID()
        closeContent()
    }
    func restartPairingAfterDeletion() throws {
        guard !resetRecoveryBlocked else { throw SecureResetError.pendingReset }
        guard let accountID else { throw EncryptedMessagingError.inactiveSession }
        invalidate()
        try beginAccountSession(accountID)
    }
    /// Explicit destructive intent only. The adapter must return the server's exact
    /// conversation receipt; success alone cannot authorize cleanup of another scope.
    func resetConversation(expectedConversationID: String,
                           deleteRemote: @MainActor (String) async throws -> String) async throws {
        try await runReset(expectedConversationID: expectedConversationID, verifiedClosed: false, deleteRemote: deleteRemote)
    }

    /// Only a server-confirmed absent/deleting conversation with validated membership
    /// may enter here. A cached nil profile assignment is not a deletion proof.
    func finishVerifiedConversationDeletion(expectedConversationID: String) async throws {
        try await runReset(expectedConversationID: expectedConversationID, verifiedClosed: true, deleteRemote: { _ in
            throw SecureResetError.assignmentChanged
        })
    }

    /// Rechecks the server rather than trusting a cached nil profile or a generic
    /// key-unavailability error. Known membership was captured before native key lookup.
    func verifyAndFinishConversationDeletion(expectedConversationID: String) async throws {
        guard let id = accountID else { throw EncryptedMessagingError.inactiveSession }
        let token = generation
        var known = knownConversationMembers[Data(expectedConversationID.utf8)]
        if let capsule = pairingClient?.completedCapsule,
           SecureConversationSession.same(capsule.conversationID, expectedConversationID) {
            known = Set([Data(capsule.creatorID.utf8), Data(capsule.recipientID.utf8)])
        }
        if known == nil, let resources {
            let capsule = try await resources.readCapsule(KeyScope(accountID: id, conversationID: expectedConversationID, epoch: 1))
            try requireCurrent(id, token)
            if let capsule {
                guard SecureConversationSession.same(capsule.localAccountID, id),
                      SecureConversationSession.same(capsule.conversationID, expectedConversationID), capsule.keyEpoch == 1 else {
                    throw SecureResetError.assignmentChanged
                }
                known = Set([Data(capsule.creatorID.utf8), Data(capsule.recipientID.utf8)])
            }
        }
        guard let known, known.count == 2, known.contains(Data(id.utf8)) else { throw SecureResetError.assignmentChanged }
        let profile = try await dependencies.readProfile(id)
        try requireCurrent(id, token)
        guard let profile, profile["activeConversationId"] == nil || profile["activeConversationId"] is NSNull else {
            throw SecureResetError.assignmentChanged
        }
        // The exact current-session, uncached listener proof remains valid after
        // backend cleanup removes the document and Rules deny a subsequent get.
        if verifiedConversationDeletionID.map({ SecureConversationSession.same($0, expectedConversationID) }) == true {
            try await finishVerifiedConversationDeletion(expectedConversationID: expectedConversationID)
            return
        }
        let record = try await dependencies.readConversation(expectedConversationID)
        try requireCurrent(id, token)
        if let record {
            guard record["status"] as? String == "deleting", let members = record["members"] as? [String],
                  members.count == 2, Set(members.map { Data($0.utf8) }) == known else { throw SecureResetError.assignmentChanged }
        }
        try await finishVerifiedConversationDeletion(expectedConversationID: expectedConversationID)
    }

    func retryConversationReset(deleteRemote: @MainActor (String) async throws -> String) async throws {
        if resetCheckpoint == nil, resetRecoveryBlocked {
            guard let id = accountID, let root, isCurrent(id, generation) else { throw EncryptedMessagingError.inactiveSession }
            guard let restored = try resetStore(id, root).load() else { throw SecureResetError.invalidCheckpoint }
            resetCheckpoint = restored
        }
        guard let checkpoint = resetCheckpoint else { return }
        try await resetConversation(expectedConversationID: checkpoint.conversationID, deleteRemote: deleteRemote)
    }

    private func runReset(expectedConversationID: String, verifiedClosed: Bool,
                          deleteRemote: @MainActor (String) async throws -> String) async throws {
        guard let id = accountID, let root, isCurrent(id, generation) else { throw EncryptedMessagingError.inactiveSession }
        guard resetOperation == nil else { throw SecureResetError.pendingReset }
        guard [contentConversationID, openingConversationID].compactMap({ $0 }).allSatisfy({
            SecureConversationSession.same($0, expectedConversationID)
        }) else { throw SecureResetError.assignmentChanged }
        let token = generation, operation = UUID(), store = try resetStore(id, root)
        // Validate the exact scope first. Revoke locally before persisting intent;
        // persistence must succeed before any remote side effect.
        let loaded = try store.load() ?? resetCheckpoint
        if let loaded, !SecureConversationSession.same(loaded.conversationID, expectedConversationID) { throw SecureResetError.pendingReset }
        let intended = try SecureResetCheckpoint(accountID: id, conversationID: expectedConversationID,
            phase: loaded?.phase == .localCleanup || verifiedClosed ? .localCleanup : .requestingDeletion)
        resetRecoveryBlocked = true; resetCheckpoint = intended
        pairingClient?.blockForConversationReset()
        if [contentConversationID, openingConversationID].compactMap({ $0 }).contains(where: {
            SecureConversationSession.same($0, expectedConversationID)
        }) { cancelOpeningConversation() }
        resetOperation = operation; resetErrorMessage = nil
        defer { if resetOperation == operation { resetOperation = nil } }
        do {
            resetCheckpoint = try store.save(conversationID: expectedConversationID, phase: intended.phase)
            if resetCheckpoint?.phase == .requestingDeletion {
                let receipt = try await deleteRemote(expectedConversationID)
                try requireResetCurrent(id, token, operation)
                guard SecureConversationSession.same(receipt, expectedConversationID) else { throw SecureResetError.assignmentChanged }
                resetCheckpoint = try store.save(conversationID: expectedConversationID, phase: .localCleanup)
            }
            try requireResetCurrent(id, token, operation)
            // This tombstone only closes the old account/C. It is independent of an open route.
            let queue = try DurableCiphertextOutbox(directory: root.appendingPathComponent("Outbox", isDirectory: true), limits: .production)
            defer { queue.close() }
            try queue.closeConversation(accountID: id, conversationID: expectedConversationID)
            try await pairingClient?.retireAfterVerifiedConversationDeletion(expectedConversationID)
            try requireResetCurrent(id, token, operation)
            // Construct the fresh client while the checkpoint still blocks all entry points.
            // A failure here must remain retryable local cleanup, with no remote RPC repeated.
            guard contentConversationID == nil, openingConversationID == nil else { throw SecureResetError.assignmentChanged }
            let fresh = try dependencies.makeAccount(id, root, { [weak self] in self?.isCurrent(id, token) == true })
            do { try store.remove(conversationID: expectedConversationID) }
            catch { fresh.invalidate(); throw error }
            resources?.invalidate()
            if let old = pairingClient { Task { await old.invalidate() } }
            resources = fresh; pairingClient = fresh.pairingClient
            resetCheckpoint = nil; resetRecoveryBlocked = false; resetErrorMessage = nil
        } catch {
            guard isCurrent(id, token), resetOperation == operation else { throw EncryptedMessagingError.inactiveSession }
            resetErrorMessage = resetCheckpoint?.phase == .localCleanup
                ? "The conversation was deleted. Retry cleanup before making a new connection."
                : "Deletion could not be confirmed. Retry to safely finish this reset."
            throw error
        }
    }
    private func resetStore(_ id: String, _ root: URL) throws -> SecureResetCheckpointStore {
        try SecureResetCheckpointStore(accountID: id, directory: root.appendingPathComponent("ResetCheckpoints", isDirectory: true))
    }
    private func requireResetCurrent(_ id: String, _ token: UUID, _ operation: UUID) throws {
        try requireCurrent(id, token)
        guard resetOperation == operation else { throw EncryptedMessagingError.inactiveSession }
    }

    func enqueueDrafts(_ shares: [PendingShare]) throws {
        // Text-only composer submission legitimately has no attachment drafts. It must not
        // inspect routing, initialize storage, or invoke a draft writer for an empty batch.
        guard !shares.isEmpty else { return }
        guard let accountID, let conversationID = shares.first?.targetConversationID,
              shares.allSatisfy({ $0.targetConversationID == conversationID }) else { throw PendingShareStoreError.missingConversationTarget }
        _ = try messaging(for: conversationID)
        try drafts.enqueue(shares, accountID, conversationID)
    }
    func pendingDrafts() throws -> [PendingShare] {
        guard let accountID else { return [] }
        return try drafts.load(accountID)
    }
    func acknowledgeDrafts(_ ids: Set<UUID>) throws {
        guard let accountID else { throw EncryptedMessagingError.inactiveSession }
        try drafts.acknowledge(ids, accountID)
    }
    func retryPendingMessages() async {
        let pinned = generation, opening = openGeneration
        do { try await encryptedMessaging?.retryPendingMessages() }
        catch {
            guard generation == pinned, openGeneration == opening else { return }
            contentErrorMessage = "Some queued messages could not be sent. They remain saved on this device."
        }
    }
    func messaging(for conversationID: String) throws -> any MessagingProviding {
        if let session, let encryptedMessaging {
            try session.requireActive(conversationID: conversationID); return encryptedMessaging
        }
        guard let id = accountID, isCurrent(id, generation), let legacyConversationID,
              SecureConversationSession.same(legacyConversationID, conversationID) else { throw EncryptedMessagingError.inactiveSession }
        return legacyMessaging
    }
    func attachments(for conversationID: String) throws -> any AttachmentProviding {
        if let session, let encryptedAttachments {
            try session.requireActive(conversationID: conversationID); return encryptedAttachments
        }
        _ = try messaging(for: conversationID)
        return legacyAttachments
    }
    func closeConversation(_ id: String, deleted: Bool) throws {
        try? dependencies.sharedState().clear(accountID: accountID)
        openGeneration = UUID()
        session?.invalidate()
        resolver?.clearTemporaryFiles()
        defer { closeContent() }
        if deleted {
            guard let accountID, let root else { throw EncryptedMessagingError.inactiveSession }
            let store = try outbox ?? DurableCiphertextOutbox(directory: root.appendingPathComponent("Outbox", isDirectory: true), limits: .production)
            defer { if outbox == nil { store.close() } }
            try store.closeConversation(accountID: accountID, conversationID: id)
        }
    }
    func invalidate() {
        try? dependencies.sharedState().clear(accountID: accountID)
        generation = UUID(); openGeneration = UUID(); openingConversationID = nil
        resources?.invalidate(); resources = nil
        if let client = pairingClient { Task { await client.invalidate() } }
        pairingClient = nil; accountID = nil; requiresSecurePairing = false
        freshEncryptedConversationID = nil
        closeContent(); root = nil
        resetCheckpoint = nil; resetRecoveryBlocked = false; resetOperation = nil; resetErrorMessage = nil
        verifiedConversationDeletionID = nil; knownConversationMembers = [:]
    }
    private func secureFloor(for id: String) throws -> Bool {
        try dependencies.sharedState().requiresEncryption(accountID: id)
    }
    private func persistSecureFloor(for id: String) throws {
        try dependencies.sharedState().markEncryptionRequired(accountID: id)
    }
    private func closeContent() {
        contentInvalidation?.cancel(); contentInvalidation = nil
        try? dependencies.sharedState().clear(accountID: accountID)
        assignmentObservation?.cancel(); assignmentObservation = nil
        session?.invalidate(); session = nil; resolver?.clearTemporaryFiles(); resolver = nil
        locations?.invalidate(); locations = nil
        encryptedMessaging = nil; encryptedAttachments = nil; outbox?.close(); outbox = nil; legacyConversationID = nil; contentConversationID = nil
    }
    private func isCurrent(_ id: String, _ token: UUID) -> Bool {
        generation == token && accountID.map { SecureConversationSession.same($0, id) } == true
            && dependencies.currentUID().map { SecureConversationSession.same($0, id) } == true
    }
    private func requireCurrent(_ id: String, _ token: UUID) throws {
        guard isCurrent(id, token) else { throw EncryptedMessagingError.inactiveSession }
    }
}
