import Observation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private struct ConversationHeaderControl: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.frame(width: 44, height: 44)
                .glassEffect(.regular.interactive(), in: .circle)
        } else {
            content.frame(width: 44, height: 44)
                .background(.thinMaterial, in: Circle())
        }
    }
}

private struct ConversationNameGlass: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        let label = content.padding(.horizontal, 10).padding(.vertical, 4)
        if #available(iOS 26.0, *) {
            label.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            label.background(.thinMaterial, in: Capsule())
        }
    }
}

struct ConversationView: View {

    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var pickerPhotoTarget: SecureConversationResetTarget?
    @State private var pickerFileTarget: SecureConversationResetTarget?
    @State private var showingAttachmentSheet = false
    @State private var attachmentSheetTarget: SecureConversationResetTarget?
    @State private var pendingAttachmentAction: AttachmentSheetAction?
    @State private var showingPhotoPicker = false
    @State private var showingFileImporter = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var isPreviewingStagedPhoto = false
    @State private var stagedPhotos: [StagedPhotoDraft]
    @State private var stagedFiles: [StagedFileDraft]
    @State private var isPreparingPhotos = false
    @State private var photoPreparation: AttachmentPreparationLease?
    @State private var photoPreparationTask: Task<Void, Never>?
    @State private var photoDraftTarget: SecureConversationResetTarget?
    @State private var searchText = ""
    @State private var isSearchPresented = false
    @FocusState private var isSearchFieldFocused: Bool
    @State private var showingEditAlert = false
    @State private var editedText = ""
    @State private var messageBeingEdited: ChatMessage?
    @State private var messageBeingUnsent: ChatMessage?
    @State private var timestampRevealState: MessageTimestampRevealState
    @State private var interactionMessageID: UUID?
    @State private var interactionSourceFrame: CGRect?
    @State private var interactionMessageOffsetY: CGFloat = 0
    @State private var viewport = ConversationViewport()
    @State private var viewportCommand: ConversationViewportCommand?
    @State private var viewportCommandSerial = 0
    @State private var messageFrames = ConversationMessageFrames()
    @State private var isPresentingLocationMap = false
    @State private var isPresentingPartnerProfile = false
    @State private var headerSafeAreaTop: CGFloat = 0
    @State private var partnerPhotos = PartnerPhotoStore()
    @State private var activeReactionBurst: ReactionBurstEvent?
    @State private var timelineCache = ConversationTimelinePresentationCache()
    @State private var photoPrefetcher = ChatPhotoPrefetcher()
    @State private var photoPrefetchIsActive = false
    @State private var isShowingReplyHistory = false
    @Namespace private var locationTransition

    init() {
        _stagedPhotos = State(initialValue: [])
        _stagedFiles = State(initialValue: [])
        _isPreparingPhotos = State(initialValue: false)
        _timestampRevealState = State(
            initialValue: MessageTimestampRevealState()
        )
    }

    var body: some View {
        let timeline = currentTimelinePresentation

        NavigationStack {
            conversationHistoryAndComposer(timeline: timeline)
            .modifier(ConversationHeaderBar(header: conversationHeader))
            .background { GiftWrapWallpaper().ignoresSafeArea(.container) }
            .modifier(ConversationSnowfallPreview())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $isPresentingPartnerProfile) {
                PartnerProfileView(
                    accountID: model.currentUser.id,
                    partnerID: model.partner.id,
                    initials: model.partner.initials,
                    name: model.partner.displayName,
                    store: partnerPhotos,
                    searchMessages: {
                        isPresentingPartnerProfile = false
                        isSearchPresented = true
                    },
                    showMessageInConversation: { id in
                        isPresentingPartnerProfile = false
                        showPinnedMessageInHistory(id)
                    }
                )
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("conversation-screen")
            .accessibilityHidden(interactionMessageID != nil)
            .onChange(of: searchText) {
                model.searchMessageHistory(searchText)
            }
            .onChange(of: isSearchPresented) {
                dismissMessageInteractions()
                isSearchFieldFocused = isSearchPresented
                if !isSearchPresented {
                    searchText = ""
                    if !isShowingReplyHistory && !model.usesBoundedHistory {
                        model.finishMessageHistorySearch()
                    }
                } else {
                    isShowingReplyHistory = false
                    model.beginMessageHistorySearch()
                }
            }
            .sheet(isPresented: $showingAttachmentSheet, onDismiss: performAttachmentSheetAction) {
                RecentPhotoAttachmentSheet(
                    maximumSelectionCount: remainingPhotoSlots,
                    onSelect: { identifiers in
                        pendingAttachmentAction = .recentPhotos(identifiers)
                        showingAttachmentSheet = false
                    },
                    onLibrary: {
                        pendingAttachmentAction = .library
                        showingAttachmentSheet = false
                    },
                    onFiles: {
                        pendingAttachmentAction = .files
                        showingAttachmentSheet = false
                    }
                )
            }
            .photosPicker(
                isPresented: $showingPhotoPicker,
                selection: $selectedPhotoItems,
                maxSelectionCount: max(1, remainingPhotoSlots),
                matching: .any(of: [.images, .videos]),
                preferredItemEncoding: .current
            )
            .onChange(of: selectedPhotoItems) {
                guard !selectedPhotoItems.isEmpty else { return }
                let items = selectedPhotoItems
                selectedPhotoItems = []
                guard let pickedTarget = pickerPhotoTarget, model.isCurrentAttachmentPreparation(pickedTarget) else { return }
                guard let preparation = beginPhotoPreparation() else { return }
                photoPreparationTask = Task {
                    await prepareSelectedPhotos(items, target: preparation.target, lease: preparation.lease)
                }
            }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.data]
            ) { [pickedTarget = pickerFileTarget] result in
                switch result {
                case let .success(url):
                    guard let pickedTarget, model.isCurrentAttachmentPreparation(pickedTarget) else { return }
                    prepareSelectedFile(url)
                case let .failure(error):
                    guard let pickedTarget, model.isCurrentAttachmentPreparation(pickedTarget) else { return }
                    let nsError = error as NSError
                    guard nsError.code != NSUserCancelledError else { return }
                    model.errorMessage = error.localizedDescription
                }
            }
            .fullScreenCover(isPresented: $isPresentingLocationMap) {
                if let presentation = model.mutualLocationPresentation() {
                    let map = MutualLocationMapView(
                        presentation: presentation,
                        currentUserName: "You",
                        partnerName: partnerDisplayName
                    ) {
                        isPresentingLocationMap = false
                    }
                    if reduceMotion {
                        map.transition(.opacity)
                    } else {
                        map.navigationTransition(
                            .zoom(
                                sourceID: "mutual-location-map",
                                in: locationTransition
                            )
                        )
                    }
                }
            }
            .onChange(of: model.mutualLocationPresentation() != nil) {
                if model.mutualLocationPresentation() == nil {
                    isPresentingLocationMap = false
                }
            }
            .alert("Edit Message", isPresented: $showingEditAlert) {
                TextField("Message", text: $editedText)
                Button("Cancel", role: .cancel) {
                    messageBeingEdited = nil
                    editedText = ""
                }
                Button("Save") {
                    guard let message = messageBeingEdited else { return }
                    let body = editedText
                    messageBeingEdited = nil
                    editedText = ""
                    Task {
                        await model.editMessage(message, body: body)
                    }
                }
            } message: {
                Text("The edited label will appear beneath the message.")
            }
            .confirmationDialog(
                "Unsend this message?",
                isPresented: Binding(
                    get: { messageBeingUnsent != nil },
                    set: { isPresented in
                        if !isPresented {
                            messageBeingUnsent = nil
                        }
                    }
                ),
                titleVisibility: .visible
            ) {
                Button("Unsend", role: .destructive) {
                    guard let message = messageBeingUnsent else { return }
                    messageBeingUnsent = nil
                    Task {
                        await model.unsendMessage(message)
                    }
                }
                Button("Cancel", role: .cancel) {
                    messageBeingUnsent = nil
                }
            } message: {
                Text("This removes the message from both devices.")
            }
            .onAppear {
                photoPrefetchIsActive = true
                model.conversationVisibilityDidChange(
                    isVisible: true,
                    isAppActive: scenePhase == .active
                )
            }
            .onChange(of: model.reactionBurstEvent) { _, event in
                activeReactionBurst = event
            }
            .onChange(
                of: conversationPresentationIsObscuring,
                initial: true
            ) { _, isPresented in
                model.conversationObscurationDidChange(
                    .conversationPresentation,
                    isObscured: isPresented
                )
            }
            .onChange(of: model.attachmentPreparationTarget) {
                photoPreparationTargetDidChange()
            }
            .onChange(of: model.currentUser.id) {
                isPresentingPartnerProfile = false
            }
            .onChange(of: model.partner.id) {
                isPresentingPartnerProfile = false
            }
            .onDisappear(perform: conversationDidDisappear)
            .onChange(of: scenePhase) {
                if scenePhase != .active {
                    dismissMessageInteractions()
                    activeReactionBurst = nil
                }
                model.conversationVisibilityDidChange(
                    isVisible: !isPresentingPartnerProfile,
                    isAppActive: scenePhase == .active
                )
            }
        }
        .overlay {
            GeometryReader { geometry in
                if
                    let interactionMessageID,
                    let frame = messageFrames.frame(for: interactionMessageID)
                        ?? interactionSourceFrame.map({ $0.offsetBy(dx: geometry.frame(in: .global).minX, dy: geometry.frame(in: .global).minY) }),
                    let message = timeline.messagesByID[interactionMessageID]
                {
                    let resolvedSourceFrame =
                        interactionSourceFrame ?? frame.offsetBy(
                            dx: -geometry.frame(in: .global).minX,
                            dy: -geometry.frame(in: .global).minY
                        )
                    MessageInteractionOverlay(
                        message: message,
                        currentUserID: model.currentUser.id,
                        sourceFrame: resolvedSourceFrame,
                        containerSize: geometry.size,
                        safeAreaInsets: geometry.safeAreaInsets,
                        focusedMessage:
                            focusedInteractionPresentation(
                                for: message,
                                timeline: timeline
                            ),
                        onReact: { emoji in
                            dismissMessageInteractions()
                            Task {
                                await model.toggleReaction(
                                    emoji,
                                    on: message
                                )
                            }
                        },
                        onAction: { action in
                            performMessageAction(
                                action,
                                for: message
                            )
                        },
                        onPresentationUpdate: {
                            sourceFrame,
                            translationY in
                            guard
                                interactionMessageID == message.id
                            else {
                                return
                            }
                            let updatePresentation = {
                                if interactionSourceFrame == nil {
                                    interactionSourceFrame = sourceFrame
                                }
                                interactionMessageOffsetY = translationY
                            }
                            if reduceMotion {
                                updatePresentation()
                            } else {
                                withAnimation(
                                    .easeOut(duration: 0.16)
                                ) {
                                    updatePresentation()
                                }
                            }
                        },
                        onDismiss: dismissMessageInteractions,
                        isPinned: model.messagePins?.isPinned(pinTarget(for: message)?.id ?? message.id) == true,
                        allowsPinning: pinTarget(for: message) != nil,
                        pinIsPending: pinTarget(for: message).map { model.messagePins?.pendingMessageIDs.contains($0.id) == true } ?? false
                    )
                }
            }
        }
        .overlay {
            if let activeReactionBurst {
                ReactionEmojiBurstView(event: activeReactionBurst) {
                    guard
                        self.activeReactionBurst?.id
                            == activeReactionBurst.id
                    else {
                        return
                    }
                    self.activeReactionBurst = nil
                    model.reactionBurstDidFinish(activeReactionBurst.id)
                }
                .id(activeReactionBurst.id)
            }
        }
        .environment(\.usesGiftWrap, true)
        .tint(GiftWrapAppearance.accent(colorScheme == .dark))
    }

    private var conversationPresentationIsObscuring: Bool {
        showingPhotoPicker
            || showingAttachmentSheet
            || isPresentingPartnerProfile
            || showingFileImporter
            || isPresentingLocationMap
            || showingEditAlert
            || messageBeingUnsent != nil
    }

    @ViewBuilder
    private func conversationHistoryAndComposer(timeline: ConversationTimelinePresentation) -> some View {
        if #available(iOS 26.0, *) {
            GeometryReader { geometry in
                conversationHistoryScroll(timeline: timeline, edgeInsets: geometry.safeAreaInsets)
                    .padding(.top, -geometry.safeAreaInsets.top)
                    .padding(.bottom, -geometry.safeAreaInsets.bottom)
            }
            .safeAreaBar(edge: .bottom, spacing: 0) { conversationComposer }
        } else {
            VStack(spacing: 0) {
                conversationHistoryScroll(timeline: timeline)
                conversationComposer
            }
        }
    }

    private func conversationHistoryScroll(
        timeline: ConversationTimelinePresentation,
        edgeInsets: EdgeInsets = EdgeInsets()
    ) -> some View {
        let accountID = model.currentUser.id
        let conversationID = model.conversationID
        let revision = ConversationTimelineRevision(
            messages: model.messagesRevision,
            search: model.historyController?.searchRevision ?? 0,
            query: searchText,
            loading: model.historyIsLoading,
            hasOlder: model.historyHasOlder,
            hasNewer: model.historyHasNewer,
            recent: model.historyIsRecent,
            browsing: model.historyController?.isBrowsingHistory == true,
            typing: showsPartnerTyping,
            interaction: interactionMessageID,
            interactionOffset: interactionMessageOffsetY,
            pendingShares: model.pendingShareTimelineStatuses,
            colorScheme: colorScheme == .dark,
            contentSize: dynamicTypeSize
        )
        return ConversationTimelineView(
            viewport: viewport,
            rowIDs: timelineRowIDs(timeline),
            revision: AnyHashable([AnyHashable(revision), AnyHashable(model.messagePins?.messageIDs ?? [])]),
            memberTargets: timeline.scrollTargetsByMessageID,
            isReady: model.messageHistoryIsReady,
            isRecent: model.historyWindowIsRecent,
            searchQuery: searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : searchText,
            command: viewportCommand,
            content: { id in
                AnyView(timelineContent(id, timeline: timeline)
                    .accessibilityHidden(interactionMessageID != nil)
                    .environment(model)
                    .environment(\.usesGiftWrap, true)
                    .environment(\.colorScheme, colorScheme)
                    .environment(\.dynamicTypeSize, dynamicTypeSize)

                    .environment(\.conversationMessageFrames, messageFrames)
                    .environment(\.encryptedAttachmentResolver, model.encryption?.resolver))
            },
            onLatestVisibilityChange: { isAtLatest in
                guard model.currentUser.id == accountID, model.conversationID == conversationID else { return }
                model.historyViewportDidChange(isAtLatest: isAtLatest)
            },
            onUserReachedWindowEnd: {
                guard model.currentUser.id == accountID, model.conversationID == conversationID else { return }
                if isShowingReplyHistory {
                    isShowingReplyHistory = false
                    requestViewport(.latest)
                    model.returnToRecentMessageHistory()
                }
            },
            didCompleteViewportLayout: { collection in
            },
            isInteractionPresented: interactionMessageID != nil,
            edgeInsets: edgeInsets,
            onVisibleRowsChange: { ids in
                guard photoPrefetchIsActive, model.currentUser.id == accountID,
                      model.conversationID == conversationID else { return }
                let indices = ids.compactMap { id -> Int? in
                    guard case let .message(messageID) = id else { return nil }
                    return timeline.rowIndexesByID[messageID]
                }
                photoPrefetcher.update(
                    ChatPhotoPrefetchHorizon.attachments(
                        itemCount: timeline.rows.count, visibleIndices: indices, itemAt: { timeline.rows[$0].item }
                    ),
                    resolver: model.encryption?.resolver
                )
            }
        )
        .accessibilityHidden(interactionMessageID != nil)
        .overlay(alignment: .bottomTrailing) {
            if showsViewportMarkers {
                Color(red: 0, green: 1, blue: 1).frame(width: 12, height: 2)
                    .accessibilityHidden(true).allowsHitTesting(false)
            }
        }
        .simultaneousGesture(timestampRevealGesture, including: .all)
        .overlay {
            if !model.messageHistoryIsReady {
                if model.messageHistoryLoadFailed {
                    ContentUnavailableView {
                        Label("Messages unavailable", systemImage: "wifi.exclamationmark")
                    } actions: { Button("Retry") { model.retryMessageHistory() } }
                } else { ProgressView().accessibilityLabel("Opening messages") }
            }
        }
    }

    private func timelineRowIDs(_ timeline: ConversationTimelinePresentation) -> [ConversationViewportRowID] {
        var ids: [ConversationViewportRowID] = [.controls]
        if timeline.rows.isEmpty { ids.append(.empty) }
        else { ids += timeline.rows.map { .message($0.id) } }
        if !timeline.rows.isEmpty, showsPartnerTyping, searchText.isEmpty { ids.append(.typing) }
        ids.append(.footer)
        return ids
    }

    @ViewBuilder
    private func timelineContent(_ id: ConversationViewportRowID, timeline: ConversationTimelinePresentation) -> some View {
        switch id {
        case .controls:
            VStack(spacing: 0) {
                if !searchText.isEmpty { searchHeader(resultCount: timeline.rows.count) }
                historyControls
            }.padding(.top, 16).padding(.horizontal, 12)
                .modifier(ConversationEdgeBlurModifier())
        case .message(let id):
            if let index = timeline.rowIndexesByID[id] {
                let row = timeline.rows[index]
                VStack(spacing: 0) {
                    if row.showsDayHeader { dayHeader(for: row.message.createdAt) }
                    messageRow(
                        for: row.message, photoGroup: row.item.photoGroup,
                        groupedWithPrevious: row.grouping.joinsPrevious,
                        groupedWithNext: row.grouping.joinsNext,
                        latestOutgoingMessageID: timeline.latestOutgoingMessageID,
                        replyMessage: row.message.replyToID.flatMap { timeline.messagesByID[$0] }
                    )
                    .opacity(interactionMessageID == row.message.id ? 0 : 1)
                    .background(ConversationViewportBubbleMarker())
                    .padding(.top, row.topPadding)
                }.padding(.horizontal, 12)
                .overlay(alignment: .leading) {
                    if showsViewportMarkers {
                        Color(red: 1, green: 1, blue: 0).frame(width: 2)
                            .accessibilityHidden(true).allowsHitTesting(false)
                    }
                }
            }
        case .empty:
            Group {
                if searchText.isEmpty {
                    ContentUnavailableView {
                        Label("Start your conversation", systemImage: "bubble.left.and.bubble.right")
                    } description: { Text("Send a message, photo, or voice note.") }
                    .padding(.top, 40)
                } else { ContentUnavailableView.search(text: searchText) }
            }.padding(.horizontal, 12)
        case .typing:
            TypingIndicator(partnerName: partnerDisplayName)
                .modifier(ConversationEdgeBlurModifier())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 10).padding(.horizontal, 12)
        case .footer:
            Color.clear.frame(height: 16)
                .overlay(alignment: .bottomLeading) {
                    if showsViewportMarkers {
                        Color(red: 1, green: 0, blue: 1).frame(height: 2)
                    }
                }.accessibilityHidden(true)
        }
    }

    private var showsViewportMarkers: Bool {
        false
    }

    private func requestViewport(_ destination: ConversationViewportCommand.Destination) {
        viewportCommandSerial &+= 1
        viewportCommand = ConversationViewportCommand(serial: viewportCommandSerial, destination: destination)
    }

    private var conversationComposer: some View {
        @Bindable var model = model
        return MessageComposer(
            text: $model.draft,
            replyingTo: model.replyTarget,
            currentUserID: model.currentUser.id,
            stagedPhotos: stagedPhotos,
            stagedFiles: stagedFiles,
            usesRecentPhotoSheet: true,
            stagedPhotoPreviewChanged: { isPreviewingStagedPhoto = $0 },
            isPreparingPhotos: isPreparingPhotos,
            canAddPhoto: remainingPhotoSlots > 0,
            allowsVoiceMessages: true,
            addPhoto: {

                guard !isPreparingPhotos, let target = model.attachmentPreparationTarget,
                      model.isCurrentAttachmentPreparation(target) else { return }
                attachmentSheetTarget = target
                pendingAttachmentAction = nil
                showingAttachmentSheet = true
            },
            addFile: {

                pickerFileTarget = model.attachmentPreparationTarget
                showingFileImporter = true
            },
            removePhoto: { photoID in
                removeStagedPhoto(photoID)
            },
            removeFile: { fileID in
                removeStagedFile(fileID)
            },
            pastePhotos: { photos in

                guard let preparation = beginPhotoPreparation() else { return }
                photoPreparationTask = Task {
                    await preparePastedPhotos(photos, target: preparation.target, lease: preparation.lease)
                }
            },
            cancelReply: {
                model.cancelReply()
            },
            textChanged: {
                model.draftDidChange()
            },
            voiceMessageStaged: { staged in
                prepareLatestConversationPosition()
                searchText = ""
                isSearchPresented = false
                if !model.historyIsRecent { model.returnToRecentMessageHistory() }
                Task {
                    await model.sendStagedVoiceMessage(staged)
                }
            },
            voiceMessageError: { message in
                model.errorMessage = message
            },
            makeVoiceMessageStagingOperation: model.makeVoiceMessageStagingOperation,
            allowsQuietDelivery: true
        ) { submittedDraft, replyToID, deliveryMode in
            let photoShares = stagedPhotos.map(\.share)
            let fileShares = stagedFiles.map(\.share)
            do {
                // Optimistic rows may render as soon as submission
                // publishes them. Their previews must already exist.
                let photosToCache = stagedPhotos
                for photo in photosToCache {
                    AttachmentImageCache.shared.insertInMemory(
                        photo.thumbnail,
                        forKey: photo.id.uuidString
                    )
                }
                try model.submitComposerMessage(
                    submittedDraft,
                    replyingTo: replyToID,
                    photoShares: photoShares,
                    fileShares: fileShares,
                    deliveryMode: deliveryMode
                )
                // Sending is an explicit request to see the new row, even after
                // reading history. Incoming updates keep their existing policy.
                prepareLatestConversationPosition()
                searchText = ""
                isSearchPresented = false
                if !model.historyIsRecent { model.returnToRecentMessageHistory() }
                if !photoShares.isEmpty || !fileShares.isEmpty {
                    Task {
                        for photo in photosToCache where model.encryption == nil {
                            await AttachmentImageCache.shared.storeDownloadedImage(
                                photo.thumbnail,
                                forKey: photo.id.uuidString
                            )
                        }
                    }
                    withAnimation(photoDraftAnimation) {
                        stagedPhotos = []
                        stagedFiles = []
                    }
                }
                return true
            } catch {
                return false
            }
        }
    }

    @ViewBuilder private var historyControls: some View {
    if model.usesBoundedHistory, !searchText.isEmpty {
        if model.historyController?.isSearching == true { ProgressView("Searching messages") }
        if model.historyController?.search?.continuation != nil {
            Button("More search results") { model.loadMoreSearchResults() }
                .padding(.vertical, 12)
        }
    }
    if model.usesBoundedHistory, searchText.isEmpty,
       model.historyController?.isBrowsingHistory == true {
        HStack {
            if model.historyHasNewer {
                Button("Newer messages") {
                    requestViewport(.preserve)
                    model.loadNewerMessages()
                }
            }
            Button("Latest messages") {
                prepareLatestConversationPosition()
                model.returnToRecentMessageHistory()
            }
        }.disabled(model.historyIsLoading).padding(.vertical, 12)
    }
    if model.historyIsLoading {
        if !model.usesBoundedHistory || model.historyController?.isBrowsingHistory == true {
            ProgressView("Loading earlier messages")
                .font(.caption)
                .padding(.vertical, 12)
                .accessibilityIdentifier("conversation-history-loading")
        }
    } else if model.historyHasOlder, searchText.isEmpty {
        Button("Load earlier messages") {
            requestViewport(.preserve)
            model.loadOlderMessages()
        }
        .font(.subheadline)
        .padding(.vertical, 12)
        .accessibilityIdentifier("conversation-load-earlier")
    }
    }

    private var currentTimelinePresentation: ConversationTimelinePresentation {
        timelineCache.value(
            messages: model.usesBoundedHistory && !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? (model.historyController?.search?.messages ?? []) : model.messages,
            replyContextMessages: model.replyContextMessages,
            revision: model.messagesRevision &+ (model.historyController?.searchRevision ?? 0),
            searchText: searchText,
            currentUserID: model.currentUser.id
        )
    }

    private var showsPartnerTyping: Bool {
        model.isPartnerTyping
    }

    private var remainingPhotoSlots: Int {
        max(
            0,
            PhotoAttachmentDraftPolicy.maximumCount
                - stagedPhotos.count
                - stagedFiles.count
        )
    }

    private func photoPreparationTargetDidChange() {
        photoPrefetcher.stop()
        pendingAttachmentAction = nil; attachmentSheetTarget = nil
        showingAttachmentSheet = false
        pickerPhotoTarget = nil; pickerFileTarget = nil
        showingPhotoPicker = false; showingFileImporter = false
        discardStagedFiles()
        if photoPreparation?.isCurrent == false { cancelPhotoPreparation() }
        if let photoDraftTarget, photoDraftTarget != model.attachmentPreparationTarget {
            discardStagedPhotos()
        }
    }

    private func conversationDidDisappear() {
        photoPrefetchIsActive = false
        photoPrefetcher.stop()
        dismissMessageInteractions()
        activeReactionBurst = nil
        model.conversationObscurationDidChange(.conversationPresentation, isObscured: false)
        model.conversationVisibilityDidChange(isVisible: false, isAppActive: scenePhase == .active)
        // Pushing the person's profile keeps the conversation and its draft alive.
        guard !isPresentingPartnerProfile || model.phase != .conversation else { return }
        // A full-screen draft preview temporarily covers chat; its source stays staged.
        guard !isPreviewingStagedPhoto || model.phase != .conversation else { return }
        cancelPhotoPreparation()
        discardStagedPhotos()
        discardStagedFiles()
    }

    @MainActor
    private func beginPhotoPreparation() -> (target: SecureConversationResetTarget, lease: AttachmentPreparationLease)? {

        guard !isPreparingPhotos, let target = model.attachmentPreparationTarget,
              model.isCurrentAttachmentPreparation(target) else { return nil }
        if let photoDraftTarget, photoDraftTarget != target { discardStagedPhotos() }
        let capturedModel = model
        let lease = AttachmentPreparationLease { [weak capturedModel] in
            capturedModel?.isCurrentAttachmentPreparation(target) == true
        }
        photoPreparation = lease; isPreparingPhotos = true
        return (target, lease)
    }

    @MainActor
    private func cancelPhotoPreparation() {
        photoPreparation?.invalidate(); photoPreparationTask?.cancel()
        photoPreparation = nil; photoPreparationTask = nil; isPreparingPhotos = false
    }

    @MainActor
    private func finishPhotoPreparation(_ lease: AttachmentPreparationLease) {
        guard photoPreparation === lease else { return }
        photoPreparation = nil; photoPreparationTask = nil; isPreparingPhotos = false
    }

    private enum AttachmentSheetAction {
        case recentPhotos([String])
        case library
        case files
    }

    private func performAttachmentSheetAction() {
        let action = pendingAttachmentAction
        pendingAttachmentAction = nil
        defer { attachmentSheetTarget = nil }
        guard let action, let target = attachmentSheetTarget,
              model.isCurrentAttachmentPreparation(target) else { return }
        switch action {
        case .library:
            guard remainingPhotoSlots > 0 else { return }
            pickerPhotoTarget = target
            showingPhotoPicker = true
        case .files:
            pickerFileTarget = target
            showingFileImporter = true
        case let .recentPhotos(identifiers):
            guard !identifiers.isEmpty, let preparation = beginPhotoPreparation() else { return }
            photoPreparationTask = Task {
                await prepareRecentPhotos(identifiers, target: preparation.target, lease: preparation.lease)
            }
        }
    }

    @MainActor
    private func prepareRecentPhotos(_ identifiers: [String], target: SecureConversationResetTarget,
                                     lease: AttachmentPreparationLease) async {
        defer { finishPhotoPreparation(lease) }
        var failureMessage: String?
        for identifier in identifiers.prefix(remainingPhotoSlots) {
            do {
                let photo = try await lease.load { try await RecentPhotoLibrary.importPhoto(identifier: identifier) }
                defer { photo.cleanUp() }
                guard let thumbnail = try await lease.load({ await ImageDecoding.thumbnail(from: photo.url, maximumPixelSize: 960) }) else {
                    failureMessage = "One of the photos couldn’t be prepared."
                    continue
                }
                let share = try lease.stage({ try model.stageAttachmentFile(from: photo.url, kind: .image,
                    suggestedName: photo.originalFileName, contentTypeIdentifier: photo.contentTypeIdentifier)
                }, accepts: { share in
                    share.conversationOwnerID?.utf8.elementsEqual(target.accountID.utf8) == true
                        && share.targetConversationID?.utf8.elementsEqual(target.conversationID.utf8) == true
                }, discard: { model.discardAttachmentDrafts(for: [$0]) })
                photoDraftTarget = target
                withAnimation(photoDraftAnimation) { stagedPhotos.append(StagedPhotoDraft(share: share, thumbnail: thumbnail)) }
            } catch {
                guard lease.isCurrent, !Task.isCancelled, photoPreparation === lease else { return }
                failureMessage = error.localizedDescription
            }
        }
        if lease.isCurrent, !Task.isCancelled, photoPreparation === lease, let failureMessage {
            model.errorMessage = failureMessage
        }
    }

    @MainActor
    private func prepareSelectedPhotos(
        _ items: [PhotosPickerItem], target: SecureConversationResetTarget,
        lease: AttachmentPreparationLease
    ) async {
        defer { finishPhotoPreparation(lease) }

        var failureMessage: String?
        for item in items.prefix(remainingPhotoSlots) {
            do {
                if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                    guard let transfer = try await lease.load({ try await item.loadTransferable(type: ImportedMovieTransfer.self) }) else {
                        failureMessage = "One of the videos couldn’t be prepared."
                        continue
                    }
                    let movie = try transfer.result.get()
                    defer { movie.cleanUp() }
                    let share = try lease.stage({ try model.stageAttachmentFile(from: movie.url, kind: .movie,
                        suggestedName: movie.originalFileName, contentTypeIdentifier: movie.contentTypeIdentifier)
                    }, accepts: { share in
                        share.conversationOwnerID?.utf8.elementsEqual(target.accountID.utf8) == true
                            && share.targetConversationID?.utf8.elementsEqual(target.conversationID.utf8) == true
                    }, discard: { model.discardAttachmentDrafts(for: [$0]) })
                    photoDraftTarget = target
                    withAnimation(photoDraftAnimation) { stagedFiles.append(StagedFileDraft(share: share)) }
                    continue
                }
                guard let transfer = try await lease.load({ try await item.loadTransferable(type: ImportedPhotoTransfer.self) }) else {
                    failureMessage = "One of the photos couldn’t be prepared."
                    continue
                }
                let photo = try transfer.result.get()
                defer { photo.cleanUp() }
                guard let thumbnail = try await lease.load({ await ImageDecoding.thumbnail(
                    from: photo.url, maximumPixelSize: 960
                ) }) else {
                    failureMessage = "One of the photos couldn’t be prepared."
                    continue
                }
                let share = try lease.stage({ try model.stageAttachmentFile(
                    from: photo.url,
                    kind: .image,
                    suggestedName: photo.originalFileName,
                    contentTypeIdentifier: photo.contentTypeIdentifier
                ) }, accepts: { share in
                    share.conversationOwnerID?.utf8.elementsEqual(target.accountID.utf8) == true
                        && share.targetConversationID?.utf8.elementsEqual(target.conversationID.utf8) == true
                }, discard: { model.discardAttachmentDrafts(for: [$0]) })
                // No suspension between the scoped staging check and draft admission.
                photoDraftTarget = target
                withAnimation(photoDraftAnimation) {
                    stagedPhotos.append(
                        StagedPhotoDraft(
                            share: share,
                            thumbnail: thumbnail
                        )
                    )
                }
            } catch {
                guard lease.isCurrent, !Task.isCancelled, photoPreparation === lease else { return }
                failureMessage = error.localizedDescription
            }
        }

        if lease.isCurrent, !Task.isCancelled, photoPreparation === lease, let failureMessage {
            model.errorMessage = failureMessage
        }
    }

    @MainActor
    private func preparePastedPhotos(_ photos: [PastedPhoto], target: SecureConversationResetTarget,
                                     lease: AttachmentPreparationLease) async {
        defer { finishPhotoPreparation(lease) }

        let availableSlots = remainingPhotoSlots
        var failureMessage: String?
        if photos.count > availableSlots {
            failureMessage = PhotoAttachmentDraftError.tooMany(
                maximum: PhotoAttachmentDraftPolicy.maximumCount
            ).localizedDescription
        }

        for photo in photos.prefix(availableSlots) {
            do {
                try PendingShareAttachmentPolicy.validate(byteSize: Int64(photo.data.count),
                    maximumBytes: PendingShareAttachmentPolicy.maximumSendingPhotoBytes)
                guard
                    let thumbnail = try await lease.load({ await ImageDecoding.thumbnail(
                        from: photo.data,
                        maximumPixelSize: 960
                    ) })
                else {
                    failureMessage = "One of the photos couldn’t be prepared."
                    continue
                }
                let contentType =
                    UTType(photo.contentTypeIdentifier) ?? .image
                let share = try lease.stage({ try model.stageAttachmentData(
                    photo.data,
                    kind: .image,
                    suggestedName: nil,
                    preferredExtension:
                        contentType.preferredFilenameExtension,
                    contentTypeIdentifier: contentType.identifier
                ) }, accepts: { share in
                    share.conversationOwnerID?.utf8.elementsEqual(target.accountID.utf8) == true
                        && share.targetConversationID?.utf8.elementsEqual(target.conversationID.utf8) == true
                }, discard: { model.discardAttachmentDrafts(for: [$0]) })
                // No suspension between the scoped staging check and draft admission.
                photoDraftTarget = target
                withAnimation(photoDraftAnimation) {
                    stagedPhotos.append(
                        StagedPhotoDraft(
                            share: share,
                            thumbnail: thumbnail
                        )
                    )
                }
            } catch {
                guard lease.isCurrent, !Task.isCancelled, photoPreparation === lease else { return }
                failureMessage = error.localizedDescription
            }
        }

        if lease.isCurrent, !Task.isCancelled, photoPreparation === lease, let failureMessage {
            model.errorMessage = failureMessage
        }
    }

    private func removeStagedPhoto(_ photoID: UUID) {
        guard
            let index = stagedPhotos.firstIndex(
                where: { $0.id == photoID }
            )
        else {
            return
        }
        let removed = stagedPhotos[index]
        _ = withAnimation(photoDraftAnimation) {
            stagedPhotos.remove(at: index)
        }
        model.discardAttachmentDrafts(for: [removed.share])
    }

    private func discardStagedPhotos() {
        guard !stagedPhotos.isEmpty else { return }
        model.discardAttachmentDrafts(
            for: stagedPhotos.map(\.share)
        )
        stagedPhotos = []; photoDraftTarget = nil
    }

    private func prepareSelectedFile(_ url: URL) {

        guard remainingPhotoSlots > 0 else {
            model.errorMessage = PhotoAttachmentDraftError.tooMany(
                maximum: PhotoAttachmentDraftPolicy.maximumCount
            ).localizedDescription
            return
        }
        do {
            let contentType = UTType(
                filenameExtension: url.pathExtension
            )
            let share = try model.stageAttachmentFile(
                from: url,
                kind: LocalAttachmentService.fileKind(for: contentType),
                suggestedName: url.lastPathComponent,
                contentTypeIdentifier: contentType?.identifier
            )
            withAnimation(photoDraftAnimation) {
                stagedFiles.append(StagedFileDraft(share: share))
            }
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func removeStagedFile(_ fileID: UUID) {
        guard
            let index = stagedFiles.firstIndex(where: { $0.id == fileID })
        else {
            return
        }
        let removed = stagedFiles[index]
        _ = withAnimation(photoDraftAnimation) {
            stagedFiles.remove(at: index)
        }
        model.discardAttachmentDrafts(for: [removed.share])
    }

    private func discardStagedFiles() {
        guard !stagedFiles.isEmpty else { return }
        model.discardAttachmentDrafts(
            for: stagedFiles.map(\.share)
        )
        stagedFiles = []
    }

    private var photoDraftAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.2)
    }

    private func dayHeader(for date: Date) -> some View {
        Text(dayTitle(for: date))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.thinMaterial, in: .capsule)
            .padding(.vertical, 10)
    }

    private func messageRow(
        for message: ChatMessage,
        photoGroup: PhotoMessageGroup?,
        groupedWithPrevious: Bool,
        groupedWithNext: Bool,
        latestOutgoingMessageID: UUID?,
        replyMessage: ChatMessage?
    ) -> some View {
        let pendingShareStatus = photoGroup.map {
            aggregatedPendingShareStatus(for: $0)
        } ?? model.pendingShareTimelineStatus(for: message.id)
        return MessageRow(
            message: message,
            photoGroup: photoGroup,
            isCurrentUser: message.senderID == model.currentUser.id,
            currentUserID: model.currentUser.id,
            showsDeliveryStatus:
                pendingShareStatus != nil
                || OutgoingDeliveryStatusVisibility.shouldShowStatus(
                    for: message,
                    currentUserID: model.currentUser.id,
                    latestApplicableMessageID: latestOutgoingMessageID
                ),
            isLatestOutgoing: message.id == latestOutgoingMessageID,
            pendingShareStatus: pendingShareStatus,
            groupedWithPrevious: groupedWithPrevious,
            groupedWithNext: groupedWithNext,
            replyMessage: replyMessage,
            timestampReveal: .interactive(timestampRevealState),
            interactionOffsetY:
                interactionMessageID == message.id
                    ? interactionMessageOffsetY
                    : 0,
            allowsInteractions: pendingShareStatus == nil,
            onShowReply: {
                guard let replyID = message.replyToID else {
                    return
                }
                isShowingReplyHistory = true
                model.finishMessageHistorySearch(restoringWindow: false)
                searchText = ""
                isSearchPresented = false
                requestViewport(.message(replyID))
                if currentTimelinePresentation.scrollTargetsByMessageID[replyID] == nil {
                    model.showMessageInHistory(replyID)
                }
            },
            onPresentInteractions: {
                presentMessageInteractions(for: message)
            },
            onReply: {
                model.beginReply(to: message)
            },
            onReact: { emoji in
                Task {
                    await model.toggleReaction(emoji, on: message)
                }
            },
            onEdit: {
                messageBeingEdited = message
                editedText = message.body
                showingEditAlert = true
            },
            onUnsend: {
                messageBeingUnsent = message
            },
            onRetry: {
                Task {
                    if photoGroup == nil {
                        await model.retryMessage(message)
                    } else {
                        await model.retryPendingShares()
                    }
                }
            },
            onRemovePendingShare: {
                Task {
                    if let photoGroup {
                        await model.discardPendingShares(
                            Set(photoGroup.messages.map(\.id))
                        )
                    } else {
                        await model.discardPendingShare(message.id)
                    }
                }
            },
            isPinned: model.messagePins?.isPinned(photoGroup?.id ?? message.id) == true
        )
    }

    @ViewBuilder
    private func focusedInteractionPresentation(
        for message: ChatMessage,
        timeline: ConversationTimelinePresentation
    ) -> some View {
        if
            let targetID = timeline.scrollTargetsByMessageID[message.id],
            let index = timeline.rowIndexesByID[targetID]
        {
            let row = timeline.rows[index]
            let photoGroup = row.item.photoGroup
            let pendingShareStatus = photoGroup.map {
                aggregatedPendingShareStatus(for: $0)
            } ?? model.pendingShareTimelineStatus(for: message.id)

            MessageRow(
                message: message,
                photoGroup: photoGroup,
                isCurrentUser:
                    message.senderID == model.currentUser.id,
                currentUserID: model.currentUser.id,
                showsDeliveryStatus:
                    pendingShareStatus != nil
                    || OutgoingDeliveryStatusVisibility
                        .shouldShowStatus(
                            for: message,
                            currentUserID: model.currentUser.id,
                            latestApplicableMessageID:
                                timeline.latestOutgoingMessageID
                        ),
                isLatestOutgoing:
                    message.id == timeline.latestOutgoingMessageID,
                pendingShareStatus: pendingShareStatus,
                groupedWithPrevious: row.grouping.joinsPrevious,
                groupedWithNext: row.grouping.joinsNext,
                replyMessage: message.replyToID.flatMap { replyID in
                    timeline.messagesByID[replyID]
                },
                timestampReveal: .fixed(0),
                interactionOffsetY: 0,
                allowsInteractions: false,
                onShowReply: {},
                onPresentInteractions: {},
                onReply: {},
                onReact: { _ in },
                onEdit: {},
                onUnsend: {},
                onRetry: {},
                onRemovePendingShare: {},
                isInteractionPreview: true,
                isPinned: model.messagePins?.isPinned(photoGroup?.id ?? message.id) == true
            )
        }
    }

    private func prepareLatestConversationPosition() {
        isShowingReplyHistory = false
        requestViewport(.latest)
    }

    private var timestampRevealGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                let axis = MessageTimestampReveal.lockedAxis(
                    current: timestampRevealState.dragAxis,
                    translation: value.translation
                )
                if axis != timestampRevealState.dragAxis {
                    timestampRevealState.dragAxis = axis
                }

                let offset = MessageTimestampReveal.offset(
                    translationWidth: value.translation.width,
                    axis: axis
                )
                guard offset != timestampRevealState.offset else { return }

                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    timestampRevealState.offset = offset
                }
            }
            .onEnded { _ in
                timestampRevealState.dragAxis = .undetermined
                guard timestampRevealState.offset != 0 else { return }

                if reduceMotion {
                    timestampRevealState.offset = 0
                } else {
                    withAnimation(
                        .snappy(duration: 0.24, extraBounce: 0)
                    ) {
                        timestampRevealState.offset = 0
                    }
                }
            }
    }

    private func aggregatedPendingShareStatus(
        for group: PhotoMessageGroup
    ) -> PendingShareTimelineStatus? {
        let statuses = group.messages.compactMap {
            model.pendingShareTimelineStatus(for: $0.id)
        }
        if
            let failure = statuses.first(where: {
                if case .failed = $0 { return true }
                return false
            })
        {
            return failure
        }
        if statuses.contains(.sending) {
            return .sending
        }
        return statuses.isEmpty ? nil : .waiting
    }

    private func presentMessageInteractions(for message: ChatMessage) {
        guard
            MessageInteractionPolicy.canPresent(
                message: message,
                allowsInteractions: true
            )
        else {
            return
        }

        guard messageFrames.frame(for: message.id) != nil else { return }
        interactionSourceFrame = nil
        interactionMessageOffsetY = 0
        isSearchFieldFocused = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        if reduceMotion {
            interactionMessageID = message.id
        } else {
            withAnimation(.easeOut(duration: 0.16)) {
                interactionMessageID = message.id
            }
        }
    }

    private func dismissMessageInteractions() {
        guard interactionMessageID != nil else { return }
        if reduceMotion {
            interactionMessageOffsetY = 0
            interactionSourceFrame = nil
            interactionMessageID = nil
        } else {
            withAnimation(.easeOut(duration: 0.12)) {
                interactionMessageOffsetY = 0
                interactionSourceFrame = nil
                interactionMessageID = nil
            }
        }
    }

    private func performMessageAction(
        _ action: MessageInteractionAction,
        for message: ChatMessage
    ) {
        dismissMessageInteractions()

        switch action {
        case .reply:
            model.beginReply(to: message)
        case .copy:
            UIPasteboard.general.string = message.body
        case .copyLink:
            if let selection = MessageInteractionPolicy.previewSelection(for: message) {
                selection.copyToPasteboard()
            }
        case .edit:
            messageBeingEdited = message
            editedText = message.body
            showingEditAlert = true
        case .retry:
            Task {
                await model.retryMessage(message)
            }
        case .pin, .unpin:
            guard let target = pinTarget(for: message) else { return }
            let pins = model.messagePins
            Task { await pins?.setPinned(action == .pin, message: target) }
        case .unsend:
            messageBeingUnsent = message
        }
    }

    private func pinTarget(for message: ChatMessage) -> ChatMessage? {
        let timeline = currentTimelinePresentation
        let group = timeline.scrollTargetsByMessageID[message.id]
            .flatMap { timeline.rowIndexesByID[$0] }
            .flatMap { timeline.rows[$0].item.photoGroup }
        return MessagePinningInteractionPolicy.target(message: message, photoGroup: group)
    }

    private func showPinnedMessageInHistory(_ id: UUID) {
        isShowingReplyHistory = true
        model.finishMessageHistorySearch(restoringWindow: false)
        searchText = ""
        isSearchPresented = false
        requestViewport(.message(id))
        if currentTimelinePresentation.scrollTargetsByMessageID[id] == nil { model.showMessageInHistory(id) }
    }

    private func dayTitle(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private var conversationHeader: some View {
        ZStack(alignment: .topTrailing) {
            if isSearchPresented {
                messageSearchField
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            } else {
                partnerIdentity
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 76)

            }
        }
        .padding(.top, 4)
        .padding(.bottom, 10)
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { headerSafeAreaTop = $0 }
        .accessibilityHidden(interactionMessageID != nil)
    }

    private var partnerDisplayName: String {
        partnerPhotos.nickname(accountID: model.currentUser.id, partnerID: model.partner.id)
            ?? model.partner.displayName
    }

    private var partnerIdentity: some View {
        let identity = model.conversationPartnerIdentity
        let photo = identity.flatMap {
            partnerPhotos.image(accountID: model.currentUser.id, partnerID: $0.id)
        }
        return VStack(spacing: 3) {
            Button {
                isPresentingPartnerProfile = true
            } label: {
                ZStack(alignment: .bottom) {
                    ConversationPhotoOrnament(size: 80, warpsPhoto: photo != nil) {
                        PartnerPhotoAvatar(photo: photo, initials: identity?.initials, size: 80)
                    }
                    .accessibilityIdentifier("partner-header-photo")

                    if let identity {
                        Text(partnerPhotos.nickname(accountID: model.currentUser.id, partnerID: identity.id) ?? identity.displayName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .modifier(ConversationNameGlass())
                            .offset(y: 17)
                            .accessibilityIdentifier("partner-header-name")
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Loading profile")
                            .accessibilityIdentifier("partner-identity-loading")
                    }
                }
                // Dynamic Island phones lift the ornament toward the spruce; shorter
                // status bars keep the hanger clear of the centered clock.
                .padding(.top, headerSafeAreaTop >= 54 ? 2 : 12)
                .padding(.bottom, 17)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(identity == nil)
            .accessibilityLabel(identity.map { _ in "View \(partnerDisplayName)'s profile" } ?? "Loading profile")
            .accessibilityIdentifier("partner-profile-button")

            TimelineView(.periodic(from: .now, by: 30)) { context in
                if let presentation = model.mutualLocationPresentation(at: context.date) {
                    Button {
                        isPresentingLocationMap = true
                    } label: {
                        Text(presentation.subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(presentation.subtitle). Show both locations.")
                    .accessibilityIdentifier("mutual-location-subtitle")
                }
            }
        }
        .matchedTransitionSource(id: "mutual-location-map", in: locationTransition)
    }

    @ViewBuilder
    private var messageSearchField: some View {
        if #available(iOS 26.0, *) {
            messageSearchFieldContent
                .glassEffect(.regular.interactive(), in: .capsule)
        } else {
            messageSearchFieldContent
                .background(.thinMaterial, in: Capsule())
        }
    }

    private var messageSearchFieldContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search messages", text: $searchText)
                .focused($isSearchFieldFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityIdentifier("message-search-field")
                .task { isSearchFieldFocused = true }

            Button {
                withAnimation(.snappy(duration: 0.25)) {
                    isSearchPresented = false
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Close search")
            .accessibilityIdentifier("close-message-search")
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private func searchHeader(resultCount: Int) -> some View {
        Text("\(resultCount) \(resultCount == 1 ? "result" : "results")")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
            .accessibilityIdentifier("search-result-count")
    }
}

enum OutgoingDeliveryStatusVisibility {
    static func latestApplicableMessageID(
        in messages: [ChatMessage],
        currentUserID: String
    ) -> UUID? {
        messages.last {
            $0.senderID == currentUserID && !$0.isUnsent
        }?.id
    }

    static func shouldShowStatus(
        for message: ChatMessage,
        currentUserID: String,
        latestApplicableMessageID: UUID?
    ) -> Bool {
        guard message.senderID == currentUserID else { return false }
        return message.deliveryState == .failed
            || message.id == latestApplicableMessageID
    }
}

private struct ConversationTimelineRevision: Hashable {
    let messages: Int
    let search: Int
    let query: String
    let loading: Bool
    let hasOlder: Bool
    let hasNewer: Bool
    let recent: Bool
    let browsing: Bool
    let typing: Bool
    let interaction: UUID?
    let interactionOffset: CGFloat
    let pendingShares: [UUID: PendingShareTimelineStatus]
    let colorScheme: Bool
    let contentSize: DynamicTypeSize
}

struct SendingSharedItemBanner: View {
    let isSending: Bool
    let hasError: Bool
    let retry: () -> Void
    let remove: () -> Void
    let errorDetails: () -> String?

    var body: some View {
        HStack(spacing: 8) {
            if isSending {
                ProgressView()
                    .controlSize(.small)
            } else if hasError {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
            } else {
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(statusText)
                    .font(.caption.weight(.semibold))
                if let detail = errorDetails(), hasError {
                    Text(detail)
                        .font(.caption2)
                        .lineLimit(2)
                }
            }
            .foregroundStyle(.secondary)
            Spacer()
            if !isSending {
                Button("Retry", action: retry)
                    .font(.caption.weight(.semibold))
                if hasError {
                    Button("Remove", role: .destructive, action: remove)
                        .font(.caption.weight(.semibold))
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .background(.thinMaterial)
        .accessibilityIdentifier("pending-share-banner")
    }

    private var statusText: String {
        if isSending {
            return "Sending shared item…"
        }
        if hasError {
            return "Shared item couldn’t send"
        }
        return "Shared item waiting to send"
    }
}

struct StagedPhotoDraft: Identifiable {
    let share: PendingShare
    let thumbnail: UIImage

    var id: UUID {
        share.id
    }

}

struct StagedPhotoTray: View {
    @State private var previewPhoto: StagedPhotoDraft?
    private static let preparationID = "staged-photo-preparation"

    let photos: [StagedPhotoDraft]
    var previewChanged: ((Bool) -> Void)? = nil
    let isPreparing: Bool
    let remove: (UUID) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 10) {
                    ForEach(
                        Array(photos.enumerated()),
                        id: \.element.id
                    ) { index, photo in
                        ZStack(alignment: .topTrailing) {
                            if let previewChanged {
                                Button {
                                    previewChanged(true)
                                    previewPhoto = photo
                                } label: {
                                    thumbnail(photo)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Preview photo \(index + 1)")
                                .accessibilityHint("Opens a larger photo. Pinch to zoom.")
                            } else {
                                thumbnail(photo).accessibilityHidden(true)
                            }

                            Button {
                                remove(photo.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.white)
                                    .frame(width: 24, height: 24)
                                    .background(
                                        .black.opacity(0.68),
                                        in: .circle
                                    )
                            }
                            .offset(x: 7, y: -7)
                            .accessibilityLabel(
                                "Remove photo \(index + 1)"
                            )
                            .accessibilityIdentifier(
                                "remove-staged-photo-\(index)"
                            )
                        }
                        .transition(
                            .scale(scale: 0.92).combined(with: .opacity)
                        )
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("staged-photo-preview-\(index)")
                    }

                    if isPreparing {
                        ZStack {
                            RoundedRectangle(cornerRadius: 14)
                                .fill(.secondary.opacity(0.1))

                            ProgressView()
                                .controlSize(.small)
                        }
                        .frame(width: 76, height: 76)
                        .transition(.opacity)
                        .id(Self.preparationID)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Preparing selected photos")
                        .accessibilityIdentifier(Self.preparationID)
                    }
                }
                .padding(.top, 7)
                .padding(.trailing, 7)
            }
            .scrollIndicators(.hidden)
            .onChange(of: isPreparing, initial: true) {
                scrollToPreparationIfNeeded(proxy)
            }
            .onChange(of: photos.count) {
                scrollToPreparationIfNeeded(proxy)
            }
        }
        .frame(height: 90)
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("staged-photo-tray")
        .fullScreenCover(item: $previewPhoto, onDismiss: { previewChanged?(false) }) { photo in
            StagedPhotoPreview(photo: photo) { previewPhoto = nil }
        }
        .onChange(of: photos.map(\.id)) {
            if let previewPhoto, !photos.contains(where: { $0.id == previewPhoto.id }) {
                self.previewPhoto = nil
            }
        }
    }

    private func thumbnail(_ photo: StagedPhotoDraft) -> some View {
        Image(uiImage: photo.thumbnail)
            .resizable()
            .scaledToFill()
            .frame(width: 76, height: 76)
            .clipShape(.rect(cornerRadius: 14))
    }

    private func scrollToPreparationIfNeeded(_ proxy: ScrollViewProxy) {
        guard isPreparing else { return }
        Task { @MainActor in
            await Task.yield()
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(Self.preparationID, anchor: .trailing)
            }
        }
    }
}

struct StagedFileDraft: Identifiable {
    let share: PendingShare

    var id: UUID { share.id }

    var displayName: String {
        share.originalFileName ?? "File"
    }
}

private struct StagedFileTray: View {
    let files: [StagedFileDraft]
    let remove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 8) {
                ForEach(files) { file in
                    HStack(spacing: 8) {
                        Image(systemName: "doc")
                            .foregroundStyle(.secondary)
                        Text(file.displayName)
                            .font(.caption)
                            .lineLimit(1)
                        Button {
                            remove(file.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(
                            "Remove \(file.displayName)"
                        )
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 36)
                    .background(.quaternary, in: .capsule)
                    .accessibilityElement(children: .contain)
                }
            }
            .padding(.horizontal, 12)
        }
        .scrollIndicators(.hidden)
        .frame(height: 44)
        .accessibilityIdentifier("staged-file-tray")
    }
}

private struct ComposerPanelSurface: ViewModifier {
    let reduceTransparency: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        let panel = RoundedRectangle(cornerRadius: 22, style: .continuous)
        if reduceTransparency {
            content.background(Color(uiColor: .secondarySystemBackground), in: panel)
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: panel)
        } else {
            content
                .background(.regularMaterial, in: panel)
                .overlay { panel.strokeBorder(.primary.opacity(0.12)).allowsHitTesting(false) }
        }
    }
}

// Always lay out the same UITextView so crossing the wrap threshold preserves
// the selection, marked text, keyboard, and any ongoing paste operation.
private struct ComposerInputLayout: Layout {
    let controlSize: CGFloat
    let singleLineHeight: CGFloat

    private func fieldSize(width: CGFloat, subviews: Subviews) -> (CGSize, expanded: Bool) {
        let compactWidth = max(1, width - 2 * controlSize)
        let compact = subviews[1].sizeThatFits(.init(width: compactWidth, height: nil))
        if compact.height <= singleLineHeight + 1 {
            return (CGSize(width: compactWidth, height: compact.height), false)
        }
        let expandedWidth = max(1, width - 24)
        let expanded = subviews[1].sizeThatFits(.init(width: expandedWidth, height: nil))
        return (CGSize(width: expandedWidth, height: expanded.height), true)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 320
        let (field, expanded) = fieldSize(width: width, subviews: subviews)
        return CGSize(width: width, height: expanded ? field.height + controlSize : max(field.height, controlSize))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (field, expanded) = fieldSize(width: bounds.width, subviews: subviews)
        let controlsY = expanded ? bounds.maxY - controlSize : bounds.midY - controlSize / 2
        let control = ProposedViewSize(width: controlSize, height: controlSize)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: controlsY), anchor: .topLeading, proposal: control)
        subviews[1].place(
            at: CGPoint(x: bounds.minX + (expanded ? 12 : controlSize),
                        y: expanded ? bounds.minY : bounds.midY - field.height / 2),
            anchor: .topLeading, proposal: .init(field)
        )
        subviews[2].place(at: CGPoint(x: bounds.maxX - controlSize, y: controlsY), anchor: .topLeading, proposal: control)
    }
}

struct MessageComposer: View {

    @Environment(\.usesGiftWrap) private var usesGiftWrap
    @Environment(\.colorScheme) private var colorScheme
    private static let controlSize: CGFloat = 44

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ScaledMetric(relativeTo: .body) private var bodyLineHeight: CGFloat = 21

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var text: String
    let replyingTo: ChatMessage?
    let currentUserID: String
    let stagedPhotos: [StagedPhotoDraft]
    let stagedFiles: [StagedFileDraft]
    var usesRecentPhotoSheet = false
    var stagedPhotoPreviewChanged: ((Bool) -> Void)? = nil
    let isPreparingPhotos: Bool
    let canAddPhoto: Bool
    let allowsVoiceMessages: Bool
    let addPhoto: () -> Void
    let addFile: () -> Void
    let removePhoto: (UUID) -> Void
    let removeFile: (UUID) -> Void
    let pastePhotos: ([PastedPhoto]) -> Void
    let cancelReply: () -> Void
    let textChanged: () -> Void
    let voiceMessageStaged: (StagedVoiceMessage) -> Void
    let voiceMessageError: (String) -> Void
    var voiceMessageRecorder: VoiceMessageRecorder? = nil
    var stageVoiceMessage:
        ((VoiceMessageDraft) throws -> StagedVoiceMessage)? = nil
    var makeVoiceMessageStagingOperation:
        (() -> (VoiceMessageDraft) throws -> StagedVoiceMessage)? = nil
    let allowsQuietDelivery: Bool
    let send: (String, UUID?, MessageDeliveryMode) -> Bool
    @StateObject private var defaultVoiceRecorder = VoiceMessageRecorder()
    @State private var pinnedVoiceStagingOperation:
        ((VoiceMessageDraft) throws -> StagedVoiceMessage)?
    @State private var sendFeedbackTrigger = 0
    @State private var isTextFieldFocused = false
    @State private var keepVoiceKeyboard = false

    var body: some View {
        ObservedVoiceMessageRecorderContent(recorder: voiceRecorder) {
            recorder in
            composerContent(recorder: recorder)
        }
    }

    private var accent: Color {
        usesGiftWrap ? GiftWrapAppearance.accent(colorScheme == .dark) : .indigo
    }

    private func composerContent(
        recorder: VoiceMessageRecorder
    ) -> some View {
        VStack(spacing: 0) {
            if !stagedPhotos.isEmpty || isPreparingPhotos {
                StagedPhotoTray(
                    photos: stagedPhotos,
                    previewChanged: stagedPhotoPreviewChanged,
                    isPreparing: isPreparingPhotos,
                    remove: removePhoto
                )
                .transition(
                    reduceMotion
                        ? .opacity
                        : .move(edge: .bottom).combined(with: .opacity)
                )
            }

            if !stagedFiles.isEmpty {
                StagedFileTray(files: stagedFiles, remove: removeFile)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .bottom).combined(with: .opacity)
                    )
            }

            if let replyingTo {
                HStack(spacing: 8) {
                    Capsule()
                        .fill(accent)
                        .frame(width: 3, height: 34)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(
                            replyingTo.senderID == currentUserID
                                ? "Replying to yourself"
                                : "Replying"
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(accent)
                        Text(replyingTo.replyPreviewText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Button(action: cancelReply) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Cancel reply")
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .move(edge: .bottom).combined(with: .opacity)
                )
                .accessibilityIdentifier("reply-composer")
            }

            ZStack {
                // The native editor remains attached and visible to UIKit while
                // recording. Hiding its ancestor can dismiss its input window.
                standardComposerRow(recorder: recorder)

                if voiceComposerIsActive(recorder) {
                    VoiceMessageComposerControl(
                        recorder: recorder,
                        controlSize: Self.controlSize,
                        stageDraft: pinnedVoiceStagingOperation ?? stageVoiceMessage,
                        onError: voiceMessageError,
                        onStaged: voiceMessageStaged
                    )
                    .transition(reduceMotion ? .identity : .opacity)
                }
            }
        }
        .modifier(ComposerPanelSurface(reduceTransparency: reduceTransparency))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .alert(
            "Microphone access is off",
            isPresented: permissionDeniedBinding(recorder: recorder)
        ) {
            Button("Not now", role: .cancel) {
                recorder.cancel()
            }
            Button("Open Settings") {
                recorder.cancel()
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        } message: {
            Text(
                "Allow microphone access in Settings to record a voice message."
            )
        }
        .onChange(of: recorder.state) { _, state in
            if case let .failed(message) = state {
                voiceMessageError(message)
            }
        }
        .onDisappear {
            recorder.shutdown()
        }
        .accessibilityElement(children: .contain)
        .animation(
            reduceMotion ? nil : .snappy(duration: 0.2),
            value: showsSendControl
        )
        .animation(
            reduceMotion ? nil : .snappy(duration: 0.22),
            value: replyingTo?.id
        )
        .animation(
            reduceMotion ? nil : .snappy(duration: 0.2),
            value: voiceComposerIsActive(recorder)
        )
        .accessibilityIdentifier("message-composer")
    }

    private func standardComposerRow(
        recorder: VoiceMessageRecorder
    ) -> some View {
        let voicePanelVisible = voiceComposerIsActive(recorder)
        return ComposerInputLayout(controlSize: Self.controlSize, singleLineHeight: max(40, ceil(bodyLineHeight + 17))) {
            attachmentMenu
                .opacity(voicePanelVisible ? 0 : 1)
                .allowsHitTesting(!voicePanelVisible)
                .accessibilityHidden(voicePanelVisible)

            PasteableMessageField(
                text: $text,
                isFocused: Binding(
                    get: { isTextFieldFocused || (keepVoiceKeyboard && voiceComposerIsActive(recorder)) },
                    set: { isTextFieldFocused = $0 }
                ),
                isEnabled: true,
                isShowingVoicePanel: voicePanelVisible,
                textChanged: textChanged,
                pastePhotos: pastePhotos
            )
            .overlay(alignment: .topLeading) {
                if text.isEmpty && !voicePanelVisible {
                    Text("Message")
                        .foregroundStyle(.secondary)
                        .padding(.top, 9)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityHidden(voicePanelVisible)

            ZStack {
                trailingControl(recorder: recorder)
            }
            .frame(width: Self.controlSize, height: Self.controlSize)
            .opacity(voicePanelVisible ? 0 : 1)
            .allowsHitTesting(!voicePanelVisible)
            .accessibilityHidden(voicePanelVisible)
        }
    }

    @ViewBuilder
    private var attachmentMenu: some View {
        Group {
            if usesRecentPhotoSheet {
                Button(action: addPhoto) { attachmentButtonLabel }
                    .buttonStyle(.plain)
                    .disabled(!canAddPhoto || isPreparingPhotos)
            } else {
                Menu {
                    Button(action: addPhoto) {
                        Label("Photo", systemImage: "photo.on.rectangle.angled")
                    }
                    .disabled(!canAddPhoto || isPreparingPhotos)
                    Button(action: addFile) {
                        Label("File", systemImage: "folder")
                    }
                } label: { attachmentButtonLabel }
                .menuOrder(.fixed)
            }
        }
        .accessibilityLabel("Add attachment")
        .accessibilityIdentifier("add-attachment")
    }

    private var attachmentButtonLabel: some View {
        Image(systemName: "plus")
            .font(.title3.weight(.medium))
            .foregroundStyle(usesRecentPhotoSheet ? accent : .primary)
            .frame(width: Self.controlSize, height: Self.controlSize)
            .contentShape(.rect)
    }

    private var showsSendControl: Bool {
        !text.isEmpty || !stagedPhotos.isEmpty || !stagedFiles.isEmpty || isPreparingPhotos
    }

    private var reducedControlTransition: AnyTransition {
        reduceMotion ? .identity : .scale(scale: 0.84).combined(with: .opacity)
    }

    @ViewBuilder
    private func trailingControl(recorder: VoiceMessageRecorder) -> some View {
        if showsSendControl {
            Group {
                if allowsQuietDelivery {
                    Menu {
                        Button {
                            submit(deliveryMode: .quiet)
                        } label: {
                            Label(
                                "Send Quietly",
                                systemImage: "bell.slash"
                            )
                        }
                        .accessibilityIdentifier(
                            "send-message-quietly"
                        )
                        .accessibilityLabel(
                            quietSendAccessibilityLabel
                        )
                    } label: {
                        sendButtonLabel
                    } primaryAction: {
                        submit(deliveryMode: .normal)
                    }
                    .menuOrder(.fixed)
                    .accessibilityAction(
                        named: Text(quietSendAccessibilityLabel)
                    ) {
                        submit(deliveryMode: .quiet)
                    }
                } else {
                    Button {
                        submit(deliveryMode: .normal)
                    } label: {
                        sendButtonLabel
                    }
                }
            }
            .accessibilityLabel(sendAccessibilityLabel)
            .accessibilityIdentifier("send-message")
            .disabled(isPreparingPhotos || !hasSendableContent)
            .transition(reducedControlTransition)
            .sensoryFeedback(
                .impact(weight: .light),
                trigger: sendFeedbackTrigger
            )
        } else if allowsVoiceMessages {
            Button {
                keepVoiceKeyboard = isTextFieldFocused
                pinnedVoiceStagingOperation = makeVoiceMessageStagingOperation?() ?? stageVoiceMessage
                Task { await recorder.start() }
            } label: {
                Group {
                    if recorder.state == .requestingPermission {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "mic")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                }
                .frame(width: Self.controlSize, height: Self.controlSize)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(recorder.state == .requestingPermission)
            .accessibilityLabel("Record a voice message")
            .accessibilityIdentifier("record-voice-message")
            .transition(reducedControlTransition)
        }
    }

    private var sendButtonLabel: some View {
        Image(systemName: "arrow.up")
            .font(.body.bold())
            .foregroundStyle(usesGiftWrap && colorScheme == .dark ? Color.black : Color.white)
            .frame(width: 32, height: 32)
            .background(accent, in: .circle)
            .frame(width: Self.controlSize, height: Self.controlSize)
            .contentShape(.rect)
    }

    private func submit(deliveryMode: MessageDeliveryMode) {
        let submittedDraft = text
        let submittedReplyToID = replyingTo?.id
        if send(submittedDraft, submittedReplyToID, deliveryMode) {
            text = ""
            isTextFieldFocused = true
            sendFeedbackTrigger += 1
        }
    }

    private func voiceComposerIsActive(
        _ recorder: VoiceMessageRecorder
    ) -> Bool {
        allowsVoiceMessages
            && (recorder.state == .recording
                || recorder.state == .ready)
    }

    private var voiceRecorder: VoiceMessageRecorder {
        voiceMessageRecorder ?? defaultVoiceRecorder
    }

    private func permissionDeniedBinding(
        recorder: VoiceMessageRecorder
    ) -> Binding<Bool> {
        Binding(
            get: { recorder.state == .permissionDenied },
            set: { isPresented in
                if !isPresented,
                    recorder.state == .permissionDenied
                {
                    recorder.cancel()
                }
            }
        )
    }

    private var hasSendableText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasSendableContent: Bool {
        hasSendableText || !stagedPhotos.isEmpty || !stagedFiles.isEmpty
    }

    private var sendAccessibilityLabel: String {
        ComposerSendAccessibilityLabel.text(
            photoCount: stagedPhotos.count,
            fileCount: stagedFiles.count,
            deliveryMode: .normal
        )
    }

    private var quietSendAccessibilityLabel: String {
        ComposerSendAccessibilityLabel.text(
            photoCount: stagedPhotos.count,
            fileCount: stagedFiles.count,
            deliveryMode: .quiet
        )
    }
}

private struct ObservedVoiceMessageRecorderContent<Content: View>: View {
    @ObservedObject private var recorder: VoiceMessageRecorder
    private let content: (VoiceMessageRecorder) -> Content

    init(
        recorder: VoiceMessageRecorder,
        @ViewBuilder content: @escaping (VoiceMessageRecorder) -> Content
    ) {
        self.recorder = recorder
        self.content = content
    }

    var body: some View {
        content(recorder)
    }
}

struct TypingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.usesGiftWrap) private var usesGiftWrap
    @Environment(\.colorScheme) private var colorScheme
    let partnerName: String

    var body: some View {
        Group {
            if reduceMotion {
                dots(at: nil)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) {
                    timeline in
                    dots(at: timeline.date)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            usesGiftWrap
                ? AnyShapeStyle(GiftWrapAppearance.incoming(colorScheme == .dark))
                : AnyShapeStyle(.quaternary),
            in: .capsule
        )
        .accessibilityLabel("\(partnerName) is typing")
        .accessibilityIdentifier("typing-indicator")
    }

    private func dots(at date: Date?) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                let phase = date.map {
                    $0.timeIntervalSinceReferenceDate * 4.5
                        - Double(index) * 0.75
                }
                let lift = phase.map { max(0, sin($0)) } ?? 0

                Circle()
                    .fill(
                        usesGiftWrap
                            ? AnyShapeStyle(GiftWrapAppearance.accent(colorScheme == .dark))
                            : AnyShapeStyle(.secondary)
                    )
                    .frame(width: 6, height: 6)
                    .scaleEffect(0.85 + lift * 0.2)
                    .offset(y: -lift * 2)
            }
        }
    }
}
