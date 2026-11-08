import Foundation

enum MacConversationPresentation {
    static let reactionChoices = MessageReactionPalette.defaults

    static func reactionSummary(
        for reactions: [String: String],
        currentUserID: String
    ) -> [(emoji: String, count: Int, isCurrentUser: Bool)] {
        let counts = Dictionary(grouping: reactions, by: \.value)
        return counts.map { emoji, reactions in
            (
                emoji: emoji,
                count: reactions.count,
                isCurrentUser: reactions.contains {
                    $0.key == currentUserID
                }
            )
        }
        .sorted { lhs, rhs in
            let leftIndex =
                reactionChoices.firstIndex(of: lhs.emoji) ?? .max
            let rightIndex =
                reactionChoices.firstIndex(of: rhs.emoji) ?? .max
            return leftIndex == rightIndex
                ? lhs.emoji < rhs.emoji
                : leftIndex < rightIndex
        }
    }

    static func reactionAccessibilityLabel(
        emoji: String,
        count: Int,
        includesCurrentUser: Bool
    ) -> String {
        let noun = count == 1 ? "reaction" : "reactions"
        let ownership = includesCurrentUser
            ? ", including yours"
            : ""
        return "\(MessageReactionPalette.name(for: emoji)), \(count) \(noun)\(ownership)"
    }

    static func latestOutgoingMessageID(
        in messages: [ChatMessage],
        currentUserID: String
    ) -> UUID? {
        messages.last {
            $0.senderID == currentUserID && !$0.isUnsent
        }?.id
    }

    static func showsDeliveryStatus(
        for message: ChatMessage,
        latestOutgoingMessageID: UUID?,
        currentUserID: String
    ) -> Bool {
        message.senderID == currentUserID
            && (
                message.deliveryState == .failed
                    || message.id == latestOutgoingMessageID
            )
    }

    static func shouldShowDayHeader(
        at index: Int,
        in messages: [ChatMessage],
        calendar: Calendar = .current
    ) -> Bool {
        guard messages.indices.contains(index) else { return false }
        guard index > messages.startIndex else { return true }
        return !calendar.isDate(
            messages[index - 1].createdAt,
            inSameDayAs: messages[index].createdAt
        )
    }

    static func groupTailHasPersistentMetadata(
        at index: Int,
        in messages: [ChatMessage],
        latestOutgoingMessageID: UUID?,
        currentUserID: String
    ) -> Bool {
        guard messages.indices.contains(index) else { return false }

        var tailIndex = index
        while
            messages.indices.contains(tailIndex + 1),
            MessageGrouping.position(
                at: tailIndex,
                in: messages
            ).joinsNext
        {
            tailIndex += 1
        }

        let tailMessage = messages[tailIndex]
        let showsEditedStatus =
            !tailMessage.isUnsent && tailMessage.editedAt != nil
        return showsEditedStatus
            || showsDeliveryStatus(
                for: tailMessage,
                latestOutgoingMessageID: latestOutgoingMessageID,
                currentUserID: currentUserID
            )
    }

    static func dayTitle(
        for date: Date,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return "Today"
        }
        if
            let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(date, inSameDayAs: yesterday)
        {
            return "Yesterday"
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
