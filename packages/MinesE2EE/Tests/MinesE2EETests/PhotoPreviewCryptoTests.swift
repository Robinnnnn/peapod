import CryptoKit
import Foundation
import XCTest
@testable import MinesE2EE

final class PhotoPreviewCryptoTests: XCTestCase {
    private let key = SymmetricKey(data: Data(repeating: 7, count: 32))
    private func fixture(revision: UInt64 = 1) throws -> (RecordContext, SealedAttachment) {
        let context = try RecordContext(conversationID: "conversation", recordID: "message", senderID: "alice", keyEpoch: 1, revision: revision)
        return (context, try AttachmentCipher().seal(Data("full-resolution original".utf8), context: context,
            attachmentID: "original", filename: "private.jpg", mediaType: "image/jpeg"))
    }

    func testPhotoPreviewRoundTripLeavesOriginalMessageAndAttachmentUnchanged() throws {
        let (context, original) = try fixture()
        let payload = try MessagePayload(text: "", attachments: [original.privateMetadata])
        let message = try MessageCipher.seal(payload, context: context, epochKey: key)
        let bytes = Data("small JPEG stand-in".utf8)
        let first = try PhotoPreviewCipher.seal(bytes, original: original.privateMetadata, context: context)
        let second = try PhotoPreviewCipher.seal(bytes, original: original.privateMetadata, context: context)
        XCTAssertEqual(first.attachmentID, second.attachmentID)
        XCTAssertEqual(UUID(uuidString: first.attachmentID)?.uuidString.lowercased(), first.attachmentID)
        XCTAssertNotEqual(first.attachmentID, original.privateMetadata.attachmentID)
        let rekeyed = try PrivateAttachment(attachmentID: original.privateMetadata.attachmentID,
            key: Data(repeating: 0x91, count: 32), filename: original.privateMetadata.filename,
            mediaType: original.privateMetadata.mediaType, originalByteCount: original.privateMetadata.originalByteCount)
        XCTAssertNotEqual(first.attachmentID, PhotoPreviewCipher.attachmentID(for: rekeyed, context: context),
                          "Relay-visible identity must not be a dictionary-testable hash of private metadata.")
        XCTAssertNotEqual(first.bytes, second.bytes)
        XCTAssertEqual(try PhotoPreviewCipher.open(first.bytes, original: original.privateMetadata, context: context), bytes)
        XCTAssertEqual(try MessageCipher.open(message, expectedContext: context, epochKey: key), payload)
        XCTAssertEqual(try AttachmentCipher().open(original.bytes, privateMetadata: original.privateMetadata, expectedContext: context), Data("full-resolution original".utf8))
    }

    func testPhotoPreviewRejectsTamperingWrongOriginalContextAndSize() throws {
        let (context, original) = try fixture()
        let preview = try PhotoPreviewCipher.seal(Data([1, 2, 3]), original: original.privateMetadata, context: context)
        var corrupt = preview.bytes; corrupt[corrupt.count - 1] ^= 1
        XCTAssertThrowsError(try PhotoPreviewCipher.open(corrupt, original: original.privateMetadata, context: context))
        let (otherContext, otherOriginal) = try fixture(revision: 2)
        XCTAssertNotEqual(PhotoPreviewCipher.attachmentID(for: original.privateMetadata, context: context), PhotoPreviewCipher.attachmentID(for: original.privateMetadata, context: otherContext))
        XCTAssertThrowsError(try PhotoPreviewCipher.open(preview.bytes, original: original.privateMetadata, context: otherContext))
        XCTAssertThrowsError(try PhotoPreviewCipher.open(preview.bytes, original: otherOriginal.privateMetadata, context: context))
        XCTAssertThrowsError(try PhotoPreviewCipher.seal(Data(repeating: 1, count: PhotoPreviewCipher.maximumBytes + 1), original: original.privateMetadata, context: context))
        XCTAssertThrowsError(try PhotoPreviewCipher.open(Data(repeating: 0, count: PhotoPreviewCipher.maximumEnvelopeBytes + 1), original: original.privateMetadata, context: context))
        let audio = try PrivateAttachment(attachmentID: "audio", key: original.privateMetadata.key, filename: "voice.m4a", mediaType: "audio/mp4", originalByteCount: 3)
        XCTAssertThrowsError(try PhotoPreviewCipher.seal(Data([1]), original: audio, context: context))
    }

    func testPhotoPreviewOutboxPreservesExactSidecarAcrossRestartAndRejectsForeignExtras() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("photo-preview-outbox-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (context, original) = try fixture()
        let scope = try OutboxScope(accountID: context.senderID, conversationID: context.conversationID, keyEpoch: 1)
        let envelope = try MessageCipher.seal(MessagePayload(text: "", attachments: [original.privateMetadata]), context: context, epochKey: key)
        let blob = try OutboxAttachment(attachmentID: original.privateMetadata.attachmentID, bytes: original.bytes)
        let preview = try PhotoPreviewCipher.seal(Data([1, 2, 3]), original: original.privateMetadata, context: context)
        let store = try DurableCiphertextOutbox(directory: directory)
        let pending = try store.enqueueForDelivery(envelope: envelope, attachments: [preview, blob], context: context, scope: scope, epochKey: key)
        XCTAssertEqual(pending.attachments, [blob, preview])
        store.close()
        let restarted = try DurableCiphertextOutbox(directory: directory)
        defer { restarted.close() }
        let loaded = try XCTUnwrap(restarted.load(scope: scope, recordID: context.recordID, epochKey: key))
        XCTAssertEqual(loaded.attachments, pending.attachments)
        XCTAssertEqual(loaded.envelope, envelope)
        XCTAssertEqual(try restarted.enqueueForDelivery(envelope: envelope, attachments: [blob, preview], context: context, scope: scope, epochKey: key).acknowledgement, pending.acknowledgement)
        let foreign = try OutboxAttachment(attachmentID: "foreign", bytes: preview.bytes)
        XCTAssertThrowsError(try restarted.enqueue(envelope: envelope, attachments: [blob, foreign], context: context, scope: scope, epochKey: key))
        XCTAssertThrowsError(try restarted.enqueue(envelope: envelope, attachments: [blob, preview, preview], context: context, scope: scope, epochKey: key))
        var corrupt = preview.bytes; corrupt[corrupt.count - 1] ^= 1
        let corruptBlob = try OutboxAttachment(attachmentID: preview.attachmentID, bytes: corrupt)
        XCTAssertThrowsError(try restarted.enqueue(envelope: envelope, attachments: [blob, corruptBlob], context: context, scope: scope, epochKey: key))
    }
}
