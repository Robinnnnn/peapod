import CryptoKit
import Foundation
import XCTest
@testable import MinesE2EE

final class ConversationContentTests: XCTestCase {
    let conversation = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    let messageID = "01234567-89ab-cdef-0123-456789abcdef"
    let replyID = "11111111-2222-3333-4444-555555555555"
    let key = SymmetricKey(data: Data(0..<32))

    func context(kind: RecordKind = .message, recordID: String? = nil, revision: UInt64 = 1) throws -> RecordContext {
        try RecordContext(conversationID: conversation, recordID: recordID ?? messageID, senderID: "alice", kind: kind, keyEpoch: 1, revision: revision)
    }
    func attachment(duration: UInt64? = nil) throws -> PrivateAttachment {
        try PrivateAttachment(attachmentID: messageID, key: Data(0..<32), filename: "private-filename.m4a", mediaType: "audio/mp4",
                              originalByteCount: 10, voiceDurationMilliseconds: duration)
    }
    func raw(_ messagePayload: MessagePayload) throws -> Data {
        try XCTUnwrap(Data(base64Encoded: String(messagePayload.text.dropFirst(ContentWire.messagePrefix.count))))
    }
    func wrapped(_ bytes: Data, attachments: [PrivateAttachment] = []) throws -> MessagePayload {
        try MessagePayload(text: ContentWire.messagePrefix + bytes.base64EncodedString(), attachments: attachments)
    }
    func assertContentError(_ expected: ContentError, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { XCTAssertEqual($0 as? ContentError, expected, file: file, line: line) }
    }

    func testEveryMessageKindAndAttachmentTypeRoundTripAllPrivateFields() throws {
        let location = try LegacyMessageLocation(latitude: 37.7, longitude: -122.4, updatedAtMilliseconds: 1_700_000_000_000,
                                                 expiresAtMilliseconds: 1_700_000_300_000)
        let group = try ContentPhotoGroup(id: replyID, index: 1, count: 10)
        var payloads = try [
            ConversationMessagePayload(kind: .text, body: "hello 😀 é\n", replyToID: replyID, deliveryMode: .quiet),
            ConversationMessagePayload(kind: .link, body: "https://example.com?q=private", replyToID: replyID),
            ConversationMessagePayload(kind: .voice, body: "", replyToID: replyID, attachment: attachment(duration: 9876), attachmentType: .audio),
            ConversationMessagePayload(kind: .liveLocation, body: "", replyToID: replyID, legacyLocation: location)
        ]
        for type in ContentAttachmentType.allCases {
            payloads.append(try ConversationMessagePayload(kind: .attachment, body: "private caption", replyToID: replyID,
                photoGroup: type == .image ? group : nil, attachment: attachment(), attachmentType: type))
        }
        for payload in payloads {
            XCTAssertEqual(try ConversationMessagePayload(messagePayload: payload.messagePayload()), payload)
            let sealed = try ConversationMessageCipher.seal(payload, context: context(), epochKey: key)
            XCTAssertEqual(try ConversationMessageCipher.open(sealed, expectedContext: context(), epochKey: key), payload)
            XCTAssertNil(sealed.range(of: Data(payload.body.utf8).isEmpty ? Data("private-caption-canary".utf8) : Data(payload.body.utf8)))
            XCTAssertNil(sealed.range(of: Data("private-filename.m4a".utf8)))
            XCTAssertNil(sealed.range(of: Data(replyID.utf8)))
        }
    }

    func testMaximumBodyAndByteBoundRoundTrip() throws {
        let body = String(repeating: "😀", count: ContentLimits.bodyBytes / 4)
        let payload = try ConversationMessagePayload(kind: .text, body: body, replyToID: replyID, deliveryMode: .quiet)
        XCTAssertLessThan(try payload.messagePayload().text.utf8.count, POCLimits.messageTextBytes)
        XCTAssertEqual(try ConversationMessagePayload(messagePayload: payload.messagePayload()).body, body)
        assertContentError(.sizeLimitExceeded) { _ = try ConversationMessagePayload(kind: .text, body: body + "a") }
        XCTAssertEqual(try ConversationMessagePayload(kind: .text, body: "").body, "")
    }

    func testSemanticCombinationsUUIDAndMetadataIntegerBounds() throws {
        let metadata = try attachment()
        XCTAssertThrowsError(try ContentPhotoGroup(id: replyID, index: .max, count: .max))
        XCTAssertThrowsError(try ContentPhotoGroup(id: replyID, index: -1, count: 2))
        XCTAssertThrowsError(try ContentPhotoGroup(id: replyID, index: 2, count: 2))
        XCTAssertThrowsError(try ContentPhotoGroup(id: replyID, index: 0, count: 1))
        assertContentError(.invalidIdentifier) { _ = try ConversationMessagePayload(kind: .text, body: "", replyToID: messageID.uppercased()) }
        assertContentError(.invalidCombination) { _ = try ConversationMessagePayload(kind: .text, body: "", attachment: metadata, attachmentType: .file) }
        assertContentError(.invalidCombination) { _ = try ConversationMessagePayload(kind: .attachment, body: "") }
        assertContentError(.invalidCombination) { _ = try ConversationMessagePayload(kind: .attachment, body: "", attachment: metadata) }
        assertContentError(.invalidCombination) { _ = try ConversationMessagePayload(kind: .voice, body: "", attachment: metadata, attachmentType: .audio) }
        assertContentError(.invalidCombination) { _ = try ConversationMessagePayload(kind: .voice, body: "", attachment: attachment(duration: 0), attachmentType: .audio) }
        assertContentError(.invalidCombination) { _ = try ConversationMessagePayload(kind: .voice, body: "", attachment: attachment(duration: .max), attachmentType: .audio) }
        assertContentError(.invalidCombination) { _ = try ConversationMessagePayload(kind: .liveLocation, body: "") }
        assertContentError(.invalidCombination) {
            _ = try ConversationMessagePayload(kind: .attachment, body: "", photoGroup: ContentPhotoGroup(id: replyID, index: 0, count: 2), attachment: metadata, attachmentType: .file)
        }
        let invalidID = try PrivateAttachment(attachmentID: "not-a-uuid", key: Data(0..<32), filename: "file", mediaType: "type", originalByteCount: 0)
        assertContentError(.invalidIdentifier) { _ = try ConversationMessagePayload(kind: .attachment, body: "", attachment: invalidID, attachmentType: .file) }
    }

    func testStrictSchemaDiscriminatorVersionEnumFlagsLengthsUTF8AndTrailingBytes() throws {
        let payload = try ConversationMessagePayload(kind: .text, body: "a").messagePayload()
        let original = try raw(payload)
        XCTAssertThrowsError(try ConversationMessagePayload(messagePayload: MessagePayload(text: "arbitrary plaintext")))
        XCTAssertThrowsError(try ConversationMessagePayload(messagePayload: MessagePayload(text: payload.text + "\n")))
        XCTAssertThrowsError(try ConversationMessagePayload(messagePayload: MessagePayload(text: payload.text.replacingOccurrences(of: "v1:", with: "v2:"))))
        var future = original; future[ContentWire.messageMagic.count + 3] = 2
        assertContentError(.unsupportedVersion) { _ = try ConversationMessagePayload(messagePayload: wrapped(future)) }
        var unknownKind = original; unknownKind[ContentWire.messageMagic.count + 7] = 99
        assertContentError(.malformed) { _ = try ConversationMessagePayload(messagePayload: wrapped(unknownKind)) }
        var hugeLength = original
        let bodyLength = ContentWire.messageMagic.count + 8
        hugeLength.replaceSubrange(bodyLength..<(bodyLength + 4), with: [255, 255, 255, 255])
        XCTAssertThrowsError(try ConversationMessagePayload(messagePayload: wrapped(hugeLength)))
        var badUTF8 = original; badUTF8[bodyLength + 4] = 255
        XCTAssertThrowsError(try ConversationMessagePayload(messagePayload: wrapped(badUTF8)))
        var badOptionalFlag = original; badOptionalFlag[bodyLength + 4 + 1 + 3] = 2
        assertContentError(.malformed) { _ = try ConversationMessagePayload(messagePayload: wrapped(badOptionalFlag)) }
        var badDelivery = original; badDelivery[badDelivery.count - 1] = 2
        assertContentError(.malformed) { _ = try ConversationMessagePayload(messagePayload: wrapped(badDelivery)) }
        for length in 0..<original.count { XCTAssertThrowsError(try ConversationMessagePayload(messagePayload: wrapped(Data(original.prefix(length))))) }
        assertContentError(.malformed) { _ = try ConversationMessagePayload(messagePayload: wrapped(original + Data([0]))) }
        XCTAssertThrowsError(try ConversationMessagePayload(messagePayload: MessagePayload(text: payload.text, attachments: [attachment(), attachmentWithDifferentID()])))
    }

    func testWrongKeyContextKindAndRecordIDFailBeforeContentUse() throws {
        let payload = try ConversationMessagePayload(kind: .text, body: "private")
        let sealed = try ConversationMessageCipher.seal(payload, context: context(), epochKey: key)
        XCTAssertThrowsError(try ConversationMessageCipher.open(sealed, expectedContext: context(recordID: replyID), epochKey: key))
        XCTAssertThrowsError(try ConversationMessageCipher.open(sealed, expectedContext: context(revision: 2), epochKey: key))
        XCTAssertThrowsError(try ConversationMessageCipher.open(sealed, expectedContext: context(), epochKey: SymmetricKey(size: .bits256)))
        assertContentError(.contextMismatch) { _ = try ConversationMessageCipher.open(sealed, expectedContext: context(kind: .reaction), epochKey: key) }
        assertContentError(.invalidIdentifier) { _ = try ConversationMessageCipher.seal(payload, context: context(recordID: "not-uuid"), epochKey: key) }
        var tampered = sealed; tampered[tampered.count - 1] ^= 1
        XCTAssertThrowsError(try ConversationMessageCipher.open(tampered, expectedContext: context(), epochKey: key))
    }

    func testExistingDurableOutboxAcceptsTypedMessageAndEncryptedAttachment() throws {
        let context = try context()
        let attachment = try AttachmentCipher().seal(Data("private file bytes".utf8), context: context, attachmentID: messageID, filename: "secret.txt", mediaType: "text/plain")
        let payload = try ConversationMessagePayload(kind: .attachment, body: "private caption", replyToID: replyID,
                                                      attachment: attachment.privateMetadata, attachmentType: .file)
        let sealed = try ConversationMessageCipher.seal(payload, context: context, epochKey: key)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mines-content-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DurableCiphertextOutbox(directory: directory)
        let scope = try OutboxScope(accountID: "alice", conversationID: conversation, keyEpoch: 1)
        try store.enqueue(envelope: sealed, attachments: [OutboxAttachment(attachmentID: messageID, bytes: attachment.bytes)], context: context, scope: scope, epochKey: key)
        store.close()
        let restored = try DurableCiphertextOutbox(directory: directory)
        let queued = try XCTUnwrap(restored.load(scope: scope, recordID: messageID, epochKey: key))
        XCTAssertEqual(queued.envelope, sealed)
        XCTAssertEqual(try ConversationMessageCipher.open(queued.envelope, expectedContext: context, epochKey: key), payload)
        XCTAssertEqual(try AttachmentCipher().open(queued.attachments[0].bytes, privateMetadata: payload.attachment!, expectedContext: context), Data("private file bytes".utf8))
        restored.close()
    }

    func testReactionRoundTripRemovalAndMalformedSchema() throws {
        let context = try context(kind: .reaction, recordID: ReactionCipher.recordID(targetMessageID: messageID, senderID: "alice"))
        for emoji in [nil, "👍🏽", "👨‍👩‍👧‍👦", "❤️"] {
            let reaction = try ReactionPayload(targetMessageID: messageID, emoji: emoji)
            let sealed = try ReactionCipher.seal(reaction, context: context, expectedTargetMessageID: messageID, epochKey: key)
            XCTAssertEqual(try ReactionCipher.open(sealed, expectedContext: context, expectedTargetMessageID: messageID, epochKey: key), reaction)
            XCTAssertThrowsError(try ReactionCipher.open(sealed, expectedContext: self.context(kind: .reaction, recordID: "reaction/bob"), expectedTargetMessageID: messageID, epochKey: key))
            assertContentError(.contextMismatch) { _ = try ReactionCipher.open(sealed, expectedContext: context, expectedTargetMessageID: replyID, epochKey: key) }
            assertContentError(.contextMismatch) { _ = try ReactionCipher.seal(reaction, context: context, expectedTargetMessageID: replyID, epochKey: key) }
        }
        XCTAssertThrowsError(try ReactionPayload(targetMessageID: messageID, emoji: ""))
        XCTAssertThrowsError(try ReactionPayload(targetMessageID: messageID, emoji: "👍👍"))
        XCTAssertThrowsError(try ReactionPayload(targetMessageID: "bad-id", emoji: nil))
        XCTAssertThrowsError(try ReactionPayload(targetMessageID: messageID, emoji: "a" + String(repeating: "\u{301}", count: 70)))
        let reaction = try ReactionPayload(targetMessageID: messageID, emoji: nil)
        var future = reaction.encoded; future[ContentWire.reactionMagic.count + 3] = 2
        assertContentError(.unsupportedVersion) { _ = try ReactionPayload.decode(future) }
        var flag = reaction.encoded; flag[flag.count - 1] = 2
        assertContentError(.malformed) { _ = try ReactionPayload.decode(flag) }
        XCTAssertThrowsError(try ReactionPayload.decode(reaction.encoded + Data([0])))
        assertContentError(.contextMismatch) { _ = try ReactionCipher.seal(reaction, context: self.context(), expectedTargetMessageID: messageID, epochKey: key) }
        // A public caller cannot reinterpret a location/message envelope as a reaction.
        let foreign = try RecordCipher.seal(reaction.encoded, context: self.context(), epochKey: key)
        XCTAssertThrowsError(try ReactionCipher.open(foreign, expectedContext: context, expectedTargetMessageID: messageID, epochKey: key))
    }

    func testLocationFiniteRangesTimestampsAndAuthenticatedNaNTamper() throws {
        let context = try context(kind: .location, recordID: "alice")
        for coords in [(90.0, 180.0), (-90.0, -180.0), (0.0, 0.0)] {
            let point = try LocationPayload(latitude: coords.0, longitude: coords.1, horizontalAccuracy: 0, recordedAtMilliseconds: 0)
            let sealed = try LocationCipher.seal(point, context: context, epochKey: key)
            XCTAssertEqual(try LocationCipher.open(sealed, expectedContext: context, epochKey: key), point)
        }
        for invalid in [Double.nan, .infinity, -.infinity, 90.1] {
            assertContentError(.invalidLocation) { _ = try LocationPayload(latitude: invalid, longitude: 0, horizontalAccuracy: 1, recordedAtMilliseconds: 0) }
        }
        for invalid in [Double.nan, .infinity, -.infinity, -1, ContentLimits.maximumHorizontalAccuracyMeters + 1] {
            assertContentError(.invalidLocation) { _ = try LocationPayload(latitude: 0, longitude: 0, horizontalAccuracy: invalid, recordedAtMilliseconds: 0) }
        }
        assertContentError(.invalidTimestamp) { _ = try LocationPayload(latitude: 0, longitude: 0, horizontalAccuracy: 1, recordedAtMilliseconds: .max) }
        assertContentError(.invalidTimestamp) { _ = try LegacyMessageLocation(latitude: 0, longitude: 0, updatedAtMilliseconds: 100, expiresAtMilliseconds: 99) }
        let point = try LocationPayload(latitude: 37.7, longitude: -122.4, horizontalAccuracy: 2, recordedAtMilliseconds: ContentLimits.maximumTimestampMilliseconds)
        assertContentError(.contextMismatch) { _ = try LocationCipher.seal(point, context: self.context(kind: .location, recordID: "bob"), epochKey: key) }
        var nan = point.encoded
        let doubleOffset = ContentWire.locationMagic.count + 4
        var encodedNaN = BinaryWriter(); encodedNaN.uint64(Double.nan.bitPattern)
        nan.replaceSubrange(doubleOffset..<(doubleOffset + 8), with: encodedNaN.data)
        let authenticatedInvalid = try RecordCipher.seal(nan, context: context, epochKey: key)
        assertContentError(.invalidLocation) { _ = try LocationCipher.open(authenticatedInvalid, expectedContext: context, epochKey: key) }
        var future = point.encoded; future[ContentWire.locationMagic.count + 3] = 2
        assertContentError(.unsupportedVersion) { _ = try LocationPayload.decode(future) }
        XCTAssertThrowsError(try LocationPayload.decode(point.encoded + Data([0])))
        for length in 0..<point.encoded.count { XCTAssertThrowsError(try LocationPayload.decode(Data(point.encoded.prefix(length)))) }
    }

    private func attachmentWithDifferentID() throws -> PrivateAttachment {
        try PrivateAttachment(attachmentID: replyID, key: Data(0..<32), filename: "file", mediaType: "type", originalByteCount: 0)
    }
}
