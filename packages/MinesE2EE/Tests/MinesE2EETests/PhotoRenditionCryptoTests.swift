import CryptoKit
import XCTest
@testable import MinesE2EE

final class PhotoRenditionCryptoTests: XCTestCase {
    func testDisplayCopiesRoundTripWithoutChangingOriginal() throws {
        let context = try RecordContext(conversationID: "conversation", recordID: "photo", senderID: "alice", keyEpoch: 1, revision: 1)
        let original = try AttachmentCipher().seal(Data("original".utf8), context: context,
            attachmentID: "original", filename: "photo.heic", mediaType: "image/heic")
        var ids = Set<String>()
        for rendition in PhotoRendition.allCases {
            let image = Data(repeating: 7, count: 100_000)
            let sealed = try PhotoRenditionCipher.seal(image, original: original.privateMetadata, context: context, rendition: rendition)
            ids.insert(sealed.attachmentID)
            XCTAssertEqual(try PhotoRenditionCipher.open(sealed.bytes, original: original.privateMetadata, context: context, rendition: rendition), image)
            let other: PhotoRendition = rendition == .chat ? .viewer : .chat
            XCTAssertThrowsError(try PhotoRenditionCipher.open(sealed.bytes, original: original.privateMetadata, context: context, rendition: other))
        }
        XCTAssertEqual(ids.count, 2)
        XCTAssertFalse(ids.contains(original.privateMetadata.attachmentID))
        XCTAssertEqual(try AttachmentCipher().open(original.bytes, privateMetadata: original.privateMetadata, expectedContext: context), Data("original".utf8))
    }
    private func fixture() throws -> (RecordContext, SealedAttachment) {
        let context = try RecordContext(conversationID: "conversation", recordID: "photo", senderID: "alice", keyEpoch: 1, revision: 1)
        return (context, try AttachmentCipher().seal(Data("original bytes stay exact".utf8), context: context,
            attachmentID: "original", filename: "private.heic", mediaType: "image/heic"))
    }

    func testTamperCrossContextMetadataKeyAndPurposeFailAuthentication() throws {
        let (context, original) = try fixture()
        let metadata = original.privateMetadata
        for rendition in PhotoRendition.allCases {
            let sealed = try PhotoRenditionCipher.seal(Data([1, 2, 3]), original: metadata, context: context, rendition: rendition)
            var corrupt = sealed.bytes; corrupt[corrupt.count - 1] ^= 1
            XCTAssertThrowsError(try PhotoRenditionCipher.open(corrupt, original: metadata, context: context, rendition: rendition))
            let foreign = try RecordContext(conversationID: "foreign", recordID: context.recordID, senderID: context.senderID, keyEpoch: 1, revision: 1)
            let revision = try RecordContext(conversationID: context.conversationID, recordID: context.recordID, senderID: context.senderID, keyEpoch: 1, revision: 2)
            for changed in [foreign, revision] {
                XCTAssertThrowsError(try PhotoRenditionCipher.open(sealed.bytes, original: metadata, context: changed, rendition: rendition))
                XCTAssertNotEqual(sealed.attachmentID, PhotoRenditionCipher.attachmentID(for: metadata, context: changed, rendition: rendition))
            }
            for changed in [
                try PrivateAttachment(attachmentID: metadata.attachmentID, key: Data(repeating: 91, count: 32), filename: metadata.filename, mediaType: metadata.mediaType, originalByteCount: metadata.originalByteCount),
                try PrivateAttachment(attachmentID: metadata.attachmentID, key: metadata.key, filename: "changed.heic", mediaType: metadata.mediaType, originalByteCount: metadata.originalByteCount),
                try PrivateAttachment(attachmentID: metadata.attachmentID, key: metadata.key, filename: metadata.filename, mediaType: metadata.mediaType, originalByteCount: metadata.originalByteCount + 1)
            ] {
                XCTAssertThrowsError(try PhotoRenditionCipher.open(sealed.bytes, original: changed, context: context, rendition: rendition))
            }
            XCTAssertThrowsError(try PhotoPreviewCipher.open(sealed.bytes, original: metadata, context: context))
            XCTAssertThrowsError(try AttachmentCipher().open(sealed.bytes, privateMetadata: metadata, expectedContext: context))
            XCTAssertThrowsError(try PhotoRenditionCipher.seal(Data(), original: metadata, context: context, rendition: rendition))
            XCTAssertThrowsError(try PhotoRenditionCipher.seal(Data(repeating: 1, count: rendition.maximumBytes + 1), original: metadata, context: context, rendition: rendition))
            XCTAssertThrowsError(try PhotoRenditionCipher.open(Data(repeating: 0, count: rendition.maximumEnvelopeBytes + 1), original: metadata, context: context, rendition: rendition))
        }
        let audio = try PrivateAttachment(attachmentID: "audio", key: metadata.key, filename: "voice.m4a", mediaType: "audio/mp4", originalByteCount: 3)
        XCTAssertThrowsError(try PhotoRenditionCipher.seal(Data([1]), original: audio, context: context, rendition: .chat))
    }

    func testDurableBundleRestartsWithExactOriginalPreviewAndBothRenditionsAndRejectsExtras() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("photo-renditions-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (context, original) = try fixture()
        let key = SymmetricKey(data: Data(repeating: 7, count: 32))
        let scope = try OutboxScope(accountID: context.senderID, conversationID: context.conversationID, keyEpoch: 1)
        let envelope = try MessageCipher.seal(MessagePayload(text: "", attachments: [original.privateMetadata]), context: context, epochKey: key)
        let blob = try OutboxAttachment(attachmentID: original.privateMetadata.attachmentID, bytes: original.bytes)
        let preview = try PhotoPreviewCipher.seal(Data([1, 2]), original: original.privateMetadata, context: context)
        let copies = try PhotoRendition.allCases.map { try PhotoRenditionCipher.seal(Data(repeating: 3, count: 50_000), original: original.privateMetadata, context: context, rendition: $0) }
        let canonical = [blob, preview] + copies
        let store = try DurableCiphertextOutbox(directory: directory)
        let pending = try store.enqueueForDelivery(envelope: envelope, attachments: canonical.reversed(), context: context, scope: scope, epochKey: key)
        XCTAssertEqual(pending.attachments, canonical)
        store.close()
        let reopened = try DurableCiphertextOutbox(directory: directory)
        defer { reopened.close() }
        let loaded = try XCTUnwrap(reopened.load(scope: scope, recordID: context.recordID, epochKey: key))
        XCTAssertEqual(loaded.envelope, envelope)
        XCTAssertEqual(loaded.attachments, canonical)
        XCTAssertEqual(try reopened.enqueueForDelivery(envelope: envelope, attachments: canonical, context: context, scope: scope, epochKey: key).acknowledgement, pending.acknowledgement)
        let foreign = try OutboxAttachment(attachmentID: "foreign", bytes: copies[0].bytes)
        XCTAssertThrowsError(try reopened.enqueue(envelope: envelope, attachments: canonical + [foreign], context: context, scope: scope, epochKey: key))
        XCTAssertThrowsError(try reopened.enqueue(envelope: envelope, attachments: canonical + [copies[0]], context: context, scope: scope, epochKey: key))
        let wrongPurpose = try OutboxAttachment(attachmentID: copies[0].attachmentID, bytes: copies[1].bytes)
        XCTAssertThrowsError(try reopened.enqueue(envelope: envelope, attachments: [blob, preview, wrongPurpose, copies[1]], context: context, scope: scope, epochKey: key))
        var corrupt = copies[0].bytes; corrupt[corrupt.count - 1] ^= 1
        let tampered = try OutboxAttachment(attachmentID: copies[0].attachmentID, bytes: corrupt)
        XCTAssertThrowsError(try reopened.enqueue(envelope: envelope, attachments: [blob, preview, tampered, copies[1]], context: context, scope: scope, epochKey: key))
    }

}
