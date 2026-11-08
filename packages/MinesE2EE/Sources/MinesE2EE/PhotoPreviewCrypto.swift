import CryptoKit
import Foundation

/// Optional sidecar: existing message/original formats stay unchanged. The authenticated
/// original descriptor and message context determine its identity and its separate key.
public enum PhotoPreviewCipher {
    public static let maximumBytes = 32 * 1024
    public static let maximumEnvelopeBytes = maximumBytes + 4096
    private static let domain = Data("mines/e2ee/photo-preview/v1".utf8)

    public static func attachmentID(for original: PrivateAttachment, context: RecordContext) -> String {
        // A public hash of descriptor fields would permit filename dictionary attacks.
        // Keep the deterministic identity opaque to the relay with a separate keyed domain.
        let identityDomain = Data("mines/e2ee/photo-preview/identity/v1".utf8)
        var bytes = Array(HMAC<SHA256>.authenticationCode(for: identityDomain + binding(original, context),
                                                        using: SymmetricKey(data: original.key)))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.prefix(16).map { String(format: "%02x", $0) }.joined()
        let lengths = [8, 4, 4, 4, 12]
        var position = hex.startIndex
        return lengths.map { count in
            let end = hex.index(position, offsetBy: count)
            defer { position = end }
            return String(hex[position..<end])
        }.joined(separator: "-")
    }

    public static func seal(_ jpeg: Data, original: PrivateAttachment, context: RecordContext) throws -> OutboxAttachment {
        try validate(original, context)
        guard !jpeg.isEmpty, jpeg.count <= maximumBytes else { throw E2EEError.sizeLimitExceeded }
        let bytes = try RecordCipher.seal(jpeg, context: previewContext(original, context), epochKey: key(original, context))
        return try OutboxAttachment(attachmentID: attachmentID(for: original, context: context), bytes: bytes)
    }

    public static func open(_ envelope: Data, original: PrivateAttachment, context: RecordContext) throws -> Data {
        try validate(original, context)
        guard envelope.count <= maximumEnvelopeBytes else { throw E2EEError.sizeLimitExceeded }
        let bytes = try RecordCipher.open(envelope, expectedContext: previewContext(original, context), epochKey: key(original, context))
        guard !bytes.isEmpty, bytes.count <= maximumBytes else { throw E2EEError.sizeLimitExceeded }
        return bytes
    }

    private static func validate(_ original: PrivateAttachment, _ context: RecordContext) throws {
        guard context.kind == .message, original.mediaType.hasPrefix("image/") else { throw E2EEError.invalidAttachmentMetadata }
    }
    private static func binding(_ original: PrivateAttachment, _ context: RecordContext) -> Data {
        var writer = BinaryWriter()
        writer.bytes(domain); writer.bytes(context.canonicalBytes)
        writer.string(original.attachmentID); writer.string(original.filename); writer.string(original.mediaType)
        writer.uint64(UInt64(original.originalByteCount))
        writer.uint32(original.voiceDurationMilliseconds == nil ? 0 : 1)
        if let duration = original.voiceDurationMilliseconds { writer.uint64(duration) }
        return writer.data
    }
    private static func key(_ original: PrivateAttachment, _ context: RecordContext) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: original.key), salt: domain,
                              info: binding(original, context), outputByteCount: 32)
    }
    private static func previewContext(_ original: PrivateAttachment, _ context: RecordContext) throws -> RecordContext {
        try RecordContext(conversationID: context.conversationID, recordID: attachmentID(for: original, context: context),
                          senderID: context.senderID, kind: .attachmentKey, keyEpoch: context.keyEpoch, revision: context.revision)
    }
}
