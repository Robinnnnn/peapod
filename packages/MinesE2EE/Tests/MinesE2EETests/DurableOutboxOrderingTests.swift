import CSQLite
import CryptoKit
import Foundation
import XCTest
@testable import MinesE2EE

final class DurableOutboxOrderingTests: XCTestCase {
    private let key = SymmetricKey(data: Data(repeating: 0x71, count: 32))
    private let noteID = "ffffffff-ffff-4fff-8fff-ffffffffffff"
    private let photoIDs = ["00000000-0000-4000-8000-000000000000", "88888888-8888-4888-8888-888888888888"]
    private func directory() -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("mines-ordered-outbox-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }; return path
    }
    private func scope() throws -> OutboxScope { try OutboxScope(accountID: "alice", conversationID: "conversation", keyEpoch: 1) }
    private func request(_ id: String, revision: UInt64 = 1, photo: Bool = false) throws -> OutboxEnqueueRequest {
        let context = try RecordContext(conversationID: "conversation", recordID: id, senderID: "alice", keyEpoch: 1, revision: revision)
        let attachment = try photo ? AttachmentCipher().seal(Data("private photo".utf8), context: context, attachmentID: UUID().uuidString, filename: "private.jpg", mediaType: "image/jpeg") : nil
        let payload = try MessagePayload(text: photo ? "" : "optional note", attachments: attachment.map { [$0.privateMetadata] } ?? [])
        let blobs = try attachment.map { [try OutboxAttachment(attachmentID: $0.privateMetadata.attachmentID, bytes: $0.bytes)] } ?? []
        return try OutboxEnqueueRequest(envelope: MessageCipher.seal(payload, context: context, epochKey: key), attachments: blobs, context: context)
    }

    func testNoteAndPhotosKeepInputOrderAcrossRestartExactRetryAndEdit() throws {
        let path = directory(); let store = try DurableCiphertextOutbox(directory: path, limits: .production)
        let entries = try [request(noteID), request(photoIDs[1], photo: true), request(photoIDs[0], photo: true)]
        let expected = entries.map(\.context.recordID)
        XCTAssertNotEqual(expected, expected.sorted())
        let receipts = try store.enqueueBatch(entries, scope: scope(), epochKey: key)
        XCTAssertEqual(try store.pendingRecordIDs(scope: scope()), expected)
        store.close()
        let reopened = try DurableCiphertextOutbox(directory: path, limits: .production); defer { reopened.close() }
        XCTAssertEqual(try reopened.enqueueBatch(entries.reversed(), scope: scope(), epochKey: key), receipts.reversed())
        XCTAssertEqual(try reopened.pendingRecordIDs(scope: scope()), expected)
        let edited = try request(noteID, revision: 2)
        _ = try reopened.enqueueBatch([edited], scope: scope(), epochKey: key)
        XCTAssertEqual(try reopened.pendingRecordIDs(scope: scope()), expected)
        XCTAssertEqual(try reopened.load(scope: scope(), recordID: noteID, epochKey: key)?.envelope, edited.envelope)
        XCTAssertFalse(try reopened.acknowledge(receipts[0]))
        XCTAssertTrue(try reopened.acknowledge(receipts[1]))
        XCTAssertEqual(try reopened.pendingRecordIDs(scope: scope()), [noteID, photoIDs[0]])
        XCTAssertEqual(try integer(path, "SELECT next_sequence FROM admission_counter"), 4)
    }

    func testConcurrentConnectionsAllocateUniqueContiguousBatchOrder() throws {
        let path = directory()
        let stores = try [DurableCiphertextOutbox(directory: path, limits: .production), DurableCiphertextOutbox(directory: path, limits: .production)]
        defer { stores.forEach { $0.close() } }
        let scope = try scope(); let key = self.key
        let batches = try [ [request("z-first"), request("a-second")], [request("y-first"), request("b-second")] ]
        let gate = DispatchSemaphore(value: 0); let group = DispatchGroup(); let failures = FailureBox()
        for index in 0..<2 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }; gate.wait()
                do { _ = try stores[index].enqueueBatch(batches[index], scope: scope, epochKey: key) }
                catch { failures.append(error) }
            }
        }
        gate.signal(); gate.signal()
        XCTAssertEqual(group.wait(timeout: .now() + 20), .success)
        XCTAssertTrue(failures.isEmpty)
        let ids = try stores[0].pendingRecordIDs(scope: scope)
        XCTAssertTrue(ids == ["z-first", "a-second", "y-first", "b-second"] || ids == ["y-first", "b-second", "z-first", "a-second"])
        XCTAssertEqual(try integer(path, "SELECT count(DISTINCT admission) FROM records"), 4)
        XCTAssertEqual(try integer(path, "SELECT next_sequence FROM admission_counter"), 5)
        stores.forEach { $0.close() }
        let restart = try DurableCiphertextOutbox(directory: path, limits: .production); defer { restart.close() }
        XCTAssertEqual(try restart.pendingRecordIDs(scope: scope), ids)
    }

    func testFailedBatchDoesNotConsumeSequenceAndClosedConversationNeverResetsIt() throws {
        let path = directory(); let store = try DurableCiphertextOutbox(directory: path, limits: OutboxLimits(maximumRecords: 1)); defer { store.close() }
        let entries = try [request("z-first"), request("a-second")]
        XCTAssertThrowsError(try store.enqueueBatch(entries, scope: scope(), epochKey: key))
        XCTAssertEqual(try integer(path, "SELECT next_sequence FROM admission_counter"), 1)
        _ = try store.enqueueBatch([entries[0]], scope: scope(), epochKey: key)
        try store.closeConversation(accountID: "alice", conversationID: "conversation")
        XCTAssertEqual(try integer(path, "SELECT next_sequence FROM admission_counter"), 2)
        let otherScope = try OutboxScope(accountID: "alice", conversationID: "new-conversation", keyEpoch: 1)
        let context = try RecordContext(conversationID: otherScope.conversationID, recordID: "new", senderID: "alice", keyEpoch: 1, revision: 1)
        _ = try store.enqueue(envelope: MessageCipher.seal(MessagePayload(text: "new"), context: context, epochKey: key), context: context, scope: otherScope, epochKey: key)
        XCTAssertEqual(try integer(path, "SELECT admission FROM records"), 2)
    }

    func testExhaustedCounterAllowsExactRetryAndEditButNoNewAdmissionAndRollbackIsCorrupt() throws {
        let path = directory(); let store = try DurableCiphertextOutbox(directory: path); let original = try request("existing")
        _ = try store.enqueueBatch([original], scope: scope(), epochKey: key)
        try sql(path, "UPDATE admission_counter SET next_sequence=9007199254740992")
        store.close()
        let restart = try DurableCiphertextOutbox(directory: path); defer { restart.close() }
        _ = try restart.enqueueBatch([original], scope: scope(), epochKey: key)
        _ = try restart.enqueueBatch([request("existing", revision: 2)], scope: scope(), epochKey: key)
        XCTAssertThrowsError(try restart.enqueueBatch([request("new")], scope: scope(), epochKey: key)) { XCTAssertEqual($0 as? OutboxError, .capacityExceeded) }
        XCTAssertEqual(try restart.pendingRecordIDs(scope: scope()), ["existing"])
        try sql(path, "UPDATE admission_counter SET next_sequence=1")
        XCTAssertThrowsError(try restart.enqueueBatch([request("new")], scope: scope(), epochKey: key)) { XCTAssertEqual($0 as? OutboxError, .corruptStore) }
        restart.close()
        XCTAssertThrowsError(try DurableCiphertextOutbox(directory: path)) { XCTAssertEqual($0 as? OutboxError, .corruptStore) }
    }

    func testUnshippedVersionOneIsRejectedWithoutErasingOrChangingPendingBytes() throws {
        let path = directory(); try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let original = try request("existing")
        try sql(path, """
            CREATE TABLE conversations(account BLOB NOT NULL,conversation BLOB NOT NULL,closed INTEGER NOT NULL CHECK(closed IN(0,1)),PRIMARY KEY(account,conversation)) WITHOUT ROWID;
            CREATE TABLE records(account BLOB NOT NULL,conversation BLOB NOT NULL,epoch INTEGER NOT NULL,record BLOB NOT NULL,revision BLOB NOT NULL CHECK(length(revision)=8),digest BLOB NOT NULL CHECK(length(digest)=32),envelope BLOB,attachments BLOB,CHECK((envelope IS NULL)=(attachments IS NULL)),PRIMARY KEY(account,conversation,epoch,record),FOREIGN KEY(account,conversation) REFERENCES conversations(account,conversation)) WITHOUT ROWID;
            PRAGMA application_id=1296387889; PRAGMA user_version=1;
            INSERT INTO conversations VALUES(X'616c696365',X'636f6e766572736174696f6e',0);
            """)
        try withDatabase(path) { database in
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(database, "INSERT INTO records VALUES(X'616c696365',X'636f6e766572736174696f6e',1,X'6578697374696e67',X'0000000000000001',zeroblob(32),?,X'00000000')", -1, &statement, nil), SQLITE_OK)
            let prepared = try XCTUnwrap(statement); defer { sqlite3_finalize(prepared) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            XCTAssertEqual(original.envelope.withUnsafeBytes { sqlite3_bind_blob(prepared, 1, $0.baseAddress, Int32($0.count), transient) }, SQLITE_OK)
            XCTAssertEqual(sqlite3_step(prepared), SQLITE_DONE)
        }
        let file = path.appendingPathComponent("ciphertext-outbox.sqlite"); let before = try Data(contentsOf: file)
        XCTAssertThrowsError(try DurableCiphertextOutbox(directory: path)) { XCTAssertEqual($0 as? OutboxError, .unsupportedSchema) }
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(try integer(path, "PRAGMA user_version"), 1)
        XCTAssertEqual(try integer(path, "SELECT count(*) FROM records WHERE envelope IS NOT NULL"), 1)
    }

    private final class FailureBox: @unchecked Sendable {
        private let lock = NSLock(); private var errors: [Error] = []
        func append(_ error: Error) { lock.lock(); defer { lock.unlock() }; errors.append(error) }
        var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return errors.isEmpty }
    }
    private func withDatabase<T>(_ path: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var connection: OpaquePointer?
        guard sqlite3_open(path.appendingPathComponent("ciphertext-outbox.sqlite").path, &connection) == SQLITE_OK, let connection else { throw OutboxError.storageUnavailable }
        defer { sqlite3_close(connection) }; return try body(connection)
    }
    private func sql(_ path: URL, _ statement: String) throws {
        try withDatabase(path) { database in
            guard sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK else { throw OutboxError.storageUnavailable }
        }
    }
    private func integer(_ path: URL, _ sql: String) throws -> Int64 {
        try withDatabase(path) { database in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw OutboxError.storageUnavailable }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) == SQLITE_INTEGER else { throw OutboxError.corruptStore }
            return sqlite3_column_int64(statement, 0)
        }
    }
}
