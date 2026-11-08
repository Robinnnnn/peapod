import CryptoKit
import Foundation
import Security
import XCTest
@testable import MinesE2EE

@MainActor
final class PendingPairingKeychainStoreTests: XCTestCase {
    nonisolated(unsafe) private var directory: URL!
    private let initial = Data("opaque synthetic initial state".utf8)
    private let claim = Data("opaque synthetic accepted claim".utf8)
    private let grant = Data("opaque synthetic sealed grant".utf8)

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("mines-pairing-lock-tests-\(UUID().uuidString)")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    private func scope(account: String = "creator", invite: String = "3adef3634a9347bc833d09be5543886b",
                       role: PendingPairingScope.Role = .creator) throws -> PendingPairingScope {
        try PendingPairingScope(localAccountID: account, inviteID: invite, role: role)
    }
    private func store(_ backend: CapsuleMockKeychain) throws -> PendingPairingKeychainStore {
        try PendingPairingKeychainStore(namespace: ConversationKeychainNamespace(productionAccessGroup: "TESTTEAM01.org.example.peapod.e2ee"),
                                        coordinationDirectory: directory, backend: backend)
    }
    private func digest(_ bytes: Data) -> Data { Data(SHA256.hash(data: bytes)) }

    func testDeviceLocalQueryPolicyAndImmutableInitialState() async throws {
        let backend = CapsuleMockKeychain()
        let subject = try store(backend)
        let scope = try scope()
        let pin = try await subject.pinInitialState(initial, scope: scope)
        _ = try await subject.pinInitialState(initial, scope: scope)
        XCTAssertEqual(pin.initialStateDigest, digest(initial))
        XCTAssertEqual(backend.addQueries.count, 1)
        let query = try XCTUnwrap(backend.addQueries.first)
        XCTAssertEqual(query[kSecAttrService as String] as? String, "mines.e2ee.pending-pairing.v1")
        XCTAssertEqual(query[kSecAttrAccessGroup as String] as? String, "TESTTEAM01.org.example.peapod.e2ee")
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(query[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        do {
            _ = try await subject.pinInitialState(Data("changed initial".utf8), scope: scope)
            XCTFail("Initial state changed")
        } catch { XCTAssertEqual(error as? ConversationKeyStoreError, .conflict) }
        let record = try await subject.readStage(.initialState, scope: scope)
        XCTAssertEqual(record?.opaqueBytesForLocalStorage(), initial)
        XCTAssertEqual(record?.initialStatePin.initialStateDigest, pin.initialStateDigest)
        XCTAssertTrue(backend.deleteQueries.isEmpty)
    }

    func testStagesRequireExactPersistedInitialAndAcceptedClaim() async throws {
        let backend = CapsuleMockKeychain()
        let subject = try store(backend)
        let scope = try scope()
        let pin = try await subject.pinInitialState(initial, scope: scope)
        do {
            try await subject.pinStage(.sealedGrant, bytes: grant, scope: scope, pin: pin, acceptedClaimDigest: digest(claim))
            XCTFail("Grant before claim")
        } catch { XCTAssertEqual(error as? ConversationKeyStoreError, .missingPrerequisite) }
        try await subject.pinStage(.acceptedClaim, bytes: claim, scope: scope, pin: pin)
        do {
            try await subject.pinStage(.sealedGrant, bytes: Data(repeating: 0, count: 8 * 1024 + 1),
                                        scope: scope, pin: pin, acceptedClaimDigest: digest(claim))
            XCTFail("Oversized sealed wire grant")
        } catch { XCTAssertEqual(error as? ConversationKeyStoreError, .sizeLimitExceeded) }
        do {
            try await subject.pinStage(.sealedGrant, bytes: grant, scope: scope, pin: pin, acceptedClaimDigest: Data(repeating: 0, count: 32))
            XCTFail("Wrong claim digest")
        } catch { XCTAssertEqual(error as? ConversationKeyStoreError, .conflict) }
        try await subject.pinStage(.sealedGrant, bytes: grant, scope: scope, pin: pin, acceptedClaimDigest: digest(claim))
        let recovered = try await subject.readStage(.sealedGrant, scope: scope)
        XCTAssertEqual(recovered?.opaqueBytesForLocalStorage(), grant)
        XCTAssertEqual(recovered?.acceptedClaimDigest, digest(claim))
        XCTAssertEqual(backend.addQueries.count, 3)
        XCTAssertTrue(backend.deleteQueries.isEmpty)
    }

    func testFirstClaimAndSealedGrantCannotBeChangedOnRetry() async throws {
        let backend = CapsuleMockKeychain()
        let subject = try store(backend)
        let scope = try scope()
        let pin = try await subject.pinInitialState(initial, scope: scope)
        try await subject.pinStage(.acceptedClaim, bytes: claim, scope: scope, pin: pin)
        try await subject.pinStage(.acceptedClaim, bytes: claim, scope: scope, pin: pin)
        try await subject.pinStage(.sealedGrant, bytes: grant, scope: scope, pin: pin, acceptedClaimDigest: digest(claim))
        try await subject.pinStage(.sealedGrant, bytes: grant, scope: scope, pin: pin, acceptedClaimDigest: digest(claim))
        for stage in [PendingPairingStage.acceptedClaim, .sealedGrant] {
            do {
                try await subject.pinStage(stage, bytes: Data("different".utf8), scope: scope, pin: pin,
                                           acceptedClaimDigest: stage == .sealedGrant ? digest(claim) : nil)
                XCTFail("Immutable stage replaced")
            } catch { XCTAssertEqual(error as? ConversationKeyStoreError, .conflict) }
        }
        XCTAssertEqual(backend.addQueries.count, 3)
    }

    func testWrongInitialPinCannotAdvanceAnotherInvite() async throws {
        let backend = CapsuleMockKeychain()
        let subject = try store(backend)
        let originalScope = try scope()
        let otherScope = try scope(invite: "3929e2c7d7454350b4932a87035435a4")
        let pin = try await subject.pinInitialState(initial, scope: originalScope)
        _ = try await subject.pinInitialState(Data("other initial".utf8), scope: otherScope)
        do {
            try await subject.pinStage(.acceptedClaim, bytes: claim, scope: otherScope, pin: pin)
            XCTFail("Cross-invite pin accepted")
        } catch { XCTAssertEqual(error as? ConversationKeyStoreError, .conflict) }
    }

    func testScopeAccountInviteRoleAndRawUTF8Isolation() async throws {
        let backend = CapsuleMockKeychain()
        let subject = try store(backend)
        let original = try scope(account: "e\u{301}")
        _ = try await subject.pinInitialState(initial, scope: original)
        for wrong in [try scope(account: "\u{e9}"), try scope(account: "other"),
                      try scope(account: "e\u{301}", invite: "3929e2c7d7454350b4932a87035435a4"),
                      try scope(account: "e\u{301}", role: .recipient)] {
            let missing = try await subject.readStage(.initialState, scope: wrong)
            XCTAssertNil(missing)
        }
    }

    func testCancellationRetainsTombstoneAndCannotResurrectStagesOrDeleteCapsule() async throws {
        let backend = CapsuleMockKeychain()
        let subject = try store(backend)
        let scope = try scope()
        let pin = try await subject.pinInitialState(initial, scope: scope)
        try await subject.pinStage(.acceptedClaim, bytes: claim, scope: scope, pin: pin)
        try await subject.cancelAndCleanUp(scope: scope, pin: pin)
        try await subject.cancelAndCleanUp(scope: scope, pin: pin)
        for stage in [PendingPairingStage.initialState, .acceptedClaim, .sealedGrant] {
            do {
                _ = try await subject.readStage(stage, scope: scope)
                XCTFail("Terminal stages readable")
            } catch { XCTAssertEqual(error as? ConversationKeyStoreError, .terminalInvite) }
        }
        do {
            _ = try await subject.pinInitialState(initial, scope: scope)
            XCTFail("Invite resurrected")
        } catch { XCTAssertEqual(error as? ConversationKeyStoreError, .terminalInvite) }
        do {
            try await subject.pinStage(.sealedGrant, bytes: grant, scope: scope, pin: pin, acceptedClaimDigest: digest(claim))
            XCTFail("Delayed grant writer succeeded after cancel")
        } catch { XCTAssertEqual(error as? ConversationKeyStoreError, .terminalInvite) }
        XCTAssertEqual(backend.deleteQueries.count, 6)
        for query in backend.deleteQueries {
            XCTAssertEqual(query.count, 5)
            XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
            XCTAssertEqual(query[kSecAttrService as String] as? String, "mines.e2ee.pending-pairing.v1")
            let account = try XCTUnwrap(query[kSecAttrAccount as String] as? String)
            let bytes = try XCTUnwrap(Data(base64Encoded: account))
            var reader = BinaryReader(bytes)
            XCTAssertEqual(try reader.string(maximum: 256), scope.localAccountID)
            XCTAssertEqual(try reader.string(maximum: 256), scope.inviteID)
            XCTAssertEqual(try reader.uint32(), scope.role.rawValue)
            XCTAssertTrue((1...3).contains(try reader.uint32()))
            XCTAssertTrue(reader.isAtEnd)
        }
    }

    func testConsumedTombstoneRequiresExactGrantAndSurvivesCleanup() async throws {
        let backend = CapsuleMockKeychain()
        let subject = try store(backend)
        let scope = try scope()
        let pin = try await subject.pinInitialState(initial, scope: scope)
        try await subject.pinStage(.acceptedClaim, bytes: claim, scope: scope, pin: pin)
        try await subject.pinStage(.sealedGrant, bytes: grant, scope: scope, pin: pin, acceptedClaimDigest: digest(claim))
        do {
            try await subject.consumeAndCleanUp(scope: scope, pin: pin, expectedSealedGrantDigest: Data(repeating: 0, count: 32))
            XCTFail("Wrong grant consumed")
        } catch { XCTAssertEqual(error as? ConversationKeyStoreError, .conflict) }
        XCTAssertTrue(backend.deleteQueries.isEmpty)
        try await subject.consumeAndCleanUp(scope: scope, pin: pin, expectedSealedGrantDigest: digest(grant))
        try await subject.consumeAndCleanUp(scope: scope, pin: pin, expectedSealedGrantDigest: digest(grant))
        do {
            try await subject.cancelAndCleanUp(scope: scope, pin: pin)
            XCTFail("Consumed decision changed to cancelled")
        } catch { XCTAssertEqual(error as? ConversationKeyStoreError, .conflict) }
        do {
            _ = try await subject.pinInitialState(initial, scope: scope)
            XCTFail("Consumed invite resurrected")
        } catch { XCTAssertEqual(error as? ConversationKeyStoreError, .terminalInvite) }
    }

    func testConcurrentStoresPinOnlyOneFirstAcceptedClaim() async throws {
        let backend = CapsuleMockKeychain()
        let first = try store(backend)
        let second = try store(backend)
        let scope = try scope()
        let pin = try await first.pinInitialState(initial, scope: scope)
        let successes = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<12 {
                let subject = index.isMultiple(of: 2) ? first : second
                group.addTask {
                    do {
                        try await subject.pinStage(.acceptedClaim, bytes: Data("claim-\(index)".utf8), scope: scope, pin: pin)
                        return true
                    } catch { return false }
                }
            }
            var count = 0
            for await succeeded in group { if succeeded { count += 1 } }
            return count
        }
        XCTAssertEqual(successes, 1)
        XCTAssertEqual(backend.addQueries.count, 2)
        let recovered = try await second.readStage(.acceptedClaim, scope: scope)
        XCTAssertNotNil(recovered)
    }

    func testOversizeUnavailableAndMalformedStagesFailClosed() async throws {
        let backend = CapsuleMockKeychain()
        let subject = try store(backend)
        let scope = try scope()
        do {
            _ = try await subject.pinInitialState(Data(repeating: 0, count: 32 * 1024 + 1), scope: scope)
            XCTFail("Oversized opaque state")
        } catch { XCTAssertEqual(error as? ConversationKeyStoreError, .sizeLimitExceeded) }
        XCTAssertTrue(backend.addQueries.isEmpty)
        backend.overrideNextRead(status: errSecInteractionNotAllowed, result: nil)
        do {
            _ = try await subject.pinInitialState(initial, scope: scope)
            XCTFail("Unavailable must not mean missing")
        } catch { XCTAssertEqual(error as? ConversationKeyStoreError, .securityStatus(errSecInteractionNotAllowed)) }
        XCTAssertTrue(backend.addQueries.isEmpty)
        backend.overrideNextRead(status: errSecSuccess, result: Data("malformed terminal tombstone".utf8))
        do {
            _ = try await subject.readStage(.initialState, scope: scope)
            XCTFail("Malformed terminal must not mean active")
        } catch { XCTAssertEqual(error as? ConversationKeyStoreError, .terminalInvite) }
    }

    func testRecoveredPendingSecretsAreRedacted() async throws {
        let subject = try store(CapsuleMockKeychain())
        let scope = try scope()
        let pin = try await subject.pinInitialState(initial, scope: scope)
        let value = try await subject.readStage(.initialState, scope: scope)
        let record = try XCTUnwrap(value)
        XCTAssertEqual(String(reflecting: record), "PendingPairingRecord(redacted)")
        XCTAssertTrue(Mirror(reflecting: record).children.isEmpty)
        XCTAssertEqual(String(reflecting: pin), "PendingPairingPin(redacted)")
        XCTAssertEqual(String(reflecting: scope), "PendingPairingScope(redacted)")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(try files[0].resourceValues(forKeys: [.fileSizeKey]).fileSize, 0)
        XCTAssertFalse(files[0].lastPathComponent.contains(scope.localAccountID))
    }
}
