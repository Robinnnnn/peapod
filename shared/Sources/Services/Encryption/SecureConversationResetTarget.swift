import Foundation

/// Non-secret confirmation scope. A dialog cannot authorize a later account/session/conversation.
struct SecureConversationResetTarget: Equatable {
    let accountID: String
    let conversationID: String
    let sessionID: UUID
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.accountID.utf8.elementsEqual(rhs.accountID.utf8)
            && lhs.conversationID.utf8.elementsEqual(rhs.conversationID.utf8)
            && lhs.sessionID == rhs.sessionID
    }
}
