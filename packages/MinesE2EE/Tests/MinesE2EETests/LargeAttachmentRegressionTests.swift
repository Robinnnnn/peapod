import CryptoKit
import Foundation
import XCTest
@testable import MinesE2EE

final class LargeAttachmentRegressionTests: XCTestCase {
    func testBinaryReaderAndCipherAcceptSharedSlicesWithNonzeroIndices() throws {
        var writer = BinaryWriter()
        writer.uint32(0x01020304)
        writer.lengthPrefixed(Data(repeating: 0x95, count: 8192))
        writer.uint64(0x0102030405060708)
        let prefix = Data(repeating: 0xFA, count: 19)
        let container = prefix + writer.data
        let slice = container[prefix.count...]
        XCTAssertNotEqual(slice.startIndex, 0)
        var reader = BinaryReader(slice)
        XCTAssertEqual(try reader.uint32(), 0x01020304)
        let payload = try reader.lengthPrefixed(maximum: 8192)
        XCTAssertNotEqual(payload.startIndex, 0)
        XCTAssertEqual(payload, Data(repeating: 0x95, count: 8192))
        XCTAssertEqual(try reader.uint64(), 0x0102030405060708)
        XCTAssertTrue(reader.isAtEnd)
        XCTAssertThrowsError(try reader.bytes(1))

        let context = try RecordContext(conversationID: "conversation", recordID: "message", senderID: "alice", keyEpoch: 1, revision: 1)
        let cipher = try AttachmentCipher()
        let sealed = try cipher.seal(payload, context: context, attachmentID: "blob", filename: "original.mov", mediaType: "video/quicktime")
        let wrapped = prefix + sealed.bytes
        XCTAssertEqual(try cipher.open(wrapped[prefix.count...], privateMetadata: sealed.privateMetadata, expectedContext: context), payload)
    }

    /// Isolated file-mapped one-shot sealing resource probe, separate from SQLite/open.
    func test200MiBMappedOriginalSealing() throws {
        guard ProcessInfo.processInfo.environment["MINES_RUN_LARGE_ATTACHMENT_TEST"] == "1" else {
            throw XCTSkip("Opt-in mapped 200 MiB sealing probe")
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mines-mapped-original-\(UUID())")
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]))
        let writer = try FileHandle(forWritingTo: file)
        do {
            let block = Data(repeating: 0x35, count: 1024 * 1024)
            for _ in 0..<200 { try writer.write(contentsOf: block) }
            try writer.close()
        } catch { try? writer.close(); throw error }
        let original = try Data(contentsOf: file, options: [.alwaysMapped])
        XCTAssertEqual(original.count, 200 * 1024 * 1024)
        let context = try RecordContext(conversationID: "conversation", recordID: "message", senderID: "alice", keyEpoch: 1, revision: 1)
        let cipher = try AttachmentCipher()
        let sealed = try cipher.seal(original, context: context, attachmentID: "original-video", filename: "original.mov", mediaType: "video/quicktime")
        XCTAssertEqual(sealed.privateMetadata.originalByteCount, original.count)
        XCTAssertGreaterThan(sealed.bytes.count, original.count)
        XCTAssertLessThanOrEqual(sealed.bytes.count, POCLimits.attachmentEnvelopeBytes)
    }

    /// Explicit native resource probe; run serially with MINES_RUN_LARGE_ATTACHMENT_TEST=1.
    /// This checks exact original bytes and durable retry, not physical-iPhone memory safety.
    func test200MiBOriginalSurvivesOutboxRestart() throws {
        guard ProcessInfo.processInfo.environment["MINES_RUN_LARGE_ATTACHMENT_TEST"] == "1" else {
            throw XCTSkip("Opt-in 200 MiB durable round trip; run serially with MINES_RUN_LARGE_ATTACHMENT_TEST=1")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mines-large-outbox-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try RecordContext(conversationID: "conversation", recordID: "message", senderID: "alice", keyEpoch: 1, revision: 1)
        let scope = try OutboxScope(accountID: "alice", conversationID: "conversation", keyEpoch: 1)
        let key = SymmetricKey(size: .bits256)
        let metadata: PrivateAttachment
        let originalDigest: Data
        let ciphertextDigest: Data
        let receipt: OutboxAcknowledgement
        do {
            let original = Data(repeating: 0x35, count: 200 * 1024 * 1024)
            originalDigest = Data(SHA256.hash(data: original))
            let sealed = try AttachmentCipher().seal(original, context: context, attachmentID: "original-video",
                filename: "original.mov", mediaType: "video/quicktime")
            metadata = sealed.privateMetadata
            XCTAssertEqual(metadata.originalByteCount, original.count)
            ciphertextDigest = Data(SHA256.hash(data: sealed.bytes))
            let message = try MessageCipher.seal(MessagePayload(text: "original video", attachments: [metadata]), context: context, epochKey: key)
            let store = try DurableCiphertextOutbox(directory: directory, limits: .production)
            let prepared = try store.enqueueForDelivery(envelope: message,
                attachments: [OutboxAttachment(attachmentID: metadata.attachmentID, bytes: sealed.bytes)],
                context: context, scope: scope, epochKey: key)
            receipt = prepared.acknowledgement
            XCTAssertEqual(prepared.envelope, message)
            XCTAssertEqual(prepared.attachments.first?.bytes, sealed.bytes)
            XCTAssertEqual(try store.recordState(scope: scope, recordID: context.recordID), .pending(revision: 1))
            XCTAssertEqual(try store.enqueue(envelope: message,
                attachments: [OutboxAttachment(attachmentID: metadata.attachmentID, bytes: sealed.bytes)],
                context: context, scope: scope, epochKey: key), receipt)
            store.close()
        }
        let restarted = try DurableCiphertextOutbox(directory: directory, limits: .production)
        defer { restarted.close() }
        let pending = try XCTUnwrap(restarted.load(scope: scope, recordID: context.recordID, epochKey: key))
        XCTAssertEqual(pending.acknowledgement, receipt)
        let attachment = try XCTUnwrap(pending.attachments.first)
        XCTAssertEqual(pending.attachments.count, 1)
        XCTAssertEqual(Data(SHA256.hash(data: attachment.bytes)), ciphertextDigest)
        let decrypted = try AttachmentCipher().open(attachment.bytes, privateMetadata: metadata, expectedContext: context)
        XCTAssertEqual(decrypted.count, 200 * 1024 * 1024)
        XCTAssertEqual(Data(SHA256.hash(data: decrypted)), originalDigest)
        XCTAssertTrue(try restarted.acknowledge(receipt))
        XCTAssertNil(try restarted.load(scope: scope, recordID: context.recordID, epochKey: key))
    }
}
