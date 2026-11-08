import Foundation

/// Derived message data is rebuilt only when history or the search changes.
/// Composer, scroll, and interaction updates can reuse the same presentation.
struct ConversationTimelinePresentation {
    struct Row: Identifiable {
        let item: ConversationTimelineItem
        let message: ChatMessage
        let grouping: MessageGroupPosition
        let showsDayHeader: Bool

        var id: UUID { item.id }
        var topPadding: Double {
            showsDayHeader ? 0 : (grouping.joinsPrevious ? 3 : 13)
        }
    }

    let rows: [Row]
    let messagesByID: [UUID: ChatMessage]
    let scrollTargetsByMessageID: [UUID: UUID]
    let rowIndexesByID: [UUID: Int]
    let latestOutgoingMessageID: UUID?

    init(
        messages: [ChatMessage],
        replyContextMessages: [UUID: ChatMessage] = [:],
        searchText: String,
        currentUserID: String,
        calendar: Calendar = .current
    ) {
        var messageIndex = replyContextMessages
        for message in messages {
            messageIndex[message.id] = message
        }
        messagesByID = messageIndex
        let visibleMessages = searchText.isEmpty
            ? messages
            : messages.filter { $0.matchesSearch(searchText) }
        let items = PhotoMessagePresentation.timelineItems(
            from: visibleMessages
        )
        let displayedMessages = items.map(\.displayMessage)
        latestOutgoingMessageID =
            OutgoingDeliveryStatusVisibility.latestApplicableMessageID(
                in: displayedMessages,
                currentUserID: currentUserID
            )
        rows = items.enumerated().map { index, item in
            let message = displayedMessages[index]
            return Row(
                item: item,
                message: message,
                grouping: MessageGrouping.position(
                    at: index,
                    in: displayedMessages,
                    calendar: calendar
                ),
                showsDayHeader: index == 0 || !calendar.isDate(
                    displayedMessages[index - 1].createdAt,
                    inSameDayAs: message.createdAt
                )
            )
        }
        var scrollTargets: [UUID: UUID] = [:]
        var rowIndexes: [UUID: Int] = [:]
        for (index, item) in items.enumerated() {
            rowIndexes[item.id] = index
            scrollTargets[item.displayMessage.id] = item.id
            for message in item.photoGroup?.messages ?? [] {
                scrollTargets[message.id] = item.id
            }
        }
        scrollTargetsByMessageID = scrollTargets
        rowIndexesByID = rowIndexes
    }
}

final class ConversationTimelinePresentationCache {
    private var revision: Int?
    private var searchText: String?
    private var currentUserID: String?
    private var calendar: Calendar?
    private var presentation: ConversationTimelinePresentation?
    private(set) var rebuildCount = 0

    func value(
        messages: [ChatMessage],
        replyContextMessages: [UUID: ChatMessage] = [:],
        revision: Int,
        searchText: String,
        currentUserID: String,
        calendar: Calendar = .current
    ) -> ConversationTimelinePresentation {
        if
            self.revision == revision,
            self.searchText == searchText,
            self.currentUserID == currentUserID,
            self.calendar == calendar,
            let presentation
        {
            return presentation
        }
        let updated = ConversationTimelinePresentation(
            messages: messages,
            replyContextMessages: replyContextMessages,
            searchText: searchText,
            currentUserID: currentUserID,
            calendar: calendar
        )
        self.revision = revision
        self.searchText = searchText
        self.currentUserID = currentUserID
        self.calendar = calendar
        presentation = updated
        rebuildCount += 1
        return updated
    }
}
