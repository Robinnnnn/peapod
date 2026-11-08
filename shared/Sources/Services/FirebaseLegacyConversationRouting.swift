@preconcurrency import FirebaseAuth
@preconcurrency import FirebaseFirestore
import Foundation
import MinesE2EE

@MainActor
extension LegacyConversationTargetPublisher {
    static func native(auth: Auth = .auth(), database: Firestore = .firestore()) -> LegacyConversationTargetPublisher {
        LegacyConversationTargetPublisher(dependencies: .init(currentAccountID: { auth.currentUser?.uid },
            readTarget: SharedConversationStore.currentTarget,
            publish: SharedConversationStore.publishTrusted,
            clear: { try SharedConversationStore.clearActiveTarget(accountID: $0) },
            requiresEncryption: SharedConversationStore.requiresEncryption,
            verify: { accountID, conversationID in
                func checkAccount() throws {
                    guard auth.currentUser?.uid.utf8.elementsEqual(accountID.utf8) == true else {
                        throw LegacyConversationTargetError.assignmentChanged
                    }
                }
                try checkAccount()
                guard try !SharedConversationStore.requiresEncryption(accountID: accountID) else {
                    throw LegacyConversationTargetError.encryptionRequired
                }
                let profile = try await database.collection("users").document(accountID).getDocument(source: .server).data()
                try checkAccount()
                do {
                    try LegacyConversationTargetValidation.validateProfile(accountID: accountID,
                        conversationID: conversationID, profile: profile)
                } catch LegacyConversationTargetError.encryptionRequired {
                    try SharedConversationStore.markEncryptionRequired(accountID: accountID)
                    throw LegacyConversationTargetError.encryptionRequired
                }
                let conversation = try await database.collection("conversations").document(conversationID).getDocument(source: .server).data()
                try checkAccount()
                do {
                    // Validate remote markers before a possibly unavailable Keychain read.
                    _ = try LegacyConversationTargetValidation.target(accountID: accountID, conversationID: conversationID,
                        profile: profile, conversation: conversation, hasSyncedCapsule: false)
                    var hasCapsule = false
                    if UUID(uuidString: conversationID)?.uuidString.lowercased() == conversationID {
                        let namespace = try ConversationKeychainNamespace(productionAccessGroup: EncryptedAppServices.keychainAccessGroup)
                        let store = ConversationCapsuleStore(namespace: namespace)
                        hasCapsule = try await store.readCapsule(scope: KeyScope(accountID: accountID, conversationID: conversationID, epoch: 1)) != nil
                        try checkAccount()
                    }
                    return try LegacyConversationTargetValidation.target(accountID: accountID, conversationID: conversationID,
                        profile: profile, conversation: conversation, hasSyncedCapsule: hasCapsule)
                } catch LegacyConversationTargetError.encryptionRequired {
                    try SharedConversationStore.markEncryptionRequired(accountID: accountID)
                    throw LegacyConversationTargetError.encryptionRequired
                }
            }))
    }
}

/// Synchronous dispatch guard for legacy plaintext writers. No network lookup and no metadata
/// receipt/typing restriction: encrypted services intentionally share those metadata providers.
@MainActor
enum LegacyContentWriteGuard {
    static func require(conversationID: String, accountID: String? = nil) throws {
        guard let current = Auth.auth().currentUser?.uid,
              accountID.map({ $0.utf8.elementsEqual(current.utf8) }) ?? true else {
            throw LegacyConversationTargetError.assignmentChanged
        }
        try LegacyConversationTargetValidation.requireLegacyRoute(target: SharedConversationStore.currentTarget(),
            accountID: current, conversationID: conversationID,
            requiresEncryption: SharedConversationStore.requiresEncryption(accountID: current))
    }
}
