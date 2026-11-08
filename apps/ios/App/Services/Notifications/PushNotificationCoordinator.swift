@preconcurrency import FirebaseMessaging
import UIKit
@preconcurrency import UserNotifications

@MainActor
protocol UserNotificationCenterControlling: AnyObject {
    var delegate: (any UNUserNotificationCenterDelegate)? { get set }

    func requestAuthorization(
        options: UNAuthorizationOptions
    ) async throws -> Bool
    func setNotificationCategories(
        _ categories: Set<UNNotificationCategory>
    )
    func removeAllDeliveredNotifications()
    func removeAllPendingNotificationRequests()
    func setBadgeCount(_ newBadgeCount: Int) async throws
}

extension UNUserNotificationCenter: UserNotificationCenterControlling {}

@MainActor
protocol PushNotificationCoordinating: AnyObject {
    func requestAuthorizationAndRegister() async throws -> Bool
    func setActiveConversationForForegroundNotifications(
        _ conversationID: String?
    )
    func setTokenHandler(
        _ handler: PushNotificationCoordinator.TokenHandler?
    )
    func setActionHandler(
        _ handler: PushNotificationCoordinator.ActionHandler?
    )
    func setRegistrationSuccessHandler(
        _ handler: PushNotificationCoordinator.RegistrationSuccessHandler?
    )
    func setRegistrationErrorHandler(
        _ handler: PushNotificationCoordinator.RegistrationErrorHandler?
    )
    func clearConversationNotifications() async
    func resetForSignOut() async
}

enum ForegroundNotificationPresentationPolicy {
    static let standardOptions: UNNotificationPresentationOptions = [
        .banner,
        .list,
        .sound,
        .badge,
    ]

    static func options(
        notificationConversationID: String?,
        activeConversationID: String?
    ) -> UNNotificationPresentationOptions {
        guard
            let notificationConversationID,
            let activeConversationID,
            notificationConversationID == activeConversationID
        else {
            return standardOptions
        }
        return []
    }
}

/// Owns notification permission, categories, Firebase token updates, and actions.
///
/// Call `connectFirebaseMessaging` only after Firebase has been configured. The
/// token handler can be installed later (for example, after authentication);
/// the latest token is retained and delivered when the handler becomes available.
@MainActor
final class PushNotificationCoordinator: NSObject {
    typealias TokenHandler = @MainActor @Sendable (String) async -> Void
    typealias ActionHandler = @MainActor @Sendable (MessageNotificationAction) async -> Void
    typealias RegistrationErrorHandler = @MainActor @Sendable (Error) async -> Void

    static let shared = PushNotificationCoordinator()

    static let messageCategoryIdentifier = "MESSAGE"
    static let replyActionIdentifier = "MESSAGE_REPLY"
    static let markReadActionIdentifier = "MESSAGE_MARK_READ"

    private let center: any UserNotificationCenterControlling
    private let registerForRemoteNotifications: @MainActor () -> Void
    private let unregisterForRemoteNotifications: @MainActor () -> Void
    private var latestFCMToken: String?
    private var tokenHandler: TokenHandler?
    private var actionHandler: ActionHandler?
    private var registrationSuccessHandler: RegistrationSuccessHandler?
    private var registrationErrorHandler: RegistrationErrorHandler?
    private var pendingActions: [MessageNotificationAction] = []
    private var activeConversationID: String?
    private var acceptsPendingActions = true

    typealias RegistrationSuccessHandler = @MainActor @Sendable () async -> Void

    init(
        center: any UserNotificationCenterControlling =
            UNUserNotificationCenter.current(),
        registerForRemoteNotifications: @escaping @MainActor () -> Void = {
            UIApplication.shared.registerForRemoteNotifications()
        },
        unregisterForRemoteNotifications: @escaping @MainActor () -> Void = {
            UIApplication.shared.unregisterForRemoteNotifications()
        }
    ) {
        self.center = center
        self.registerForRemoteNotifications = registerForRemoteNotifications
        self.unregisterForRemoteNotifications =
            unregisterForRemoteNotifications
        super.init()
    }

    /// Installs categories and asks for alert, sound, and badge permission.
    /// Registration with APNs is attempted only when notification permission is
    /// currently granted.
    @discardableResult
    func requestAuthorizationAndRegister() async throws -> Bool {
        prepareForLaunch()

        let granted = try await center.requestAuthorization(
            options: [.alert, .badge, .sound]
        )
        if granted {
            registerForRemoteNotifications()
        }
        return granted
    }

    /// This must run at process launch so iOS can deliver cold-launch actions
    /// before authentication and conversation setup have completed.
    func prepareForLaunch() {
        center.delegate = self
        installCategories()
    }

    /// Starts Firebase token observation. Firebase must already be configured.
    func connectFirebaseMessaging() {
        let messaging = Messaging.messaging()
        messaging.delegate = self
        if let token = messaging.fcmToken {
            receiveFCMToken(token)
        }
    }

    /// Attaches persistence after sign-in without losing a token obtained earlier.
    func setTokenHandler(_ handler: TokenHandler?) {
        tokenHandler = handler
        guard let handler, let latestFCMToken else { return }
        Task {
            await handler(latestFCMToken)
        }
    }

    func setActiveConversationForForegroundNotifications(
        _ conversationID: String?
    ) {
        activeConversationID = conversationID
    }

    func setActionHandler(_ handler: ActionHandler?) {
        actionHandler = handler
        if handler != nil {
            acceptsPendingActions = true
        }
        guard let handler, !pendingActions.isEmpty else { return }
        let actions = pendingActions
        pendingActions.removeAll()
        Task {
            for action in actions {
                await handler(action)
            }
        }
    }

    func setRegistrationSuccessHandler(
        _ handler: RegistrationSuccessHandler?
    ) {
        registrationSuccessHandler = handler
    }

    func setRegistrationErrorHandler(_ handler: RegistrationErrorHandler?) {
        registrationErrorHandler = handler
    }

    /// Forward the APNs callback here from `NotificationAppDelegate`.
    func didRegisterForRemoteNotifications(deviceToken: Data) {
        Messaging.messaging().apnsToken = deviceToken
        guard let registrationSuccessHandler else { return }
        Task {
            await registrationSuccessHandler()
        }
    }

    /// Forward the APNs failure callback here from `NotificationAppDelegate`.
    func didFailToRegisterForRemoteNotifications(error: Error) {
        guard let registrationErrorHandler else { return }
        Task {
            await registrationErrorHandler(error)
        }
    }

    func clearBadge() async {
        try? await center.setBadgeCount(0)
    }

    func clearConversationNotifications() async {
        activeConversationID = nil
        pendingActions.removeAll()
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
        await clearBadge()
    }

    func resetForSignOut() async {
        await clearConversationNotifications()
        acceptsPendingActions = false
        setTokenHandler(nil)
        setActionHandler(nil)
        setRegistrationSuccessHandler(nil)
        setRegistrationErrorHandler(nil)
        unregisterForRemoteNotifications()
    }

    private func installCategories() {
        let reply = UNTextInputNotificationAction(
            identifier: Self.replyActionIdentifier,
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Message"
        )
        let markRead = UNNotificationAction(
            identifier: Self.markReadActionIdentifier,
            title: "Mark as Read",
            options: []
        )
        let message = UNNotificationCategory(
            identifier: Self.messageCategoryIdentifier,
            actions: [reply, markRead],
            intentIdentifiers: ["INSendMessageIntent"],
            options: [.customDismissAction]
        )
        center.setNotificationCategories([message])
    }

    private func receiveFCMToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        latestFCMToken = trimmed

        guard let tokenHandler else { return }
        Task {
            await tokenHandler(trimmed)
        }
    }

    private func action(from response: UNNotificationResponse) -> MessageNotificationAction? {
        let payload = MessageNotificationPayload(
            userInfo: response.notification.request.content.userInfo
        )
        let conversationID = payload?.conversationID
        let messageID = payload?.messageID

        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier:
            return .open(conversationID: conversationID, messageID: messageID)

        case Self.replyActionIdentifier:
            guard
                let textResponse = response as? UNTextInputNotificationResponse
            else {
                return nil
            }
            let text = textResponse.userText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return .reply(
                text: text,
                conversationID: conversationID,
                messageID: messageID
            )

        case Self.markReadActionIdentifier:
            return .markRead(conversationID: conversationID, messageID: messageID)

        default:
            return nil
        }
    }

    private func presentationOptions(
        for notification: UNNotification
    ) -> UNNotificationPresentationOptions {
        let payload = MessageNotificationPayload(
            userInfo: notification.request.content.userInfo
        )
        return ForegroundNotificationPresentationPolicy.options(
            notificationConversationID: payload?.conversationID,
            activeConversationID: activeConversationID
        )
    }
}

extension PushNotificationCoordinator: PushNotificationCoordinating {}

extension PushNotificationCoordinating {
    func clearConversationNotifications() async {}
    func resetForSignOut() async {}
}

extension PushNotificationCoordinator: MessagingDelegate {
    nonisolated func messaging(
        _ messaging: Messaging,
        didReceiveRegistrationToken fcmToken: String?
    ) {
        guard let fcmToken else { return }
        Task { @MainActor [weak self] in
            self?.receiveFCMToken(fcmToken)
        }
    }
}

extension PushNotificationCoordinator: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        await presentationOptions(for: notification)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await handle(response)
    }

    @MainActor
    private func handle(_ response: UNNotificationResponse) async {
        guard let action = action(from: response) else { return }
        guard let actionHandler else {
            if acceptsPendingActions {
                pendingActions.append(action)
            }
            return
        }
        await actionHandler(action)
    }
}
