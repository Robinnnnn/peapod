import SwiftUI

@main
struct PeapodApp: App {
    @UIApplicationDelegateAdaptor(NotificationAppDelegate.self)
    private var notificationAppDelegate
    @State private var model: AppModel?

    init() {

        let firebaseIsConfigured = FirebaseBootstrap.configureIfPossible()
        let auth: any AuthProviding
        let pairing: any PairingProviding
        let messaging: any MessagingProviding
        let profiles: any ProfileProviding
        let attachments: any AttachmentProviding
        let connectionLocations: any ConnectionLocationProviding
        let configurationIssue: String?

        if firebaseIsConfigured {
            PushNotificationCoordinator.shared.connectFirebaseMessaging()
            auth = FirebaseAuthService()
            pairing = FirebasePairingService()
            messaging = FirestoreMessagingService()
            profiles = FirebaseProfileService()
            attachments = FirebaseAttachmentService()
            connectionLocations = FirestoreConnectionLocationService()
            configurationIssue = nil
        } else {
            auth = LocalAuthService()
            pairing = LocalPairingService()
            messaging = LocalMessagingService()
            profiles = LocalProfileService()
            attachments = LocalAttachmentService()
            connectionLocations = LocalConnectionLocationService()
            configurationIssue = """
            This build is missing its Firebase configuration. Rebuild Peapod \
            with GoogleService-Info.plist included.
            """
        }

        _model = State(
            initialValue: AppModel(
                auth: auth,
                pairing: pairing,
                messaging: messaging,
                profiles: profiles,
                attachments: attachments,
                encryption: firebaseIsConfigured ? EncryptedAppServices() : nil,
                legacyRouting: nil,
                usesFirebase: firebaseIsConfigured,
                configurationIssue: configurationIssue,
                connectionLocations: connectionLocations
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            appRoot
        }
    }

    @ViewBuilder
    private var appRoot: some View {
        if let model {
            RootView()
                .environment(model)
                .task { await model.start() }
                .onOpenURL { model.handle($0) }
        }
    }

}
