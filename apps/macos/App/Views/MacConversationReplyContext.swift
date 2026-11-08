import Foundation

/// A selected reply is a composer draft, not a member of the current history
/// page. Keep just its snapshot; accepted updates can refresh or tombstone it.
struct MacConversationReplyContext {
    private(set) var selectedID: UUID?
    private var pinnedMessage: ChatMessage?

    mutating func select(_ message: ChatMessage) {
        guard !message.isUnsent else { return }
        selectedID = message.id
        pinnedMessage = message
    }

    mutating func setSelectedID(_ id: UUID?) {
        if selectedID != id { pinnedMessage = nil }
        selectedID = id
    }

    mutating func clear() {
        selectedID = nil
        pinnedMessage = nil
    }

    func target(messages: [ChatMessage], context: [UUID: ChatMessage]) -> ChatMessage? {
        guard let selectedID else { return nil }
        let target = messages.first { $0.id == selectedID }
            ?? context[selectedID]
            ?? pinnedMessage.flatMap { $0.id == selectedID ? $0 : nil }
        return target?.isUnsent == true ? nil : target
    }

    mutating func accept(messages: [ChatMessage], context: [UUID: ChatMessage]) {
        guard let selectedID,
              let current = messages.first(where: { $0.id == selectedID }) ?? context[selectedID]
        else { return }
        if current.isUnsent { clear() }
        else { pinnedMessage = current }
    }
}
