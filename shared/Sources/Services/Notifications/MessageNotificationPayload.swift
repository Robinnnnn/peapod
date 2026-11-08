import Foundation

/// The app-owned fields carried alongside the APNs `aps` dictionary.
struct MessageNotificationPayload: Equatable, Sendable {
    let senderID: String
    let senderName: String
    let conversationID: String?
    let messageID: String?

    init?(
        userInfo: [AnyHashable: Any],
        fallbackSenderName: String = "New message"
    ) {
        guard let senderID = Self.nonemptyString(
            in: userInfo,
            keys: ["senderId", "senderID"]
        ) else {
            return nil
        }

        self.senderID = senderID
        self.senderName = Self.nonemptyString(
            in: userInfo,
            keys: ["senderName"]
        ) ?? fallbackSenderName
        self.conversationID = Self.nonemptyString(
            in: userInfo,
            keys: ["conversationId", "conversationID"]
        )
        self.messageID = Self.nonemptyString(
            in: userInfo,
            keys: ["messageId", "messageID"]
        )
    }

    private static func nonemptyString(
        in userInfo: [AnyHashable: Any],
        keys: [String]
    ) -> String? {
        for key in keys {
            guard let value = userInfo[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }
}
