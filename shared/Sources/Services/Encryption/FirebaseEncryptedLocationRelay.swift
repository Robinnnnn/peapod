@preconcurrency import FirebaseFirestore
import CoreFoundation
import Foundation
import MinesE2EE

/// Every write carries its original source lease. Reading a newer point/revision never
/// refreshes that authority. Explicit source mutations pin a before-state once, including
/// across Firestore transaction retries and uncertain acknowledgements.
@MainActor final class FirebaseEncryptedLocationRelay: EncryptedLocationRelay {
    let localDeviceID: String?
    private let database: Firestore
    private let session: SecureConversationSession
    private let gate = EncryptedLocationTransportGate()
    private let mutations = EncryptedLocationMutationQueue()
    private var invalidation: ServiceObservation?
    private var pendingMutation: SourceMutation?
    private var pendingAbandonment: (original: SourceMutation, rollback: Consent)?
    init(session: SecureConversationSession, database: Firestore = Firestore.firestore()) {
        self.session = session; self.database = database
        localDeviceID = EncryptedLocationDeviceIdentity.current
        invalidation = session.observeInvalidation { [gate] in gate.invalidate() }
    }
    /// Explicit identity injection is reserved for controlled synthetic fixtures/tests.
    init(session: SecureConversationSession, database: Firestore, localDeviceID: String?) {
        self.session = session; self.database = database
        self.localDeviceID = localDeviceID.flatMap { EncryptedLocationSourceLease.validDeviceID($0) ? $0 : nil }
        invalidation = session.observeInvalidation { [gate] in gate.invalidate() }
    }
    private var conversation: DocumentReference { database.collection("conversations").document(session.capsule.conversationID) }
    private var point: DocumentReference { conversation.collection("locations").document(session.capsule.localAccountID) }
    private var intent: DocumentReference { conversation.collection("locationSharing").document(session.capsule.localAccountID) }

    func readLatest() async throws -> EncryptedLocationRecord? {
        try session.requireActive()
        let snapshot = try await point.getDocument(source: .server)
        try session.requireActive()
        return snapshot.exists ? try Self.decode(id: snapshot.documentID, data: snapshot.data() ?? [:]) : nil
    }
    func recoverSourceLease() async throws -> EncryptedLocationSourceLease {
        try session.requireActive()
        guard let localDeviceID else { throw EncryptedLocationError.sourceOwnedByAnotherDevice }
        let snapshot = try await intent.getDocument(source: .server)
        try session.requireActive()
        guard snapshot.exists else { throw EncryptedLocationError.sharingDisabled }
        let consent = try Self.decodeConsent(id: snapshot.documentID, data: snapshot.data() ?? [:])
        guard consent.lease.deviceID == localDeviceID else { throw EncryptedLocationError.sourceOwnedByAnotherDevice }
        guard consent.enabled else { throw EncryptedLocationError.sharingDisabled }
        return consent.lease
    }
    func compareAndSet(_ record: EncryptedLocationRecord, expectedRevision: UInt64?) async throws -> EncryptedLocationWriteResult {
        try session.requireActive(accountID: record.userID)
        guard record.sourceLease.isValid, record.sourceDeviceID == localDeviceID,
              record.userID.utf8.elementsEqual(session.capsule.localAccountID.utf8),
              record.encryption.utf8.elementsEqual(session.capsule.suite.utf8), record.keyEpoch == session.capsule.keyEpoch,
              record.revision > 0, record.revision <= EncryptedLocationService.maximumRevision,
              !record.ciphertext.isEmpty, record.ciphertext.count <= 4096 else { throw EncryptedLocationError.invalidRecord }
        let point = point, intent = intent, gate = gate
        let code = try await transaction { transaction in
            guard gate.canWrite else { throw EncryptedLocationError.inactive }
            let sharing = try transaction.getDocument(intent)
            let oldSnapshot = try transaction.getDocument(point)
            guard sharing.exists else { return 2 }
            let consent = try Self.decodeConsent(id: sharing.documentID, data: sharing.data() ?? [:])
            guard consent.lease == record.sourceLease else { return 3 }
            guard consent.enabled else { return 2 }
            let old = oldSnapshot.exists ? try Self.decode(id: oldSnapshot.documentID, data: oldSnapshot.data() ?? [:]) : nil
            if old == record { return 0 } // Exact committed retry, including original source generation.
            guard old?.revision == expectedRevision, record.revision > (old?.revision ?? 0) else { return 1 }
            guard gate.canWrite else { throw EncryptedLocationError.inactive }
            transaction.setData(["userId": record.userID, "encryption": record.encryption,
                "keyEpoch": Int64(record.keyEpoch), "revision": Int64(record.revision), "ciphertext": record.ciphertext,
                "sourceDeviceId": record.sourceDeviceID, "sourceGeneration": Int64(record.sourceGeneration),
                "updatedAt": FieldValue.serverTimestamp()], forDocument: point)
            return 0
        }
        try session.requireActive()
        switch code {
        case 0: return .applied
        case 1: return .revisionConflict
        case 2: return .sharingDisabled
        case 3: return .sourceChanged
        default: throw EncryptedLocationError.invalidRecord
        }
    }
    func setSharingEnabled(_ enabled: Bool) async throws -> EncryptedLocationSourceLease? {
        try await mutateSource(enabled ? .enable : .disable)
    }
    func transferSharingSource() async throws -> EncryptedLocationSourceLease {
        guard let lease = try await mutateSource(.transfer) else { throw EncryptedLocationError.invalidRecord }
        return lease
    }
    private enum MutationKind: Sendable { case enable, disable, transfer }
    private struct Consent: Sendable, Equatable {
        let lease: EncryptedLocationSourceLease
        let enabled: Bool
        let mutationID: String
    }
    private struct SourceMutation: Sendable {
        let kind: MutationKind
        let expected: Consent?
        let target: Consent
    }
    private func mutateSource(_ kind: MutationKind) async throws -> EncryptedLocationSourceLease? {
        try session.requireActive()
        if kind != .disable, localDeviceID == nil { throw EncryptedLocationError.sourceOwnedByAnotherDevice }
        var result: EncryptedLocationSourceLease?
        try await mutations.perform { [self] in
            try session.requireActive()
            let mutation: SourceMutation
            if let pendingMutation, pendingMutation.kind == kind { mutation = pendingMutation }
            else {
                let snapshot = try await intent.getDocument(source: .server)
                try session.requireActive()
                let old = snapshot.exists ? try Self.decodeConsent(id: snapshot.documentID, data: snapshot.data() ?? [:]) : nil
                if kind == .enable, let old, old.lease.deviceID != localDeviceID,
                   old.enabled || old.lease.deviceID != EncryptedLocationSourceLease.unclaimedDeviceID {
                    throw EncryptedLocationError.sourceOwnedByAnotherDevice
                }
                let high = old?.lease.generation ?? 0
                guard high < EncryptedLocationService.maximumRevision else { throw EncryptedLocationError.revisionExhausted }
                guard let device = kind == .disable ? (old?.lease.deviceID ?? EncryptedLocationSourceLease.unclaimedDeviceID) : localDeviceID else { throw EncryptedLocationError.invalidRecord }
                mutation = SourceMutation(kind: kind, expected: old, target: Consent(
                    lease: .init(deviceID: device, generation: high + 1), enabled: kind != .disable,
                    mutationID: UUID().uuidString.lowercased()))
                pendingMutation = mutation // Retain exact intent across an uncertain commit.
            }
            let point = point, intent = intent, uid = session.capsule.localAccountID, gate = gate
            let code = try await transaction { transaction in
                guard gate.canWrite else { throw EncryptedLocationError.inactive }
                let snapshot = try transaction.getDocument(intent)
                let current = snapshot.exists ? try Self.decodeConsent(id: snapshot.documentID, data: snapshot.data() ?? [:]) : nil
                if current == mutation.target { return 0 }
                // Never rebase an older enable/transfer/off after a competing mutation.
                guard current == mutation.expected else { return 1 }
                transaction.setData(Self.consentData(mutation.target, uid: uid), forDocument: intent)
                transaction.deleteDocument(point)
                return 0
            }
            try session.requireActive()
            pendingMutation = nil; pendingAbandonment = nil
            guard code == 0 else { throw EncryptedLocationError.sourceOwnedByAnotherDevice }
            result = mutation.target.enabled ? mutation.target.lease : nil
        }
        try session.requireActive()
        return result
    }
    func deleteLatest(sourceLease: EncryptedLocationSourceLease) async throws {
        try await endSource(sourceLease, disable: false)
    }
    func abandonSource(sourceLease: EncryptedLocationSourceLease) async throws {
        try await endSource(sourceLease, disable: true)
    }
    func abandonPendingSource() async throws {
        try session.requireActive()
        try await mutations.perform { [self] in
            guard let pendingMutation, pendingMutation.kind != .disable else { return }
            let rollback: Consent
            if let pendingAbandonment, pendingAbandonment.original.target == pendingMutation.target {
                rollback = pendingAbandonment.rollback
            } else {
                guard pendingMutation.target.lease.generation < EncryptedLocationService.maximumRevision else {
                    throw EncryptedLocationError.revisionExhausted
                }
                rollback = Consent(lease: .init(deviceID: pendingMutation.target.lease.deviceID,
                    generation: pendingMutation.target.lease.generation + 1), enabled: false,
                    mutationID: UUID().uuidString.lowercased())
                pendingAbandonment = (pendingMutation, rollback)
            }
            let point = point, intent = intent, uid = session.capsule.localAccountID, gate = gate
            let code = try await transaction { transaction in
                guard gate.canWrite else { throw EncryptedLocationError.inactive }
                let snapshot = try transaction.getDocument(intent)
                let current = snapshot.exists ? try Self.decodeConsent(id: snapshot.documentID, data: snapshot.data() ?? [:]) : nil
                if current == rollback { return 0 } // Exact rollback acknowledgement retry.
                guard current == pendingMutation.target else { return 1 }
                transaction.setData(Self.consentData(rollback, uid: uid), forDocument: intent)
                transaction.deleteDocument(point)
                return 0
            }
            try session.requireActive()
            // Mismatch is a safe no-op. An uncertain/noncommitted original target is
            // retained for exact explicit retry; it is never rebased onto the current source.
            if code == 0, self.pendingMutation?.target == pendingMutation.target {
                self.pendingMutation = nil; pendingAbandonment = nil
            }
        }
        try session.requireActive()
    }
    private func endSource(_ sourceLease: EncryptedLocationSourceLease, disable: Bool) async throws {
        try session.requireActive()
        guard sourceLease.isValid, sourceLease.deviceID == localDeviceID else { throw EncryptedLocationError.sourceOwnedByAnotherDevice }
        let point = point, intent = intent, uid = session.capsule.localAccountID, gate = gate
        let operationID = UUID().uuidString.lowercased()
        // A stale lifecycle stop must not remove a replacement phone's point, or a
        // newer session on this same phone. Generation change also fences an absent-point CAS.
        _ = try await transaction { transaction in
            guard gate.canWrite else { throw EncryptedLocationError.inactive }
            let snapshot = try transaction.getDocument(intent)
            guard snapshot.exists else { return 1 }
            let current = try Self.decodeConsent(id: snapshot.documentID, data: snapshot.data() ?? [:])
            guard current.enabled, current.lease == sourceLease else { return 1 }
            guard sourceLease.generation < EncryptedLocationService.maximumRevision else { throw EncryptedLocationError.revisionExhausted }
            let next = Consent(lease: .init(deviceID: sourceLease.deviceID, generation: sourceLease.generation + 1),
                               enabled: !disable, mutationID: operationID)
            transaction.setData(Self.consentData(next, uid: uid), forDocument: intent)
            transaction.deleteDocument(point)
            return 0
        }
        try session.requireActive()
    }
    private func transaction(_ body: @escaping @Sendable (Transaction) throws -> Int) async throws -> Int {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            database.runTransaction({ @Sendable transaction, errorPointer in
                do { return NSNumber(value: try body(transaction)) }
                catch { errorPointer?.pointee = error as NSError; return nil }
            }) { @Sendable result, error in
                if let error { continuation.resume(throwing: (error as? EncryptedLocationError) ?? .unavailable) }
                else if let number = result as? NSNumber { continuation.resume(returning: number.intValue) }
                else { continuation.resume(throwing: EncryptedLocationError.invalidRecord) }
            }
        }
    }
    nonisolated private static func consentData(_ consent: Consent, uid: String) -> [String: Any] {
        ["userId": uid, "isSharing": consent.enabled, "updatedAt": FieldValue.serverTimestamp(),
         "sourceDeviceId": consent.lease.deviceID, "sourceGeneration": Int64(consent.lease.generation), "sourceMutationId": consent.mutationID]
    }
    nonisolated private static func decodeConsent(id: String, data: [String: Any]) throws -> Consent {
        guard Set(data.keys) == Set(["userId", "isSharing", "updatedAt", "sourceDeviceId", "sourceGeneration", "sourceMutationId"]),
              data["userId"] as? String == id, let enabled = data["isSharing"] as? Bool,
              let device = data["sourceDeviceId"] as? String, let generation = integer(data["sourceGeneration"]),
              let mutation = data["sourceMutationId"] as? String, UUID(uuidString: mutation)?.uuidString.lowercased() == mutation else {
            throw EncryptedLocationError.invalidRecord
        }
        let lease = EncryptedLocationSourceLease(deviceID: device, generation: generation)
        guard lease.isValid else { throw EncryptedLocationError.invalidRecord }
        return Consent(lease: lease, enabled: enabled, mutationID: mutation)
    }

    func observe(_ onChange: @escaping @MainActor (Result<EncryptedLocationRelaySnapshot, EncryptedLocationError>) -> Void) -> ServiceObservation {
        do { try session.requireActive() } catch { onChange(.failure(.inactive)); return ServiceObservation() }
        let state = EncryptedLocationListenerState(session: session, onChange: onChange)
        let sharing = conversation.collection("locationSharing").limit(to: 3).addSnapshotListener { snapshot, error in
            Task { @MainActor in
                guard !state.cancelled else { return }
                do {
                    try state.session.requireActive()
                    guard error == nil, let snapshot, snapshot.documents.count <= 2 else { throw EncryptedLocationError.invalidRecord }
                    var users: [String] = [], leases: [String: EncryptedLocationSourceLease] = [:]
                    for document in snapshot.documents {
                        let consent = try Self.decodeConsent(id: document.documentID, data: document.data())
                        guard [state.session.capsule.creatorID, state.session.capsule.recipientID].contains(document.documentID) else { throw EncryptedLocationError.invalidRecord }
                        leases[document.documentID] = consent.lease
                        if consent.enabled { users.append(document.documentID) }
                    }
                    state.users = users; state.leases = leases; state.emit()
                } catch { state.fail() }
            }
        }
        let points = conversation.collection("locations").limit(to: 3).addSnapshotListener { snapshot, error in
            Task { @MainActor in
                guard !state.cancelled else { return }
                do {
                    try state.session.requireActive()
                    guard error == nil, let snapshot, snapshot.documents.count <= 2 else { throw EncryptedLocationError.invalidRecord }
                    state.records = try snapshot.documents.map { try Self.decode(id: $0.documentID, data: $0.data()) }; state.emit()
                } catch { state.fail() }
            }
        }
        return ServiceObservation { state.cancelled = true; sharing.remove(); points.remove() }
    }
    nonisolated static func decode(id: String, data: [String: Any]) throws -> EncryptedLocationRecord {
        guard Set(data.keys) == Set(["userId", "encryption", "keyEpoch", "revision", "ciphertext", "updatedAt", "sourceDeviceId", "sourceGeneration"]),
              let user = data["userId"] as? String, !user.isEmpty, user.utf8.count <= 256, user.utf8.elementsEqual(id.utf8),
              let suite = data["encryption"] as? String, suite == StoredConversationCapsule.contentSuite,
              let epoch = integer(data["keyEpoch"]), epoch > 0, epoch <= UInt64(UInt32.max),
              let revision = integer(data["revision"]), revision > 0, revision <= 9_007_199_254_740_991,
              let bytes = data["ciphertext"] as? Data, !bytes.isEmpty, bytes.count <= 4096,
              let device = data["sourceDeviceId"] as? String, let generation = integer(data["sourceGeneration"]),
              EncryptedLocationSourceLease(deviceID: device, generation: generation).isValid else { throw EncryptedLocationError.invalidRecord }
        return EncryptedLocationRecord(userID: user, encryption: suite, keyEpoch: UInt32(epoch), revision: revision,
                                       ciphertext: bytes, sourceDeviceID: device, sourceGeneration: generation)
    }
    nonisolated private static func integer(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0, number.doubleValue <= 9_007_199_254_740_991,
              floor(number.doubleValue) == number.doubleValue else { return nil }
        return UInt64(number.doubleValue)
    }
}
private final class EncryptedLocationTransportGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    var canWrite: Bool { lock.withLock { active } }
    func invalidate() { lock.withLock { active = false } }
}
@MainActor private final class EncryptedLocationListenerState {
    let session: SecureConversationSession
    let onChange: @MainActor (Result<EncryptedLocationRelaySnapshot, EncryptedLocationError>) -> Void
    var cancelled = false
    var users: [String] = []
    var leases: [String: EncryptedLocationSourceLease] = [:]
    var records: [EncryptedLocationRecord] = []
    init(session: SecureConversationSession, onChange: @escaping @MainActor (Result<EncryptedLocationRelaySnapshot, EncryptedLocationError>) -> Void) {
        self.session = session; self.onChange = onChange
    }
    func emit() { guard !cancelled else { return }; onChange(.success(.init(sharingUserIDs: users, records: records, sourceLeases: leases))) }
    func fail() { guard !cancelled else { return }; onChange(.failure(.invalidRecord)) }
}
@MainActor extension EncryptedLocationService {
    convenience init(session: SecureConversationSession, database: Firestore = Firestore.firestore(),
                     revisionStore: any EncryptedLocationRevisionStoring = EncryptedLocationRevisionFileStore()) {
        self.init(session: session, relay: FirebaseEncryptedLocationRelay(session: session, database: database), revisionStore: revisionStore)
    }
}
