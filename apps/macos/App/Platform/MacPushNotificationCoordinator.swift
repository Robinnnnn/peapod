import AppKit
@preconcurrency import FirebaseMessaging
import Foundation
@preconcurrency import UserNotifications

@MainActor
protocol MacUserNotificationCenterControlling: AnyObject {
    var delegate: (any UNUserNotificationCenterDelegate)? { get set }
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>)
    func removeAllDeliveredNotifications()
    func removeAllPendingNotificationRequests()
    func setBadgeCount(_ count: Int) async throws
}

extension UNUserNotificationCenter: MacUserNotificationCenterControlling {}

@MainActor
protocol MacNotificationCoordinating: AnyObject {
    func configure(
        tokenHandler: MacPushNotificationCoordinator.TokenHandler?,
        actionHandler: MacPushNotificationCoordinator.ActionHandler?
    )
    func requestAuthorizationAndRegister() async throws -> Bool
    func setActiveConversation(_ conversationID: String?)
    func resetForSignOut() async
    func invalidateSession()
}

extension MacNotificationCoordinating {
    func invalidateSession() {}
}

@MainActor
final class MacPushNotificationCoordinator: NSObject {
    typealias TokenHandler =
        @MainActor @Sendable (String) async -> Void
    typealias ActionHandler =
        @MainActor @Sendable (MessageNotificationAction) async -> Void

    static let shared = MacPushNotificationCoordinator()

    static let messageCategoryIdentifier = "MESSAGE"
    static let replyActionIdentifier = "MESSAGE_REPLY"
    static let markReadActionIdentifier = "MESSAGE_MARK_READ"

    private let center: any MacUserNotificationCenterControlling
    private let registerForRemoteNotifications: @MainActor () -> Void
    private let unregisterForRemoteNotifications: @MainActor () -> Void
    private var latestFCMToken: String?
    private var tokenHandler: TokenHandler?
    private var actionHandler: ActionHandler?
    private var pendingActions: [MessageNotificationAction] = []
    private var activeConversationID: String?
    private let retryConfiguration: NotificationRetryConfiguration
    private var registrationRetryTask: Task<Void, Never>?
    private var registrationRetryIndex = 0
    private var registrationEnabled = false
    private var registrationSucceeded = false
    private var session = UUID()

    init(center: any MacUserNotificationCenterControlling = UNUserNotificationCenter.current(),
         retryConfiguration: NotificationRetryConfiguration = .production,
         registerForRemoteNotifications: @escaping @MainActor () -> Void = {
             NSApplication.shared.registerForRemoteNotifications()
         },
         unregisterForRemoteNotifications: @escaping @MainActor () -> Void = {
             NSApplication.shared.unregisterForRemoteNotifications()
         }) {
        self.center = center
        self.retryConfiguration = retryConfiguration
        self.registerForRemoteNotifications = registerForRemoteNotifications
        self.unregisterForRemoteNotifications = unregisterForRemoteNotifications
        super.init()
    }

    func prepareForLaunch() {
        center.delegate = self
        installCategories()
    }

    func connectFirebaseMessaging() {
        let messaging = Messaging.messaging()
        messaging.delegate = self
        if let token = messaging.fcmToken {
            receiveFCMToken(token)
        }
    }

    func configure(
        tokenHandler: TokenHandler?,
        actionHandler: ActionHandler?
    ) {
        let configuredSession = session
        self.tokenHandler = tokenHandler
        self.actionHandler = actionHandler

        if let tokenHandler, let latestFCMToken {
            Task {
                guard self.session == configuredSession else { return }
                await tokenHandler(latestFCMToken)
            }
        }

        if let actionHandler, !pendingActions.isEmpty {
            let actions = pendingActions
            pendingActions.removeAll()
            Task {
                for action in actions {
                    guard self.session == configuredSession else { return }
                    await actionHandler(action)
                }
            }
        }
    }

    @discardableResult
    func requestAuthorizationAndRegister() async throws -> Bool {
        let requestedSession = session
        prepareForLaunch()
        let granted = try await center.requestAuthorization(
            options: [.alert, .badge, .sound]
        )
        guard session == requestedSession else { return false }
        registrationEnabled = granted
        registrationSucceeded = false
        if granted {
            registrationRetryTask?.cancel(); registrationRetryTask = nil
            registrationRetryIndex = 0
            registerForRemoteNotifications()
        }
        return granted
    }

    func setActiveConversation(_ conversationID: String?) {
        activeConversationID = conversationID
    }

    func didRegisterForRemoteNotifications(deviceToken: Data) {
        guard registrationEnabled else { return }
        registrationSucceeded = true
        registrationRetryTask?.cancel(); registrationRetryTask = nil
        registrationRetryIndex = 0
        Messaging.messaging().apnsToken = deviceToken
    }

    func didFailToRegisterForRemoteNotifications(error: Error) {
        guard registrationEnabled, !registrationSucceeded, registrationRetryTask == nil,
              registrationRetryIndex < retryConfiguration.delays.count else { return }
        let retrySession = session
        let delay = retryConfiguration.delays[registrationRetryIndex]
        registrationRetryIndex += 1
        registrationRetryTask = Task { [weak self] in
            guard let self else { return }
            do { try await retryConfiguration.sleep(delay) } catch { return }
            guard !Task.isCancelled, session == retrySession, registrationEnabled else { return }
            registrationRetryTask = nil
            registerForRemoteNotifications()
        }
    }

    func invalidateSession() {
        session = UUID()
        registrationEnabled = false
        registrationSucceeded = false
        registrationRetryTask?.cancel(); registrationRetryTask = nil
        registrationRetryIndex = 0
        tokenHandler = nil
        actionHandler = nil
    }

    func resetForSignOut() async {
        invalidateSession()
        activeConversationID = nil
        tokenHandler = nil
        actionHandler = nil
        pendingActions.removeAll()
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
        let resetSession = session
        try? await center.setBadgeCount(0)
        guard session == resetSession else { return }
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
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        center.setNotificationCategories([message])
    }

    private func receiveFCMToken(_ token: String) {
        let trimmed = token.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else { return }
        latestFCMToken = trimmed
        guard let tokenHandler else { return }
        let tokenSession = session
        Task {
            guard self.session == tokenSession else { return }
            await tokenHandler(trimmed)
        }
    }

    private func action(
        from response: UNNotificationResponse
    ) -> MessageNotificationAction? {
        let payload = MessageNotificationPayload(
            userInfo: response.notification.request.content.userInfo
        )
        let conversationID = payload?.conversationID
        let messageID = payload?.messageID

        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier:
            return .open(
                conversationID: conversationID,
                messageID: messageID
            )
        case Self.replyActionIdentifier:
            guard
                let response =
                    response as? UNTextInputNotificationResponse
            else {
                return nil
            }
            let text = response.userText.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !text.isEmpty else { return nil }
            return .reply(
                text: text,
                conversationID: conversationID,
                messageID: messageID
            )
        case Self.markReadActionIdentifier:
            return .markRead(
                conversationID: conversationID,
                messageID: messageID
            )
        default:
            return nil
        }
    }
}

extension MacPushNotificationCoordinator:
    MacNotificationCoordinating
{}

extension MacPushNotificationCoordinator: MessagingDelegate {
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

extension MacPushNotificationCoordinator:
    UNUserNotificationCenterDelegate
{
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
    private func presentationOptions(
        for notification: UNNotification
    ) -> UNNotificationPresentationOptions {
        let payload = MessageNotificationPayload(
            userInfo: notification.request.content.userInfo
        )
        guard
            let conversationID = payload?.conversationID,
            conversationID == activeConversationID
        else {
            return [.banner, .list, .sound, .badge]
        }
        return []
    }

    @MainActor
    private func handle(_ response: UNNotificationResponse) async {
        guard let action = action(from: response) else { return }
        guard let actionHandler else {
            pendingActions.append(action)
            return
        }
        await actionHandler(action)
    }
}

final class MacApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(
        _ notification: Notification
    ) {
        Task { @MainActor in
            MacPushNotificationCoordinator.shared.prepareForLaunch()
        }
    }

    func application(
        _ application: NSApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            MacPushNotificationCoordinator.shared
                .didRegisterForRemoteNotifications(deviceToken: deviceToken)
        }
    }

    func application(
        _ application: NSApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { @MainActor in
            MacPushNotificationCoordinator.shared
                .didFailToRegisterForRemoteNotifications(error: error)
        }
    }
}
