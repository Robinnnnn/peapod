import CoreLocation
import Foundation

/// Explicit connection-level location state. Sharing intent and coordinate
/// freshness are deliberately independent: an old point remains useful and
/// honestly labeled until either person turns sharing off.
struct ConnectionLocationSnapshot: Equatable, Sendable {
    var sharingUserIDs: Set<String>
    var latestPoints: [String: LiveLocationPoint]
    var sourceDeviceIDs: [String: String] = [:]
    var sourceGenerations: [String: UInt64] = [:]

    static let empty = ConnectionLocationSnapshot(
        sharingUserIDs: [],
        latestPoints: [:]
    )

    func mutualPresentation(
        currentUserID: String,
        partnerID: String,
        now: Date = .now
    ) -> MutualLocationPresentation? {
        guard
            sharingUserIDs.contains(currentUserID),
            sharingUserIDs.contains(partnerID),
            let currentPoint = latestPoints[currentUserID],
            let partnerPoint = latestPoints[partnerID]
        else {
            return nil
        }

        return MutualLocationPresentation(
            currentUserPoint: currentPoint,
            partnerPoint: partnerPoint,
            distanceMeters: currentPoint.distance(from: partnerPoint),
            olderRecordedAt: min(
                currentPoint.recordedAt,
                partnerPoint.recordedAt
            ),
            now: now
        )
    }
}

struct MutualLocationPresentation: Equatable, Sendable {
    let currentUserPoint: LiveLocationPoint
    let partnerPoint: LiveLocationPoint
    let distanceMeters: CLLocationDistance
    let olderRecordedAt: Date
    let now: Date

    var distanceText: String {
        DistanceText.awayString(meters: distanceMeters)
    }

    var ageText: String? {
        LocationAgeText.string(
            since: olderRecordedAt,
            now: now
        )
    }

    var subtitle: String {
        guard let ageText else { return distanceText }
        return "\(distanceText) · \(ageText)"
    }
}

enum LocationAgeText {
    static func string(
        since date: Date,
        now: Date = .now
    ) -> String? {
        let elapsed = max(0, now.timeIntervalSince(date))
        guard elapsed >= 60 else { return nil }

        let minutes = Int(elapsed / 60)
        if minutes < 60 {
            return "\(minutes)m ago"
        }

        let hours = Int(elapsed / 3_600)
        if hours < 24 {
            return "\(hours)h ago"
        }

        return "\(Int(elapsed / 86_400))d ago"
    }
}
