import CryptoKit
import Foundation

/// Optional display copies. Original descriptors and legacy preview envelopes stay unchanged.
/// Separate keyed identities and authenticated purposes prevent swapping chat/viewer/original bytes.
public enum PhotoRendition: String, CaseIterable, Sendable {
    case chat, viewer

    public var maximumBytes: Int { self == .chat ? 768 * 1024 : 3 * 1024 * 1024 }
    public var maximumEnvelopeBytes: Int { maximumBytes + 4096 }
    public var maximumPixelDimension: Int { self == .chat ? 1536 : 4096 }
}

public enum PhotoRenditionCipher {
    private static let domain = Data("mines/e2ee/photo-rendition/v1".utf8)

    public static func attachmentID(for original: PrivateAttachment, context: RecordContext,
                                    rendition: PhotoRendition) -> String {
        let bytes = Array(HMAC<SHA256>.authenticationCode(
            for: Data("mines/e2ee/photo-rendition/identity/v1".utf8) + binding(original, context, rendition),
            using: SymmetricKey(data: original.key)))
        var id = Array(bytes.prefix(16))
        id[6] = (id[6] & 0x0f) | 0x50
        id[8] = (id[8] & 0x3f) | 0x80
        return UUID(uuid: (id[0], id[1], id[2], id[3], id[4], id[5], id[6], id[7],
                           id[8], id[9], id[10], id[11], id[12], id[13], id[14], id[15])).uuidString.lowercased()
    }

    public static func seal(_ image: Data, original: PrivateAttachment, context: RecordContext,
                            rendition: PhotoRendition) throws -> OutboxAttachment {
        try validate(original, context)
        guard !image.isEmpty, image.count <= rendition.maximumBytes else { throw E2EEError.sizeLimitExceeded }
        let aad = binding(original, context, rendition)
        let box = try ChaChaPoly.seal(image, using: key(original, aad), authenticating: aad)
        return try OutboxAttachment(attachmentID: attachmentID(for: original, context: context, rendition: rendition),
                                    bytes: box.combined)
    }

    public static func open(_ envelope: Data, original: PrivateAttachment, context: RecordContext,
                            rendition: PhotoRendition) throws -> Data {
        try validate(original, context)
        guard envelope.count <= rendition.maximumEnvelopeBytes else { throw E2EEError.sizeLimitExceeded }
        let aad = binding(original, context, rendition)
        let image: Data
        do {
            image = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: envelope),
                                       using: key(original, aad), authenticating: aad)
        } catch { throw E2EEError.authenticationFailed }
        guard !image.isEmpty, image.count <= rendition.maximumBytes else { throw E2EEError.sizeLimitExceeded }
        return image
    }

    private static func validate(_ original: PrivateAttachment, _ context: RecordContext) throws {
        guard context.kind == .message, original.mediaType.hasPrefix("image/") else { throw E2EEError.invalidAttachmentMetadata }
    }

    private static func binding(_ original: PrivateAttachment, _ context: RecordContext,
                                _ rendition: PhotoRendition) -> Data {
        var writer = BinaryWriter()
        writer.bytes(domain); writer.string(rendition.rawValue); writer.bytes(context.canonicalBytes)
        writer.string(original.attachmentID); writer.string(original.filename); writer.string(original.mediaType)
        writer.uint64(UInt64(original.originalByteCount))
        writer.uint32(original.voiceDurationMilliseconds == nil ? 0 : 1)
        if let duration = original.voiceDurationMilliseconds { writer.uint64(duration) }
        return writer.data
    }

    private static func key(_ original: PrivateAttachment, _ aad: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: original.key), salt: domain,
                              info: aad, outputByteCount: 32)
    }
}
