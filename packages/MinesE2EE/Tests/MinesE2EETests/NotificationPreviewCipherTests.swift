import CryptoKit
import Foundation
import XCTest
@testable import MinesE2EE

final class NotificationPreviewCipherTests: XCTestCase {
    let conversationID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    let messageID = "01234567-89ab-cdef-0123-456789abcdef"
    let otherID = "11111111-2222-3333-4444-555555555555"
    let key = SymmetricKey(data: Data(0..<32))

    func context(conversation: String? = nil, record: String? = nil, sender: String = "alice",
                 kind: RecordKind = .message, epoch: UInt32 = 1, revision: UInt64 = 1) throws -> RecordContext {
        try RecordContext(conversationID: conversation ?? conversationID, recordID: record ?? messageID,
                          senderID: sender, kind: kind, keyEpoch: epoch, revision: revision)
    }

    func attachment(duration: UInt64? = nil) throws -> PrivateAttachment {
        try PrivateAttachment(attachmentID: otherID, key: Data(repeating: 0xB7, count: 32),
            filename: "private-filename-canary.m4a", mediaType: "private/media-type-canary",
            originalByteCount: 12345, voiceDurationMilliseconds: duration)
    }

    func roundTrip(_ payload: ConversationMessagePayload) throws -> String {
        let sealed = try NotificationPreviewCipher.seal(payload, context: context(), epochKey: key)
        XCTAssertLessThanOrEqual(sealed.count, NotificationPreviewCipher.maximumEnvelopeBytes)
        return try NotificationPreviewCipher.open(sealed, messageContext: context(), epochKey: key)
    }

    func encodedText(_ text: String, version: UInt32 = 1) -> Data {
        var writer = BinaryWriter()
        writer.bytes(NotificationPreviewCipher.magic); writer.uint32(version); writer.string(text)
        return writer.data
    }

    func assertRejectedPayload(_ bytes: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        let envelope = try RecordCipher.seal(bytes, context: context(kind: .notificationPreview), epochKey: key)
        XCTAssertThrowsError(try NotificationPreviewCipher.open(envelope, messageContext: context(), epochKey: key), file: file, line: line)
    }

    func testTextLinksCaptionsAndFamiliarMediaLabels() throws {
        for kind in [ContentMessageKind.text, .link] {
            XCTAssertEqual(try roundTrip(ConversationMessagePayload(kind: kind, body: "Hello 😀 é\nhttps://example.com")), "Hello 😀 é\nhttps://example.com")
            XCTAssertEqual(try roundTrip(ConversationMessagePayload(kind: kind, body: "")), "New message")
        }
        for (type, label) in [(ContentAttachmentType.image, "Sent photo"), (.video, "Sent video"),
                              (.audio, "Sent voice message"), (.file, "Sent file")] {
            XCTAssertEqual(try roundTrip(ConversationMessagePayload(kind: .attachment, body: "", attachment: attachment(), attachmentType: type)), label)
            XCTAssertEqual(try roundTrip(ConversationMessagePayload(kind: .attachment, body: "Private caption", attachment: attachment(), attachmentType: type)), "Private caption")
        }
        XCTAssertEqual(try roundTrip(ConversationMessagePayload(kind: .voice, body: "", attachment: attachment(duration: 9876), attachmentType: .audio)), "Sent voice message")
        let location = try LegacyMessageLocation(latitude: 37.7, longitude: -122.4, updatedAtMilliseconds: 1_700_000_000_000)
        XCTAssertEqual(try roundTrip(ConversationMessagePayload(kind: .liveLocation, body: "private address canary", legacyLocation: location)), "Shared location")
    }

    func testDecodedPreviewContainsOnlyTextAndNoPrivateMetadata() throws {
        let payload = try ConversationMessagePayload(kind: .attachment, body: "", replyToID: otherID,
            photoGroup: ContentPhotoGroup(id: otherID, index: 0, count: 2), attachment: attachment(), attachmentType: .image,
            deliveryMode: .quiet)
        let envelope = try NotificationPreviewCipher.seal(payload, context: context(), epochKey: key)
        let decoded = try RecordCipher.decode(envelope)
        XCTAssertEqual(decoded.context, try context(kind: .notificationPreview))
        let plaintext = try RecordCipher.open(envelope, expectedContext: context(kind: .notificationPreview), epochKey: key)
        var reader = BinaryReader(plaintext)
        try reader.expect(NotificationPreviewCipher.magic)
        XCTAssertEqual(try reader.uint32(), 1)
        XCTAssertEqual(try reader.string(maximum: NotificationPreviewCipher.maximumTextBytes), "Sent photo")
        XCTAssertTrue(reader.isAtEnd)
        for canary in [Data(otherID.utf8), Data("private-filename-canary.m4a".utf8),
                       Data("private/media-type-canary".utf8), Data(repeating: 0xB7, count: 32)] {
            XCTAssertNil(plaintext.range(of: canary))
            XCTAssertNil(envelope.range(of: canary))
        }
    }

    func testByteAndCharacterBoundsPreserveGraphemes() throws {
        XCTAssertEqual(NotificationPreviewCipher.maximumEnvelopeBytes, 2048)
        XCTAssertEqual(NotificationPreviewCipher.maximumTextBytes, 512)
        XCTAssertEqual(try roundTrip(ConversationMessagePayload(kind: .text, body: String(repeating: "a", count: ContentLimits.bodyBytes))), String(repeating: "a", count: 180))
        for unit in ["😀", "e\u{301}", "👩🏽‍🚀", "👨‍👩‍👧‍👦", "🇨🇦"] {
            let source = String(repeating: unit, count: 500)
            let result = try roundTrip(ConversationMessagePayload(kind: .text, body: source))
            XCTAssertLessThanOrEqual(result.utf8.count, 512)
            XCTAssertLessThanOrEqual(result.count, 180)
            XCTAssertTrue(source.hasPrefix(result))
            XCTAssertTrue(result.allSatisfy { String($0) == unit })
            XCTAssertFalse(result.contains("\u{FFFD}"))
        }
        // A single giant grapheme must not cause unbounded Character iteration.
        let giant = "a" + String(repeating: "\u{301}", count: 9000)
        XCTAssertEqual(try roundTrip(ConversationMessagePayload(kind: .text, body: giant)), "New message")
        XCTAssertEqual(try roundTrip(ConversationMessagePayload(kind: .text, body: "hello " + giant)), "hello ")
        let exact = String(repeating: "😀", count: 128)
        XCTAssertEqual(try roundTrip(ConversationMessagePayload(kind: .text, body: exact)), exact)
    }

    func testMessageCreateContextRequiredAndEveryContextFieldIsBound() throws {
        let payload = try ConversationMessagePayload(kind: .text, body: "private")
        let envelope = try NotificationPreviewCipher.seal(payload, context: context(), epochKey: key)
        let variants = try [context(conversation: otherID), context(record: otherID), context(sender: "bob"),
                            context(epoch: 2), context(revision: 2)]
        for candidate in variants {
            XCTAssertThrowsError(try NotificationPreviewCipher.open(envelope, messageContext: candidate, epochKey: key))
        }
        for kind in RecordKind.allCases where kind != .message {
            XCTAssertThrowsError(try NotificationPreviewCipher.seal(payload, context: context(kind: kind), epochKey: key))
            XCTAssertThrowsError(try NotificationPreviewCipher.open(envelope, messageContext: context(kind: kind), epochKey: key))
        }
        XCTAssertThrowsError(try NotificationPreviewCipher.seal(payload, context: context(revision: 2), epochKey: key))
        XCTAssertThrowsError(try NotificationPreviewCipher.seal(payload, context: context(record: "not-a-uuid"), epochKey: key))
        XCTAssertThrowsError(try NotificationPreviewCipher.seal(payload, context: context(conversation: "not-a-uuid"), epochKey: key))
        // Byte-exact sender identity must survive Swift's normalized String equality.
        let original = try NotificationPreviewCipher.seal(payload, context: context(sender: "caf\u{e9}"), epochKey: key)
        XCTAssertThrowsError(try NotificationPreviewCipher.open(original, messageContext: context(sender: "cafe\u{301}"), epochKey: key))
    }

    func testMessageOrOtherRecordCiphertextCannotBecomeAPreview() throws {
        let raw = encodedText("private")
        for kind in RecordKind.allCases where kind != .notificationPreview {
            let envelope = try RecordCipher.seal(raw, context: context(kind: kind), epochKey: key)
            XCTAssertThrowsError(try NotificationPreviewCipher.open(envelope, messageContext: context(), epochKey: key))
            let relabeled = recordEnvelope(context: try context(kind: .notificationPreview), box: try RecordCipher.decode(envelope).box)
            XCTAssertThrowsError(try NotificationPreviewCipher.open(relabeled, messageContext: context(), epochKey: key))
        }
        let message = try ConversationMessageCipher.seal(ConversationMessagePayload(kind: .text, body: "private"), context: context(), epochKey: key)
        XCTAssertThrowsError(try NotificationPreviewCipher.open(message, messageContext: context(), epochKey: key))
        let preview = try NotificationPreviewCipher.seal(ConversationMessagePayload(kind: .text, body: "private"), context: context(), epochKey: key)
        XCTAssertThrowsError(try ConversationMessageCipher.open(preview, expectedContext: context(), epochKey: key))
    }

    func testWrongKeyTamperingTruncationTrailingAndEnvelopeBounds() throws {
        let envelope = try NotificationPreviewCipher.seal(ConversationMessagePayload(kind: .text, body: "private"), context: context(), epochKey: key)
        XCTAssertThrowsError(try NotificationPreviewCipher.open(envelope, messageContext: context(), epochKey: SymmetricKey(size: .bits256)))
        XCTAssertThrowsError(try NotificationPreviewCipher.open(envelope, messageContext: context(), epochKey: SymmetricKey(size: .bits128)))
        XCTAssertThrowsError(try NotificationPreviewCipher.seal(ConversationMessagePayload(kind: .text, body: "private"), context: context(), epochKey: SymmetricKey(size: .bits128)))
        let box = try RecordCipher.decode(envelope).box
        let nonceOffset = envelope.count - 16 - box.ciphertext.count - 4 - 12
        for offset in [nonceOffset, envelope.count - 17, envelope.count - 1] {
            var changed = envelope; changed[offset] ^= 1
            XCTAssertThrowsError(try NotificationPreviewCipher.open(changed, messageContext: context(), epochKey: key))
        }
        for length in 0..<envelope.count {
            XCTAssertThrowsError(try NotificationPreviewCipher.open(Data(envelope.prefix(length)), messageContext: context(), epochKey: key))
        }
        XCTAssertThrowsError(try NotificationPreviewCipher.open(envelope + Data([0]), messageContext: context(), epochKey: key))
        XCTAssertThrowsError(try NotificationPreviewCipher.open(Data(repeating: 0, count: 2049), messageContext: context(), epochKey: key)) { error in
            XCTAssertEqual(error as? ContentError, .sizeLimitExceeded)
        }
        var future = envelope; future[RecordCipher.magic.count + 3] = 2
        XCTAssertThrowsError(try NotificationPreviewCipher.open(future, messageContext: context(), epochKey: key))
    }

    func testStrictPayloadMagicVersionUTF8SizeEmptyMissingAndTrailing() throws {
        let valid = encodedText("hello")
        for length in 0..<valid.count { try assertRejectedPayload(Data(valid.prefix(length))) }
        try assertRejectedPayload(encodedText(""))
        try assertRejectedPayload(encodedText("future", version: 2))
        try assertRejectedPayload(valid + Data([0]))
        try assertRejectedPayload(encodedText(String(repeating: "a", count: 181)))
        try assertRejectedPayload(encodedText(String(repeating: "😀", count: 129)))
        var badMagic = valid; badMagic[0] ^= 1
        try assertRejectedPayload(badMagic)
        var badUTF8 = valid; badUTF8[badUTF8.count - 1] = 0xFF
        try assertRejectedPayload(badUTF8)
        var hugeLength = valid
        hugeLength.replaceSubrange((NotificationPreviewCipher.magic.count + 4)..<(NotificationPreviewCipher.magic.count + 8), with: [255, 255, 255, 255])
        try assertRejectedPayload(hugeLength)
        try assertRejectedPayload(Data(repeating: 0, count: NotificationPreviewCipher.magic.count + 8 + 513))
    }
}
