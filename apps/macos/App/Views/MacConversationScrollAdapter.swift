import Foundation
import Observation
import SwiftUI

/// The renderer owns scrolling, including lazy-row realization and late image
/// sizing. This module owns intent; it never writes an NSClipView's bounds.
/// ScrollPosition's edge/identity retention is documented at:
/// https://developer.apple.com/documentation/swiftui/scrollposition
@MainActor
@Observable
final class MacConversationScrollAdapter {
    var rendererPosition = ScrollPosition(idType: UUID.self, edge: .bottom) {
        didSet {
            if rendererPosition.isPositionedByUser {
                followsLatest = false
                pendingReplyID = nil
            }
        }
    }

    @ObservationIgnored private var followsLatest = true
    @ObservationIgnored private var isRecent = true
    @ObservationIgnored private var latestIsVisible = false
    @ObservationIgnored private var isUserScrolling = false
    @ObservationIgnored private var query = ""
    @ObservationIgnored private var rowMembers: [UUID: [UUID]] = [:]
    @ObservationIgnored private var rowOrder: [UUID] = []
    @ObservationIgnored private var visibleIDs: Set<UUID> = []
    @ObservationIgnored private var pendingReplyID: UUID?
    @ObservationIgnored private var normalPosition: ScrollPosition?
    @ObservationIgnored private var normalFollowsLatest = true

    func update(rowMembers: [UUID: [UUID]], isRecent: Bool, rowOrder: [UUID] = []) {
        self.rowMembers = rowMembers
        self.isRecent = isRecent
        self.rowOrder = rowOrder
        contentDidChange()
    }

    func visibleRowsDidChange(_ ids: [UUID]) {
        visibleIDs = Set(ids)
    }

    func searchDidChange(_ text: String) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized != query else { return }
        pendingReplyID = nil
        if !normalized.isEmpty {
            if query.isEmpty {
                normalPosition = rendererPosition
                normalFollowsLatest = followsLatest
            }
            followsLatest = false
            rendererPosition = ScrollPosition(idType: UUID.self, edge: .top)
        } else {
            let restored = normalPosition
            normalPosition = nil
            rendererPosition = restored ?? ScrollPosition(idType: UUID.self, edge: .bottom)
            followsLatest = normalFollowsLatest
        }
        query = normalized
        contentDidChange()
    }

    func geometryDidChange(isAtLatest: Bool) {
        // Passive changes in estimated height do not change the reader's intent.
        latestIsVisible = isAtLatest
    }

    func userScrollDidChange(isScrolling: Bool) {
        let wasScrolling = isUserScrolling
        isUserScrolling = isScrolling
        if isScrolling {
            followsLatest = false
            pendingReplyID = nil
        } else if wasScrolling, latestIsVisible, isRecent, query.isEmpty {
            requestLatest()
        }
    }

    func requestLatest() {
        pendingReplyID = nil
        followsLatest = true
        if !query.isEmpty {
            normalPosition = ScrollPosition(idType: UUID.self, edge: .bottom)
            normalFollowsLatest = true
        }
        contentDidChange()
    }

    func requestReply(_ id: UUID) {
        followsLatest = false
        pendingReplyID = id
        contentDidChange()
    }

    func requestHistoryPage() {
        followsLatest = false
        pendingReplyID = nil
        // A user-positioned binding already retains its identified row. When a
        // short window is edge-pinned, turn its visible identity into the anchor
        // before inserting a page; do not retain a bottom-edge instruction.
        if rendererPosition.edge != nil,
           let first = rowOrder.first(where: { visibleIDs.contains($0) }) {
            rendererPosition.scrollTo(id: first)
        }
    }

    func contentDidChange() {
        guard !isUserScrolling, query.isEmpty else { return }
        if let pendingReplyID,
           let row = Self.rowID(containing: pendingReplyID, rowMembers: rowMembers) {
            rendererPosition.scrollTo(id: row, anchor: .center)
            self.pendingReplyID = nil
        } else if followsLatest, isRecent, rendererPosition.edge != .bottom {
            rendererPosition.scrollTo(edge: .bottom)
        }
    }

    static func rowID(containing messageID: UUID, rowMembers: [UUID: [UUID]]) -> UUID? {
        if rowMembers[messageID] != nil { return messageID }
        return rowMembers.first { $0.value.contains(messageID) }?.key
    }
}
