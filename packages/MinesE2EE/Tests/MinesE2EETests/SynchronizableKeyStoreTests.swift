import Foundation
import Security
import XCTest
@testable import MinesE2EE

final class SynchronizableKeyStoreTests: XCTestCase {
    private let scope = KeyScope(accountID: "synthetic-account", conversationID: "synthetic-conversation", epoch: 1)
    private let key = Data(repeating: 7, count: 32)

    private func store(_ backend: MockKeychain) throws -> SynchronizableKeyStore {
        try SynchronizableKeyStore(accessGroup: "TESTTEAM.mines.e2ee-probe", backend: backend)
    }

    func testMissingReadDoesNotAddOrDelete() throws {
        let backend = MockKeychain()
        XCTAssertNil(try store(backend).read(scope: scope))
        XCTAssertEqual(backend.adds.count, 0)
        XCTAssertEqual(backend.deletes.count, 0)
        try assertScope(backend.reads[0])
        XCTAssertEqual(backend.reads[0][kSecReturnData as String] as? Bool, true)
        XCTAssertEqual(backend.reads[0][kSecMatchLimit as String] as? String, kSecMatchLimitOne as String)
    }

    func testInsertUsesSynchronizableAfterFirstUnlockAndDedicatedScope() throws {
        let backend = MockKeychain()
        try store(backend).insert(key, scope: scope)
        XCTAssertEqual(backend.adds.count, 1)
        try assertScope(backend.adds[0])
        XCTAssertEqual(backend.adds[0][kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleAfterFirstUnlock as String)
        XCTAssertEqual(backend.adds[0][kSecValueData as String] as? Data, key)
    }

    func testIdenticalExistingKeyIsIdempotent() throws {
        let backend = MockKeychain(results: [(errSecSuccess, key)])
        try store(backend).insert(key, scope: scope)
        XCTAssertTrue(backend.adds.isEmpty)
    }

    func testDifferentExistingKeyFailsWithoutMutation() throws {
        let backend = MockKeychain(results: [(errSecSuccess, Data(repeating: 9, count: 32))])
        XCTAssertThrowsError(try store(backend).insert(key, scope: scope)) {
            XCTAssertEqual($0 as? KeyStoreError, .conflict)
        }
        XCTAssertTrue(backend.adds.isEmpty)
        XCTAssertTrue(backend.deletes.isEmpty)
    }

    func testDuplicateRaceDetectsDifferentKey() throws {
        let backend = MockKeychain(results: [(errSecItemNotFound, nil), (errSecSuccess, Data(repeating: 9, count: 32))])
        backend.addStatus = errSecDuplicateItem
        XCTAssertThrowsError(try store(backend).insert(key, scope: scope)) {
            XCTAssertEqual($0 as? KeyStoreError, .conflict)
        }
        XCTAssertEqual(backend.adds.count, 1)
        XCTAssertTrue(backend.deletes.isEmpty)
    }

    func testDuplicateRaceAcceptsIdenticalKey() throws {
        let backend = MockKeychain(results: [(errSecItemNotFound, nil), (errSecSuccess, key)])
        backend.addStatus = errSecDuplicateItem
        try store(backend).insert(key, scope: scope)
        XCTAssertEqual(backend.reads.count, 2)
    }

    func testUnavailableIsNotMissingAndCannotCreate() throws {
        for status in [errSecInteractionNotAllowed, errSecMissingEntitlement, errSecNotAvailable, errSecAuthFailed] {
            let backend = MockKeychain(results: [(status, nil)])
            XCTAssertThrowsError(try store(backend).insert(key, scope: scope)) {
                XCTAssertEqual($0 as? KeyStoreError, .securityStatus(status))
            }
            XCTAssertTrue(backend.adds.isEmpty)
        }
    }

    func testMalformedStoredBytesFailClosed() throws {
        for value: Any in [Data(repeating: 0, count: 31), "unexpected"] {
            let backend = MockKeychain(results: [(errSecSuccess, value)])
            XCTAssertThrowsError(try store(backend).read(scope: scope)) {
                XCTAssertEqual($0 as? KeyStoreError, .unexpectedResult)
            }
        }
    }

    func testAllScopeDimensionsProduceDifferentQueries() throws {
        let backend = MockKeychain()
        let subject = try store(backend)
        for value in [scope,
                      KeyScope(accountID: "other", conversationID: scope.conversationID, epoch: 1),
                      KeyScope(accountID: scope.accountID, conversationID: "other", epoch: 1),
                      KeyScope(accountID: scope.accountID, conversationID: scope.conversationID, epoch: 2),
                      KeyScope(accountID: "a:b", conversationID: "c", epoch: 1),
                      KeyScope(accountID: "a", conversationID: "b:c", epoch: 1)] {
            _ = try subject.read(scope: value)
        }
        XCTAssertEqual(Set(backend.reads.compactMap { $0[kSecAttrAccount as String] as? String }).count, 6)
    }

    func testCleanupCannotDeleteOutsideExactScope() throws {
        let backend = MockKeychain()
        try store(backend).deleteForExplicitProbeCleanup(scope: scope)
        XCTAssertEqual(backend.deletes.count, 1)
        try assertScope(backend.deletes[0])
        XCTAssertEqual(backend.deletes[0].count, 5)
    }

    func testInvalidConfigurationAndScopeNeverCallBackend() throws {
        let backend = MockKeychain()
        for group in ["", "TEAM.production", "TEAM.mines"] {
            XCTAssertThrowsError(try SynchronizableKeyStore(accessGroup: group, backend: backend))
        }
        let subject = try store(backend)
        XCTAssertThrowsError(try subject.read(scope: KeyScope(accountID: "", conversationID: "c", epoch: 1)))
        XCTAssertThrowsError(try subject.read(scope: KeyScope(accountID: "a", conversationID: "c", epoch: 0)))
        XCTAssertThrowsError(try subject.insert(Data(), scope: scope))
        XCTAssertTrue(backend.reads.isEmpty)
        XCTAssertTrue(backend.adds.isEmpty)
    }

    private func assertScope(_ query: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String, file: file, line: line)
        XCTAssertEqual(query[kSecAttrAccessGroup as String] as? String, "TESTTEAM.mines.e2ee-probe", file: file, line: line)
        XCTAssertEqual(query[kSecAttrService as String] as? String, SynchronizableKeyStore.service, file: file, line: line)
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, true, file: file, line: line)
        let account = try XCTUnwrap(query[kSecAttrAccount as String] as? String)
        let data = try XCTUnwrap(Data(base64Encoded: account))
        XCTAssertEqual(try JSONDecoder().decode(KeyScope.self, from: data), scope, file: file, line: line)
    }
}

private final class MockKeychain: KeychainBackend {
    var results: [(OSStatus, Any?)]
    var reads: [[String: Any]] = []
    var adds: [[String: Any]] = []
    var deletes: [[String: Any]] = []
    var addStatus = errSecSuccess
    var deleteStatus = errSecSuccess
    init(results: [(OSStatus, Any?)] = []) { self.results = results }
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Any?) {
        reads.append(query)
        return results.isEmpty ? (errSecItemNotFound, nil) : results.removeFirst()
    }
    func add(_ attributes: [String: Any]) -> OSStatus { adds.append(attributes); return addStatus }
    func delete(_ query: [String: Any]) -> OSStatus { deletes.append(query); return deleteStatus }
}
