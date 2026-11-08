import CryptoKit
import Foundation
import Security
import XCTest
@testable import MinesE2EE

private actor CoordinatorRelay {
    var offer: Data = Data(), acceptance: Data?, grant: Data?
    var creator = "", recipient: String?, conversation = "", invite = "", claim: String?
    var expiry: UInt64 = 0
    var state: SecurePairingSnapshot.State = .offered
    var grantWrites: [Data] = []
    var failGrantOnce = false
    var activeConversation = true
    var failCancelOnce = false
    var corruptDigest = false
    var suspended = false
    var onlyGrant = false
    var waiting: CheckedContinuation<Void, Never>?
    var reached: CheckedContinuation<Void, Never>?
    var didReach = false
    func setFailCancel() { failCancelOnce = true }
    func corruptOfferDigest() { corruptDigest = true }
    func alterClaim() { acceptance = Data(repeating: 2, count: 100) }
    func setFailGrant() { failGrantOnce = true }
    func setActive(_ value: Bool) { activeConversation = value }
    func suspendNext() { suspended = true; onlyGrant = false; didReach = false }
    func suspendGrant() { suspended = true; onlyGrant = true; didReach = false }
    func waitUntilSuspended() async { if didReach { return }; await withCheckedContinuation { reached = $0 } }
    func release() { waiting?.resume(); waiting = nil }
    func writes() -> [Data] { grantWrites }
    func request(_ request: SecurePairingRequest, account: String) async throws -> SecurePairingResponse {
        let isGrant: Bool
        if case .grant = request { isGrant = true } else { isGrant = false }
        if suspended && (!onlyGrant || isGrant) { suspended = false; didReach = true; reached?.resume(); reached = nil
            await withCheckedContinuation { waiting = $0 }
        }
        switch request {
        case let .publish(id, c, _, bytes, expires):
            if offer.isEmpty { invite = id; conversation = c; creator = account; offer = bytes; expiry = expires }
            else { guard invite == id, offer == bytes, creator == account else { throw SecurePairingCoordinatorError.invalidRelay } }
        case .read: break
        case let .claim(_, id, bytes, digest):
            guard digest == Data(SHA256.hash(data: offer)) else { throw SecurePairingCoordinatorError.invalidRelay }
            if let acceptance { guard acceptance == bytes, recipient == account, claim == id else { throw SecurePairingCoordinatorError.conflictingTranscript } }
            else { acceptance = bytes; recipient = account; claim = id; state = .claimed }
        case let .grant(_, digest, bytes):
            guard account == creator, digest == acceptance.map({ Data(SHA256.hash(data: $0)) }) else { throw SecurePairingCoordinatorError.invalidRelay }
            grantWrites.append(bytes)
            if let grant { guard grant == bytes else { throw SecurePairingCoordinatorError.conflictingTranscript } }
            else { grant = bytes; state = .grantReady }
            if failGrantOnce { failGrantOnce = false; throw URLError(.networkConnectionLost) }
        case let .acknowledge(_, digest):
            guard account == recipient, digest == grant.map({ Data(SHA256.hash(data: $0)) }) else { throw SecurePairingCoordinatorError.invalidRelay }
            state = .complete
        case .cancel:
            state = .cancelled
            if failCancelOnce { failCancelOnce = false; throw URLError(.networkConnectionLost) }
            return .cancelled
        }
        return .snapshot(SecurePairingSnapshot(creatorID: creator, conversationID: conversation, keyEpoch: 1,
            protocolID: PairingProtocol.contentSuite, expiresAtMilliseconds: expiry, state: state,
            offer: offer, offerDigest: corruptDigest ? Data(repeating: 0, count: 32) : Data(SHA256.hash(data: offer)), claimantID: recipient, claimID: claim,
            acceptance: acceptance, acceptanceDigest: acceptance.map { Data(SHA256.hash(data: $0)) },
            grant: grant, grantDigest: grant.map { Data(SHA256.hash(data: $0)) }))
    }
    func confirm(c: String, creator: String, recipient: String, invite: String, digest: Data) -> Bool {
        activeConversation && state == .complete && conversation == c && self.creator == creator && self.recipient == recipient
            && self.invite == invite && grant.map { Data(SHA256.hash(data: $0)) } == digest
    }
}
private struct CoordinatorTransport: SecurePairingTransport {
    let relay: CoordinatorRelay
    let account: String
    func perform(_ request: SecurePairingRequest) async throws -> SecurePairingResponse { try await relay.request(request, account: account) }
    func confirmActiveConversation(conversationID: String, creatorID: String, recipientID: String, keyEpoch: UInt32,
                                   inviteID: String, grantDigest: Data) async throws -> Bool {
        await relay.confirm(c: conversationID, creator: creatorID, recipient: recipientID, invite: inviteID, digest: grantDigest)
    }
}

private final class FailableCoordinatorKeychain: KeychainBackend, @unchecked Sendable {
    private let lock = NSLock()
    private let underlying = CapsuleMockKeychain()
    private var fail = false
    func failNextAdd() { lock.withLock { fail = true } }
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Any?) { underlying.copyMatching(query) }
    func add(_ attributes: [String: Any]) -> OSStatus {
        if lock.withLock({ if fail { fail = false; return true }; return false }) { return errSecInteractionNotAllowed }
        return underlying.add(attributes)
    }
    func delete(_ query: [String: Any]) -> OSStatus { underlying.delete(query) }
}

@MainActor
final class SecurePairingCoordinatorTests: XCTestCase {
    let c = "f035ae9c-a095-4b52-9ffb-c103503835ac"
    let key = Data(repeating: 73, count: 32)
    let now: UInt64 = 1000
    private func stores(backend: any KeychainBackend & Sendable = CapsuleMockKeychain()) throws -> (PendingPairingKeychainStore, ConversationCapsuleStore) {
        let ns = try ConversationKeychainNamespace(productionAccessGroup: "TESTTEAM01.org.example.peapod.e2ee")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (try PendingPairingKeychainStore(namespace: ns, coordinationDirectory: directory, backend: backend),
                ConversationCapsuleStore(namespace: ns, backend: backend))
    }
    private func coordinator(_ uid: String, _ relay: CoordinatorRelay, _ stores: (PendingPairingKeychainStore, ConversationCapsuleStore)) throws -> SecurePairingCoordinator {
        try SecurePairingCoordinator(localAccountID: uid, transport: CoordinatorTransport(relay: relay, account: uid),
                                     pendingStore: stores.0, capsuleStore: stores.1)
    }
    private func prepare(_ relay: CoordinatorRelay, _ creator: SecurePairingCoordinator, _ recipient: SecurePairingCoordinator) async throws -> (PendingPairingHandle, PendingPairingHandle) {
        let ch = try await creator.beginCreator(conversationID: c, epochKey: key, nowMilliseconds: now, expiresAtMilliseconds: 100000)
        _ = try await creator.advance(ch, nowMilliseconds: now)
        let invite = try await creator.shareInvite(ch)
        let rh = try await recipient.accept(invite, nowMilliseconds: now)
        _ = try await recipient.advance(rh, nowMilliseconds: now)
        return (ch, rh)
    }
    func testCompletePairInstallsBothCapsulesAndConsumesOnlyAfterConfirmation() async throws {
        let relay = CoordinatorRelay(), cs = try stores(), rs = try stores()
        let creator = try coordinator("creator", relay, cs), recipient = try coordinator("recipient", relay, rs)
        let (ch, rh) = try await prepare(relay, creator, recipient)
        _ = try await creator.advance(ch, nowMilliseconds: now)
        guard case let .completed(rc) = try await recipient.advance(rh, nowMilliseconds: now),
              case let .completed(cc) = try await creator.advance(ch, nowMilliseconds: now) else { return XCTFail("not completed") }
        XCTAssertEqual(rc.keyMaterialForLocalStorage(), key)
        XCTAssertEqual(cc.transcriptHash, rc.transcriptHash)
        let scope = KeyScope(accountID: "recipient", conversationID: c, epoch: 1)
        let stored = try await rs.1.readCapsule(scope: scope)
        XCTAssertEqual(stored?.encodedForLocalStorage(), rc.encodedForLocalStorage())
        do { _ = try await recipient.advance(rh, nowMilliseconds: now); XCTFail("consumed handle revived") }
        catch { XCTAssertEqual(error as? ConversationKeyStoreError, .terminalInvite) }
    }
    func testRestartRetriesExactGrantAfterLostUploadResponse() async throws {
        let relay = CoordinatorRelay(), cs = try stores(), rs = try stores()
        var creator = try coordinator("creator", relay, cs)
        let recipient = try coordinator("recipient", relay, rs)
        let (ch, rh) = try await prepare(relay, creator, recipient)
        await relay.setFailGrant()
        do { _ = try await creator.advance(ch, nowMilliseconds: now); XCTFail("expected network failure") } catch {}
        creator = try coordinator("creator", relay, cs)
        _ = try await creator.advance(ch, nowMilliseconds: now)
        let writes = await relay.writes()
        XCTAssertEqual(writes.count, 2); XCTAssertEqual(writes[0], writes[1])
        _ = try await recipient.advance(rh, nowMilliseconds: now)
        _ = try await creator.advance(ch, nowMilliseconds: now)
    }
    func testPreparedHandlesResumeBeforeFirstPublishAndClaim() async throws {
        let relay = CoordinatorRelay(), cs = try stores(), rs = try stores()
        var creator = try coordinator("creator", relay, cs)
        let ch = try await creator.beginCreator(conversationID: c, epochKey: key, nowMilliseconds: now, expiresAtMilliseconds: 100000)
        creator = try coordinator("creator", relay, cs)
        _ = try await creator.advance(ch, nowMilliseconds: now)
        let invite = try await creator.shareInvite(ch)
        var recipient = try coordinator("recipient", relay, rs)
        let rh = try await recipient.accept(invite, nowMilliseconds: now)
        recipient = try coordinator("recipient", relay, rs)
        _ = try await recipient.advance(rh, nowMilliseconds: now)
        _ = try await creator.advance(ch, nowMilliseconds: now)
        _ = try await recipient.advance(rh, nowMilliseconds: now)
    }
    func testSignoutDuringRelayReadCannotReturnHandleOrWriteAcceptance() async throws {
        let relay = CoordinatorRelay(), cs = try stores(), rs = try stores()
        let creator = try coordinator("creator", relay, cs), recipient = try coordinator("recipient", relay, rs)
        let ch = try await creator.beginCreator(conversationID: c, epochKey: key, nowMilliseconds: now, expiresAtMilliseconds: 100000)
        _ = try await creator.advance(ch, nowMilliseconds: now)
        let invite = try await creator.shareInvite(ch)
        await relay.suspendNext()
        let task = Task { try await recipient.accept(invite, nowMilliseconds: now) }
        await relay.waitUntilSuspended(); await recipient.invalidate(); await relay.release()
        do { _ = try await task.value; XCTFail("stale handle returned") }
        catch { XCTAssertEqual(error as? SecurePairingCoordinatorError, .invalidSession) }
        let scope = try PendingPairingScope(localAccountID: "recipient", inviteID: invite.locatorHex, role: .recipient)
        let record = try await rs.0.readStage(.initialState, scope: scope)
        XCTAssertNil(record)
    }
    func testCancelWhileGrantUploadPendingPreventsCompletionAndResurrection() async throws {
        let relay = CoordinatorRelay(), cs = try stores(), rs = try stores()
        let creator = try coordinator("creator", relay, cs), recipient = try coordinator("recipient", relay, rs)
        let (ch, _) = try await prepare(relay, creator, recipient)
        await relay.suspendGrant()
        let task = Task { try await creator.advance(ch, nowMilliseconds: now) }
        await relay.waitUntilSuspended()
        try await creator.cancel(ch)
        await relay.release()
        do { _ = try await task.value; XCTFail("cancelled callback accepted") } catch {}
        let restarted = try coordinator("creator", relay, cs)
        do { _ = try await restarted.advance(ch, nowMilliseconds: now); XCTFail("tombstone ignored") }
        catch { XCTAssertEqual(error as? ConversationKeyStoreError, .terminalInvite) }
    }
    func testInactiveAssignmentPreventsCompletedReturnAndCleanup() async throws {
        let relay = CoordinatorRelay(), cs = try stores(), rs = try stores()
        let creator = try coordinator("creator", relay, cs), recipient = try coordinator("recipient", relay, rs)
        let (ch, rh) = try await prepare(relay, creator, recipient)
        _ = try await creator.advance(ch, nowMilliseconds: now)
        await relay.setActive(false)
        do { _ = try await recipient.advance(rh, nowMilliseconds: now); XCTFail("inactive accepted") }
        catch { XCTAssertEqual(error as? SecurePairingCoordinatorError, .inactiveConversation) }
        let remaining = try await rs.0.readStage(.initialState, scope: rh.scope)
        XCTAssertNotNil(remaining)
    }
    func testCancelledTombstoneAllowsRestartedRemoteRetry() async throws {
        let relay = CoordinatorRelay(), cs = try stores()
        var creator = try coordinator("creator", relay, cs)
        let ch = try await creator.beginCreator(conversationID: c, epochKey: key, nowMilliseconds: now, expiresAtMilliseconds: 100000)
        _ = try await creator.advance(ch, nowMilliseconds: now)
        await relay.setFailCancel()
        do { try await creator.cancel(ch); XCTFail("expected lost response") } catch {}
        let status = try await cs.0.terminalStatus(scope: ch.scope)
        XCTAssertEqual(status, .cancelled)
        creator = try coordinator("creator", relay, cs)
        try await creator.cancel(ch)
        do { _ = try await creator.advance(ch, nowMilliseconds: now); XCTFail("cancelled resumed") } catch {}
    }
    func testTransientCancellationPinFailureCanRetry() async throws {
        let relay = CoordinatorRelay(), backend = FailableCoordinatorKeychain()
        let cs = try stores(backend: backend)
        let creator = try coordinator("creator", relay, cs)
        let handle = try await creator.beginCreator(conversationID: c, epochKey: key, nowMilliseconds: now, expiresAtMilliseconds: 100000)
        _ = try await creator.advance(handle, nowMilliseconds: now)
        backend.failNextAdd()
        do { try await creator.cancel(handle); XCTFail("expected Keychain unavailable") } catch {}
        let absent = try await cs.0.terminalStatus(scope: handle.scope)
        XCTAssertNil(absent)
        try await creator.cancel(handle)
        let cancelled = try await cs.0.terminalStatus(scope: handle.scope)
        XCTAssertEqual(cancelled, .cancelled)
    }
    func testMissingPersistedGrantDoesNotRegeneratePublishedGrant() async throws {
        let relay = CoordinatorRelay(), backend = CapsuleMockKeychain()
        let cs = try stores(backend: backend), rs = try stores()
        let creator = try coordinator("creator", relay, cs), recipient = try coordinator("recipient", relay, rs)
        let (ch, _) = try await prepare(relay, creator, recipient)
        _ = try await creator.advance(ch, nowMilliseconds: now)
        // Last add is the exact local grant stage; emulate damaged/missing device-local state.
        let grantAttributes = try XCTUnwrap(backend.addQueries.last)
        XCTAssertEqual(backend.delete(grantAttributes), errSecSuccess)
        do { _ = try await creator.advance(ch, nowMilliseconds: now); XCTFail("grant regenerated") }
        catch { XCTAssertEqual(error as? SecurePairingCoordinatorError, .missingState) }
        let writes = await relay.writes()
        XCTAssertEqual(writes.count, 1)
    }
    func testRelayDigestAndChangedAcceptanceFailClosed() async throws {
        let relay = CoordinatorRelay(), cs = try stores(), rs = try stores()
        let creator = try coordinator("creator", relay, cs), recipient = try coordinator("recipient", relay, rs)
        let (ch, _) = try await prepare(relay, creator, recipient)
        _ = try await creator.advance(ch, nowMilliseconds: now)
        await relay.alterClaim()
        do { _ = try await creator.advance(ch, nowMilliseconds: now); XCTFail("changed acceptance accepted") } catch {}
        let writes = await relay.writes()
        XCTAssertEqual(writes.count, 1)
        await relay.corruptOfferDigest()
        do { _ = try await creator.advance(ch, nowMilliseconds: now); XCTFail("bad digest accepted") }
        catch { XCTAssertEqual(error as? SecurePairingCoordinatorError, .invalidRelay) }
    }
    func testWrongAccountAndMissingStateFailClosed() async throws {
        let relay = CoordinatorRelay(), cs = try stores()
        let creator = try coordinator("creator", relay, cs)
        let absent = try PendingPairingHandle(scope: PendingPairingScope(localAccountID: "creator", inviteID: String(repeating: "a", count: 32), role: .creator), conversationID: c)
        do { _ = try await creator.advance(absent, nowMilliseconds: now); XCTFail("missing accepted") }
        catch { XCTAssertEqual(error as? SecurePairingCoordinatorError, .missingState) }
        let other = try coordinator("other", relay, cs)
        do { _ = try await other.advance(absent, nowMilliseconds: now); XCTFail("wrong account accepted") }
        catch { XCTAssertEqual(error as? SecurePairingCoordinatorError, .invalidSession) }
    }
}
