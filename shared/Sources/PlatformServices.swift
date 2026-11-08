import Foundation

enum ClientPlatform: String, Sendable {
    case iOS = "ios"
    case macOS = "macos"
}

@MainActor
protocol ClipboardProviding: AnyObject {
    func setString(_ value: String)
}

@MainActor
protocol DeviceIdentityProviding: AnyObject {
    var identifier: String { get }
    var platform: ClientPlatform { get }
}

@MainActor
protocol ApplicationSettingsOpening: AnyObject {
    func openApplicationSettings()
}
