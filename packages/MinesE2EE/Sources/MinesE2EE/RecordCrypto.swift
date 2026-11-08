import CryptoKit
import Foundation

public enum RecordKind: String, CaseIterable, Sendable {
    case message
    case reaction
    case location
    case notificationPreview = "notification-preview"
    case attachmentKey = "attachment-key"
}

public struct RecordContext: Equatable, Sendable {
    public let conversationID: String
    public let recordID: String
    public let senderID: String
    public let kind: RecordKind
    public let keyEpoch: UInt32
    public let revision: UInt64

    public init(conversationID: String, recordID: String, senderID: String,
                kind: RecordKind = .message, keyEpoch: UInt32, revision: UInt64) throws {
        try validateIdentifier(conversationID)
        try validateIdentifier(recordID)
        try validateIdentifier(senderID)
        guard keyEpoch > 0, revision > 0 else { throw E2EEError.invalidContext }
        self.conversationID = conversationID
        self.recordID = recordID
        self.senderID = senderID
        self.kind = kind
        self.keyEpoch = keyEpoch
        self.revision = revision
    }

    func appendFields(to writer: inout BinaryWriter) {
        writer.string(conversationID)
        writer.string(recordID)
        writer.string(senderID)
        writer.uint32(keyEpoch)
        writer.string(kind.rawValue)
        writer.uint64(revision)
    }

    var canonicalBytes: Data {
        var writer = BinaryWriter()
        writer.bytes(Data("mines/e2ee/v1/record".utf8))
        appendFields(to: &writer)
        return writer.data
    }

    // Swift String equality normalizes Unicode; protocol identifiers are byte-exact.
    public static func == (lhs: RecordContext, rhs: RecordContext) -> Bool {
        lhs.canonicalBytes == rhs.canonicalBytes
    }

    var salt: Data {
        var writer = BinaryWriter()
        writer.bytes(Data("mines/e2ee/v1/salt".utf8))
        writer.string(conversationID)
        return Data(SHA256.hash(data: writer.data))
    }

    var authenticatedData: Data {
        Data("mines/e2ee/v1/aad".utf8) + canonicalBytes
    }

    static func read(from reader: inout BinaryReader) throws -> RecordContext {
        let conversation = try reader.string(maximum: POCLimits.identifierBytes)
        let record = try reader.string(maximum: POCLimits.identifierBytes)
        let sender = try reader.string(maximum: POCLimits.identifierBytes)
        let epoch = try reader.uint32()
        let kindString = try reader.string(maximum: POCLimits.identifierBytes)
        guard let kind = RecordKind(rawValue: kindString) else { throw E2EEError.unsupportedRecordKind }
        let revision = try reader.uint64()
        return try RecordContext(conversationID: conversation, recordID: record, senderID: sender,
                                 kind: kind, keyEpoch: epoch, revision: revision)
    }
}

/// Isolated POC, not integrated with the apps. No forward secrecy, sender signature,
/// identity exchange, key revocation, or durable rollback defense is provided here.
/// Anyone holding the shared epoch key can authenticate a record claiming either sender.
/// The caller must persist the returned bytes once, then resend those exact bytes on retry.
public enum RecordCipher {
    static let magic = Data("mines/poc/record".utf8)
    static let suite = "mines-e2ee-v1"

    public static func seal(_ plaintext: Data, context: RecordContext, epochKey: SymmetricKey) throws -> Data {
        try seal(plaintext, context: context, epochKey: epochKey, nonce: ChaChaPoly.Nonce())
    }

    // Deterministic nonce injection is internal solely for independent known-answer fixtures.
    static func seal(_ plaintext: Data, context: RecordContext, epochKey: SymmetricKey,
                     nonce: ChaChaPoly.Nonce) throws -> Data {
        guard plaintext.count <= POCLimits.recordPlaintextBytes else { throw E2EEError.sizeLimitExceeded }
        let key = try derivedKey(context: context, epochKey: epochKey)
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce,
                                      authenticating: context.authenticatedData)
        var writer = BinaryWriter()
        writer.bytes(magic)
        writer.uint32(1)
        writer.string(suite)
        context.appendFields(to: &writer)
        writer.bytes(Data(box.nonce))
        writer.lengthPrefixed(box.ciphertext)
        writer.bytes(box.tag)
        return writer.data
    }

    public static func open(_ envelope: Data, expectedContext: RecordContext,
                            epochKey: SymmetricKey) throws -> Data {
        guard envelope.count <= POCLimits.recordEnvelopeBytes else { throw E2EEError.sizeLimitExceeded }
        guard epochKey.bitCount == 256 else { throw E2EEError.invalidKey }
        let decoded = try decode(envelope)
        guard decoded.context == expectedContext else { throw E2EEError.contextMismatch }
        let key = try derivedKey(context: expectedContext, epochKey: epochKey)
        do {
            return try ChaChaPoly.open(decoded.box, using: key, authenticating: expectedContext.authenticatedData)
        } catch { throw E2EEError.authenticationFailed }
    }

    static func derivedKey(context: RecordContext, epochKey: SymmetricKey) throws -> SymmetricKey {
        guard epochKey.bitCount == 256 else { throw E2EEError.invalidKey }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: epochKey, salt: context.salt,
                                      info: context.canonicalBytes, outputByteCount: 32)
    }

    static func decode(_ envelope: Data) throws -> (context: RecordContext, box: ChaChaPoly.SealedBox) {
        guard envelope.count <= POCLimits.recordEnvelopeBytes else { throw E2EEError.sizeLimitExceeded }
        var reader = BinaryReader(envelope)
        try reader.expect(magic)
        guard try reader.uint32() == 1 else { throw E2EEError.unsupportedVersion }
        guard try reader.string(maximum: POCLimits.identifierBytes) == suite else { throw E2EEError.unsupportedSuite }
        let context = try RecordContext.read(from: &reader)
        let nonce = try reader.bytes(12)
        let ciphertext = try reader.lengthPrefixed(maximum: POCLimits.recordPlaintextBytes)
        let tag = try reader.bytes(16)
        guard reader.isAtEnd else { throw E2EEError.malformedEnvelope }
        return (context, try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: nonce),
                                                ciphertext: ciphertext, tag: tag))
    }
}

/// Demonstrates local replay rules only. Production needs durable, atomic state shared
/// with its outbox; fresh-device history rollback is NOT prevented by this in-memory guard.
public struct RecordReplayGuard {
    private struct Identity: Hashable {
        let conversation: Data
        let record: Data
        let kind: String
        let epoch: UInt32
    }
    private var accepted: [Identity: (revision: UInt64, digest: SHA256.Digest)] = [:]
    public init() {}

    public mutating func openAndAccept(_ envelope: Data, expectedContext: RecordContext,
                                       epochKey: SymmetricKey) throws -> Data {
        let plaintext = try RecordCipher.open(envelope, expectedContext: expectedContext, epochKey: epochKey)
        let identity = Identity(conversation: Data(expectedContext.conversationID.utf8), record: Data(expectedContext.recordID.utf8),
                                kind: expectedContext.kind.rawValue, epoch: expectedContext.keyEpoch)
        let digest = SHA256.hash(data: envelope)
        if let previous = accepted[identity] {
            guard expectedContext.revision >= previous.revision else { throw E2EEError.staleRevision }
            if expectedContext.revision == previous.revision, digest != previous.digest {
                throw E2EEError.revisionConflict
            }
        }
        accepted[identity] = (expectedContext.revision, digest)
        return plaintext
    }
}
