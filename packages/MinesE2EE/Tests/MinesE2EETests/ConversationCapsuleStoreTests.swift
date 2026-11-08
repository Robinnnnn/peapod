import CryptoKit
import Foundation
import Security
import XCTest
@testable import MinesE2EE

@MainActor
final class ConversationCapsuleStoreTests: XCTestCase {
    private let conversation = "f035ae9c-a095-4b52-9ffb-c103503835ac"
    private let key = Data(repeating: 43, count: 32)

    private func capsule(local: String = "creator", creator: String = "creator", recipient: String = "recipient",
                         epoch: UInt32 = 1, key: Data? = nil, transcript: Data? = nil) throws -> StoredConversationCapsule {
        let material = key ?? self.key
        let scope = KeyScope(accountID: local, conversationID: conversation, epoch: epoch)
        return try StoredConversationCapsule(localAccountID: local, creatorID: creator, recipientID: recipient,
            conversationID: conversation, keyEpoch: epoch, epochKey: material,
            transcriptHash: transcript ?? Data(repeating: 88, count: 32),
            protocolKeyCommitment: StoredConversationCapsule.protocolCommitment(epochKey: material, conversationID: conversation, keyEpoch: epoch),
            expectedKeyCommitment: TrustedKeyDescriptor.commitment(for: material, scope: scope))
    }

    private func namespace() throws -> ConversationKeychainNamespace {
        try ConversationKeychainNamespace(productionAccessGroup: "TESTTEAM01.org.example.peapod.e2ee")
    }

    func testCapsuleStrictRoundtripAndRedaction() throws {
        let original = try capsule()
        let decoded = try StoredConversationCapsule(localStorage: original.encodedForLocalStorage())
        XCTAssertEqual(decoded.encodedForLocalStorage(), original.encodedForLocalStorage())
        XCTAssertEqual(decoded.keyMaterialForLocalStorage(), key)
        XCTAssertEqual(String(describing: decoded), "StoredConversationCapsule(redacted)")
        XCTAssertEqual(String(reflecting: decoded), "StoredConversationCapsule(redacted)")
        XCTAssertTrue(Mirror(reflecting: decoded).children.isEmpty)
    }

    func testMalformedVersionTrailingAndOversizeFailClosed() throws {
        let encoded = try capsule().encodedForLocalStorage()
        var unknown = encoded; unknown[7] = 2
        XCTAssertThrowsError(try StoredConversationCapsule(localStorage: unknown)) {
            XCTAssertEqual($0 as? ConversationKeyStoreError, .unsupportedVersion)
        }
        for invalid in [Data(encoded.prefix(20)), encoded + Data([0]), Data(repeating: 0, count: 4097)] {
            XCTAssertThrowsError(try StoredConversationCapsule(localStorage: invalid))
        }
        var wrongDigest = encoded; wrongDigest[wrongDigest.count - 1] ^= 1
        XCTAssertThrowsError(try StoredConversationCapsule(localStorage: wrongDigest)) {
            XCTAssertEqual($0 as? ConversationKeyStoreError, .invalidCommitment)
        }
    }

    func testMemberIdentityIsByteExactAndLocalAccountMustBeMember() throws {
        XCTAssertThrowsError(try capsule(local: "outsider")) {
            XCTAssertEqual($0 as? ConversationKeyStoreError, .identityMismatch)
        }
        XCTAssertThrowsError(try capsule(recipient: "creator"))
        XCTAssertThrowsError(try capsule(local: "\u{e9}", creator: "e\u{301}")) {
            XCTAssertEqual($0 as? ConversationKeyStoreError, .identityMismatch)
        }
        _ = try capsule(local: "e\u{301}", creator: "e\u{301}", recipient: "\u{e9}")
    }

    func testUnsupportedSuiteBadKeysAndNoncanonicalConversationRejected() throws {
        let good = try capsule()
        for (id, suite, bytes) in [(conversation.uppercased(), StoredConversationCapsule.contentSuite, key),
                                    (conversation, "unsupported", key),
                                    (conversation, StoredConversationCapsule.contentSuite, Data(repeating: 0, count: 31))] {
            XCTAssertThrowsError(try StoredConversationCapsule(localAccountID: "creator", creatorID: "creator", recipientID: "recipient",
                conversationID: id, keyEpoch: 1, suite: suite, epochKey: bytes,
                transcriptHash: good.transcriptHash, protocolKeyCommitment: good.protocolKeyCommitment,
                expectedKeyCommitment: good.expectedKeyCommitment))
        }
    }

    func testNamespaceIsDedicatedAndProbeRequiresExplicitOptIn() throws {
        _ = try namespace()
        for group in ["", "TESTTEAM01.org.example.peapod.shared-auth", "TESTTEAM01.org.example.peapod.e2ee-probe",
                      "TESTTEAM01.org.example.peapod.e2ee.extra", "*.org.example.peapod.e2ee"] {
            XCTAssertThrowsError(try ConversationKeychainNamespace(productionAccessGroup: group))
        }
        _ = try ConversationKeychainNamespace(productionAccessGroup: "TESTTEAM01.org.example.peapod.e2ee",
            expectedSuffix: ".org.example.peapod.e2ee")
        XCTAssertThrowsError(try ConversationKeychainNamespace(productionAccessGroup: "TESTTEAM01.org.example.peapod.e2ee",
            expectedSuffix: ".org.example.other.e2ee"))
        for invalid in ["SHORT.org.example.peapod.e2ee", "TESTTEAM01.org..example.e2ee",
                        "$(AppIdentifierPrefix)org.example.peapod.e2ee"] {
            XCTAssertThrowsError(try ConversationKeychainNamespace(productionAccessGroup: invalid))
        }
        let synthetic = try ConversationKeychainNamespace.syntheticProbe(accessGroup: "TESTTEAM01.org.example.peapod.e2ee-probe")
        XCTAssertNotEqual(synthetic.service("conversation-capsule"), try namespace().service("conversation-capsule"))
    }

    func testNativeQueryPolicyAndFreshDeviceDescriptorFromAtomicCapsule() async throws {
        let backend = CapsuleMockKeychain()
        let subject = ConversationCapsuleStore(namespace: try namespace(), backend: backend)
        let original = try capsule()
        try await subject.insertAuthenticatedCapsule(original)
        try await subject.insertAuthenticatedCapsule(original)
        XCTAssertEqual(backend.addQueries.count, 1)
        let attributes = try XCTUnwrap(backend.addQueries.first)
        XCTAssertEqual(attributes[kSecAttrAccessGroup as String] as? String, "TESTTEAM01.org.example.peapod.e2ee")
        XCTAssertEqual(attributes[kSecAttrService as String] as? String, "mines.e2ee.conversation-capsule.v1")
        XCTAssertEqual(attributes[kSecAttrSynchronizable as String] as? Bool, true)
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlock as String)
        XCTAssertEqual(attributes[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(attributes[kSecValueData as String] as? Data, original.encodedForLocalStorage())
        let freshDevice = ConversationCapsuleStore(namespace: try namespace(), backend: backend)
        let descriptorValue = try await freshDevice.trustedDescriptor(scope: original.scope)
        let descriptor = try XCTUnwrap(descriptorValue)
        let controller = KeyReadinessController(reader: freshDevice)
        let token = try await controller.activate(descriptor)
        let state = await controller.read(token: token)
        guard case .ready(let lease) = state else { XCTFail("Trusted capsule must become ready"); return }
        let bitCount = try await controller.useKey(lease) { key, _ in key.bitCount }
        XCTAssertEqual(bitCount, 256)
        await controller.signOut()
        XCTAssertTrue(backend.deleteQueries.isEmpty)
    }

    func testMissingReadsDoNotGenerateAndUnavailableIsDistinct() async throws {
        let backend = CapsuleMockKeychain()
        let subject = ConversationCapsuleStore(namespace: try namespace(), backend: backend)
        let scope = try capsule().scope
        let result = await subject.read(scope: scope)
        XCTAssertEqual(result.description, "missing")
        XCTAssertTrue(backend.addQueries.isEmpty)
        for status in [errSecMissingEntitlement, errSecInteractionNotAllowed, errSecNotAvailable] {
            backend.overrideNextRead(status: status, result: nil)
            let result = await subject.read(scope: scope)
            XCTAssertEqual(result.description, "unavailable(\(status))")
        }
        XCTAssertTrue(backend.deleteQueries.isEmpty)
    }

    func testScopeDimensionsIsolationAndByteExactIdentifiers() async throws {
        let backend = CapsuleMockKeychain()
        let subject = ConversationCapsuleStore(namespace: try namespace(), backend: backend)
        let original = try capsule(local: "e\u{301}", creator: "e\u{301}")
        try await subject.insertAuthenticatedCapsule(original)
        for wrong in [KeyScope(accountID: "\u{e9}", conversationID: conversation, epoch: 1),
                      KeyScope(accountID: "e\u{301}", conversationID: "496b90ed-5c26-4d1f-a8d1-a7e300f13b3c", epoch: 1),
                      KeyScope(accountID: "e\u{301}", conversationID: conversation, epoch: 2)] {
            let result = try await subject.readCapsule(scope: wrong)
            XCTAssertNil(result)
        }
        let scopes = backend.readQueries.compactMap { $0[kSecAttrAccount as String] as? String }
        XCTAssertEqual(Set(scopes).count, 4)
    }

    func testWrongIdentityReturnedByBackendIsInvalidInsteadOfReady() async throws {
        let backend = CapsuleMockKeychain()
        let subject = ConversationCapsuleStore(namespace: try namespace(), backend: backend)
        let original = try capsule()
        backend.overrideNextRead(status: errSecSuccess, result: original.encodedForLocalStorage())
        let wrong = KeyScope(accountID: "recipient", conversationID: conversation, epoch: 1)
        let result = await subject.read(scope: wrong)
        XCTAssertEqual(result.description, "invalidBytes")
    }

    func testFullCapsuleConflictsEvenWhenKeyIsIdentical() async throws {
        let backend = CapsuleMockKeychain()
        let subject = ConversationCapsuleStore(namespace: try namespace(), backend: backend)
        try await subject.insertAuthenticatedCapsule(capsule())
        for altered in [try capsule(recipient: "other-peer"), try capsule(transcript: Data(repeating: 0, count: 32))] {
            do {
                try await subject.insertAuthenticatedCapsule(altered)
                XCTFail("Trust evidence must not be overwritten")
            } catch { XCTAssertEqual(error as? ConversationKeyStoreError, .conflict) }
        }
        XCTAssertEqual(backend.addQueries.count, 1)
        XCTAssertTrue(backend.deleteQueries.isEmpty)
    }

    func testDuplicateRaceChecksExactStoredBytes() async throws {
        for same in [true, false] {
            let backend = CapsuleMockKeychain()
            let subject = ConversationCapsuleStore(namespace: try namespace(), backend: backend)
            let original = try capsule()
            backend.duplicateNextAdd(with: same ? original.encodedForLocalStorage() : try capsule(recipient: "other-peer").encodedForLocalStorage())
            do {
                try await subject.insertAuthenticatedCapsule(original)
                XCTAssertTrue(same)
            } catch {
                XCTAssertFalse(same)
                XCTAssertEqual(error as? ConversationKeyStoreError, .conflict)
            }
            XCTAssertTrue(backend.deleteQueries.isEmpty)
        }
    }

    func testObservedFullCapsuleChangeFreezesReadyLeaseEvenWithSameKey() async throws {
        let backend = CapsuleMockKeychain()
        let subject = ConversationCapsuleStore(namespace: try namespace(), backend: backend)
        let original = try capsule()
        try await subject.insertAuthenticatedCapsule(original)
        let descriptorValue = try await subject.trustedDescriptor(scope: original.scope)
        let controller = KeyReadinessController(reader: subject)
        let token = try await controller.activate(XCTUnwrap(descriptorValue))
        let result = await controller.read(token: token)
        guard case .ready(let lease) = result else { XCTFail("Expected ready"); return }
        backend.overrideNextRead(status: errSecSuccess, result: try capsule(transcript: Data(repeating: 7, count: 32)).encodedForLocalStorage())
        let conflict = await controller.read(token: token)
        XCTAssertEqual(conflict.description, "conflictingExpectedKey")
        do {
            let _: Int = try await controller.useKey(lease) { key, _ in key.bitCount }
            XCTFail("A full-capsule conflict must freeze prior validated leases")
        } catch { XCTAssertEqual(error as? KeyLifecycleError, .conflictingExpectedKey) }
        let permanentlyConflicted = await subject.read(scope: original.scope)
        XCTAssertEqual(permanentlyConflicted.description, "conflictingExpectedKey")
    }

    func testFreshPinnedAdapterRejectsChangedPeerOnItsFirstRead() async throws {
        let backend = CapsuleMockKeychain()
        let writer = ConversationCapsuleStore(namespace: try namespace(), backend: backend)
        let original = try capsule()
        try await writer.insertAuthenticatedCapsule(try capsule(recipient: "different-peer"))
        let freshStore = ConversationCapsuleStore(namespace: try namespace(), backend: backend)
        let pinned = PinnedConversationCapsuleReader(store: freshStore, expectedCapsule: original)
        let descriptor = try await pinned.trustedDescriptor()
        let controller = KeyReadinessController(reader: pinned)
        let token = try await controller.activate(descriptor)
        let result = await controller.read(token: token)
        XCTAssertEqual(result.description, "conflictingExpectedKey")
        XCTAssertTrue(backend.deleteQueries.isEmpty)
    }

    func testEachParticipantStoresSameProtocolCommitmentButOwnLocalCommitment() throws {
        let creator = try capsule()
        let recipient = try capsule(local: "recipient")
        XCTAssertEqual(creator.protocolKeyCommitment, recipient.protocolKeyCommitment)
        XCTAssertNotEqual(creator.expectedKeyCommitment, recipient.expectedKeyCommitment)
        XCTAssertNotEqual(creator.encodedForLocalStorage(), recipient.encodedForLocalStorage())
    }
}

/// Thread-safe shared native-query fake permits tests across multiple store actors.
final class CapsuleMockKeychain: KeychainBackend, @unchecked Sendable {
    private struct Identity: Hashable {
        let group: String; let service: String; let account: String; let sync: Bool
        init(_ query: [String: Any]) {
            group = query[kSecAttrAccessGroup as String] as? String ?? ""
            service = query[kSecAttrService as String] as? String ?? ""
            account = query[kSecAttrAccount as String] as? String ?? ""
            sync = query[kSecAttrSynchronizable as String] as? Bool ?? false
        }
    }
    private let lock = NSLock()
    private var items: [Identity: Data] = [:]
    private var reads: [[String: Any]] = []
    private var adds: [[String: Any]] = []
    private var deletes: [[String: Any]] = []
    private var readOverride: (OSStatus, Any?)?
    private var duplicateBytes: Data?
    var readQueries: [[String: Any]] { lock.withLock { reads } }
    var addQueries: [[String: Any]] { lock.withLock { adds } }
    var deleteQueries: [[String: Any]] { lock.withLock { deletes } }
    func overrideNextRead(status: OSStatus, result: Any?) { lock.withLock { readOverride = (status, result) } }
    func duplicateNextAdd(with bytes: Data) { lock.withLock { duplicateBytes = bytes } }
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Any?) {
        lock.withLock {
            reads.append(query)
            if let override = readOverride { readOverride = nil; return override }
            guard let bytes = items[Identity(query)] else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, bytes)
        }
    }
    func add(_ attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            adds.append(attributes)
            let identity = Identity(attributes)
            if let duplicateBytes { items[identity] = duplicateBytes; self.duplicateBytes = nil; return errSecDuplicateItem }
            guard items[identity] == nil else { return errSecDuplicateItem }
            guard let bytes = attributes[kSecValueData as String] as? Data else { return errSecParam }
            items[identity] = bytes
            return errSecSuccess
        }
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        lock.withLock {
            deletes.append(query)
            return items.removeValue(forKey: Identity(query)) == nil ? errSecItemNotFound : errSecSuccess
        }
    }
}
