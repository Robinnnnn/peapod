import CryptoKit
import Foundation
import XCTest
@testable import MinesE2EE

final class AttachmentCryptoTests: XCTestCase {
    func context(revision: UInt64 = 1) throws -> RecordContext {
        try RecordContext(conversationID: "conversation", recordID: "message", senderID: "alice",
                          keyEpoch: 1, revision: revision)
    }

    func testRandomIndependentKeysAndNoncesRoundTripEmptyAndNonempty() throws {
        let cipher = try AttachmentCipher()
        let context = try context()
        for plaintext in [Data(), Data("file contents 😀".utf8)] {
            let first = try cipher.seal(plaintext, context: context, attachmentID: "opaque-a",
                                        filename: "private.txt", mediaType: "text/plain")
            let second = try cipher.seal(plaintext, context: context, attachmentID: "opaque-a",
                                         filename: "private.txt", mediaType: "text/plain")
            XCTAssertNotEqual(first.privateMetadata.key, second.privateMetadata.key)
            XCTAssertNotEqual(first.bytes, second.bytes)
            let nonceOffset = first.bytes.count - 16 - plaintext.count - 4 - 12
            XCTAssertNotEqual(first.bytes.subdata(in: nonceOffset..<(nonceOffset + 12)),
                              second.bytes.subdata(in: nonceOffset..<(nonceOffset + 12)))
            XCTAssertEqual(try cipher.open(first.bytes, privateMetadata: first.privateMetadata,
                                            expectedContext: context), plaintext)
        }
    }

    func testHard200MiBCapIsInclusiveAndCannotBeRaised() throws {
        let cipher = try AttachmentCipher()
        let context = try context()
        let maximum = Data(repeating: 0x35, count: POCLimits.attachmentPlaintextBytes)
        let sealed = try cipher.seal(maximum, context: context, attachmentID: "maximum",
                                     filename: "maximum.bin", mediaType: "application/octet-stream")
        XCTAssertEqual(try cipher.open(sealed.bytes, privateMetadata: sealed.privateMetadata,
                                      expectedContext: context), maximum)
        XCTAssertThrowsError(try AttachmentCipher(maximumPlaintextBytes: POCLimits.attachmentPlaintextBytes + 1)) {
            XCTAssertEqual($0 as? E2EEError, .invalidLimit)
        }
        XCTAssertThrowsError(try AttachmentCipher(maximumPlaintextBytes: -1)) {
            XCTAssertEqual($0 as? E2EEError, .invalidLimit)
        }
        XCTAssertThrowsError(try cipher.seal(maximum + Data([0]), context: context, attachmentID: "oversized",
                                             filename: "file", mediaType: "type")) {
            XCTAssertEqual($0 as? E2EEError, .sizeLimitExceeded)
        }
        let lower = try AttachmentCipher(maximumPlaintextBytes: 5)
        XCTAssertThrowsError(try lower.open(sealed.bytes, privateMetadata: sealed.privateMetadata, expectedContext: context)) {
            XCTAssertEqual($0 as? E2EEError, .sizeLimitExceeded)
        }
        let zero = try AttachmentCipher(maximumPlaintextBytes: 0)
        let empty = try zero.seal(Data(), context: context, attachmentID: "empty", filename: "file", mediaType: "type")
        XCTAssertEqual(try zero.open(empty.bytes, privateMetadata: empty.privateMetadata, expectedContext: context), Data())
        XCTAssertThrowsError(try zero.seal(Data([0]), context: context, attachmentID: "one", filename: "file", mediaType: "type"))
    }

    func testCorruptTruncatedOversizedAndFutureAttachmentsFailClosed() throws {
        let cipher = try AttachmentCipher(maximumPlaintextBytes: 64)
        let context = try context()
        let sealed = try cipher.seal(Data("attachment".utf8), context: context, attachmentID: "blob",
                                     filename: "file", mediaType: "type")
        let nonceStart = sealed.bytes.count - 16 - 10 - 4 - 12
        for offset in [nonceStart, sealed.bytes.count - 16 - 10, sealed.bytes.count - 1] {
            var corrupt = sealed.bytes
            corrupt[offset] ^= 1
            XCTAssertThrowsError(try cipher.open(corrupt, privateMetadata: sealed.privateMetadata, expectedContext: context)) {
                XCTAssertEqual($0 as? E2EEError, .authenticationFailed)
            }
        }
        for length in 0..<sealed.bytes.count {
            XCTAssertThrowsError(try cipher.open(Data(sealed.bytes.prefix(length)), privateMetadata: sealed.privateMetadata,
                                                 expectedContext: context))
        }
        var declaredOversize = sealed.bytes
        let lengthOffset = nonceStart + 12
        declaredOversize.replaceSubrange(lengthOffset..<(lengthOffset + 4), with: [255, 255, 255, 255])
        XCTAssertThrowsError(try cipher.open(declaredOversize, privateMetadata: sealed.privateMetadata, expectedContext: context)) {
            XCTAssertEqual($0 as? E2EEError, .sizeLimitExceeded)
        }
        XCTAssertThrowsError(try cipher.open(Data(repeating: 0, count: 4161), privateMetadata: sealed.privateMetadata, expectedContext: context)) {
            XCTAssertEqual($0 as? E2EEError, .sizeLimitExceeded)
        }
        var future = sealed.bytes
        future[AttachmentCipher.magic.count + 3] = 2
        XCTAssertThrowsError(try cipher.open(future, privateMetadata: sealed.privateMetadata, expectedContext: context)) {
            XCTAssertEqual($0 as? E2EEError, .unsupportedVersion)
        }
        XCTAssertThrowsError(try cipher.open(sealed.bytes + Data([0]), privateMetadata: sealed.privateMetadata, expectedContext: context)) {
            XCTAssertEqual($0 as? E2EEError, .malformedEnvelope)
        }
    }

    func testWrongContextKeyAndEveryPrivateMetadataFieldAreRejected() throws {
        let cipher = try AttachmentCipher()
        let context = try context()
        let sealed = try cipher.seal(Data("audio".utf8), context: context, attachmentID: "blob",
                                     filename: "voice.m4a", mediaType: "audio/mp4", voiceDurationMilliseconds: 750)
        XCTAssertThrowsError(try cipher.open(sealed.bytes, privateMetadata: sealed.privateMetadata,
                                             expectedContext: self.context(revision: 2))) {
            XCTAssertEqual($0 as? E2EEError, .contextMismatch)
        }
        let metadata = sealed.privateMetadata
        let variants = try [
            PrivateAttachment(attachmentID: "other", key: metadata.key, filename: metadata.filename,
                mediaType: metadata.mediaType, originalByteCount: 5, voiceDurationMilliseconds: 750),
            PrivateAttachment(attachmentID: "blob", key: Data(repeating: 0, count: 32), filename: metadata.filename,
                mediaType: metadata.mediaType, originalByteCount: 5, voiceDurationMilliseconds: 750),
            PrivateAttachment(attachmentID: "blob", key: metadata.key, filename: "other.m4a",
                mediaType: metadata.mediaType, originalByteCount: 5, voiceDurationMilliseconds: 750),
            PrivateAttachment(attachmentID: "blob", key: metadata.key, filename: metadata.filename,
                mediaType: "other/type", originalByteCount: 5, voiceDurationMilliseconds: 750),
            PrivateAttachment(attachmentID: "blob", key: metadata.key, filename: metadata.filename,
                mediaType: metadata.mediaType, originalByteCount: 6, voiceDurationMilliseconds: 750),
            PrivateAttachment(attachmentID: "blob", key: metadata.key, filename: metadata.filename,
                mediaType: metadata.mediaType, originalByteCount: 5, voiceDurationMilliseconds: 751)
        ]
        for variant in variants {
            XCTAssertThrowsError(try cipher.open(sealed.bytes, privateMetadata: variant, expectedContext: context))
        }
        XCTAssertThrowsError(try PrivateAttachment(attachmentID: "blob", key: Data(), filename: "file", mediaType: "type", originalByteCount: 0))
        XCTAssertThrowsError(try PrivateAttachment(attachmentID: "blob", key: metadata.key, filename: "file", mediaType: "type", originalByteCount: .max))
    }

    func testCanonicalEquivalentAttachmentIDMutationIsRejected() throws {
        let cipher = try AttachmentCipher()
        let context = try context()
        let sealed = try cipher.seal(Data([1]), context: context, attachmentID: "caf\u{e9}", filename: "file", mediaType: "type")
        var reader = BinaryReader(sealed.bytes)
        try reader.expect(AttachmentCipher.magic)
        _ = try reader.uint32()
        let decodedContext = try RecordContext.read(from: &reader)
        _ = try reader.string(maximum: POCLimits.identifierBytes)
        let nonce = try reader.bytes(12)
        let ciphertext = try reader.lengthPrefixed(maximum: POCLimits.attachmentPlaintextBytes)
        let tag = try reader.bytes(16)
        var writer = BinaryWriter()
        writer.bytes(AttachmentCipher.magic); writer.uint32(1)
        decodedContext.appendFields(to: &writer)
        writer.string("cafe\u{301}"); writer.bytes(nonce); writer.lengthPrefixed(ciphertext); writer.bytes(tag)
        XCTAssertThrowsError(try cipher.open(writer.data, privateMetadata: sealed.privateMetadata, expectedContext: context)) {
            XCTAssertEqual($0 as? E2EEError, .contextMismatch)
        }
    }
}
