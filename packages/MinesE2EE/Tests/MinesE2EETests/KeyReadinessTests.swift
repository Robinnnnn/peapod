import CryptoKit
import Foundation
import Security
import XCTest
@testable import MinesE2EE

@MainActor
final class KeyReadinessTests: XCTestCase {
    private let key = Data(repeating: 19, count: 32)
    private let scope = KeyScope(accountID: "synthetic-account", conversationID: "unique-conversation", epoch: 1)

    private func descriptor(_ scope: KeyScope? = nil, key: Data? = nil) throws -> TrustedKeyDescriptor {
        let scope = scope ?? self.scope
        return try TrustedKeyDescriptor(scope: scope,
                                        expectedKeyCommitment: TrustedKeyDescriptor.commitment(for: key ?? self.key, scope: scope))
    }

    private func lease(_ readiness: KeyReadiness) throws -> ReadyKeyLease {
        var result: ReadyKeyLease?
        if case .ready(let value) = readiness { result = value }
        return try XCTUnwrap(result, "Expected a ready lease")
    }

    func testSignedOutDoesNotRead() async throws {
        let reader = QueueKeyReader([.found(key)])
        let subject = KeyReadinessController(reader: reader)
        let token = try await subject.activate(descriptor())
        await subject.signOut()
        let result = await subject.read(token: token)
        XCTAssertEqual(result.description, "signedOut")
        let count = await reader.scopes.count
        XCTAssertEqual(count, 0)
    }

    func testMissingWaitsAndLaterReadRecoversWithoutCreation() async throws {
        let reader = QueueKeyReader([.missing, .found(key)])
        let subject = KeyReadinessController(reader: reader)
        let token = try await subject.activate(descriptor())
        let missing = await subject.read(token: token)
        XCTAssertEqual(missing.description, "awaitingSync")
        let ready = try lease(await subject.read(token: token))
        let verifiedSize = try await subject.useKey(ready) { key, _ in key.bitCount }
        XCTAssertEqual(verifiedSize, 256)
        let count = await reader.scopes.count
        XCTAssertEqual(count, 2)
    }

    func testUnavailableAndReaderFailureAreDistinctFromMissing() async throws {
        let statuses: [OSStatus] = [errSecInteractionNotAllowed, errSecMissingEntitlement, errSecNotAvailable, errSecAuthFailed]
        let reader = QueueKeyReader(statuses.map(EpochKeyReadResult.unavailable) + [.readerFailure])
        let subject = KeyReadinessController(reader: reader)
        let token = try await subject.activate(descriptor())
        for status in statuses {
            let result = await subject.read(token: token)
            XCTAssertEqual(result.description, "unavailable(\(status))")
        }
        let result = await subject.read(token: token)
        XCTAssertEqual(result.description, "readerFailure")
    }

    func testInvalidStoredBytesAreRejected() async throws {
        let reader = QueueKeyReader([.invalidBytes, .found(Data()), .found(Data(repeating: 0, count: 31)),
                                     .found(Data(repeating: 0, count: 33))])
        let subject = KeyReadinessController(reader: reader)
        let token = try await subject.activate(descriptor())
        for _ in 0..<4 {
            let result = await subject.read(token: token)
            XCTAssertEqual(result.description, "invalidBytes")
        }
    }

    func testDifferentKeyConflictsWithoutExposingFingerprint() async throws {
        let subject = KeyReadinessController(reader: QueueKeyReader([.found(Data(repeating: 20, count: 32))]))
        let token = try await subject.activate(descriptor())
        let result = await subject.read(token: token)
        XCTAssertEqual(result.description, "conflictingExpectedKey")
        XCTAssertEqual(String(reflecting: result), "conflictingExpectedKey")
    }

    func testCommitmentCannotBeReusedForAnotherAccountConversationOrEpoch() async throws {
        let commitment = try TrustedKeyDescriptor.commitment(for: key, scope: scope)
        for changed in [KeyScope(accountID: "other", conversationID: scope.conversationID, epoch: 1),
                        KeyScope(accountID: scope.accountID, conversationID: "other", epoch: 1),
                        KeyScope(accountID: scope.accountID, conversationID: scope.conversationID, epoch: 2)] {
            let subject = KeyReadinessController(reader: QueueKeyReader([.found(key)]))
            let token = try await subject.activate(TrustedKeyDescriptor(scope: changed, expectedKeyCommitment: commitment))
            let result = await subject.read(token: token)
            XCTAssertEqual(result.description, "conflictingExpectedKey")
        }
    }

    func testIdentifierBindingIsByteExactAndLengthPrefixed() throws {
        let composed = KeyScope(accountID: "\u{e9}", conversationID: "c", epoch: 1)
        let decomposed = KeyScope(accountID: "e\u{301}", conversationID: "c", epoch: 1)
        XCTAssertEqual(composed.accountID, decomposed.accountID) // Swift String equality normalizes.
        XCTAssertNotEqual(try TrustedKeyDescriptor.commitment(for: key, scope: composed),
                          try TrustedKeyDescriptor.commitment(for: key, scope: decomposed))
        XCTAssertNotEqual(try TrustedKeyDescriptor.commitment(for: key, scope: KeyScope(accountID: "a:b", conversationID: "c", epoch: 1)),
                          try TrustedKeyDescriptor.commitment(for: key, scope: KeyScope(accountID: "a", conversationID: "b:c", epoch: 1)))
    }

    func testReaderReceivesExactExpectedScope() async throws {
        let exactScope = KeyScope(accountID: "e\u{301}", conversationID: "raw:\u{e9}", epoch: 7)
        let reader = QueueKeyReader([.found(key)])
        let subject = KeyReadinessController(reader: reader)
        let token = try await subject.activate(descriptor(exactScope))
        _ = try lease(await subject.read(token: token))
        let scopes = await reader.scopes
        let captured = try XCTUnwrap(scopes.first)
        XCTAssertEqual(Data(captured.accountID.utf8), Data(exactScope.accountID.utf8))
        XCTAssertEqual(Data(captured.conversationID.utf8), Data(exactScope.conversationID.utf8))
        XCTAssertEqual(captured.epoch, 7)
    }

    func testDelayedReadAfterSignOutCannotReturnUsableKey() async throws {
        let reader = SuspendedKeyReader()
        let subject = KeyReadinessController(reader: reader)
        let token = try await subject.activate(descriptor())
        let task = Task { await subject.read(token: token) }
        await reader.waitForRead()
        await subject.signOut()
        await reader.complete(.found(key))
        let result = await task.value
        XCTAssertEqual(result.description, "staleSession")
    }

    func testDelayedReadAfterSwitchAwayAndBackStillStale() async throws {
        let reader = SuspendedKeyReader()
        let subject = KeyReadinessController(reader: reader)
        let original = try await subject.activate(descriptor())
        let task = Task { await subject.read(token: original) }
        await reader.waitForRead()
        _ = try await subject.activate(descriptor(KeyScope(accountID: "other-account", conversationID: "other-conversation", epoch: 1)))
        let replacement = try await subject.activate(descriptor())
        XCTAssertNotEqual(original, replacement)
        await reader.complete(.found(key))
        let result = await task.value
        XCTAssertEqual(result.description, "staleSession")
    }

    func testDelayedReadAfterCloseAndEpochReactivationRejected() async throws {
        let reader = SuspendedKeyReader()
        let subject = KeyReadinessController(reader: reader)
        let token = try await subject.activate(descriptor())
        let task = Task { await subject.read(token: token) }
        await reader.waitForRead()
        try await subject.closeConversation(token: token)
        await reader.complete(.found(key))
        let result = await task.value
        XCTAssertEqual(result.description, "staleSession")
        let closed = await subject.read(token: token)
        XCTAssertEqual(closed.description, "closedConversation")
        do {
            _ = try await subject.activate(descriptor(KeyScope(accountID: scope.accountID, conversationID: scope.conversationID, epoch: 2)))
            XCTFail("Closed conversation must never be reused")
        } catch { XCTAssertEqual(error as? KeyLifecycleError, .closedConversation) }
        _ = try await subject.activate(descriptor(KeyScope(accountID: scope.accountID, conversationID: "new-unique-conversation", epoch: 1)))
    }

    func testStaleLeaseCannotInvokeOperationAfterSameAccountReactivation() async throws {
        let subject = KeyReadinessController(reader: QueueKeyReader([.found(key)]))
        let token = try await subject.activate(descriptor())
        let ready = try lease(await subject.read(token: token))
        _ = try await subject.activate(descriptor())
        do {
            let _: Int = try await subject.useKey(ready) { _, _ in throw CallbackCalled.unexpected }
            XCTFail("Stale lease must not invoke callback")
        } catch { XCTAssertEqual(error as? KeyLifecycleError, .staleSession) }
    }

    func testClosedLeaseAndForeignControllerLeaseCannotInvokeOperation() async throws {
        let subject = KeyReadinessController(reader: QueueKeyReader([.found(key)]))
        let token = try await subject.activate(descriptor())
        let ready = try lease(await subject.read(token: token))
        let foreign = KeyReadinessController(reader: QueueKeyReader([]))
        _ = try await foreign.activate(descriptor())
        do {
            let _: Int = try await foreign.useKey(ready) { _, _ in throw CallbackCalled.unexpected }
            XCTFail("Foreign lease accepted")
        } catch { XCTAssertEqual(error as? KeyLifecycleError, .staleSession) }
        try await subject.closeConversation(token: token)
        do {
            let _: Int = try await subject.useKey(ready) { _, _ in throw CallbackCalled.unexpected }
            XCTFail("Closed lease accepted")
        } catch { XCTAssertEqual(error as? KeyLifecycleError, .closedConversation) }
    }

    func testReadyLeaseSupportsSynchronousCryptoAndRedactsSecrets() async throws {
        let subject = KeyReadinessController(reader: QueueKeyReader([.found(key)]))
        let trusted = try descriptor()
        let token = try await subject.activate(trusted)
        let result = await subject.read(token: token)
        let ready = try lease(result)
        let context = try RecordContext(conversationID: scope.conversationID, recordID: "synthetic-record",
                                        senderID: scope.accountID, keyEpoch: 1, revision: 1)
        let sealed = try await subject.useKey(ready) { key, _ in
            try RecordCipher.seal(Data("synthetic message".utf8), context: context, epochKey: key)
        }
        let recovered = try await subject.useKey(ready) { key, _ in
            try RecordCipher.open(sealed, expectedContext: context, epochKey: key)
        }
        XCTAssertEqual(recovered, Data("synthetic message".utf8))
        XCTAssertEqual(String(describing: ready), "ReadyKeyLease(redacted)")
        XCTAssertEqual(String(reflecting: ready), "ReadyKeyLease(redacted)")
        XCTAssertTrue(Mirror(reflecting: ready).children.isEmpty)
        XCTAssertEqual(String(reflecting: result), "ready(redacted)")
        XCTAssertEqual(String(reflecting: trusted), "TrustedKeyDescriptor(redacted)")
        XCTAssertEqual(String(reflecting: EpochKeyReadResult.found(key)), "found(redacted)")
        let capturedScope = try await subject.useKey(ready) { _, scope in scope }
        XCTAssertEqual(Data(capturedScope.accountID.utf8), Data(scope.accountID.utf8))
        XCTAssertEqual(Data(capturedScope.conversationID.utf8), Data(scope.conversationID.utf8))
        XCTAssertEqual(capturedScope.epoch, scope.epoch)
    }

    func testMissingAndUnavailablePreserveKnownLeaseButConflictFreezesUntilActivation() async throws {
        let reader = QueueKeyReader([.found(key), .missing, .unavailable(errSecNotAvailable),
                                     .found(Data(repeating: 20, count: 32)), .found(key)])
        let subject = KeyReadinessController(reader: reader)
        let token = try await subject.activate(descriptor())
        let ready = try lease(await subject.read(token: token))
        for expected in ["awaitingSync", "unavailable(\(errSecNotAvailable))"] {
            let result = await subject.read(token: token)
            XCTAssertEqual(result.description, expected)
            let count = try await subject.useKey(ready) { key, _ in key.bitCount }
            XCTAssertEqual(count, 256)
        }
        let conflict = await subject.read(token: token)
        XCTAssertEqual(conflict.description, "conflictingExpectedKey")
        do {
            let _: Int = try await subject.useKey(ready) { _, _ in throw CallbackCalled.unexpected }
            XCTFail("Conflict must freeze previously valid lease")
        } catch { XCTAssertEqual(error as? KeyLifecycleError, .conflictingExpectedKey) }
        let frozen = await subject.read(token: token)
        XCTAssertEqual(frozen.description, "conflictingExpectedKey")
        let reads = await reader.scopes.count
        XCTAssertEqual(reads, 4)
        let replacement = try await subject.activate(descriptor())
        _ = try lease(await subject.read(token: replacement))
        do {
            let _: Int = try await subject.useKey(ready) { _, _ in throw CallbackCalled.unexpected }
            XCTFail("New activation must not revive old lease")
        } catch { XCTAssertEqual(error as? KeyLifecycleError, .staleSession) }
    }

    func testConflictFreezesEarlierValidReadStillInFlight() async throws {
        let reader = ControllableKeyReader()
        let subject = KeyReadinessController(reader: reader)
        let token = try await subject.activate(descriptor())
        let earlier = Task { await subject.read(token: token) }
        await reader.waitForReads(1)
        let later = Task { await subject.read(token: token) }
        await reader.waitForReads(2)
        await reader.complete(index: 1, value: .found(Data(repeating: 20, count: 32)))
        let conflict = await later.value
        XCTAssertEqual(conflict.description, "conflictingExpectedKey")
        await reader.complete(index: 0, value: .found(key))
        let frozen = await earlier.value
        XCTAssertEqual(frozen.description, "conflictingExpectedKey")
    }

    func testInvalidDescriptorAndAdapterConfigurationFailClosed() throws {
        for invalid in [KeyScope(accountID: "", conversationID: "c", epoch: 1),
                        KeyScope(accountID: "a", conversationID: "", epoch: 1),
                        KeyScope(accountID: "a", conversationID: "c", epoch: 0)] {
            XCTAssertThrowsError(try TrustedKeyDescriptor(scope: invalid, expectedKeyCommitment: Data(repeating: 0, count: 32)))
        }
        XCTAssertThrowsError(try TrustedKeyDescriptor(scope: scope, expectedKeyCommitment: Data()))
        XCTAssertThrowsError(try TrustedKeyDescriptor.commitment(for: Data(), scope: scope))
        XCTAssertThrowsError(try SynchronizableEpochKeyReader(accessGroup: "production-group"))
    }
}

private enum CallbackCalled: Error { case unexpected }

private actor QueueKeyReader: EpochKeyReader {
    var scopes: [KeyScope] = []
    private var values: [EpochKeyReadResult]
    init(_ values: [EpochKeyReadResult]) { self.values = values }
    func read(scope: KeyScope) async -> EpochKeyReadResult {
        scopes.append(scope)
        return values.isEmpty ? .readerFailure : values.removeFirst()
    }
}

private actor SuspendedKeyReader: EpochKeyReader {
    private var readContinuation: CheckedContinuation<EpochKeyReadResult, Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    func read(scope: KeyScope) async -> EpochKeyReadResult {
        await withCheckedContinuation { continuation in
            readContinuation = continuation
            startedContinuation?.resume()
            startedContinuation = nil
        }
    }
    func waitForRead() async {
        if readContinuation != nil { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }
    func complete(_ value: EpochKeyReadResult) {
        readContinuation?.resume(returning: value)
        readContinuation = nil
    }
}

private actor ControllableKeyReader: EpochKeyReader {
    private var continuations: [CheckedContinuation<EpochKeyReadResult, Never>?] = []
    private var waiting: (count: Int, continuation: CheckedContinuation<Void, Never>)?
    func read(scope: KeyScope) async -> EpochKeyReadResult {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
            if let waiting, continuations.count >= waiting.count {
                waiting.continuation.resume()
                self.waiting = nil
            }
        }
    }
    func waitForReads(_ count: Int) async {
        if continuations.count >= count { return }
        await withCheckedContinuation { waiting = (count, $0) }
    }
    func complete(index: Int, value: EpochKeyReadResult) {
        continuations[index]?.resume(returning: value)
        continuations[index] = nil
    }
}
