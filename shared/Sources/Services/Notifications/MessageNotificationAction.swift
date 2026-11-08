import Foundation

enum MessageNotificationAction: Equatable, Sendable {
    case open(conversationID: String?, messageID: String?)
    case reply(
        text: String,
        conversationID: String?,
        messageID: String?
    )
    case markRead(conversationID: String?, messageID: String?)
}
