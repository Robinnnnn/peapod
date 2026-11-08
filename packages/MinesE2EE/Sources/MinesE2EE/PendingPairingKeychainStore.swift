import CryptoKit
import Darwin
import Foundation

public struct PendingPairingScope: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public enum Role: UInt32, Sendable { case creator = 1, recipient = 2 }
    public let localAccountID: String
    public let inviteID: String
    public let role: Role
    public init(localAccountID: String, inviteID: String, role: Role) throws {
        try validateStoredKeyIdentifier(localAccountID)
        guard inviteID.utf8.count == 32, inviteID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ConversationKeyStoreError.invalidScope
        }
        self.localAccountID = localAccountID
        self.inviteID = inviteID
        self.role = role
    }
    fileprivate func encoded() -> Data {
        var writer = BinaryWriter()
        writer.string(localAccountID)
        writer.string(inviteID)
        writer.uint32(role.rawValue)
        return writer.data
    }
    public var description: String { "PendingPairingScope(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public enum PendingPairingStage: UInt32, Sendable {
    case initialState = 1
    case acceptedClaim = 2
    case sealedGrant = 3
}

public struct PendingPairingPin: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let initialStateDigest: Data
    fileprivate init(_ bytes: Data) { initialStateDigest = Data(SHA256.hash(data: bytes)) }
    fileprivate init(digest: Data) { initialStateDigest = digest }
    public var description: String { "PendingPairingPin(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Immutable device-local stage. The opaque payload may contain private keys; never log it.
public struct PendingPairingRecord: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let stage: PendingPairingStage
    public let initialStateDigest: Data
    public let acceptedClaimDigest: Data?
    fileprivate let payload: Data
    fileprivate init(stage: PendingPairingStage, initialStateDigest: Data, payload: Data, acceptedClaimDigest: Data? = nil) {
        self.stage = stage; self.initialStateDigest = initialStateDigest; self.payload = payload
        self.acceptedClaimDigest = acceptedClaimDigest
    }
    public var initialStatePin: PendingPairingPin { PendingPairingPin(digest: initialStateDigest) }
    public func opaqueBytesForLocalStorage() -> Data { payload }
    public var payloadDigest: Data { Data(SHA256.hash(data: payload)) }
    public var description: String { "PendingPairingRecord(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Add-only stage pinning under a cross-process advisory lock. Every process must use the same
/// App Group coordination directory. Invite IDs are unique and are never reused after termination.
/// Device-local state must not synchronize: the initiating device owns its claim and grant.
public actor PendingPairingKeychainStore {
    public static let maximumOpaqueBytes = 32 * 1024
    public static let maximumSealedGrantBytes = 8 * 1024
    private let keychain: ImmutableScopedKeychain
    private let coordinationDirectory: URL

    public init(namespace: ConversationKeychainNamespace, coordinationDirectory: URL) throws {
        guard coordinationDirectory.isFileURL, coordinationDirectory.path.hasPrefix("/") else {
            throw ConversationKeyStoreError.invalidConfiguration
        }
        self.coordinationDirectory = coordinationDirectory
        keychain = ImmutableScopedKeychain(namespace: namespace, name: "pending-pairing", synchronizable: false,
                                           maximumBytes: Self.maximumOpaqueBytes + 4096, backend: SecurityKeychainBackend())
    }

    init(namespace: ConversationKeychainNamespace, coordinationDirectory: URL, backend: any KeychainBackend) throws {
        guard coordinationDirectory.isFileURL, coordinationDirectory.path.hasPrefix("/") else {
            throw ConversationKeyStoreError.invalidConfiguration
        }
        self.coordinationDirectory = coordinationDirectory
        keychain = ImmutableScopedKeychain(namespace: namespace, name: "pending-pairing", synchronizable: false,
                                           maximumBytes: Self.maximumOpaqueBytes + 4096, backend: backend)
    }

    public func pinInitialState(_ bytes: Data, scope: PendingPairingScope) throws -> PendingPairingPin {
        try withLock(scope) {
            try requireActive(scope)
            try validateOpaque(bytes)
            let pin = PendingPairingPin(bytes)
            let record = PendingPairingRecord(stage: .initialState, initialStateDigest: pin.initialStateDigest, payload: bytes)
            try keychain.insert(encode(record, scope: scope), scope: stageScope(scope, stage: .initialState))
            return pin
        }
    }

    /// Pin the exact accepted creator-state/acceptance before deriving or publishing a grant.
    /// Sealed grant requires the caller's exact persisted claim digest, never an in-memory claim.
    public func pinStage(_ stage: PendingPairingStage, bytes: Data, scope: PendingPairingScope,
                         pin: PendingPairingPin, acceptedClaimDigest: Data? = nil) throws {
        guard stage != .initialState else { throw ConversationKeyStoreError.invalidScope }
        try withLock(scope) {
            try requireActive(scope)
            try validateOpaque(bytes, maximum: stage == .sealedGrant ? Self.maximumSealedGrantBytes : Self.maximumOpaqueBytes)
            guard let initial = try readRecord(.initialState, scope: scope) else { throw ConversationKeyStoreError.missingPrerequisite }
            guard initial.initialStateDigest == pin.initialStateDigest else { throw ConversationKeyStoreError.conflict }
            if stage == .sealedGrant {
                guard let claim = try readRecord(.acceptedClaim, scope: scope) else { throw ConversationKeyStoreError.missingPrerequisite }
                guard let acceptedClaimDigest, acceptedClaimDigest.count == 32,
                      claim.payloadDigest == acceptedClaimDigest, claim.initialStateDigest == pin.initialStateDigest else {
                    throw ConversationKeyStoreError.conflict
                }
            } else if acceptedClaimDigest != nil { throw ConversationKeyStoreError.invalidScope }
            let record = PendingPairingRecord(stage: stage, initialStateDigest: pin.initialStateDigest, payload: bytes,
                                              acceptedClaimDigest: acceptedClaimDigest)
            try keychain.insert(encode(record, scope: scope), scope: stageScope(scope, stage: stage))
        }
    }

    public func readStage(_ stage: PendingPairingStage, scope: PendingPairingScope) throws -> PendingPairingRecord? {
        try withLock(scope) {
            try requireActive(scope)
            guard let record = try readRecord(stage, scope: scope) else { return nil }
            if stage != .initialState {
                guard let initial = try readRecord(.initialState, scope: scope) else { throw ConversationKeyStoreError.missingPrerequisite }
                guard record.initialStateDigest == initial.initialStateDigest else { throw ConversationKeyStoreError.conflict }
            }
            if stage == .sealedGrant {
                guard let claim = try readRecord(.acceptedClaim, scope: scope) else { throw ConversationKeyStoreError.missingPrerequisite }
                guard record.acceptedClaimDigest == claim.payloadDigest, claim.initialStateDigest == record.initialStateDigest else {
                    throw ConversationKeyStoreError.conflict
                }
            }
            return record
        }
    }

    public enum TerminalStatus: Sendable { case cancelled, consumed }

    /// Non-secret durable decision for cancellation retry. Malformed tombstones fail closed.
    public func terminalStatus(scope: PendingPairingScope) throws -> TerminalStatus? {
        try withLock(scope) { try readTerminalStatus(scope) }
    }

    /// Retry exact device-local cleanup after a terminal decision survived an OS deletion failure.
    /// Missing/malformed tombstones fail closed. The durable tombstone and synchronized capsules
    /// are never deleted, and this method cannot authorize activation or new pairing stages.
    @discardableResult
    public func retryTerminalCleanup(scope: PendingPairingScope) throws -> TerminalStatus {
        try withLock(scope) {
            guard let terminal = try readTerminalStatus(scope) else { throw ConversationKeyStoreError.missingPrerequisite }
            for stage in [PendingPairingStage.initialState, .acceptedClaim, .sealedGrant] {
                try keychain.deleteLocal(scope: stageScope(scope, stage: stage))
            }
            return terminal
        }
    }

    /// Explicit local retirement after the caller verifies deletion of the conversation
    /// bound to its account-scoped handle. Never authorizes pairing or erases a synced capsule.
    /// A missing initial stage is terminalized with a scope-derived sentinel, not regenerated.
    public func retireAfterVerifiedConversationDeletion(scope: PendingPairingScope) throws {
        try withLock(scope) {
            if try readTerminalStatus(scope) != nil {
                for stage in [PendingPairingStage.initialState, .acceptedClaim, .sealedGrant] {
                    try keychain.deleteLocal(scope: stageScope(scope, stage: stage))
                }
                return
            }
            let pin = try readRecord(.initialState, scope: scope)?.initialStatePin
                ?? PendingPairingPin(Data("mines/pending-retirement/v1\0".utf8) + scope.encoded())
            try terminate(scope, pin: pin, decision: 1, grantDigest: nil)
        }
    }

    private func readTerminalStatus(_ scope: PendingPairingScope) throws -> TerminalStatus? {
        guard let bytes = try keychain.read(scope: terminalScope(scope)) else { return nil }
        do {
            var reader = BinaryReader(bytes)
            try reader.expect(Data("PPTM".utf8))
            guard try reader.uint32() == 1 else { throw ConversationKeyStoreError.unsupportedVersion }
            guard Data(try reader.string(maximum: 256).utf8) == Data(scope.localAccountID.utf8),
                  Data(try reader.string(maximum: 256).utf8) == Data(scope.inviteID.utf8),
                  try reader.uint32() == scope.role.rawValue else { throw ConversationKeyStoreError.identityMismatch }
            let decision = try reader.uint32()
            _ = try reader.bytes(32)
            if decision == 2 { _ = try reader.bytes(32) }
            guard reader.isAtEnd, decision == 1 || decision == 2 else { throw ConversationKeyStoreError.invalidEncoding }
            return decision == 1 ? .cancelled : .consumed
        } catch let error as ConversationKeyStoreError { throw error }
        catch { throw ConversationKeyStoreError.invalidEncoding }
    }

    /// Explicit cleanup only. Terminal tombstone is retained before deleting exact local stages.
    /// Cancellation does not revoke already exported/published grants; transport must recheck it.
    public func cancelAndCleanUp(scope: PendingPairingScope, pin: PendingPairingPin) throws {
        try withLock(scope) { try terminate(scope, pin: pin, decision: 1, grantDigest: nil) }
    }

    /// Caller invokes only after trusted capsule installation and exact grant acknowledgement.
    /// Retains a consumed tombstone so delayed callbacks cannot recreate ephemeral pairing state.
    public func consumeAndCleanUp(scope: PendingPairingScope, pin: PendingPairingPin,
                                  expectedSealedGrantDigest: Data) throws {
        try withLock(scope) {
            if try keychain.read(scope: terminalScope(scope)) == nil {
                guard let grant = try readRecord(.sealedGrant, scope: scope) else { throw ConversationKeyStoreError.missingPrerequisite }
                guard expectedSealedGrantDigest.count == 32, grant.payloadDigest == expectedSealedGrantDigest else {
                    throw ConversationKeyStoreError.conflict
                }
                guard let initial = try readRecord(.initialState, scope: scope), let claim = try readRecord(.acceptedClaim, scope: scope) else {
                    throw ConversationKeyStoreError.missingPrerequisite
                }
                guard initial.initialStateDigest == pin.initialStateDigest, grant.initialStateDigest == pin.initialStateDigest,
                      claim.initialStateDigest == pin.initialStateDigest, grant.acceptedClaimDigest == claim.payloadDigest else {
                    throw ConversationKeyStoreError.conflict
                }
            }
            try terminate(scope, pin: pin, decision: 2, grantDigest: expectedSealedGrantDigest)
        }
    }

    private func terminate(_ scope: PendingPairingScope, pin: PendingPairingPin, decision: UInt32, grantDigest: Data?) throws {
        if let initial = try readRecord(.initialState, scope: scope), initial.initialStateDigest != pin.initialStateDigest {
            throw ConversationKeyStoreError.conflict
        }
        var writer = BinaryWriter()
        writer.bytes(Data("PPTM".utf8)); writer.uint32(1); writer.bytes(scope.encoded())
        writer.uint32(decision); writer.bytes(pin.initialStateDigest)
        if let grantDigest { writer.bytes(grantDigest) }
        // Different terminal decisions conflict rather than replacing a consumed/cancelled invite.
        try keychain.insert(writer.data, scope: terminalScope(scope))
        for stage in [PendingPairingStage.initialState, .acceptedClaim, .sealedGrant] {
            try keychain.deleteLocal(scope: stageScope(scope, stage: stage))
        }
    }

    private func requireActive(_ scope: PendingPairingScope) throws {
        // Presence, even malformed, fails closed. No stage can resurrect a terminal invite.
        if try keychain.read(scope: terminalScope(scope)) != nil { throw ConversationKeyStoreError.terminalInvite }
    }

    private func validateOpaque(_ bytes: Data, maximum: Int = maximumOpaqueBytes) throws {
        guard !bytes.isEmpty else { throw ConversationKeyStoreError.invalidEncoding }
        guard bytes.count <= maximum else { throw ConversationKeyStoreError.sizeLimitExceeded }
    }

    private func stageScope(_ scope: PendingPairingScope, stage: PendingPairingStage) -> Data {
        var writer = BinaryWriter(); writer.bytes(scope.encoded()); writer.uint32(stage.rawValue)
        return writer.data
    }
    private func terminalScope(_ scope: PendingPairingScope) -> Data {
        var writer = BinaryWriter(); writer.bytes(scope.encoded()); writer.uint32(0)
        return writer.data
    }
    private func encode(_ record: PendingPairingRecord, scope: PendingPairingScope) -> Data {
        var writer = BinaryWriter()
        writer.bytes(Data("PPST".utf8)); writer.uint32(1); writer.bytes(scope.encoded())
        writer.uint32(record.stage.rawValue); writer.bytes(record.initialStateDigest)
        writer.uint32(record.acceptedClaimDigest == nil ? 0 : 1)
        if let claimDigest = record.acceptedClaimDigest { writer.bytes(claimDigest) }
        writer.lengthPrefixed(record.payload)
        return writer.data
    }
    private func readRecord(_ stage: PendingPairingStage, scope: PendingPairingScope) throws -> PendingPairingRecord? {
        guard let bytes = try keychain.read(scope: stageScope(scope, stage: stage)) else { return nil }
        do {
            var reader = BinaryReader(bytes)
            try reader.expect(Data("PPST".utf8))
            guard try reader.uint32() == 1 else { throw ConversationKeyStoreError.unsupportedVersion }
            guard Data(try reader.string(maximum: 256).utf8) == Data(scope.localAccountID.utf8),
                  Data(try reader.string(maximum: 256).utf8) == Data(scope.inviteID.utf8),
                  try reader.uint32() == scope.role.rawValue,
                  try reader.uint32() == stage.rawValue else { throw ConversationKeyStoreError.identityMismatch }
            let digest = try reader.bytes(32)
            let hasClaimDigest = try reader.uint32()
            guard hasClaimDigest == (stage == .sealedGrant ? 1 : 0) else { throw ConversationKeyStoreError.invalidEncoding }
            let claimDigest = hasClaimDigest == 1 ? try reader.bytes(32) : nil
            let payload = try reader.lengthPrefixed(maximum: stage == .sealedGrant ? Self.maximumSealedGrantBytes : Self.maximumOpaqueBytes)
            guard reader.isAtEnd, !payload.isEmpty else { throw ConversationKeyStoreError.invalidEncoding }
            if stage == .initialState, digest != Data(SHA256.hash(data: payload)) { throw ConversationKeyStoreError.invalidCommitment }
            return PendingPairingRecord(stage: stage, initialStateDigest: digest, payload: payload, acceptedClaimDigest: claimDigest)
        } catch let error as ConversationKeyStoreError { throw error }
        catch { throw ConversationKeyStoreError.invalidEncoding }
    }

    private func withLock<T>(_ scope: PendingPairingScope, operation: () throws -> T) throws -> T {
        do { try FileManager.default.createDirectory(at: coordinationDirectory, withIntermediateDirectories: true) }
        catch { throw ConversationKeyStoreError.coordinationFailed }
        let name = SHA256.hash(data: scope.encoded()).map { String(format: "%02x", $0) }.joined()
        let url = coordinationDirectory.appendingPathComponent("\(name).lock")
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ConversationKeyStoreError.coordinationFailed }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw ConversationKeyStoreError.coordinationFailed }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }
}
