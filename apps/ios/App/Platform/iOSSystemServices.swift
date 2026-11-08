import UIKit

@MainActor
final class IOSClipboard: ClipboardProviding {
    func setString(_ value: String) {
        UIPasteboard.general.string = value
    }
}

@MainActor
final class IOSDeviceIdentity: DeviceIdentityProviding {
    private static let defaultsKey = "mines.device-identity"

    var identifier: String {
        if let vendorID = UIDevice.current.identifierForVendor?.uuidString {
            return vendorID
        }
        if let saved = UserDefaults.standard.string(
            forKey: Self.defaultsKey
        ) {
            return saved
        }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: Self.defaultsKey)
        return created
    }

    let platform = ClientPlatform.iOS
}

@MainActor
final class IOSApplicationSettingsOpener: ApplicationSettingsOpening {
    func openApplicationSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            return
        }
        UIApplication.shared.open(url)
    }
}
