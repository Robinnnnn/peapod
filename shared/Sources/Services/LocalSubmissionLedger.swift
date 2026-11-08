import Foundation

enum PendingShareTimelineStatus: Hashable, Sendable {
    case waiting
    case sending
    case failed(String)

    var deliveryState: DeliveryState {
        switch self {
        case .waiting, .sending:
            .sending
        case .failed:
            .failed
        }
    }
}

/// Session-only presentation state. The durable outbox remains the delivery owner.
struct LocalSubmissionLedger {
    var displayDates: [UUID: Date] = [:]
    var pending: [UUID: ChatMessage] = [:]
    var observedIDs: Set<UUID> = []

    mutating func register(_ message: ChatMessage, after rows: [ChatMessage]) {
        if displayDates[message.id] == nil, !observedIDs.contains(message.id) {
            let latestRow = rows.last.map { displayDates[$0.id] ?? $0.createdAt } ?? .distantPast
            let latest = max(latestRow, displayDates.values.max() ?? .distantPast)
            displayDates[message.id] = max(message.createdAt, latest.addingTimeInterval(0.000_001))
        }
        if pending[message.id] != nil || !observedIDs.contains(message.id) {
            pending[message.id] = message
        }
    }

    mutating func observe(_ rows: [ChatMessage], queuedIDs: Set<UUID>) {
        observedIDs = Set(rows.map(\.id))
        for row in rows where row.deliveryState != .sending { pending[row.id] = nil }
        let retained = observedIDs.union(pending.keys).union(queuedIDs)
        displayDates = displayDates.filter { retained.contains($0.key) }
    }

    func ordered(_ rows: [ChatMessage]) -> [ChatMessage] {
        rows.enumerated().sorted { left, right in
            let lhs = displayDates[left.element.id] ?? left.element.createdAt
            let rhs = displayDates[right.element.id] ?? right.element.createdAt
            return lhs == rhs ? left.offset < right.offset : lhs < rhs
        }.map(\.element)
    }

    mutating func remove(_ id: UUID) { pending[id] = nil; displayDates[id] = nil }
}

/// Checked again immediately before each upload, including drains already in flight.
struct ComposerSubmissionFence {
    private(set) var waiting: Set<UUID> = []
    mutating func hold(_ ids: Set<UUID>) { waiting.formUnion(ids) }
    mutating func release(_ ids: Set<UUID>) { waiting.subtract(ids) }
    func allows(_ id: UUID) -> Bool { !waiting.contains(id) }
}
