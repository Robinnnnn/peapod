import CryptoKit
import Foundation

/// Experimental private payload encoding. Does not freeze the production protocol.
/// This binary POC supports UTF-8 text and attachment descriptors only; all fields are encrypted.
public struct MessagePayload: Equatable, Sendable {
    public let text: String
    public let attachments: [PrivateAttachment]

    public init(text: String, attachments: [PrivateAttachment] = []) throws {
        guard text.utf8.count <= POCLimits.messageTextBytes,
              attachments.count <= POCLimits.attachmentsPerMessage else { throw E2EEError.sizeLimitExceeded }
        // Reject ambiguous duplicate attachment references.
        guard Set(attachments.map { Data($0.attachmentID.utf8) }).count == attachments.count else {
            throw E2EEError.invalidAttachmentMetadata
        }
        self.text = text
        self.attachments = attachments
    }

    static let magic = Data("mines/poc/message".utf8)
    func encoded() throws -> Data {
        var writer = BinaryWriter()
        writer.bytes(Self.magic)
        writer.uint32(1)
        writer.string(text)
        writer.uint32(UInt32(attachments.count))
        for attachment in attachments {
            writer.string(attachment.attachmentID)
            writer.bytes(attachment.key)
            writer.string(attachment.filename)
            writer.string(attachment.mediaType)
            writer.uint64(UInt64(attachment.originalByteCount))
            writer.uint32(attachment.voiceDurationMilliseconds == nil ? 0 : 1)
            if let duration = attachment.voiceDurationMilliseconds { writer.uint64(duration) }
        }
        guard writer.data.count <= POCLimits.recordPlaintextBytes else { throw E2EEError.sizeLimitExceeded }
        return writer.data
    }

    static func decode(_ plaintext: Data) throws -> MessagePayload {
        guard plaintext.count <= POCLimits.recordPlaintextBytes else { throw E2EEError.sizeLimitExceeded }
        do {
            var reader = BinaryReader(plaintext)
            try reader.expect(magic)
            guard try reader.uint32() == 1 else { throw E2EEError.unsupportedPayloadVersion }
            let text = try reader.string(maximum: POCLimits.messageTextBytes)
            let count = try reader.uint32()
            guard count <= POCLimits.attachmentsPerMessage else { throw E2EEError.sizeLimitExceeded }
            var attachments: [PrivateAttachment] = []
            for _ in 0..<count {
                let identifier = try reader.string(maximum: POCLimits.identifierBytes)
                let key = try reader.bytes(32)
                let filename = try reader.string(maximum: 1024)
                let mediaType = try reader.string(maximum: 256)
                let size = try reader.uint64()
                guard size <= POCLimits.attachmentPlaintextBytes else { throw E2EEError.sizeLimitExceeded }
                let hasDuration = try reader.uint32()
                guard hasDuration <= 1 else { throw E2EEError.malformedPayload }
                let duration = hasDuration == 1 ? try reader.uint64() : nil
                attachments.append(try PrivateAttachment(attachmentID: identifier, key: key,
                    filename: filename, mediaType: mediaType, originalByteCount: Int(size),
                    voiceDurationMilliseconds: duration))
            }
            guard reader.isAtEnd else { throw E2EEError.malformedPayload }
            return try MessagePayload(text: text, attachments: attachments)
        } catch E2EEError.malformedEnvelope { throw E2EEError.malformedPayload }
    }
}

public enum MessageCipher {
    public static func seal(_ payload: MessagePayload, context: RecordContext,
                            epochKey: SymmetricKey) throws -> Data {
        guard context.kind == .message else { throw E2EEError.invalidContext }
        return try RecordCipher.seal(payload.encoded(), context: context, epochKey: epochKey)
    }

    public static func open(_ envelope: Data, expectedContext: RecordContext,
                            epochKey: SymmetricKey) throws -> MessagePayload {
        guard expectedContext.kind == .message else { throw E2EEError.invalidContext }
        return try MessagePayload.decode(RecordCipher.open(envelope, expectedContext: expectedContext, epochKey: epochKey))
    }
}
