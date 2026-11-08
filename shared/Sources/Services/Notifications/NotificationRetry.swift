import Foundation

struct NotificationRetryConfiguration: Sendable {
    let delays: [Duration]
    let sleep: @Sendable (Duration) async throws -> Void

    static let production = NotificationRetryConfiguration(
        delays: [
            .seconds(1),
            .seconds(4),
            .seconds(15),
        ],
        sleep: { duration in
            try await Task.sleep(for: duration)
        }
    )
}

@MainActor
enum BoundedNotificationRetry {
    static func run(
        configuration: NotificationRetryConfiguration,
        operation: @escaping @MainActor () async throws -> Void
    ) async throws {
        var retryIndex = 0

        while true {
            do {
                try await operation()
                return
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else {
                    throw CancellationError()
                }
                guard retryIndex < configuration.delays.count else {
                    throw error
                }

                let delay = configuration.delays[retryIndex]
                retryIndex += 1
                try await configuration.sleep(delay)
            }
        }
    }
}
