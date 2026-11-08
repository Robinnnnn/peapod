import CoreLocation
import Foundation

/// A single replaceable location sample. Publishers should overwrite the
/// session's previous point rather than append it to a location history.
struct LiveLocationPoint: Codable, Hashable, Sendable {
    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: Double
    let recordedAt: Date

    init(location: CLLocation) {
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        horizontalAccuracy = location.horizontalAccuracy
        recordedAt = location.timestamp
    }

    init(
        latitude: Double,
        longitude: Double,
        horizontalAccuracy: Double,
        recordedAt: Date
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.recordedAt = recordedAt
    }

    var location: CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(
                latitude: latitude,
                longitude: longitude
            ),
            altitude: 0,
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: -1,
            timestamp: recordedAt
        )
    }

    var isValid: Bool {
        horizontalAccuracy >= 0
            && CLLocationCoordinate2DIsValid(location.coordinate)
    }

    /// Returns straight-line distance, ready to pass to `DistanceText.string`.
    func distance(from other: LiveLocationPoint) -> CLLocationDistance {
        location.distance(from: other.location)
    }
}
