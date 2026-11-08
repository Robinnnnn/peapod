import SwiftUI
import UniformTypeIdentifiers

struct MessageFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [UUID: Anchor<CGRect>],
        nextValue: () -> [UUID: Anchor<CGRect>]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

enum MessageInteractionAction: String, CaseIterable, Identifiable {
    case reply
    case copy
    case copyLink
    case edit
    case retry
    case unsend
    case pin
    case unpin

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pin: "Pin"
        case .unpin: "Unpin"
        case .reply:
            "Reply"
        case .copy:
            "Copy"
        case .copyLink:
            "Copy Link"
        case .edit:
            "Edit"
        case .retry:
            "Retry"
        case .unsend:
            "Unsend"
        }
    }

    var systemImage: String {
        switch self {
        case .pin: "pin"
        case .unpin: "pin.slash"
        case .reply:
            "arrowshape.turn.up.left"
        case .copy, .copyLink:
            "doc.on.doc"
        case .edit:
            "pencil"
        case .retry:
            "arrow.clockwise"
        case .unsend:
            "trash"
        }
    }

    var isDestructive: Bool {
        self == .unsend
    }
}

extension LinkPreviewSelection {
    @MainActor
    func copyToPasteboard() {
        UIPasteboard.general.items = [[
            UTType.url.identifier: url as NSURL,
            UTType.utf8PlainText.identifier: originalURLText,
        ]]
    }
}

enum MessageInteractionPolicy {
    static let reactionChoices = MessageReactionPalette.defaults

    static func actions(
        for message: ChatMessage,
        currentUserID: String,
        isPinned: Bool = false,
        allowsPinning: Bool = true
    ) -> [MessageInteractionAction] {
        guard !message.isUnsent else { return [] }

        let isCurrentUser = message.senderID == currentUserID
        var actions: [MessageInteractionAction] = [.reply]

        if let selection = previewSelection(for: message) {
            actions.append(.copyLink)
            if !selection.isURLOnly { actions.append(.copy) }
        } else if canCopy(message) {
            actions.append(.copy)
        }
        if
            isCurrentUser,
            message.kind == .text || message.kind == .link
        {
            actions.append(.edit)
        }
        if
            isCurrentUser,
            message.deliveryState == .failed,
            message.kind != .liveLocation
        {
            actions.append(.retry)
        }
        if allowsPinning && MessagePinningPolicy.canPin(message) { actions.append(isPinned ? .unpin : .pin) }
        if isCurrentUser {
            actions.append(.unsend)
        }

        return actions
    }

    static func canPresent(
        message: ChatMessage,
        allowsInteractions: Bool
    ) -> Bool {
        allowsInteractions && !message.isUnsent
    }

    static func previewSelection(for message: ChatMessage) -> LinkPreviewSelection? {
        guard !message.isUnsent, message.kind == .link || message.kind == .text else { return nil }
        return LinkPreviewSelection.first(in: message.body)
    }

    private static func canCopy(_ message: ChatMessage) -> Bool {
        guard message.kind == .text || message.kind == .link else {
            return false
        }
        return !message.body.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty
    }
}

enum MessageInteractionOverlayPlacement: Equatable {
    case split
    case below
    case above
    case translatedSplit
    case constrainedBelow
    case constrainedAbove
}

struct MessageInteractionOverlayLayout: Equatable {
    let reactionFrame: CGRect
    let actionFrame: CGRect
    let placement: MessageInteractionOverlayPlacement
    let sourceTranslationY: CGFloat

    static let edgeMargin: CGFloat = 12
    static let sourceGap: CGFloat = 8
    static let menuGap: CGFloat = 8

    static func resolve(
        sourceFrame: CGRect,
        containerSize: CGSize,
        safeAreaInsets: EdgeInsets,
        reactionSize: CGSize,
        actionSize: CGSize,
        isCurrentUser: Bool
    ) -> MessageInteractionOverlayLayout {
        let safeFrame = CGRect(
            x: Self.edgeMargin + safeAreaInsets.leading,
            y: Self.edgeMargin + safeAreaInsets.top,
            width: max(
                0,
                containerSize.width
                    - safeAreaInsets.leading
                    - safeAreaInsets.trailing
                    - (Self.edgeMargin * 2)
            ),
            height: max(
                0,
                containerSize.height
                    - safeAreaInsets.top
                    - safeAreaInsets.bottom
                    - (Self.edgeMargin * 2)
            )
        )
        let reactionSize = constrained(reactionSize, to: safeFrame.size)
        let actionSize = constrained(actionSize, to: safeFrame.size)
        let reactionX = horizontalOrigin(
            menuWidth: reactionSize.width,
            sourceFrame: sourceFrame,
            safeFrame: safeFrame,
            isCurrentUser: isCurrentUser
        )
        let actionX = horizontalOrigin(
            menuWidth: actionSize.width,
            sourceFrame: sourceFrame,
            safeFrame: safeFrame,
            isCurrentUser: isCurrentUser
        )

        let reactionAboveY =
            sourceFrame.minY - Self.sourceGap - reactionSize.height
        let actionBelowY = sourceFrame.maxY + Self.sourceGap
        if
            reactionAboveY >= safeFrame.minY,
            actionBelowY + actionSize.height <= safeFrame.maxY
        {
            return MessageInteractionOverlayLayout(
                reactionFrame: CGRect(
                    origin: CGPoint(x: reactionX, y: reactionAboveY),
                    size: reactionSize
                ),
                actionFrame: CGRect(
                    origin: CGPoint(x: actionX, y: actionBelowY),
                    size: actionSize
                ),
                placement: .split,
                sourceTranslationY: 0
            )
        }

        let belowReactionY = sourceFrame.maxY + Self.sourceGap
        let belowActionY =
            belowReactionY + reactionSize.height + Self.menuGap
        if belowActionY + actionSize.height <= safeFrame.maxY {
            return MessageInteractionOverlayLayout(
                reactionFrame: CGRect(
                    origin: CGPoint(x: reactionX, y: belowReactionY),
                    size: reactionSize
                ),
                actionFrame: CGRect(
                    origin: CGPoint(x: actionX, y: belowActionY),
                    size: actionSize
                ),
                placement: .below,
                sourceTranslationY: 0
            )
        }

        let splitGroupHeight =
            actionBelowY + actionSize.height - reactionAboveY
        if splitGroupHeight <= safeFrame.height {
            let translationY: CGFloat
            if reactionAboveY < safeFrame.minY {
                translationY = safeFrame.minY - reactionAboveY
            } else {
                translationY =
                    safeFrame.maxY
                    - (actionBelowY + actionSize.height)
            }

            if translationY != 0 {
                return MessageInteractionOverlayLayout(
                    reactionFrame: CGRect(
                        origin: CGPoint(
                            x: reactionX,
                            y: reactionAboveY + translationY
                        ),
                        size: reactionSize
                    ),
                    actionFrame: CGRect(
                        origin: CGPoint(
                            x: actionX,
                            y: actionBelowY + translationY
                        ),
                        size: actionSize
                    ),
                    placement: .translatedSplit,
                    sourceTranslationY: translationY
                )
            }
        }

        let aboveReactionY =
            sourceFrame.minY - Self.sourceGap - reactionSize.height
        let aboveActionY =
            aboveReactionY - Self.menuGap - actionSize.height
        if aboveActionY >= safeFrame.minY {
            return MessageInteractionOverlayLayout(
                reactionFrame: CGRect(
                    origin: CGPoint(x: reactionX, y: aboveReactionY),
                    size: reactionSize
                ),
                actionFrame: CGRect(
                    origin: CGPoint(x: actionX, y: aboveActionY),
                    size: actionSize
                ),
                placement: .above,
                sourceTranslationY: 0
            )
        }

        let spaceBelow = safeFrame.maxY - sourceFrame.maxY
        let spaceAbove = sourceFrame.minY - safeFrame.minY
        if spaceBelow >= spaceAbove {
            let reactionY = min(
                max(belowReactionY, safeFrame.minY),
                safeFrame.maxY - reactionSize.height
            )
            let actionY = min(
                max(
                    reactionY + reactionSize.height + Self.menuGap,
                    safeFrame.minY
                ),
                safeFrame.maxY - actionSize.height
            )
            return MessageInteractionOverlayLayout(
                reactionFrame: CGRect(
                    origin: CGPoint(x: reactionX, y: reactionY),
                    size: reactionSize
                ),
                actionFrame: CGRect(
                    origin: CGPoint(x: actionX, y: actionY),
                    size: actionSize
                ),
                placement: .constrainedBelow,
                sourceTranslationY: 0
            )
        }

        let reactionY = min(
            max(aboveReactionY, safeFrame.minY),
            safeFrame.maxY - reactionSize.height
        )
        let actionY = min(
            max(
                reactionY - Self.menuGap - actionSize.height,
                safeFrame.minY
            ),
            safeFrame.maxY - actionSize.height
        )
        return MessageInteractionOverlayLayout(
            reactionFrame: CGRect(
                origin: CGPoint(x: reactionX, y: reactionY),
                size: reactionSize
            ),
            actionFrame: CGRect(
                origin: CGPoint(x: actionX, y: actionY),
                size: actionSize
            ),
            placement: .constrainedAbove,
            sourceTranslationY: 0
        )
    }

    private static func constrained(
        _ size: CGSize,
        to availableSize: CGSize
    ) -> CGSize {
        CGSize(
            width: min(size.width, availableSize.width),
            height: min(size.height, availableSize.height)
        )
    }

    private static func horizontalOrigin(
        menuWidth: CGFloat,
        sourceFrame: CGRect,
        safeFrame: CGRect,
        isCurrentUser: Bool
    ) -> CGFloat {
        let preferred =
            isCurrentUser
                ? sourceFrame.maxX - menuWidth
                : sourceFrame.minX
        return min(
            max(preferred, safeFrame.minX),
            safeFrame.maxX - menuWidth
        )
    }
}

struct MessageInteractionOverlay<FocusedMessage: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var reactionGlyphSize: CGFloat = 25
    @AccessibilityFocusState private var focusedReaction: String?
    @State private var measuredReactionSize = CGSize.zero
    @State private var naturalActionHeight: CGFloat = 0

    let message: ChatMessage
    let currentUserID: String
    let sourceFrame: CGRect
    let containerSize: CGSize
    let safeAreaInsets: EdgeInsets
    let focusedMessage: FocusedMessage
    let onReact: (String) -> Void
    let onAction: (MessageInteractionAction) -> Void
    let onPresentationUpdate: (CGRect, CGFloat) -> Void
    let onDismiss: () -> Void

    var isPinned = false
    var allowsPinning = true
    var pinIsPending = false

    private var isCurrentUser: Bool {
        message.senderID == currentUserID
    }

    private var actions: [MessageInteractionAction] {
        MessageInteractionPolicy.actions(
            for: message,
            currentUserID: currentUserID,
            isPinned: isPinned,
            allowsPinning: allowsPinning
        )
    }

    private var reactionWidth: CGFloat {
        min(276, max(0, containerSize.width - 24))
    }

    private var actionWidth: CGFloat {
        min(232, max(0, containerSize.width - 24))
    }

    private var maximumActionHeight: CGFloat {
        max(132, containerSize.height * 0.55)
    }

    private var actionHeight: CGFloat {
        let estimatedHeight = CGFloat(actions.count) * 49
        let naturalHeight =
            naturalActionHeight > 0
                ? naturalActionHeight
                : estimatedHeight
        return min(naturalHeight, maximumActionHeight)
    }

    private var layout: MessageInteractionOverlayLayout {
        MessageInteractionOverlayLayout.resolve(
            sourceFrame: sourceFrame,
            containerSize: containerSize,
            safeAreaInsets: safeAreaInsets,
            reactionSize:
                measuredReactionSize == .zero
                    ? CGSize(width: reactionWidth, height: 56)
                    : measuredReactionSize,
            actionSize: CGSize(
                width: actionWidth,
                height: actionHeight
            ),
            isCurrentUser: isCurrentUser
        )
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            MessageInteractionBackdrop()
                .contentShape(.rect)
                .onTapGesture(perform: onDismiss)
                .accessibilityHidden(true)

            focusedMessage
                .frame(
                    width: sourceFrame.width,
                    height: sourceFrame.height
                )
                .position(
                    x: sourceFrame.midX,
                    y: sourceFrame.midY + layout.sourceTranslationY
                )
                .accessibilityElement(children: .contain)

            reactionStrip
                .frame(
                    width: layout.reactionFrame.width,
                    height: layout.reactionFrame.height
                )
                .position(
                    x: layout.reactionFrame.midX,
                    y: layout.reactionFrame.midY
                )

            actionList
                .frame(
                    width: layout.actionFrame.width,
                    height: layout.actionFrame.height
                )
                .position(
                    x: layout.actionFrame.midX,
                    y: layout.actionFrame.midY
                )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("message-interaction-overlay")
        .accessibilityAction(.escape, onDismiss)
        .transition(
            reduceMotion
                ? .opacity
                : .scale(scale: 0.96, anchor: .center)
                    .combined(with: .opacity)
        )
        .onAppear {
            focusedReaction = MessageInteractionPolicy.reactionChoices.first
            onPresentationUpdate(
                sourceFrame,
                layout.sourceTranslationY
            )
        }
        .onChange(of: layout) {
            onPresentationUpdate(
                sourceFrame,
                layout.sourceTranslationY
            )
        }
    }

    private var reactionStrip: some View {
        HStack(spacing: 0) {
            ForEach(
                MessageInteractionPolicy.reactionChoices,
                id: \.self
            ) { emoji in
                let isSelected =
                    message.reactions[currentUserID] == emoji
                Button {
                    onReact(emoji)
                } label: {
                    ZStack {
                        if isSelected {
                            Circle()
                                .fill(Color.accentColor.opacity(0.18))
                                .frame(
                                    width: 38,
                                    height: 38
                                )
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }

                        Text(emoji)
                            .font(
                                .system(
                                    size: min(reactionGlyphSize, 31)
                                )
                            )
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel(
                    "React with \(MessageReactionAccessibility.name(for: emoji))"
                )
                .accessibilityHint(
                    isSelected
                        ? "Removes your current reaction"
                        : message.reactions[currentUserID] == nil
                            ? "Adds this reaction"
                            : "Replaces your current reaction"
                )
                .accessibilityAddTraits(
                    isSelected
                        ? .isSelected
                        : []
                )
                .accessibilityIdentifier(
                    "message-reaction-option-\(emojiIdentifier(emoji))"
                )
                .accessibilityFocused($focusedReaction, equals: emoji)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .frame(width: reactionWidth)
        .background(
            Color(.secondarySystemBackground),
            in: .rect(cornerRadius: 18)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reactions")
        .accessibilityIdentifier("message-reaction-picker")
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            measuredReactionSize = size
        }
    }

    private var actionList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(actions.enumerated()), id: \.element.id) {
                    index,
                    action in
                    Button {
                        onAction(action)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: action.systemImage)
                                .font(.body.weight(.medium))
                                .frame(width: 24)
                                .accessibilityHidden(true)

                            Text(action.title)
                                .font(.body)
                                .multilineTextAlignment(.leading)
                                .fixedSize(
                                    horizontal: false,
                                    vertical: true
                                )

                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(
                            action.isDestructive
                                ? AnyShapeStyle(Color.red)
                                : AnyShapeStyle(Color.primary)
                        )
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .frame(minHeight: 48)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(pinIsPending && (action == .pin || action == .unpin))
                    .accessibilityIdentifier(
                        "message-action-\(action.rawValue)"
                    )

                    if index < actions.count - 1 {
                        Divider()
                            .padding(.leading, 50)
                            .accessibilityHidden(true)
                    }
                }
            }
            .frame(width: actionWidth)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                naturalActionHeight = height
            }
        }
        .scrollIndicators(.hidden)
        .scrollDisabled(naturalActionHeight <= maximumActionHeight)
        .frame(width: actionWidth, height: actionHeight)
        .background(
            Color(.secondarySystemBackground),
            in: .rect(cornerRadius: 16)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .clipShape(.rect(cornerRadius: 16))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Message actions")
        .accessibilityIdentifier("message-action-list")
    }

    private func emojiIdentifier(_ emoji: String) -> String {
        switch emoji {
        case "❤️":
            "heart"
        case "👍":
            "thumbs-up"
        case "👎":
            "thumbs-down"
        case "😂":
            "laughing"
        case "😢":
            "sad-face"
        case "‼️":
            "double-exclamation"
        case "❓":
            "question-mark"
        default:
            "reaction"
        }
    }
}

private struct MessageInteractionBackdrop: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)

            Rectangle()
                .fill(Color.black.opacity(0.24))
        }
        .ignoresSafeArea()
    }
}

/// Albums pin their stable first-message identity, never whichever member happened to load first.
enum MessagePinningInteractionPolicy {
    static func target(message: ChatMessage, photoGroup: PhotoMessageGroup?) -> ChatMessage? {
        guard let photoGroup else { return MessagePinningPolicy.canPin(message) ? message : nil }
        guard let anchor = photoGroup.messages.first(where: { $0.id == photoGroup.id }),
              MessagePinningPolicy.canPin(anchor) else { return nil }
        return anchor
    }
}
