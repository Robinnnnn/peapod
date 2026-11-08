import CryptoKit
import Foundation
import XCTest
@testable import MinesE2EE

final class RecordCryptoTests: XCTestCase {
    let key = SymmetricKey(data: Data(0..<32))

    func context(conversation: String = "conversation", record: String = "message",
                 sender: String = "alice", kind: RecordKind = .message,
                 epoch: UInt32 = 1, revision: UInt64 = 1) throws -> RecordContext {
        try RecordContext(conversationID: conversation, recordID: record, senderID: sender,
                          kind: kind, keyEpoch: epoch, revision: revision)
    }

    func assertError(_ expected: E2EEError, _ action: () throws -> Void,
                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try action(), file: file, line: line) {
            XCTAssertEqual($0 as? E2EEError, expected, file: file, line: line)
        }
    }

    func testIndependentPhaseZeroKnownAnswer() throws {
        // Deterministic known-answer vector; never production key material.
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<2 { repository.deleteLastPathComponent() }
        let vector = try JSONSerialization.jsonObject(with:
            Data(contentsOf: repository.appendingPathComponent("PairingFixtures/record-vector.json"))) as! [String: Any]
        let input = vector["inputs"] as! [String: Any]
        let expected = vector["expected"] as! [String: String]
        let context = try context(conversation: input["conversationId"] as! String,
            record: input["recordId"] as! String, sender: input["senderId"] as! String,
            epoch: UInt32(input["keyEpoch"] as! Int), revision: UInt64(input["revision"] as! Int))
        let epochKey = SymmetricKey(data: Data(hex: input["epochKeyHex"] as! String))
        let plaintext = Data((input["plaintextUTF8"] as! String).utf8)
        let nonce = try ChaChaPoly.Nonce(data: Data(hex: input["nonceHex"] as! String))
        XCTAssertEqual(context.salt.hex, expected["saltHex"])
        XCTAssertEqual(context.canonicalBytes.hex, expected["recordContextHex"])
        XCTAssertEqual(context.authenticatedData.hex, expected["authenticatedDataHex"])
        XCTAssertEqual(try RecordCipher.derivedKey(context: context, epochKey: epochKey).withUnsafeBytes { Data($0).hex },
                       expected["derivedKeyHex"])
        let sealed = try RecordCipher.seal(plaintext, context: context, epochKey: epochKey, nonce: nonce)
        let box = try RecordCipher.decode(sealed).box
        XCTAssertEqual(box.ciphertext.hex, expected["ciphertextHex"])
        XCTAssertEqual(box.tag.hex, expected["tagHex"])
        XCTAssertEqual(box.combined.hex, expected["combinedNonceCiphertextTagHex"])
        XCTAssertEqual(try RecordCipher.open(sealed, expectedContext: context, epochKey: epochKey), plaintext)
    }

    func testAllRecordKindsEmptyAndMaximumPayloadWithUTF8Identifiers() throws {
        for kind in RecordKind.allCases {
            let context = try context(conversation: String(repeating: "é", count: 256),
                                      record: "记录-😀", sender: "人", kind: kind,
                                      epoch: .max, revision: .max)
            for bytes in [Data(), Data(repeating: 0xA5, count: POCLimits.recordPlaintextBytes)] {
                let sealed = try RecordCipher.seal(bytes, context: context, epochKey: key)
                XCTAssertEqual(try RecordCipher.open(sealed, expectedContext: context, epochKey: key), bytes)
            }
        }
    }

    func testTamperingEveryContextFieldIsAuthenticated() throws {
        let original = try context()
        let plaintext = Data("private".utf8)
        let variants = try [context(conversation: "other"), context(record: "other"), context(sender: "other"),
                            context(kind: .reaction), context(epoch: 2), context(revision: 2)]
        let envelope = try RecordCipher.seal(plaintext, context: original, epochKey: key)
        let box = try RecordCipher.decode(envelope).box
        for candidate in variants {
            assertError(.contextMismatch) { _ = try RecordCipher.open(envelope, expectedContext: candidate, epochKey: key) }
            let relabeled = recordEnvelope(context: candidate, box: box)
            assertError(.authenticationFailed) { _ = try RecordCipher.open(relabeled, expectedContext: candidate, epochKey: key) }
        }
    }

    func testCanonicalEquivalentUTF8ContextMutationIsRejected() throws {
        let composed = try context(conversation: "caf\u{e9}")
        let decomposed = try context(conversation: "cafe\u{301}")
        XCTAssertEqual(composed.conversationID, decomposed.conversationID) // Swift normalizes equality.
        XCTAssertNotEqual(composed, decomposed) // Protocol must not.
        let original = try RecordCipher.seal(Data("secret".utf8), context: composed, epochKey: key)
        let tampered = recordEnvelope(context: decomposed, box: try RecordCipher.decode(original).box)
        assertError(.contextMismatch) { _ = try RecordCipher.open(tampered, expectedContext: composed, epochKey: key) }
        assertError(.authenticationFailed) { _ = try RecordCipher.open(tampered, expectedContext: decomposed, epochKey: key) }
        var guardState = RecordReplayGuard()
        _ = try guardState.openAndAccept(original, expectedContext: composed, epochKey: key)
        let separate = try RecordCipher.seal(Data("different byte identity".utf8), context: decomposed, epochKey: key)
        _ = try guardState.openAndAccept(separate, expectedContext: decomposed, epochKey: key)
    }

    func testNonceCiphertextAndTagTamperingAndWrongKey() throws {
        let context = try context()
        let sealed = try RecordCipher.seal(Data("secret".utf8), context: context, epochKey: key)
        let cipherCount = 6
        let nonceStart = sealed.count - 16 - cipherCount - 4 - 12
        for offset in [nonceStart, sealed.count - 16 - cipherCount, sealed.count - 1] {
            var tampered = sealed
            tampered[offset] ^= 1
            assertError(.authenticationFailed) { _ = try RecordCipher.open(tampered, expectedContext: context, epochKey: key) }
        }
        assertError(.authenticationFailed) {
            _ = try RecordCipher.open(sealed, expectedContext: context, epochKey: SymmetricKey(size: .bits256))
        }
        assertError(.invalidKey) {
            _ = try RecordCipher.open(sealed, expectedContext: context, epochKey: SymmetricKey(size: .bits128))
        }
        assertError(.invalidKey) {
            _ = try RecordCipher.seal(Data(), context: context, epochKey: SymmetricKey(size: .bits128))
        }
    }

    func testEnvelopeVersionsLengthsMalformedUTF8AndTruncation() throws {
        let context = try context()
        let sealed = try RecordCipher.seal(Data("hello".utf8), context: context, epochKey: key)
        var future = sealed
        future[RecordCipher.magic.count + 3] = 2
        assertError(.unsupportedVersion) { _ = try RecordCipher.open(future, expectedContext: context, epochKey: key) }
        var suite = sealed
        suite[RecordCipher.magic.count + 8] = 0x58
        assertError(.unsupportedSuite) { _ = try RecordCipher.open(suite, expectedContext: context, epochKey: key) }
        var header = BinaryWriter()
        header.bytes(RecordCipher.magic); header.uint32(1); header.string(RecordCipher.suite)
        header.string(context.conversationID); header.string(context.recordID); header.string(context.senderID)
        header.uint32(1); header.string("future-kind"); header.uint64(1)
        assertError(.unsupportedRecordKind) { _ = try RecordCipher.open(header.data, expectedContext: context, epochKey: key) }
        var hugeLength = sealed
        let ciphertextLengthOffset = sealed.count - 16 - 5 - 4
        hugeLength.replaceSubrange(ciphertextLengthOffset..<(ciphertextLengthOffset + 4), with: [255, 255, 255, 255])
        assertError(.sizeLimitExceeded) { _ = try RecordCipher.open(hugeLength, expectedContext: context, epochKey: key) }
        var badUTF8 = sealed
        badUTF8[RecordCipher.magic.count + 8 + RecordCipher.suite.utf8.count + 4] = 255
        assertError(.malformedEnvelope) { _ = try RecordCipher.open(badUTF8, expectedContext: context, epochKey: key) }
        for length in 0..<sealed.count {
            XCTAssertThrowsError(try RecordCipher.open(Data(sealed.prefix(length)), expectedContext: context, epochKey: key))
        }
        assertError(.malformedEnvelope) { _ = try RecordCipher.open(sealed + Data([0]), expectedContext: context, epochKey: key) }
        assertError(.sizeLimitExceeded) {
            _ = try RecordCipher.open(Data(repeating: 0, count: POCLimits.recordEnvelopeBytes + 1), expectedContext: context, epochKey: key)
        }
    }

    func testContextAndPlaintextBounds() throws {
        assertError(.invalidContext) { _ = try context(conversation: "") }
        assertError(.invalidContext) { _ = try context(sender: String(repeating: "😀", count: 129)) }
        assertError(.invalidContext) { _ = try context(epoch: 0) }
        assertError(.invalidContext) { _ = try context(revision: 0) }
        assertError(.sizeLimitExceeded) {
            _ = try RecordCipher.seal(Data(repeating: 0, count: POCLimits.recordPlaintextBytes + 1), context: context(), epochKey: key)
        }
    }

    func testDurableExactByteRetryRandomNoncesRevisionConflictAndRollback() throws {
        let context = try context()
        let plaintext = Data("retry".utf8)
        let sealedOnce = try RecordCipher.seal(plaintext, context: context, epochKey: key)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mines-e2ee-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("outbox.bin")
        try sealedOnce.write(to: file, options: .atomic)
        var guardState = RecordReplayGuard()
        for _ in 0..<3 {
            let retry = try Data(contentsOf: file)
            XCTAssertEqual(retry, sealedOnce)
            XCTAssertEqual(try guardState.openAndAccept(retry, expectedContext: context, epochKey: key), plaintext)
        }
        let resealed = try RecordCipher.seal(plaintext, context: context, epochKey: key)
        XCTAssertNotEqual(try RecordCipher.decode(resealed).box.nonce.withUnsafeBytes { Data($0) },
                          try RecordCipher.decode(sealedOnce).box.nonce.withUnsafeBytes { Data($0) })
        assertError(.revisionConflict) { _ = try guardState.openAndAccept(resealed, expectedContext: context, epochKey: key) }
        let next = try self.context(revision: 2)
        var corrupt = try RecordCipher.seal(Data("edit".utf8), context: next, epochKey: key)
        corrupt[corrupt.count - 1] ^= 1
        assertError(.authenticationFailed) { _ = try guardState.openAndAccept(corrupt, expectedContext: next, epochKey: key) }
        // Authentication failure must not consume the newer revision.
        _ = try guardState.openAndAccept(sealedOnce, expectedContext: context, epochKey: key)
        let revised = try RecordCipher.seal(Data("edit".utf8), context: next, epochKey: key)
        _ = try guardState.openAndAccept(revised, expectedContext: next, epochKey: key)
        assertError(.staleRevision) { _ = try guardState.openAndAccept(sealedOnce, expectedContext: context, epochKey: key) }
    }
}

func recordEnvelope(context: RecordContext, box: ChaChaPoly.SealedBox) -> Data {
    var writer = BinaryWriter()
    writer.bytes(RecordCipher.magic)
    writer.uint32(1)
    writer.string(RecordCipher.suite)
    context.appendFields(to: &writer)
    writer.bytes(Data(box.nonce))
    writer.lengthPrefixed(box.ciphertext)
    writer.bytes(box.tag)
    return writer.data
}

extension Data {
    init(hex: String) {
        self.init()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
    }
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
