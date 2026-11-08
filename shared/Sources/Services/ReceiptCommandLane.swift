import Foundation

/// Serializes commands touching one receipt document within this provider instance.
/// Server transactions still enforce monotonic positions and authorization across devices.
/// No successful command is cached, retried, or combined with another receipt field.
@MainActor
final class ReceiptCommandLane {
    enum Failure: LocalizedError {
        case capacityExceeded, invalidScope

        var errorDescription: String? {
            switch self {
            case .capacityExceeded: "Too many receipt updates are waiting. Please try again."
            case .invalidScope: "The receipt scope is not valid."
            }
        }
    }

    private struct Scope: Hashable, Sendable {
        let conversation: Data
        let user: Data
    }
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private struct Lane {
        var owner: UUID
        var waiters: [Waiter] = []
    }

    private let maximumCommands: Int
    private var lanes: [Scope: Lane] = [:]
    private(set) var commandCount = 0

    init(maximumCommands: Int = 64) {
        precondition((1...64).contains(maximumCommands))
        self.maximumCommands = maximumCommands
    }

    func perform(conversationID: String, userID: String,
                 operation: @MainActor () async throws -> Void) async throws {
        // Firestore document IDs have a 1,500-byte limit. Bound key allocation too.
        guard !conversationID.isEmpty, !userID.isEmpty,
              conversationID.utf8.count <= 1_500, userID.utf8.count <= 1_500 else {
            throw Failure.invalidScope
        }
        let scope = Scope(conversation: Data(conversationID.utf8), user: Data(userID.utf8))
        let id = UUID()
        try await acquire(scope: scope, id: id)
        defer { release(scope: scope, id: id) }
        try Task.checkCancellation()
        try await operation()
    }

    private func acquire(scope: Scope, id: UUID) async throws {
        try Task.checkCancellation()
        guard commandCount < maximumCommands else { throw Failure.capacityExceeded }
        commandCount += 1
        guard lanes[scope] != nil else {
            lanes[scope] = Lane(owner: id)
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    commandCount -= 1
                    continuation.resume(throwing: CancellationError())
                } else if var lane = lanes[scope] {
                    lane.waiters.append(Waiter(id: id, continuation: continuation))
                    lanes[scope] = lane
                } else {
                    lanes[scope] = Lane(owner: id)
                    continuation.resume()
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancelWaiter(scope: scope, id: id) }
        }
    }

    private func cancelWaiter(scope: Scope, id: UUID) {
        guard var lane = lanes[scope], let index = lane.waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = lane.waiters.remove(at: index)
        lanes[scope] = lane
        commandCount -= 1
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release(scope: Scope, id: UUID) {
        guard var lane = lanes[scope], lane.owner == id else { return }
        commandCount -= 1
        if lane.waiters.isEmpty {
            lanes[scope] = nil
        } else {
            let next = lane.waiters.removeFirst()
            lane.owner = next.id
            lanes[scope] = lane
            next.continuation.resume()
        }
    }
}
