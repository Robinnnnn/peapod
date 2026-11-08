import UIKit

/// APNs delivers its device token through UIApplicationDelegate even in a
/// SwiftUI lifecycle app. Install this with `@UIApplicationDelegateAdaptor`.
@MainActor
final class NotificationAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [
            UIApplication.LaunchOptionsKey: Any
        ]? = nil
    ) -> Bool {
        PushNotificationCoordinator.shared.prepareForLaunch()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        PushNotificationCoordinator.shared.didRegisterForRemoteNotifications(
            deviceToken: deviceToken
        )
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        PushNotificationCoordinator.shared.didFailToRegisterForRemoteNotifications(
            error: error
        )
    }
}
