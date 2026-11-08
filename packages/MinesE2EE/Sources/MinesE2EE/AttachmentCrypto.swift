import CryptoKit
import Foundation

/// This entire descriptor belongs ONLY inside the encrypted message payload.
/// Never send its key, filename, media type, duration, or byte count to the relay.
public struct PrivateAttachment: Equatable, Sendable {
    public let attachmentID: String
    public let key: Data
    public let filename: String
    public let mediaType: String
    public let originalByteCount: Int
    public let voiceDurationMilliseconds: UInt64?

    public init(attachmentID: String, key: Data, filename: String, mediaType: String,
                originalByteCount: Int, voiceDurationMilliseconds: UInt64? = nil) throws {
        try validateIdentifier(attachmentID)
        guard key.count == 32 else { throw E2EEError.invalidKey }
        guard !filename.isEmpty, filename.utf8.count <= 1024,
              !mediaType.isEmpty, mediaType.utf8.count <= 256,
              originalByteCount >= 0, originalByteCount <= POCLimits.attachmentPlaintextBytes else {
            throw E2EEError.invalidAttachmentMetadata
        }
        self.attachmentID = attachmentID
        self.key = key
        self.filename = filename
        self.mediaType = mediaType
        self.originalByteCount = originalByteCount
        self.voiceDurationMilliseconds = voiceDurationMilliseconds
    }
}

public struct SealedAttachment: Sendable {
    /// Persist/upload ONLY these opaque bytes with an opaque object name and application/octet-stream.
    public let bytes: Data
    /// Encrypt this descriptor in MessagePayload before sending it.
    public let privateMetadata: PrivateAttachment
}

/// One-shot v1 attachment format. The 200 MiB ceiling preserves the wire format;
/// callers may lower it. CryptoKit still allocates whole-file buffers, so physical-phone
/// peak memory and foreground/background reliability remain unmeasured.
/// Attachments bind the containing message's revision: this POC requires resealing when
/// that context changes. Production edit/reuse semantics still need protocol review.
public struct AttachmentCipher: Sendable {
    public let maximumPlaintextBytes: Int
    static let magic = Data("mines/poc/attachment".utf8)

    public init(maximumPlaintextBytes: Int = POCLimits.attachmentPlaintextBytes) throws {
        guard maximumPlaintextBytes >= 0, maximumPlaintextBytes <= POCLimits.attachmentPlaintextBytes else {
            throw E2EEError.invalidLimit
        }
        self.maximumPlaintextBytes = maximumPlaintextBytes
    }

    public func seal(_ plaintext: Data, context: RecordContext, attachmentID: String,
                     filename: String, mediaType: String,
                     voiceDurationMilliseconds: UInt64? = nil) throws -> SealedAttachment {
        guard context.kind == .message else { throw E2EEError.invalidContext }
        guard plaintext.count <= maximumPlaintextBytes else { throw E2EEError.sizeLimitExceeded }
        let key = SymmetricKey(size: .bits256)
        let metadata = try PrivateAttachment(attachmentID: attachmentID,
            key: key.withUnsafeBytes { Data($0) }, filename: filename, mediaType: mediaType,
            originalByteCount: plaintext.count, voiceDurationMilliseconds: voiceDurationMilliseconds)
        let aad = authenticatedData(context: context, metadata: metadata)
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: ChaChaPoly.Nonce(), authenticating: aad)
        var writer = BinaryWriter()
        writer.bytes(Self.magic)
        writer.uint32(1)
        context.appendFields(to: &writer)
        writer.string(attachmentID)
        writer.bytes(Data(box.nonce))
        // Reserve once before appending the whole ciphertext and authentication tag.
        writer.data.reserveCapacity(writer.data.count + 4 + plaintext.count + 16)
        writer.lengthPrefixed(box.ciphertext)
        writer.bytes(box.tag)
        return SealedAttachment(bytes: writer.data, privateMetadata: metadata)
    }

    public func open(_ envelope: Data, privateMetadata: PrivateAttachment,
                     expectedContext: RecordContext) throws -> Data {
        // Checks precede slicing or opening the untrusted ciphertext.
        guard envelope.count <= maximumPlaintextBytes + 4096,
              privateMetadata.originalByteCount <= maximumPlaintextBytes else {
            throw E2EEError.sizeLimitExceeded
        }
        guard expectedContext.kind == .message else { throw E2EEError.invalidContext }
        var reader = BinaryReader(envelope)
        try reader.expect(Self.magic)
        guard try reader.uint32() == 1 else { throw E2EEError.unsupportedVersion }
        let context = try RecordContext.read(from: &reader)
        let identifier = try reader.string(maximum: POCLimits.identifierBytes)
        guard context == expectedContext, Data(identifier.utf8) == Data(privateMetadata.attachmentID.utf8) else {
            throw E2EEError.contextMismatch
        }
        let nonce = try reader.bytes(12)
        let ciphertext = try reader.lengthPrefixed(maximum: maximumPlaintextBytes)
        let tag = try reader.bytes(16)
        guard reader.isAtEnd else { throw E2EEError.malformedEnvelope }
        guard ciphertext.count == privateMetadata.originalByteCount else {
            throw E2EEError.invalidAttachmentMetadata
        }
        let box = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
        do {
            return try ChaChaPoly.open(box, using: SymmetricKey(data: privateMetadata.key),
                authenticating: authenticatedData(context: context, metadata: privateMetadata))
        } catch { throw E2EEError.authenticationFailed }
    }

    private func authenticatedData(context: RecordContext, metadata: PrivateAttachment) -> Data {
        var writer = BinaryWriter()
        writer.bytes(Self.magic)
        writer.uint32(1)
        writer.bytes(context.canonicalBytes)
        writer.string(metadata.attachmentID)
        writer.string(metadata.filename)
        writer.string(metadata.mediaType)
        writer.uint64(UInt64(metadata.originalByteCount))
        writer.uint32(metadata.voiceDurationMilliseconds == nil ? 0 : 1)
        if let duration = metadata.voiceDurationMilliseconds { writer.uint64(duration) }
        return writer.data
    }
}
