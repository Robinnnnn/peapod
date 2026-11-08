import Foundation

/// Only modal surfaces covering or blocking the conversation suppress reading.
/// Menus, reaction pickers and timestamp reveals leave the timeline visible.
enum MacConversationObscuration: Hashable {
    case partnerDetails
    case messageEditor
    case attachmentImporter
    case attachmentPreview
    case confirmation
}

struct MacConversationReadVisibility {
    var isVisible = false
    var isAppActive = true
    var isAtLatest = false
    var isRecent = true
    var isSearching = false
    var obscurations: Set<MacConversationObscuration> = []

    var suppressesForegroundAlerts: Bool {
        isVisible && isAppActive && obscurations.isEmpty
    }

    var allowsReadAcknowledgment: Bool {
        suppressesForegroundAlerts && isAtLatest && isRecent && !isSearching
    }
}
