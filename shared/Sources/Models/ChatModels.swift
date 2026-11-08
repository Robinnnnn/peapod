import CoreLocation
import Foundation

struct Person: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var displayName: String
    var initials: String
}

enum MessageKind: String, Codable, Sendable {
    case text
    case link
    case attachment
    case voice
    case liveLocation
}

enum DeliveryState: String, Codable, Sendable {
    case sending
    case sent
    case delivered
    case read
    case failed
}

enum ComposerSendAccessibilityLabel {
    static func text(
        photoCount: Int,
        fileCount: Int,
        deliveryMode: MessageDeliveryMode
    ) -> String {
        let photos = max(0, photoCount)
        let files = max(0, fileCount)
        let content: String

        if photos > 0, files == 0 {
            content = "\(photos) \(photos == 1 ? "photo" : "photos")"
        } else if files > 0, photos == 0 {
            content = "\(files) \(files == 1 ? "file" : "files")"
        } else if photos + files > 0 {
            let count = photos + files
            content = "\(count) \(count == 1 ? "attachment" : "attachments")"
        } else {
            return deliveryMode == .quiet ? "Send Quietly" : "Send"
        }

        return deliveryMode == .quiet
            ? "Send \(content) quietly"
            : "Send \(content)"
    }
}

struct MessageReceipt: Hashable, Sendable {
    let lastDeliveredMessageID: String?
    let lastReadMessageID: String?

    func deliveryState(
        for messageID: String,
        messageIndexes: [String: Int],
        fallback: DeliveryState
    ) -> DeliveryState {
        guard fallback != .sending, fallback != .failed else {
            return fallback
        }
        guard let messageIndex = messageIndexes[messageID] else {
            return fallback
        }

        if
            let lastReadMessageID,
            let lastReadIndex = messageIndexes[lastReadMessageID],
            messageIndex <= lastReadIndex
        {
            return .read
        }
        if
            let lastDeliveredMessageID,
            let lastDeliveredIndex = messageIndexes[lastDeliveredMessageID],
            messageIndex <= lastDeliveredIndex
        {
            return .delivered
        }
        return fallback
    }
}

enum AttachmentType: String, Codable, Sendable {
    case image
    case video
    case audio
    case file
}

struct AttachmentContent: Codable, Hashable, Sendable {
    let id: String
    let type: AttachmentType
    let storagePath: String?
    let fileName: String
    let contentType: String
    let byteSize: Int64
    let audioDurationMilliseconds: Int?

    init(
        id: String,
        type: AttachmentType,
        storagePath: String?,
        fileName: String,
        contentType: String,
        byteSize: Int64,
        audioDurationMilliseconds: Int? = nil
    ) {
        self.id = id
        self.type = type
        self.storagePath = storagePath
        self.fileName = fileName
        self.contentType = contentType
        self.byteSize = byteSize
        self.audioDurationMilliseconds = audioDurationMilliseconds
    }

    var audioDuration: TimeInterval? {
        audioDurationMilliseconds.map { TimeInterval($0) / 1_000 }
    }
}

struct LiveLocationContent: Codable, Hashable, Sendable {
    var latitude: Double
    var longitude: Double
    var updatedAt: Date
    var expiresAt: Date?

    var location: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }

    var isActive: Bool {
        isActive(at: .now)
    }

    func isActive(at date: Date) -> Bool {
        if let expiresAt {
            return expiresAt > date
        }

        // Legacy records without a renewable lease fall back to freshness.
        return updatedAt.addingTimeInterval(5 * 60) > date
    }
}

struct ChatMessage: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let senderID: String
    var kind: MessageKind
    var body: String
    let createdAt: Date
    var editedAt: Date?
    var deletedAt: Date?
    var deliveryState: DeliveryState
    var replyToID: UUID?
    var reactions: [String: String]
    var attachment: AttachmentContent?
    /// Photos selected in one send keep the first photo's message ID as a
    /// durable action target. Every member records its position and the
    /// expected group size so either device can rebuild the same stack.
    var attachmentGroupID: UUID?
    var attachmentGroupIndex: Int?
    var attachmentGroupCount: Int?
    var liveLocation: LiveLocationContent?
    /// `nil` is the canonical representation of normal delivery so messages
    /// created by older clients remain fully compatible.
    var deliveryMode: MessageDeliveryMode?

    init(
        id: UUID = UUID(),
        senderID: String,
        kind: MessageKind,
        body: String,
        createdAt: Date = .now,
        editedAt: Date? = nil,
        deletedAt: Date? = nil,
        deliveryState: DeliveryState,
        replyToID: UUID? = nil,
        reactions: [String: String] = [:],
        attachment: AttachmentContent? = nil,
        attachmentGroupID: UUID? = nil,
        attachmentGroupIndex: Int? = nil,
        attachmentGroupCount: Int? = nil,
        liveLocation: LiveLocationContent? = nil,
        deliveryMode: MessageDeliveryMode? = nil
    ) {
        self.id = id
        self.senderID = senderID
        self.kind = kind
        self.body = body
        self.createdAt = createdAt
        self.editedAt = editedAt
        self.deletedAt = deletedAt
        self.deliveryState = deliveryState
        self.replyToID = replyToID
        self.reactions = reactions
        self.attachment = attachment
        self.attachmentGroupID = attachmentGroupID
        self.attachmentGroupIndex = attachmentGroupIndex
        self.attachmentGroupCount = attachmentGroupCount
        self.liveLocation = liveLocation
        self.deliveryMode = deliveryMode?.storedValue == nil
            ? nil
            : deliveryMode
    }

    var resolvedDeliveryMode: MessageDeliveryMode {
        deliveryMode == .quiet ? .quiet : .normal
    }
}

struct PhotoMessageGroup: Identifiable, Equatable, Sendable {
    let id: UUID
    let messages: [ChatMessage]
    let expectedCount: Int

    var anchor: ChatMessage {
        messages.first {
            $0.id == id
        } ?? messages[0]
    }

    var failedCount: Int {
        messages.filter { $0.deliveryState == .failed }.count
    }

    var availableCount: Int {
        messages.filter { $0.attachment != nil && !$0.isUnsent }.count
    }

    var displayMessage: ChatMessage {
        var message = anchor
        message.deliveryState = Self.groupDeliveryState(messages)
        return message
    }

    private static func groupDeliveryState(
        _ messages: [ChatMessage]
    ) -> DeliveryState {
        if messages.contains(where: { $0.deliveryState == .failed }) {
            return .failed
        }
        if messages.contains(where: { $0.deliveryState == .sending }) {
            return .sending
        }
        if messages.allSatisfy({ $0.deliveryState == .read }) {
            return .read
        }
        if messages.allSatisfy({
            $0.deliveryState == .read || $0.deliveryState == .delivered
        }) {
            return .delivered
        }
        return .sent
    }
}

enum ConversationTimelineItem: Identifiable, Equatable, Sendable {
    case message(ChatMessage)
    case photoGroup(PhotoMessageGroup)

    var id: UUID {
        switch self {
        case let .message(message):
            message.id
        case let .photoGroup(group):
            group.id
        }
    }

    var displayMessage: ChatMessage {
        switch self {
        case let .message(message):
            message
        case let .photoGroup(group):
            group.displayMessage
        }
    }

    var photoGroup: PhotoMessageGroup? {
        guard case let .photoGroup(group) = self else { return nil }
        return group
    }
}

enum PhotoMessagePresentation {
    static func timelineItems(
        from messages: [ChatMessage]
    ) -> [ConversationTimelineItem] {
        typealias GroupEntry = (
            groupID: UUID,
            expectedCount: Int,
            message: ChatMessage
        )
        let entries: [GroupEntry] = messages.compactMap { message in
            guard
                message.kind == .attachment,
                (
                    message.attachment?.type == .image
                        || message.attachmentGroupID != nil
                ),
                let groupID = message.attachmentGroupID,
                let expectedCount = message.attachmentGroupCount,
                expectedCount > 1
            else {
                return nil
            }
            return (groupID, expectedCount, message)
        }
        let grouped = Dictionary(
            grouping: entries,
            by: \.groupID
        )

        var emittedGroupIDs: Set<UUID> = []
        return messages.compactMap { message in
            guard
                let groupID = message.attachmentGroupID,
                let entries = grouped[groupID],
                !entries.isEmpty
            else {
                return .message(message)
            }
            guard emittedGroupIDs.insert(groupID).inserted else {
                return nil
            }

            let sorted = entries
                .map(\.message)
                .sorted { lhs, rhs in
                    let leftIndex = lhs.attachmentGroupIndex ?? .max
                    let rightIndex = rhs.attachmentGroupIndex ?? .max
                    if leftIndex != rightIndex {
                        return leftIndex < rightIndex
                    }
                    if lhs.createdAt != rhs.createdAt {
                        return lhs.createdAt < rhs.createdAt
                    }
                    return lhs.id.uuidString < rhs.id.uuidString
                }
            let expectedCount =
                entries.map(\.expectedCount).max() ?? sorted.count
            return .photoGroup(
                PhotoMessageGroup(
                    id: groupID,
                    messages: sorted,
                    expectedCount: expectedCount
                )
            )
        }
    }

    static func standaloneRotationDegrees(for messageID: UUID) -> Double {
        let bytes = withUnsafeBytes(of: messageID.uuid) {
            Array($0)
        }
        let seed = Int(bytes[0]) + Int(bytes[15])
        let magnitude = 1.1 + Double(seed % 4) * 0.15
        return seed.isMultiple(of: 2) ? magnitude : -magnitude
    }
}

enum MessageAttachmentHydration {
    static func provisionalContent(
        messageID: UUID,
        firestoreType: String
    ) -> AttachmentContent? {
        guard firestoreType == "image" else { return nil }
        return AttachmentContent(
            id: messageID.uuidString,
            type: .image,
            storagePath: nil,
            fileName: "Photo",
            contentType: "image/*",
            byteSize: 0
        )
    }

    static func content(
        for message: ChatMessage,
        availableAttachments: [String: AttachmentContent]
    ) -> AttachmentContent? {
        availableAttachments[message.id.uuidString] ?? message.attachment
    }
}

struct MessageGroupPosition: Equatable, Sendable {
    let joinsPrevious: Bool
    let joinsNext: Bool
}

enum MessageGrouping {
    static let maximumInterval: TimeInterval = 5 * 60

    static func position(
        at index: Int,
        in messages: [ChatMessage],
        calendar: Calendar = .current
    ) -> MessageGroupPosition {
        guard messages.indices.contains(index) else {
            return MessageGroupPosition(
                joinsPrevious: false,
                joinsNext: false
            )
        }

        let joinsPrevious =
            index > messages.startIndex
            && belongsToSameGroup(
                messages[index - 1],
                messages[index],
                calendar: calendar
            )
        let joinsNext =
            messages.indices.contains(index + 1)
            && belongsToSameGroup(
                messages[index],
                messages[index + 1],
                calendar: calendar
            )

        return MessageGroupPosition(
            joinsPrevious: joinsPrevious,
            joinsNext: joinsNext
        )
    }

    private static func belongsToSameGroup(
        _ earlier: ChatMessage,
        _ later: ChatMessage,
        calendar: Calendar
    ) -> Bool {
        let interval = later.createdAt.timeIntervalSince(earlier.createdAt)
        return earlier.senderID == later.senderID
            && calendar.isDate(
                earlier.createdAt,
                inSameDayAs: later.createdAt
            )
            && interval >= 0
            && interval <= maximumInterval
    }
}

enum MessageTimestampText {
    static func string(
        for date: Date,
        locale: Locale = .current,
        calendar: Calendar = .current,
        timeZone: TimeZone = .current
    ) -> String {
        MessageTimestampTextCache.shared.value(
            forKey: cacheKey(
                kind: "short",
                date: date,
                locale: locale,
                calendar: calendar,
                timeZone: timeZone
            )
        ) {
            Date.FormatStyle(
                date: .omitted,
                time: .shortened,
                locale: locale,
                calendar: calendar,
                timeZone: timeZone
            )
            .format(date)
        }
    }

    static func accessibilityString(
        for date: Date,
        locale: Locale = .current,
        calendar: Calendar = .current,
        timeZone: TimeZone = .current
    ) -> String {
        MessageTimestampTextCache.shared.value(
            forKey: cacheKey(
                kind: "accessibility",
                date: date,
                locale: locale,
                calendar: calendar,
                timeZone: timeZone
            )
        ) {
            Date.FormatStyle(
                date: .abbreviated,
                time: .shortened,
                locale: locale,
                calendar: calendar,
                timeZone: timeZone
            )
            .format(date)
        }
    }

    private static func cacheKey(
        kind: String,
        date: Date,
        locale: Locale,
        calendar: Calendar,
        timeZone: TimeZone
    ) -> String {
        [
            kind,
            String(date.timeIntervalSinceReferenceDate.bitPattern, radix: 16),
            locale.identifier,
            String(describing: calendar.identifier),
            timeZone.identifier,
        ].joined(separator: "|")
    }
}

private final class MessageTimestampTextCache: @unchecked Sendable {
    static let shared = MessageTimestampTextCache()

    private let values = NSCache<NSString, NSString>()

    private init() {
        values.countLimit = 2_000
    }

    func value(
        forKey key: String,
        create: () -> String
    ) -> String {
        let cacheKey = key as NSString
        if let cached = values.object(forKey: cacheKey) {
            return cached as String
        }

        let value = create()
        values.setObject(value as NSString, forKey: cacheKey)
        return value
    }
}

enum MessageTimestampVisibility {
    static func isVisible(
        timestampsRevealed: Bool,
        groupedWithNext: Bool
    ) -> Bool {
        timestampsRevealed && !groupedWithNext
    }

    static func shouldLiftGroup(
        timestampsRevealed: Bool,
        groupTailHasPersistentMetadata: Bool
    ) -> Bool {
        timestampsRevealed && !groupTailHasPersistentMetadata
    }
}

struct LinkPreviewText: Equatable, Sendable {
    let domain: String
    let title: String

    init(urlText: String) {
        guard
            let url = URL(string: urlText),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else {
            domain = "Shared link"
            title = "Shared link"
            return
        }

        var host = url.host(percentEncoded: false) ?? "Shared link"
        if host.lowercased().hasPrefix("www.") {
            host.removeFirst(4)
        }
        domain = host

        guard
            let lastComponent = url.pathComponents.last,
            lastComponent != "/",
            !lastComponent.isEmpty
        else {
            title = "Shared link"
            return
        }

        let decoded = lastComponent.removingPercentEncoding ?? lastComponent
        let words = decoded
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        title = words.isEmpty || Self.looksOpaqueIdentifier(decoded)
            ? "Shared link"
            : words.capitalized
    }

    static func looksOpaqueIdentifier(_ component: String) -> Bool {
        let normalized = component.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let tokenCharacterCount = normalized.filter {
            $0.isLetter || $0.isNumber || Self.isTokenSeparator($0)
        }.count
        guard
            Double(tokenCharacterCount) / Double(normalized.count) > 0.9
        else {
            return false
        }

        let compact = normalized.filter { !Self.isTokenSeparator($0) }
        guard compact.count >= 8 else { return false }

        let uuidCandidate = normalized
            .replacingOccurrences(of: "_", with: "-")
        if UUID(uuidString: uuidCandidate) != nil {
            return true
        }

        if compact.allSatisfy({
            $0.isNumber || "abcdefABCDEF".contains($0)
        }) {
            return compact.count >= 8
        }

        let segments = normalized.split(
            whereSeparator: Self.isTokenSeparator
        )
        if segments.count == 1 {
            if compact.count >= 24 {
                return true
            }

            let uppercaseCount = compact.filter(\.isUppercase).count
            let lowercaseCount = compact.filter(\.isLowercase).count
            let vowelCount = compact.filter {
                "aeiouAEIOU".contains($0)
            }.count
            if uppercaseCount >= 2
                && lowercaseCount >= 2
                && vowelCount <= 1
            {
                return true
            }

            return compact.count >= 12
                && uppercaseCount >= 4
                && lowercaseCount >= 4
                && uppercaseCount * 4 >= compact.count
                && vowelCount * 4 <= compact.count
        }

        let digitCount = compact.filter(\.isNumber).count
        guard digitCount >= 4 else { return false }

        let readableCharacterCount = segments
            .filter { segment in
                segment.count >= 2 && segment.allSatisfy(\.isLetter)
            }
            .reduce(0) { $0 + $1.count }
        return readableCharacterCount * 2 < compact.count
    }

    private static func isTokenSeparator(_ character: Character) -> Bool {
        character == "-"
            || character == "_"
            || character.isWhitespace
    }
}

extension ChatMessage {
    var isUnsent: Bool {
        deletedAt != nil
    }

    var replyPreviewText: String {
        if isUnsent {
            return "Message unsent"
        }

        switch kind {
        case .attachment:
            if
                attachment?.type == .image,
                let attachmentGroupCount,
                attachmentGroupCount > 1
            {
                return "\(attachmentGroupCount) photos"
            }
            return attachment?.fileName ?? (body.isEmpty ? "Attachment" : body)
        case .voice:
            return "Voice message"
        case .liveLocation:
            return "Live location"
        case .text, .link:
            return body
        }
    }

    func matchesSearch(_ query: String) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return true }
        guard !isUnsent else { return false }

        return replyPreviewText.range(
            of: normalized,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
    }

}
