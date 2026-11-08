import CSQLite
import CryptoKit
import Darwin
import Foundation

public enum OutboxError: Error, Equatable, Sendable {
    case storageUnavailable
    case unsupportedSchema
    case corruptStore
    case closedStore
    case closedConversation
    case capacityExceeded
    case scopeMismatch
    case attachmentMismatch
    case invalidLimits
    case pendingChanged
}

/// Default POC limits retain 128 total ledger rows. Production explicitly separates at most
/// 128 pending rows from the compact immutable latest-revision/digest ledger (1M rows/256MiB
/// logical metadata). Default bounds remain 64MiB pending/24MiB per bundle; the explicit
/// production profile allows one original 200MiB video plus bounded queue headroom. No eviction.
public struct OutboxLimits: Sendable {
    /// Pending rows only; acknowledged rows count toward maximumLedgerRecords instead.
    public let maximumRecords: Int
    public let maximumLedgerRecords: Int
    public let maximumLedgerMetadataBytes: Int
    public let maximumConversations: Int
    public let maximumPendingBytes: Int
    public let maximumEntryBytes: Int

    public init(maximumRecords: Int = 128, maximumConversations: Int = 64,
                maximumPendingBytes: Int = 64 * 1024 * 1024,
                maximumEntryBytes: Int = 24 * 1024 * 1024,
                maximumLedgerRecords: Int = 128,
                maximumLedgerMetadataBytes: Int = 256 * 1024 * 1024) throws {
        guard (1...128).contains(maximumRecords), (1...64).contains(maximumConversations),
              (1...1_000_000).contains(maximumLedgerRecords), maximumLedgerRecords >= maximumRecords,
              (1...(256 * 1024 * 1024)).contains(maximumLedgerMetadataBytes),
              (1...(264 * 1024 * 1024)).contains(maximumPendingBytes),
              (1...(204 * 1024 * 1024)).contains(maximumEntryBytes) else { throw OutboxError.invalidLimits }
        self.maximumRecords = maximumRecords; self.maximumLedgerRecords = maximumLedgerRecords
        self.maximumLedgerMetadataBytes = maximumLedgerMetadataBytes
        self.maximumConversations = maximumConversations
        self.maximumPendingBytes = maximumPendingBytes; self.maximumEntryBytes = maximumEntryBytes
    }

    /// Explicit app profile. Capacity exhaustion is an error; never prune acknowledged digests
    /// or conversation tombstones to manufacture room. This is not a physical disk-size bound.
    public static let production = OutboxLimits(productionDefaults: ())
    private init(productionDefaults: Void) {
        maximumRecords = 128; maximumLedgerRecords = 1_000_000
        maximumLedgerMetadataBytes = 256 * 1024 * 1024; maximumConversations = 64
        maximumPendingBytes = 264 * 1024 * 1024; maximumEntryBytes = 204 * 1024 * 1024
    }
}

public struct OutboxScope: Equatable, Sendable {
    public let accountID: String
    public let conversationID: String
    public let keyEpoch: UInt32
    public init(accountID: String, conversationID: String, keyEpoch: UInt32) throws {
        try validateIdentifier(accountID)
        try validateIdentifier(conversationID)
        guard keyEpoch > 0 else { throw E2EEError.invalidContext }
        self.accountID = accountID
        self.conversationID = conversationID
        self.keyEpoch = keyEpoch
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        Data(lhs.accountID.utf8) == Data(rhs.accountID.utf8)
            && Data(lhs.conversationID.utf8) == Data(rhs.conversationID.utf8) && lhs.keyEpoch == rhs.keyEpoch
    }
}

public struct OutboxAttachment: Equatable, Sendable {
    public let attachmentID: String
    public let bytes: Data
    public init(attachmentID: String, bytes: Data) throws {
        try validateIdentifier(attachmentID)
        guard bytes.count <= POCLimits.attachmentEnvelopeBytes else { throw E2EEError.sizeLimitExceeded }
        self.attachmentID = attachmentID
        self.bytes = bytes
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        Data(lhs.attachmentID.utf8) == Data(rhs.attachmentID.utf8) && lhs.bytes == rhs.bytes
    }
}

/// A bounded candidate for one atomic batch. It contains routing and opaque ciphertext only.
public struct OutboxEnqueueRequest: Sendable {
    public let envelope: Data
    public let attachments: [OutboxAttachment]
    public let context: RecordContext
    public init(envelope: Data, attachments: [OutboxAttachment] = [], context: RecordContext) throws {
        guard envelope.count <= POCLimits.recordEnvelopeBytes, attachments.count <= POCLimits.attachmentsPerMessage else { throw E2EEError.sizeLimitExceeded }
        self.envelope = envelope; self.attachments = attachments; self.context = context
    }
}

/// Local matching receipt; not proof of remote delivery and never a network authentication token.
public struct OutboxAcknowledgement: Sendable, Equatable {
    public let scope: OutboxScope
    public let recordID: String
    public let revision: UInt64
    fileprivate let digest: Data
    fileprivate init(scope: OutboxScope, recordID: String, revision: UInt64, digest: Data) {
        self.scope = scope; self.recordID = recordID; self.revision = revision; self.digest = digest
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.scope == rhs.scope && Data(lhs.recordID.utf8) == Data(rhs.recordID.utf8)
            && lhs.revision == rhs.revision && lhs.digest == rhs.digest
    }
}

/// Local ledger state. Supersession records a discarded obsolete intent, never remote delivery.
public enum OutboxRecordState: Equatable, Sendable {
    case pending(revision: UInt64)
    case acknowledged(revision: UInt64)
    case superseded(revision: UInt64)
}

public struct PendingOutboxRecord: Sendable {
    public let context: RecordContext
    public let envelope: Data
    public let attachments: [OutboxAttachment]
    public let acknowledgement: OutboxAcknowledgement
}

/// Isolated local persistence only: no network, delivery claims, or account authorization.
/// Caller supplies trusted account/context/key and revalidates key readiness at transport time.
/// Enqueue and load authenticate all content with transient keys; only sealed bytes and bounded
/// routing/digest metadata reach SQLite. IDs are byte-exact and conversations may NEVER be reused.
/// Tombstones and latest revision/digest survive restart, but deleting/restoring the database can
/// roll back those local rules. File protection is not secure deletion or an at-rest database cipher.
/// Use a dedicated caller-owned directory; this API tightens its permissions. Filesystem ancestors
/// must be trusted. Logical capacity limits do not bound SQLite's freed pages, journals, or WAL size.
public final class DurableCiphertextOutbox: @unchecked Sendable {
    public let limits: OutboxLimits
    private let lock = NSLock()
    private var database: OpaquePointer?
    // SQLITE_LIMIT_LENGTH also bounds a complete encoded row. maximumEntryBytes
    // includes the message envelope and packed attachment bytes; leave bounded room
    // for identifiers, digest, revision and SQLite record-header overhead.
    private static let maximumStoredBlob = 204 * 1024 * 1024
    private static let maximumAdmission: Int64 = 9_007_199_254_740_991
    private static let counterSQL = "CREATE TABLE admission_counter(id INTEGER PRIMARY KEY CHECK(id=1),next_sequence INTEGER NOT NULL CHECK(next_sequence BETWEEN 1 AND 9007199254740992))"
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let conversationsSQL = "CREATE TABLE conversations(account BLOB NOT NULL,conversation BLOB NOT NULL,closed INTEGER NOT NULL CHECK(closed IN(0,1)),PRIMARY KEY(account,conversation)) WITHOUT ROWID"
    private static let recordsSQL = """
        CREATE TABLE records(account BLOB NOT NULL,conversation BLOB NOT NULL,epoch INTEGER NOT NULL,
        record BLOB NOT NULL,admission INTEGER NOT NULL UNIQUE CHECK(admission BETWEEN 1 AND 9007199254740991),revision BLOB NOT NULL CHECK(length(revision)=8),digest BLOB NOT NULL CHECK(length(digest)=32),
        envelope BLOB,attachments BLOB,state INTEGER NOT NULL CHECK(state IN(0,1,2)),
        CHECK((envelope IS NULL)=(attachments IS NULL)),CHECK((state=0)=(envelope IS NOT NULL)),
        PRIMARY KEY(account,conversation,epoch,record),
        FOREIGN KEY(account,conversation) REFERENCES conversations(account,conversation)) WITHOUT ROWID
        """

    public init(directory: URL, limits: OutboxLimits? = nil) throws {
        self.limits = try limits ?? OutboxLimits()
        let file = try Self.prepareDirectory(directory)
        var connection: OpaquePointer?
        guard sqlite3_open_v2(file.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let connection else {
            if let connection { sqlite3_close(connection) }
            throw OutboxError.storageUnavailable
        }
        database = connection
        do {
            sqlite3_limit(connection, SQLITE_LIMIT_LENGTH, Int32(Self.maximumStoredBlob + 4096))
            sqlite3_busy_timeout(connection, 5000)
            try initializeSchema()
            try execute("PRAGMA foreign_keys=ON")
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA secure_delete=ON")
            try execute("PRAGMA wal_autocheckpoint=100")
            try enforceCapacity()
        } catch {
            sqlite3_close(connection)
            database = nil
            throw error
        }
    }

    deinit { if let database { sqlite3_close(database) } }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        if let database { sqlite3_close(database) }
        database = nil
    }

    /// Persist once before any send. Exact duplicates are idempotent, including after acknowledgement;
    /// they do not become pending again. Different ciphertext at the same revision always conflicts.
    /// A newer revision atomically replaces the prior pending revision; older ones fail closed.
    /// First admission order survives retries, edits and acknowledgements; it is local, not a
    /// remote conversation ordering claim. Batch input order determines new admissions.
    @discardableResult
    public func enqueue(envelope: Data, attachments: [OutboxAttachment] = [], context: RecordContext,
                        scope: OutboxScope, epochKey: SymmetricKey) throws -> OutboxAcknowledgement {
        let request = try OutboxEnqueueRequest(envelope: envelope, attachments: attachments, context: context)
        return try enqueueBatch([request], scope: scope, epochKey: epochKey)[0]
    }

    /// Persist and authenticate before returning the exact immutable source buffers for
    /// immediate delivery. Restart/retry still uses load; avoids reading a second whole
    /// ciphertext copy out of SQLite just after a successful fresh enqueue.
    public func enqueueForDelivery(envelope: Data, attachments: [OutboxAttachment] = [], context: RecordContext,
                                   scope: OutboxScope, epochKey: SymmetricKey) throws -> PendingOutboxRecord {
        let receipt = try enqueue(envelope: envelope, attachments: attachments, context: context, scope: scope, epochKey: epochKey)
        lock.lock(); defer { lock.unlock() }
        guard let current = try row(scope: scope, recordID: context.recordID, includePayloads: false),
              current.state == 0, current.revision == receipt.revision, current.digest == receipt.digest else {
            throw OutboxError.pendingChanged
        }
        // enqueue already authenticated every attachment. Reopen only the small message
        // to return the same canonical descriptor order as a subsequent durable load.
        let message = try MessageCipher.open(envelope, expectedContext: context, epochKey: epochKey)
        var ordered: [OutboxAttachment] = []
        for metadata in message.attachments {
            guard let attachment = attachments.first(where: { Data($0.attachmentID.utf8) == Data(metadata.attachmentID.utf8) }) else {
                throw OutboxError.attachmentMismatch
            }
            ordered.append(attachment)
            let previewID = PhotoPreviewCipher.attachmentID(for: metadata, context: context)
            if let preview = attachments.first(where: { $0.attachmentID == previewID }) { ordered.append(preview) }
            for rendition in PhotoRendition.allCases {
                let id = PhotoRenditionCipher.attachmentID(for: metadata, context: context, rendition: rendition)
                if let copy = attachments.first(where: { $0.attachmentID == id }) { ordered.append(copy) }
            }
        }
        return PendingOutboxRecord(context: context, envelope: envelope, attachments: ordered, acknowledgement: receipt)
    }

    /// Authenticates a maximum of 16 complete entries before one transaction, then admits every
    /// revision or none. Duplicate logical IDs within a batch fail closed; exact existing retries
    /// remain idempotent. Aggregate ciphertext is bounded by the pending-byte policy before SQL.
    @discardableResult
    public func enqueueBatch(_ entries: [OutboxEnqueueRequest], scope: OutboxScope,
                             epochKey: SymmetricKey) throws -> [OutboxAcknowledgement] {
        guard entries.count <= 16 else { throw E2EEError.sizeLimitExceeded }
        guard !entries.isEmpty else { return [] }
        var prepared: [(OutboxEnqueueRequest, Data, OutboxAcknowledgement)] = []
        var ids = Set<Data>(); var total = 0
        for entry in entries {
            try validateScope(scope, context: entry.context)
            guard ids.insert(Data(entry.context.recordID.utf8)).inserted else { throw E2EEError.revisionConflict }
            let packed = try validateAndPack(envelope: entry.envelope, attachments: entry.attachments, context: entry.context, epochKey: epochKey)
            total += entry.envelope.count + packed.count
            guard total <= limits.maximumPendingBytes else { throw OutboxError.capacityExceeded }
            let digest = bundleDigest(envelope: entry.envelope, packed: packed)
            let receipt = OutboxAcknowledgement(scope: scope, recordID: entry.context.recordID, revision: entry.context.revision, digest: digest)
            prepared.append((entry, packed, receipt))
        }
        lock.lock(); defer { lock.unlock() }
        try transaction {
            try admitConversation(scope)
            for (entry, packed, receipt) in prepared {
                let existing = try row(scope: scope, recordID: entry.context.recordID, includePayloads: false)
                if let existing {
                    guard entry.context.revision >= existing.revision else { throw E2EEError.staleRevision }
                    if entry.context.revision == existing.revision {
                        guard receipt.digest == existing.digest else { throw E2EEError.revisionConflict }
                        continue
                    }
                }
                let admission = try existing?.admission ?? reserveAdmission()
                try execute("""
                    INSERT INTO records(account, conversation, epoch, record, admission, revision, digest, envelope, attachments,state)
                    VALUES(?,?,?,?,?,?,?,?,?,0) ON CONFLICT(account,conversation,epoch,record) DO UPDATE SET
                    revision=excluded.revision,digest=excluded.digest,envelope=excluded.envelope,attachments=excluded.attachments,state=0
                    """, identity(scope, recordID: entry.context.recordID) + [.integer(admission), .blob(revisionBytes(entry.context.revision)), .blob(receipt.digest), .blob(entry.envelope), .blob(packed)])
            }
            try enforceCapacity()
        }
        return prepared.map { $0.2 }
    }

    /// Consult the permanent account/conversation tombstone before opening content.
    /// This read does not allocate a conversation slot or change the retry ledger.
    public func isConversationClosed(accountID: String, conversationID: String) throws -> Bool {
        let scope = try OutboxScope(accountID: accountID, conversationID: conversationID, keyEpoch: 1)
        lock.lock(); defer { lock.unlock() }
        return try conversationState(scope) == 1
    }

    /// IDs in first-admission order, independent of UUID spelling. Avoids loading a whole queue's
    /// ciphertext at once. A closed conversation returns [].
    public func pendingRecordIDs(scope: OutboxScope) throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        var ids: [String] = []
        try query("SELECT record,admission FROM records WHERE account=? AND conversation=? AND epoch=? AND envelope IS NOT NULL ORDER BY admission",
                  scopeValues(scope)) { statement in
            guard ids.count < limits.maximumRecords else { throw OutboxError.corruptStore }
            _ = try admissionValue(statement, column: 1)
            let bytes = try blob(statement, column: 0, maximum: POCLimits.identifierBytes)
            guard let id = String(data: bytes, encoding: .utf8), !id.isEmpty else { throw OutboxError.corruptStore }
            ids.append(id)
        }
        return ids
    }

    /// Distinguishes an acknowledged admission from a never-admitted ID without creating fresh
    /// ciphertext or requiring a network lookup for every new offline draft. No secrets returned.
    public func acknowledgedRevision(scope: OutboxScope, recordID: String) throws -> UInt64? {
        try validateIdentifier(recordID)
        lock.lock(); defer { lock.unlock() }
        guard let existing = try row(scope: scope, recordID: recordID, includePayloads: false), existing.state == 1 else { return nil }
        return existing.revision
    }

    public func recordState(scope: OutboxScope, recordID: String) throws -> OutboxRecordState? {
        try validateIdentifier(recordID)
        lock.lock(); defer { lock.unlock() }
        guard let row = try row(scope: scope, recordID: recordID, includePayloads: false) else { return nil }
        switch row.state {
        case 0: return .pending(revision: row.revision)
        case 1: return .acknowledged(revision: row.revision)
        case 2: return .superseded(revision: row.revision)
        default: throw OutboxError.corruptStore
        }
    }

    /// Conditional replacement of the exact still-pending edit. Caller first authenticates a
    /// definite newer server revision; this method itself makes no network/supersession claim.
    /// Fresh replacement ciphertext is authenticated before storage, and FIFO admission survives.
    @discardableResult
    public func supersedePendingEdit(matching receipt: OutboxAcknowledgement, with request: OutboxEnqueueRequest,
                                     epochKey: SymmetricKey) throws -> OutboxAcknowledgement {
        try validateScope(receipt.scope, context: request.context)
        guard receipt.revision > 1, request.context.revision > receipt.revision,
              Data(request.context.recordID.utf8) == Data(receipt.recordID.utf8), request.attachments.isEmpty else { throw OutboxError.scopeMismatch }
        let packed = try validateAndPack(envelope: request.envelope, attachments: [], context: request.context, epochKey: epochKey)
        let digest = bundleDigest(envelope: request.envelope, packed: packed)
        let replacement = OutboxAcknowledgement(scope: receipt.scope, recordID: receipt.recordID, revision: request.context.revision, digest: digest)
        lock.lock(); defer { lock.unlock() }
        try transaction {
            guard let current = try row(scope: receipt.scope, recordID: receipt.recordID),
                  current.state == 0, current.revision == receipt.revision, current.digest == receipt.digest,
                  let envelope = current.envelope, let attachments = current.attachments else { throw OutboxError.pendingChanged }
            guard attachments == Data([0,0,0,0]), bundleDigest(envelope: envelope, packed: attachments) == receipt.digest else { throw OutboxError.corruptStore }
            let oldContext = try RecordCipher.decode(envelope).context
            try validateScope(receipt.scope, context: oldContext)
            guard oldContext.revision == receipt.revision, Data(oldContext.recordID.utf8) == Data(receipt.recordID.utf8) else { throw OutboxError.corruptStore }
            _ = try MessageCipher.open(envelope, expectedContext: oldContext, epochKey: epochKey)
            try execute("UPDATE records SET revision=?,digest=?,envelope=?,attachments=?,state=0 WHERE account=? AND conversation=? AND epoch=? AND record=?",
                [.blob(revisionBytes(request.context.revision)), .blob(digest), .blob(request.envelope), .blob(packed)] + identity(receipt.scope, recordID: receipt.recordID))
            guard sqlite3_changes(try connection()) == 1 else { throw OutboxError.pendingChanged }
            try enforceCapacity()
        }
        return replacement
    }

    /// Retires an obsolete prepared attachment-free edit after a definite conflict, or a terminal server
    /// tombstone confirmed by the transport. This is local cancellation, never acknowledgement.
    /// Original revision/digest and FIFO position remain; an exact retry stays retired forever.
    @discardableResult
    public func retireSupersededEdit(matching receipt: OutboxAcknowledgement) throws -> Bool {
        guard receipt.revision > 1 else { throw OutboxError.scopeMismatch }
        lock.lock(); defer { lock.unlock() }
        return try transaction {
            guard let current = try row(scope: receipt.scope, recordID: receipt.recordID), current.state == 0,
                  current.revision == receipt.revision, current.digest == receipt.digest else { return false }
            guard let envelope = current.envelope, let attachments = current.attachments,
                  attachments == Data([0,0,0,0]), bundleDigest(envelope: envelope, packed: attachments) == receipt.digest else { throw OutboxError.corruptStore }
            try execute("UPDATE records SET envelope=NULL,attachments=NULL,state=2 WHERE account=? AND conversation=? AND epoch=? AND record=?",
                        identity(receipt.scope, recordID: receipt.recordID))
            return sqlite3_changes(try connection()) == 1
        }
    }

    /// Reauthenticates persisted message and blobs before returning ciphertext for a retry.
    public func load(scope: OutboxScope, recordID: String, epochKey: SymmetricKey) throws -> PendingOutboxRecord? {
        try validateIdentifier(recordID)
        lock.lock(); defer { lock.unlock() }
        guard let existing = try row(scope: scope, recordID: recordID), let envelope = existing.envelope,
              let packed = existing.attachments else { return nil }
        let context = try RecordCipher.decode(envelope).context
        try validateScope(scope, context: context)
        guard Data(context.recordID.utf8) == Data(recordID.utf8), context.revision == existing.revision,
              bundleDigest(envelope: envelope, packed: packed) == existing.digest else { throw OutboxError.corruptStore }
        let attachments = try unpack(packed)
        _ = try validateAttachments(envelope: envelope, attachments: attachments, context: context, epochKey: epochKey)
        return PendingOutboxRecord(context: context, envelope: envelope, attachments: attachments,
            acknowledgement: OutboxAcknowledgement(scope: scope, recordID: recordID, revision: context.revision, digest: existing.digest))
    }

    /// Only the exact currently pending receipt can clear ciphertext. Keeps revision+digest metadata
    /// so duplicate/conflict/rollback rules survive acknowledgements and store restarts.
    @discardableResult
    public func acknowledge(_ receipt: OutboxAcknowledgement) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        return try transaction {
            try execute("UPDATE records SET envelope=NULL,attachments=NULL,state=1 WHERE account=? AND conversation=? AND epoch=? AND record=? AND revision=? AND digest=? AND envelope IS NOT NULL",
                        identity(receipt.scope, recordID: receipt.recordID) + [.blob(revisionBytes(receipt.revision)), .blob(receipt.digest)])
            return sqlite3_changes(try connection()) == 1
        }
    }

    /// Atomically discards pending/history rows for every epoch and permanently closes this local
    /// account+conversation. Admission reserves a slot, so closing a known conversation cannot run
    /// out of tombstone capacity. Unknown scopes at capacity cannot enqueue in the first place.
    public func closeConversation(accountID: String, conversationID: String) throws {
        let scope = try OutboxScope(accountID: accountID, conversationID: conversationID, keyEpoch: 1)
        lock.lock(); defer { lock.unlock() }
        try transaction {
            let parameters: [Value] = [.blob(Data(accountID.utf8)), .blob(Data(conversationID.utf8))]
            if try conversationState(scope) == nil {
                guard try scalar("SELECT count(*) FROM conversations") < limits.maximumConversations else { throw OutboxError.capacityExceeded }
            }
            try execute("INSERT INTO conversations(account,conversation,closed) VALUES(?,?,1) ON CONFLICT(account,conversation) DO UPDATE SET closed=1", parameters)
            try execute("DELETE FROM records WHERE account=? AND conversation=?", parameters)
            try enforceCapacity()
        }
    }

    private func validateScope(_ scope: OutboxScope, context: RecordContext) throws {
        guard Data(scope.conversationID.utf8) == Data(context.conversationID.utf8), scope.keyEpoch == context.keyEpoch,
              Data(scope.accountID.utf8) == Data(context.senderID.utf8), context.kind == .message else { throw OutboxError.scopeMismatch }
    }

    private func validateAndPack(envelope: Data, attachments: [OutboxAttachment], context: RecordContext,
                                 epochKey: SymmetricKey) throws -> Data {
        let ordered = try validateAttachments(envelope: envelope, attachments: attachments, context: context, epochKey: epochKey)
        var writer = BinaryWriter()
        writer.data.reserveCapacity(4 + ordered.reduce(0) { $0 + 8 + $1.attachmentID.utf8.count + $1.bytes.count })
        writer.uint32(UInt32(ordered.count))
        for attachment in ordered {
            writer.string(attachment.attachmentID)
            writer.lengthPrefixed(attachment.bytes)
        }
        return writer.data
    }

    /// Authenticate without reconstructing a second whole packed bundle on reads.
    private func validateAttachments(envelope: Data, attachments: [OutboxAttachment], context: RecordContext,
                                     epochKey: SymmetricKey) throws -> [OutboxAttachment] {
        guard attachments.count <= POCLimits.attachmentsPerMessage, envelope.count <= POCLimits.recordEnvelopeBytes else { throw E2EEError.sizeLimitExceeded }
        var total = envelope.count + 4
        for attachment in attachments {
            total += 8 + attachment.attachmentID.utf8.count + attachment.bytes.count
            guard total <= limits.maximumEntryBytes else { throw OutboxError.capacityExceeded }
        }
        guard total <= limits.maximumEntryBytes else { throw OutboxError.capacityExceeded }
        let message = try MessageCipher.open(envelope, expectedContext: context, epochKey: epochKey)
        // Canonical order comes from private message descriptors, never a dictionary.
        var ordered: [OutboxAttachment] = []
        for metadata in message.attachments {
            let matches = attachments.filter { Data($0.attachmentID.utf8) == Data(metadata.attachmentID.utf8) }
            guard matches.count == 1, let attachment = matches.first else { throw OutboxError.attachmentMismatch }
            _ = try AttachmentCipher().open(attachment.bytes, privateMetadata: metadata, expectedContext: context)
            ordered.append(attachment)
            let previewID = PhotoPreviewCipher.attachmentID(for: metadata, context: context)
            let previews = attachments.filter { $0.attachmentID == previewID }
            guard previews.count <= 1 else { throw OutboxError.attachmentMismatch }
            if let preview = previews.first {
                _ = try PhotoPreviewCipher.open(preview.bytes, original: metadata, context: context)
                ordered.append(preview)
            }
            for rendition in PhotoRendition.allCases {
                let id = PhotoRenditionCipher.attachmentID(for: metadata, context: context, rendition: rendition)
                let copies = attachments.filter { $0.attachmentID == id }
                guard copies.count <= 1 else { throw OutboxError.attachmentMismatch }
                if let copy = copies.first {
                    _ = try PhotoRenditionCipher.open(copy.bytes, original: metadata, context: context, rendition: rendition)
                    ordered.append(copy)
                }
            }
        }
        guard ordered.count == attachments.count,
              Set(ordered.map { Data($0.attachmentID.utf8) }).count == ordered.count else { throw OutboxError.attachmentMismatch }
        return ordered
    }

    private func unpack(_ packed: Data) throws -> [OutboxAttachment] {
        guard packed.count <= limits.maximumEntryBytes else { throw OutboxError.corruptStore }
        var reader = BinaryReader(packed)
        let count = try reader.uint32()
        guard count <= POCLimits.attachmentsPerMessage else { throw OutboxError.corruptStore }
        var attachments: [OutboxAttachment] = []
        for _ in 0..<count {
            let id = try reader.string(maximum: POCLimits.identifierBytes)
            let bytes = try reader.lengthPrefixed(maximum: POCLimits.attachmentEnvelopeBytes)
            attachments.append(try OutboxAttachment(attachmentID: id, bytes: bytes))
        }
        guard reader.isAtEnd else { throw OutboxError.corruptStore }
        return attachments
    }

    private func bundleDigest(envelope: Data, packed: Data) -> Data {
        var hasher = SHA256()
        var prefix = BinaryWriter()
        prefix.bytes(Data("mines/poc/outbox/bundle/v1".utf8)); prefix.uint64(UInt64(envelope.count))
        hasher.update(data: prefix.data); hasher.update(data: envelope); hasher.update(data: packed)
        return Data(hasher.finalize())
    }

    private func revisionBytes(_ revision: UInt64) -> Data {
        var writer = BinaryWriter(); writer.uint64(revision); return writer.data
    }

    private struct Row {
        let state: Int
        let admission: Int64
        let revision: UInt64
        let digest: Data
        let envelope: Data?
        let attachments: Data?
    }
    private func row(scope: OutboxScope, recordID: String, includePayloads: Bool = true) throws -> Row? {
        var result: Row?
        // Ledger/status checks need lengths, not a copy of every pending ciphertext blob.
        let columns = "revision,digest,length(envelope),length(attachments),admission,state,typeof(envelope),typeof(attachments)" + (includePayloads ? ",envelope,attachments" : "")
        try query("SELECT \(columns) FROM records WHERE account=? AND conversation=? AND epoch=? AND record=?", identity(scope, recordID: recordID)) { statement in
            var reader = BinaryReader(try blob(statement, column: 0, maximum: 8, exact: 8))
            let revision = try reader.uint64()
            let admission = try admissionValue(statement, column: 4)
            guard revision > 0 else { throw OutboxError.corruptStore }
            let digest = try blob(statement, column: 1, maximum: 32, exact: 32)
            guard sqlite3_column_type(statement, 5) == SQLITE_INTEGER else { throw OutboxError.corruptStore }
            let state = Int(sqlite3_column_int64(statement, 5))
            guard (0...2).contains(state), (state == 0) == (sqlite3_column_type(statement, 2) != SQLITE_NULL) else { throw OutboxError.corruptStore }
            var envelope: Data?; var attachments: Data?
            if sqlite3_column_type(statement, 2) == SQLITE_NULL {
                guard sqlite3_column_type(statement, 3) == SQLITE_NULL else { throw OutboxError.corruptStore }
            } else {
                guard sqlite3_column_type(statement, 2) == SQLITE_INTEGER,
                      sqlite3_column_type(statement, 3) == SQLITE_INTEGER,
                      try text(statement, column: 6, maximum: 16) == "blob",
                      try text(statement, column: 7, maximum: 16) == "blob" else { throw OutboxError.corruptStore }
                let messageSize = sqlite3_column_int64(statement, 2)
                let attachmentSize = sqlite3_column_int64(statement, 3)
                // Check BOTH declared lengths before copying either untrusted blob.
                guard messageSize >= 0, messageSize <= POCLimits.recordEnvelopeBytes,
                      attachmentSize >= 0, attachmentSize <= limits.maximumEntryBytes,
                      messageSize + attachmentSize <= limits.maximumEntryBytes else { throw OutboxError.corruptStore }
                if includePayloads {
                    envelope = try blob(statement, column: 8, maximum: POCLimits.recordEnvelopeBytes)
                    attachments = try blob(statement, column: 9, maximum: limits.maximumEntryBytes)
                }
            }
            result = Row(state: state, admission: admission, revision: revision, digest: digest, envelope: envelope, attachments: attachments)
        }
        return result
    }

    private func conversationState(_ scope: OutboxScope) throws -> Int? {
        var state: Int?
        try query("SELECT closed FROM conversations WHERE account=? AND conversation=?", Array(scopeValues(scope).prefix(2))) { statement in
            guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER else { throw OutboxError.corruptStore }
            let value = sqlite3_column_int64(statement, 0)
            guard value == 0 || value == 1 else { throw OutboxError.corruptStore }
            state = Int(value)
        }
        return state
    }
    private func admitConversation(_ scope: OutboxScope) throws {
        if let state = try conversationState(scope) {
            guard state == 0 else { throw OutboxError.closedConversation }
            return
        }
        guard try scalar("SELECT count(*) FROM conversations") < limits.maximumConversations else { throw OutboxError.capacityExceeded }
        try execute("INSERT INTO conversations(account,conversation,closed) VALUES(?,?,0)", Array(scopeValues(scope).prefix(2)))
    }

    private func enforceCapacity() throws {
        guard try scalar("SELECT count(*) FROM records WHERE envelope IS NOT NULL") <= limits.maximumRecords,
              try scalar("SELECT count(*) FROM records") <= limits.maximumLedgerRecords,
              // Epoch/revision/admission are budgeted as 8 bytes each, digest as 32, state as 1.
              // The singleton counter has a fixed 16-byte logical budget (id + next sequence). Identifiers are
              // budgeted for every row plus their separately retained conversation scope.
              try scalar("SELECT coalesce(sum(length(account)+length(conversation)+length(record)+57),0) FROM records")
                + scalar("SELECT coalesce(sum(length(account)+length(conversation)+1),0) FROM conversations") + 16 <= limits.maximumLedgerMetadataBytes,
              try scalar("SELECT count(*) FROM conversations") <= limits.maximumConversations,
              try scalar("SELECT coalesce(sum(coalesce(length(envelope),0)+coalesce(length(attachments),0)),0) FROM records") <= limits.maximumPendingBytes else {
            throw OutboxError.capacityExceeded
        }
    }

    private func initializeSchema() throws {
        try transaction {
            let version = try scalar("PRAGMA user_version")
            let application = try scalar("PRAGMA application_id")
            if version == 0 {
                guard application == 0,
                      try scalar("SELECT count(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'") == 0 else { throw OutboxError.unsupportedSchema }
                try execute(Self.conversationsSQL)
                try execute(Self.recordsSQL)
                try execute(Self.counterSQL)
                try execute("INSERT INTO admission_counter(id,next_sequence) VALUES(1,1)")
                try execute("PRAGMA user_version=3")
                try execute("PRAGMA application_id=1296387889") // ASCII MEO1.
            } else if version != 3 || application != 1296387889 {
                // Unshipped v1/v2 prototypes lack admission order/explicit supersession state.
                // Reject unchanged, preserving pending bytes; never silently erase or recreate.
                throw OutboxError.unsupportedSchema
            }
            try validateSchema()
            _ = try nextAdmission()
        }
    }

    private func validateSchema() throws {
        var expected = ["conversations": Data(Self.conversationsSQL.utf8), "records": Data(Self.recordsSQL.utf8), "admission_counter": Data(Self.counterSQL.utf8)]
        try query("SELECT name,sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'") { statement in
            let name = try text(statement, column: 0, maximum: 256)
            let sql = try text(statement, column: 1, maximum: 4096)
            guard let definition = expected.removeValue(forKey: name), definition == Data(sql.utf8) else { throw OutboxError.unsupportedSchema }
        }
        guard expected.isEmpty else { throw OutboxError.unsupportedSchema }
    }

    private func admissionValue(_ statement: OpaquePointer, column: Int32) throws -> Int64 {
        guard sqlite3_column_type(statement, column) == SQLITE_INTEGER else { throw OutboxError.corruptStore }
        let value = sqlite3_column_int64(statement, column)
        guard value > 0, value <= Self.maximumAdmission else { throw OutboxError.corruptStore }
        return value
    }

    /// Call only within BEGIN IMMEDIATE: the singleton is shared by every connection/process.
    private func nextAdmission() throws -> Int64 {
        guard try scalar("SELECT count(*) FROM admission_counter") == 1 else { throw OutboxError.corruptStore }
        let next = Int64(try scalar("SELECT next_sequence FROM admission_counter WHERE id=1"))
        let largest = Int64(try scalar("SELECT coalesce(max(admission),0) FROM records"))
        guard next > largest, next <= Self.maximumAdmission + 1 else { throw OutboxError.corruptStore }
        return next
    }

    private func reserveAdmission() throws -> Int64 {
        let next = try nextAdmission()
        guard next <= Self.maximumAdmission else { throw OutboxError.capacityExceeded }
        try execute("UPDATE admission_counter SET next_sequence=? WHERE id=1", [.integer(next + 1)])
        guard sqlite3_changes(try connection()) == 1 else { throw OutboxError.corruptStore }
        return next
    }

    private enum Value { case blob(Data), integer(Int64) }
    private func scopeValues(_ scope: OutboxScope) -> [Value] {
        [.blob(Data(scope.accountID.utf8)), .blob(Data(scope.conversationID.utf8)), .integer(Int64(scope.keyEpoch))]
    }
    private func identity(_ scope: OutboxScope, recordID: String) -> [Value] { scopeValues(scope) + [.blob(Data(recordID.utf8))] }
    private func connection() throws -> OpaquePointer {
        guard let database else { throw OutboxError.closedStore }; return database
    }
    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let result = try body(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func prepareStatement(_ sql: String) throws -> OpaquePointer {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(try connection(), sql, -1, &prepared, nil) == SQLITE_OK, let prepared else { throw OutboxError.storageUnavailable }
        return prepared
    }
    private func statement(_ sql: String, _ parameters: [Value]) throws -> OpaquePointer {
        let prepared = try prepareStatement(sql)
        do {
            for (index, value) in parameters.enumerated() {
                let status: Int32
                switch value {
                case .blob(let data):
                    status = data.withUnsafeBytes { sqlite3_bind_blob(prepared, Int32(index + 1), $0.baseAddress, Int32(data.count), Self.transient) }
                case .integer(let value): status = sqlite3_bind_int64(prepared, Int32(index + 1), value)
                }
                guard status == SQLITE_OK else { throw OutboxError.storageUnavailable }
            }
            return prepared
        } catch { sqlite3_finalize(prepared); throw error }
    }
    private func execute(_ sql: String, _ parameters: [Value] = []) throws {
        let prepared = try prepareStatement(sql); defer { sqlite3_finalize(prepared) }
        // Nested borrows keep every Data pointer alive through sqlite3_step. In
        // particular, SQLite need not copy an entire attachment bundle at bind time.
        // Reset and clear bindings BEFORE each withUnsafeBytes scope ends, including
        // errors while binding a later parameter. No borrowed pointer escapes.
        func bindAndExecute(_ index: Int) throws {
            if index == parameters.count {
                defer { sqlite3_reset(prepared); sqlite3_clear_bindings(prepared) }
                var status = sqlite3_step(prepared)
                while status == SQLITE_ROW { status = sqlite3_step(prepared) }
                guard status == SQLITE_DONE else { throw OutboxError.storageUnavailable }
                return
            }
            switch parameters[index] {
            case .blob(let data):
                try data.withUnsafeBytes { bytes in
                    defer { sqlite3_reset(prepared); sqlite3_clear_bindings(prepared) }
                    guard sqlite3_bind_blob(prepared, Int32(index + 1), bytes.baseAddress, Int32(data.count), nil) == SQLITE_OK else {
                        throw OutboxError.storageUnavailable
                    }
                    try bindAndExecute(index + 1)
                }
            case .integer(let value):
                guard sqlite3_bind_int64(prepared, Int32(index + 1), value) == SQLITE_OK else { throw OutboxError.storageUnavailable }
                try bindAndExecute(index + 1)
            }
        }
        try bindAndExecute(0)
    }
    private func query(_ sql: String, _ parameters: [Value] = [], body: (OpaquePointer) throws -> Void) throws {
        let prepared = try statement(sql, parameters); defer { sqlite3_finalize(prepared) }
        var status = sqlite3_step(prepared)
        while status == SQLITE_ROW { try body(prepared); status = sqlite3_step(prepared) }
        guard status == SQLITE_DONE else { throw OutboxError.storageUnavailable }
    }
    private func scalar(_ sql: String) throws -> Int {
        var value: Int?
        try query(sql) { statement in
            guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER else { throw OutboxError.corruptStore }
            let result = sqlite3_column_int64(statement, 0)
            guard result >= 0, result <= Int64(Int.max) else { throw OutboxError.corruptStore }
            value = Int(result)
        }
        guard let value else { throw OutboxError.corruptStore }; return value
    }
    private func blobSize(_ statement: OpaquePointer, column: Int32, maximum: Int) throws -> Int {
        guard sqlite3_column_type(statement, column) == SQLITE_BLOB else { throw OutboxError.corruptStore }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count >= 0, count <= maximum else { throw OutboxError.corruptStore }
        return count
    }
    private func text(_ statement: OpaquePointer, column: Int32, maximum: Int) throws -> String {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT else { throw OutboxError.unsupportedSchema }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count <= maximum, let bytes = sqlite3_column_text(statement, column),
              let string = String(data: Data(bytes: bytes, count: count), encoding: .utf8) else { throw OutboxError.unsupportedSchema }
        return string
    }
    private func blob(_ statement: OpaquePointer, column: Int32, maximum: Int, exact: Int? = nil) throws -> Data {
        let count = try blobSize(statement, column: column, maximum: maximum)
        if let exact, count != exact { throw OutboxError.corruptStore }
        if count == 0 { return Data() }
        guard let bytes = sqlite3_column_blob(statement, column) else { throw OutboxError.corruptStore }
        return Data(bytes: bytes, count: count)
    }

    private static func prepareDirectory(_ directory: URL) throws -> URL {
        guard directory.isFileURL else { throw OutboxError.storageUnavailable }
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let attributes = try manager.attributesOfItem(atPath: directory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw OutboxError.storageUnavailable }
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            var protectedDirectory = directory
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try protectedDirectory.setResourceValues(values)
            #if os(iOS)
            try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
            #endif
            let file = directory.appendingPathComponent("ciphertext-outbox.sqlite")
            let descriptor = Darwin.open(file.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw OutboxError.storageUnavailable }
            defer { Darwin.close(descriptor) }
            var status = stat()
            guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
                  status.st_uid == geteuid(), fchmod(descriptor, 0o600) == 0 else { throw OutboxError.storageUnavailable }
            #if os(iOS)
            try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
            #endif
            return file
        } catch let error as OutboxError { throw error }
        catch { throw OutboxError.storageUnavailable }
    }
}
