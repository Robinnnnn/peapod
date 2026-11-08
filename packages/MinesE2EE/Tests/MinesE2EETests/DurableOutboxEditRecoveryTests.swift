import CSQLite
import CryptoKit
import Foundation
import XCTest
@testable import MinesE2EE

final class DurableOutboxEditRecoveryTests: XCTestCase {
    private let key = SymmetricKey(data: Data(repeating: 0x39, count: 32))
    private func scope() throws -> OutboxScope { try OutboxScope(accountID: "alice", conversationID: "conversation", keyEpoch: 1) }
    private func request(_ id: String = "edit", revision: UInt64, text: String = "private intent") throws -> OutboxEnqueueRequest {
        let context = try RecordContext(conversationID: "conversation", recordID: id, senderID: "alice", keyEpoch: 1, revision: revision)
        return try OutboxEnqueueRequest(envelope: MessageCipher.seal(MessagePayload(text: text), context: context, epochKey: key), context: context)
    }
    private func directory() -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("mines-edit-outbox-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }; return path
    }
    func testConditionalReplacementKeepsFIFOAndRejectsCompetingConnectionAndStaleAcknowledgement() throws {
        let path = directory(); let first = try DurableCiphertextOutbox(directory: path); defer { first.close() }
        let peer = try DurableCiphertextOutbox(directory: path); defer { peer.close() }
        let initial = try request(revision: 2)
        let receipt = try first.enqueueBatch([initial, request("other", revision: 1)], scope: scope(), epochKey: key)[0]
        let latest = try request(revision: 4, text: "rebased desired body")
        let replacement = try peer.supersedePendingEdit(matching: receipt, with: latest, epochKey: key)
        XCTAssertEqual(try first.pendingRecordIDs(scope: scope()), ["edit", "other"])
        XCTAssertThrowsError(try first.supersedePendingEdit(matching: receipt, with: request(revision: 5), epochKey: key)) { XCTAssertEqual($0 as? OutboxError, .pendingChanged) }
        XCTAssertFalse(try first.acknowledge(receipt)); XCTAssertFalse(try first.retireSupersededEdit(matching: receipt))
        XCTAssertEqual(try first.load(scope: scope(), recordID: "edit", epochKey: key)?.envelope, latest.envelope)
        XCTAssertTrue(try first.acknowledge(replacement))
        XCTAssertEqual(try first.recordState(scope: scope(), recordID: "edit"), .acknowledged(revision: 4))
    }
    func testRetirementSurvivesRestartIsNotAcknowledgementAndCannotResealSameRevision() throws {
        let path = directory(); let first = try DurableCiphertextOutbox(directory: path)
        let initial = try request(revision: 2)
        let receipt = try first.enqueueBatch([initial], scope: scope(), epochKey: key)[0]
        XCTAssertTrue(try first.retireSupersededEdit(matching: receipt)); first.close()
        let restart = try DurableCiphertextOutbox(directory: path); defer { restart.close() }
        XCTAssertEqual(try restart.recordState(scope: scope(), recordID: "edit"), .superseded(revision: 2))
        XCTAssertNil(try restart.acknowledgedRevision(scope: scope(), recordID: "edit"))
        XCTAssertNil(try restart.load(scope: scope(), recordID: "edit", epochKey: key))
        XCTAssertEqual(try restart.enqueueBatch([initial], scope: scope(), epochKey: key), [receipt])
        XCTAssertTrue(try restart.pendingRecordIDs(scope: scope()).isEmpty)
        XCTAssertThrowsError(try restart.enqueueBatch([request(revision: 2)], scope: scope(), epochKey: key))
        let newer = try request(revision: 5)
        _ = try restart.enqueueBatch([newer], scope: scope(), epochKey: key)
        XCTAssertFalse(try restart.retireSupersededEdit(matching: receipt))
        XCTAssertFalse(try restart.acknowledge(receipt))
        XCTAssertEqual(try restart.load(scope: scope(), recordID: "edit", epochKey: key)?.envelope, newer.envelope)
    }
    func testInvalidReplacementAndCreateRetirementLeaveExactPendingBytesUnchanged() throws {
        let store = try DurableCiphertextOutbox(directory: directory()); defer { store.close() }
        let initial = try request(revision: 2); let receipt = try store.enqueueBatch([initial], scope: scope(), epochKey: key)[0]
        XCTAssertThrowsError(try store.supersedePendingEdit(matching: receipt, with: request(revision: 3), epochKey: SymmetricKey(size: .bits256)))
        XCTAssertThrowsError(try store.supersedePendingEdit(matching: receipt, with: request("foreign", revision: 3), epochKey: key))
        XCTAssertThrowsError(try store.supersedePendingEdit(matching: receipt, with: request(revision: 2), epochKey: key))
        XCTAssertEqual(try store.load(scope: scope(), recordID: "edit", epochKey: key)?.envelope, initial.envelope)
        let create = try store.enqueueBatch([request("create", revision: 1)], scope: scope(), epochKey: key)[0]
        XCTAssertThrowsError(try store.retireSupersededEdit(matching: create)) { XCTAssertEqual($0 as? OutboxError, .scopeMismatch) }
    }
    func testOldUnshippedVersionTwoFailsClosedWithoutMutatingPendingStore() throws {
        let path = directory(); let store = try DurableCiphertextOutbox(directory: path)
        _ = try store.enqueueBatch([request(revision: 2)], scope: scope(), epochKey: key); store.close()
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.appendingPathComponent("ciphertext-outbox.sqlite").path, &database), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, "PRAGMA user_version=2", nil, nil, nil), SQLITE_OK); sqlite3_close(database)
        let file = path.appendingPathComponent("ciphertext-outbox.sqlite"); let before = try Data(contentsOf: file)
        XCTAssertThrowsError(try DurableCiphertextOutbox(directory: path)) { XCTAssertEqual($0 as? OutboxError, .unsupportedSchema) }
        XCTAssertEqual(try Data(contentsOf: file), before)
    }
}
