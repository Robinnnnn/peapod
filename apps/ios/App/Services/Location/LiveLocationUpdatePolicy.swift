import Foundation

/// Filters noisy or overly frequent GPS samples before they are published.
///
/// Movement can trigger an update after `minimumTimeInterval`; otherwise a
/// fresh point is forced at `maximumTimeInterval` so a stationary person's
/// location does not appear stale.
struct LiveLocationUpdatePolicy: Hashable, Sendable {
    var minimumTimeInterval: TimeInterval
    var maximumTimeInterval: TimeInterval
    var minimumDistance: Double
    var maximumHorizontalAccuracy: Double

    static let batteryBalanced = LiveLocationUpdatePolicy(
        minimumTimeInterval: 20,
        maximumTimeInterval: 120,
        minimumDistance: 40,
        maximumHorizontalAccuracy: 100
    )

    init(
        minimumTimeInterval: TimeInterval,
        maximumTimeInterval: TimeInterval,
        minimumDistance: Double,
        maximumHorizontalAccuracy: Double
    ) {
        precondition(minimumTimeInterval >= 0)
        precondition(maximumTimeInterval >= minimumTimeInterval)
        precondition(minimumDistance >= 0)
        precondition(maximumHorizontalAccuracy >= 0)

        self.minimumTimeInterval = minimumTimeInterval
        self.maximumTimeInterval = maximumTimeInterval
        self.minimumDistance = minimumDistance
        self.maximumHorizontalAccuracy = maximumHorizontalAccuracy
    }

    func shouldPublish(
        _ candidate: LiveLocationPoint,
        after previous: LiveLocationPoint?
    ) -> Bool {
        guard candidate.isValid,
              candidate.horizontalAccuracy <= maximumHorizontalAccuracy
        else {
            return false
        }

        guard let previous else {
            return true
        }

        let elapsed = candidate.recordedAt.timeIntervalSince(previous.recordedAt)
        guard elapsed >= minimumTimeInterval else {
            return false
        }

        if elapsed >= maximumTimeInterval {
            return true
        }

        return candidate.distance(from: previous) >= minimumDistance
    }
}
