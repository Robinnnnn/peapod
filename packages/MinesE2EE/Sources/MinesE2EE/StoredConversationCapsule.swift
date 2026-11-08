import CryptoKit
import Foundation

/// One atomic trusted record. Construct only from authenticated pairing, never server key material.
/// Creator then recipient is the canonical role order. IDs are compared as raw UTF-8 bytes.
public struct StoredConversationCapsule: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public static let contentSuite = "mines-e2ee-v1"
    public static let maximumEncodedBytes = 4096
    public let localAccountID: String
    public let creatorID: String
    public let recipientID: String
    public let conversationID: String
    public let keyEpoch: UInt32
    public let suite: String
    public let transcriptHash: Data
    public let protocolKeyCommitment: Data
    public let expectedKeyCommitment: Data
    private let key: Data

    public var scope: KeyScope {
        KeyScope(accountID: localAccountID, conversationID: conversationID, epoch: keyEpoch)
    }

    public init(localAccountID: String, creatorID: String, recipientID: String,
                conversationID: String, keyEpoch: UInt32, suite: String = Self.contentSuite,
                epochKey: Data, transcriptHash: Data, protocolKeyCommitment: Data,
                expectedKeyCommitment: Data) throws {
        for value in [localAccountID, creatorID, recipientID, conversationID] { try validateStoredKeyIdentifier(value) }
        guard Data(creatorID.utf8) != Data(recipientID.utf8),
              [Data(creatorID.utf8), Data(recipientID.utf8)].contains(Data(localAccountID.utf8)) else {
            throw ConversationKeyStoreError.identityMismatch
        }
        guard let id = UUID(uuidString: conversationID), id.uuidString.lowercased() == conversationID,
              keyEpoch > 0 else { throw ConversationKeyStoreError.invalidScope }
        guard suite == Self.contentSuite else { throw ConversationKeyStoreError.unsupportedSuite }
        guard epochKey.count == 32, transcriptHash.count == 32, protocolKeyCommitment.count == 32,
              expectedKeyCommitment.count == 32 else { throw ConversationKeyStoreError.invalidEncoding }
        let scope = KeyScope(accountID: localAccountID, conversationID: conversationID, epoch: keyEpoch)
        let expectedLocal = try TrustedKeyDescriptor.commitment(for: epochKey, scope: scope)
        let expectedProtocol = try Self.protocolCommitment(epochKey: epochKey, conversationID: conversationID, keyEpoch: keyEpoch)
        guard Self.equalDigest(expectedKeyCommitment, expectedLocal),
              Self.equalDigest(protocolKeyCommitment, expectedProtocol) else { throw ConversationKeyStoreError.invalidCommitment }
        self.localAccountID = localAccountID
        self.creatorID = creatorID
        self.recipientID = recipientID
        self.conversationID = conversationID
        self.keyEpoch = keyEpoch
        self.suite = suite
        self.key = epochKey
        self.transcriptHash = transcriptHash
        self.protocolKeyCommitment = protocolKeyCommitment
        self.expectedKeyCommitment = expectedKeyCommitment
    }

    /// This matches the pairing protocol's account-independent offer commitment.
    /// Computing a digest does not authenticate a pairing or establish trust.
    public static func protocolCommitment(epochKey: Data, conversationID: String, keyEpoch: UInt32) throws -> Data {
        try validateStoredKeyIdentifier(conversationID)
        guard epochKey.count == 32, keyEpoch > 0 else { throw ConversationKeyStoreError.invalidEncoding }
        var writer = BinaryWriter()
        writer.bytes(Data("mines/pairing/v1/epoch-key\0".utf8))
        writer.string(conversationID)
        writer.uint32(keyEpoch)
        writer.string(contentSuite)
        writer.bytes(epochKey)
        return Data(SHA256.hash(data: writer.data))
    }

    public func trustedDescriptor() throws -> TrustedKeyDescriptor {
        try TrustedKeyDescriptor(scope: scope, expectedKeyCommitment: expectedKeyCommitment)
    }

    /// Explicit secret export for native local storage/crypto only. Never log these bytes.
    public func keyMaterialForLocalStorage() -> Data { key }

    /// The entire key, both identities, trust evidence and commitments are one Keychain value.
    public func encodedForLocalStorage() -> Data {
        var writer = BinaryWriter()
        writer.bytes(Data("MCKC".utf8))
        writer.uint32(1)
        writer.string(localAccountID)
        writer.string(creatorID)
        writer.string(recipientID)
        writer.string(conversationID)
        writer.uint32(keyEpoch)
        writer.string(suite)
        writer.bytes(key)
        writer.bytes(transcriptHash)
        writer.bytes(protocolKeyCommitment)
        writer.bytes(expectedKeyCommitment)
        return writer.data
    }

    public init(localStorage bytes: Data) throws {
        guard bytes.count <= Self.maximumEncodedBytes else { throw ConversationKeyStoreError.sizeLimitExceeded }
        do {
            var reader = BinaryReader(bytes)
            try reader.expect(Data("MCKC".utf8))
            guard try reader.uint32() == 1 else { throw ConversationKeyStoreError.unsupportedVersion }
            let local = try reader.string(maximum: 256)
            let creator = try reader.string(maximum: 256)
            let recipient = try reader.string(maximum: 256)
            let conversation = try reader.string(maximum: 256)
            let epoch = try reader.uint32()
            let suite = try reader.string(maximum: 64)
            let key = try reader.bytes(32)
            let transcript = try reader.bytes(32)
            let protocolCommitment = try reader.bytes(32)
            let expectedCommitment = try reader.bytes(32)
            guard reader.isAtEnd else { throw ConversationKeyStoreError.invalidEncoding }
            try self.init(localAccountID: local, creatorID: creator, recipientID: recipient,
                          conversationID: conversation, keyEpoch: epoch, suite: suite, epochKey: key,
                          transcriptHash: transcript, protocolKeyCommitment: protocolCommitment,
                          expectedKeyCommitment: expectedCommitment)
        } catch let error as ConversationKeyStoreError { throw error }
        catch { throw ConversationKeyStoreError.invalidEncoding }
    }

    fileprivate func matches(_ expected: KeyScope) -> Bool {
        Data(localAccountID.utf8) == Data(expected.accountID.utf8)
            && Data(conversationID.utf8) == Data(expected.conversationID.utf8)
            && keyEpoch == expected.epoch
    }

    private static func equalDigest(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    public var description: String { "StoredConversationCapsule(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Native read-only adapter plus explicit trusted-pairing insertion. There is no delete operation.
/// Each participant stores their own capsule; iCloud's account domain is distinct from Firebase auth.
public actor ConversationCapsuleStore: EpochKeyReader {
    private let keychain: ImmutableScopedKeychain
    private var observedCapsules: [Data: Data] = [:]
    private var conflictingScopes: Set<Data> = []

    public init(namespace: ConversationKeychainNamespace) {
        keychain = ImmutableScopedKeychain(namespace: namespace, name: "conversation-capsule", synchronizable: true,
                                           maximumBytes: StoredConversationCapsule.maximumEncodedBytes,
                                           backend: SecurityKeychainBackend())
    }

    init(namespace: ConversationKeychainNamespace, backend: any KeychainBackend) {
        keychain = ImmutableScopedKeychain(namespace: namespace, name: "conversation-capsule", synchronizable: true,
                                           maximumBytes: StoredConversationCapsule.maximumEncodedBytes, backend: backend)
    }

    public func insertAuthenticatedCapsule(_ capsule: StoredConversationCapsule) throws {
        let scope = try storedKeyScope(capsule.scope)
        let bytes = capsule.encodedForLocalStorage()
        try requireMatchingObservation(bytes, scope: scope)
        do { try keychain.insert(bytes, scope: scope) }
        catch ConversationKeyStoreError.conflict {
            conflictingScopes.insert(scope)
            throw ConversationKeyStoreError.conflict
        }
        observedCapsules[scope] = bytes
    }

    /// nil means no visible record; never reconstruct trust from a server-selected digest or key.
    public func readCapsule(scope: KeyScope) throws -> StoredConversationCapsule? {
        let storageScope = try storedKeyScope(scope)
        guard !conflictingScopes.contains(storageScope) else { throw ConversationKeyStoreError.conflict }
        guard let bytes = try keychain.read(scope: storageScope) else { return nil }
        let capsule = try StoredConversationCapsule(localStorage: bytes)
        guard capsule.matches(scope) else { throw ConversationKeyStoreError.identityMismatch }
        try requireMatchingObservation(bytes, scope: storageScope)
        observedCapsules[storageScope] = bytes
        return capsule
    }

    /// A fresh device obtains the descriptor from the trusted atomic Keychain capsule itself.
    public func trustedDescriptor(scope: KeyScope) throws -> TrustedKeyDescriptor? {
        try readCapsule(scope: scope)?.trustedDescriptor()
    }

    public func read(scope: KeyScope) async -> EpochKeyReadResult {
        do {
            if let capsule = try readCapsule(scope: scope) { return .found(capsule.keyMaterialForLocalStorage()) }
            return .missing
        } catch ConversationKeyStoreError.securityStatus(let status) { return .unavailable(status) }
        catch ConversationKeyStoreError.conflict { return .conflictingExpectedKey }
        catch ConversationKeyStoreError.invalidConfiguration { return .readerFailure }
        catch { return .invalidBytes }
    }

    /// iCloud is eventually consistent. Pin only observed history; a fresh process cannot detect
    /// an earlier overwritten capsule. Authenticated pairing and durable peer binding remain required.
    private func requireMatchingObservation(_ bytes: Data, scope: Data) throws {
        guard !conflictingScopes.contains(scope) else { throw ConversationKeyStoreError.conflict }
        if let observed = observedCapsules[scope], observed != bytes {
            conflictingScopes.insert(scope)
            throw ConversationKeyStoreError.conflict
        }
    }
}

/// Pins the exact authenticated capsule before the first native read, even with a fresh store.
/// Derive the descriptor through this reader and use it with KeyReadinessController. A separately
/// created unpinned reader would otherwise lose peer/transcript provenance while retaining the key.
public actor PinnedConversationCapsuleReader: EpochKeyReader {
    private let store: ConversationCapsuleStore
    private let expected: StoredConversationCapsule
    private var conflicted = false

    public init(namespace: ConversationKeychainNamespace, expectedCapsule: StoredConversationCapsule) {
        store = ConversationCapsuleStore(namespace: namespace)
        expected = expectedCapsule
    }

    public init(store: ConversationCapsuleStore, expectedCapsule: StoredConversationCapsule) {
        self.store = store
        expected = expectedCapsule
    }

    public func trustedDescriptor() throws -> TrustedKeyDescriptor { try expected.trustedDescriptor() }

    public func read(scope: KeyScope) async -> EpochKeyReadResult {
        if conflicted { return .conflictingExpectedKey }
        guard expected.matches(scope) else { conflicted = true; return .conflictingExpectedKey }
        do {
            let capsule = try await store.readCapsule(scope: scope)
            if conflicted { return .conflictingExpectedKey }
            guard let capsule else { return .missing }
            guard capsule.encodedForLocalStorage() == expected.encodedForLocalStorage() else {
                conflicted = true
                return .conflictingExpectedKey
            }
            return .found(capsule.keyMaterialForLocalStorage())
        } catch ConversationKeyStoreError.securityStatus(let status) { return .unavailable(status) }
        catch ConversationKeyStoreError.conflict { conflicted = true; return .conflictingExpectedKey }
        catch { return .invalidBytes }
    }
}
