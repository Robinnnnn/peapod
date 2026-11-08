import CryptoKit
import Foundation
import Darwin
import MinesE2EE

/// Safe failures contain no account identifiers, coordinates, ciphertext or Firebase diagnostics.
enum EncryptedLocationError: LocalizedError, Equatable {
    case inactive, invalidPoint, invalidRecord, sharingDisabled, sourceOwnedByAnotherDevice, busy, unavailable, revisionExhausted
    var errorDescription: String? {
        switch self {
        case .inactive: "Location sharing is no longer active."
        case .invalidPoint: "This location sample cannot be shared."
        case .invalidRecord: "The shared location could not be verified."
        case .sourceOwnedByAnotherDevice: "Location is shared from another iPhone. Change the source to use this iPhone."
        case .sharingDisabled: "Turn on location sharing before sending a location."
        case .busy: "A location update is already in progress."
        case .unavailable: "Location sharing could not finish. Try again."
        case .revisionExhausted: "Location sharing needs a new conversation."
        }
    }
}

struct EncryptedLocationRecord: Sendable, Equatable {
    let userID: String
    let encryption: String
    let keyEpoch: UInt32
    let revision: UInt64
    let ciphertext: Data
    let sourceDeviceID: String
    let sourceGeneration: UInt64
    var sourceLease: EncryptedLocationSourceLease { .init(deviceID: sourceDeviceID, generation: sourceGeneration) }
}
struct EncryptedLocationRelaySnapshot: Sendable {
    let sharingUserIDs: [String]
    let records: [EncryptedLocationRecord]
    var sourceLeases: [String: EncryptedLocationSourceLease] = [:]
}
enum EncryptedLocationWriteResult: Sendable {
    case applied, revisionConflict, sharingDisabled, sourceChanged
}

@MainActor protocol EncryptedLocationRelay: AnyObject {
    func readLatest() async throws -> EncryptedLocationRecord?
    /// A definite conflict permits a new revision. Any thrown/uncertain outcome must retry exact bytes.
    func compareAndSet(_ record: EncryptedLocationRecord, expectedRevision: UInt64?) async throws -> EncryptedLocationWriteResult
    /// False + deletion of the precise ciphertext document is one atomic commit.
    var localDeviceID: String? { get }
    /// Reads existing active ownership only; it never claims or transfers a source.
    func recoverSourceLease() async throws -> EncryptedLocationSourceLease
    func setSharingEnabled(_ enabled: Bool) async throws -> EncryptedLocationSourceLease?
    func transferSharingSource() async throws -> EncryptedLocationSourceLease
    func deleteLatest(sourceLease: EncryptedLocationSourceLease) async throws
    func abandonSource(sourceLease: EncryptedLocationSourceLease) async throws
    func abandonPendingSource() async throws
    func observe(_ onChange: @escaping @MainActor (Result<EncryptedLocationRelaySnapshot, EncryptedLocationError>) -> Void) -> ServiceObservation
}

@MainActor protocol EncryptedLocationKeySession: AnyObject {
    var capsule: SecureConversationRouting { get }
    func requireActive(conversationID: String?, accountID: String?) throws
    func makeContext(recordID: String, senderID: String?, kind: RecordKind, revision: UInt64) throws -> RecordContext
    func performKeyOperation<T: Sendable>(_ operation: @escaping @Sendable (SymmetricKey) throws -> T) async throws -> T
    func observeInvalidation(_ callback: @escaping () -> Void) -> ServiceObservation
}
extension SecureConversationSession: EncryptedLocationKeySession {}

@MainActor protocol EncryptedLocationRevisionStoring {
    func value(scope: KeyScope) throws -> UInt64
    func reserve(_ revision: UInt64, scope: KeyScope) throws
}

/// Non-secret atomic high-water marks, scoped by exact account/conversation/epoch. The common
/// directory + flock serializes local processes; Firestore CAS serializes different devices.
@MainActor final class EncryptedLocationRevisionFileStore: EncryptedLocationRevisionStoring {
    private let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mines-e2ee-location-revisions", isDirectory: true)
    }
    private func identity(_ scope: KeyScope) -> Data {
        var bytes = Data("mines/location/revision/v1\0".utf8)
        for identifier in [scope.accountID, scope.conversationID] {
            var length = UInt32(identifier.utf8.count).bigEndian
            withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }; bytes.append(contentsOf: identifier.utf8)
        }
        var epoch = scope.epoch.bigEndian; withUnsafeBytes(of: &epoch) { bytes.append(contentsOf: $0) }
        return Data(SHA256.hash(data: bytes))
    }
    func value(scope: KeyScope) throws -> UInt64 {
        try locked(scope) { url, id in try read(url, id: id) }
    }
    func reserve(_ revision: UInt64, scope: KeyScope) throws {
        guard revision > 0, revision <= EncryptedLocationService.maximumRevision else { throw EncryptedLocationError.revisionExhausted }
        try locked(scope) { url, id in
            var bytes = Data("MLRV".utf8); bytes.append(contentsOf: [0, 0, 0, 1]); bytes.append(id)
            var high = max(try read(url, id: id), revision).bigEndian
            withUnsafeBytes(of: &high) { bytes.append(contentsOf: $0) }
            var options: Data.WritingOptions = [.atomic]
            #if os(iOS)
            options.insert(.completeFileProtectionUntilFirstUserAuthentication)
            #endif
            do {
                try bytes.write(to: url, options: options)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
                guard fd >= 0 else { throw EncryptedLocationError.unavailable }
                defer { close(fd) }
                guard fsync(fd) == 0 else { throw EncryptedLocationError.unavailable }
                // Persist the atomic rename itself, not only the new file's contents.
                let directoryFD = open(directory.path, O_RDONLY | O_NOFOLLOW | O_DIRECTORY)
                guard directoryFD >= 0 else { throw EncryptedLocationError.unavailable }
                defer { close(directoryFD) }
                guard fsync(directoryFD) == 0 else { throw EncryptedLocationError.unavailable }
            } catch { throw EncryptedLocationError.unavailable }
        }
    }
    private func read(_ url: URL, id: Data) throws -> UInt64 {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        if fd < 0 { if errno == ENOENT { return 0 }; throw EncryptedLocationError.unavailable }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? file.close() }
        let bytes: Data
        do { bytes = try file.read(upToCount: 49) ?? Data() } catch { throw EncryptedLocationError.unavailable }
        guard bytes.count == 48, bytes.prefix(8) == Data([77, 76, 82, 86, 0, 0, 0, 1]),
              bytes.subdata(in: 8..<40) == id else { throw EncryptedLocationError.invalidRecord }
        let revision = bytes.suffix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard revision > 0, revision <= EncryptedLocationService.maximumRevision else { throw EncryptedLocationError.invalidRecord }
        return revision
    }
    private func locked<T>(_ scope: KeyScope, _ operation: (URL, Data) throws -> T) throws -> T {
        guard directory.isFileURL, directory.path.hasPrefix("/"), !scope.accountID.isEmpty, scope.accountID.utf8.count <= 256, scope.epoch > 0,
              !scope.conversationID.isEmpty, scope.conversationID.utf8.count <= 256 else { throw EncryptedLocationError.invalidRecord }
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { throw EncryptedLocationError.unavailable }
        let id = identity(scope), name = identity(scope).map { String(format: "%02x", $0) }.joined()
        let fd = open(directory.appendingPathComponent(name + ".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw EncryptedLocationError.unavailable }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw EncryptedLocationError.unavailable }
        defer { _ = flock(fd, LOCK_UN) }
        return try operation(directory.appendingPathComponent(name + ".bin"), id)
    }
}

/// Shared by native intent/stop operations: a newer off waits for an older in-flight enable,
/// including an uncertain failure, before committing its final atomic delete/false state.
@MainActor final class EncryptedLocationMutationQueue {
    private var tail: Task<Void, Error>?
    private var tailID: UUID?
    func perform(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        let previous = tail, id = UUID()
        let task = Task { @MainActor in
            if let previous { _ = try? await previous.value }
            try await operation()
        }
        tail = task; tailID = id
        defer { if tailID == id { tail = nil; tailID = nil } }
        try await task.value
    }
}

/// Single replaceable point per member. There is no location history or plaintext persistence.
@MainActor final class EncryptedLocationService {
    nonisolated static let maximumRevision: UInt64 = 9_007_199_254_740_991
    private let session: any EncryptedLocationKeySession
    private let relay: any EncryptedLocationRelay
    private let revisions: any EncryptedLocationRevisionStoring
    private let now: () -> Date
    private var valid = true
    private var writing = false
    private var sharingGeneration = UUID()
    private var explicitlyDisabled = false
    private var latestLocationSession: LiveLocationSession?
    private var latestLocationSessionClosed = false
    private var sourceLease: EncryptedLocationSourceLease?
    private var sessionSourceLease: EncryptedLocationSourceLease?
    private var cleanupSourceLease: EncryptedLocationSourceLease?
    private var pending: (record: EncryptedLocationRecord, expectedRevision: UInt64?)?
    private var invalidation: ServiceObservation?
    private var observers: [UUID: (Result<ConnectionLocationSnapshot, any Error>) -> Void] = [:]
    private var listener: ServiceObservation?
    private var decodeTask: Task<Void, Never>?
    private var queuedSnapshot: Result<EncryptedLocationRelaySnapshot, EncryptedLocationError>?
    private var decodeRunID: UUID?
    private var snapshotGeneration = UUID()
    private var lastSnapshot: ConnectionLocationSnapshot?
    private var observed: [Data: (lease: EncryptedLocationSourceLease, revision: UInt64, ciphertext: Data)] = [:]

    var localDeviceID: String? { relay.localDeviceID }
    var activeSourceGeneration: UInt64? { sourceLease?.generation }
    var requiresDeviceLocation: Bool { localDeviceID != nil }
    init(session: any EncryptedLocationKeySession, relay: any EncryptedLocationRelay,
         revisionStore: any EncryptedLocationRevisionStoring = EncryptedLocationRevisionFileStore(), now: @escaping () -> Date = Date.init) {
        self.session = session; self.relay = relay; revisions = revisionStore; self.now = now
        invalidation = session.observeInvalidation { [weak self] in self?.invalidate() }
    }
    func invalidate() {
        guard valid else { return }
        valid = false; sharingGeneration = UUID(); snapshotGeneration = UUID()
        sourceLease = nil; sessionSourceLease = nil; cleanupSourceLease = nil; pending = nil; queuedSnapshot = nil; decodeRunID = nil; decodeTask?.cancel(); decodeTask = nil; listener?.cancel(); listener = nil
        observed.removeAll(); lastSnapshot = nil
        let callbacks = Array(observers.values); observers.removeAll()
        callbacks.forEach { $0(.failure(EncryptedLocationError.inactive)) }
    }
    private func check(generation: UUID? = nil) throws {
        guard valid else { throw EncryptedLocationError.inactive }
        do { try session.requireActive(conversationID: session.capsule.conversationID, accountID: session.capsule.localAccountID) }
        catch { invalidate(); throw EncryptedLocationError.inactive }
        if let generation, generation != sharingGeneration { throw EncryptedLocationError.sharingDisabled }
    }

    func setSharingEnabled(_ enabled: Bool, conversationID: String, userID: String) async throws {
        try await changeSource(enabled: enabled, transfer: false, conversationID: conversationID, userID: userID)
    }
    func transferSharingSource(conversationID: String, userID: String) async throws {
        try await changeSource(enabled: true, transfer: true, conversationID: conversationID, userID: userID)
    }
    /// Roll back only this service's successful claim after denied/cancelled local setup.
    /// This is intentionally narrower than the explicit account-wide sharing-off action.
    func abandonSharingSource(conversationID: String, userID: String) async throws {
        try check()
        guard same(conversationID, session.capsule.conversationID), same(userID, session.capsule.localAccountID) else {
            throw EncryptedLocationError.invalidRecord
        }
        let captured = sourceLease ?? cleanupSourceLease
        if let captured { cleanupSourceLease = captured }
        sharingGeneration = UUID(); pending = nil; sourceLease = nil; explicitlyDisabled = true
        if latestLocationSession != nil { latestLocationSessionClosed = true }
        if let captured {
            try await relay.abandonSource(sourceLease: captured)
            try check()
            if cleanupSourceLease == captured { cleanupSourceLease = nil }
        }
        // A failed acknowledgement may have committed the relay's exact explicit
        // claim. Cleanup may revoke that target, but may never recover writer authority.
        try await relay.abandonPendingSource()
        try check()
    }
    private func changeSource(enabled: Bool, transfer: Bool, conversationID: String, userID: String) async throws {
        try check()
        guard same(conversationID, session.capsule.conversationID), same(userID, session.capsule.localAccountID) else {
            throw EncryptedLocationError.invalidRecord
        }
        if enabled, localDeviceID == nil { throw EncryptedLocationError.sourceOwnedByAnotherDevice }
        let hadWriterLease = sourceLease != nil
        if let sourceLease { cleanupSourceLease = sourceLease }
        sharingGeneration = UUID(); pending = nil; sourceLease = nil
        // A session captured before this explicit intent may never inherit its new generation.
        if latestLocationSession != nil, hadWriterLease { latestLocationSessionClosed = true }
        let generation = sharingGeneration
        if !enabled {
            explicitlyDisabled = true
            snapshotGeneration = UUID(); queuedSnapshot = nil
            lastSnapshot?.sharingUserIDs.remove(userID); lastSnapshot?.latestPoints[userID] = nil
            if let lastSnapshot { Array(observers.values).forEach { $0(.success(lastSnapshot)) } }
        }
        let lease: EncryptedLocationSourceLease?
        do {
            lease = transfer ? try await relay.transferSharingSource() : try await relay.setSharingEnabled(enabled)
        } catch {
            try check(generation: generation)
            throw (error as? EncryptedLocationError) ?? .unavailable
        }
        try check(generation: generation)
        if enabled {
            guard let lease, lease.isValid, lease.deviceID == localDeviceID else { throw EncryptedLocationError.invalidRecord }
            sourceLease = lease
        }
        cleanupSourceLease = nil
        explicitlyDisabled = !enabled
    }

    func publishLatest(_ point: LiveLocationPoint, for locationSession: LiveLocationSession) async throws {
        try check()
        guard !explicitlyDisabled else { throw EncryptedLocationError.sharingDisabled }
        guard locationSession.isActive(at: now()), fresh(point), !writing else {
            throw writing ? EncryptedLocationError.busy : EncryptedLocationError.invalidPoint
        }
        if let latest = latestLocationSession {
            if latest.id == locationSession.id {
                guard !latestLocationSessionClosed else { throw EncryptedLocationError.sharingDisabled }
            } else {
                guard locationSession.startedAt > latest.startedAt else { throw EncryptedLocationError.sharingDisabled }
                sourceLease = nil; sessionSourceLease = nil
                latestLocationSession = locationSession; latestLocationSessionClosed = false
            }
        } else {
            latestLocationSession = locationSession
        }
        writing = true; defer { writing = false }
        let generation = sharingGeneration
        if sourceLease == nil {
            let recovered: EncryptedLocationSourceLease
            do { recovered = try await relay.recoverSourceLease() }
            catch { try check(generation: generation); throw (error as? EncryptedLocationError) ?? .unavailable }
            try check(generation: generation)
            sourceLease = recovered
        }
        guard let lease = sourceLease, lease.isValid, lease.deviceID == localDeviceID else {
            throw EncryptedLocationError.sourceOwnedByAnotherDevice
        }
        if let captured = sessionSourceLease, captured != lease { throw EncryptedLocationError.sourceOwnedByAnotherDevice }
        sessionSourceLease = lease
        for _ in 0..<3 {
            try check(generation: generation)
            if pending == nil { pending = try await prepare(point, generation: generation, sourceLease: lease) }
            guard let pending else { throw EncryptedLocationError.invalidRecord }
            // Revalidate the pinned key immediately before every write/retry, not merely at seal.
            let context = try session.makeContext(recordID: pending.record.userID, senderID: pending.record.userID,
                                                  kind: .location, revision: pending.record.revision)
            do {
                _ = try await session.performKeyOperation { key in
                    try LocationCipher.open(pending.record.ciphertext, expectedContext: context, epochKey: key)
                }
            } catch { try check(generation: generation); throw EncryptedLocationError.invalidRecord }
            try check(generation: generation)
            let result: EncryptedLocationWriteResult
            do { result = try await relay.compareAndSet(pending.record, expectedRevision: pending.expectedRevision) }
            catch { try check(generation: generation); throw EncryptedLocationError.unavailable }
            try check(generation: generation)
            switch result {
            case .applied: self.pending = nil; return
            case .revisionConflict: self.pending = nil // explicit CAS failure is the only reprepare gate
            case .sourceChanged: self.pending = nil; self.sourceLease = nil; latestLocationSessionClosed = true; throw EncryptedLocationError.sourceOwnedByAnotherDevice
            case .sharingDisabled: self.pending = nil; explicitlyDisabled = true; throw EncryptedLocationError.sharingDisabled
            }
        }
        throw EncryptedLocationError.unavailable
    }

    private func prepare(_ point: LiveLocationPoint, generation: UUID, sourceLease: EncryptedLocationSourceLease) async throws -> (record: EncryptedLocationRecord, expectedRevision: UInt64?) {
        let existing: EncryptedLocationRecord?
        do { existing = try await relay.readLatest() }
        catch { try check(generation: generation); throw EncryptedLocationError.unavailable }
        try check(generation: generation)
        if let existing {
            guard same(existing.userID, session.capsule.localAccountID) else { throw EncryptedLocationError.invalidRecord }
            _ = try await decrypt(existing); try check(generation: generation)
        }
        let scope = session.capsule.scope
        let high = max(existing?.revision ?? 0, try revisions.value(scope: scope))
        guard high < Self.maximumRevision else { throw EncryptedLocationError.revisionExhausted }
        let wall = try milliseconds(now())
        let revision = max(high + 1, wall)
        guard revision <= Self.maximumRevision else { throw EncryptedLocationError.revisionExhausted }
        try revisions.reserve(revision, scope: scope)
        let context = try session.makeContext(recordID: scope.accountID, senderID: scope.accountID, kind: .location, revision: revision)
        let payload = try LocationPayload(latitude: point.latitude, longitude: point.longitude, horizontalAccuracy: point.horizontalAccuracy,
                                          recordedAtMilliseconds: milliseconds(point.recordedAt))
        let bytes: Data
        do { bytes = try await session.performKeyOperation { key in try LocationCipher.seal(payload, context: context, epochKey: key) } }
        catch { try check(generation: generation); throw EncryptedLocationError.invalidRecord }
        try check(generation: generation)
        guard bytes.count <= 4096 else { throw EncryptedLocationError.invalidRecord }
        return (EncryptedLocationRecord(userID: scope.accountID, encryption: session.capsule.suite, keyEpoch: scope.epoch,
                                        revision: revision, ciphertext: bytes, sourceDeviceID: sourceLease.deviceID, sourceGeneration: sourceLease.generation), existing?.revision)
    }

    func finish(_ locationSession: LiveLocationSession, reason: LiveLocationStopReason) async {
        // Expiry/unavailability clear the point; explicit stop/permission revocation also
        // abandon only this exact source. A failed cleanup retains no publication authority.
        do {
            try check()
            guard let latest = latestLocationSession, latest.id == locationSession.id, !latestLocationSessionClosed,
                  let lease = sessionSourceLease, sourceLease == lease else { return }
            // This lease belongs to the actual publishing session, not a later explicit claim.
            latestLocationSessionClosed = true
            sharingGeneration = UUID(); pending = nil; sourceLease = nil; sessionSourceLease = nil; cleanupSourceLease = lease
            if reason == .stoppedByUser || reason == .authorizationDenied {
                explicitlyDisabled = true
                try await relay.abandonSource(sourceLease: lease)
            } else {
                try await relay.deleteLatest(sourceLease: lease)
            }
            try check()
            if cleanupSourceLease == lease { cleanupSourceLease = nil }
        } catch { /* Safe best effort: caller can retry stopping/sharing-off; never log coordinates. */ }
    }

    func observe(conversationID: String, onChange: @escaping (Result<ConnectionLocationSnapshot, any Error>) -> Void) -> ServiceObservation {
        let id = UUID()
        do {
            try check()
            guard same(conversationID, session.capsule.conversationID), observers.count < 16 else { throw EncryptedLocationError.invalidRecord }
        } catch { onChange(.failure(EncryptedLocationError.inactive)); return ServiceObservation() }
        observers[id] = onChange
        if let lastSnapshot { onChange(.success(lastSnapshot)) }
        if listener == nil {
            listener = relay.observe { [weak self] result in self?.receive(result) }
        }
        return ServiceObservation { [weak self] in
            guard let self else { return }; self.observers[id] = nil
            if self.observers.isEmpty {
                self.listener?.cancel(); self.listener = nil; self.queuedSnapshot = nil; self.decodeRunID = nil
                self.decodeTask?.cancel(); self.decodeTask = nil
                self.snapshotGeneration = UUID(); self.lastSnapshot = nil
            }
        }
    }
    private func receive(_ result: Result<EncryptedLocationRelaySnapshot, EncryptedLocationError>) {
        guard valid else { return }
        snapshotGeneration = UUID(); queuedSnapshot = result
        guard decodeTask == nil else { return } // one decrypt task, one newest queued snapshot
        let run = UUID(); decodeRunID = run
        decodeTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.decodeRunID == run { self.decodeTask = nil; self.decodeRunID = nil } }
            drain: while let result = self.queuedSnapshot {
                guard self.valid, !Task.isCancelled, self.decodeRunID == run else { return }
                self.queuedSnapshot = nil
                let generation = self.snapshotGeneration
                do {
                    try self.check()
                    let snapshot = try result.get()
                    let members = [self.session.capsule.creatorID, self.session.capsule.recipientID].map { Data($0.utf8) }
                    guard snapshot.records.count <= 2, snapshot.sharingUserIDs.count <= 2,
                          Set(snapshot.sharingUserIDs.map { Data($0.utf8) }).count == snapshot.sharingUserIDs.count,
                          snapshot.sharingUserIDs.allSatisfy({ members.contains(Data($0.utf8)) }),
                          Set(snapshot.records.map { Data($0.userID.utf8) }).count == snapshot.records.count else { throw EncryptedLocationError.invalidRecord }
                    var points: [String: LiveLocationPoint] = [:]
                    var updates: [Data: (lease: EncryptedLocationSourceLease, revision: UInt64, ciphertext: Data)] = [:]
                    for record in snapshot.records {
                        let point = try await self.decrypt(record)
                        try self.check()
                        guard generation == self.snapshotGeneration, !Task.isCancelled else { continue drain }
                        let id = Data(record.userID.utf8)
                        if let old = self.observed[id], record.sourceGeneration < old.lease.generation || (record.sourceGeneration == old.lease.generation && (record.sourceDeviceID != old.lease.deviceID || record.revision < old.revision || (record.revision == old.revision && record.ciphertext != old.ciphertext))) {
                            throw EncryptedLocationError.invalidRecord
                        }
                        updates[id] = (record.sourceLease, record.revision, record.ciphertext)
                        // Never infer opt-in from ciphertext. A concurrent sharing-off snapshot may
                        // still contain a point document; only explicit true intent enables display.
                        if snapshot.sharingUserIDs.contains(where: { self.same($0, record.userID) }), snapshot.sourceLeases[record.userID] == record.sourceLease { points[record.userID] = point }
                    }
                    try self.check()
                    guard generation == self.snapshotGeneration, !Task.isCancelled else { continue drain }
                    for (id, value) in updates { self.observed[id] = value }
                    // Local shutdown suppresses this phone's cached point, not a replacement
                    // phone's explicit sharing intent. Observing a source never grants its lease.
                    let suppressOwn = self.explicitlyDisabled
                        && snapshot.sourceLeases[self.session.capsule.localAccountID]?.deviceID == self.localDeviceID
                    let sharing = snapshot.sharingUserIDs.filter { !suppressOwn || !self.same($0, self.session.capsule.localAccountID) }
                    if suppressOwn { points[self.session.capsule.localAccountID] = nil }
                    let decoded = ConnectionLocationSnapshot(sharingUserIDs: Set(sharing), latestPoints: points, sourceDeviceIDs: snapshot.sourceLeases.mapValues(\.deviceID), sourceGenerations: snapshot.sourceLeases.mapValues(\.generation))
                    if let own = updates[Data(self.session.capsule.localAccountID.utf8)] {
                        try self.revisions.reserve(own.revision, scope: self.session.capsule.scope)
                    }
                    self.lastSnapshot = decoded
                    Array(self.observers.values).forEach { $0(.success(decoded)) }
                } catch {
                    guard self.valid, generation == self.snapshotGeneration, !Task.isCancelled else { continue drain }
                    Array(self.observers.values).forEach { $0(.failure(EncryptedLocationError.invalidRecord)) }
                }
            }
        }
    }
    private func decrypt(_ record: EncryptedLocationRecord) async throws -> LiveLocationPoint {
        try check()
        guard [session.capsule.creatorID, session.capsule.recipientID].contains(where: { same($0, record.userID) }),
              same(record.encryption, session.capsule.suite), record.keyEpoch == session.capsule.keyEpoch,
              record.sourceLease.isValid, record.revision > 0, record.revision <= Self.maximumRevision, !record.ciphertext.isEmpty, record.ciphertext.count <= 4096 else {
            throw EncryptedLocationError.invalidRecord
        }
        let context = try session.makeContext(recordID: record.userID, senderID: record.userID, kind: .location, revision: record.revision)
        let payload: LocationPayload
        do { payload = try await session.performKeyOperation { key in try LocationCipher.open(record.ciphertext, expectedContext: context, epochKey: key) } }
        catch { try check(); throw EncryptedLocationError.invalidRecord }
        try check()
        let date = Date(timeIntervalSince1970: Double(payload.recordedAtMilliseconds) / 1000)
        guard date <= now().addingTimeInterval(60) else { throw EncryptedLocationError.invalidPoint }
        return LiveLocationPoint(latitude: payload.latitude, longitude: payload.longitude,
                                 horizontalAccuracy: payload.horizontalAccuracy, recordedAt: date)
    }
    private func fresh(_ point: LiveLocationPoint) -> Bool {
        point.latitude.isFinite && point.longitude.isFinite && point.horizontalAccuracy.isFinite && point.horizontalAccuracy >= 0
            && (-90...90).contains(point.latitude) && (-180...180).contains(point.longitude)
            && point.horizontalAccuracy <= ContentLimits.maximumHorizontalAccuracyMeters
            && point.recordedAt >= now().addingTimeInterval(-300) && point.recordedAt <= now().addingTimeInterval(60)
    }
    private func milliseconds(_ date: Date) throws -> UInt64 {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite, seconds >= 0, seconds <= Double(ContentLimits.maximumTimestampMilliseconds) / 1000 else { throw EncryptedLocationError.invalidPoint }
        return UInt64(seconds * 1000)
    }
    private func same(_ a: String, _ b: String) -> Bool { Data(a.utf8) == Data(b.utf8) }
}

#if os(iOS)
extension EncryptedLocationService: ConnectionLocationProviding, LiveLocationPublishing {}
#endif
