import Foundation
import Security
import CryptoKit
import XCTest
@testable import MinesE2EE

private final class CleanupFaultKeychain: KeychainBackend, @unchecked Sendable {
    let base = CapsuleMockKeychain()
    private let lock = NSLock()
    private var remaining: Int?
    func failDeletion(_ ordinal: Int) { lock.withLock { remaining = ordinal } }
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Any?) { base.copyMatching(query) }
    func add(_ attributes: [String: Any]) -> OSStatus { base.add(attributes) }
    func delete(_ query: [String: Any]) -> OSStatus {
        let fail = lock.withLock {
            guard let left = remaining else { return false }
            remaining = left == 1 ? nil : left - 1
            return left == 1
        }
        return fail ? errSecInteractionNotAllowed : base.delete(query)
    }
}

@MainActor final class TerminalPairingCleanupTests: XCTestCase {
    private func store(_ backend: CleanupFaultKeychain, _ directory: URL) throws -> PendingPairingKeychainStore {
        try PendingPairingKeychainStore(namespace: ConversationKeychainNamespace(productionAccessGroup: "TESTTEAM01.org.example.peapod.e2ee"),
            coordinationDirectory: directory, backend: backend)
    }
    func testCancelledAndConsumedCleanupRetryAcrossStoreRestartAfterEveryDeletionFault() async throws {
        for consumed in [false, true] { for failure in 1...3 {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let backend = CleanupFaultKeychain(), subject = try store(backend, directory)
            let scope = try PendingPairingScope(localAccountID: "account", inviteID: String(repeating: "a", count: 32), role: .creator)
            let other = try PendingPairingScope(localAccountID: "other", inviteID: String(repeating: "a", count: 32), role: .creator)
            let initial = Data("secret initial".utf8), claim = Data("secret claim".utf8), grant = Data("sealed grant".utf8)
            let pin = try await subject.pinInitialState(initial, scope: scope)
            _ = try await subject.pinInitialState(initial, scope: other)
            try await subject.pinStage(.acceptedClaim, bytes: claim, scope: scope, pin: pin)
            try await subject.pinStage(.sealedGrant, bytes: grant, scope: scope, pin: pin, acceptedClaimDigest: Data(SHA256.hash(data: claim)))
            backend.failDeletion(failure)
            do {
                if consumed { try await subject.consumeAndCleanUp(scope: scope, pin: pin, expectedSealedGrantDigest: Data(SHA256.hash(data: grant))) }
                else { try await subject.cancelAndCleanUp(scope: scope, pin: pin) }
                XCTFail("fault ignored")
            } catch { XCTAssertEqual(error as? ConversationKeyStoreError, .securityStatus(errSecInteractionNotAllowed)) }
            let restarted = try store(backend, directory)
            let terminal = try await restarted.retryTerminalCleanup(scope: scope)
            XCTAssertEqual(terminal, consumed ? .consumed : .cancelled)
            _ = try await restarted.retryTerminalCleanup(scope: scope)
            let untouched = try await restarted.readStage(.initialState, scope: other)
            XCTAssertNotNil(untouched)
            let before = backend.base.addQueries.count
            do { _ = try await restarted.pinInitialState(initial, scope: scope); XCTFail("resurrected") }
            catch { XCTAssertEqual(error as? ConversationKeyStoreError, .terminalInvite) }
            XCTAssertEqual(backend.base.addQueries.count, before)
            for query in backend.base.deleteQueries {
                XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
                XCTAssertEqual(query[kSecAttrService as String] as? String, "mines.e2ee.pending-pairing.v1")
                XCTAssertEqual(query.count, 5)
            }
        } }
    }
    func testVerifiedDeletionRetirementWithMissingInitialRetainsScopedTerminalAndRetriesPartialCleanup() async throws {
        for failure in 1...3 {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let backend = CleanupFaultKeychain(), subject = try store(backend, directory)
            let scope = try PendingPairingScope(localAccountID: "account", inviteID: String(repeating: "b", count: 32), role: .creator)
            let other = try PendingPairingScope(localAccountID: "other", inviteID: scope.inviteID, role: .creator)
            _ = try await subject.pinInitialState(Data("synthetic other state".utf8), scope: other)
            backend.failDeletion(failure)
            do { try await subject.retireAfterVerifiedConversationDeletion(scope: scope); XCTFail("fault ignored") }
            catch { XCTAssertEqual(error as? ConversationKeyStoreError, .securityStatus(errSecInteractionNotAllowed)) }
            let restarted = try store(backend, directory)
            let terminal = try await restarted.terminalStatus(scope: scope)
            XCTAssertEqual(terminal, .cancelled)
            try await restarted.retireAfterVerifiedConversationDeletion(scope: scope)
            let untouched = try await restarted.readStage(.initialState, scope: other)
            XCTAssertNotNil(untouched)
            do { _ = try await restarted.pinInitialState(Data("replacement".utf8), scope: scope); XCTFail("resurrected") }
            catch { XCTAssertEqual(error as? ConversationKeyStoreError, .terminalInvite) }
            XCTAssertTrue(backend.base.deleteQueries.allSatisfy { $0[kSecAttrSynchronizable as String] as? Bool == false })
        }
    }

    func testVerifiedDeletionPreservesConsumedDecision() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = CleanupFaultKeychain(), subject = try store(backend, directory)
        let scope = try PendingPairingScope(localAccountID: "account", inviteID: String(repeating: "c", count: 32), role: .recipient)
        let pin = try await subject.pinInitialState(Data("initial".utf8), scope: scope)
        let claim = Data("claim".utf8), grant = Data("grant".utf8)
        try await subject.pinStage(.acceptedClaim, bytes: claim, scope: scope, pin: pin)
        try await subject.pinStage(.sealedGrant, bytes: grant, scope: scope, pin: pin, acceptedClaimDigest: Data(SHA256.hash(data: claim)))
        try await subject.consumeAndCleanUp(scope: scope, pin: pin, expectedSealedGrantDigest: Data(SHA256.hash(data: grant)))
        try await subject.retireAfterVerifiedConversationDeletion(scope: scope)
        let terminal = try await subject.terminalStatus(scope: scope)
        XCTAssertEqual(terminal, .consumed)
    }

    func testMissingMalformedOrWrongScopeTerminalCannotAuthorizeDeletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = CleanupFaultKeychain(), subject = try store(backend, directory)
        let scope = try PendingPairingScope(localAccountID: "account", inviteID: String(repeating: "a", count: 32), role: .creator)
        do { _ = try await subject.retryTerminalCleanup(scope: scope); XCTFail("no tombstone") }
        catch { XCTAssertEqual(error as? ConversationKeyStoreError, .missingPrerequisite) }
        backend.base.overrideNextRead(status: errSecSuccess, result: Data("malformed".utf8))
        do { _ = try await subject.retryTerminalCleanup(scope: scope); XCTFail("malformed tombstone") } catch {}
        var wrong = BinaryWriter()
        wrong.bytes(Data("PPTM".utf8)); wrong.uint32(1); wrong.string("other")
        wrong.string(scope.inviteID); wrong.uint32(scope.role.rawValue); wrong.uint32(1)
        wrong.bytes(Data(repeating: 0, count: 32))
        backend.base.overrideNextRead(status: errSecSuccess, result: wrong.data)
        do { _ = try await subject.retryTerminalCleanup(scope: scope); XCTFail("wrong-scope tombstone") }
        catch { XCTAssertEqual(error as? ConversationKeyStoreError, .identityMismatch) }
        XCTAssertTrue(backend.base.deleteQueries.isEmpty)
    }
}
