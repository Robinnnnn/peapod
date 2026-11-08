import Foundation

enum DistanceText {
    static func string(meters: Double) -> String {
        "\(measurement(meters: meters)) from you"
    }

    static func awayString(meters: Double) -> String {
        "\(measurement(meters: meters)) away"
    }

    private static func measurement(meters: Double) -> String {
        let nonnegativeMeters = max(0, meters)
        let feet = nonnegativeMeters * 3.280_839_895

        if feet < 1_000 {
            let roundedFeet = max(10, (feet / 10).rounded() * 10)
            return "\(Int(roundedFeet)) ft"
        }

        let miles = nonnegativeMeters / 1_609.344
        if miles < 10 {
            return "\(miles.formatted(.number.precision(.fractionLength(1)))) mi"
        }
        return "\(miles.formatted(.number.precision(.fractionLength(0)))) mi"
    }
}
