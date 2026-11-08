import CryptoKit
import Foundation
import MinesE2EE
import Observation

/// The custom scheme is an explicit paste/QR handoff, not an authenticated identity claim.
/// Other installed apps can register this scheme. Do not put invite secrets in query strings,
/// logs, preferences or analytics; an HTTPS universal-link domain is not configured yet.
enum SecurePairingInviteInput {
    static func parse(_ input: String) throws -> PairingInvite {
        guard input.utf8.count <= 100, !input.contains("%") else { throw SecurePairingClientFailure.invalidInvite }
        let fragment: String
        if input.hasPrefix("v1.") { fragment = input }
        else {
            let prefix = "peapod://secure-pair#"
            guard input.hasPrefix(prefix) else { throw SecurePairingClientFailure.invalidInvite }
            fragment = String(input.dropFirst(prefix.count))
            // Exact prefix rejects ports, userinfo, query, alternate paths and URL normalization.
        }
        do { return try PairingInvite(shareFragment: fragment) }
        catch { throw SecurePairingClientFailure.invalidInvite }
    }
}

private enum SecurePairingClientFailure: Error { case invalidInvite, invalidPersistence, alreadyPending, invalidSession, superseded }

protocol SecurePairingCoordinating: Sendable {
    func beginCreator(conversationID: String, epochKey: Data, nowMilliseconds: UInt64,
                      expiresAtMilliseconds: UInt64) async throws -> PendingPairingHandle
    func accept(_ invite: PairingInvite, nowMilliseconds: UInt64) async throws -> PendingPairingHandle
    func shareInvite(_ handle: PendingPairingHandle) async throws -> PairingInvite
    func advance(_ handle: PendingPairingHandle, nowMilliseconds: UInt64) async throws -> SecurePairingProgress
    func cancel(_ handle: PendingPairingHandle) async throws
    func invalidate() async
}
extension SecurePairingCoordinator: SecurePairingCoordinating {}

/// Current authoritative routing must be read independently of the relay's completed state.
/// This metadata authorizes routing only; the authenticated Keychain capsule supplies trust/key.
struct SecurePairingActiveAssignment: Sendable {
    let localAccountID: String
    let conversationID: String
    let keyEpoch: UInt32
    let creatorID: String
    let recipientID: String
    let inviteID: String
    let grantDigest: Data
    /// Caller reads these fields from the current secure conversation with server source, after
    /// verifying both account assignments point at it. Cached paired-profile IDs are insufficient.
    init(localAccountID: String, conversationID: String, keyEpoch: UInt32, creatorID: String,
         recipientID: String, isActive: Bool, protocolID: String, inviteID: String, grantDigest: Data) throws {
        guard isActive, Data(protocolID.utf8) == Data(PairingProtocol.contentSuite.utf8), keyEpoch == 1,
              grantDigest.count == 32, inviteID.utf8.count == 32,
              inviteID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ConversationKeyStoreError.identityMismatch
        }
        self.localAccountID = localAccountID; self.conversationID = conversationID; self.keyEpoch = keyEpoch
        self.creatorID = creatorID; self.recipientID = recipientID; self.inviteID = inviteID; self.grantDigest = grantDigest
    }
}

protocol SecurePairingCapsuleReading: Sendable {
    func readCapsule(scope: KeyScope) async throws -> StoredConversationCapsule?
}
extension ConversationCapsuleStore: SecurePairingCapsuleReading {}

/// One account's non-secret resume locator. Private crypto is held only by the Keychain store.
/// An app must invalidate this client and its transport before changing the authenticated account.
@MainActor @Observable
final class SecurePairingClient {
    enum State: Equatable {
        case idle, waitingForPerson, waitingForCreator, completed, expired, retryableFailure, keyUnavailable, signedOut
    }
    static let minimumPollInterval: TimeInterval = 5
    private(set) var state: State = .idle
    private(set) var errorMessage: String?
    private(set) var pendingHandle: PendingPairingHandle?
    private(set) var completedCapsule: StoredConversationCapsule?
    private(set) var isBusy = false
    private(set) var resetBlocked = false

    @ObservationIgnored private let account: String
    @ObservationIgnored private let coordinator: any SecurePairingCoordinating
    @ObservationIgnored private let pendingStore: PendingPairingKeychainStore?
    @ObservationIgnored private let capsuleStore: (any SecurePairingCapsuleReading)?
    @ObservationIgnored private let handleStore: SecurePairingHandleFile
    @ObservationIgnored private let currentSession: @MainActor () -> Bool
    @ObservationIgnored private let invalidateTransport: @MainActor () -> Void
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var operationGeneration = UUID()
    @ObservationIgnored private var activeOperations = 0
    @ObservationIgnored private var cancellationInProgress = false
    @ObservationIgnored private var invalidated = false
    @ObservationIgnored private var cancelRequested = false
    @ObservationIgnored private var nextAdvanceAt = Date.distantPast

    /// Dedicated explicit E2EE access group; no fallback to Firebase-auth/default Keychain groups.
    convenience init(localAccountID: String, accessGroup: String, coordinationDirectory: URL,
                     transport: any SecurePairingTransport, currentSession: @escaping @MainActor () -> Bool,
                     invalidateTransport: @escaping @MainActor () -> Void) throws {
        let namespace = try ConversationKeychainNamespace(productionAccessGroup: accessGroup)
        let pending = try PendingPairingKeychainStore(namespace: namespace, coordinationDirectory: coordinationDirectory)
        let capsules = ConversationCapsuleStore(namespace: namespace)
        let coordinator = try SecurePairingCoordinator(localAccountID: localAccountID, transport: transport,
                                                       pendingStore: pending, capsuleStore: capsules)
        try self.init(localAccountID: localAccountID, coordinator: coordinator, capsuleStore: capsules, pendingStore: pending,
                      persistenceDirectory: coordinationDirectory.appendingPathComponent("PairingHandles", isDirectory: true),
                      currentSession: currentSession, invalidateTransport: invalidateTransport)
    }

    init(localAccountID: String, coordinator: any SecurePairingCoordinating,
         capsuleStore: (any SecurePairingCapsuleReading)? = nil, pendingStore: PendingPairingKeychainStore? = nil, persistenceDirectory: URL,
         currentSession: @escaping @MainActor () -> Bool, invalidateTransport: @escaping @MainActor () -> Void,
         now: @escaping @MainActor () -> Date = Date.init) throws {
        guard !localAccountID.isEmpty, localAccountID.utf8.count <= 256 else { throw SecurePairingClientFailure.invalidPersistence }
        account = localAccountID; self.coordinator = coordinator; self.capsuleStore = capsuleStore; self.pendingStore = pendingStore
        handleStore = try SecurePairingHandleFile(account: localAccountID, directory: persistenceDirectory)
        self.currentSession = currentSession; self.invalidateTransport = invalidateTransport; self.now = now
        do {
            if let stored = try handleStore.load() {
                pendingHandle = stored.handle; cancelRequested = stored.cancelRequested
                state = stored.handle.scope.role == .creator ? .waitingForPerson : .waitingForCreator
            }
        } catch {
            state = .keyUnavailable
            errorMessage = "Saved pairing could not be restored. No new key was created."
        }
        if !currentSession() { revokeSession(); state = .signedOut }
    }

    /// Explicit action only. Persists the non-secret handle before the first relay publication.
    func createInvite() async {
        guard beginOperation() else { return }
        defer { endOperation() }
        do {
            guard pendingHandle == nil, completedCapsule == nil, state != .keyUnavailable else { throw SecurePairingClientFailure.alreadyPending }
            let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            let milliseconds = try timeMilliseconds()
            let handle = try await coordinator.beginCreator(conversationID: UUID().uuidString.lowercased(), epochKey: key,
                nowMilliseconds: milliseconds, expiresAtMilliseconds: milliseconds + 15 * 60 * 1000)
            try requireSession()
            try keep(handle)
            try await performAdvance(handle)
        } catch { fail(error) }
    }

    func joinInvite(_ input: String) async {
        guard beginOperation() else { return }
        defer { endOperation() }
        do {
            guard pendingHandle == nil, completedCapsule == nil, state != .keyUnavailable else { throw SecurePairingClientFailure.alreadyPending }
            let invite = try SecurePairingInviteInput.parse(input)
            let handle = try await coordinator.accept(invite, nowMilliseconds: timeMilliseconds())
            try requireSession()
            try keep(handle)
            try await performAdvance(handle)
        } catch { fail(error) }
    }

    /// Root UI may call every five seconds. Reentrant calls and faster polling are ignored.
    func advance() async {
        guard !isBusy, now() >= nextAdvanceAt, beginOperation() else { return }
        defer { endOperation() }
        do {
            guard let handle = pendingHandle else { return }
            if cancelRequested { try await performCancel(handle) }
            else { try await performAdvance(handle) }
        } catch { fail(error) }
    }

    /// Keep the locator until BOTH durable local cancellation and remote confirmation succeed.
    /// On restart advance retries cancellation, so a relay failure cannot turn into pairing again.
    func cancel() async {
        do { try requireSession() } catch { fail(error); return }
        guard !cancellationInProgress, let handle = pendingHandle else { return }
        cancellationInProgress = true
        operationGeneration = UUID() // revoke results from an already in-flight advance
        activeOperations += 1; isBusy = true
        defer { cancellationInProgress = false; endOperation() }
        do {
            cancelRequested = true
            try handleStore.save(handle, cancelRequested: true)
            try await performCancel(handle)
        } catch { fail(error) }
    }

    /// Explicit export only, recovered from persisted creator Keychain state rather than memory/UI.
    func sharingFragment() async -> String? {
        do {
            try requireSession()
            guard !isBusy, !cancelRequested, let handle = pendingHandle, handle.scope.role == .creator else { return nil }
            let generation = operationGeneration
            let invite: PairingInvite
            do { invite = try await coordinator.shareInvite(handle) }
            catch { try requireGeneration(generation); throw error }
            try requireGeneration(generation)
            guard !cancelRequested else { return nil }
            return invite.shareFragment()
        } catch { fail(error); return nil }
    }
    func sharingURL() async -> URL? {
        guard let fragment = await sharingFragment() else { return nil }
        return URL(string: "peapod://secure-pair#" + fragment)
    }

    /// Independently restore installed trusted capsules, including after ephemeral state consumption.
    /// A missing key remains unavailable; server metadata can never manufacture trust or key material.
    func restoreCompleted(assignment: SecurePairingActiveAssignment) async {
        guard beginOperation() else { return }
        defer { endOperation() }
        do {
            guard exact(assignment.localAccountID, account), assignment.keyEpoch == 1,
                  UUID(uuidString: assignment.conversationID)?.uuidString.lowercased() == assignment.conversationID,
                  !exact(assignment.creatorID, assignment.recipientID),
                  exact(account, assignment.creatorID) || exact(account, assignment.recipientID),
                  let capsuleStore else { throw ConversationKeyStoreError.identityMismatch }
            if let handle = pendingHandle, (!exact(handle.conversationID, assignment.conversationID)
                || !exact(handle.scope.inviteID, assignment.inviteID)) {
                throw ConversationKeyStoreError.identityMismatch
            }
            let generation = operationGeneration
            let capsule: StoredConversationCapsule?
            do { capsule = try await capsuleStore.readCapsule(scope: KeyScope(accountID: account,
                conversationID: assignment.conversationID, epoch: assignment.keyEpoch)) }
            catch { try requireGeneration(generation); throw error }
            try requireGeneration(generation)
            guard let capsule, exact(capsule.localAccountID, account), exact(capsule.conversationID, assignment.conversationID),
                  capsule.keyEpoch == assignment.keyEpoch, exact(capsule.creatorID, assignment.creatorID),
                  exact(capsule.recipientID, assignment.recipientID) else { throw ConversationKeyStoreError.identityMismatch }
            if let handle = pendingHandle, let pendingStore {
                do {
                    let terminal = try await pendingStore.terminalStatus(scope: handle.scope)
                    try requireGeneration(generation)
                    if terminal != nil {
                        _ = try await pendingStore.retryTerminalCleanup(scope: handle.scope)
                        try requireGeneration(generation)
                    } else {
                        let initial = try await pendingStore.readStage(.initialState, scope: handle.scope)
                        try requireGeneration(generation)
                        let grant = try await pendingStore.readStage(.sealedGrant, scope: handle.scope)
                        try requireGeneration(generation)
                        guard let initial, let grant, grant.payloadDigest == assignment.grantDigest else {
                            throw ConversationKeyStoreError.missingPrerequisite
                        }
                        try await pendingStore.consumeAndCleanUp(scope: handle.scope, pin: initial.initialStatePin,
                                                                 expectedSealedGrantDigest: assignment.grantDigest)
                        try requireGeneration(generation)
                    }
                } catch { try requireGeneration(generation); throw error }
            }
            // A verified active assignment plus matching authenticated capsule reconciles an ack
            // that won the cancellation race. This never claims that cancellation succeeded.
            try handleStore.remove()
            pendingHandle = nil; cancelRequested = false; completedCapsule = capsule; state = .completed; errorMessage = nil
        } catch { fail(error) }
    }

    /// Runs synchronously before the first suspension to revoke the transport/account context.
    /// Blocks all external pairing operations while durable reset recovery is pending.
    func blockForConversationReset() {
        resetBlocked = true; operationGeneration = UUID(); invalidateTransport()
    }

    /// Cleanup is bound to this account and matching old conversation only. Metadata is
    /// removed after the Keychain tombstone/cleanup succeeds; failures preserve the locator.
    func retireAfterVerifiedConversationDeletion(_ conversationID: String) async throws {
        guard currentSession(), !invalidated else { throw SecurePairingClientFailure.invalidSession }
        let token = operationGeneration
        let storedHandle = try handleStore.load()?.handle
        if let handle = storedHandle ?? pendingHandle, exact(handle.conversationID, conversationID) {
            guard let pendingStore else { throw SecurePairingClientFailure.invalidPersistence }
            try await pendingStore.retireAfterVerifiedConversationDeletion(scope: handle.scope)
            guard token == operationGeneration, currentSession(), !invalidated else { throw SecurePairingClientFailure.invalidSession }
            try handleStore.remove()
            pendingHandle = nil; cancelRequested = false
        }
        if let capsule = completedCapsule, exact(capsule.conversationID, conversationID) { completedCapsule = nil }
    }

    func invalidate() async {
        revokeSession()
        completedCapsule = nil; state = .signedOut; errorMessage = nil
        await coordinator.invalidate()
    }

    private func beginOperation() -> Bool {
        guard !isBusy else { return false }
        do { try requireSession() } catch { fail(error); return false }
        activeOperations += 1; isBusy = true; errorMessage = nil
        return true
    }
    private func endOperation() {
        activeOperations -= 1; isBusy = activeOperations > 0
    }
    private func requireGeneration(_ generation: UUID) throws {
        try requireSession()
        guard generation == operationGeneration else { throw SecurePairingClientFailure.superseded }
    }
    private func revokeSession() {
        guard !invalidated else { return }
        invalidated = true; operationGeneration = UUID(); invalidateTransport()
    }
    private func requireSession() throws {
        if !currentSession() { revokeSession() }
        guard !invalidated else { throw SecurePairingClientFailure.invalidSession }
        guard !resetBlocked else { throw SecurePairingClientFailure.superseded }
    }
    private func keep(_ handle: PendingPairingHandle) throws {
        guard exact(handle.scope.localAccountID, account) else { throw SecurePairingClientFailure.invalidSession }
        // Keep in-memory locator even if disk is unavailable, so the current UI can retry/cancel.
        pendingHandle = handle; cancelRequested = false
        try handleStore.save(handle, cancelRequested: false)
        state = handle.scope.role == .creator ? .waitingForPerson : .waitingForCreator
    }
    private func performAdvance(_ handle: PendingPairingHandle) async throws {
        // Re-pin metadata before network writes, including a prior persistence failure.
        try handleStore.save(handle, cancelRequested: false)
        nextAdvanceAt = now().addingTimeInterval(Self.minimumPollInterval)
        let generation = operationGeneration
        let result: SecurePairingProgress
        do { result = try await coordinator.advance(handle, nowMilliseconds: timeMilliseconds()) }
        catch { try requireGeneration(generation); throw error }
        try requireGeneration(generation)
        switch result {
        case .waiting: state = handle.scope.role == .creator ? .waitingForPerson : .waitingForCreator; errorMessage = nil
        case let .completed(capsule):
            guard exact(capsule.localAccountID, account), exact(capsule.conversationID, handle.conversationID), capsule.keyEpoch == 1 else {
                throw ConversationKeyStoreError.identityMismatch
            }
            try handleStore.remove()
            pendingHandle = nil; cancelRequested = false; completedCapsule = capsule; state = .completed; errorMessage = nil
        }
    }
    private func performCancel(_ handle: PendingPairingHandle) async throws {
        try handleStore.save(handle, cancelRequested: true)
        nextAdvanceAt = now().addingTimeInterval(Self.minimumPollInterval)
        do { try await coordinator.cancel(handle) }
        catch SecurePairingTransportFailure.notFound { /* Server confirms this locator is absent. */ }
        try requireSession()
        try handleStore.remove()
        pendingHandle = nil; cancelRequested = false; state = .idle; errorMessage = nil
    }
    private func timeMilliseconds() throws -> UInt64 {
        let seconds = now().timeIntervalSince1970
        guard seconds.isFinite, seconds >= 0, seconds < Double(UInt64.max / 1000) - 900 else { throw SecurePairingClientFailure.invalidPersistence }
        return UInt64(seconds * 1000)
    }
    private func fail(_ error: any Error) {
        if error as? SecurePairingClientFailure == .superseded { return }
        if invalidated || !currentSession() || error as? SecurePairingClientFailure == .invalidSession {
            revokeSession()
            completedCapsule = nil; state = .signedOut; errorMessage = nil
        } else if error as? SecurePairingClientFailure == .invalidInvite {
            state = .retryableFailure; errorMessage = "Paste the complete secure invite."
        } else if error as? SecurePairingClientFailure == .alreadyPending {
            errorMessage = "Finish or cancel the current pairing first."
        } else if error as? MinesE2EE.PairingError == .expired || error as? SecurePairingTransportFailure == .expired {
            state = .expired; errorMessage = "This invite expired. Cancel it before creating another."
        } else if error is ConversationKeyStoreError || error as? SecurePairingCoordinatorError == .missingState {
            state = .keyUnavailable; errorMessage = "The pairing key is unavailable. No new key was created."
        } else if error is MinesE2EE.PairingError || error as? SecurePairingTransportFailure == .conflict
                    || error as? SecurePairingCoordinatorError == .conflictingTranscript
                    || error as? SecurePairingCoordinatorError == .invalidRelay {
            state = .keyUnavailable; errorMessage = "This pairing could not be verified."
        } else if error as? SecurePairingCoordinatorError == .cancellationTooLate {
            state = .retryableFailure; errorMessage = "Pairing already finished. Reconnecting to the conversation."
        } else {
            state = .retryableFailure; errorMessage = "Pairing could not finish. Try again."
        }
    }
    private func exact(_ a: String, _ b: String) -> Bool { Data(a.utf8) == Data(b.utf8) }
}

/// Bounded account-scoped metadata only. Atomic protected file, no secret invite or private state.
private struct SecurePairingHandleFile {
    private struct Record: Codable {
        let version: Int
        let account: String
        let invite: String
        let conversation: String
        let role: UInt32
        let cancelRequested: Bool
    }
    struct Stored { let handle: PendingPairingHandle; let cancelRequested: Bool }
    let account: String
    let directory: URL
    let url: URL
    let file: SecureAccountMetadataFile
    init(account: String, directory: URL) throws {
        guard directory.isFileURL, directory.path.hasPrefix("/") else { throw SecurePairingClientFailure.invalidPersistence }
        self.account = account; self.directory = directory
        file = try SecureAccountMetadataFile(account: account, directory: directory)
        let hash = SHA256.hash(data: Data(account.utf8)).map { String(format: "%02x", $0) }.joined()
        url = directory.appendingPathComponent(hash + ".json")
    }
    func load() throws -> Stored? {
        try file.locked { try loadUnlocked() }
    }
    private func loadUnlocked() throws -> Stored? {
        guard let bytes = try file.read(maximum: 2048) else { return nil }
        guard !bytes.isEmpty, bytes.count <= 2048,
              let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(object.keys) == Set(["version", "account", "invite", "conversation", "role", "cancelRequested"]) else {
            throw SecurePairingClientFailure.invalidPersistence
        }
        let record = try JSONDecoder().decode(Record.self, from: bytes)
        guard try encoded(record) == bytes else { throw SecurePairingClientFailure.invalidPersistence }
        guard record.version == 1, Data(record.account.utf8) == Data(account.utf8),
              let role = PendingPairingScope.Role(rawValue: record.role) else { throw SecurePairingClientFailure.invalidPersistence }
        let handle = try PendingPairingHandle(scope: PendingPairingScope(localAccountID: record.account, inviteID: record.invite, role: role),
                                             conversationID: record.conversation)
        return Stored(handle: handle, cancelRequested: record.cancelRequested)
    }
    func save(_ handle: PendingPairingHandle, cancelRequested: Bool) throws {
        guard Data(handle.scope.localAccountID.utf8) == Data(account.utf8) else { throw SecurePairingClientFailure.invalidPersistence }
        let record = Record(version: 1, account: account, invite: handle.scope.inviteID, conversation: handle.conversationID,
                            role: handle.scope.role.rawValue, cancelRequested: cancelRequested)
        let bytes = try encoded(record)
        guard bytes.count <= 2048 else { throw SecurePairingClientFailure.invalidPersistence }
        try file.locked { try file.replace(bytes) }
    }
    private func encoded(_ record: Record) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(record)
    }
    func remove() throws {
        try file.locked { try file.remove() }
    }
}
