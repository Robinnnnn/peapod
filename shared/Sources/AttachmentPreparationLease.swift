import Foundation

/// Captured before asynchronous media loading. The owning model supplies a
/// byte-exact account/conversation/session predicate; invalidation is irreversible.
@MainActor
final class AttachmentPreparationLease {
    private let sessionIsCurrent: @MainActor () -> Bool
    private var revoked = false
    init(isCurrent: @escaping @MainActor () -> Bool) { sessionIsCurrent = isCurrent }
    var isCurrent: Bool { !revoked && sessionIsCurrent() }
    func invalidate() { revoked = true }
    func checkCurrent() throws {
        guard isCurrent, !Task.isCancelled else { throw CancellationError() }
    }
    func load<Value>(_ operation: @MainActor () async throws -> Value) async throws -> Value {
        try checkCurrent()
        do {
            let value = try await operation()
            try checkCurrent()
            return value
        } catch {
            // A late load error belongs to the revoked operation, not the new UI.
            try checkCurrent()
            throw error
        }
    }
    func stage<Value>(_ operation: () throws -> Value, accepts: (Value) -> Bool,
                      discard: (Value) -> Void) throws -> Value {
        try checkCurrent()
        let value: Value
        do { value = try operation() }
        catch { try checkCurrent(); throw error }
        guard isCurrent, !Task.isCancelled, accepts(value) else {
            discard(value) // Only the exact object created by this operation.
            throw CancellationError()
        }
        return value
    }
}
