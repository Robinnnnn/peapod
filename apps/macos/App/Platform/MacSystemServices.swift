import AppKit

@MainActor
final class MacClipboard: ClipboardProviding {
    func setURLText(_ value: String) {
        let item = NSPasteboardItem()
        item.setString(value, forType: .URL)
        item.setString(value, forType: .string)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }

    func setString(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

@MainActor
final class MacDeviceIdentity: DeviceIdentityProviding {
    private static let defaultsKey = "mines.device-identity"

    var identifier: String {
        if let saved = UserDefaults.standard.string(
            forKey: Self.defaultsKey
        ) {
            return saved
        }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: Self.defaultsKey)
        return created
    }

    let platform = ClientPlatform.macOS
}

@MainActor
final class MacApplicationSettingsOpener: ApplicationSettingsOpening {
    func openApplicationSettings() {
        NSApplication.shared.sendAction(
            Selector(("showSettingsWindow:")),
            to: nil,
            from: nil
        )
    }
}
