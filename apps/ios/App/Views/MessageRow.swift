@preconcurrency import FirebaseStorage
import Observation
import QuickLook
import SwiftUI
import UIKit

private func singlePhotoSize(_ imageSize: CGSize?) -> CGSize {
    ChatPhotoLayout.size(for: imageSize, maximum: CGSize(width: 240, height: 320),
                        placeholder: CGSize(width: 240, height: 220))
}

// Let the bubble propagate its center through quotes/status stacks to the timestamp.
enum MessageContentCenterAlignment: AlignmentID {
    static func defaultValue(in dimensions: ViewDimensions) -> CGFloat {
        dimensions[VerticalAlignment.center]
    }
}

extension VerticalAlignment {
    static let messageContentCenter = VerticalAlignment(MessageContentCenterAlignment.self)
}

struct MessageRow: View {
    @Environment(\.usesGiftWrap) private var usesGiftWrap
    @Environment(\.conversationMessageFrames) private var messageFrames
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.encryptedAttachmentResolver) private var encryptedResolver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let message: ChatMessage
    let photoGroup: PhotoMessageGroup?
    let isCurrentUser: Bool
    let currentUserID: String
    let showsDeliveryStatus: Bool
    let isLatestOutgoing: Bool
    let pendingShareStatus: PendingShareTimelineStatus?
    let groupedWithPrevious: Bool
    let groupedWithNext: Bool
    let replyMessage: ChatMessage?
    let timestampReveal: MessageTimestampRevealSource
    let interactionOffsetY: CGFloat
    let allowsInteractions: Bool
    let onShowReply: () -> Void
    let onPresentInteractions: () -> Void
    let onReply: () -> Void
    let onReact: (String) -> Void
    let onEdit: () -> Void
    let onUnsend: () -> Void
    let onRetry: () -> Void
    let onRemovePendingShare: () -> Void
    var isInteractionPreview = false
    var isPinned = false

    @ViewBuilder
    var body: some View {
        if isInteractionPreview {
            messageSurface
                .allowsHitTesting(false)
                .accessibilityElement(children: .contain)
        } else { timelineRow }
    }

    private var timelineRow: some View {
        ZStack(alignment: Alignment(horizontal: .trailing, vertical: .messageContentCenter)) {
            MessageTimestampRevealLabel(
                messageID: message.id,
                date: message.createdAt,
                reveal: timestampReveal
            )
            .modifier(ConversationEdgeBlurModifier())

            HStack(alignment: .messageContentCenter) {
                if isCurrentUser {
                    Spacer(minLength: 52)
                }

                messageSurface
                    .modifier(ConversationEdgeBlurModifier())
                    .background(ConversationMessageFrameMarker(id: message.id, frames: messageFrames))
                    .id(encryptedResolver.map(ObjectIdentifier.init))
                    .anchorPreference(
                        key: MessageFramePreferenceKey.self,
                        value: .bounds
                    ) {
                        [message.id: $0]
                    }
                    .messageInteractionTrigger(
                        isEnabled:
                            MessageInteractionPolicy.canPresent(
                                message: message,
                                allowsInteractions: allowsInteractions
                            ),
                        action: onPresentInteractions
                    )

                if !isCurrentUser {
                    Spacer(minLength: 52)
                }
            }
            .modifier(
                MessageTimestampRevealSurfaceEffect(
                    reveal: timestampReveal,
                    isCurrentUser: isCurrentUser
                )
            )
            .offset(y: interactionOffsetY)
        }
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("message-row-\(message.id.uuidString)")
        .animation(
            reduceMotion ? nil : .snappy(duration: 0.22),
            value: message.isUnsent
        )
        .animation(
            reduceMotion ? nil : .snappy(duration: 0.2),
            value: message.editedAt
        )
        .animation(
            reduceMotion
                ? .easeOut(
                    duration: MessageReactionAnimationPolicy
                        .reducedMotionDuration
                )
                : .snappy(
                    duration: MessageReactionAnimationPolicy
                        .standardDuration
                ),
            value: message.reactions
        )
        .accessibilityAction(
            named: "Read sent time"
        ) {
            UIAccessibility.post(
                notification: .announcement,
                argument:
                    "Sent "
                    + MessageTimestampText.accessibilityString(
                        for: message.createdAt
                    )
            )
        }
    }

    private var messageSurface: some View {
        VStack(alignment: isCurrentUser ? .trailing : .leading, spacing: 3) {
            if message.replyToID != nil {
                replyPreview
            }

            displayedContent
                .alignmentGuide(.messageContentCenter) { $0[VerticalAlignment.center] }
                .padding(.bottom, needsPinFooter ? 22 : 0)
                .background {
                    if needsPinFooter {
                        (usesGiftWrap ? GiftWrapAppearance.incoming(colorScheme == .dark) : Color(.secondarySystemBackground))
                            .clipShape(bubbleShape)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if showsPin {
                        MessagePinBadge(isOutgoing: isCurrentUser && isPlainText, overMedia: isPhoto)
                    }
                }
                .accessibilityIdentifier(
                    "message-bubble-\(message.id.uuidString)"
                )
                .overlay(
                    alignment: reactionBadgeAlignment
                ) {
                    if !message.isUnsent, !message.reactions.isEmpty {
                        reactions
                            .offset(
                                x: MessageReactionBadgeLayout
                                    .horizontalOffset(
                                        isCurrentUser: isCurrentUser
                                ),
                                y: MessageReactionBadgeLayout
                                    .verticalOffset
                            )
                            .transition(reactionAppearanceTransition)
                    }
                }
                .padding(
                    .top,
                    message.reactions.isEmpty || message.isUnsent
                        ? 0
                        : MessageReactionBadgeLayout.reservedDepth
                )
                .transition(
                    reduceMotion
                        ? .opacity
                        : .scale(scale: 0.98).combined(with: .opacity)
                )

            messageMetadata
        }
    }

    @ViewBuilder
    private var displayedContent: some View {
        if
            photoGroup != nil
                || message.attachment?.type == .image
                || (
                    !message.isUnsent
                        && (message.kind == .link || message.kind == .text)
                        && LinkPreviewSelection.first(
                            in: message.body
                        ) != nil
                )
                || (
                    message.kind == .attachment
                        && AttachmentImageCache.shared.memoryImage(
                            forKey: message.id.uuidString
                        ) != nil
                )
        {
            content
        } else {
            content.clipShape(bubbleShape)
                .overlay {
                    if !message.isUnsent && (message.kind == .attachment || message.kind == .voice) {
                        AttachmentLights(messageID: message.id) { bubbleShape.path(in: $0).cgPath }
                    }
                }
        }
    }

    private var bubbleShape: UnevenRoundedRectangle {
        let fullRadius: CGFloat = 18
        let groupedRadius: CGFloat = 6

        if isCurrentUser {
            return UnevenRoundedRectangle(
                topLeadingRadius: fullRadius,
                bottomLeadingRadius: fullRadius,
                bottomTrailingRadius:
                    groupedWithNext ? groupedRadius : fullRadius,
                topTrailingRadius:
                    groupedWithPrevious ? groupedRadius : fullRadius,
                style: .continuous
            )
        }

        return UnevenRoundedRectangle(
            topLeadingRadius:
                groupedWithPrevious ? groupedRadius : fullRadius,
            bottomLeadingRadius:
                groupedWithNext ? groupedRadius : fullRadius,
            bottomTrailingRadius: fullRadius,
            topTrailingRadius: fullRadius,
            style: .continuous
        )
    }

    private var replyPreview: some View {
        let dark = colorScheme == .dark
        let accent = usesGiftWrap ? GiftWrapAppearance.accent(dark) : .indigo
        let surface = usesGiftWrap ? AnyShapeStyle(GiftWrapAppearance.incoming(dark)) : AnyShapeStyle(.quaternary)
        return Button(action: onShowReply) {
            HStack(spacing: 7) {
                Capsule()
                    .fill(accent)
                    .frame(width: 3)

                VStack(alignment: .leading, spacing: 1) {
                    Text(
                        replyMessage?.senderID == currentUserID
                            ? "You"
                            : "Reply"
                    )
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(accent)

                    Text(replyMessage?.replyPreviewText ?? "Original message unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(surface, in: .rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show replied-to message")
    }

    @ViewBuilder
    private var content: some View {
        if message.isUnsent {
            Label("Message unsent", systemImage: "nosign")
                .font(.callout.italic())
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .foregroundStyle(.secondary)
                .background(
                    Color(.secondarySystemBackground),
                    in: .rect(cornerRadius: 18)
                )
        } else {
            switch message.kind {
            case .liveLocation:
                Label(
                    "Location shared in an earlier version",
                    systemImage: "location.slash"
                )
                .font(.callout)
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .foregroundStyle(.secondary)
                .background(
                    Color(.secondarySystemBackground),
                    in: .rect(cornerRadius: 18)
                )
                .accessibilityIdentifier("legacy-location-message")
            case .link:
                LinkBubble(
                    messageID: message.id, messageText: message.body,
                    isCurrentUser: isCurrentUser
                )
            case .attachment:
                if let photoGroup {
                    PhotoGroupBubble(group: photoGroup)
                } else if let attachment = message.attachment {
                    if attachment.type == .image {
                        AttachmentBubble(attachment: attachment, deliveryState: message.deliveryState)
                            .overlay { AttachmentLights(messageID: message.id) }
                            .rotationEffect(
                                .degrees(
                                    PhotoMessagePresentation
                                        .standaloneRotationDegrees(
                                            for: message.id
                                        )
                                )
                            )
                            .padding(7)
                    } else {
                        AttachmentBubble(attachment: attachment, deliveryState: message.deliveryState)
                    }
                } else if
                    let cachedImage = AttachmentImageCache.shared.memoryImage(
                        forKey: message.id.uuidString
                    )
                {
                    Image(uiImage: cachedImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: singlePhotoSize(cachedImage.size).width,
                               height: singlePhotoSize(cachedImage.size).height)
                        .clipShape(.rect(cornerRadius: 18))
                        .overlay { AttachmentLights(messageID: message.id) }
                        .rotationEffect(
                            .degrees(
                                PhotoMessagePresentation
                                    .standaloneRotationDegrees(
                                        for: message.id
                                    )
                            )
                        )
                        .padding(7)
                        .accessibilityLabel("Photo")
                        .accessibilityIdentifier("message-attachment")
                } else {
                    Label(message.body, systemImage: "paperclip")
                        .padding(.horizontal, 13)
                        .padding(.vertical, 11)
                        .background(
                            Color(.secondarySystemBackground),
                            in: .rect(cornerRadius: 18)
                        )
                }
            case .voice:
                if let attachment = message.attachment {
                    VoiceMessageBubble(attachment: attachment)
                } else {
                    Label("Voice message", systemImage: "waveform")
                        .padding(.horizontal, 13)
                        .padding(.vertical, 11)
                        .background(
                            Color(.secondarySystemBackground),
                            in: .rect(cornerRadius: 18)
                        )
                }
            case .text:
                if LinkPreviewSelection.first(in: message.body) != nil {
                    LinkBubble(
                        messageID: message.id, messageText: message.body,
                        isCurrentUser: isCurrentUser
                    )
                } else {
                    Text(message.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.trailing, showsPin ? 18 : 0)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 9)
                        .foregroundStyle(isCurrentUser ? .white : .primary)
                        .background(
                            isCurrentUser
                                ? (usesGiftWrap ? AnyShapeStyle(LinearGradient(colors: [GiftWrapAppearance.pine, GiftWrapAppearance.pineDark], startPoint: .topLeading, endPoint: .bottomTrailing)) : AnyShapeStyle(Color.indigo.gradient))
                                : AnyShapeStyle(usesGiftWrap ? GiftWrapAppearance.incoming(colorScheme == .dark) : Color(.secondarySystemBackground)),
                            in: .rect(cornerRadius: 18)
                        )
                }
            }
        }
    }

    private var reactions: some View {
        HStack(spacing: 3) {
            ForEach(
                Array(reactionSummary.enumerated()),
                id: \.element.emoji
            ) { index, item in
                if allowsInteractions {
                    Button {
                        onReact(item.emoji)
                    } label: {
                        reactionLabel(for: item)
                            .frame(
                                width: MessageReactionBadgeLayout.hitTargetSize,
                                height: MessageReactionBadgeLayout.hitTargetSize
                            )
                            .background(Color.clear)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        MessageReactionAccessibility.label(
                            emoji: item.emoji,
                            count: item.count,
                            includesCurrentUser: item.isCurrentUser
                        )
                    )
                    .accessibilityHint(
                        item.isCurrentUser
                            ? "Double-tap to remove your reaction"
                            : "Double-tap to react"
                    )
                    .accessibilityIdentifier(
                        "message-reaction-\(message.id.uuidString)-\(index)"
                    )
                } else {
                    reactionLabel(for: item)
                        .frame(
                            width: MessageReactionBadgeLayout.hitTargetSize,
                            height: MessageReactionBadgeLayout.hitTargetSize
                        )
                        .accessibilityLabel(
                            MessageReactionAccessibility.label(
                                emoji: item.emoji,
                                count: item.count,
                                includesCurrentUser: item.isCurrentUser
                            )
                        )
                }
            }
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            "message-reactions-\(message.id.uuidString)"
        )
    }

    private func reactionLabel(
        for item: (emoji: String, count: Int, isCurrentUser: Bool)
    ) -> some View {
        Text(item.emoji)
            .font(.system(size: MessageReactionBadgeLayout.glyphSize))
            .frame(
                width: MessageReactionBadgeLayout.visibleDiameter,
                height: MessageReactionBadgeLayout.visibleDiameter
            )

    }

    private var reactionAppearanceTransition: AnyTransition {
        switch MessageReactionAnimationPolicy.appearance(
            reduceMotion: reduceMotion
        ) {
        case .scaleAndOpacity:
            .scale(
                scale: MessageReactionAnimationPolicy.appearanceScale
            )
            .combined(with: .opacity)
        case .opacityOnly:
            .opacity
        }
    }

    private var reactionSummary: [(emoji: String, count: Int, isCurrentUser: Bool)] {
        let counts = Dictionary(grouping: message.reactions, by: \.value)
        return counts.map { emoji, reactions in
            (
                emoji: emoji,
                count: reactions.count,
                isCurrentUser: reactions.contains { $0.key == currentUserID }
            )
        }
        .sorted { lhs, rhs in
            let leftIndex =
                MessageInteractionPolicy.reactionChoices
                    .firstIndex(of: lhs.emoji) ?? .max
            let rightIndex =
                MessageInteractionPolicy.reactionChoices
                    .firstIndex(of: rhs.emoji) ?? .max
            return leftIndex == rightIndex
                ? lhs.emoji < rhs.emoji
                : leftIndex < rightIndex
        }
    }

    @ViewBuilder
    private var messageMetadata: some View {
        if showsPersistentMetadata {
            HStack(spacing: 4) {
                if showsEditedStatus {
                    Text("Edited")
                        .transition(.opacity)
                }

                if showsMessageDeliveryStatus {
                    if showsEditedStatus {
                        metadataSeparator
                    }
                    deliveryLabel
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, isPhoto ? 11 : 4)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var reactionBadgeAlignment: Alignment {
        switch MessageReactionBadgeLayout.corner(
            isCurrentUser: isCurrentUser
        ) {
        case .upperLeading:
            .topLeading
        case .upperTrailing:
            .topTrailing
        }
    }

    private var showsPin: Bool { isPinned && !message.isUnsent }
    private var isPhoto: Bool { photoGroup != nil || message.attachment?.type == .image }
    private var isPlainText: Bool {
        message.kind == .text && LinkPreviewSelection.first(in: message.body) == nil
    }
    private var needsPinFooter: Bool { showsPin && !isPlainText && !isPhoto }

    private var showsEditedStatus: Bool {
        !message.isUnsent && message.editedAt != nil
    }

    private var showsMessageDeliveryStatus: Bool {
        isCurrentUser && showsDeliveryStatus
    }

    private var showsPersistentMetadata: Bool {
        showsEditedStatus || showsMessageDeliveryStatus
    }

    private var metadataSeparator: some View {
        Text("·")
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var deliveryLabel: some View {
        if let pendingShareStatus {
            pendingShareDeliveryLabel(pendingShareStatus)
                .frame(minHeight: 20, alignment: .trailing)
        } else {
            standardDeliveryLabel
                .accessibilityIdentifier(
                    isLatestOutgoing
                        ? "latest-delivery-status"
                        : "message-delivery-status-\(message.id.uuidString)"
                )
        }
    }

    @ViewBuilder
    private func pendingShareDeliveryLabel(
        _ status: PendingShareTimelineStatus
    ) -> some View {
        switch status {
        case .waiting:
            Label("Waiting", systemImage: "clock")
                .accessibilityIdentifier("pending-share-status-waiting")
        case .sending:
            MessageDeliveryStatusView(state: .sending)
                .accessibilityIdentifier("pending-share-status-sending")
        case .failed(let detail):
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 8) {
                    Button("Try again", action: onRetry)
                        .accessibilityIdentifier("retry-pending-share")
                    Button(
                        "Remove",
                        role: .destructive,
                        action: onRemovePendingShare
                    )
                    .accessibilityIdentifier("remove-pending-share")
                }
                .font(.caption2.weight(.semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .accessibilityIdentifier(
                        "pending-share-status-failed"
                    )
            }
        }
    }

    @ViewBuilder
    private var standardDeliveryLabel: some View {
        if
            message.kind == .liveLocation,
            message.deliveryState == .failed
        {
            Text("Not sent")
                .foregroundStyle(.red)
        } else {
            MessageDeliveryStatusView(
                state: message.deliveryState,
                retry:
                    message.deliveryState == .failed
                        ? onRetry
                        : nil
            )
        }
    }
}

enum MessageTimestampReveal {
    enum DragAxis: Equatable {
        case undetermined
        case horizontal
        case vertical
    }

    static let maximumDistance: CGFloat = 76

    static func lockedAxis(
        current: DragAxis,
        translation: CGSize
    ) -> DragAxis {
        guard current == .undetermined else { return current }
        guard translation != .zero else { return .undetermined }
        return abs(translation.width) > abs(translation.height)
            ? .horizontal
            : .vertical
    }

    static func offset(
        translationWidth: CGFloat,
        axis: DragAxis
    ) -> CGFloat {
        guard axis == .horizontal else { return 0 }
        return min(0, max(-maximumDistance, translationWidth))
    }

    static func progress(for offset: CGFloat) -> Double {
        min(1, max(0, Double(-offset / maximumDistance)))
    }

    static func surfaceOffset(
        revealOffset: CGFloat,
        isCurrentUser: Bool
    ) -> CGFloat {
        isCurrentUser ? revealOffset : 0
    }
}

@Observable
final class MessageTimestampRevealState {
    var offset: CGFloat
    var dragAxis: MessageTimestampReveal.DragAxis

    init(
        offset: CGFloat = 0,
        dragAxis: MessageTimestampReveal.DragAxis = .undetermined
    ) {
        self.offset = offset
        self.dragAxis = dragAxis
    }
}

enum MessageTimestampRevealSource {
    case fixed(CGFloat)
    case interactive(MessageTimestampRevealState)

    fileprivate var offset: CGFloat {
        switch self {
        case .fixed(let offset):
            offset
        case .interactive(let state):
            state.offset
        }
    }
}

struct MessageTimestampRevealLabel: View {
    @Environment(\.usesGiftWrap) private var usesGiftWrap
    @Environment(\.colorScheme) private var colorScheme
    let messageID: UUID
    let date: Date
    let reveal: MessageTimestampRevealSource

    var body: some View {
        let offset = reveal.offset
        Text(MessageTimestampText.string(for: date))
            .font(.caption2)
            .foregroundStyle(usesGiftWrap ? Color.white : Color.secondary)
            .monospacedDigit()
            .fixedSize(horizontal: true, vertical: false)
            .shadow(
                color: usesGiftWrap
                    ? (colorScheme == .dark ? .black.opacity(0.28)
                        : Color(.sRGB, red: 46/255, green: 31/255, blue: 18/255, opacity: 0.40))
                    : .clear,
                radius: 3, y: 0.5
            )
            .padding(.trailing, 4)
            .offset(
                x: MessageTimestampReveal.maximumDistance + offset
            )
            .opacity(MessageTimestampReveal.progress(for: offset))
            .accessibilityLabel(
                "Sent \(MessageTimestampText.accessibilityString(for: date))"
            )
            .accessibilityIdentifier(
                "message-timestamp-\(messageID.uuidString)"
            )
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

private struct MessageTimestampRevealSurfaceEffect: ViewModifier {
    let reveal: MessageTimestampRevealSource
    let isCurrentUser: Bool

    func body(content: Content) -> some View {
        content.offset(
            x: MessageTimestampReveal.surfaceOffset(
                revealOffset: reveal.offset,
                isCurrentUser: isCurrentUser
            )
        )
    }
}

enum MessageReactionBadgeLayout {
    enum Corner: Equatable {
        case upperLeading
        case upperTrailing
    }

    static let hitTargetSize: CGFloat = 44
    static let visibleDiameter: CGFloat = 28
    static let glyphSize: CGFloat = 24
    static let verticalOffset: CGFloat = -28
    static let reservedDepth: CGFloat = 20

    static func corner(isCurrentUser: Bool) -> Corner {
        isCurrentUser ? .upperLeading : .upperTrailing
    }

    static func horizontalOffset(isCurrentUser: Bool) -> CGFloat {
        isCurrentUser ? -20 : 20
    }
}

enum MessageReactionAnimationPolicy {
    enum Appearance: Equatable {
        case scaleAndOpacity
        case opacityOnly
    }

    static let appearanceScale = 0.88
    static let standardDuration = 0.2
    static let reducedMotionDuration = 0.12

    static func appearance(reduceMotion: Bool) -> Appearance {
        reduceMotion ? .opacityOnly : .scaleAndOpacity
    }
}

enum MessageReactionAccessibility {
    static func name(for emoji: String) -> String {
        MessageReactionPalette.name(for: emoji)
    }

    static func label(
        emoji: String,
        count: Int,
        includesCurrentUser: Bool
    ) -> String {
        let countText = count == 1 ? "1 reaction" : "\(count) reactions"
        return includesCurrentUser
            ? "\(name(for: emoji)), \(countText), including yours"
            : "\(name(for: emoji)), \(countText)"
    }
}

private extension View {
    @ViewBuilder
    func messageInteractionTrigger(
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        if isEnabled {
            self
                .contentShape(.rect)
                .highPriorityGesture(
                    LongPressGesture(
                        minimumDuration: 0.45,
                        maximumDistance: 16
                    )
                    .onEnded { _ in
                        action()
                    }
                )
                .accessibilityAction(
                    named: "Show message actions",
                    action
                )
        } else {
            self
        }
    }
}

private struct VoiceMessageBubble: View {
    @Environment(\.encryptedAttachmentResolver) private var encryptedResolver
    let attachment: AttachmentContent
    @State private var downloadURL: URL?
    @State private var downloadError: String?

    var body: some View {
        Group {
            if let downloadError {
                AttachmentLoadFailure(
                    title: "Voice message unavailable",
                    detail: downloadError
                ) {
                    Task {
                        await loadDownloadURL()
                    }
                }
            } else {
                VoiceMessagePlaybackView(
                    sourceURL: downloadURL,
                    fallbackDuration: attachment.audioDuration,
                    prepareSource: EncryptedMediaLoading.isEncrypted(attachment) ? {
                        await loadDownloadURL()
                        return downloadURL
                    } : nil
                )
            }
        }
        .task(id: "\(attachment.storagePath ?? attachment.id)-\(String(describing: encryptedResolver.map(ObjectIdentifier.init)))") {
            if !EncryptedMediaLoading.isEncrypted(attachment) { await loadDownloadURL() }
        }
        .encryptedMediaLifetime(encryptedResolver) {
            if EncryptedMediaLoading.isEncrypted(attachment) { downloadURL = nil; downloadError = "Encrypted attachment unavailable" }
        }
        .accessibilityIdentifier("message-attachment")
    }

    private func loadDownloadURL() async {
        guard let path = attachment.storagePath else { return }
        do {
            downloadError = nil
            downloadURL = try await EncryptedMediaLoading.url(attachment, resolver: encryptedResolver) {
                try await Storage.storage().reference(withPath: path).downloadURL()
            }
        } catch {
            downloadURL = nil
            downloadError = error.localizedDescription
        }
    }
}

private struct AttachmentBubble: View {
    @Environment(\.encryptedAttachmentResolver) private var encryptedResolver
    @Environment(\.usesGiftWrap) private var usesGiftWrap
    @Environment(\.colorScheme) private var colorScheme
    let attachment: AttachmentContent
    var deliveryState: DeliveryState = .sent
    @State private var downloadURL: URL?
    @State private var downloadError: String?
    @State private var previewURL: URL?
    @State private var opening = false
    @State private var metadataLease = EncryptedMediaPresentationLease()
    @State private var previewGeneration = UUID()
    @State private var previewTask: Task<Void, Never>?

    var body: some View {
        Group {
            if attachment.type == .image {
                ImageAttachmentBubble(attachment: attachment, deliveryState: deliveryState)
            } else if EncryptedMediaLoading.isEncrypted(attachment) {
                Button {
                    openEncryptedPreview()
                } label: {
                    VStack(alignment: .leading) {
                        fileLabel
                        if downloadError != nil { Text("Attachment unavailable. Tap to retry.").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .buttonStyle(.plain)
                .disabled(opening)
            } else if let downloadURL {
                if downloadURL.isFileURL {
                    Button { previewURL = downloadURL } label: { fileLabel }.buttonStyle(.plain)
                } else {
                    Link(destination: downloadURL) { fileLabel }.buttonStyle(.plain)
                }
            } else if let downloadError {
                AttachmentLoadFailure(
                    title: "Attachment unavailable",
                    detail: downloadError
                ) {
                    Task {
                        await loadDownloadURL()
                    }
                }
            } else {
                fileLabel
                    .overlay(alignment: .trailing) {
                        if attachment.storagePath != nil {
                            ActivitySpinner()
                                .padding(.trailing, 12)
                        }
                    }
            }
        }
        .quickLookPreview($previewURL)
        .encryptedMediaLifetime(encryptedResolver) {
            if EncryptedMediaLoading.isEncrypted(attachment) {
                closePreview(); downloadError = "Encrypted attachment unavailable"
            }
        }
        .onChange(of: previewURL) { _, value in if value == nil { closePreview() } }
        .onChange(of: attachment) { _, _ in closePreview() }
        .onDisappear { if previewURL == nil { closePreview() } }
        .task(id: "\(attachment.storagePath ?? attachment.id)-\(String(describing: encryptedResolver.map(ObjectIdentifier.init)))") {
            if attachment.type != .image, !EncryptedMediaLoading.isEncrypted(attachment) {
                await loadDownloadURL()
            }
        }
    }

    private func openEncryptedPreview() {
        guard !opening else { return }
        do { try metadataLease.acquire([attachment], resolver: encryptedResolver) }
        catch { downloadError = "Encrypted attachment unavailable"; return }
        let generation = UUID(); previewGeneration = generation; opening = true
        previewTask = Task { @MainActor in
            defer {
                if previewGeneration == generation {
                    opening = false; previewTask = nil
                    if previewURL == nil { metadataLease.release() }
                }
            }
            await loadDownloadURL()
            guard !Task.isCancelled, previewGeneration == generation else { return }
            if let downloadURL { previewURL = downloadURL }
        }
    }

    private func closePreview() {
        previewGeneration = UUID(); previewTask?.cancel(); previewTask = nil
        previewURL = nil; opening = false; metadataLease.release()
        if EncryptedMediaLoading.isEncrypted(attachment) { downloadURL = nil }
    }

    private func loadDownloadURL() async {
        guard let path = attachment.storagePath else { return }
        let generation = previewGeneration
        let resolver = encryptedResolver
        do {
            downloadError = nil
            let url = try await EncryptedMediaLoading.url(attachment, resolver: resolver) {
                try await Storage.storage().reference(withPath: path).downloadURL()
            }
            guard !Task.isCancelled, previewGeneration == generation else { return }
            try EncryptedMediaLoading.validate(attachment, resolver: resolver)
            downloadURL = url
        } catch {
            guard !Task.isCancelled, previewGeneration == generation else { return }
            downloadURL = nil
            downloadError = error.localizedDescription
        }
    }

    private var fileLabel: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.fileName)
                    .lineLimit(2)
                Text(
                    ByteCountFormatter.string(
                        fromByteCount: attachment.byteSize,
                        countStyle: .file
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } icon: {
            Image(
                systemName: attachment.type == .video
                    ? "play.rectangle.fill"
                    : "doc.fill"
            )
            .font(.title2)
            .foregroundStyle(usesGiftWrap ? GiftWrapAppearance.accent(colorScheme == .dark) : .indigo)
        }
        .padding(12)
        .frame(maxWidth: 280, alignment: .leading)
        .background(
            usesGiftWrap ? GiftWrapAppearance.incoming(colorScheme == .dark) : Color(.secondarySystemBackground),
            in: .rect(cornerRadius: 18)
        )
    }
}

private struct ImageAttachmentBubble: View {
    @Environment(\.encryptedAttachmentResolver) private var encryptedResolver
    @State private var metadataLease = EncryptedMediaPresentationLease()
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let attachment: AttachmentContent
    let deliveryState: DeliveryState

    @State private var downloadURL: URL?
    @State private var downloadError: String?
    @State private var image: UIImage?
    @State private var imageAttempt = 0
    @State private var isPresentingPhoto = false
    @Namespace private var photoTransition

    init(attachment: AttachmentContent, deliveryState: DeliveryState = .sent) {
        self.attachment = attachment
        self.deliveryState = deliveryState
        _image = State(
            initialValue: (EncryptedMediaLoading.isEncrypted(attachment)) ? nil : AttachmentImageCache.shared.memoryImage(
                forKey: attachment.id
            )
        )
    }

    private var displayedImage: UIImage? {
        image ?? encryptedResolver?.cachedChatPhoto(attachment)
    }

    private var photoSize: CGSize {
        singlePhotoSize(displayedImage?.size)
    }

    var body: some View {
        Group {
            if let image = displayedImage {
                Button {
                    do { try metadataLease.acquire([attachment], resolver: encryptedResolver) }
                    catch { downloadError = "Encrypted attachment unavailable"; return }
                    isPresentingPhoto = true
                } label: {
                    imageContent(image)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(attachment.fileName)")
                .matchedTransitionSource(
                    id: attachment.id,
                    in: photoTransition
                ) { source in
                    source.clipShape(
                        .rect(cornerRadius: 18)
                    )
                }
            } else if let downloadError {
                AttachmentLoadFailure(
                    title: "Photo unavailable",
                    detail: downloadError
                ) {
                    self.downloadError = nil
                    imageAttempt += 1
                }
            } else {
                PhotoAttachmentLoadingView()
            }
        }
        .frame(width: photoSize.width, height: photoSize.height)
        .clipShape(.rect(cornerRadius: 18))
        .task(id: loadTaskID) {
            await loadImage()
        }
        .encryptedMediaLifetime(encryptedResolver) {
            metadataLease.release()
            if EncryptedMediaLoading.isEncrypted(attachment) { image = nil; downloadURL = nil; isPresentingPhoto = false }
        }
        .fullScreenCover(isPresented: $isPresentingPhoto, onDismiss: { metadataLease.release() }) {
            if let image = displayedImage {
                if reduceMotion {
                    photoLightbox(image: image)
                } else {
                    photoLightbox(image: image)
                        .navigationTransition(
                            .zoom(
                                sourceID: attachment.id,
                                in: photoTransition
                            )
                        )
                }
            }
        }
        .onChange(of: isPresentingPhoto, initial: true) {
            _, isPresented in
            model.conversationObscurationDidChange(
                .photo(attachment.id),
                isObscured: isPresented
            )
        }
        .onDisappear {
            model.conversationObscurationDidChange(
                .photo(attachment.id),
                isObscured: false
            )
        }
        .onDisappear { if !isPresentingPhoto { metadataLease.release() } }
        .accessibilityIdentifier("message-attachment")
    }

    private func photoLightbox(image: UIImage) -> some View {
        PhotoLightbox(
            image: image,
            downloadURL: downloadURL,
            fileName: attachment.fileName,
            encryptedAttachment: EncryptedMediaLoading.isEncrypted(attachment) ? attachment : nil
        ) {
            isPresentingPhoto = false
        }
    }

    private var loadTaskID: EncryptedMediaTaskIdentity<EncryptedPhotoPreviewPolicy.LoadKey> {
        .init(resource: .init(attachment: attachment, fallbackID: attachment.id, deliveryState: deliveryState, manualAttempt: imageAttempt),
              resolver: encryptedResolver.map(ObjectIdentifier.init))
    }

    private func imageContent(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(width: photoSize.width, height: photoSize.height)
            .contentShape(.rect)
    }

    private func loadImage() async {
        guard EncryptedPhotoPreviewPolicy.isReady(attachment, deliveryState: deliveryState) else { return }
        if EncryptedMediaLoading.isEncrypted(attachment) {
            do {
                guard let encryptedResolver else { throw EncryptedMediaError.unavailable }
                let decoded = try await encryptedResolver.chatPhoto(attachment)
                try EncryptedMediaLoading.validate(attachment, resolver: encryptedResolver)
                image = decoded; downloadURL = nil; downloadError = nil
            } catch {
                guard EncryptedMediaLoading.shouldPublishFailure(error) else { return }
                image = nil; downloadURL = nil; downloadError = "Encrypted photo unavailable"
            }
            return
        }
        if
            image == nil,
            let cachedImage = await AttachmentImageCache.shared.loadImage(
                forKey: attachment.id
            )
        {
            guard !Task.isCancelled else { return }
            image = cachedImage
        }

        guard let path = attachment.storagePath else { return }

        do {
            downloadError = nil
            let resolvedURL: URL
            if let downloadURL {
                resolvedURL = downloadURL
            } else {
                resolvedURL = try await Storage.storage()
                    .reference(withPath: path)
                    .downloadURL()
                try Task.checkCancellation()
                downloadURL = resolvedURL
            }

            guard image == nil else { return }

            let (data, response) = try await URLSession.shared.data(
                from: resolvedURL
            )
            if
                let response = response as? HTTPURLResponse,
                !(200..<300).contains(response.statusCode)
            {
                throw URLError(.badServerResponse)
            }
            guard
                let loadedImage = await AttachmentImageCache.displayImage(
                    from: data
                )
            else {
                throw URLError(.cannotDecodeContentData)
            }
            guard !Task.isCancelled else { return }
            await AttachmentImageCache.shared.storeDownloadedImage(
                loadedImage,
                forKey: attachment.id
            )
            try Task.checkCancellation()
            image = loadedImage
        } catch {
            guard EncryptedMediaLoading.shouldPublishFailure(error) else { return }
            if image == nil {
                downloadError = error.localizedDescription
            }
        }
    }
}

private struct PhotoGroupBubble: View {
    @Environment(\.encryptedAttachmentResolver) private var encryptedResolver
    @Environment(\.openURL) private var openURL
    @State private var saveOperation = PhotoGroupSaveOperation()
    @State private var metadataLease = EncryptedMediaPresentationLease()
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let group: PhotoMessageGroup

    @State private var loadedImages: [UUID: UIImage]
    @State private var downloadURLs: [UUID: URL] = [:]
    @State private var failedImageIDs: Set<UUID> = []
    @State private var isPresentingPhotos = false
    @State private var selectedPhotoID: UUID?

    init(group: PhotoMessageGroup) {
        self.group = group
        _loadedImages = State(
            initialValue: Dictionary(
                uniqueKeysWithValues: group.messages.compactMap { message in
                    guard !EncryptedMediaLoading.isEncrypted(message.attachment) else { return nil }
                    return AttachmentImageCache.shared.memoryImage(
                        forKey: message.id.uuidString
                    ).map { (message.id, $0) }
                }
            )
        )
        _selectedPhotoID = State(initialValue: group.messages.first?.id)
    }

    // The resolver owns decoded encrypted thumbnails across native cell reuse.
    private var images: [UUID: UIImage] {
        var result = loadedImages
        for message in group.messages where result[message.id] == nil {
            if let attachment = message.attachment,
               let cached = encryptedResolver?.cachedChatPhoto(attachment) {
                result[message.id] = cached
            }
        }
        return result
    }

    var body: some View {
        Button {
            guard let firstAvailableID = lightboxItems.first?.id else {
                return
            }
            selectedPhotoID = images[selectedPhotoID ?? group.id] == nil
                ? firstAvailableID
                : selectedPhotoID
            do { try metadataLease.acquire(group.messages.compactMap(\.attachment), resolver: encryptedResolver) }
                    catch { return }
                    isPresentingPhotos = true
        } label: {
            stack
        }
        .buttonStyle(.plain)
        .disabled(lightboxItems.isEmpty)
        .id(encryptedResolver.map(ObjectIdentifier.init))
        .encryptedMediaLifetime(encryptedResolver) {
            metadataLease.release()
            if group.messages.contains(where: { EncryptedMediaLoading.isEncrypted($0.attachment) }) {
                loadedImages.removeAll(); downloadURLs.removeAll(); isPresentingPhotos = false
            }
        }
        .task(id: EncryptedMediaTaskIdentity(resource: PhotoGroupImageLoadKey(group: group), resolver: encryptedResolver.map(ObjectIdentifier.init))) {
            await loadImages()
        }
        .contextMenu {
            Button("Save All", systemImage: "square.and.arrow.down.on.square") {
                Task { await saveAllPhotos() }
            }
            .disabled(!saveOperation.canSave(lightboxItems))
        }
        .alert(item: $saveOperation.alert) { alert in
            alert.presentation {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
        }
        .fullScreenCover(isPresented: $isPresentingPhotos, onDismiss: { metadataLease.release() }) {
            PhotoGroupLightbox(
                items: lightboxItems,
                initialPhotoID: selectedPhotoID,
                isPresented: $isPresentingPhotos
            )
        }
        .onChange(of: isPresentingPhotos, initial: true) {
            _, isPresented in
            model.conversationObscurationDidChange(
                .photoGroup(group.id),
                isObscured: isPresented
            )
        }
        .onDisappear {
            model.conversationObscurationDidChange(
                .photoGroup(group.id),
                isObscured: false
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens all available photos")
        .onDisappear { if !isPresentingPhotos { metadataLease.release() } }
        .accessibilityIdentifier("message-photo-group")
    }

    private let cardSize = CGSize(width: 224, height: 202)
    private let cardRadius: CGFloat = 18

    private var stack: some View {
        ZStack {
            ForEach(
                Array(stackMessages.enumerated()).reversed(),
                id: \.element.id
            ) { index, message in
                card(for: message)
                    .rotationEffect(.degrees(stackRotation(at: index)))
                    .offset(
                        x: stackOffset(at: index).width,
                        y: stackOffset(at: index).height
                    )
            }
        }
        .frame(width: 252, height: 232)
        .overlay { AttachmentLights(messageID: group.id, perimeter: stackPerimeter) }
        .contentShape(.rect(cornerRadius: 22))
        .overlay(alignment: .topLeading) {
            if availability.failedCount > 0 {
                Image(systemName: "exclamationmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(.red, in: .circle)
                    .padding(9)
                    .accessibilityHidden(true)
            }
        }
        .padding(7)
    }

    private var availability: PhotoGroupAvailability.Summary {
        PhotoGroupAvailability.summary(
            group: group,
            loadedImageIDs: Set(images.keys),
            failedImageIDs: failedImageIDs
        )
    }

    private var stackMessages: [ChatMessage] {
        // An unavailable first photo must not cover another photo that is ready.
        let available = group.messages.filter { availability.availableImageIDs.contains($0.id) }
        let remaining = group.messages.filter { !availability.availableImageIDs.contains($0.id) }
        return Array((available + remaining).prefix(3))
    }

    private func card(for message: ChatMessage) -> some View {
        ZStack {
            Color(.secondarySystemBackground)
            if isUnavailable(message) {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.title2)
                    .foregroundStyle(.red)
            } else if let image = images[message.id] {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: cardSize.width, height: cardSize.height)
                    .transition(.opacity)
            } else {
                PhotoAttachmentLoadingView()
            }
        }
        .frame(width: cardSize.width, height: cardSize.height)
        .clipShape(.rect(cornerRadius: cardRadius))
        .shadow(
            color: .black.opacity(reduceMotion ? 0.10 : 0.18),
            radius: 5,
            y: 3
        )
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.16),
            value: images[message.id] != nil
        )
    }

    private func stackOffset(at index: Int) -> CGSize {
        CGSize(width: CGFloat(index) * 5, height: CGFloat(index) * -5)
    }

    private func stackPerimeter(in bounds: CGRect) -> CGPath {
        let rect = CGRect(x: -cardSize.width / 2, y: -cardSize.height / 2,
                          width: cardSize.width, height: cardSize.height)
        let card = Path(roundedRect: rect, cornerRadius: cardRadius, style: .continuous)
        return stackMessages.indices.reduce(CGMutablePath() as CGPath) { outline, index in
            let offset = stackOffset(at: index)
            let transform = CGAffineTransform(translationX: bounds.midX + offset.width,
                                              y: bounds.midY + offset.height)
                .rotated(by: stackRotation(at: index) * .pi / 180)
            return outline.union(card.applying(transform).cgPath)
        }
    }

    private func stackRotation(at index: Int) -> Double {
        switch index {
        case 0: 0
        case 1: -3.5
        default: 3
        }
    }

    private var lightboxItems: [PhotoLightboxItem] {
        group.messages.compactMap { message in
            let image = images[message.id]
            guard
                PhotoGroupAvailability.isAvailable(
                    hasImage: image != nil,
                    deliveryState: message.deliveryState,
                    imageLoadFailed: failedImageIDs.contains(message.id)
                ),
                let image
            else {
                return nil
            }
            return PhotoLightboxItem(
                id: message.id,
                image: image,
                downloadURL: downloadURLs[message.id],
                fileName: message.attachment?.fileName
                    ?? (
                        message.body.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                            ? "Photo"
                            : message.body
                    ),
                encryptedAttachment: EncryptedMediaLoading.isEncrypted(message.attachment) ? message.attachment : nil
            )
        }
    }

    private func isUnavailable(_ message: ChatMessage) -> Bool {
        PhotoGroupAvailability.isUnavailable(
            deliveryState: message.deliveryState,
            imageLoadFailed: failedImageIDs.contains(message.id)
        )
    }

    private var accessibilityLabel: String {
        var components = [
            "\(group.expectedCount)-photo group",
            "\(lightboxItems.count) available",
        ]
        if availability.loadingCount > 0 {
            components.append("\(availability.loadingCount) loading")
        }
        if availability.failedCount > 0 {
            components.append("\(availability.failedCount) failed")
        }
        return components.joined(separator: ", ")
    }

    private func saveAllPhotos() async {
        let lease = EncryptedMediaPresentationLease()
        do {
            try lease.acquire(group.messages.compactMap(\.attachment), resolver: encryptedResolver)
            defer { lease.release() }
            await saveOperation.save(lightboxItems, resolver: encryptedResolver)
        } catch {
            saveOperation.alert = .saveFailed(error.localizedDescription)
        }
    }

    private func loadImages() async {
        await PhotoGroupImageLoading.load(group.messages) { message in
            await loadImage(message)
        }
    }

    private func loadImage(_ message: ChatMessage) async {
        guard !Task.isCancelled else { return }
        guard EncryptedPhotoPreviewPolicy.isReady(message.attachment, deliveryState: message.deliveryState) else { return }
        if let attachment = message.attachment, EncryptedMediaLoading.isEncrypted(attachment) {
            guard loadedImages[message.id] == nil else { return }
            do {
                guard let encryptedResolver else { throw EncryptedMediaError.unavailable }
                let decoded = try await encryptedResolver.chatPhoto(attachment)
                try EncryptedMediaLoading.validate(attachment, resolver: encryptedResolver)
                loadedImages[message.id] = decoded; failedImageIDs.remove(message.id)
            } catch {
                guard EncryptedMediaLoading.shouldPublishFailure(error) else { return }
                loadedImages[message.id] = nil; downloadURLs[message.id] = nil; failedImageIDs.insert(message.id)
            }
            return
        }

        if
            loadedImages[message.id] == nil,
            let cachedImage = await AttachmentImageCache.shared.loadImage(
                forKey: message.id.uuidString
            )
        {
            guard !Task.isCancelled else { return }
            loadedImages[message.id] = cachedImage
        }
        guard
            let attachment = message.attachment,
            let path = attachment.storagePath
        else {
            // Pending sends and freshly received photo metadata can
            // legitimately have no remote path yet. Keep their loading
            // card instead of flashing an unavailable-photo warning.
            return
        }

        do {
            let downloadURL: URL
            if let existingURL = downloadURLs[message.id] {
                downloadURL = existingURL
            } else {
                downloadURL = try await Storage.storage()
                    .reference(withPath: path)
                    .downloadURL()
                try Task.checkCancellation()
                downloadURLs[message.id] = downloadURL
            }

            if loadedImages[message.id] == nil {
                let (data, response) = try await URLSession.shared.data(
                    from: downloadURL
                )
                if
                    let response = response as? HTTPURLResponse,
                    !(200..<300).contains(response.statusCode)
                {
                    throw URLError(.badServerResponse)
                }
                guard
                    let loadedImage = await AttachmentImageCache.displayImage(
                        from: data
                    )
                else {
                    throw URLError(.cannotDecodeContentData)
                }
                guard !Task.isCancelled else { return }
                await AttachmentImageCache.shared.storeDownloadedImage(
                    loadedImage,
                    forKey: message.id.uuidString
                )
                try Task.checkCancellation()
                loadedImages[message.id] = loadedImage
            }
            failedImageIDs.remove(message.id)
        } catch {
            guard EncryptedMediaLoading.shouldPublishFailure(error) else { return }
            if loadedImages[message.id] == nil {
                failedImageIDs.insert(message.id)
            }
        }
    }
}

private struct PhotoAttachmentLoadingView: View {
    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)
            ActivitySpinner()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading photo")
    }
}

private struct AttachmentLoadFailure: View {
    let title: String
    let detail: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: "exclamationmark.triangle")
                .font(.callout.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Button("Try again", action: retry)
                .font(.caption.weight(.semibold))
        }
        .padding(12)
        .frame(maxWidth: 280, alignment: .leading)
        .background(
            Color(.secondarySystemBackground),
            in: .rect(cornerRadius: 18)
        )
    }
}

private struct LinkBubble: View {
    @Environment(\.usesGiftWrap) private var usesGiftWrap

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    let messageID: UUID
    let messageText: String
    let isCurrentUser: Bool
    private let presentation: LinkPreviewMessagePresentation?
    @State private var displayState: LinkPreviewDisplayState

    init(messageID: UUID, messageText: String, isCurrentUser: Bool) {
        self.messageID = messageID
        self.messageText = messageText
        self.isCurrentUser = isCurrentUser
        presentation = LinkPreviewMessagePresentation(
            messageText: messageText
        )
        _displayState = State(initialValue: LinkPreviewDisplayState(
            url: presentation?.previewURL
        ))
    }

    var body: some View {
        Group {
            if let presentation, preview != nil {
                VStack(alignment: .leading, spacing: 0) {
                    if let caption = presentation.previewCaption {
                        Text(caption)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .tint(accent)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding([.horizontal, .top], 12)
                            .accessibilityIdentifier("embedded-link-message-text")
                    }

                    Button {
                        openURL(presentation.previewURL)
                    } label: {
                        previewCard
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("link-preview-card")
                }
                .frame(maxWidth: 280, alignment: .leading)
                .background(cardBackground)
                .clipShape(.rect(cornerRadius: 18))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(accent.opacity(0.18), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .overlay { AttachmentLights(messageID: messageID) }
            } else {
                Text(presentation?.attributedOriginalMessage ?? AttributedString(messageText))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .foregroundStyle(isCurrentUser ? .white : .primary)
                    .tint(isCurrentUser ? .white : accent)
                    .background(
                        isCurrentUser
                            ? (usesGiftWrap ? AnyShapeStyle(GiftWrapAppearance.pine.gradient) : AnyShapeStyle(Color.indigo.gradient))
                            : AnyShapeStyle(usesGiftWrap ? GiftWrapAppearance.incoming(colorScheme == .dark) : Color(.secondarySystemBackground)),
                        in: .rect(cornerRadius: 18)
                    )
            }
        }
        .task(id: presentation?.previewURL.absoluteString) {
            await displayState.load(for: presentation?.previewURL)
        }
    }

    private var accent: Color {
        usesGiftWrap ? GiftWrapAppearance.accent(colorScheme == .dark) : .indigo
    }

    private var cardBackground: Color {
        if usesGiftWrap { return GiftWrapAppearance.field(colorScheme == .dark) }
        return isCurrentUser ? Color.indigo.opacity(0.10) : Color(.secondarySystemBackground)
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let previewImage = preview?.image {
                Image(uiImage: previewImage)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 128)
                    .clipped()
                    .clipShape(.rect(cornerRadius: 13))
                    .accessibilityHidden(true)
            }

            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent)
                    .frame(width: 26, height: 26)
                    .background(accent.opacity(0.14), in: .circle)

                Text(displayDomain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Image(systemName: "arrow.up.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }

            Text(displayTitle)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)

            if let displayDescription {
                Text(displayDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(12)
        .frame(maxWidth: 280, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(displayTitle), \(displayDomain)")
    }

    private var preview: LinkPreviewDisplaySnapshot? {
        displayState.snapshot(for: presentation?.previewURL)
    }

    private var displayDomain: String {
        LinkPreviewText(
            urlText: presentation?.previewURL.absoluteString ?? messageText
        ).domain
    }

    private var displayTitle: String {
        if
            let metadataTitle = preview?.metadata.title,
            !LinkPreviewText.looksOpaqueIdentifier(metadataTitle)
        {
            return metadataTitle
        }
        return LinkPreviewText(
            urlText: presentation?.previewURL.absoluteString ?? messageText
        ).title
    }

    private var displayDescription: String? {
        preview?.metadata.description
    }

}

/// Separate SwiftUI hosts cannot share anchor preferences. Resolve the bubble
/// from its live native view at interaction time in the window's coordinate space.
@MainActor
final class ConversationMessageFrames {
    private final class WeakView {
        weak var view: UIView?
        init(_ view: UIView) { self.view = view }
    }
    private var views: [UUID: WeakView] = [:]

    func register(_ view: UIView, for id: UUID) {
        if views.count > 350 { views = views.filter { $0.value.view?.window != nil } }
        views[id] = WeakView(view)
    }

    func frame(for id: UUID) -> CGRect? {
        guard let view = views[id]?.view, let window = view.window,
              !view.bounds.isEmpty else { return nil }
        return view.convert(view.bounds, to: window)
    }
}

private struct ConversationMessageFrameMarker: UIViewRepresentable {
    let id: UUID
    let frames: ConversationMessageFrames?
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        frames?.register(view, for: id)
        return view
    }
    func updateUIView(_ view: UIView, context: Context) { frames?.register(view, for: id) }
}

extension EnvironmentValues {
    @Entry var conversationMessageFrames: ConversationMessageFrames? = nil
}
