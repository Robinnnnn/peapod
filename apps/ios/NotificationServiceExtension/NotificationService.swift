@preconcurrency import Intents
@preconcurrency import UserNotifications

final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    /// Tests replace key resolution, donation and the deadline scheduler. Production keeps
    /// incoming communication metadata and a four-second generic fallback.
    struct Dependencies: Sendable {
        typealias Completion = @Sendable () -> Void
        let donate: @Sendable (INSendMessageIntent, @escaping Completion) -> Void
        let scheduleFallback: @Sendable (@escaping Completion) -> Void
        let resolvePreview: @Sendable (EncryptedNotificationPreviewRequest, @escaping @Sendable (ResolvedNotificationPreview?) -> Void) -> Void

        init(donate: @escaping @Sendable (INSendMessageIntent, @escaping Completion) -> Void,
             scheduleFallback: @escaping @Sendable (@escaping Completion) -> Void,
             resolvePreview: @escaping @Sendable (EncryptedNotificationPreviewRequest, @escaping @Sendable (ResolvedNotificationPreview?) -> Void) -> Void = { request, completion in
                 Task { completion(await EncryptedNotificationPreviewResolver.live.resolve(request)) }
             }) {
            self.donate = donate; self.scheduleFallback = scheduleFallback; self.resolvePreview = resolvePreview
        }

        static let live = Self(donate: { intent, completion in
            let interaction = INInteraction(intent: intent, response: nil)
            interaction.direction = .incoming
            interaction.donate { _ in completion() }
        }, scheduleFallback: { completion in
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 4, execute: completion)
        })
    }

    private let dependencies: Dependencies
    private var delivery: NotificationDelivery?
    private var bestAttemptContent: UNMutableNotificationContent?

    override init() {
        dependencies = .live
        super.init()
    }

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
        super.init()
    }

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }

        if content.userInfo["type"] as? String == "encrypted" {
            content.body = "New message"
            content.subtitle = ""
            content.attachments = []
        }
        bestAttemptContent = content
        let delivery = NotificationDelivery(handler: contentHandler)
        self.delivery = delivery

        guard let payload = MessagePayload(
            userInfo: content.userInfo,
            fallbackSenderName: content.title
        ) else {
            delivery.finish(with: content)
            return
        }

        content.categoryIdentifier = "MESSAGE"
        // Start the deadline before key access. A locked/missing key, slow resolver or
        // extension expiration must still deliver the already-sanitized generic alert.
        dependencies.scheduleFallback {
            delivery.finish(with: content)
        }

        if let preview = EncryptedNotificationPreviewRequest(userInfo: content.userInfo) {
            dependencies.resolvePreview(preview) { [self] result in
                guard delivery.beginDecoration() else { return }
                decorate(content, payload: payload, delivery: delivery,
                         preview: result.flatMap { $0.isCurrent() ? $0 : nil })
            }
        } else if delivery.beginDecoration() {
            decorate(content, payload: payload, delivery: delivery)
        }
    }

    private func decorate(_ content: UNMutableNotificationContent, payload: MessagePayload, delivery: NotificationDelivery,
                          preview: ResolvedNotificationPreview? = nil) {
        // Donate sender/Focus metadata with the generic body. The preview belongs only in
        // the final alert, not persistent Siri interaction content or a losing callback.
        let intent = messageIntent(content: content, payload: payload)
        dependencies.donate(intent) {
            let updated = (try? content.updating(from: intent)) ?? content
            if let preview, preview.isCurrent(),
               let resolved = updated.mutableCopy() as? UNMutableNotificationContent {
                resolved.body = preview.body
                delivery.finish(with: resolved)
            } else {
                delivery.finish(with: updated)
            }
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let delivery, let bestAttemptContent {
            delivery.finish(with: bestAttemptContent)
        }
    }

    private func messageIntent(
        content: UNNotificationContent,
        payload: MessagePayload
    ) -> INSendMessageIntent {
        let handle = INPersonHandle(value: payload.senderID, type: .unknown)
        let sender = INPerson(
            personHandle: handle,
            nameComponents: nil,
            displayName: payload.senderName,
            image: nil,
            contactIdentifier: nil,
            customIdentifier: payload.senderID
        )
        return INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: content.body,
            speakableGroupName: nil,
            conversationIdentifier: payload.conversationID ?? "mines-primary-conversation",
            serviceName: "Peapod",
            sender: sender,
            attachments: nil
        )
    }
}

private struct MessagePayload: Sendable {
    let senderID: String
    let senderName: String
    let conversationID: String?

    init?(userInfo: [AnyHashable: Any], fallbackSenderName: String) {
        guard let senderID = Self.nonemptyString(
            in: userInfo,
            keys: ["senderId", "senderID"]
        ) else {
            return nil
        }

        self.senderID = senderID
        self.senderName = Self.nonemptyString(
            in: userInfo,
            keys: ["senderName"]
        ) ?? Self.nonempty(fallbackSenderName) ?? "New message"
        self.conversationID = Self.nonemptyString(
            in: userInfo,
            keys: ["conversationId", "conversationID"]
        )
    }

    private static func nonemptyString(
        in userInfo: [AnyHashable: Any],
        keys: [String]
    ) -> String? {
        for key in keys {
            guard let value = userInfo[key] as? String else { continue }
            if let value = nonempty(value) {
                return value
            }
        }
        return nil
    }

    private static func nonempty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private final class NotificationDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((UNNotificationContent) -> Void)?
    private var decorationStarted = false

    init(handler: @escaping (UNNotificationContent) -> Void) {
        self.handler = handler
    }

    func beginDecoration() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard handler != nil, !decorationStarted else { return false }
        decorationStarted = true
        return true
    }

    func finish(with content: UNNotificationContent) {
        let handler: ((UNNotificationContent) -> Void)?
        lock.lock()
        handler = self.handler
        self.handler = nil
        lock.unlock()
        handler?(content)
    }
}
