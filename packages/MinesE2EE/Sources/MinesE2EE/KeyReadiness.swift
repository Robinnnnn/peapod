import CryptoKit
import Foundation
import Security

public enum KeyLifecycleError: Error, Equatable, Sendable {
    case invalidDescriptor
    case invalidKey
    case staleSession
    case closedConversation
    case conflictingExpectedKey
}

/// A commitment supplied by authenticated pairing, never an arbitrary server-selected digest.
/// The conversation ID is a globally unique generation and must never be reused after closure.
public struct TrustedKeyDescriptor: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let scope: KeyScope
    private let expectedCommitment: Data

    public init(scope: KeyScope, expectedKeyCommitment: Data) throws {
        try Self.validate(scope)
        guard expectedKeyCommitment.count == SHA256.byteCount else {
            throw KeyLifecycleError.invalidDescriptor
        }
        self.scope = scope
        self.expectedCommitment = expectedKeyCommitment
    }

    /// Pairing must authenticate this exact scope and commitment before constructing a descriptor.
    /// This helper computes bytes only; it does not confer trust or authenticate a server response.
    public static func commitment(for key: Data, scope: KeyScope) throws -> Data {
        try validate(scope)
        guard key.count == 32 else { throw KeyLifecycleError.invalidKey }
        var input = Data("mines.poc.key-commitment.v1\0".utf8)
        for value in [Data(scope.accountID.utf8), Data(scope.conversationID.utf8)] {
            append(UInt32(value.count), to: &input)
            input.append(value)
        }
        append(scope.epoch, to: &input)
        input.append(key)
        return Data(SHA256.hash(data: input))
    }

    fileprivate func accepts(_ key: Data) -> Bool {
        guard let actual = try? Self.commitment(for: key, scope: scope) else { return false }
        // Both digests have fixed size. Do not report either fingerprint on conflict.
        return zip(actual, expectedCommitment).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func validate(_ scope: KeyScope) throws {
        guard scope.epoch > 0, !scope.accountID.utf8.isEmpty, !scope.conversationID.utf8.isEmpty,
              scope.accountID.utf8.count <= 256, scope.conversationID.utf8.count <= 256 else {
            throw KeyLifecycleError.invalidDescriptor
        }
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
                                 UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }

    public var description: String { "TrustedKeyDescriptor(redacted)" }
    public var debugDescription: String { description }
}

/// This reader has no create, replace or delete capability.
public protocol EpochKeyReader: Sendable {
    func read(scope: KeyScope) async -> EpochKeyReadResult
}

public enum EpochKeyReadResult: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case found(Data)
    /// No visible item; sync and entitlement state remain unproven.
    case missing
    case unavailable(OSStatus)
    case invalidBytes
    case readerFailure
    case conflictingExpectedKey

    public var description: String {
        switch self {
        case .found: "found(redacted)"
        case .missing: "missing"
        case .unavailable(let status): "unavailable(\(status))"
        case .invalidBytes: "invalidBytes"
        case .readerFailure: "readerFailure"
        case .conflictingExpectedKey: "conflictingExpectedKey"
        }
    }
    public var debugDescription: String { description }
}

/// Actor confines the non-Sendable Security backend; only the existing scoped read is exposed.
public actor SynchronizableEpochKeyReader: EpochKeyReader {
    private let store: SynchronizableKeyStore

    public init(accessGroup: String) throws {
        store = try SynchronizableKeyStore(accessGroup: accessGroup)
    }

    public func read(scope: KeyScope) async -> EpochKeyReadResult {
        do {
            if let bytes = try store.read(scope: scope) { return .found(bytes) }
            return .missing
        } catch KeyStoreError.securityStatus(let status) {
            return .unavailable(status)
        } catch KeyStoreError.unexpectedResult {
            return .invalidBytes
        } catch {
            return .readerFailure
        }
    }
}

/// Opaque activation identity. Re-activating even the same descriptor creates a different token.
public struct KeySessionToken: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    fileprivate let id = UUID()
    fileprivate init() {}
    public var description: String { "KeySessionToken(redacted)" }
    public var debugDescription: String { description }
}

/// No public key accessor. Every operation must validate this lease through its originating actor.
public struct ReadyKeyLease: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    fileprivate let token: KeySessionToken
    fileprivate let bytes: Data
    fileprivate init(token: KeySessionToken, bytes: Data) { self.token = token; self.bytes = bytes }
    public var description: String { "ReadyKeyLease(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public enum KeyReadiness: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case signedOut
    case awaitingSync
    case unavailable(OSStatus)
    case invalidBytes
    case conflictingExpectedKey
    case ready(ReadyKeyLease)
    case staleSession
    case closedConversation
    case readerFailure

    public var description: String {
        switch self {
        case .signedOut: "signedOut"
        case .awaitingSync: "awaitingSync"
        case .unavailable(let status): "unavailable(\(status))"
        case .invalidBytes: "invalidBytes"
        case .conflictingExpectedKey: "conflictingExpectedKey"
        case .ready: "ready(redacted)"
        case .staleSession: "staleSession"
        case .closedConversation: "closedConversation"
        case .readerFailure: "readerFailure"
        }
    }
    public var debugDescription: String { description }
}

/// In-memory session gate only. The caller must persist conversation tombstones before transport.
/// Authentication/pairing supplies trusted descriptors. This actor cannot establish their trust.
public actor KeyReadinessController {
    private struct ActiveSession {
        let token: KeySessionToken
        let descriptor: TrustedKeyDescriptor
    }
    private struct Conversation: Hashable {
        let account: Data
        let conversation: Data
        init(_ scope: KeyScope) {
            account = Data(scope.accountID.utf8)
            conversation = Data(scope.conversationID.utf8)
        }
    }
    private let reader: any EpochKeyReader
    private var active: ActiveSession?
    private var activeHasConflict = false
    private var closedConversations: Set<Conversation> = []
    private var closedTokens: Set<KeySessionToken> = []

    public init(reader: any EpochKeyReader) { self.reader = reader }

    public func activate(_ descriptor: TrustedKeyDescriptor) throws -> KeySessionToken {
        guard !closedConversations.contains(Conversation(descriptor.scope)) else {
            throw KeyLifecycleError.closedConversation
        }
        let token = KeySessionToken()
        active = ActiveSession(token: token, descriptor: descriptor)
        activeHasConflict = false
        return token
    }

    /// Drops session access only. No Keychain mutation occurs.
    public func signOut() { active = nil; activeHasConflict = false }

    /// Closes the entire unique conversation ID, across epochs, for this account.
    public func closeConversation(token: KeySessionToken) throws {
        guard let active, active.token == token else { throw KeyLifecycleError.staleSession }
        closedConversations.insert(Conversation(active.descriptor.scope))
        closedTokens.insert(token)
        self.active = nil
    }

    public func read(token: KeySessionToken) async -> KeyReadiness {
        if closedTokens.contains(token) { return .closedConversation }
        guard let captured = active else { return .signedOut }
        guard captured.token == token else { return .staleSession }
        if activeHasConflict { return .conflictingExpectedKey }
        let result = await reader.read(scope: captured.descriptor.scope)
        // Actor reentrancy may have signed out, switched away and back, or closed the conversation.
        guard active?.token == captured.token else { return .staleSession }
        if activeHasConflict { return .conflictingExpectedKey }
        switch result {
        case .missing: return .awaitingSync
        case .unavailable(let status): return .unavailable(status)
        case .invalidBytes: return .invalidBytes
        case .readerFailure: return .readerFailure
        case .conflictingExpectedKey:
            activeHasConflict = true
            return .conflictingExpectedKey
        case .found(let bytes):
            guard bytes.count == 32 else { return .invalidBytes }
            guard captured.descriptor.accepts(bytes) else {
                activeHasConflict = true
                return .conflictingExpectedKey
            }
            return .ready(ReadyKeyLease(token: captured.token, bytes: bytes))
        }
    }

    /// Linearizes local synchronous crypto/enqueue against sign-out and closure.
    /// Do not retain the key, start asynchronous work, or treat completion as remote-send authority.
    /// A copied key cannot be revoked; callers must separately gate transport and durable closure.
    /// All non-conflict read failures preserve prior validated leases while the same token is active.
    /// A commitment conflict freezes every lease and pending read until explicit new activation.
    public func useKey<T: Sendable>(_ lease: ReadyKeyLease,
                                   operation: @Sendable (SymmetricKey, KeyScope) throws -> T) throws -> T {
        if closedTokens.contains(lease.token) { throw KeyLifecycleError.closedConversation }
        guard let active, active.token == lease.token else { throw KeyLifecycleError.staleSession }
        guard !activeHasConflict else { throw KeyLifecycleError.conflictingExpectedKey }
        return try operation(SymmetricKey(data: lease.bytes), active.descriptor.scope)
    }
}
