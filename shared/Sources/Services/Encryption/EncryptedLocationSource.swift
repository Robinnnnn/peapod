import Foundation
#if os(iOS)
import UIKit
#endif

/// A writer capability is captured when a location session begins. A later revision conflict
/// never authorizes a different source generation. The identifier is local to the phone,
/// deliberately independent of the synchronizable conversation capsule and copied defaults.
struct EncryptedLocationSourceLease: Sendable, Equatable {
    static let unclaimedDeviceID = "unclaimed-location-source"
    let deviceID: String
    let generation: UInt64
    var isValid: Bool {
        Self.validDeviceID(deviceID) && generation > 0 && generation <= 9_007_199_254_740_991
    }
    static func validDeviceID(_ value: String) -> Bool {
        (16...128).contains(value.utf8.count)
            && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }
}

@MainActor enum EncryptedLocationDeviceIdentity {
    static var current: String? {
#if os(iOS)
        // IDFV is device-specific and is not restored from this app's defaults backup.
        // An unavailable/changed ID never silently inherits the former phone's ownership.
        UIDevice.current.identifierForVendor?.uuidString.lowercased()
#else
        nil // Native Mac is a viewer. Synthetic publishers must explicitly inject an identity.
#endif
    }
}
