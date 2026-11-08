import ChatLayout
import SwiftUI
import UIKit

/// Insets preserve the readable viewport while optional drawing underlap lets
/// messages soften behind the native header and composer bars.
struct ConversationTimelineView: UIViewRepresentable {
    let viewport: ConversationViewport
    let rowIDs: [ConversationViewportRowID]
    let revision: AnyHashable
    let memberTargets: [UUID: UUID]
    let isReady: Bool
    let isRecent: Bool
    let searchQuery: String?
    let command: ConversationViewportCommand?
    let content: (ConversationViewportRowID) -> AnyView
    let onLatestVisibilityChange: (Bool) -> Void
    let onUserReachedWindowEnd: () -> Void
    var didCompleteViewportLayout: ((ConversationTimelineCollection) -> Void)? = nil
    var isInteractionPresented = false
    var edgeInsets = EdgeInsets()
    var onVisibleRowsChange: (([ConversationViewportRowID]) -> Void)? = nil

    func makeUIView(context: Context) -> ConversationTimelineCollection {
        ConversationTimelineCollection()
    }

    func updateUIView(_ collection: ConversationTimelineCollection, context: Context) {
        collection.configureEdgeInsets(edgeInsets)
        collection.display(self)
    }
}

/// The row may include a day header. Mark the bubble itself so that inserting or
/// removing that header does not move the actual text somebody is reading.
struct ConversationViewportBubbleMarker: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let marker = BubbleLandmarkView()
        marker.isUserInteractionEnabled = false
        marker.isAccessibilityElement = false
        return marker
    }

    func updateUIView(_ marker: UIView, context: Context) {}
}

private final class BubbleLandmarkView: UIView {
    override func didMoveToWindow() {
        super.didMoveToWindow()
        var parent = superview
        while let view = parent {
            if let cell = view as? TimelineCell {
                cell.bubbleMarker = self
                break
            }
            parent = view.superview
        }
    }
}

private final class TimelineCell: UICollectionViewCell {
    private let host = UIHostingController(rootView: AnyView(EmptyView()))
    let edgeBlur = ConversationEdgeBlurState()
    weak var bubbleMarker: UIView?
    var rowID: ConversationViewportRowID?
    var revision: AnyHashable?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Only the *timeline* has a safe area. A cell crossing the status bar
        // must not acquire a second top inset when its SwiftUI root is measured.
        host.safeAreaRegions = []
        host.sizingOptions = [.intrinsicContentSize]
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: contentView.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
        backgroundColor = .clear
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { nil }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        updateHostingParent()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateHostingParent()
    }

    private func updateHostingParent() {
        // A full-screen SwiftUI media viewer can remove the presenting tree
        // from the window temporarily. Containment follows the actual responder
        // hierarchy, so its presenting controller remains alive during dismissal.
        var ancestor = next
        var owner: UIViewController?
        while let responder = ancestor {
            if let controller = responder as? UIViewController {
                owner = controller
                break
            }
            ancestor = responder.next
        }
        guard host.parent !== owner else { return }
        if host.parent != nil {
            host.willMove(toParent: nil)
            host.removeFromParent()
        }
        if let owner {
            owner.addChild(host)
            host.didMove(toParent: owner)
        }
    }

    @discardableResult
    func configure(id: ConversationViewportRowID, with timeline: ConversationTimelineView) -> Bool {
        guard rowID != id || revision != timeline.revision else { return false }
        rowID = id
        revision = timeline.revision
        let version = timeline.revision
        host.rootView = AnyView(timeline.content(id).id(id)
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
            .coordinateSpace(name: ConversationEdgeBlurParameters.cellCoordinateSpace)
            .environment(\.conversationEdgeBlur, edgeBlur)
            .transaction(value: version) {
                $0.animation = nil
                $0.disablesAnimations = true
            })
        return true
    }

    func setAccessibilityObscured(_ obscured: Bool) {
        // UIKit exposes the cell and the hosted SwiftUI accessibility container
        // separately when VoiceOver explores a collection.
        accessibilityElementsHidden = obscured
        host.view.accessibilityElementsHidden = obscured
    }

    override func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        let attributes = layoutAttributes.copy() as! UICollectionViewLayoutAttributes
        let width = attributes.size.width
        guard width > 0 else { return attributes }
        let size = host.sizeThatFits(in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        let scale = max(traitCollection.displayScale, 1)
        attributes.size.height = max(1, ceil(size.height * scale)) / scale
        return attributes
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        rowID = nil
        revision = nil
        bubbleMarker = nil
        edgeBlur.parameters = .inactive
    }

    var bubbleOffset: CGFloat? {
        guard let bubbleMarker, bubbleMarker.isDescendant(of: self) else { return nil }
        return bubbleMarker.convert(bubbleMarker.bounds, to: self).minY
    }
}

@MainActor
final class ConversationTimelineCollection: UICollectionView, UICollectionViewDataSource, UICollectionViewDelegate {
    private typealias RowID = ConversationViewportRowID
    private let chatLayout: CollectionViewChatLayout
    private var input: ConversationTimelineView?
    private var deferredInput: ConversationTimelineView?
    private var rowIndexes: [RowID: Int] = [:]
    private var isApplyingBatch = false
    private var committingInput = false
    private var layingOutViewport = false
    private var measuredWidth: CGFloat = 0
    private var userIsScrolling = false
    private var gestureStartY: CGFloat = 0
    private var gestureMoved = false
    private var visibilityReportQueued = false
    private var photoHorizonReportQueued = false
    private var lastReportedVisibility: Bool?
    private var hidesRowAccessibility = false
    private(set) var presentedRows = [ConversationViewportRowID]()
    private(set) var isContentPresented = false
    var presentedRevision: AnyHashable? { input?.revision }

    init() {
        let layout = CollectionViewChatLayout()
        layout.keepContentAtBottomOfVisibleArea = true
        layout.supportSelfSizingInvalidation = true
        chatLayout = layout
        super.init(frame: .zero, collectionViewLayout: layout)
        register(TimelineCell.self, forCellWithReuseIdentifier: "message-row")
        dataSource = self
        delegate = self
        backgroundColor = .clear
        if #available(iOS 26.0, *) {
            topEdgeEffect.isHidden = true
            bottomEdgeEffect.isHidden = true
        }
        keyboardDismissMode = .interactive
        // Owned guide: while the keyboard is offscreen it follows this full-screen
        // view's physical bottom instead of the home-indicator safe-area boundary.
        keyboardLayoutGuide.usesBottomSafeArea = false
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardFrameDidChange(_:)),
            name: UIResponder.keyboardDidChangeFrameNotification, object: nil
        )
        contentInsetAdjustmentBehavior = .never
        automaticallyAdjustsScrollIndicatorInsets = false
        alwaysBounceVertical = true
        isPrefetchingEnabled = false
        selfSizingInvalidation = .enabledIncludingConstraints
        accessibilityIdentifier = "conversation-message-list"
        alpha = 0
    }

    required init?(coder: NSCoder) { nil }

    func configureEdgeInsets(_ insets: EdgeInsets) {
        // SwiftUI already lays out the horizontal safe area; extend only vertically.
        let insets = UIEdgeInsets(top: insets.top, left: 0, bottom: insets.bottom, right: 0)
        guard contentInset != insets else { return }
        contentInset = insets
        verticalScrollIndicatorInsets = insets
        updateEdgeBlurs()
    }

    @objc private func keyboardFrameDidChange(_ notification: Notification) {
        // Re-evaluate the visible bottom once the guide has settled.
        setNeedsLayout()
    }

    /// Top of a docked keyboard in viewport coordinates, or nil when it is offscreen,
    /// undocked or not yet measured. The guide's frame is in this scroll view's bounds space.
    private var dockedKeyboardTop: CGFloat? {
        let frame = keyboardLayoutGuide.layoutFrame
        guard let window, frame.width > 0, frame.height > 0,
              frame.minY.isFinite, frame.height.isFinite else { return nil }
        // An offscreen guide can still report overlap when this view extends past
        // its window, as in hosted layout fixtures. A docked keyboard rises above it.
        let topInWindow = convert(CGPoint(x: frame.midX, y: frame.minY), to: window).y
        guard topInWindow < window.bounds.maxY - 1 else { return nil }
        return frame.minY - bounds.minY
    }

    private func updateEdgeBlurs() {
        let viewportHeight = bounds.height
        let topInset = adjustedContentInset.top
        let bottomInset = adjustedContentInset.bottom
        let visibleBottom = ConversationEdgeBlurParameters.visibleBottom(
            keyboardTop: dockedKeyboardTop, viewportHeight: viewportHeight, bottomInset: bottomInset
        )
        for case let cell as TimelineCell in visibleCells {
            var parameters = ConversationEdgeBlurParameters(
                originY: cell.frame.minY - bounds.minY, viewportHeight: viewportHeight,
                topInset: topInset, bottomInset: bottomInset, visibleBottom: visibleBottom
            )
            parameters.isEnabled = parameters.intersectsBlur(rowHeight: cell.bounds.height)
            // Rows in the readable center need neither GPU filtering nor scroll
            // updates. Only an edge crossing changes their rendering state.
            if !parameters.isEnabled { parameters = .inactive }
            if cell.edgeBlur.parameters != parameters { cell.edgeBlur.parameters = parameters }
        }
    }


    func display(_ newInput: ConversationTimelineView) {
        // The overlay owns accessibility while it presents a copy of a bubble.
        // Its hosted UIKit siblings must leave the accessibility tree immediately,
        // even if a gesture or a batch update is holding the next row snapshot.
        accessibilityElementsHidden = newInput.isInteractionPresented
        if hidesRowAccessibility != newInput.isInteractionPresented {
            hidesRowAccessibility = newInput.isInteractionPresented
            for case let cell as TimelineCell in visibleCells {
                cell.setAccessibilityObscured(hidesRowAccessibility)
            }
        }
        if userIsScrolling || isApplyingBatch {
            deferredInput = newInput
            if !newInput.isReady { presentContent(false) }
            return
        }

        committingInput = true
        defer {
            committingInput = false
            reportPhotoHorizon()
        }
        let oldInput = input
        let rowsChanged = presentedRows != newInput.rowIDs
        let contentChanged = oldInput?.revision != newInput.revision
        let navigationChanged = oldInput?.command != newInput.command ||
            oldInput?.searchQuery != newInput.searchQuery ||
            oldInput?.isReady != newInput.isReady ||
            oldInput?.isRecent != newInput.isRecent
        // The landmarks must refer to rows that are on screen *before* committing this snapshot.
        newInput.viewport.update(query: newInput.searchQuery, command: newInput.command, visibleLandmarks: landmarks)
        input = newInput
        configureLayoutIntent()
        let bottomAlignShortContent = newInput.searchQuery == nil
        if chatLayout.keepContentAtBottomOfVisibleArea != bottomAlignShortContent {
            chatLayout.keepContentAtBottomOfVisibleArea = bottomAlignShortContent
            chatLayout.invalidateLayout()
        }
        if !newInput.isReady { presentContent(false) }

        if rowsChanged {
            replaceRows(with: newInput)
        } else if contentChanged {
            reconfigureVisibleRows()
        }
        if rowsChanged || contentChanged || navigationChanged { setNeedsLayout() }
    }

    private func replaceRows(with timeline: ConversationTimelineView) {
        let oldRows = presentedRows
        let newRows = timeline.rowIDs
        let commit = {
            self.presentedRows = newRows
            self.rowIndexes = Dictionary(uniqueKeysWithValues: newRows.enumerated().map { ($0.element, $0.offset) })
        }
        guard !oldRows.isEmpty, window != nil, bounds.width > 0, isContentPresented else {
            commit()
            reloadData()
            return
        }

        // CollectionDifference's offsets are relative to the old array for removals and
        // to the new one for insertions. Reloading every row here would also discard
        // unaffected hosted views and their media/presentation state.
        let difference = newRows.difference(from: oldRows)
        var removed: [IndexPath] = []
        var inserted: [IndexPath] = []
        for change in difference {
            switch change {
            case let .remove(index, _, _): removed.append(IndexPath(item: index, section: 0))
            case let .insert(index, _, _): inserted.append(IndexPath(item: index, section: 0))
            }
        }
        isApplyingBatch = true
        UIView.performWithoutAnimation {
            self.performBatchUpdates {
                commit()
                self.deleteItems(at: removed)
                self.insertItems(at: inserted)
            } completion: { [weak self] _ in
                guard let self else { return }
                self.isApplyingBatch = false
                self.reconfigureVisibleRows()
                self.setNeedsLayout()
                self.applyDeferredInput()
            }
        }
    }

    private func reconfigureVisibleRows() {
        guard let input else { return }
        for case let cell as TimelineCell in visibleCells {
            guard let id = cell.rowID, rowIndexes[id] != nil else { continue }
            guard cell.configure(id: id, with: input),
                  let path = indexPath(for: cell),
                  let original = chatLayout.layoutAttributesForItem(at: path) else { continue }
            // A new hosted value can have the same message ID and different size.
            // Measure the already mounted cell with its real width and include
            // the resulting attributes in this revision's layout transaction.
            let preferred = cell.preferredLayoutAttributesFitting(original)
            if chatLayout.shouldInvalidateLayout(forPreferredLayoutAttributes: preferred,
                                                 withOriginalAttributes: original) {
                let change = chatLayout.invalidationContext(forPreferredLayoutAttributes: preferred,
                                                            withOriginalAttributes: original)
                chatLayout.invalidateLayout(with: change)
            }
        }
    }

    private func applyDeferredInput() {
        guard !isApplyingBatch, !userIsScrolling, let input = deferredInput else { return }
        deferredInput = nil
        display(input)
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        presentedRows.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = dequeueReusableCell(withReuseIdentifier: "message-row", for: indexPath) as! TimelineCell
        if let input, presentedRows.indices.contains(indexPath.item) {
            cell.configure(id: presentedRows[indexPath.item], with: input)
        }
        cell.setAccessibilityObscured(hidesRowAccessibility)
        return cell
    }

    override func layoutSubviews() {
        // UIKit may ask for a nested layout while instantiating a hosted cell.
        // Only the enclosing transaction may acknowledge a destination or reveal content.
        guard !layingOutViewport, !committingInput else {
            super.layoutSubviews()
            return
        }
        layingOutViewport = true
        defer { layingOutViewport = false }

        if bounds.width > 0, bounds.width != measuredWidth {
            if measuredWidth > 0 { chatLayout.invalidateLayout() }
            measuredWidth = bounds.width
        }
        // Realize the appropriate neighborhood, rather than first building a page of
        // cells at offset zero, when attributes for this revision are already available.
        if !userIsScrolling { placeViewport() }
        super.layoutSubviews()
        // Self-sizing during super can change the origin of our anchor. Resolve it against
        // the new attributes here, within layout, before this surface can be displayed.
        if !userIsScrolling { placeViewport() }
        // After the final placement, so this frame's rows use their current origins.
        updateEdgeBlurs()
        if let input, input.isReady, window != nil, bounds.width > 0, bounds.height > 0 {
            if destinationIsRealized(in: input) {
                presentContent(true)
            }
        }
        reportVisibility()
        reportPhotoHorizon()
        input?.didCompleteViewportLayout?(self)
    }

    private var insetTop: CGFloat { adjustedContentInset.top }
    private var insetBottom: CGFloat { adjustedContentInset.bottom }
    private var minOffset: CGFloat { -insetTop }
    private var maxOffset: CGFloat {
        max(minOffset, chatLayout.collectionViewContentSize.height - bounds.height + insetBottom)
    }
    private var pixel: CGFloat { 1 / max(traitCollection.displayScale, 1) }

    private var footerAlignmentTolerance: CGFloat {
        let viewportHeight = chatLayout.visibleBounds.height
        let contentHeight = chatLayout.collectionViewContentSize.height
        // ChatLayout 2.5.2 bottom-aligns short lists by subtracting the two
        // heights rounded to whole points. Their residuals can differ by up
        // to one point even at the only legal scroll offset.
        let shortContent = chatLayout.keepContentAtBottomOfVisibleArea &&
            contentHeight.rounded() <= viewportHeight.rounded()
        return (shortContent ? 1 : pixel) + max(viewportHeight, contentHeight).ulp
    }

    /// Positive means there's empty space below the footer; negative means it is
    /// clipped. This measures the realized footer, independently of the offset formula.
    var visibleFooterGap: CGFloat? {
        guard let footer = cell(for: .footer) else { return nil }
        return bounds.maxY - insetBottom - footer.frame.maxY
    }

    private func cell(for row: RowID) -> TimelineCell? {
        guard let index = rowIndexes[row],
              let cell = cellForItem(at: IndexPath(item: index, section: 0)) as? TimelineCell,
              cell.rowID == row else { return nil }
        return cell
    }

    private func frame(for row: RowID) -> CGRect? {
        guard let index = rowIndexes[row], numberOfSections > 0,
              index < numberOfItems(inSection: 0) else { return nil }
        return chatLayout.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame
    }

    private func clamp(_ offset: CGFloat) -> CGFloat {
        min(maxOffset, max(minOffset, offset))
    }

    private enum Target {
        case latest
        case top
        case reading(row: RowID, offsetInRow: CGFloat, offsetInViewport: CGFloat)
        case jump(RowID)
    }

    private func target(in input: ConversationTimelineView) -> Target? {
        if let destination = input.viewport.pendingDestination, input.searchQuery == nil {
            switch destination {
            case .latest where input.isRecent: return .latest
            case let .message(member):
                let row = RowID.message(input.memberTargets[member] ?? member)
                if rowIndexes[row] != nil { return .jump(row) }
            default: break
            }
        }
        switch input.viewport.position {
        case .latest:
            // With a pending jump/return, never navigate to the tail of the
            // obsolete older window. Ongoing follow uses the accepted recent
            // window even while a new observation or refresh is loading.
            return input.isRecent ? .latest : nil
        case .top:
            return .top
        case let .reading(anchors):
            for anchor in anchors {
                let row = RowID.message(anchor.message)
                if rowIndexes[row] != nil {
                    return .reading(row: row, offsetInRow: anchor.offsetInRow, offsetInViewport: anchor.offsetInViewport)
                }
                for member in anchor.members {
                    if let id = input.memberTargets[member], rowIndexes[.message(id)] != nil {
                        return .reading(row: .message(id), offsetInRow: anchor.offsetInRow, offsetInViewport: anchor.offsetInViewport)
                    }
                }
            }
            // A disjoint window has no visual correspondence. Hold the current
            // legal position; keep the anchors for a later overlapping cached/server update.
            return nil
        }
    }

    private func desiredOffset(for target: Target) -> CGFloat? {
        switch target {
        case .latest: return maxOffset
        case .top: return minOffset
        case let .jump(row):
            guard let frame = frame(for: row) else { return nil }
            let usableHeight = bounds.height - insetTop - insetBottom
            return clamp(frame.midY - usableHeight / 2 - insetTop)
        case let .reading(row, offsetInRow, offsetInViewport):
            guard let frame = frame(for: row) else { return nil }
            let landmark = cell(for: row)?.bubbleOffset ?? offsetInRow
            return clamp(frame.minY + landmark - insetTop - offsetInViewport)
        }
    }

    private func configureLayoutIntent() {
        guard let input, !userIsScrolling, case .latest? = target(in: input) else {
            chatLayout.keepContentOffsetAtBottomOnBatchUpdates = false
            return
        }
        // Let the layout compensate preferred sizes as cells are measured.
        // The viewport solve uses an absolute destination, never an extra delta.
        chatLayout.keepContentOffsetAtBottomOnBatchUpdates = true
    }

    private func placeViewport() {
        guard let input, input.isReady, bounds.width > 0, bounds.height > 0,
              let target = target(in: input), let offset = desiredOffset(for: target),
              abs(contentOffset.y - offset) > pixel / 2 else { return }
        contentOffset = CGPoint(x: contentOffset.x, y: offset)
    }

    private func destinationIsRealized(in input: ConversationTimelineView) -> Bool {
        guard let target = target(in: input) else {
            return visibleCells.contains { ($0 as? TimelineCell)?.rowID != nil }
        }
        guard let desired = desiredOffset(for: target), abs(contentOffset.y - desired) <= pixel else { return false }
        switch target {
        case .latest:
            guard let gap = visibleFooterGap, abs(gap) <= footerAlignmentTolerance else { return false }
            if input.viewport.pendingDestination == .latest { input.viewport.followLatest() }
        case .top:
            guard visibleCells.isEmpty == false else { return false }
        case let .jump(row):
            guard let cell = cell(for: row), cell.frame.intersects(bounds) else { return false }
            input.viewport.finishJump(landmarks())
        case let .reading(row, _, _):
            guard cell(for: row) != nil else { return false }
        }
        return true
    }

    private func landmarks() -> [ConversationViewport.Landmark] {
        guard let input else { return [] }
        let viewportTop = bounds.minY + insetTop
        let viewportBottom = bounds.maxY - insetBottom
        let candidates = visibleCells.compactMap { $0 as? TimelineCell }
            .filter { $0.frame.maxY > viewportTop && $0.frame.minY < viewportBottom }
            .sorted { $0.frame.minY < $1.frame.minY }
        return candidates.compactMap { cell in
            guard case let .message(id) = cell.rowID else { return nil }
            let local = cell.bubbleOffset ?? 0
            let members = input.memberTargets.compactMap { $0.value == id ? $0.key : nil }
            return ConversationViewport.Landmark(message: id, members: members, offsetInRow: local,
                offsetInViewport: cell.frame.minY + local - viewportTop)
        }
    }

    private func presentContent(_ presented: Bool) {
        guard isContentPresented != presented else { return }
        isContentPresented = presented
        alpha = presented ? 1 : 0
    }

    private func isActuallyAtLatest() -> Bool {
        guard isContentPresented, window != nil, let input,
              input.isReady, input.isRecent, input.searchQuery == nil,
              let gap = visibleFooterGap else { return false }
        return abs(gap) <= footerAlignmentTolerance
    }

    private func reportVisibility() {
        guard !visibilityReportQueued, lastReportedVisibility != isActuallyAtLatest() else { return }
        visibilityReportQueued = true
        // Publishing a read-receipt input to SwiftUI while updating UIView is
        // illegal. Only this *observation* is deferred; it never changes position.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            visibilityReportQueued = false
            let visible = isActuallyAtLatest()
            guard visible != lastReportedVisibility else { return }
            lastReportedVisibility = visible
            input?.onLatestVisibilityChange(visible)
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        userIsScrolling = true
        gestureStartY = contentOffset.y
        gestureMoved = false
        // A command received before this touch may still be waiting for a
        // data batch to complete. Mark its serial consumed as well.
        input?.viewport.cancelNavigation(through: deferredInput?.command?.serial)
        input?.viewport.beginReading(landmarks())
        configureLayoutIntent()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateEdgeBlurs()
        if userIsScrolling, abs(contentOffset.y - gestureStartY) > pixel { gestureMoved = true }
        reportVisibility()
        reportPhotoHorizon()
    }

    private func reportPhotoHorizon() {
        guard !photoHorizonReportQueued else { return }
        photoHorizonReportQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.photoHorizonReportQueued = false
            guard self.window != nil, self.isContentPresented, self.input?.isReady == true else { return }
            let ids = self.indexPathsForVisibleItems.sorted().compactMap { path in
                self.presentedRows.indices.contains(path.item) ? self.presentedRows[path.item] : nil
            }
            self.input?.onVisibleRowsChange?(ids)
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { finishUserScroll() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        finishUserScroll()
    }

    private func finishUserScroll() {
        guard userIsScrolling, let input else { return }
        userIsScrolling = false
        let reachedEnd = visibleFooterGap.map { $0 >= -footerAlignmentTolerance } ?? false
        if reachedEnd, input.isRecent, input.searchQuery == nil {
            input.viewport.followLatest()
        } else {
            input.viewport.beginReading(landmarks())
        }
        configureLayoutIntent()
        applyDeferredInput()
        setNeedsLayout()
        if gestureMoved, reachedEnd, input.searchQuery == nil { input.onUserReachedWindowEnd() }
    }
}
