import CryptoKit
import Foundation

public enum ContentError: Error, Equatable, Sendable {
    case unsupportedVersion
    case malformed
    case invalidIdentifier
    case invalidCombination
    case invalidLocation
    case invalidTimestamp
    case sizeLimitExceeded
    case contextMismatch
}

public enum ContentMessageKind: UInt32, CaseIterable, Sendable {
    case text = 1, link, attachment, voice, liveLocation
}
public enum ContentAttachmentType: UInt32, CaseIterable, Sendable {
    case image = 1, video, audio, file
}
public enum ContentDeliveryMode: UInt32, Sendable {
    case normal = 0, quiet = 1
}

public enum ContentLimits {
    /// Bounded below the existing 32 KiB MessagePayload.text ceiling after Base64 encoding.
    public static let bodyBytes = 20 * 1024
    public static let photoGroupCount = 10
    public static let emojiBytes = 128
    public static let durationMilliseconds: UInt64 = 24 * 60 * 60 * 1000
    public static let maximumTimestampMilliseconds: UInt64 = 253_402_300_799_999
    public static let maximumHorizontalAccuracyMeters: Double = 100_000
}

public struct ContentPhotoGroup: Equatable, Sendable {
    public let id: String
    public let index: Int
    public let count: Int
    public init(id: String, index: Int, count: Int) throws {
        try ContentWire.uuid(id)
        guard (2...ContentLimits.photoGroupCount).contains(count), (0..<count).contains(index) else { throw ContentError.invalidCombination }
        self.id = id; self.index = index; self.count = count
    }
}

/// Legacy location embedded in a message; separate from the current replaceable point record.
public struct LegacyMessageLocation: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let updatedAtMilliseconds: UInt64
    public let expiresAtMilliseconds: UInt64?
    public init(latitude: Double, longitude: Double, updatedAtMilliseconds: UInt64, expiresAtMilliseconds: UInt64? = nil) throws {
        try ContentWire.coordinates(latitude, longitude)
        try ContentWire.timestamp(updatedAtMilliseconds)
        if let expiry = expiresAtMilliseconds {
            try ContentWire.timestamp(expiry)
            guard expiry >= updatedAtMilliseconds else { throw ContentError.invalidTimestamp }
        }
        self.latitude = latitude; self.longitude = longitude
        self.updatedAtMilliseconds = updatedAtMilliseconds; self.expiresAtMilliseconds = expiresAtMilliseconds
    }
}

/// Every field is private content. Message routing/timestamps/receipts come from a separately
/// validated public envelope. Attachment keys and metadata stay in the existing encrypted
/// PrivateAttachment descriptor; do not mirror them into Firestore attachment metadata.
public struct ConversationMessagePayload: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let kind: ContentMessageKind
    public let body: String
    public let replyToID: String?
    public let photoGroup: ContentPhotoGroup?
    public let attachment: PrivateAttachment?
    public let attachmentType: ContentAttachmentType?
    public let legacyLocation: LegacyMessageLocation?
    public let deliveryMode: ContentDeliveryMode
    public var description: String { "ConversationMessagePayload(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }

    public init(kind: ContentMessageKind, body: String, replyToID: String? = nil, photoGroup: ContentPhotoGroup? = nil,
                attachment: PrivateAttachment? = nil, attachmentType: ContentAttachmentType? = nil,
                legacyLocation: LegacyMessageLocation? = nil, deliveryMode: ContentDeliveryMode = .normal) throws {
        guard body.utf8.count <= ContentLimits.bodyBytes else { throw ContentError.sizeLimitExceeded }
        if let replyToID { try ContentWire.uuid(replyToID) }
        guard (attachment == nil) == (attachmentType == nil) else { throw ContentError.invalidCombination }
        if let attachment {
            try ContentWire.uuid(attachment.attachmentID)
            if let duration = attachment.voiceDurationMilliseconds, duration > ContentLimits.durationMilliseconds { throw ContentError.invalidCombination }
        }
        switch kind {
        case .text, .link:
            guard attachment == nil, photoGroup == nil, legacyLocation == nil else { throw ContentError.invalidCombination }
        case .attachment:
            guard attachment != nil, legacyLocation == nil else { throw ContentError.invalidCombination }
        case .voice:
            guard let attachment, attachmentType == .audio, let duration = attachment.voiceDurationMilliseconds, duration > 0,
                  photoGroup == nil, legacyLocation == nil else { throw ContentError.invalidCombination }
        case .liveLocation:
            guard legacyLocation != nil, attachment == nil, photoGroup == nil else { throw ContentError.invalidCombination }
        }
        if photoGroup != nil, attachmentType != .image { throw ContentError.invalidCombination }
        self.kind = kind; self.body = body; self.replyToID = replyToID; self.photoGroup = photoGroup
        self.attachment = attachment; self.attachmentType = attachmentType
        self.legacyLocation = legacyLocation; self.deliveryMode = deliveryMode
    }

    /// Compatibility adapter: an explicitly versioned canonical binary schema in encrypted text,
    /// retaining the existing MessageCipher and authenticated durable-outbox wire unchanged.
    public func messagePayload() throws -> MessagePayload {
        var writer = BinaryWriter(); writer.bytes(ContentWire.messageMagic); writer.uint32(1)
        writer.uint32(kind.rawValue); writer.string(body)
        ContentWire.optionalString(replyToID, writer: &writer)
        writer.uint32(photoGroup == nil ? 0 : 1)
        if let group = photoGroup { writer.string(group.id); writer.uint32(UInt32(group.index)); writer.uint32(UInt32(group.count)) }
        writer.uint32(attachmentType?.rawValue ?? 0)
        writer.uint32(legacyLocation == nil ? 0 : 1)
        if let location = legacyLocation {
            ContentWire.double(location.latitude, writer: &writer); ContentWire.double(location.longitude, writer: &writer)
            writer.uint64(location.updatedAtMilliseconds); ContentWire.optionalUInt64(location.expiresAtMilliseconds, writer: &writer)
        }
        writer.uint32(deliveryMode.rawValue)
        let text = ContentWire.messagePrefix + writer.data.base64EncodedString()
        return try MessagePayload(text: text, attachments: attachment.map { [$0] } ?? [])
    }

    public init(messagePayload: MessagePayload) throws {
        let text = messagePayload.text
        guard text.utf8.count <= POCLimits.messageTextBytes, text.hasPrefix(ContentWire.messagePrefix), messagePayload.attachments.count <= 1 else { throw ContentError.malformed }
        let encoded = String(text.dropFirst(ContentWire.messagePrefix.count))
        guard let bytes = Data(base64Encoded: encoded), bytes.base64EncodedString() == encoded,
              bytes.count <= 24 * 1024 else { throw ContentError.malformed }
        var reader = BinaryReader(bytes); try reader.expect(ContentWire.messageMagic)
        guard try reader.uint32() == 1 else { throw ContentError.unsupportedVersion }
        guard let kind = ContentMessageKind(rawValue: try reader.uint32()) else { throw ContentError.malformed }
        let body = try reader.string(maximum: ContentLimits.bodyBytes)
        let reply = try ContentWire.optionalString(&reader)
        let group: ContentPhotoGroup?
        if try ContentWire.presence(&reader) {
            let id = try reader.string(maximum: 36)
            let index = try reader.uint32(); let count = try reader.uint32()
            guard index <= UInt32(ContentLimits.photoGroupCount), count <= UInt32(ContentLimits.photoGroupCount) else { throw ContentError.invalidCombination }
            group = try ContentPhotoGroup(id: id, index: Int(index), count: Int(count))
        } else { group = nil }
        let attachmentTypeRaw = try reader.uint32()
        let attachmentType: ContentAttachmentType?
        if attachmentTypeRaw == 0 { attachmentType = nil }
        else {
            guard let type = ContentAttachmentType(rawValue: attachmentTypeRaw) else { throw ContentError.malformed }
            attachmentType = type
        }
        let location: LegacyMessageLocation?
        if try ContentWire.presence(&reader) {
            location = try LegacyMessageLocation(latitude: ContentWire.double(&reader), longitude: ContentWire.double(&reader),
                updatedAtMilliseconds: reader.uint64(), expiresAtMilliseconds: ContentWire.optionalUInt64(&reader))
        } else { location = nil }
        guard let delivery = ContentDeliveryMode(rawValue: try reader.uint32()), reader.isAtEnd else { throw ContentError.malformed }
        try self.init(kind: kind, body: body, replyToID: reply, photoGroup: group, attachment: messagePayload.attachments.first,
                      attachmentType: attachmentType, legacyLocation: location, deliveryMode: delivery)
    }
}

public enum ConversationMessageCipher {
    public static func seal(_ payload: ConversationMessagePayload, context: RecordContext, epochKey: SymmetricKey) throws -> Data {
        try ContentWire.context(context, kind: .message)
        try ContentWire.uuid(context.recordID)
        return try MessageCipher.seal(payload.messagePayload(), context: context, epochKey: epochKey)
    }
    public static func open(_ envelope: Data, expectedContext: RecordContext, epochKey: SymmetricKey) throws -> ConversationMessagePayload {
        try ContentWire.context(expectedContext, kind: .message)
        try ContentWire.uuid(expectedContext.recordID)
        return try ConversationMessagePayload(messagePayload: MessageCipher.open(envelope, expectedContext: expectedContext, epochKey: epochKey))
    }
}

public struct ReactionPayload: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let targetMessageID: String
    /// nil is an authenticated removal tombstone; do not delete the revision record on the relay.
    public let emoji: String?
    public var description: String { "ReactionPayload(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
    public init(targetMessageID: String, emoji: String?) throws {
        try ContentWire.uuid(targetMessageID)
        if let emoji { guard !emoji.isEmpty, emoji.utf8.count <= ContentLimits.emojiBytes, emoji.count == 1 else { throw ContentError.invalidCombination } }
        self.targetMessageID = targetMessageID; self.emoji = emoji
    }
    var encoded: Data {
        var writer = BinaryWriter(); writer.bytes(ContentWire.reactionMagic); writer.uint32(1)
        writer.string(targetMessageID); ContentWire.optionalString(emoji, writer: &writer); return writer.data
    }
    static func decode(_ bytes: Data) throws -> Self {
        guard bytes.count <= 512 else { throw ContentError.sizeLimitExceeded }
        var reader = BinaryReader(bytes); try reader.expect(ContentWire.reactionMagic)
        guard try reader.uint32() == 1 else { throw ContentError.unsupportedVersion }
        let target = try reader.string(maximum: 36); let emoji = try ContentWire.optionalString(&reader, maximum: ContentLimits.emojiBytes)
        guard reader.isAtEnd else { throw ContentError.malformed }; return try Self(targetMessageID: target, emoji: emoji)
    }
}

public enum ReactionCipher {
    public static func recordID(targetMessageID: String, senderID: String) throws -> String {
        try ContentWire.uuid(targetMessageID)
        guard !senderID.isEmpty, senderID.utf8.count <= 256 else { throw ContentError.invalidIdentifier }
        return targetMessageID + "--" + senderID
    }
    /// Supply the trusted Firestore parent message ID. Use a recordID unique to target+sender;
    /// a sender-only ID would collide across different messages' independent revision streams.
    public static func seal(_ payload: ReactionPayload, context: RecordContext, expectedTargetMessageID: String, epochKey: SymmetricKey) throws -> Data {
        try ContentWire.context(context, kind: .reaction)
        try ContentWire.uuid(expectedTargetMessageID)
        guard Data(payload.targetMessageID.utf8) == Data(expectedTargetMessageID.utf8),
              Data(context.recordID.utf8) == Data(try recordID(targetMessageID: expectedTargetMessageID, senderID: context.senderID).utf8) else { throw ContentError.contextMismatch }
        return try RecordCipher.seal(payload.encoded, context: context, epochKey: epochKey)
    }
    public static func open(_ envelope: Data, expectedContext: RecordContext, expectedTargetMessageID: String, epochKey: SymmetricKey) throws -> ReactionPayload {
        try ContentWire.context(expectedContext, kind: .reaction)
        try ContentWire.uuid(expectedTargetMessageID)
        guard Data(expectedContext.recordID.utf8) == Data(try recordID(targetMessageID: expectedTargetMessageID, senderID: expectedContext.senderID).utf8) else { throw ContentError.contextMismatch }
        let payload = try ReactionPayload.decode(RecordCipher.open(envelope, expectedContext: expectedContext, epochKey: epochKey))
        guard Data(payload.targetMessageID.utf8) == Data(expectedTargetMessageID.utf8) else { throw ContentError.contextMismatch }
        return payload
    }
}

/// A bounded replaceable precise point. Sharing authorization remains a separate app/backend gate.
public struct LocationPayload: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let latitude: Double
    public let longitude: Double
    public let horizontalAccuracy: Double
    public let recordedAtMilliseconds: UInt64
    public var description: String { "LocationPayload(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
    public init(latitude: Double, longitude: Double, horizontalAccuracy: Double, recordedAtMilliseconds: UInt64) throws {
        try ContentWire.coordinates(latitude, longitude)
        guard horizontalAccuracy.isFinite, (0...ContentLimits.maximumHorizontalAccuracyMeters).contains(horizontalAccuracy) else { throw ContentError.invalidLocation }
        try ContentWire.timestamp(recordedAtMilliseconds)
        self.latitude = latitude; self.longitude = longitude; self.horizontalAccuracy = horizontalAccuracy
        self.recordedAtMilliseconds = recordedAtMilliseconds
    }
    var encoded: Data {
        var writer = BinaryWriter(); writer.bytes(ContentWire.locationMagic); writer.uint32(1)
        ContentWire.double(latitude, writer: &writer); ContentWire.double(longitude, writer: &writer)
        ContentWire.double(horizontalAccuracy, writer: &writer); writer.uint64(recordedAtMilliseconds)
        return writer.data
    }
    static func decode(_ bytes: Data) throws -> Self {
        guard bytes.count <= 128 else { throw ContentError.sizeLimitExceeded }
        var reader = BinaryReader(bytes); try reader.expect(ContentWire.locationMagic)
        guard try reader.uint32() == 1 else { throw ContentError.unsupportedVersion }
        let result = try Self(latitude: ContentWire.double(&reader), longitude: ContentWire.double(&reader),
                              horizontalAccuracy: ContentWire.double(&reader), recordedAtMilliseconds: reader.uint64())
        guard reader.isAtEnd else { throw ContentError.malformed }; return result
    }
}

public enum LocationCipher {
    public static func seal(_ payload: LocationPayload, context: RecordContext, epochKey: SymmetricKey) throws -> Data {
        try ContentWire.context(context, kind: .location)
        guard Data(context.recordID.utf8) == Data(context.senderID.utf8) else { throw ContentError.contextMismatch }
        return try RecordCipher.seal(payload.encoded, context: context, epochKey: epochKey)
    }
    public static func open(_ envelope: Data, expectedContext: RecordContext, epochKey: SymmetricKey) throws -> LocationPayload {
        try ContentWire.context(expectedContext, kind: .location)
        guard Data(expectedContext.recordID.utf8) == Data(expectedContext.senderID.utf8) else { throw ContentError.contextMismatch }
        return try LocationPayload.decode(RecordCipher.open(envelope, expectedContext: expectedContext, epochKey: epochKey))
    }
}

enum ContentWire {
    static let messagePrefix = "mines-content-v1:"
    static let messageMagic = Data("mines/content/message\0".utf8)
    static let reactionMagic = Data("mines/content/reaction\0".utf8)
    static let locationMagic = Data("mines/content/location\0".utf8)
    static func uuid(_ value: String) throws {
        guard value.utf8.count == 36, let uuid = UUID(uuidString: value), Data(uuid.uuidString.lowercased().utf8) == Data(value.utf8) else { throw ContentError.invalidIdentifier }
    }
    static func context(_ context: RecordContext, kind: RecordKind) throws {
        try uuid(context.conversationID)
        guard !context.senderID.isEmpty, context.senderID.utf8.count <= 256 else { throw ContentError.invalidIdentifier }
        guard context.kind == kind else { throw ContentError.contextMismatch }
    }
    static func timestamp(_ value: UInt64) throws {
        guard value <= ContentLimits.maximumTimestampMilliseconds else { throw ContentError.invalidTimestamp }
    }
    static func coordinates(_ latitude: Double, _ longitude: Double) throws {
        guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude) else { throw ContentError.invalidLocation }
    }
    static func double(_ value: Double, writer: inout BinaryWriter) { writer.uint64(value.bitPattern) }
    static func double(_ reader: inout BinaryReader) throws -> Double { Double(bitPattern: try reader.uint64()) }
    static func presence(_ reader: inout BinaryReader) throws -> Bool {
        let flag = try reader.uint32(); guard flag <= 1 else { throw ContentError.malformed }; return flag == 1
    }
    static func optionalString(_ value: String?, writer: inout BinaryWriter) {
        writer.uint32(value == nil ? 0 : 1); if let value { writer.string(value) }
    }
    static func optionalString(_ reader: inout BinaryReader, maximum: Int = 36) throws -> String? {
        try presence(&reader) ? reader.string(maximum: maximum) : nil
    }
    static func optionalUInt64(_ value: UInt64?, writer: inout BinaryWriter) {
        writer.uint32(value == nil ? 0 : 1); if let value { writer.uint64(value) }
    }
    static func optionalUInt64(_ reader: inout BinaryReader) throws -> UInt64? { try presence(&reader) ? reader.uint64() : nil }
}
