import CryptoKit
import Foundation
import XCTest
@testable import MinesE2EE

final class MessageAndRelayTests: XCTestCase {
    func context(sender: String = "alice") throws -> RecordContext {
        try RecordContext(conversationID: "paired", recordID: "message-1", senderID: sender, keyEpoch: 1, revision: 1)
    }

    func testPrivatePayloadLiteralKnownAnswerAndNonASCIIText() throws {
        // Independently specified literal binary bytes: magic, version, lp32 UTF8, attachment count.
        let expected = Data(hex: "6d696e65732f706f632f6d6573736167650000000100000005486920c3a900000000")
        let payload = try MessagePayload(text: "Hi é")
        XCTAssertEqual(try payload.encoded(), expected)
        XCTAssertEqual(try MessagePayload.decode(expected), payload)
        let empty = Data(hex: "6d696e65732f706f632f6d657373616765000000010000000000000000")
        XCTAssertEqual(try MessagePayload(text: "").encoded(), empty)
    }

    func testTextAndAttachmentDescriptorBoundsAndWrongKind() throws {
        let key = SymmetricKey(size: .bits256)
        let context = try context()
        let maximum = try MessagePayload(text: String(repeating: "😀", count: POCLimits.messageTextBytes / 4))
        let envelope = try MessageCipher.seal(maximum, context: context, epochKey: key)
        XCTAssertEqual(try MessageCipher.open(envelope, expectedContext: context, epochKey: key), maximum)
        XCTAssertThrowsError(try MessagePayload(text: maximum.text + "a"))
        let descriptors = try (0..<POCLimits.attachmentsPerMessage).map {
            try PrivateAttachment(attachmentID: String(repeating: "a", count: 510) + "\($0)",
                key: Data(repeating: UInt8($0), count: 32), filename: String(repeating: "f", count: 1024),
                mediaType: String(repeating: "m", count: 256), originalByteCount: POCLimits.attachmentPlaintextBytes,
                voiceDurationMilliseconds: .max)
        }
        let full = try MessagePayload(text: maximum.text, attachments: descriptors)
        XCTAssertEqual(try MessagePayload.decode(full.encoded()), full)
        XCTAssertThrowsError(try MessagePayload(text: "", attachments: descriptors + [descriptors[0]]))
        XCTAssertThrowsError(try MessagePayload(text: "", attachments: [descriptors[0], descriptors[0]]))
        let notMessage = try RecordContext(conversationID: "paired", recordID: "id", senderID: "alice", kind: .location, keyEpoch: 1, revision: 1)
        XCTAssertThrowsError(try MessageCipher.seal(full, context: notMessage, epochKey: key)) {
            XCTAssertEqual($0 as? E2EEError, .invalidContext)
        }
        XCTAssertThrowsError(try MessageCipher.open(envelope, expectedContext: notMessage, epochKey: key))
    }

    func testFuturePayloadMalformedLengthsUTF8DurationAndTrailingBytes() throws {
        let key = SymmetricKey(size: .bits256)
        let context = try context()
        let empty = try MessagePayload(text: "").encoded()
        var future = empty
        future[MessagePayload.magic.count + 3] = 2
        let futureEnvelope = try RecordCipher.seal(future, context: context, epochKey: key)
        XCTAssertThrowsError(try MessageCipher.open(futureEnvelope, expectedContext: context, epochKey: key)) {
            XCTAssertEqual($0 as? E2EEError, .unsupportedPayloadVersion)
        }
        var oversizedCount = empty
        oversizedCount.replaceSubrange((empty.count - 4)..<empty.count, with: [255, 255, 255, 255])
        XCTAssertThrowsError(try MessagePayload.decode(oversizedCount)) {
            XCTAssertEqual($0 as? E2EEError, .sizeLimitExceeded)
        }
        var oversizedText = empty
        oversizedText.replaceSubrange((MessagePayload.magic.count + 4)..<(MessagePayload.magic.count + 8), with: [255, 255, 255, 255])
        XCTAssertThrowsError(try MessagePayload.decode(oversizedText)) {
            XCTAssertEqual($0 as? E2EEError, .sizeLimitExceeded)
        }
        var badUTF8 = try MessagePayload(text: "a").encoded()
        badUTF8[MessagePayload.magic.count + 8] = 255
        XCTAssertThrowsError(try MessagePayload.decode(badUTF8)) {
            XCTAssertEqual($0 as? E2EEError, .malformedPayload)
        }
        let descriptor = try PrivateAttachment(attachmentID: "blob", key: Data(repeating: 0, count: 32), filename: "file", mediaType: "type", originalByteCount: 0)
        var badDuration = try MessagePayload(text: "", attachments: [descriptor]).encoded()
        badDuration[badDuration.count - 1] = 2
        XCTAssertThrowsError(try MessagePayload.decode(badDuration)) {
            XCTAssertEqual($0 as? E2EEError, .malformedPayload)
        }
        for length in 0..<badDuration.count {
            XCTAssertThrowsError(try MessagePayload.decode(Data(badDuration.prefix(length))))
        }
        XCTAssertThrowsError(try MessagePayload.decode(empty + Data([0])))
    }

    func testSimulatedTwoAccountsTwoDevicesWithCiphertextOnlyRelay() throws {
        // IN-MEMORY SIMULATION ONLY: not proof of iCloud synchronization or Apple-account isolation.
        // Pairing/key exchange is also assumed here, not implemented or security-verified.
        let pairedEpochKey = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let accountKeyCopies = ["alice": [pairedEpochKey, pairedEpochKey], "bob": [pairedEpochKey, pairedEpochKey]]
        let context = try context()
        let bytes = Data("private attachment contents".utf8)
        let attachment = try AttachmentCipher().seal(bytes, context: context, attachmentID: "opaque-object-1",
            filename: "secret-voice.m4a", mediaType: "audio/mp4", voiceDurationMilliseconds: 1234)
        let message = try MessagePayload(text: "private text 😀", attachments: [attachment.privateMetadata])
        let sealedMessage = try MessageCipher.seal(message, context: context,
            epochKey: SymmetricKey(data: accountKeyCopies["alice"]![0]))
        // The simulated relay's complete content storage consists of opaque bytes alone.
        let relay: [Data] = [sealedMessage, attachment.bytes]
        for opaque in relay {
            for privateString in [message.text, attachment.privateMetadata.filename, attachment.privateMetadata.mediaType] {
                XCTAssertNil(opaque.range(of: Data(privateString.utf8)))
            }
            XCTAssertNil(opaque.range(of: attachment.privateMetadata.key))
            XCTAssertNil(opaque.range(of: bytes))
        }
        for account in ["alice", "bob"] {
            for deviceKey in accountKeyCopies[account]! {
                let opened = try MessageCipher.open(relay[0], expectedContext: context, epochKey: SymmetricKey(data: deviceKey))
                XCTAssertEqual(opened, message)
                XCTAssertEqual(try AttachmentCipher().open(relay[1], privateMetadata: opened.attachments[0], expectedContext: context), bytes)
            }
        }
        XCTAssertThrowsError(try MessageCipher.open(relay[0], expectedContext: context, epochKey: SymmetricKey(size: .bits256)))
        // Both participants share the epoch secret, so either can claim either sender; no signatures.
        let forgedSender = try MessageCipher.seal(try MessagePayload(text: "shared-key holder"),
            context: self.context(sender: "bob"), epochKey: SymmetricKey(data: accountKeyCopies["alice"]![1]))
        XCTAssertEqual(try MessageCipher.open(forgedSender, expectedContext: self.context(sender: "bob"),
            epochKey: SymmetricKey(data: accountKeyCopies["bob"]![0])).text, "shared-key holder")
    }
}
