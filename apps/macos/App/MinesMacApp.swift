import AppKit
import Foundation
import SwiftUI

@main
struct PeapodMacApp: App {
    @NSApplicationDelegateAdaptor(MacApplicationDelegate.self)
    private var applicationDelegate
    @State private var model: MacAppModel?

    init() {

        MacFirebaseCapabilityProbe.verifyImportSurface()

        let firebaseIsConfigured = FirebaseBootstrap.configureIfPossible()
        if firebaseIsConfigured {
            MacPushNotificationCoordinator.shared
                .connectFirebaseMessaging()
            _model = State(
                initialValue: MacAppModel(
                    auth: FirebaseAuthService(),
                    pairing: FirebasePairingService(),
                    messaging: FirestoreMessagingService(),
                    profiles: FirebaseProfileService(),
                    attachments: FirebaseAttachmentService(),
                    encryption: EncryptedAppServices(),
                    legacyRouting: nil,
                    usesFirebase: true
                )
            )
        } else {
            _model = State(
                initialValue: MacAppModel(
                    auth: LocalAuthService(),
                    pairing: LocalPairingService(),
                    messaging: LocalMessagingService(),
                    profiles: LocalProfileService(),
                    attachments: LocalAttachmentService(),
                    usesFirebase: false,
                    configurationIssue: Self.configurationIssue
                )
            )
        }
    }

    var body: some Scene {
        WindowGroup {
            appRoot
        }
        .defaultSize(width: 680, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            if let model { MacSettingsView().environment(model) }
        }
    }

    @ViewBuilder
    private var appRoot: some View {
        if let model {
            MacRootView().environment(model)
                .task { await model.start(); await model.configureNotifications() }
                .onOpenURL { model.handle($0) }
        }
    }

    private static var configurationIssue: String? {
        """
        This build is missing its Firebase configuration. Rebuild Peapod \
        with GoogleService-Info.plist included.
        """
    }

}

private struct MacSettingsView: View {
    @Environment(MacAppModel.self) private var model

    var body: some View {
        Form {
            LabeledContent("App", value: "Peapod messenger")
            LabeledContent("Platform", value: "Native macOS")
            LabeledContent(
                "Connection",
                value: model.usesFirebase ? "Firebase" : "Not configured"
            )
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding()
    }
}
