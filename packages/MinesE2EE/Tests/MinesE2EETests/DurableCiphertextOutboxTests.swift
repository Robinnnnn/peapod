import CSQLite
import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import MinesE2EE

final class DurableCiphertextOutboxTests: XCTestCase {
    let key = SymmetricKey(data: Data(0..<32))

    func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mines-outbox-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
    func scope(account: String = "alice", conversation: String = "conversation", epoch: UInt32 = 1) throws -> OutboxScope {
        try OutboxScope(accountID: account, conversationID: conversation, keyEpoch: epoch)
    }
    func context(record: String = "message", revision: UInt64 = 1, scope: OutboxScope? = nil) throws -> RecordContext {
        let scope = try scope ?? self.scope()
        return try RecordContext(conversationID: scope.conversationID, recordID: record, senderID: scope.accountID,
                                 keyEpoch: scope.keyEpoch, revision: revision)
    }
    struct Fixture {
        let context: RecordContext
        let message: Data
        let attachments: [OutboxAttachment]
    }
    func fixture(context: RecordContext? = nil, text: String = "CANARY-private-message-94712",
                 attachmentCount: Int = 1) throws -> Fixture {
        let context = try context ?? self.context()
        let sealed = try (0..<attachmentCount).map { index in
            try AttachmentCipher().seal(Data("CANARY-private-file-38291-\(index)".utf8), context: context,
                attachmentID: "blob-\(index)", filename: "CANARY-private-filename-62983-\(index).m4a",
                mediaType: "CANARY-private-media-type-93872", voiceDurationMilliseconds: 1234)
        }
        let message = try MessageCipher.seal(MessagePayload(text: text, attachments: sealed.map(\.privateMetadata)), context: context, epochKey: key)
        return Fixture(context: context, message: message,
                       attachments: try sealed.enumerated().map { try OutboxAttachment(attachmentID: "blob-\($0.offset)", bytes: $0.element.bytes) })
    }
    @discardableResult
    func enqueue(_ fixture: Fixture, into store: DurableCiphertextOutbox, scope: OutboxScope? = nil) throws -> OutboxAcknowledgement {
        try store.enqueue(envelope: fixture.message, attachments: fixture.attachments, context: fixture.context,
                          scope: scope ?? self.scope(), epochKey: key)
    }

    func testEnqueueForDeliveryMatchesRestartedCanonicalBytesAndRejectsAcknowledgedRetry() throws {
        let directory = try directory()
        let fixture = try fixture(attachmentCount: 2)
        let store = try DurableCiphertextOutbox(directory: directory)
        let prepared = try store.enqueueForDelivery(envelope: fixture.message, attachments: fixture.attachments.reversed(),
            context: fixture.context, scope: scope(), epochKey: key)
        XCTAssertEqual(prepared.attachments, fixture.attachments)
        store.close()
        let restarted = try DurableCiphertextOutbox(directory: directory)
        defer { restarted.close() }
        let loaded = try XCTUnwrap(restarted.load(scope: scope(), recordID: fixture.context.recordID, epochKey: key))
        XCTAssertEqual(loaded.context, prepared.context)
        XCTAssertEqual(loaded.envelope, prepared.envelope)
        XCTAssertEqual(loaded.attachments, prepared.attachments)
        XCTAssertEqual(loaded.acknowledgement, prepared.acknowledgement)
        XCTAssertTrue(try restarted.acknowledge(loaded.acknowledgement))
        XCTAssertThrowsError(try restarted.enqueueForDelivery(envelope: fixture.message, attachments: fixture.attachments,
            context: fixture.context, scope: scope(), epochKey: key)) {
            XCTAssertEqual($0 as? OutboxError, .pendingChanged)
        }
    }

    func testProductionLedgerBeyond128AcknowledgementsAndPendingCapacityAcrossConnections() throws {
        let directory = try directory()
        let store = try DurableCiphertextOutbox(directory: directory, limits: .production)
        for index in 0..<129 {
            let value = try fixture(context: context(record: "ack-\(index)"), attachmentCount: 0)
            let receipt = try enqueue(value, into: store)
            XCTAssertTrue(try store.acknowledge(receipt))
            XCTAssertNil(try store.load(scope: scope(), recordID: "ack-\(index)", epochKey: key))
        }
        XCTAssertEqual(try store.acknowledgedRevision(scope: scope(), recordID: "ack-128"), 1)
        for index in 0..<128 {
            _ = try enqueue(fixture(context: context(record: "pending-\(index)"), attachmentCount: 0), into: store)
        }
        let peer = try DurableCiphertextOutbox(directory: directory, limits: .production)
        defer { peer.close() }
        let overflow = try fixture(context: context(record: "pending-overflow"), attachmentCount: 0)
        XCTAssertThrowsError(try enqueue(overflow, into: peer)) { XCTAssertEqual($0 as? OutboxError, .capacityExceeded) }
        XCTAssertNil(try peer.load(scope: scope(), recordID: overflow.context.recordID, epochKey: key))
        let pending = try XCTUnwrap(peer.load(scope: scope(), recordID: "pending-0", epochKey: key))
        XCTAssertTrue(try peer.acknowledge(pending.acknowledgement))
        _ = try enqueue(overflow, into: store)
        store.close()
        let restarted = try DurableCiphertextOutbox(directory: directory, limits: .production)
        defer { restarted.close() }
        XCTAssertEqual(try restarted.pendingRecordIDs(scope: scope()).count, 128)
        XCTAssertEqual(try restarted.acknowledgedRevision(scope: scope(), recordID: "ack-128"), 1)
        // All acknowledged payload columns are cleared, while compact identity/digest rows remain.
        XCTAssertEqual(try sqlInteger(directory, "SELECT count(*) FROM records WHERE envelope IS NULL AND attachments IS NULL"), 130)
        XCTAssertThrowsError(try DurableCiphertextOutbox(directory: directory)) // POC profile stays small.
    }

    func testUnknownCloseRespectsMetadataBudgetAndKnownScopeStillClosesAtCapacity() throws {
        let directory = try directory()
        let tinyLimits = try OutboxLimits(maximumLedgerMetadataBytes: 16)
        let tiny = try DurableCiphertextOutbox(directory: directory, limits: tinyLimits)
        XCTAssertThrowsError(try tiny.closeConversation(accountID: "alice", conversationID: "conversation")) {
            XCTAssertEqual($0 as? OutboxError, .capacityExceeded)
        }
        XCTAssertEqual(try sqlInteger(directory, "SELECT count(*) FROM conversations"), 0)
        tiny.close()
        let tinyRestart = try DurableCiphertextOutbox(directory: directory, limits: tinyLimits)
        tinyRestart.close()

        let otherDirectory = try self.directory()
        let value = try fixture(attachmentCount: 0)
        let routing = try scope()
        let exactBudget = routing.accountID.utf8.count + routing.conversationID.utf8.count + value.context.recordID.utf8.count + 57 + 16
            + routing.accountID.utf8.count + routing.conversationID.utf8.count + 1
        let limits = try OutboxLimits(maximumRecords: 1, maximumLedgerMetadataBytes: exactBudget)
        let store = try DurableCiphertextOutbox(directory: otherDirectory, limits: limits)
        defer { store.close() }
        _ = try enqueue(value, into: store)
        try store.closeConversation(accountID: routing.accountID, conversationID: routing.conversationID)
        XCTAssertEqual(try store.pendingRecordIDs(scope: routing), [])
        XCTAssertThrowsError(try enqueue(value, into: store)) { XCTAssertEqual($0 as? OutboxError, .closedConversation) }
        let reopen = try DurableCiphertextOutbox(directory: otherDirectory, limits: limits)
        reopen.close()
    }

    func testIndependentLedgerAndLogicalMetadataLimitsRollBackAdmission() throws {
        let directory = try directory()
        let limits = try OutboxLimits(maximumRecords: 1, maximumLedgerRecords: 2, maximumLedgerMetadataBytes: 256 * 1024 * 1024)
        let store = try DurableCiphertextOutbox(directory: directory, limits: limits)
        defer { store.close() }
        for index in 0..<2 {
            let receipt = try enqueue(fixture(context: context(record: "record-\(index)"), attachmentCount: 0), into: store)
            XCTAssertTrue(try store.acknowledge(receipt))
        }
        XCTAssertThrowsError(try enqueue(fixture(context: context(record: "record-2"), attachmentCount: 0), into: store)) { XCTAssertEqual($0 as? OutboxError, .capacityExceeded) }
        XCTAssertEqual(try store.pendingRecordIDs(scope: scope()), [])
        let small = try DurableCiphertextOutbox(directory: self.directory(), limits: OutboxLimits(maximumRecords: 1, maximumLedgerMetadataBytes: 16))
        defer { small.close() }
        XCTAssertThrowsError(try enqueue(fixture(attachmentCount: 0), into: small)) { XCTAssertEqual($0 as? OutboxError, .capacityExceeded) }
        XCTAssertEqual(try small.pendingRecordIDs(scope: scope()), [])
        XCTAssertThrowsError(try OutboxLimits(maximumLedgerRecords: 1_000_001))
        XCTAssertThrowsError(try OutboxLimits(maximumLedgerMetadataBytes: 256 * 1024 * 1024 + 1))
    }

    private func sqlInteger(_ directory: URL, _ sql: String) throws -> Int {
        var database: OpaquePointer?
        guard sqlite3_open(directory.appendingPathComponent("ciphertext-outbox.sqlite").path, &database) == SQLITE_OK, let database else { throw OutboxError.storageUnavailable }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw OutboxError.storageUnavailable }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw OutboxError.corruptStore }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func testAcknowledgedRevisionDistinguishesNewPendingAndAcknowledgedAcrossRestart() throws {
        let directory = try directory()
        let store = try DurableCiphertextOutbox(directory: directory)
        let value = try fixture(attachmentCount: 0)
        XCTAssertNil(try store.acknowledgedRevision(scope: scope(), recordID: value.context.recordID))
        let receipt = try enqueue(value, into: store)
        XCTAssertNil(try store.acknowledgedRevision(scope: scope(), recordID: value.context.recordID))
        XCTAssertTrue(try store.acknowledge(receipt))
        XCTAssertEqual(try store.acknowledgedRevision(scope: scope(), recordID: value.context.recordID), 1)
        XCTAssertNil(try store.acknowledgedRevision(scope: scope(account: "bob"), recordID: value.context.recordID))
        store.close()
        let reopened = try DurableCiphertextOutbox(directory: directory)
        defer { reopened.close() }
        XCTAssertEqual(try reopened.acknowledgedRevision(scope: scope(), recordID: value.context.recordID), 1)
        let edited = try fixture(context: context(revision: 2), attachmentCount: 0)
        _ = try enqueue(edited, into: reopened)
        XCTAssertNil(try reopened.acknowledgedRevision(scope: scope(), recordID: value.context.recordID))
        try reopened.closeConversation(accountID: "alice", conversationID: "conversation")
        XCTAssertNil(try reopened.acknowledgedRevision(scope: scope(), recordID: value.context.recordID))
    }

    func testExactBytesAndReceiptSurviveStoreRestartAndPrivateCanariesAbsent() throws {
        let directory = try directory()
        let store = try DurableCiphertextOutbox(directory: directory)
        let fixture = try fixture(attachmentCount: 2)
        let receipt = try enqueue(fixture, into: store)
        XCTAssertEqual(try enqueue(fixture, into: store), receipt)
        XCTAssertEqual(try store.pendingRecordIDs(scope: scope()), ["message"])
        let loaded = try XCTUnwrap(store.load(scope: scope(), recordID: "message", epochKey: key))
        XCTAssertEqual(loaded.envelope, fixture.message)
        XCTAssertEqual(loaded.attachments, fixture.attachments)
        XCTAssertEqual(loaded.acknowledgement, receipt)
        // Caller input order doesn't alter descriptor-ordered canonical packing.
        XCTAssertEqual(try store.enqueue(envelope: fixture.message, attachments: fixture.attachments.reversed(),
                                         context: fixture.context, scope: scope(), epochKey: key), receipt)
        let privatePayload = try MessageCipher.open(fixture.message, expectedContext: fixture.context, epochKey: key)
        let canaries = [Data(privatePayload.text.utf8), Data("CANARY-private-file-38291".utf8), key.withUnsafeBytes { Data($0) }]
            + privatePayload.attachments.flatMap { [Data($0.filename.utf8), Data($0.mediaType.utf8), $0.key] }
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let persisted = try Data(contentsOf: file)
            for canary in canaries { XCTAssertNil(persisted.range(of: canary), "Synthetic private canary leaked to SQLite files") }
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        store.close()
        let restarted = try DurableCiphertextOutbox(directory: directory)
        let retry = try XCTUnwrap(restarted.load(scope: scope(), recordID: "message", epochKey: key))
        XCTAssertEqual(retry.envelope, fixture.message)
        XCTAssertEqual(retry.attachments, fixture.attachments)
        XCTAssertEqual(retry.acknowledgement, receipt)
    }

    func testStaleAckCannotRemoveNewerRevisionAndHistorySurvivesAckRestart() throws {
        let directory = try directory()
        let store = try DurableCiphertextOutbox(directory: directory)
        let first = try fixture(attachmentCount: 0)
        let staleReceipt = try enqueue(first, into: store)
        let second = try fixture(context: context(revision: .max), text: "edited", attachmentCount: 0)
        let currentReceipt = try enqueue(second, into: store)
        XCTAssertFalse(try store.acknowledge(staleReceipt))
        XCTAssertEqual(try store.load(scope: scope(), recordID: "message", epochKey: key)?.envelope, second.message)
        XCTAssertTrue(try store.acknowledge(currentReceipt))
        XCTAssertFalse(try store.acknowledge(currentReceipt))
        store.close()
        let restarted = try DurableCiphertextOutbox(directory: directory)
        XCTAssertEqual(try enqueue(second, into: restarted), currentReceipt)
        XCTAssertNil(try restarted.load(scope: scope(), recordID: "message", epochKey: key))
        let divergent = try fixture(context: context(revision: .max), text: "divergent", attachmentCount: 0)
        XCTAssertThrowsError(try enqueue(divergent, into: restarted)) { XCTAssertEqual($0 as? E2EEError, .revisionConflict) }
        XCTAssertThrowsError(try enqueue(first, into: restarted)) { XCTAssertEqual($0 as? E2EEError, .staleRevision) }
    }

    func testAuthenticationAndScopeRejectInvalidEnqueueWithoutPartialRecords() throws {
        let store = try DurableCiphertextOutbox(directory: directory())
        let valid = try fixture(attachmentCount: 2)
        XCTAssertThrowsError(try store.enqueue(envelope: Data("arbitrary plaintext".utf8), context: valid.context, scope: scope(), epochKey: key))
        var tampered = valid.message; tampered[tampered.count - 1] ^= 1
        XCTAssertThrowsError(try store.enqueue(envelope: tampered, attachments: valid.attachments, context: valid.context, scope: scope(), epochKey: key))
        XCTAssertThrowsError(try store.enqueue(envelope: valid.message, attachments: valid.attachments, context: valid.context, scope: scope(), epochKey: SymmetricKey(size: .bits256)))
        XCTAssertThrowsError(try enqueue(valid, into: store, scope: scope(account: "bob"))) { XCTAssertEqual($0 as? OutboxError, .scopeMismatch) }
        XCTAssertThrowsError(try enqueue(valid, into: store, scope: scope(epoch: 2))) { XCTAssertEqual($0 as? OutboxError, .scopeMismatch) }
        XCTAssertThrowsError(try store.enqueue(envelope: valid.message, attachments: [valid.attachments[0]], context: valid.context, scope: scope(), epochKey: key))
        var badAttachment = valid.attachments[1].bytes; badAttachment[badAttachment.count - 1] ^= 1
        let invalid = try [valid.attachments[0], OutboxAttachment(attachmentID: "blob-1", bytes: badAttachment)]
        XCTAssertThrowsError(try store.enqueue(envelope: valid.message, attachments: invalid, context: valid.context, scope: scope(), epochKey: key))
        XCTAssertThrowsError(try store.enqueue(envelope: valid.message, attachments: [valid.attachments[0], valid.attachments[0]], context: valid.context, scope: scope(), epochKey: key))
        XCTAssertEqual(try store.pendingRecordIDs(scope: scope()), [])
        try enqueue(valid, into: store)
        XCTAssertThrowsError(try store.load(scope: scope(), recordID: "message", epochKey: SymmetricKey(size: .bits256)))
        XCTAssertEqual(try store.load(scope: scope(), recordID: "message", epochKey: key)?.attachments, valid.attachments)
    }

    func testCapacityFailureRollsBackNewRecordAndRevisionReplacement() throws {
        let one = try fixture(attachmentCount: 0)
        let other = try fixture(context: context(record: "other"), attachmentCount: 0)
        let limits = try OutboxLimits(maximumRecords: 1, maximumPendingBytes: one.message.count + 4)
        let directory = try directory()
        let store = try DurableCiphertextOutbox(directory: directory, limits: limits)
        let receipt = try enqueue(one, into: store)
        XCTAssertThrowsError(try enqueue(other, into: store)) { XCTAssertEqual($0 as? OutboxError, .capacityExceeded) }
        let largerRevision = try fixture(context: context(revision: 2), text: String(repeating: "large", count: 100), attachmentCount: 0)
        XCTAssertThrowsError(try enqueue(largerRevision, into: store)) { XCTAssertEqual($0 as? OutboxError, .capacityExceeded) }
        store.close()
        let restarted = try DurableCiphertextOutbox(directory: directory, limits: limits)
        XCTAssertEqual(try restarted.load(scope: scope(), recordID: "message", epochKey: key)?.acknowledgement, receipt)
        XCTAssertNil(try restarted.load(scope: scope(), recordID: "other", epochKey: key))
        XCTAssertThrowsError(try DurableCiphertextOutbox(directory: directory, limits: OutboxLimits(maximumPendingBytes: 1)))
        XCTAssertThrowsError(try OutboxLimits(maximumRecords: 129))
        XCTAssertThrowsError(try OutboxLimits(maximumConversations: 65))
        XCTAssertThrowsError(try OutboxLimits(maximumEntryBytes: 204 * 1024 * 1024 + 1))
        XCTAssertThrowsError(try OutboxLimits(maximumPendingBytes: 264 * 1024 * 1024 + 1))
        XCTAssertEqual(try OutboxLimits().maximumEntryBytes, 24 * 1024 * 1024)
        XCTAssertEqual(try OutboxLimits().maximumPendingBytes, 64 * 1024 * 1024)
        XCTAssertEqual(OutboxLimits.production.maximumEntryBytes, 204 * 1024 * 1024)
        XCTAssertEqual(OutboxLimits.production.maximumPendingBytes, 264 * 1024 * 1024)
        _ = try OutboxLimits(maximumPendingBytes: 264 * 1024 * 1024, maximumEntryBytes: 204 * 1024 * 1024)
    }

    func testAccountEpochAndUnicodeByteIdentityIsolation() throws {
        let store = try DurableCiphertextOutbox(directory: directory())
        let scopes = try [scope(), scope(account: "bob"), scope(epoch: 2), scope(conversation: "caf\u{e9}"), scope(conversation: "cafe\u{301}"), scope(account: "caf\u{e9}"), scope(account: "cafe\u{301}")]
        XCTAssertNotEqual(scopes[3], scopes[4])
        for scope in scopes {
            let fixture = try fixture(context: context(scope: scope), text: scope.accountID + scope.conversationID + String(scope.keyEpoch), attachmentCount: 0)
            try enqueue(fixture, into: store, scope: scope)
            XCTAssertEqual(try store.load(scope: scope, recordID: "message", epochKey: key)?.envelope, fixture.message)
        }
        XCTAssertNil(try store.load(scope: scope(account: "unrelated"), recordID: "message", epochKey: key))
        let composed = try fixture(context: context(record: "caf\u{e9}"), attachmentCount: 0)
        let decomposed = try fixture(context: context(record: "cafe\u{301}"), attachmentCount: 0)
        try enqueue(composed, into: store); try enqueue(decomposed, into: store)
        XCTAssertEqual(try store.pendingRecordIDs(scope: scope()).count, 3)
        XCTAssertEqual(try store.load(scope: scope(), recordID: "caf\u{e9}", epochKey: key)?.envelope, composed.message)
        XCTAssertEqual(try store.load(scope: scope(), recordID: "cafe\u{301}", epochKey: key)?.envelope, decomposed.message)
    }

    func testCloseAllEpochsTombstonesAcrossConnectionsAndReservesCapacity() throws {
        let directory = try directory()
        let limits = try OutboxLimits(maximumConversations: 1)
        let first = try DurableCiphertextOutbox(directory: directory, limits: limits)
        let staleConnection = try DurableCiphertextOutbox(directory: directory, limits: limits)
        let old = try fixture(attachmentCount: 0)
        let newer = try fixture(context: context(scope: scope(epoch: 2)), attachmentCount: 0)
        try enqueue(old, into: first)
        try enqueue(newer, into: first, scope: scope(epoch: 2))
        let unknownScope = try scope(conversation: "unknown")
        let unknown = try fixture(context: context(scope: unknownScope), attachmentCount: 0)
        XCTAssertThrowsError(try enqueue(unknown, into: first, scope: unknownScope))
        XCTAssertFalse(try staleConnection.isConversationClosed(accountID: "alice", conversationID: "conversation"))
        try first.closeConversation(accountID: "alice", conversationID: "conversation")
        XCTAssertTrue(try staleConnection.isConversationClosed(accountID: "alice", conversationID: "conversation"))
        XCTAssertFalse(try staleConnection.isConversationClosed(accountID: "other", conversationID: "conversation"))
        XCTAssertEqual(try staleConnection.pendingRecordIDs(scope: scope()), [])
        XCTAssertNil(try staleConnection.load(scope: scope(epoch: 2), recordID: "message", epochKey: key))
        XCTAssertThrowsError(try enqueue(old, into: staleConnection)) { XCTAssertEqual($0 as? OutboxError, .closedConversation) }
        XCTAssertThrowsError(try enqueue(newer, into: staleConnection, scope: scope(epoch: 2))) { XCTAssertEqual($0 as? OutboxError, .closedConversation) }
        first.close(); staleConnection.close()
        let reopened = try DurableCiphertextOutbox(directory: directory, limits: limits)
        XCTAssertThrowsError(try enqueue(old, into: reopened)) { XCTAssertEqual($0 as? OutboxError, .closedConversation) }
        XCTAssertTrue(try reopened.isConversationClosed(accountID: "alice", conversationID: "conversation"))
        // Unknown close cannot reserve a slot at exhaustion; its enqueue remains fail-closed.
        XCTAssertThrowsError(try reopened.closeConversation(accountID: "alice", conversationID: "unknown"))
        XCTAssertThrowsError(try enqueue(unknown, into: reopened, scope: unknownScope))
        try reopened.closeConversation(accountID: "alice", conversationID: "conversation") // Idempotent at capacity.
    }

    func testIndependentConnectionsConcurrentlyEnqueueExactBytesAndRejectConflict() throws {
        let directory = try directory()
        let first = try DurableCiphertextOutbox(directory: directory)
        let second = try DurableCiphertextOutbox(directory: directory)
        let fixture = try fixture(attachmentCount: 0)
        let scope = try scope()
        let epochKey = key
        let errors = LockedErrors()
        DispatchQueue.concurrentPerform(iterations: 20) { index in
            do {
                _ = try (index.isMultiple(of: 2) ? first : second).enqueue(envelope: fixture.message,
                    context: fixture.context, scope: scope, epochKey: epochKey)
            } catch { errors.append(error) }
        }
        XCTAssertEqual(errors.count, 0)
        XCTAssertEqual(try first.pendingRecordIDs(scope: scope), ["message"])
        let divergent = try self.fixture(attachmentCount: 0)
        XCTAssertThrowsError(try enqueue(divergent, into: second)) { XCTAssertEqual($0 as? E2EEError, .revisionConflict) }
    }

    func testUnknownSchemaAndCorruptBoundedBlobsFailWithoutReset() throws {
        let directory = try directory()
        let store = try DurableCiphertextOutbox(directory: directory)
        try enqueue(fixture(attachmentCount: 0), into: store)
        // Corrupted blob exceeds message cap; reject before copying a Data buffer.
        try sql(directory, "UPDATE records SET envelope=zeroblob(70000)")
        XCTAssertThrowsError(try store.load(scope: scope(), recordID: "message", epochKey: key)) { XCTAssertEqual($0 as? OutboxError, .corruptStore) }
        XCTAssertThrowsError(try store.recordState(scope: scope(), recordID: "message")) { XCTAssertEqual($0 as? OutboxError, .corruptStore) }
        XCTAssertThrowsError(try store.acknowledgedRevision(scope: scope(), recordID: "message")) { XCTAssertEqual($0 as? OutboxError, .corruptStore) }
        // Metadata-only reads retain the same BLOB-type checks as full payload reads.
        try sql(directory, "UPDATE records SET envelope='invalid text'")
        XCTAssertThrowsError(try store.recordState(scope: scope(), recordID: "message")) { XCTAssertEqual($0 as? OutboxError, .corruptStore) }
        XCTAssertThrowsError(try store.load(scope: scope(), recordID: "message", epochKey: key)) { XCTAssertEqual($0 as? OutboxError, .corruptStore) }
        store.close()
        try sql(directory, "PRAGMA application_id=0")
        XCTAssertThrowsError(try DurableCiphertextOutbox(directory: directory)) { XCTAssertEqual($0 as? OutboxError, .unsupportedSchema) }
        try sql(directory, "PRAGMA application_id=1296387889; PRAGMA user_version=4")
        XCTAssertThrowsError(try DurableCiphertextOutbox(directory: directory)) { XCTAssertEqual($0 as? OutboxError, .unsupportedSchema) }
        try sql(directory, "PRAGMA user_version=3; CREATE TABLE foreign_table(data TEXT)")
        XCTAssertThrowsError(try DurableCiphertextOutbox(directory: directory)) { XCTAssertEqual($0 as? OutboxError, .unsupportedSchema) }
        let otherDirectory = try self.directory()
        try FileManager.default.createDirectory(at: otherDirectory, withIntermediateDirectories: true)
        try sql(otherDirectory, "CREATE TABLE unrelated(data TEXT)")
        XCTAssertThrowsError(try DurableCiphertextOutbox(directory: otherDirectory)) { XCTAssertEqual($0 as? OutboxError, .unsupportedSchema) }
    }

    #if os(macOS)
    func testActualChildProcessPersistenceAndUncommittedExitRollback() throws {
        let directory = try directory()
        try runChild(action: "enqueue", directory: directory)
        let store = try DurableCiphertextOutbox(directory: directory)
        let before = try XCTUnwrap(store.load(scope: scope(), recordID: "message", epochKey: key))
        try runChild(action: "interrupt", directory: directory)
        let after = try XCTUnwrap(store.load(scope: scope(), recordID: "message", epochKey: key))
        XCTAssertEqual(before.envelope, after.envelope)
        XCTAssertEqual(before.attachments, after.attachments)
        XCTAssertEqual(before.acknowledgement, after.acknowledgement)
        XCTAssertEqual(try MessageCipher.open(after.envelope, expectedContext: after.context, epochKey: key).text, "CANARY-private-message-94712")
    }

    func testSubprocessHelper() throws {
        guard let action = ProcessInfo.processInfo.environment["MINES_OUTBOX_TEST_ACTION"],
              let path = ProcessInfo.processInfo.environment["MINES_OUTBOX_TEST_DIRECTORY"] else { return }
        let directory = URL(fileURLWithPath: path)
        if action == "enqueue" {
            let store = try DurableCiphertextOutbox(directory: directory)
            try enqueue(fixture(), into: store)
        } else if action == "interrupt" {
            var database: OpaquePointer?
            guard sqlite3_open(directory.appendingPathComponent("ciphertext-outbox.sqlite").path, &database) == SQLITE_OK,
                  let database else { _exit(2) }
            guard sqlite3_exec(database, "BEGIN IMMEDIATE; UPDATE records SET envelope=NULL,attachments=NULL,state=1", nil, nil, nil) == SQLITE_OK,
                  sqlite3_changes(database) == 1 else { _exit(3) }
            // Intentional abrupt child exit with an open transaction; no COMMIT or connection cleanup.
            _exit(0)
        } else { XCTFail("Unknown synthetic child action") }
    }

    private func runChild(action: String, directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xctest", "-XCTest", "MinesE2EETests.DurableCiphertextOutboxTests/testSubprocessHelper", Bundle(for: Self.self).bundleURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["MINES_OUTBOX_TEST_ACTION"] = action
        environment["MINES_OUTBOX_TEST_DIRECTORY"] = directory.path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
    #endif

    private func sql(_ directory: URL, _ sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(directory.appendingPathComponent("ciphertext-outbox.sqlite").path, &database) == SQLITE_OK,
              let database else { throw OutboxError.storageUnavailable }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw OutboxError.storageUnavailable }
    }
}

private final class LockedErrors: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [Error] = []
    var count: Int { lock.lock(); defer { lock.unlock() }; return errors.count }
    func append(_ error: Error) { lock.lock(); defer { lock.unlock() }; errors.append(error) }
}
