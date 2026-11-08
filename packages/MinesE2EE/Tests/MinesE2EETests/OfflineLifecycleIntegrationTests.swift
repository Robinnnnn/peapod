import CryptoKit
import Foundation
import XCTest
@testable import MinesE2EE

/// Local composition tests only: the reader is synthetic, and there is no cloud transport.
@MainActor
final class OfflineLifecycleIntegrationTests: XCTestCase {
    func testRestartRetryUsesTrustedScopeAndSignOutBlocksStaleEnqueue() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = Data(repeating: 71, count: 32)
        let scope = KeyScope(accountID: "synthetic-a", conversationID: UUID().uuidString, epoch: 1)
        let descriptor = try TrustedKeyDescriptor(scope: scope,
            expectedKeyCommitment: TrustedKeyDescriptor.commitment(for: key, scope: scope))
        let controller = KeyReadinessController(reader: IntegrationKeyReader(bytes: key))
        let token = try await controller.activate(descriptor)
        guard case .ready(let lease) = await controller.read(token: token) else {
            return XCTFail("Synthetic reader must yield a ready lease")
        }
        let outbox = try DurableCiphertextOutbox(directory: directory)
        let context = try RecordContext(conversationID: scope.conversationID, recordID: "message-1",
            senderID: scope.accountID, keyEpoch: scope.epoch, revision: 1)
        let envelope = try MessageCipher.seal(MessagePayload(text: "private restart test"), context: context,
            epochKey: SymmetricKey(data: key))
        let receipt = try await controller.useKey(lease) { verifiedKey, trustedScope in
            try outbox.enqueue(envelope: envelope, attachments: [], context: context,
                scope: OutboxScope(accountID: trustedScope.accountID, conversationID: trustedScope.conversationID,
                                   keyEpoch: trustedScope.epoch), epochKey: verifiedKey)
        }
        outbox.close()
        let reopened = try DurableCiphertextOutbox(directory: directory)
        let loaded = try await controller.useKey(lease) { verifiedKey, trustedScope in
            try reopened.load(scope: OutboxScope(accountID: trustedScope.accountID,
                conversationID: trustedScope.conversationID, keyEpoch: trustedScope.epoch),
                recordID: context.recordID, epochKey: verifiedKey)
        }
        XCTAssertEqual(try XCTUnwrap(loaded).envelope, envelope)
        await controller.signOut()
        do {
            _ = try await controller.useKey(lease) { verifiedKey, trustedScope in
                try reopened.enqueue(envelope: envelope, attachments: [], context: context,
                    scope: OutboxScope(accountID: trustedScope.accountID,
                        conversationID: trustedScope.conversationID, keyEpoch: trustedScope.epoch), epochKey: verifiedKey)
            }
            XCTFail("A lease from the signed-out session must not enqueue")
        } catch { XCTAssertEqual(error as? KeyLifecycleError, .staleSession) }
        XCTAssertTrue(try reopened.acknowledge(receipt))
    }

    func testDurableClosureSurvivesNewControllerAndOutbox() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = Data(repeating: 72, count: 32)
        let scope = KeyScope(accountID: "synthetic-a", conversationID: UUID().uuidString, epoch: 1)
        let descriptor = try TrustedKeyDescriptor(scope: scope,
            expectedKeyCommitment: TrustedKeyDescriptor.commitment(for: key, scope: scope))
        let controller = KeyReadinessController(reader: IntegrationKeyReader(bytes: key))
        let token = try await controller.activate(descriptor)
        let outbox = try DurableCiphertextOutbox(directory: directory)
        try outbox.closeConversation(accountID: scope.accountID, conversationID: scope.conversationID)
        try await controller.closeConversation(token: token)
        // A new process loses the actor's memory, so the durable outbox is a separate required gate.
        let freshController = KeyReadinessController(reader: IntegrationKeyReader(bytes: key))
        let freshToken = try await freshController.activate(descriptor)
        guard case .ready(let lease) = await freshController.read(token: freshToken) else {
            return XCTFail("A readable key alone does not establish an open conversation")
        }
        outbox.close()
        let reopened = try DurableCiphertextOutbox(directory: directory)
        let context = try RecordContext(conversationID: scope.conversationID, recordID: "late-message",
            senderID: scope.accountID, keyEpoch: scope.epoch, revision: 1)
        let envelope = try MessageCipher.seal(MessagePayload(text: "must never queue"), context: context,
            epochKey: SymmetricKey(data: key))
        do {
            _ = try await freshController.useKey(lease) { verifiedKey, trustedScope in
                try reopened.enqueue(envelope: envelope, attachments: [], context: context,
                    scope: OutboxScope(accountID: trustedScope.accountID,
                        conversationID: trustedScope.conversationID, keyEpoch: trustedScope.epoch), epochKey: verifiedKey)
            }
            XCTFail("Persisted closure must reject a fresh controller's otherwise valid key")
        } catch { XCTAssertEqual(error as? OutboxError, .closedConversation) }
    }
}

private struct IntegrationKeyReader: EpochKeyReader {
    let bytes: Data
    func read(scope: KeyScope) async -> EpochKeyReadResult { .found(bytes) }
}
