import CryptoKit
import Foundation

/// A separate, bounded notification record. Only display text is encrypted here;
/// attachment descriptors and all other private message fields stay in the message.
public enum NotificationPreviewCipher {
    public static let maximumEnvelopeBytes = 2048
    public static let maximumTextBytes = 512
    static let maximumCharacters = 180
    static let magic = Data("mines/content/notification-preview\0".utf8)

    /// Only the initial message revision can create a notification preview. Persist
    /// and reuse the returned envelope when retrying the same notification write.
    public static func seal(_ payload: ConversationMessagePayload, context: RecordContext,
                            epochKey: SymmetricKey) throws -> Data {
        let previewContext = try previewContext(for: context)
        let text = boundedText(displayText(for: payload))
        var writer = BinaryWriter()
        writer.bytes(magic)
        writer.uint32(1)
        writer.string(text)
        let envelope = try RecordCipher.seal(writer.data, context: previewContext, epochKey: epochKey)
        guard envelope.count <= maximumEnvelopeBytes else { throw ContentError.sizeLimitExceeded }
        return envelope
    }

    public static func open(_ envelope: Data, messageContext: RecordContext,
                            epochKey: SymmetricKey) throws -> String {
        guard envelope.count <= maximumEnvelopeBytes else { throw ContentError.sizeLimitExceeded }
        let context = try previewContext(for: messageContext)
        let plaintext = try RecordCipher.open(envelope, expectedContext: context, epochKey: epochKey)
        guard plaintext.count <= magic.count + 8 + maximumTextBytes else { throw ContentError.sizeLimitExceeded }
        var reader = BinaryReader(plaintext)
        try reader.expect(magic)
        guard try reader.uint32() == 1 else { throw ContentError.unsupportedVersion }
        let text = try reader.string(maximum: maximumTextBytes)
        guard reader.isAtEnd, !text.isEmpty, text.count <= maximumCharacters else { throw ContentError.malformed }
        return text
    }

    private static func previewContext(for message: RecordContext) throws -> RecordContext {
        try ContentWire.context(message, kind: .message)
        try ContentWire.uuid(message.recordID)
        guard message.revision == 1 else { throw ContentError.contextMismatch }
        return try RecordContext(conversationID: message.conversationID, recordID: message.recordID,
            senderID: message.senderID, kind: .notificationPreview, keyEpoch: message.keyEpoch, revision: message.revision)
    }

    private static func displayText(for payload: ConversationMessagePayload) -> String {
        switch payload.kind {
        case .text, .link:
            return payload.body
        case .attachment, .voice:
            if !payload.body.isEmpty { return payload.body }
            switch payload.attachmentType {
            case .image: return "Sent photo"
            case .video: return "Sent video"
            case .audio: return "Sent voice message"
            case .file, nil: return "Sent file"
            }
        case .liveLocation:
            return "Shared location"
        }
    }

    private static func boundedText(_ source: String) -> String {
        // Never ask Character iteration to scan an unbounded combining/ZWJ cluster.
        // One extra byte detects truncation, and at most three removals repair a
        // partial UTF-8 scalar before inspecting this small, independent string.
        var bytes = Array(source.utf8.prefix(maximumTextBytes + 1))
        let truncated = bytes.count > maximumTextBytes
        if truncated { bytes.removeLast() }
        while String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
        var prefix = String(decoding: bytes, as: UTF8.self)
        // The final cluster may continue beyond the byte window. Conservatively
        // remove it rather than display a partial grapheme or scan the full source.
        if truncated, !prefix.isEmpty { prefix.removeLast() }
        let text = String(prefix.prefix(maximumCharacters))
        return text.isEmpty ? "New message" : text
    }
}
