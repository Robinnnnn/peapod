import CryptoKit
import Foundation

public enum SecurePairingCoordinatorError: Error, Sendable {
    case invalidSession, busy, missingState, invalidRelay, conflictingTranscript, cancelled, inactiveConversation, transportUnavailable, cancellationTooLate
}

/// Non-secret locator for explicitly resuming a device-local pairing. Never reuse an invite ID.
public struct PendingPairingHandle: Sendable, CustomStringConvertible, CustomReflectable {
    public let scope: PendingPairingScope
    public let conversationID: String
    public init(scope: PendingPairingScope, conversationID: String) throws {
        guard UUID(uuidString: conversationID)?.uuidString.lowercased() == conversationID else {
            throw SecurePairingCoordinatorError.invalidRelay
        }
        self.scope = scope; self.conversationID = conversationID
    }
    public var description: String { "PendingPairingHandle(redacted)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public enum SecurePairingProgress: Sendable, CustomStringConvertible, CustomReflectable {
    case waiting
    case completed(StoredConversationCapsule)
    public var description: String { "SecurePairingProgress(redacted)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// One immutable authenticated account session. Invalidate on sign-out/account switch. Pending
/// crypto stays device-local and survives invalidation, but this instance can never reactivate.
/// All sensitive decisions precede relay writes. Consumed handles subsequently fail closed:
/// normal conversation restoration reads the installed capsule, never a completed relay alone.
public actor SecurePairingCoordinator {
    private let account: String
    private let transport: any SecurePairingTransport
    private let pending: PendingPairingKeychainStore
    private let capsules: ConversationCapsuleStore
    private var active = true
    private var busyInvites: Set<String> = []
    private var cancelledInvites: Set<String> = []

    public init(localAccountID: String, transport: any SecurePairingTransport,
                pendingStore: PendingPairingKeychainStore, capsuleStore: ConversationCapsuleStore) throws {
        try validateStoredKeyIdentifier(localAccountID)
        account = localAccountID; self.transport = transport; pending = pendingStore; capsules = capsuleStore
    }
    public func invalidate() { active = false }

    /// Explicit creation only. Caller supplies a fresh unique conversation ID and random key.
    public func beginCreator(conversationID: String, epochKey: Data, nowMilliseconds: UInt64,
                             expiresAtMilliseconds: UInt64) async throws -> PendingPairingHandle {
        try check()
        let state = try PairingProtocol.makeCreatorOffer(creatorID: account, conversationID: conversationID,
            epoch: 1, epochKey: epochKey, expiresAtMilliseconds: expiresAtMilliseconds, nowMilliseconds: nowMilliseconds)
        let scope = try PendingPairingScope(localAccountID: account, inviteID: state.invite.locatorHex, role: .creator)
        let handle = try PendingPairingHandle(scope: scope, conversationID: conversationID)
        _ = try await pending.pinInitialState(state.encodedForLocalStorage(), scope: scope)
        try check(handle)
        return handle
    }

    /// Explicit secret export for user sharing. No implicit logging or URL construction.
    public func shareInvite(_ handle: PendingPairingHandle) async throws -> PairingInvite {
        try check(handle)
        guard handle.scope.role == .creator else { throw SecurePairingCoordinatorError.invalidRelay }
        let record = try await initial(handle)
        let state = try CreatorPairingState(localState: record.opaqueBytesForLocalStorage())
        try bind(state, handle: handle)
        return state.invite
    }

    public func accept(_ invite: PairingInvite, nowMilliseconds: UInt64) async throws -> PendingPairingHandle {
        try check()
        let response = try await perform(.read(inviteID: invite.locatorHex))
        try check()
        let remote = try snapshot(response)
        try validate(remote)
        guard remote.state == .offered else { throw SecurePairingCoordinatorError.conflictingTranscript }
        let state = try PairingProtocol.makeAcceptance(publicOffer: remote.offer, invite: invite,
                                                      recipientID: account, nowMilliseconds: nowMilliseconds)
        let scope = try PendingPairingScope(localAccountID: account, inviteID: invite.locatorHex, role: .recipient)
        let handle = try PendingPairingHandle(scope: scope, conversationID: state.conversationID)
        try bind(remote, creator: state.creatorID, conversation: state.conversationID,
                 expiry: state.expiresAtMilliseconds, offer: state.publicOfferBytes)
        let pin = try await pending.pinInitialState(state.encodedForLocalStorage(), scope: scope)
        try check(handle)
        try await pending.pinStage(.acceptedClaim, bytes: state.publicAcceptanceBytes, scope: scope, pin: pin)
        try check(handle)
        return handle
    }

    public func advance(_ handle: PendingPairingHandle, nowMilliseconds: UInt64) async throws -> SecurePairingProgress {
        try check(handle)
        guard busyInvites.insert(handle.scope.inviteID).inserted else { throw SecurePairingCoordinatorError.busy }
        defer { busyInvites.remove(handle.scope.inviteID) }
        let initialRecord = try await initial(handle)
        if handle.scope.role == .creator {
            return try await advanceCreator(handle, initialRecord: initialRecord, now: nowMilliseconds)
        }
        return try await advanceRecipient(handle, initialRecord: initialRecord, now: nowMilliseconds)
    }

    /// Durable local cancellation precedes remote cancellation. It cannot retract an already sent grant.
    public func cancel(_ handle: PendingPairingHandle) async throws {
        try check()
        guard exact(handle.scope.localAccountID, account) else { throw SecurePairingCoordinatorError.invalidSession }
        let terminal = try await pending.terminalStatus(scope: handle.scope)
        try check()
        switch terminal {
        case .consumed: throw ConversationKeyStoreError.terminalInvite
        case .cancelled:
            cancelledInvites.insert(handle.scope.inviteID)
            _ = try await pending.retryTerminalCleanup(scope: handle.scope)
            try check()
        case nil:
            guard let record = try await pending.readStage(.initialState, scope: handle.scope) else {
                throw SecurePairingCoordinatorError.missingState
            }
            try check()
            cancelledInvites.insert(handle.scope.inviteID)
            try await pending.cancelAndCleanUp(scope: handle.scope, pin: record.initialStatePin)
            try check()
        }
        let response = try await perform(.cancel(inviteID: handle.scope.inviteID))
        try check()
        guard case .cancelled = response else { throw SecurePairingCoordinatorError.cancellationTooLate }
    }

    private func advanceCreator(_ handle: PendingPairingHandle, initialRecord: PendingPairingRecord,
                                now: UInt64) async throws -> SecurePairingProgress {
        let creator = try CreatorPairingState(localState: initialRecord.opaqueBytesForLocalStorage())
        try bind(creator, handle: handle)
        // Retry the exact offer, including after a process stopped before its first publish.
        var remote = try snapshot(try await relay(.publish(inviteID: handle.scope.inviteID,
            conversationID: creator.conversationID, keyEpoch: creator.keyEpoch, offer: creator.publicOfferBytes,
            expiresAtMilliseconds: creator.expiresAtMilliseconds), handle: handle))
        try bind(remote, creator: creator.creatorID, conversation: creator.conversationID,
                 expiry: creator.expiresAtMilliseconds, offer: creator.publicOfferBytes)
        if remote.state == .offered { return .waiting }
        guard let acceptance = remote.acceptance, let recipient = remote.claimantID else {
            throw SecurePairingCoordinatorError.invalidRelay
        }
        let claimed = try creator.pinAcceptance(publicAcceptance: acceptance, expectedRecipientID: recipient, nowMilliseconds: now)
        guard exact(claimed.claimIDHex, remote.claimID ?? "") else { throw SecurePairingCoordinatorError.conflictingTranscript }
        try await pending.pinStage(.acceptedClaim, bytes: claimed.encodedForLocalStorage(), scope: handle.scope,
                                   pin: initialRecord.initialStatePin)
        try check(handle)
        guard let claimRecord = try await stage(.acceptedClaim, handle) else { throw SecurePairingCoordinatorError.missingState }
        let authenticated = try claimed.creatorCapsule(nowMilliseconds: now)
        let capsule = try stored(authenticated)
        try await capsules.insertAuthenticatedCapsule(capsule)
        try check(handle)
        let grant: Data
        if let existing = try await stage(.sealedGrant, handle) { grant = existing.opaqueBytesForLocalStorage() }
        else {
            guard remote.grant == nil else { throw SecurePairingCoordinatorError.missingState }
            // No suspension between generation and initiating the immutable pin.
            grant = try claimed.makeGrant(nowMilliseconds: now)
            try await pending.pinStage(.sealedGrant, bytes: grant, scope: handle.scope,
                pin: initialRecord.initialStatePin, acceptedClaimDigest: claimRecord.payloadDigest)
            try check(handle)
        }
        if let remoteGrant = remote.grant, remoteGrant != grant { throw SecurePairingCoordinatorError.conflictingTranscript }
        remote = try snapshot(try await relay(.grant(inviteID: handle.scope.inviteID,
                                                     acceptanceDigest: claimed.acceptanceHash, grant: grant), handle: handle))
        try bind(remote, creator: creator.creatorID, conversation: creator.conversationID,
                 expiry: creator.expiresAtMilliseconds, offer: creator.publicOfferBytes)
        try bindClaim(remote, account: claimed.recipientID, claimID: claimed.claimIDHex, acceptance: acceptance)
        guard remote.grant == grant else { throw SecurePairingCoordinatorError.conflictingTranscript }
        if remote.state != .complete { return .waiting }
        return try await finish(handle, capsule: capsule, pin: initialRecord.initialStatePin, grant: grant)
    }

    private func advanceRecipient(_ handle: PendingPairingHandle, initialRecord: PendingPairingRecord,
                                  now: UInt64) async throws -> SecurePairingProgress {
        let state = try RecipientPairingState(localState: initialRecord.opaqueBytesForLocalStorage())
        guard exact(state.recipientID, account), exact(state.conversationID, handle.conversationID),
              exact(state.inviteIDHex, handle.scope.inviteID) else { throw SecurePairingCoordinatorError.conflictingTranscript }
        // Pin/retry acceptance before every claim, even if the initial call stopped after initial pin.
        try await pending.pinStage(.acceptedClaim, bytes: state.publicAcceptanceBytes, scope: handle.scope,
                                   pin: initialRecord.initialStatePin)
        try check(handle)
        var remote = try snapshot(try await relay(.claim(inviteID: handle.scope.inviteID, claimID: state.claimIDHex,
            acceptance: state.publicAcceptanceBytes, offerDigest: hash(state.publicOfferBytes)), handle: handle))
        try bindRecipient(remote, state: state)
        if remote.state == .claimed { return .waiting }
        guard let grant = remote.grant else { throw SecurePairingCoordinatorError.invalidRelay }
        let authenticated = try state.openGrant(grant: grant, nowMilliseconds: now)
        let capsule = try stored(authenticated)
        guard let claim = try await stage(.acceptedClaim, handle) else { throw SecurePairingCoordinatorError.missingState }
        try await pending.pinStage(.sealedGrant, bytes: grant, scope: handle.scope, pin: initialRecord.initialStatePin,
                                   acceptedClaimDigest: claim.payloadDigest)
        try check(handle)
        try await capsules.insertAuthenticatedCapsule(capsule)
        try check(handle)
        remote = try snapshot(try await relay(.acknowledge(inviteID: handle.scope.inviteID, grantDigest: hash(grant)), handle: handle))
        try bindRecipient(remote, state: state)
        guard remote.state == .complete, remote.grant == grant else { throw SecurePairingCoordinatorError.invalidRelay }
        return try await finish(handle, capsule: capsule, pin: initialRecord.initialStatePin, grant: grant)
    }

    private func finish(_ handle: PendingPairingHandle, capsule: StoredConversationCapsule,
                        pin: PendingPairingPin, grant: Data) async throws -> SecurePairingProgress {
        let confirmed: Bool
        do { confirmed = try await transport.confirmActiveConversation(conversationID: capsule.conversationID,
            creatorID: capsule.creatorID, recipientID: capsule.recipientID, keyEpoch: capsule.keyEpoch, inviteID: handle.scope.inviteID, grantDigest: hash(grant)) }
        catch let failure as SecurePairingTransportFailure { try check(handle); throw failure }
        catch { try check(handle); throw SecurePairingCoordinatorError.transportUnavailable }
        try check(handle)
        guard confirmed else { throw SecurePairingCoordinatorError.inactiveConversation }
        try await pending.consumeAndCleanUp(scope: handle.scope, pin: pin, expectedSealedGrantDigest: hash(grant))
        try check(handle)
        return .completed(capsule)
    }

    private func initial(_ handle: PendingPairingHandle) async throws -> PendingPairingRecord {
        guard let record = try await stage(.initialState, handle) else { throw SecurePairingCoordinatorError.missingState }
        return record
    }
    private func stage(_ stage: PendingPairingStage, _ handle: PendingPairingHandle) async throws -> PendingPairingRecord? {
        let result = try await pending.readStage(stage, scope: handle.scope)
        try check(handle)
        return result
    }
    private func relay(_ request: SecurePairingRequest, handle: PendingPairingHandle) async throws -> SecurePairingResponse {
        try check(handle)
        let result = try await perform(request)
        try check(handle)
        return result
    }
    private func perform(_ request: SecurePairingRequest) async throws -> SecurePairingResponse {
        do { return try await transport.perform(request) }
        catch let failure as SecurePairingTransportFailure { try check(); throw failure }
        catch { try check(); throw SecurePairingCoordinatorError.transportUnavailable }
    }
    private func check(_ handle: PendingPairingHandle? = nil) throws {
        guard active else { throw SecurePairingCoordinatorError.invalidSession }
        if let handle {
            guard exact(handle.scope.localAccountID, account) else { throw SecurePairingCoordinatorError.invalidSession }
            guard !cancelledInvites.contains(handle.scope.inviteID) else { throw SecurePairingCoordinatorError.cancelled }
        }
    }
    private func snapshot(_ response: SecurePairingResponse) throws -> SecurePairingSnapshot {
        guard case let .snapshot(value) = response else { throw SecurePairingCoordinatorError.cancelled }
        try validate(value)
        return value
    }
    private func validate(_ value: SecurePairingSnapshot) throws {
        try validateStoredKeyIdentifier(value.creatorID)
        guard UUID(uuidString: value.conversationID)?.uuidString.lowercased() == value.conversationID,
              value.keyEpoch == 1, exact(value.protocolID, PairingProtocol.contentSuite),
              !value.offer.isEmpty, value.offer.count <= PairingProtocol.maximumBoxBytes,
              value.offerDigest == hash(value.offer) else { throw SecurePairingCoordinatorError.invalidRelay }
        if value.state == .cancelled || value.state == .unavailable { throw SecurePairingCoordinatorError.cancelled }
        let claimed = value.state != .offered
        if claimed {
            guard let member = value.claimantID, !exact(member, value.creatorID),
                  let claim = value.claimID, claim.utf8.count == 32,
                  claim.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  let acceptance = value.acceptance, !acceptance.isEmpty, acceptance.count <= PairingProtocol.maximumBoxBytes,
                  value.acceptanceDigest == hash(acceptance) else { throw SecurePairingCoordinatorError.invalidRelay }
            try validateStoredKeyIdentifier(member)
        } else if value.claimantID != nil || value.claimID != nil || value.acceptance != nil || value.acceptanceDigest != nil {
            throw SecurePairingCoordinatorError.invalidRelay
        }
        if value.state == .grantReady || value.state == .complete {
            guard let grant = value.grant, !grant.isEmpty, grant.count <= PairingProtocol.maximumBoxBytes,
                  value.grantDigest == hash(grant) else { throw SecurePairingCoordinatorError.invalidRelay }
        } else if value.grant != nil || value.grantDigest != nil { throw SecurePairingCoordinatorError.invalidRelay }
    }
    private func bind(_ value: SecurePairingSnapshot, creator: String, conversation: String, expiry: UInt64, offer: Data) throws {
        try validate(value)
        guard exact(value.creatorID, creator), exact(value.conversationID, conversation),
              value.expiresAtMilliseconds == expiry, value.offer == offer else { throw SecurePairingCoordinatorError.conflictingTranscript }
    }
    private func bind(_ state: CreatorPairingState, handle: PendingPairingHandle) throws {
        guard exact(state.creatorID, account), exact(state.conversationID, handle.conversationID),
              exact(state.invite.locatorHex, handle.scope.inviteID), state.keyEpoch == 1 else {
            throw SecurePairingCoordinatorError.conflictingTranscript
        }
    }
    private func bindClaim(_ value: SecurePairingSnapshot, account: String, claimID: String, acceptance: Data) throws {
        guard exact(value.claimantID ?? "", account), exact(value.claimID ?? "", claimID),
              value.acceptance == acceptance else { throw SecurePairingCoordinatorError.conflictingTranscript }
    }
    private func bindRecipient(_ value: SecurePairingSnapshot, state: RecipientPairingState) throws {
        try bind(value, creator: state.creatorID, conversation: state.conversationID,
                 expiry: state.expiresAtMilliseconds, offer: state.publicOfferBytes)
        try bindClaim(value, account: state.recipientID, claimID: state.claimIDHex, acceptance: state.publicAcceptanceBytes)
    }
    private func stored(_ value: AuthenticatedPairingCapsule) throws -> StoredConversationCapsule {
        try StoredConversationCapsule(localAccountID: value.localAccountID, creatorID: value.creatorID,
            recipientID: value.recipientID, conversationID: value.conversationID, keyEpoch: value.keyEpoch,
            suite: value.contentSuite, epochKey: value.keyMaterialForLocalStorage(), transcriptHash: value.transcriptHash,
            protocolKeyCommitment: value.protocolKeyCommitment, expectedKeyCommitment: value.expectedKeyCommitment)
    }
    private func hash(_ bytes: Data) -> Data { Data(SHA256.hash(data: bytes)) }
    private func exact(_ a: String, _ b: String) -> Bool { Data(a.utf8) == Data(b.utf8) }
}
