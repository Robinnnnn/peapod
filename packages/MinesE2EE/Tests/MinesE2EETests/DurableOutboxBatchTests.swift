import CryptoKit
import Foundation
import XCTest
@testable import MinesE2EE

final class DurableOutboxBatchTests: XCTestCase {
    let key = SymmetricKey(data: Data(repeating: 0x49, count: 32))
    func directory() -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("mines-batch-outbox-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }; return path
    }
    func scope() throws -> OutboxScope { try OutboxScope(accountID: "alice", conversationID: "conversation", keyEpoch: 1) }
    func request(_ id: String, text: String = "private", revision: UInt64 = 1) throws -> OutboxEnqueueRequest {
        let context = try RecordContext(conversationID: "conversation", recordID: id, senderID: "alice", keyEpoch: 1, revision: revision)
        return try OutboxEnqueueRequest(envelope: MessageCipher.seal(MessagePayload(text: text), context: context, epochKey: key), context: context)
    }
    func testEntireBatchRollsBackCapacityAndCompetingConnectionCanRetry() throws {
        let path = directory()
        let limits = try OutboxLimits(maximumRecords: 1)
        let first = try DurableCiphertextOutbox(directory: path, limits: limits)
        let peer = try DurableCiphertextOutbox(directory: path, limits: limits)
        defer { first.close(); peer.close() }
        let entries = try [request("first"), request("second")]
        XCTAssertThrowsError(try first.enqueueBatch(entries, scope: scope(), epochKey: key)) { XCTAssertEqual($0 as? OutboxError, .capacityExceeded) }
        XCTAssertEqual(try peer.pendingRecordIDs(scope: scope()), [])
        let receipt = try peer.enqueueBatch([entries[0]], scope: scope(), epochKey: key)[0]
        XCTAssertThrowsError(try first.enqueueBatch(entries, scope: scope(), epochKey: key))
        XCTAssertEqual(try peer.pendingRecordIDs(scope: scope()), ["first"])
        XCTAssertTrue(try first.acknowledge(receipt))
        _ = try peer.enqueueBatch(entries, scope: scope(), epochKey: key)
        XCTAssertEqual(try first.pendingRecordIDs(scope: scope()), ["second"])
    }
    func testMalformedOrConflictingLaterEntryCannotPartiallyAdmitEarlierEntry() throws {
        let store = try DurableCiphertextOutbox(directory: directory(), limits: .production); defer { store.close() }
        let original = try request("existing")
        _ = try store.enqueueBatch([original], scope: scope(), epochKey: key)
        let fresh = try request("fresh")
        let divergent = try request("existing", text: "different")
        XCTAssertThrowsError(try store.enqueueBatch([fresh, divergent], scope: scope(), epochKey: key)) { XCTAssertEqual($0 as? E2EEError, .revisionConflict) }
        XCTAssertNil(try store.load(scope: scope(), recordID: "fresh", epochKey: key))
        XCTAssertEqual(try store.load(scope: scope(), recordID: "existing", epochKey: key)?.envelope, original.envelope)
        var corrupt = divergent.envelope; corrupt[corrupt.count - 1] ^= 1
        let malformed = try OutboxEnqueueRequest(envelope: corrupt, context: divergent.context)
        XCTAssertThrowsError(try store.enqueueBatch([fresh, malformed], scope: scope(), epochKey: key))
        XCTAssertNil(try store.load(scope: scope(), recordID: "fresh", epochKey: key))
        XCTAssertThrowsError(try store.enqueueBatch([fresh, fresh], scope: scope(), epochKey: key))
        XCTAssertThrowsError(try store.enqueueBatch(Array(repeating: fresh, count: 17), scope: scope(), epochKey: key))
    }
    func testBatchExactBytesAndAcknowledgedStateSurviveRestart() throws {
        let path = directory(); let store = try DurableCiphertextOutbox(directory: path, limits: .production)
        let entries = try [request("first"), request("second")]
        let receipts = try store.enqueueBatch(entries, scope: scope(), epochKey: key)
        XCTAssertTrue(try store.acknowledge(receipts[0])); store.close()
        let reopened = try DurableCiphertextOutbox(directory: path, limits: .production); defer { reopened.close() }
        XCTAssertEqual(try reopened.enqueueBatch(entries, scope: scope(), epochKey: key), receipts)
        XCTAssertNil(try reopened.load(scope: scope(), recordID: "first", epochKey: key))
        XCTAssertEqual(try reopened.load(scope: scope(), recordID: "second", epochKey: key)?.envelope, entries[1].envelope)
    }
}
