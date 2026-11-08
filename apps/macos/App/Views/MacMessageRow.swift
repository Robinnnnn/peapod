import AppKit
@preconcurrency import AVFoundation
import Combine
@preconcurrency import FirebaseStorage
import MapKit
import SwiftUI

private func macSinglePhotoSize(_ imageSize: CGSize?) -> CGSize {
    ChatPhotoLayout.size(for: imageSize, maximum: CGSize(width: 260, height: 340),
                        placeholder: CGSize(width: 260, height: 220))
}

struct MacMessageRow: View {
    @Environment(\.encryptedAttachmentResolver) private var encryptedResolver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    let message: ChatMessage
    let photoGroup: PhotoMessageGroup?
    let replyMessage: ChatMessage?
    let isCurrentUser: Bool
    let currentUserID: String
    let partnerName: String
    let grouping: MessageGroupPosition
    let showsDeliveryStatus: Bool
    let isLatestOutgoing: Bool
    let timestampsRevealed: Bool
    let groupTailHasPersistentMetadata: Bool
    let showReply: () -> Void
    let toggleTimestamps: () -> Void
    let reply: () -> Void
    let edit: () -> Void
    let unsend: () -> Void
    let react: (String) -> Void
    let retry: () -> Void
    var pendingShareStatus: PendingShareTimelineStatus? = nil
    var discardPending: (() -> Void)? = nil
    var discardPendingGroup: (() -> Void)? = nil

    var isPinned = false
    var pinIsPending = false
    var togglePin: (() -> Void)? = nil
    var allowsMessageActions = true
    var showInConversation: (() -> Void)? = nil

    private let clipboard = MacClipboard()

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isCurrentUser {
                Spacer(minLength: 90)
            }

            VStack(
                alignment: isCurrentUser ? .trailing : .leading,
                spacing: 4
            ) {
                if message.replyToID != nil {
                    replyPreview
                }

                messageBubble
                    .allowsHitTesting(showInConversation == nil)

                messageMetadata
            }
            .frame(maxWidth: 540, alignment: isCurrentUser ? .trailing : .leading)

            if !isCurrentUser {
                Spacer(minLength: 90)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(
            .bottom,
            reservesFloatingTimestampSpace ? 8 : 0
        )
        .offset(
            y:
                MessageTimestampVisibility.shouldLiftGroup(
                    timestampsRevealed: timestampsRevealed,
                    groupTailHasPersistentMetadata:
                        groupTailHasPersistentMetadata
                )
                    && !reduceMotion
                ? -3
                : 0
        )
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.16),
            value: timestampsRevealed
        )
        .animation(
            reduceMotion ? .easeOut(duration: 0.12) : .snappy(duration: 0.2),
            value: message.reactions
        )
        .contentShape(.rect)
        .contextMenu {
            if let showInConversation {
                Button("Show in Conversation", systemImage: "bubble.left", action: showInConversation)
            }
            if let togglePin, MessagePinningPolicy.canPin(message) {
                Button(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.slash" : "pin", action: togglePin)
                    .disabled(pinIsPending)
            }
            if allowsMessageActions { messageMenu }
        }
        .onTapGesture {
            if let showInConversation { showInConversation() } else { toggleTimestamps() }
        }
        .accessibilityElement(children: showInConversation == nil ? .contain : .combine)
        .accessibilityIdentifier("message-row-\(message.id.uuidString)")
        .accessibilityAction(
            named: showInConversation != nil
                ? "Open in Conversation"
                : (timestampsRevealed ? "Hide message times" : "Show message times")
        ) {
            if let showInConversation { showInConversation() } else { toggleTimestamps() }
        }
    }

    private var messageBubble: some View {
        pinReadyBubbleContent
            .overlay(alignment: .bottomTrailing) {
                if isPinned, !message.isUnsent {
                    MessagePinBadge(isOutgoing: isCurrentUser && isPlainTextBubble, overMedia: pinIsOverMedia)
                }
            }
            .overlay(
                alignment:
                    isCurrentUser
                    ? .bottomTrailing
                    : .bottomLeading
            ) {
                floatingTimestamp
            }
            .overlay(alignment: reactionBadgeAlignment) {
                if !message.isUnsent, !message.reactions.isEmpty {
                    reactions
                        .offset(
                            x: MacMessageReactionBadgeLayout
                                .horizontalOffset(
                                    isCurrentUser: isCurrentUser
                                ),
                            y: MacMessageReactionBadgeLayout.verticalOffset
                        )
                        .transition(reactionAppearanceTransition)
                }
            }
            .padding(
                .top,
                message.reactions.isEmpty || message.isUnsent
                    ? 0
                    : MacMessageReactionBadgeLayout.reservedDepth
            )
            .textSelection(.enabled)
            .onTapGesture(count: 2, perform: reply)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(
                "message-bubble-\(message.id.uuidString)"
            )
    }

    private var isPlainTextBubble: Bool {
        message.kind == .text && LinkPreviewSelection.first(in: message.body) == nil
    }

    private var pinIsOverMedia: Bool {
        photoGroup != nil || (message.kind == .attachment && message.attachment?.type == .image)
    }

    @ViewBuilder
    private var pinReadyBubbleContent: some View {
        if isPinned, !message.isUnsent, !isPlainTextBubble, !pinIsOverMedia {
            // Keep the marker away from playback, save and link controls.
            displayedBubbleContent
                .padding(.bottom, 22)
                .background(incomingMessageBackground, in: bubbleShape)
        } else {
            displayedBubbleContent
        }
    }

    @ViewBuilder
    private var displayedBubbleContent: some View {
        if
            message.kind == .voice
                || message.kind == .attachment
                || photoGroup != nil
                || message.attachment?.type == .image
                || (
                    !message.isUnsent
                        && (message.kind == .link || message.kind == .text)
                        && LinkPreviewSelection.first(
                            in: message.body
                        ) != nil
                )
        {
            bubbleContent
        } else {
            bubbleContent.clipShape(bubbleShape)
        }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        if message.isUnsent {
            Label("Message unsent", systemImage: "nosign")
                .font(.callout.italic())
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .foregroundStyle(.secondary)
                .background(incomingMessageBackground, in: bubbleShape)
        } else {
            switch message.kind {
            case .text:
                if LinkPreviewSelection.first(in: message.body) != nil {
                    MacLinkMessageView(
                        messageText: message.body,
                        isCurrentUser: isCurrentUser, messageID: message.id
                    )
                } else {
                    Text(message.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.trailing, isPinned ? 18 : 0)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 9)
                        .foregroundStyle(isCurrentUser ? .white : .primary)
                        .background(
                            isCurrentUser
                                ? AnyShapeStyle(GiftWrapAppearance.outgoing(colorScheme == .dark))
                                : AnyShapeStyle(incomingMessageBackground)
                        )
                }
            case .link:
                MacLinkMessageView(
                    messageText: message.body,
                    isCurrentUser: isCurrentUser, messageID: message.id
                )
            case .attachment:
                if let photoGroup {
                    MacPhotoGroupView(group: photoGroup)
                } else if let attachment = message.attachment {
                    if attachment.type == .image {
                        MacAttachmentView(attachment: attachment, deliveryState: message.deliveryState)
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
                        MacAttachmentView(attachment: attachment, deliveryState: message.deliveryState)
                            .clipShape(bubbleShape)
                            .overlay { AttachmentLights(messageID: message.id, perimeter: { bubbleShape.path(in: $0).cgPath }) }
                    }
                } else if
                    let cachedImage = MacAttachmentImageCache.shared.image(
                        forKey: message.id.uuidString
                    )
                {
                    Image(nsImage: cachedImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: macSinglePhotoSize(cachedImage.size).width,
                               height: macSinglePhotoSize(cachedImage.size).height)
                        .clipped()
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
                    fallbackBubble(
                        message.body.isEmpty ? "Attachment" : message.body,
                        systemImage: "paperclip"
                    )
                }
            case .voice:
                if let attachment = message.attachment {
                    MacVoiceMessageView(attachment: attachment)
                        .clipShape(bubbleShape)
                        .overlay { AttachmentLights(messageID: message.id, perimeter: { bubbleShape.path(in: $0).cgPath }) }
                } else {
                    fallbackBubble(
                        "Voice message",
                        systemImage: "waveform"
                    )
                }
            case .liveLocation:
                if let location = message.liveLocation {
                    MacLocationMessageView(
                        location: location,
                        isCurrentUser: isCurrentUser
                    )
                } else {
                    fallbackBubble(
                        "Location sharing ended",
                        systemImage: "location.slash"
                    )
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
                    grouping.joinsNext ? groupedRadius : fullRadius,
                topTrailingRadius:
                    grouping.joinsPrevious ? groupedRadius : fullRadius,
                style: .continuous
            )
        }

        return UnevenRoundedRectangle(
            topLeadingRadius:
                grouping.joinsPrevious ? groupedRadius : fullRadius,
            bottomLeadingRadius:
                grouping.joinsNext ? groupedRadius : fullRadius,
            bottomTrailingRadius: fullRadius,
            topTrailingRadius: fullRadius,
            style: .continuous
        )
    }

    private var replyPreview: some View {
        Button(action: showReply) {
            HStack(spacing: 7) {
                Capsule()
                    .fill(GiftWrapAppearance.accent(colorScheme == .dark))
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(
                        replyMessage?.senderID == currentUserID
                            ? "You"
                            : partnerName
                    )
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(GiftWrapAppearance.accent(colorScheme == .dark))
                    Text(
                        replyMessage?.replyPreviewText
                            ?? "Original message unavailable"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(incomingMessageBackground, in: .rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help("Show replied-to message")
        .accessibilityLabel("Show replied-to message")
    }

    private var reactions: some View {
        HStack(spacing: 3) {
            ForEach(
                Array(reactionSummary.enumerated()),
                id: \.element.emoji
            ) { index, item in
                Button {
                    react(item.emoji)
                } label: {
                    reactionLabel(for: item)
                        .frame(
                            width:
                                MacMessageReactionBadgeLayout.hitTargetSize,
                            height:
                                MacMessageReactionBadgeLayout.hitTargetSize
                        )
                        .background(Color.clear)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    MacConversationPresentation.reactionAccessibilityLabel(
                        emoji: item.emoji,
                        count: item.count,
                        includesCurrentUser: item.isCurrentUser
                    )
                )
                .help(
                    item.isCurrentUser
                        ? "Remove your reaction"
                        : "React with \(item.emoji)"
                )
                .accessibilityIdentifier(
                    "message-reaction-\(message.id.uuidString)-\(index)"
                )
            }
        }
        .fixedSize()
        .allowsHitTesting(allowsMessageActions)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            "message-reactions-\(message.id.uuidString)"
        )
    }

    private func reactionLabel(
        for item: (emoji: String, count: Int, isCurrentUser: Bool)
    ) -> some View {
        Text(item.emoji)
            .font(
                .system(size: MacMessageReactionBadgeLayout.glyphSize)
            )
            .frame(
                width: MacMessageReactionBadgeLayout.visibleDiameter,
                height: MacMessageReactionBadgeLayout.visibleDiameter
            )

    }

    private var reactionBadgeAlignment: Alignment {
        isCurrentUser ? .topLeading : .topTrailing
    }

    private var reactionAppearanceTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .scale(scale: 0.88).combined(with: .opacity)
    }

    @ViewBuilder
    private var messageMetadata: some View {
        if showsPersistentMetadata {
            HStack(spacing: 4) {
                if showsTimestamp {
                    timestampLabel
                }

                if showsEditedStatus {
                    if showsTimestamp {
                        metadataSeparator
                    }
                    Text("Edited")
                }

                if showsMessageDeliveryStatus {
                    if showsTimestamp || showsEditedStatus {
                        metadataSeparator
                    }
                    deliveryLabel
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, pinIsOverMedia ? 12 : 5)
            .padding(.vertical, 1)
            .background(incomingMessageBackground, in: .capsule)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var floatingTimestamp: some View {
        if timestampEligible, !showsPersistentMetadata {
            timestampLabel
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(incomingMessageBackground, in: .capsule)
                .offset(y: 15)
                .opacity(timestampsRevealed ? 1 : 0)
                .accessibilityHidden(!timestampsRevealed)
                .allowsHitTesting(false)
        }
    }

    private var timestampLabel: some View {
        Text(MessageTimestampText.string(for: message.createdAt))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel(
                "Sent \(MessageTimestampText.accessibilityString(for: message.createdAt))"
            )
            .accessibilityIdentifier(
                "message-timestamp-\(message.id.uuidString)"
            )
    }

    private var showsTimestamp: Bool {
        MessageTimestampVisibility.isVisible(
            timestampsRevealed: timestampsRevealed,
            groupedWithNext: grouping.joinsNext
        )
    }

    private var timestampEligible: Bool {
        !grouping.joinsNext
    }

    private var showsEditedStatus: Bool {
        !message.isUnsent && message.editedAt != nil
    }

    private var showsMessageDeliveryStatus: Bool {
        isCurrentUser && showsDeliveryStatus
    }

    private var showsPersistentMetadata: Bool {
        showsEditedStatus || showsMessageDeliveryStatus
    }

    private var reservesFloatingTimestampSpace: Bool {
        timestampsRevealed
            && timestampEligible
            && !showsPersistentMetadata
    }

    private var metadataSeparator: some View {
        Text("·")
            .accessibilityHidden(true)
    }

    private var deliveryLabel: some View {
        Group {
            if
                message.kind == .liveLocation,
                message.deliveryState == .failed
            {
                Text("Not sent")
                    .foregroundStyle(.red)
            } else {
                MacMessageDeliveryStatusView(
                    state: message.deliveryState,
                    retry:
                        message.deliveryState == .failed
                            ? retry
                            : nil
                )
            }
        }
        .accessibilityIdentifier(
            isLatestOutgoing
                ? "latest-delivery-status"
                : "message-delivery-status-\(message.id.uuidString)"
        )
    }

    @ViewBuilder
    private var messageMenu: some View {
        if pendingShareStatus != nil {
            if let discardPending { Button("Remove Attachment", systemImage: "trash", action: discardPending) }
            if let discardPendingGroup { Button("Remove Attachment Group", systemImage: "trash", action: discardPendingGroup) }
        }
        if !message.isUnsent {
            Button("Reply", systemImage: "arrowshape.turn.up.left", action: reply)

            if message.kind == .text || message.kind == .link {
                Button("Copy", systemImage: "doc.on.doc") {
                    clipboard.setString(message.body)
                }
            }

            if let selection = LinkPreviewSelection.first(in: message.body) {
                Button("Copy Link", systemImage: "link") { clipboard.setURLText(selection.originalURLText) }
            }

            Menu("React", systemImage: "face.smiling") {
                ForEach(
                    MacConversationPresentation.reactionChoices,
                    id: \.self
                ) { emoji in
                    Button(emoji) {
                        react(emoji)
                    }
                    .accessibilityLabel(MessageReactionPalette.name(for: emoji))
                }
            }

            if let currentReaction = message.reactions[currentUserID] {
                Button("Remove Reaction", systemImage: "xmark.circle") {
                    react(currentReaction)
                }
            }
        }

        if isCurrentUser,
            !message.isUnsent,
            message.kind == .text || message.kind == .link
        {
            Divider()
            Button("Edit…", systemImage: "pencil", action: edit)
        }

        if isCurrentUser, !message.isUnsent {
            Button(
                "Unsend",
                systemImage: "trash",
                role: .destructive,
                action: unsend
            )
        }

        if isCurrentUser, message.deliveryState == .failed {
            Divider()
            Button("Try Again", systemImage: "arrow.clockwise", action: retry)
        }
    }

    private var reactionSummary: [
        (emoji: String, count: Int, isCurrentUser: Bool)
    ] {
        MacConversationPresentation.reactionSummary(
            for: message.reactions,
            currentUserID: currentUserID
        )
    }

    private var incomingMessageBackground: Color {
        GiftWrapAppearance.incoming(colorScheme == .dark)
    }

    private func fallbackBubble(
        _ title: String,
        systemImage: String
    ) -> some View {
        Label(title, systemImage: systemImage)
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .foregroundStyle(.secondary)
            .background(incomingMessageBackground, in: bubbleShape)
    }
}

private enum MacMessageReactionBadgeLayout {
    static let hitTargetSize: CGFloat = 44
    static let visibleDiameter: CGFloat = 32
    static let glyphSize: CGFloat = 24
    static let verticalOffset: CGFloat = -27
    static let reservedDepth: CGFloat = 20

    static func horizontalOffset(isCurrentUser: Bool) -> CGFloat {
        isCurrentUser ? -16 : 16
    }
}

private struct MacLinkMessageView: View {
    @Environment(\.colorScheme) private var colorScheme

    let messageText: String
    let stableLinkID: UUID
    let isCurrentUser: Bool
    private let presentation: LinkPreviewMessagePresentation?
    @State private var displayState: LinkPreviewDisplayState

    init(messageText: String, isCurrentUser: Bool, messageID: UUID) {
        self.stableLinkID = messageID
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
            if let presentation {
                if preview != nil {
                    VStack(alignment: .leading, spacing: 0) {
                        if let caption = presentation.previewCaption {
                            Text(caption)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding([.horizontal, .top], 12)
                                .accessibilityIdentifier("embedded-link-message-text")
                        }

                        Link(destination: presentation.previewURL) { previewCard }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("link-preview-card")
                    }
                    .frame(maxWidth: 300, alignment: .leading)
                    .background(GiftWrapAppearance.incoming(colorScheme == .dark))
                    .clipShape(.rect(cornerRadius: 18))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(GiftWrapAppearance.accent(colorScheme == .dark).opacity(0.12), lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                    .overlay { AttachmentLights(messageID: stableLinkID) }
                } else {
                    Text(presentation.attributedOriginalMessage)
                        .padding(.horizontal, 13).padding(.vertical, 9)
                        .foregroundStyle(isCurrentUser ? .white : .primary)
                        .background(isCurrentUser ? GiftWrapAppearance.outgoing(colorScheme == .dark) : GiftWrapAppearance.incoming(colorScheme == .dark), in: .rect(cornerRadius: 18))
                }
            } else {
                Text(messageText)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .foregroundStyle(isCurrentUser ? .white : .primary)
                    .background(
                        isCurrentUser
                            ? AnyShapeStyle(GiftWrapAppearance.outgoing(colorScheme == .dark))
                            : AnyShapeStyle(
                                GiftWrapAppearance.incoming(colorScheme == .dark)
                            )
                    )
            }
        }
        .task(id: presentation?.previewURL.absoluteString) {
            await displayState.load(for: presentation?.previewURL)
        }
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let image {
                image
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
                    .foregroundStyle(GiftWrapAppearance.accent(colorScheme == .dark))
                    .frame(width: 26, height: 26)
                    .background(GiftWrapAppearance.accent(colorScheme == .dark).opacity(0.14), in: .circle)

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
        .frame(maxWidth: 300, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(displayTitle), \(displayDomain)")
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

    private var image: Image? {
        guard let image = preview?.image else { return nil }
        return Image(nsImage: image)
    }

    private var preview: LinkPreviewDisplaySnapshot? {
        displayState.snapshot(for: presentation?.previewURL)
    }
}

private struct MacPhotoGroupView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.encryptedAttachmentResolver) private var encryptedResolver
    @State private var metadataLease = EncryptedMediaPresentationLease()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let group: PhotoMessageGroup

    @State private var loadedImages: [UUID: NSImage]
    @State private var failedImageIDs: Set<UUID> = []
    @State private var loadAttempt = 0
    @State private var isPresentingPhotos = false
    @State private var selectedPhotoID: UUID?

    init(group: PhotoMessageGroup) {
        self.group = group
        _loadedImages = State(
            initialValue: Dictionary(
                uniqueKeysWithValues: group.messages.compactMap { message in
                    guard !EncryptedMediaLoading.isEncrypted(message.attachment) else { return nil }
                    return MacAttachmentImageCache.shared.image(
                        forKey: message.id.uuidString
                    ).map { (message.id, $0) }
                }
            )
        )
        _selectedPhotoID = State(initialValue: group.messages.first?.id)
    }

    // The resolver owns decoded encrypted thumbnails across native cell reuse.
    private var images: [UUID: NSImage] {
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
            guard let firstAvailableID = previewItems.first?.id else {
                return
            }
            if images[selectedPhotoID ?? group.id] == nil {
                selectedPhotoID = firstAvailableID
            }
            do { try metadataLease.acquire(group.messages.compactMap(\.attachment), resolver: encryptedResolver) }
                    catch { return }
                    isPresentingPhotos = true
        } label: {
            stack
        }
        .buttonStyle(.plain)
        .contextMenu {
            if availability.failedCount > 0 {
                Button("Retry Loading Photos") { failedImageIDs.removeAll(); loadAttempt += 1 }
            }
        }
        .id(encryptedResolver.map(ObjectIdentifier.init))
        .encryptedMediaLifetime(encryptedResolver) {
            metadataLease.release()
            if group.messages.contains(where: { EncryptedMediaLoading.isEncrypted($0.attachment) }) { loadedImages.removeAll(); isPresentingPhotos = false }
        }
        .task(id: EncryptedMediaTaskIdentity(resource: group.messages.map { EncryptedPhotoPreviewPolicy.LoadKey(attachment: $0.attachment, fallbackID: $0.id.uuidString, deliveryState: $0.deliveryState, manualAttempt: loadAttempt) }, resolver: encryptedResolver.map(ObjectIdentifier.init))) {
            await loadImages()
        }
        .sheet(isPresented: $isPresentingPhotos, onDismiss: { metadataLease.release() }) {
            MacPhotoGroupPreview(
                items: previewItems,
                initialPhotoID: selectedPhotoID,
                expectedCount: group.expectedCount
            )
            .modifier(MacConversationPreviewReadObscuration())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens all available photos")
        .onDisappear { if !isPresentingPhotos { metadataLease.release() } }
        .accessibilityIdentifier("message-photo-group")
    }

    private var stack: some View {
        ZStack {
            ForEach(
                Array(stackMessages.enumerated()).reversed(),
                id: \.element.id
            ) { index, message in
                card(for: message)
                    .rotationEffect(.degrees(stackRotation(at: index)))
                    .offset(
                        x: CGFloat(index) * 5,
                        y: CGFloat(index) * -5
                    )
            }
        }
        .frame(width: 272, height: 232)
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

    private var stackMessages: [ChatMessage] {
        let available = group.messages.filter { availability.availableImageIDs.contains($0.id) }
        let remaining = group.messages.filter { !availability.availableImageIDs.contains($0.id) }
        return Array((available + remaining).prefix(3))
    }

    @ViewBuilder
    private func card(for message: ChatMessage) -> some View {
        if !PhotoGroupAvailability.isUnavailable(deliveryState: message.deliveryState, imageLoadFailed: failedImageIDs.contains(message.id)), let image = images[message.id] {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 244, height: 202)
                .clipped()
                .background(GiftWrapAppearance.incoming(colorScheme == .dark))
                .clipShape(.rect(cornerRadius: 18))
                .shadow(
                    color: .black.opacity(reduceMotion ? 0.10 : 0.18),
                    radius: 5,
                    y: 3
                )
        } else {
            RoundedRectangle(cornerRadius: 18)
                .fill(GiftWrapAppearance.incoming(colorScheme == .dark))
                .frame(width: 244, height: 202)
                .overlay {
                    if
                        message.deliveryState == .failed
                            || failedImageIDs.contains(message.id)
                    {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.title2)
                            .foregroundStyle(.red)
                    } else {
                        ActivitySpinner()
                    }
                }
        }
    }

    private func stackPerimeter(in bounds: CGRect) -> CGPath {
        let card = Path(roundedRect: CGRect(x: -122, y: -101, width: 244, height: 202), cornerRadius: 18)
        return stackMessages.indices.reduce(CGMutablePath() as CGPath) { outline, index in
            let transform = CGAffineTransform(translationX: bounds.midX + CGFloat(index) * 5, y: bounds.midY - CGFloat(index) * 5)
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

    private var previewItems: [MacPhotoPreviewItem] {
        group.messages.compactMap { message in
            guard availability.availableImageIDs.contains(message.id), let image = images[message.id] else { return nil }
            let fileName =
                message.attachment?.fileName
                ?? (
                    message.body.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
                        ? "Photo.png"
                        : message.body
                )
            return MacPhotoPreviewItem(
                id: message.id,
                image: image,
                attachment: message.attachment,
                fileName: fileName
            )
        }
    }

    private var accessibilityLabel: String {
        var components = [
            "\(group.expectedCount)-photo group",
            "\(availability.availableCount) available",
            "\(availability.loadingCount) loading",
        ]
        if availability.failedCount > 0 {
            components.append("\(availability.failedCount) failed")
        }
        return components.joined(separator: ", ")
    }

    private var availability: PhotoGroupAvailability.Summary {
        PhotoGroupAvailability.summary(group: group, loadedImageIDs: Set(images.keys), failedImageIDs: failedImageIDs)
    }

    private func loadImages() async {
        await PhotoGroupImageLoading.load(group.messages) { message in
            await loadImage(message)
        }
    }

    private func loadImage(_ message: ChatMessage) async {
        guard !Task.isCancelled, loadedImages[message.id] == nil,
              EncryptedPhotoPreviewPolicy.isReady(message.attachment, deliveryState: message.deliveryState) else {
            return
        }
        guard
            let attachment = message.attachment,
            let storagePath = attachment.storagePath
        else {
            return
        }

        if !EncryptedMediaLoading.isEncrypted(attachment),
           let cached = await MacAttachmentImageCache.shared.loadImage(forKey: message.id.uuidString) {
            guard !Task.isCancelled else { return }
            loadedImages[message.id] = cached
            failedImageIDs.remove(message.id)
            return
        }
        if EncryptedMediaLoading.isEncrypted(attachment) {
            do {
                guard let encryptedResolver else { throw EncryptedMediaError.unavailable }
                let decoded = try await encryptedResolver.chatPhoto(attachment)
                try EncryptedMediaLoading.validate(attachment, resolver: encryptedResolver)
                loadedImages[message.id] = decoded
                failedImageIDs.remove(message.id)
            } catch {
                guard EncryptedMediaLoading.shouldPublishFailure(error) else { return }
                failedImageIDs.insert(message.id)
            }
            return
        }
        do {
            let maximumPreviewByteSize = PendingShareAttachmentPolicy.maximumSendingPhotoBytes
            let limit =
                attachment.byteSize > 0
                ? min(attachment.byteSize, maximumPreviewByteSize)
                : maximumPreviewByteSize
            let data = try await EncryptedMediaLoading.photoPreviewData(attachment, resolver: encryptedResolver) {
                try await Storage.storage().reference(withPath: storagePath).data(maxSize: limit)
            }
            guard
                let loadedImage =
                    await MacAttachmentImageCache.decodeImage(from: data)
            else {
                throw URLError(.cannotDecodeContentData)
            }
            try EncryptedMediaLoading.validate(attachment, resolver: encryptedResolver)
            if !EncryptedMediaLoading.isEncrypted(attachment) {
                MacAttachmentImageCache.shared.insert(loadedImage, forKey: message.id.uuidString)
            }
            loadedImages[message.id] = loadedImage
            failedImageIDs.remove(message.id)
        } catch {
            guard EncryptedMediaLoading.shouldPublishFailure(error) else { return }
            failedImageIDs.insert(message.id)
        }
    }
}

private struct MacPhotoPreviewItem: Identifiable {
    let id: UUID
    let image: NSImage
    let attachment: AttachmentContent?
    let fileName: String
}

private struct MacPhotoGroupPreview: View {
    @Environment(\.encryptedAttachmentResolver) private var encryptedResolver
    @Environment(\.dismiss) private var dismiss

    let items: [MacPhotoPreviewItem]
    let expectedCount: Int

    @State private var selectedPhotoID: UUID
    @State private var isSaving = false
    @State private var batchResult = PhotoOriginalBatchResult()
    @State private var batchDestination: URL?
    @State private var batchProgress = 0
    @State private var batchSaveTask: Task<Void, Never>?
    @State private var errorMessage: String?

    init(
        items: [MacPhotoPreviewItem],
        initialPhotoID: UUID?,
        expectedCount: Int
    ) {
        self.items = items
        self.expectedCount = expectedCount
        _selectedPhotoID = State(
            initialValue: initialPhotoID
                ?? items.first?.id
                ?? UUID()
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if let selectedItem {
                MacPhotoViewer(image: selectedItem.image, attachment: selectedItem.attachment)
                    .id(EncryptedMediaTaskIdentity(resource: PhotoOriginalLoadKey(photoID: selectedItem.id, attachment: selectedItem.attachment), resolver: encryptedResolver.map(ObjectIdentifier.init)))
                    .accessibilityLabel(selectedItem.fileName)
            } else {
                ContentUnavailableView(
                    "Photo unavailable",
                    systemImage: "photo.badge.exclamationmark"
                )
            }

            Divider()

            HStack(spacing: 12) {
                Button {
                    select(offset: -1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(selectedIndex == 0)
                .accessibilityLabel("Previous photo")

                Text(positionLabel)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 48)

                Button {
                    select(offset: 1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(selectedIndex >= items.count - 1)
                .accessibilityLabel("Next photo")

                Text("\(items.count) of \(expectedCount) available")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }

                if batchResult.totalCount > 0 {
                    Text("\(batchResult.savedIDs.count) saved, \(batchResult.failedIDs.count) failed")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if isSaving { Text("Saving \(batchProgress)…").font(.caption) }
                Button("Save All…") {
                    batchSaveTask = Task { await saveAllPhotos(retryFailures: false) }
                }.disabled(isSaving || items.isEmpty)
                if !batchResult.failedIDs.isEmpty {
                    Button("Retry Failed") {
                        batchSaveTask = Task { await saveAllPhotos(retryFailures: true) }
                    }.disabled(isSaving)
                }

                Button {
                    Task {
                        await saveSelectedPhoto()
                    }
                } label: {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Save…")
                    }
                }
                .disabled(isSaving || selectedItem == nil)

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(minWidth: 720, minHeight: 560)
        .onDisappear { batchSaveTask?.cancel(); batchSaveTask = nil }
        .encryptedMediaLifetime(encryptedResolver) {
            batchSaveTask?.cancel(); batchSaveTask = nil
            if items.contains(where: { EncryptedMediaLoading.isEncrypted($0.attachment) }) { dismiss() }
        }
        .accessibilityIdentifier("photo-group-gallery")
    }

    private var selectedIndex: Int {
        items.firstIndex(where: { $0.id == selectedPhotoID }) ?? 0
    }

    private var selectedItem: MacPhotoPreviewItem? {
        guard items.indices.contains(selectedIndex) else { return nil }
        return items[selectedIndex]
    }

    private var positionLabel: String {
        guard !items.isEmpty else { return "0 of 0" }
        return "\(selectedIndex + 1) of \(items.count)"
    }

    private func select(offset: Int) {
        let index = min(
            max(selectedIndex + offset, 0),
            max(items.count - 1, 0)
        )
        guard items.indices.contains(index) else { return }
        selectedPhotoID = items[index].id
        errorMessage = nil
    }

    @MainActor
    private func saveAllPhotos(retryFailures: Bool) async {
        let destination: URL
        if retryFailures, let existing = batchDestination { destination = existing }
        else {
            guard let folder = MacPhotoOriginalSaver.chooseDirectory() else { return }
            destination = folder
            batchDestination = folder
            batchResult = PhotoOriginalBatchResult()
        }
        let targets = retryFailures ? items.filter { batchResult.failedIDs.contains($0.id) } : items
        isSaving = true
        batchProgress = 0
        defer { isSaving = false }
        for item in targets {
            guard !Task.isCancelled else { return }
            do {
                guard let attachment = item.attachment else { throw EncryptedMediaError.unavailable }
                let name = MacPhotoOriginalSaver.fileName(item.fileName, id: item.id)
                try await MacPhotoOriginalSaver.saveOriginal(attachment, resolver: encryptedResolver,
                                                            to: destination.appendingPathComponent(name))
                batchResult.record(item.id, succeeded: true)
            } catch {
                guard !Task.isCancelled else { return }
                batchResult.record(item.id, succeeded: false)
            }
            batchProgress += 1
        }
    }

    @MainActor
    private func saveSelectedPhoto() async {
        guard let selectedItem else { return }
        isSaving = true
        defer { isSaving = false }

        do {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = selectedItem.fileName
            guard panel.runModal() == .OK, let url = panel.url else { return }
            if let attachment = selectedItem.attachment {
                try await MacPhotoOriginalSaver.saveOriginal(attachment, resolver: encryptedResolver, to: url)
            } else {
                guard let data = await MacAttachmentImageCache.pngData(from: selectedItem.image) else {
                    throw URLError(.cannotDecodeContentData)
                }
                try await MacPhotoOriginalSaver.write(data, to: url)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct MacAttachmentView: View {
    @Environment(\.encryptedAttachmentResolver) private var encryptedResolver
    @State private var metadataLease = EncryptedMediaPresentationLease()
    @Environment(\.colorScheme) private var colorScheme

    let attachment: AttachmentContent
    let deliveryState: DeliveryState

    @State private var image: NSImage?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var isPresentingImage = false
    @State private var imageAttempt = 0
    @State private var videoPreview = MacVideoPreviewModel()

    init(attachment: AttachmentContent, deliveryState: DeliveryState = .sent) {
        self.attachment = attachment
        self.deliveryState = deliveryState
        _image = State(
            initialValue: (EncryptedMediaLoading.isEncrypted(attachment)) ? nil : MacAttachmentImageCache.shared.image(
                forKey: attachment.id
            )
        )
    }

    private var displayedImage: NSImage? {
        image ?? encryptedResolver?.cachedChatPhoto(attachment)
    }

    var body: some View {
        Group {
            if attachment.type == .image {
                imagePreview
            } else {
                filePreview
            }
        }
        .task(id: loadTaskID) {
            await loadImageIfNeeded()
        }
        .encryptedMediaLifetime(encryptedResolver) {
            metadataLease.release()
            videoPreview.close()
            if EncryptedMediaLoading.isEncrypted(attachment) { image = nil; isPresentingImage = false }
        }
        .sheet(isPresented: $isPresentingImage, onDismiss: { metadataLease.release() }) {
            if let image = displayedImage {
                MacPhotoPreview(
                    image: image,
                    fileName: attachment.fileName,
                    save: {
                        Task {
                            await saveAttachment()
                        }
                    },
                    encrypted: EncryptedMediaLoading.isEncrypted(attachment),
                    attachment: attachment
                )
                .modifier(MacConversationPreviewReadObscuration())
            }
        }
        .sheet(isPresented: Binding(get: { videoPreview.isPresented }, set: { if !$0 { videoPreview.close() } }),
               onDismiss: { videoPreview.close() }) {
            MacVideoPreview(model: videoPreview, fileName: attachment.fileName,
                save: { Task { await saveAttachment() } })
                .modifier(MacConversationPreviewReadObscuration())
        }
        .onDisappear {
            videoPreview.close()
            if !isPresentingImage { metadataLease.release() }
        }
        .accessibilityIdentifier("message-attachment")
    }

    @ViewBuilder
    private var imagePreview: some View {
        Group {
            if let image = displayedImage {
                Button {
                    do { try metadataLease.acquire([attachment], resolver: encryptedResolver) }
                    catch { errorMessage = "Encrypted attachment unavailable"; return }
                    isPresentingImage = true
                } label: {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: photoSize.width, height: photoSize.height)
                        .clipped()
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Open \(attachment.fileName)")
            } else if errorMessage != nil {
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.title2)
                        .foregroundStyle(.red)
                    Text("Photo unavailable")
                        .font(.callout.weight(.semibold))
                    Button("Try Again") {
                        errorMessage = nil
                        imageAttempt += 1
                    }
                    .font(.caption.weight(.semibold))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ActivitySpinner()
            }
        }
        .frame(width: photoSize.width, height: photoSize.height)
        .background(GiftWrapAppearance.incoming(colorScheme == .dark))
        .clipShape(.rect(cornerRadius: 18))
    }

    private var photoSize: CGSize {
        macSinglePhotoSize(displayedImage?.size)
    }

    private var filePreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.fileName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                    if attachment.byteSize > 0 {
                        Text(
                            ByteCountFormatter.string(
                                fromByteCount: attachment.byteSize,
                                countStyle: .file
                            )
                        )
                        .font(.caption2)
                        .opacity(0.75)
                    }
                }
                Spacer(minLength: 10)
                Button {
                    Task {
                        await saveAttachment()
                    }
                } label: {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.down.circle")
                    }
                }
                .buttonStyle(.plain)
                .disabled(isSaving || attachment.storagePath == nil)
                .help("Save attachment")
            }

            if attachment.type == .video {
                Button {
                    videoPreview.present(attachment: attachment, resolver: encryptedResolver)
                } label: {
                    Label("Play video", systemImage: "play.circle")
                }
                .disabled(attachment.storagePath == nil || !EncryptedPhotoPreviewPolicy.isReady(attachment, deliveryState: deliveryState))
                .accessibilityIdentifier("play-video")
                if let videoError = videoPreview.errorMessage, !videoPreview.isPresented {
                    Text(videoError).font(.caption2).foregroundStyle(.red)
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
        .frame(minWidth: 190, maxWidth: 330, alignment: .leading)
        .background(
            GiftWrapAppearance.incoming(colorScheme == .dark)
        )
    }

    private var loadTaskID: EncryptedMediaTaskIdentity<EncryptedPhotoPreviewPolicy.LoadKey> {
        .init(resource: .init(attachment: attachment, fallbackID: attachment.id, deliveryState: deliveryState, manualAttempt: imageAttempt),
              resolver: encryptedResolver.map(ObjectIdentifier.init))
    }

    private var iconName: String {
        switch attachment.type {
        case .image:
            "photo"
        case .video:
            "film"
        case .audio:
            "waveform"
        case .file:
            "doc"
        }
    }

    private func loadImageIfNeeded() async {
        guard EncryptedPhotoPreviewPolicy.isReady(attachment, deliveryState: deliveryState) else { return }
        guard
            attachment.type == .image,
            image == nil,
            let storagePath = attachment.storagePath
        else {
            return
        }

        if !EncryptedMediaLoading.isEncrypted(attachment),
           let cached = await MacAttachmentImageCache.shared.loadImage(forKey: attachment.id) {
            guard !Task.isCancelled else { return }
            image = cached
            return
        }
        if EncryptedMediaLoading.isEncrypted(attachment) {
            do {
                guard let encryptedResolver else { throw EncryptedMediaError.unavailable }
                let decoded = try await encryptedResolver.chatPhoto(attachment)
                try EncryptedMediaLoading.validate(attachment, resolver: encryptedResolver)
                image = decoded
                errorMessage = nil
            } catch {
                guard EncryptedMediaLoading.shouldPublishFailure(error) else { return }
                errorMessage = "Preview unavailable"
            }
            return
        }
        do {
            errorMessage = nil
            let maximumPreviewByteSize = PendingShareAttachmentPolicy.maximumSendingPhotoBytes
            let limit =
                attachment.byteSize > 0
                ? min(attachment.byteSize, maximumPreviewByteSize)
                : maximumPreviewByteSize
            let data = try await EncryptedMediaLoading.photoPreviewData(attachment, resolver: encryptedResolver) {
                try await Storage.storage().reference(withPath: storagePath).data(maxSize: limit)
            }
            guard
                let loadedImage = await MacAttachmentImageCache.decodeImage(
                    from: data
                )
            else {
                throw URLError(.cannotDecodeContentData)
            }
            try Task.checkCancellation()
            try EncryptedMediaLoading.validate(attachment, resolver: encryptedResolver)
            if !EncryptedMediaLoading.isEncrypted(attachment) {
                MacAttachmentImageCache.shared.insert(loadedImage, forKey: attachment.id)
            }
            image = loadedImage
        } catch {
            guard EncryptedMediaLoading.shouldPublishFailure(error) else { return }
            errorMessage = "Preview unavailable"
        }
    }

    private func saveAttachment() async {
        guard let storagePath = attachment.storagePath else { return }
        isSaving = true
        defer { isSaving = false }

        do {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = attachment.fileName
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try await MacPhotoOriginalSaver.saveOriginal(attachment, resolver: encryptedResolver, to: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct MacPhotoPreview: View {
    @Environment(\.encryptedAttachmentResolver) private var encryptedResolver
    @Environment(\.dismiss) private var dismiss

    let image: NSImage
    let fileName: String
    let save: () -> Void
    var encrypted = false
    var attachment: AttachmentContent?

    var body: some View {
        VStack(spacing: 0) {
            MacPhotoViewer(image: image, attachment: attachment)
                .id(EncryptedMediaTaskIdentity(resource: attachment, resolver: encryptedResolver.map(ObjectIdentifier.init)))

            Divider()

            HStack {
                Text(fileName)
                    .font(.callout)
                    .lineLimit(1)
                Spacer()
                Button("Save…", action: save)
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(minWidth: 640, minHeight: 520)
        .encryptedMediaLifetime(encryptedResolver) { if encrypted { dismiss() } }
    }
}

/// Ordinary viewing retains the available preview while a sharp display copy loads. Pinch zoom requests original detail;
/// saving stays on the untouched original path owned by the caller.
private struct MacPhotoViewer: View {
    @Environment(\.encryptedAttachmentResolver) private var resolver
    let image: NSImage
    let attachment: AttachmentContent?
    @State private var viewingImage: NSImage?
    @State private var detailImage: NSImage?
    @State private var finishedLoading = false
    @State private var isZoomed = false
    @State private var loadGeneration = UUID()

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            MacPhotoCanvas(image: detailImage ?? viewingImage ?? image) { isZoomed = true }
            if attachment != nil && !finishedLoading && viewingImage == nil {
                ProgressView()
                    .controlSize(.small)
                    .padding(10)
                    .background(.regularMaterial, in: .circle)
                    .padding(16)
                    .allowsHitTesting(false)
                    .accessibilityLabel("Loading higher resolution photo")
            }
        }
        .task(id: EncryptedMediaTaskIdentity(resource: attachment, resolver: resolver.map(ObjectIdentifier.init))) {
            let generation = UUID()
            loadGeneration = generation
            viewingImage = nil; detailImage = nil; finishedLoading = false; isZoomed = false
            defer { if !Task.isCancelled, generation == loadGeneration { finishedLoading = true } }
            guard let attachment else { return }
            let loaded = await MacPhotoDisplayLoading.image(attachment, resolver: resolver)
            guard !Task.isCancelled, generation == loadGeneration else { return }
            viewingImage = loaded
        }
        .task(id: isZoomed) {
            let generation = loadGeneration
            guard isZoomed, detailImage == nil, let attachment else { return }
            let loaded = await MacPhotoDisplayLoading.image(attachment, resolver: resolver, originalDetail: true)
            guard !Task.isCancelled, generation == loadGeneration else { return }
            detailImage = loaded
        }
        .encryptedMediaLifetime(resolver) { loadGeneration = UUID(); viewingImage = nil; detailImage = nil }
    }
}

@MainActor
private enum MacPhotoDisplayLoading {
    static func image(_ attachment: AttachmentContent, resolver: EncryptedAttachmentResolver?, originalDetail: Bool = false) async -> NSImage? {
        guard attachment.storagePath != nil else { return nil }
        do {
            try EncryptedMediaLoading.validate(attachment, resolver: resolver)
            do {
                if !originalDetail, EncryptedMediaLoading.isEncrypted(attachment), let resolver,
                   let bytes = try await resolver.photoRenditionData(attachment, rendition: .viewer),
                   EncryptedPhotoRenditionImage.isDecodable(bytes, rendition: .viewer) {
                    let image = await MacAttachmentImageCache.decodeImage(from: bytes, maximumPixelSize: 4096, prefersHDR: true)
                    try EncryptedMediaLoading.validate(attachment, resolver: resolver)
                    return image
                }
            } catch {
                // Missing/corrupt optional viewing copies retain original-file fallback.
                try EncryptedMediaLoading.validate(attachment, resolver: resolver)
            }
            let image = try await MacPhotoOriginalSaver.withOriginalURL(attachment, resolver: resolver) { url in
                await MacAttachmentImageCache.decodeFile(url, maximumPixelSize: originalDetail ? 8192 : 4096, prefersHDR: true)
            }
            try EncryptedMediaLoading.validate(attachment, resolver: resolver)
            return image
        } catch { return nil } // Keep the authenticated preview usable when the original is offline.
    }
}

private struct MacVoiceMessageView: View {
    @Environment(\.encryptedAttachmentResolver) private var encryptedResolver
    @Environment(\.colorScheme) private var colorScheme

    let attachment: AttachmentContent

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var playbackGeneration = UUID()
    @State private var itemObservation: NSKeyValueObservation?
    @State private var playerObservation: NSKeyValueObservation?

    var body: some View {
        TimelineView(.periodic(from: .now, by: isPlaying ? 0.25 : 60)) { _ in
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Button {
                        Task {
                            await togglePlayback()
                        }
                    } label: {
                        Group {
                            if isLoading {
                                ActivitySpinner()
                            } else {
                                Image(
                                    systemName:
                                        isPlaying
                                        ? "pause.fill"
                                        : "play.fill"
                                )
                            }
                        }
                        .frame(width: 38, height: 38)
                        .background(GiftWrapAppearance.accent(colorScheme == .dark).opacity(0.16), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .disabled(
                        attachment.storagePath == nil || isLoading
                    )
                    .accessibilityLabel(
                        isPlaying
                            ? "Pause voice message"
                            : "Play voice message"
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        Slider(value: progressBinding, in: 0...1)
                            .disabled(playbackDuration <= 0)
                            .tint(GiftWrapAppearance.accent(colorScheme == .dark))
                            .accessibilityLabel(
                                "Voice message position"
                            )
                            .accessibilityValue(
                                VoiceMessageDurationText.string(
                                    playbackTime
                                )
                            )

                        HStack {
                            Text(
                                VoiceMessageDurationText.string(
                                    playbackTime
                                )
                            )
                            Spacer()
                            Text(
                                VoiceMessageDurationText.string(
                                    playbackDuration
                                )
                            )
                        }
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(11)
        .frame(width: 250)
        .background(
            GiftWrapAppearance.incoming(colorScheme == .dark)
        )
        .onReceive(
            NotificationCenter.default.publisher(
                for: .AVPlayerItemDidPlayToEndTime
            )
        ) { notification in
            guard
                let item = notification.object as? AVPlayerItem,
                item === player?.currentItem
            else {
                return
            }
            isPlaying = false
            player?.seek(to: .zero)
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)) { notification in
            guard let item = notification.object as? AVPlayerItem, item === player?.currentItem else { return }
            playbackFailed()
        }
        .encryptedMediaLifetime(encryptedResolver) { clearPlayback() }
        .onDisappear { clearPlayback() }
    }

    private var playbackTime: TimeInterval {
        guard let seconds = player?.currentTime().seconds else { return 0 }
        return seconds.isFinite ? max(0, seconds) : 0
    }

    private var playbackDuration: TimeInterval {
        if
            let seconds = player?.currentItem?.duration.seconds,
            seconds.isFinite,
            seconds > 0
        {
            return seconds
        }
        return max(attachment.audioDuration ?? 0, 0)
    }

    private var progressBinding: Binding<Double> {
        Binding(
            get: {
                guard playbackDuration > 0 else { return 0 }
                return min(max(playbackTime / playbackDuration, 0), 1)
            },
            set: { progress in
                guard let player, playbackDuration > 0 else { return }
                player.seek(
                    to: CMTime(
                        seconds: playbackDuration * progress,
                        preferredTimescale: 600
                    )
                )
            }
        )
    }

    private func clearPlayback() {
        playbackGeneration = UUID()
        itemObservation?.invalidate(); itemObservation = nil
        playerObservation?.invalidate(); playerObservation = nil
        player?.pause(); player?.replaceCurrentItem(with: nil)
        player = nil; isPlaying = false; isLoading = false
    }

    private func playbackFailed() {
        clearPlayback()
        errorMessage = "Audio unavailable. Try playing again."
    }

    private func observePlayback(_ player: AVPlayer, generation: UUID) {
        itemObservation = player.currentItem?.observe(\.status, options: [.initial, .new]) { item, _ in
            let failed = item.status == .failed
            Task { @MainActor in
                guard generation == playbackGeneration, self.player === player else { return }
                if failed { playbackFailed() }
            }
        }
        playerObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { observed, _ in
            let playing = observed.timeControlStatus == .playing
            let waiting = observed.timeControlStatus == .waitingToPlayAtSpecifiedRate
            Task { @MainActor in
                guard generation == playbackGeneration, self.player === player else { return }
                isPlaying = playing
                isLoading = waiting
            }
        }
    }

    private func togglePlayback() async {
        let generation = playbackGeneration
        do { try EncryptedMediaLoading.validate(attachment, resolver: encryptedResolver) }
        catch { clearPlayback(); errorMessage = "Audio unavailable"; return }
        if isPlaying {
            player?.pause()
            isPlaying = false
            return
        }

        if let player {
            errorMessage = nil
            player.play()
            return
        }

        guard let storagePath = attachment.storagePath else { return }
        isLoading = true
        defer { if generation == playbackGeneration { isLoading = false } }
        do {
            errorMessage = nil
            let url = try await EncryptedMediaLoading.url(attachment, resolver: encryptedResolver) {
                try await Storage.storage().reference(withPath: storagePath).downloadURL()
            }
            guard generation == playbackGeneration else { return }
            try EncryptedMediaLoading.validate(attachment, resolver: encryptedResolver)
            let player = AVPlayer(url: url)
            self.player = player
            observePlayback(player, generation: generation)
            player.play()
        } catch {
            guard generation == playbackGeneration else { return }
            errorMessage = "Audio unavailable"
        }
    }
}

private struct MacLocationMessageView: View {
    @Environment(\.colorScheme) private var colorScheme

    let location: LiveLocationContent
    let isCurrentUser: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Map(
                initialPosition: .region(
                    MKCoordinateRegion(
                        center: CLLocationCoordinate2D(
                            latitude: location.latitude,
                            longitude: location.longitude
                        ),
                        span: MKCoordinateSpan(
                            latitudeDelta: 0.01,
                            longitudeDelta: 0.01
                        )
                    )
                ),
                interactionModes: []
            ) {
                Marker(
                    "Live location",
                    coordinate: CLLocationCoordinate2D(
                        latitude: location.latitude,
                        longitude: location.longitude
                    )
                )
                .tint(GiftWrapAppearance.accent(colorScheme == .dark))
            }
            .frame(width: 280, height: 104)
            .clipShape(.rect(cornerRadius: 14))

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(isCurrentUser ? "Your live location" : "Shared location")
                        .font(.callout.weight(.semibold))

                    Text("Updated \(location.updatedAt, style: .relative)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Label(
                        location.isActive(at: context.date)
                            ? "Live"
                            : "Ended",
                        systemImage:
                            location.isActive(at: context.date)
                                ? "location.fill"
                                : "location.slash"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(
                        location.isActive(at: context.date)
                            ? Color.green
                            : Color.secondary
                    )
                }
            }
        }
        .padding(10)
        .frame(maxWidth: 300)
        .background(
            GiftWrapAppearance.incoming(colorScheme == .dark)
        )
    }
}
