import CryptoKit
import Foundation
import MinesE2EE

/// FCM values are strings. Never infer key scope from an envelope or accept alternate IDs.
struct EncryptedNotificationPreviewRequest: Sendable {
    let context: RecordContext
    let ciphertext: Data

    init?(userInfo: [AnyHashable: Any]) {
        guard userInfo["type"] as? String == "encrypted",
              let conversation = userInfo["conversationId"] as? String,
              let message = userInfo["messageId"] as? String,
              [conversation, message].allSatisfy({ UUID(uuidString: $0)?.uuidString.lowercased() == $0 }),
              let sender = userInfo["senderId"] as? String,
              let epochString = userInfo["keyEpoch"] as? String,
              let epoch = UInt32(epochString), epoch > 0, String(epoch) == epochString,
              userInfo["revision"] as? String == "1",
              let encoded = userInfo["notificationPreview"] as? String,
              encoded.utf8.count <= ((NotificationPreviewCipher.maximumEnvelopeBytes + 2) / 3) * 4,
              let ciphertext = Data(base64Encoded: encoded), !ciphertext.isEmpty,
              ciphertext.count <= NotificationPreviewCipher.maximumEnvelopeBytes,
              ciphertext.base64EncodedString() == encoded,
              let context = try? RecordContext(conversationID: conversation, recordID: message,
                  senderID: sender, keyEpoch: epoch, revision: 1) else { return nil }
        self.context = context
        self.ciphertext = ciphertext
    }
}

/// Routing is local and ephemeral; the authenticated Keychain capsule supplies the trust/key.
struct NotificationPreviewTarget: Sendable, Equatable {
    let accountID: String
    let conversationID: String
    let keyEpoch: UInt32
    let members: [String]
    let generation: UUID

    static func == (lhs: Self, rhs: Self) -> Bool {
        Data(lhs.accountID.utf8) == Data(rhs.accountID.utf8)
            && Data(lhs.conversationID.utf8) == Data(rhs.conversationID.utf8)
            && lhs.keyEpoch == rhs.keyEpoch && lhs.generation == rhs.generation
            && lhs.members.map { Data($0.utf8) } == rhs.members.map { Data($0.utf8) }
    }
}

struct ResolvedNotificationPreview: Sendable {
    let body: String
    let isCurrent: @Sendable () -> Bool
}

struct EncryptedNotificationPreviewResolver: Sendable {
    let currentTarget: @Sendable () throws -> NotificationPreviewTarget?
    let readCapsule: @Sendable (KeyScope) async throws -> StoredConversationCapsule?

    static let live = Self(currentTarget: {
        Self.target(from: try SharedConversationStore.currentTarget())
    }, readCapsule: { scope in
        let namespace = try BuildIdentity.keychainNamespace()
        return try await ConversationCapsuleStore(namespace: namespace).readCapsule(scope: scope)
    })

    /// Both native notification services read the same active App Group route.
    /// The authenticated capsule remains the authority for preview content.
    static func target(from shared: SharedConversationTarget?) -> NotificationPreviewTarget? {
        guard let shared, shared.mode == .encrypted, let epoch = shared.keyEpoch else { return nil }
        return NotificationPreviewTarget(accountID: shared.accountID, conversationID: shared.conversationID,
            keyEpoch: epoch, members: shared.members, generation: shared.generation)
    }

    func resolve(_ request: EncryptedNotificationPreviewRequest) async -> ResolvedNotificationPreview? {
        do {
            let context = request.context
            guard let target = try currentTarget(), target.keyEpoch == context.keyEpoch,
                  same(target.conversationID, context.conversationID),
                  !same(target.accountID, context.senderID), target.members.count == 2,
                  target.members.contains(where: { same($0, target.accountID) }),
                  target.members.contains(where: { same($0, context.senderID) }),
                  let capsule = try await readCapsule(KeyScope(accountID: target.accountID,
                      conversationID: target.conversationID, epoch: target.keyEpoch)),
                  same(capsule.localAccountID, target.accountID), same(capsule.conversationID, target.conversationID),
                  capsule.keyEpoch == target.keyEpoch, capsule.suite == StoredConversationCapsule.contentSuite,
                  Set([Data(capsule.creatorID.utf8), Data(capsule.recipientID.utf8)]) == Set(target.members.map { Data($0.utf8) }),
                  try currentTarget() == target else { return nil }
            let body = try NotificationPreviewCipher.open(request.ciphertext, messageContext: context,
                epochKey: SymmetricKey(data: capsule.keyMaterialForLocalStorage()))
            // Sign-out/reset/account switching clears or replaces the target. Never release a
            // result from the earlier asynchronous key read into that new session.
            guard try currentTarget() == target else { return nil }
            return ResolvedNotificationPreview(body: body, isCurrent: {
                (try? currentTarget()) == target
            })
        } catch {
            // No key waits, network, plaintext fallback, logging or mutation of key storage.
            return nil
        }
    }

    private func same(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.elementsEqual(rhs.utf8) }
}
