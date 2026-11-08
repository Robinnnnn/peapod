import AppKit
import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct MacConversationView: View {
    private static let bottomAnchorID = UUID()
    private static let composerControlSize: CGFloat = 32
    private static let headerPhotoSize: CGFloat = 68
    private static let headerOverlayHeight: CGFloat = headerPhotoSize + 45

    @Environment(MacAppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var searchText = ""
    @State private var activeReactionBurst: ReactionBurstEvent?
    @State private var scrollAdapter = MacConversationScrollAdapter()
    @State private var photoPrefetcher = ChatPhotoPrefetcher()
    @State private var photoPrefetchIsActive = false
    @State private var photoPrefetchVisibleIDs: [UUID] = []
    @State private var pickerPhotoTarget: SecureConversationResetTarget?
    @State private var pickerRecentPhotoTarget: SecureConversationResetTarget?
    @State private var pickerFileTarget: SecureConversationResetTarget?
    @State private var showingPhotoImporter = false
    @State private var showingRecentPhotoPicker = false
    @State private var showingFileImporter = false
    @State private var selectedRecentPhotoItems: [PhotosPickerItem] = []
    @State private var stagedPhotos: [MacStagedPhotoDraft] = []
    @State private var isPreviewingStagedPhoto = false
    @State private var stagedFiles: [MacStagedFileDraft] = []
    @State private var isPreparingPhotos = false
    @State private var recentPhotoPreparation: AttachmentPreparationLease?
    @State private var recentPhotoImportTask: Task<Void, Never>?
    @State private var editingMessage: ChatMessage?
    @State private var editingText = ""
    @State private var messageBeingUnsent: ChatMessage?
    @State private var showingPartnerDetails = false
    @State private var pendingProfileMessageID: UUID?
    @State private var timestampsRevealed = false
    private var voiceRecorder: MacVoiceRecorder { model.voiceRecorder }
    @State private var pinnedVoiceSend: ((VoiceMessageDraft) async -> Void)?
    @FocusState private var composerIsFocused: Bool

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            VStack(spacing: 0) {
                messageTimeline
                    .modifier(ConversationSnowfallPreview())
                    .clipped()

                composer
            }
            .modifier(ConversationHeaderBar(header: conversationHeader))
            .background { GiftWrapWallpaper(composition: .tiled) }
            .navigationTitle("")
            .searchable(
                text: $searchText,
                placement: .toolbar,
                prompt: "Search this conversation"
            )
            .onChange(of: searchText) {
                scrollAdapter.searchDidChange(searchText)
                model.searchMessageHistory(searchText)
            }
        }
        .overlay {
            if let activeReactionBurst {
                ReactionEmojiBurstView(event: activeReactionBurst) {
                    guard self.activeReactionBurst?.id == activeReactionBurst.id else { return }
                    self.activeReactionBurst = nil
                    model.reactionBurstDidFinish(activeReactionBurst.id)
                }
                .id(activeReactionBurst.id)
            }
        }
        .onChange(of: model.reactionBurstEvent) { _, event in
            if reduceMotion {
                activeReactionBurst = nil
                if let event { model.reactionBurstDidFinish(event.id) }
            } else {
                activeReactionBurst = event
            }
        }
        .onChange(of: reduceMotion) { _, reduced in
            guard reduced, let event = activeReactionBurst else { return }
            activeReactionBurst = nil
            model.reactionBurstDidFinish(event.id)
        }
        .environment(\.usesGiftWrap, true)
        .tint(GiftWrapAppearance.accent(colorScheme == .dark))
        .sheet(isPresented: $showingPartnerDetails, onDismiss: {
            guard let id = pendingProfileMessageID else { return }
            pendingProfileMessageID = nil
            showPinnedMessage(id)
        }) {
            MacPartnerDetailsView(person: model.partner) { id in
                pendingProfileMessageID = id
                showingPartnerDetails = false
            }
            .environment(model)
        }
        .fileImporter(
            isPresented: $showingPhotoImporter,
            allowedContentTypes: [.image, .movie],
            allowsMultipleSelection: true
        ) { [pickedTarget = pickerPhotoTarget] result in
            switch result {
            case let .success(urls):
                guard let pickedTarget, model.isCurrentAttachmentPreparation(pickedTarget) else { return }
                Task {
                    await handleDroppedFiles(urls, target: pickedTarget)
                }
            case let .failure(error):
                guard let pickedTarget, model.isCurrentAttachmentPreparation(pickedTarget) else { return }
                presentImporterError(error)
            }
        }
        .photosPicker(
            isPresented: $showingRecentPhotoPicker,
            selection: $selectedRecentPhotoItems,
            maxSelectionCount: max(1, remainingPhotoSlots),
            selectionBehavior: .ordered,
            matching: .images,
            preferredItemEncoding: .current
        )
        .onChange(of: selectedRecentPhotoItems) {
            guard !selectedRecentPhotoItems.isEmpty else { return }
            let items = selectedRecentPhotoItems
            selectedRecentPhotoItems = []
            let target = pickerRecentPhotoTarget
            pickerRecentPhotoTarget = nil
            guard let target, model.isCurrentAttachmentPreparation(target),
                  !isPreparingPhotos, remainingPhotoSlots > 0 else { return }
            let lease = AttachmentPreparationLease { model.isCurrentAttachmentPreparation(target) }
            recentPhotoPreparation = lease
            isPreparingPhotos = true
            recentPhotoImportTask = Task {
                await prepareRecentPhotos(items, target: target, lease: lease)
            }
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { [pickedTarget = pickerFileTarget] result in
            switch result {
            case let .success(urls):
                guard let pickedTarget, model.isCurrentAttachmentPreparation(pickedTarget) else { return }
                prepareFiles(urls)
            case let .failure(error):
                guard let pickedTarget, model.isCurrentAttachmentPreparation(pickedTarget) else { return }
                presentImporterError(error)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let target = model.attachmentPreparationTarget else { return false }
            Task {
                await handleDroppedFiles(urls, target: target)
            }
            return !urls.isEmpty
        }
        .onPasteCommand(of: [.image, .fileURL]) { _ in
            guard let target = model.attachmentPreparationTarget else { return }
            Task {
                await preparePasteboardAttachments(target: target)
            }
        }
        .sheet(item: $editingMessage) { message in
            MacEditMessageSheet(
                text: $editingText,
                save: {
                    let body = editingText
                    editingMessage = nil
                    Task {
                        await model.editMessage(message, body: body)
                    }
                },
                cancel: {
                    editingMessage = nil
                }
            )
        }
        .alert(
            "Unsend this message?",
            isPresented: Binding(
                get: { messageBeingUnsent != nil },
                set: { isPresented in
                    if !isPresented {
                        messageBeingUnsent = nil
                    }
                }
            )
        ) {
            Button("Cancel", role: .cancel) {
                messageBeingUnsent = nil
            }
            Button("Unsend", role: .destructive) {
                guard let message = messageBeingUnsent else { return }
                messageBeingUnsent = nil
                Task {
                    await model.unsendMessage(message)
                }
            }
        } message: {
            Text("This removes the message from both devices.")
        }
        .onChange(of: model.conversationDeletionTarget) { _, _ in
            photoPrefetcher.stop()
            photoPrefetchVisibleIDs = []
            pendingProfileMessageID = nil
            scrollAdapter = MacConversationScrollAdapter()
            searchText = ""
            pinnedVoiceSend = model.makeVoiceMessageSendOperation()
            pickerPhotoTarget = nil; pickerFileTarget = nil
            pickerRecentPhotoTarget = nil
            showingPhotoImporter = false; showingFileImporter = false
            showingRecentPhotoPicker = false
            selectedRecentPhotoItems = []
            recentPhotoPreparation?.invalidate(); recentPhotoImportTask?.cancel()
            recentPhotoPreparation = nil; recentPhotoImportTask = nil; isPreparingPhotos = false
            discardStagedPhotos(); discardStagedFiles()
        }
        .onChange(of: conversationObscurations, initial: true) { _, obscurations in
            model.conversationObscurationsDidChange(obscurations)
        }
        .environment(\.macConversationPreviewVisibility, MacConversationPreviewVisibilityAction { source, isPresented in
            model.conversationAttachmentPreviewDidChange(source, isPresented: isPresented)
        })
        .onAppear {
            photoPrefetchIsActive = true
            pinnedVoiceSend = model.makeVoiceMessageSendOperation()
            model.conversationVisibilityDidChange(
                isVisible: true,
                isAppActive: scenePhase == .active
            )
        }
        .onDisappear {
            photoPrefetchIsActive = false
            photoPrefetcher.stop()
            voiceRecorder.suspend()
            model.conversationVisibilityDidChange(
                isVisible: false,
                isAppActive: scenePhase == .active
            )
            model.conversationObscurationsDidChange([])
            // A draft preview temporarily covers chat; opening it never consumes the draft.
            guard !isPreviewingStagedPhoto || model.phase != .conversation else { return }
            recentPhotoPreparation?.invalidate(); recentPhotoImportTask?.cancel()
            recentPhotoPreparation = nil; recentPhotoImportTask = nil; isPreparingPhotos = false
            discardStagedPhotos()
            discardStagedFiles()
        }
    }

    private func showPinnedMessage(_ id: UUID) {
        scrollAdapter.searchDidChange("")
        searchText = ""
        let items = PhotoMessagePresentation.timelineItems(from: filteredMessages)
        scrollAdapter.requestReply(id)
        if model.usesBoundedHistory,
           MacConversationScrollAdapter.rowID(containing: id, rowMembers: timelineRowMembers(items)) == nil {
            model.showMessageInHistory(id)
        }
        updateScrollPosition(items: items)
    }

    private func pinAction(for message: ChatMessage?) -> (() -> Void)? {
        guard let message, let pins = model.messagePins else { return nil }
        return { Task { await pins.setPinned(!pins.isPinned(message.id), message: message) } }
    }

    private var conversationObscurations: Set<MacConversationObscuration> {
        var sources: Set<MacConversationObscuration> = []
        if showingPartnerDetails { sources.insert(.partnerDetails) }
        if editingMessage != nil { sources.insert(.messageEditor) }
        if showingPhotoImporter || showingFileImporter { sources.insert(.attachmentImporter) }
        if messageBeingUnsent != nil || model.errorMessage != nil { sources.insert(.confirmation) }
        return sources
    }

    // The identity belongs to the conversation artwork; window controls and
    // search retain their native toolbar placement.
    private var conversationHeader: some View {
        let identity = model.conversationPartnerIdentity
        let photo = identity.flatMap {
            model.partnerPhotoStore.image(accountID: model.currentUser.id, partnerID: $0.id)
        }
        let displayName = identity.map {
            model.partnerPhotoStore.nickname(accountID: model.currentUser.id, partnerID: $0.id) ?? $0.displayName
        }
        return Button {
            showingPartnerDetails = true
        } label: {
            ZStack(alignment: .bottom) {
                if let identity {
                    ConversationPhotoOrnament(size: Self.headerPhotoSize, warpsPhoto: photo != nil) {
                        MacAvatar(person: identity, size: Self.headerPhotoSize, image: photo)
                    }
                        .accessibilityIdentifier("partner-header-photo")
                    Text(displayName ?? identity.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 220)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .modifier(MacConversationGlassSurface(reduceTransparency: reduceTransparency,
                                                              cornerRadius: 20))
                        .offset(y: 15)
                        .accessibilityIdentifier("partner-header-name")
                } else {
                    ConversationPhotoOrnament(size: Self.headerPhotoSize, warpsPhoto: false) {
                        Image(systemName: "person.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(.white)
                            .frame(width: Self.headerPhotoSize, height: Self.headerPhotoSize)
                            .background(GiftWrapAppearance.pine, in: Circle())
                    }
                        .accessibilityIdentifier("partner-header-photo")
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Loading profile")
                        .accessibilityIdentifier("partner-identity-loading")
                        .offset(y: 15)
                }
            }
            .padding(.bottom, 15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(identity == nil)
        .help(displayName.map { "View \($0)’s details" } ?? "Loading profile")
        .accessibilityLabel(displayName.map { "View \($0)’s details" } ?? "Loading profile")
        .accessibilityIdentifier("partner-details-button")
        .padding(.top, 20)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
    }

    private var messageTimeline: some View {
        let visibleMessages = filteredMessages
        let timelineItems = PhotoMessagePresentation.timelineItems(
            from: visibleMessages
        )
        let timelineMessages = timelineItems.map(\.displayMessage)
        let latestOutgoingMessageID =
            MacConversationPresentation.latestOutgoingMessageID(
                in: timelineMessages,
                currentUserID: model.currentUser.id
            )

        @Bindable var adapter = scrollAdapter
        return ScrollView {
                LazyVStack(spacing: 0) {
                    if model.usesBoundedHistory {
                        if searchText.isEmpty {
                            HStack {
                                if model.historyHasOlder {
                                    Button("Earlier messages") {
                                        scrollAdapter.requestHistoryPage()
                                        model.loadOlderMessages()
                                    }
                                }
                                if model.historyHasNewer {
                                    Button("Newer messages") {
                                        scrollAdapter.requestHistoryPage()
                                        model.loadNewerMessages()
                                    }
                                }
                                if !model.historyIsRecent {
                                    Button("Latest messages") {
                                        scrollAdapter.requestLatest()
                                        model.returnToRecentMessageHistory()
                                        updateScrollPosition(items: timelineItems)
                                    }
                                }
                                if model.historyIsLoading { ProgressView().controlSize(.small) }
                            }.disabled(model.historyIsLoading).padding(.vertical, 10)
                        } else {
                            if model.historyController?.isSearching == true { ProgressView("Searching messages") }
                            if model.historyController?.search?.continuation != nil {
                                Button("More search results") { model.loadMoreSearchResults() }.padding(.vertical, 10)
                            }
                        }
                    }
                    if timelineItems.isEmpty {
                        ContentUnavailableView {
                            Label(
                                searchText.isEmpty
                                    ? "No messages yet"
                                    : "No matching messages",
                                systemImage: searchText.isEmpty
                                    ? "bubble.left"
                                    : "magnifyingglass"
                            )
                        } description: {
                            if searchText.isEmpty {
                                Text(
                                    "Send a message to start the conversation here."
                                )
                            }
                        }
                        .frame(minHeight: 360)
                    } else {
                        ForEach(
                            Array(timelineItems.enumerated()),
                            id: \.element.id
                        ) { index, item in
                            VStack(spacing: 0) {
                            let message = item.displayMessage
                            let pinMessage: ChatMessage? = item.photoGroup == nil ? message : item.photoGroup?.messages.first { $0.id == item.id }
                            if
                                MacConversationPresentation
                                    .shouldShowDayHeader(
                                        at: index,
                                        in: timelineMessages
                                    )
                            {
                                dayHeader(for: message.createdAt)
                            }

                            let position = MessageGrouping.position(
                                at: index,
                                in: timelineMessages
                            )
                            MacMessageRow(
                                message: message,
                                photoGroup: item.photoGroup,
                                replyMessage: replyMessage(for: message),
                                isCurrentUser:
                                    message.senderID == model.currentUser.id,
                                currentUserID: model.currentUser.id,
                                partnerName: model.partner.displayName,
                                grouping: position,
                                showsDeliveryStatus:
                                    MacConversationPresentation
                                        .showsDeliveryStatus(
                                            for: message,
                                            latestOutgoingMessageID:
                                                latestOutgoingMessageID,
                                            currentUserID:
                                                model.currentUser.id
                                        ),
                                isLatestOutgoing:
                                    message.id == latestOutgoingMessageID,
                                timestampsRevealed:
                                    timestampsRevealed,
                                groupTailHasPersistentMetadata:
                                    MacConversationPresentation
                                        .groupTailHasPersistentMetadata(
                                            at: index,
                                            in: timelineMessages,
                                            latestOutgoingMessageID:
                                                latestOutgoingMessageID,
                                            currentUserID:
                                                model.currentUser.id
                                        ),
                                showReply: {
                                    guard let replyID = message.replyToID else {
                                        return
                                    }
                                    scrollAdapter.searchDidChange("")
                                    searchText = ""
                                    scrollAdapter.requestReply(replyID)
                                    if model.usesBoundedHistory,
                                       MacConversationScrollAdapter.rowID(containing: replyID, rowMembers: timelineRowMembers(timelineItems)) == nil {
                                        model.showMessageInHistory(replyID)
                                    }
                                    updateScrollPosition(items: timelineItems)
                                },
                                toggleTimestamps:
                                    toggleTimestamps,
                                reply: {
                                    model.beginReply(to: message)
                                },
                                edit: {
                                    editingText = message.body
                                    editingMessage = message
                                },
                                unsend: {
                                    messageBeingUnsent = message
                                },
                                react: { emoji in
                                    Task {
                                        await model.toggleReaction(
                                            emoji,
                                            on: message
                                        )
                                    }
                                },
                                retry: {
                                    Task {
                                        if item.photoGroup == nil {
                                            await model.retryMessage(message)
                                        } else {
                                            await model.retryPendingShares(Set(item.photoGroup?.messages.map(\.id) ?? [message.id]))
                                        }
                                    }
                                },
                                pendingShareStatus: pendingShareStatus(for: item),
                                discardPending: pendingRemoval(for: item, wholeGroup: false),
                                discardPendingGroup: pendingRemoval(for: item, wholeGroup: true),
                                isPinned: model.messagePins?.isPinned(item.id) ?? false,
                                pinIsPending: model.messagePins?.pendingMessageIDs.contains(item.id) ?? false,
                                togglePin: pinAction(for: pinMessage)
                            )
                            .padding(
                                .top,
                                messageTopPadding(
                                    at: index,
                                    in: timelineMessages
                                )
                            )
                            }
                            .id(item.id)
                            .modifier(MacConversationTimelineEdge())
                        }

                        if model.isPartnerTyping, searchText.isEmpty {
                            HStack {
                                MacTypingIndicator(
                                    partnerName:
                                        model.partner.displayName
                                )
                                Spacer()
                            }
                            .padding(.top, 10)
                        }
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchorID)
                        .accessibilityHidden(true)
                }
                .scrollTargetLayout()
                .frame(maxWidth: 760)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
        }
            .contentMargins(.top, Self.headerOverlayHeight, for: .scrollContent)
            .coordinateSpace(name: "conversationTimelineViewport")
            .scrollPosition($adapter.rendererPosition)
            .onScrollTargetVisibilityChange(idType: UUID.self, threshold: 0.01) { ids in
                scrollAdapter.visibleRowsDidChange(ids)
                photoPrefetchVisibleIDs = ids
                updatePhotoPrefetch(items: timelineItems)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 36
            } action: { _, latest in
                scrollAdapter.geometryDidChange(isAtLatest: latest)
                model.historyViewportDidChange(isAtLatest: latest)
            }
            .onScrollPhaseChange { _, phase in
                scrollAdapter.userScrollDidChange(
                    isScrolling: phase == .tracking || phase == .interacting || phase == .decelerating
                )
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .alignment)
            .accessibilityIdentifier("conversation-message-list")
            .onChange(of: model.historyController?.searchRevision) {
                model.refreshSelectedReplyContext()
            }
            .onChange(of: timelineItems.map(\.id)) {
                updateScrollPosition(items: timelineItems)
            }
            .onChange(of: timelineItems) {
                updatePhotoPrefetch(items: timelineItems)
            }
            .onChange(of: model.historyIsRecent) {
                updateScrollPosition(items: timelineItems)
            }
            .onChange(of: searchText) {
                scrollAdapter.searchDidChange(searchText)
                updateScrollPosition(items: timelineItems)
            }
            .onAppear {
                photoPrefetchIsActive = true
                updateScrollPosition(items: timelineItems)
                updatePhotoPrefetch(items: timelineItems)
            }
            .onChange(of: (model.encryption?.resolver).map(ObjectIdentifier.init)) {
                updatePhotoPrefetch(items: timelineItems)
            }
            .onChange(of: model.composerSendRevision) {
                scrollAdapter.searchDidChange("")
                searchText = ""
                scrollAdapter.requestLatest()
                if !model.historyIsRecent { model.returnToRecentMessageHistory() }
                updateScrollPosition(items: timelineItems)
            }
    }

    private func updatePhotoPrefetch(items: [ConversationTimelineItem]) {
        guard photoPrefetchIsActive else { return }
        let visible = Set(photoPrefetchVisibleIDs)
        let indices = items.indices.filter { visible.contains(items[$0].id) }
        photoPrefetcher.update(
            ChatPhotoPrefetchHorizon.attachments(
                itemCount: items.count, visibleIndices: indices, itemAt: { items[$0] }
            ),
            resolver: model.encryption?.resolver
        )
    }

    private var composer: some View {
        @Bindable var model = model

        return VStack(spacing: 0) {
            if !stagedPhotos.isEmpty || isPreparingPhotos {
                MacStagedPhotoTray(
                    photos: stagedPhotos,
                    previewChanged: { isPreviewingStagedPhoto = $0 },
                    isPreparing: isPreparingPhotos,
                    remove: removeStagedPhoto
                )
                .transition(
                    reduceMotion
                        ? .opacity
                        : .move(edge: .bottom).combined(with: .opacity)
                )
            }

            if !stagedFiles.isEmpty {
                MacStagedFileTray(
                    files: stagedFiles,
                    remove: removeStagedFile
                )
                .transition(
                    reduceMotion
                        ? .opacity
                        : .move(edge: .bottom).combined(with: .opacity)
                )
            }

            if model.pendingExternalShare != nil {
                MacPendingShareBanner(
                    isSending: model.isSendingQueuedShares,
                    errorMessage: model.queuedShareErrorMessage,
                    retry: {
                        Task {
                            await model.retryPendingShares()
                        }
                    },
                    remove: {
                        Task {
                            await model.discardPendingShare()
                        }
                    }
                )

                Divider()
            }

            if let replyTarget = model.replyTarget {
                HStack(spacing: 10) {
                    Capsule()
                        .fill(GiftWrapAppearance.accent(colorScheme == .dark))
                        .frame(width: 3, height: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(
                            replyTarget.senderID == model.currentUser.id
                                ? "Replying to yourself"
                                : "Replying to \(model.partner.displayName)"
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(GiftWrapAppearance.accent(colorScheme == .dark))
                        Text(replyTarget.replyPreviewText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        model.cancelReply()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Cancel reply")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

                Divider()
            }

            standardComposer

            if voiceRecorder.state == .recording || voiceRecorder.state == .ready {
                MacVoiceComposer(
                    recorder: voiceRecorder,
                    isSending: model.isUploading
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }

            if case let .failed(message) = voiceRecorder.state {
                HStack {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                    Button("Dismiss") {
                        voiceRecorder.cancel()
                    }
                    .buttonStyle(.link)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            } else if voiceRecorder.state == .permissionDenied {
                HStack {
                    Text(
                        "Microphone access is off. Allow it in System Settings to record a voice message."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button("Dismiss") {
                        voiceRecorder.cancel()
                    }
                    .buttonStyle(.link)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }
        }
        .modifier(MacConversationGlassSurface(reduceTransparency: reduceTransparency,
                                              cornerRadius: 22))
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private var standardComposer: some View {
        @Bindable var model = model

        return MacComposerInputLayout(controlSize: Self.composerControlSize) {
            Menu {
                Button("Choose from Photos…", systemImage: "photo.on.rectangle.angled") {
                    guard let target = model.attachmentPreparationTarget,
                          model.isCurrentAttachmentPreparation(target) else { return }
                    pickerRecentPhotoTarget = target
                    showingRecentPhotoPicker = true
                }
                .disabled(remainingPhotoSlots == 0 || isPreparingPhotos)

                Button("Browse photos and videos…", systemImage: "folder") {
                    pickerPhotoTarget = model.attachmentPreparationTarget
                    showingPhotoImporter = true
                }
                .disabled(remainingPhotoSlots == 0 || isPreparingPhotos)

                Button("File", systemImage: "folder") {
                    pickerFileTarget = model.attachmentPreparationTarget
                    showingFileImporter = true
                }
            } label: {
                Image(systemName: "plus")
                    .font(.title3.weight(.semibold))
                    .frame(
                        width: Self.composerControlSize,
                        height: Self.composerControlSize
                    )
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .help("Add attachment")
            .accessibilityLabel("Add attachment")
            .disabled(model.isUploading || voicePanelIsActive)

            TextField("", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...7)
                .focused($composerIsFocused)
                .tint(Color.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .accessibilityLabel("Message")
                .onSubmit {
                    if voicePanelIsActive { sendVoiceMessage() }
                    else { send(deliveryMode: .normal) }
                }
                .onChange(of: model.draft) {
                    model.draftDidChange()
                }
                .background {
                    MacAttachmentPasteMonitor(
                        isActive: composerIsFocused
                    ) {
                        guard let target = model.attachmentPreparationTarget,
                              pasteboardContainsAttachment else {
                            return
                        }
                        Task {
                            await preparePasteboardAttachments(target: target)
                        }
                    }
                }

            composerTrailingControl
        }
        .padding(6)
    }

    private var voicePanelIsActive: Bool {
        voiceRecorder.state == .recording || voiceRecorder.state == .ready
            || voiceRecorder.state == .requestingPermission
    }

    @ViewBuilder
    private var composerTrailingControl: some View {
        if voicePanelIsActive {
            if model.isUploading || voiceRecorder.state == .requestingPermission {
                ProgressView().controlSize(.small)
                    .frame(width: Self.composerControlSize, height: Self.composerControlSize)
            } else {
                Button(action: sendVoiceMessage) { sendButtonLabel }
                    .buttonStyle(.plain)
                    .disabled(voiceRecorder.state == .recording
                              && voiceRecorder.elapsedTime < VoiceMessagePolicy.minimumDuration)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .accessibilityLabel("Send voice message")
                    .accessibilityIdentifier(voiceRecorder.state == .recording
                                             ? "send-recording" : "send-voice-message-preview")
                    .help("Send voice message (Command-Return)")
            }
        } else if model.isUploading {
            ProgressView()
                .controlSize(.small)
                .frame(
                    width: Self.composerControlSize,
                    height: Self.composerControlSize
                )
        } else if hasSendableContent {
            Menu {
                Button("Send") {
                    send(deliveryMode: .normal)
                }
                .keyboardShortcut(.return, modifiers: [.command])

                Button("Send Quietly", systemImage: "bell.slash") {
                    send(deliveryMode: .quiet)
                }
                .keyboardShortcut(
                    .return,
                    modifiers: [.option, .command]
                )
                .accessibilityIdentifier("send-message-quietly")
                .accessibilityLabel(quietSendAccessibilityLabel)
            } label: {
                sendButtonLabel
            } primaryAction: {
                send(deliveryMode: .normal)
            }
            .menuIndicator(.hidden)
            .menuOrder(.fixed)
            .buttonStyle(.plain)
            .accessibilityLabel(sendAccessibilityLabel)
            .accessibilityAction(
                named: Text(quietSendAccessibilityLabel)
            ) {
                send(deliveryMode: .quiet)
            }
            .help(
                "Send (Command-Return). Send quietly with Option-Command-Return."
            )
            .disabled(isPreparingPhotos)
        } else {
            Button {
                pinnedVoiceSend = model.makeVoiceMessageSendOperation()
                Task { await voiceRecorder.start() }
            } label: {
                Image(systemName: "mic.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: Self.composerControlSize, height: Self.composerControlSize)
            }
            .buttonStyle(.plain)
            .help("Record a voice message")
            .accessibilityLabel("Record a voice message")
        }
    }

    private var filteredMessages: [ChatMessage] {
        let query = searchText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !query.isEmpty else { return model.messages }
        if model.usesBoundedHistory { return model.historyController?.search?.messages ?? [] }
        return model.messages.filter { $0.matchesSearch(query) }
    }

    private var sendButtonLabel: some View {
        Image(systemName: "arrow.up")
            .font(.body.weight(.bold))
            .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
            .frame(
                width: Self.composerControlSize,
                height: Self.composerControlSize
            )
            .background(GiftWrapAppearance.accent(colorScheme == .dark), in: .circle)
    }

    private func dayHeader(for date: Date) -> some View {
        Text(MacConversationPresentation.dayTitle(for: date))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(GiftWrapAppearance.incoming(colorScheme == .dark), in: .capsule)
            .padding(.vertical, 10)
    }

    private func messageTopPadding(
        at index: Int,
        in messages: [ChatMessage]
    ) -> CGFloat {
        if
            MacConversationPresentation.shouldShowDayHeader(
                at: index,
                in: messages
            )
        {
            return 0
        }
        return MessageGrouping.position(
            at: index,
            in: messages
        ).joinsPrevious ? 3 : 13
    }

    private func toggleTimestamps() {
        if reduceMotion {
            timestampsRevealed.toggle()
        } else {
            withAnimation(.easeOut(duration: 0.16)) {
                timestampsRevealed.toggle()
            }
        }
    }

    private func pendingShareStatus(for item: ConversationTimelineItem) -> PendingShareTimelineStatus? {
        let ids = item.photoGroup?.messages.map(\.id) ?? [item.displayMessage.id]
        let statuses = ids.compactMap { model.pendingShareTimelineStatus(for: $0) }
        if let failed = statuses.first(where: { if case .failed = $0 { return true }; return false }) { return failed }
        if statuses.contains(.sending) { return .sending }
        return statuses.first
    }

    private func pendingRemoval(for item: ConversationTimelineItem, wholeGroup: Bool) -> (() -> Void)? {
        guard pendingShareStatus(for: item) != nil else { return nil }
        if wholeGroup {
            guard let group = item.photoGroup else { return nil }
            let ids = Set(group.messages.map(\.id))
            return { Task { await model.discardPendingShares(ids) } }
        }
        guard item.photoGroup == nil else { return nil }
        let id = item.displayMessage.id
        return { Task { await model.discardPendingShare(id) } }
    }

    private func timelineRowMembers(_ items: [ConversationTimelineItem]) -> [UUID: [UUID]] {
        Dictionary(uniqueKeysWithValues: items.map { item in
            (item.id, item.photoGroup?.messages.map(\.id) ?? [item.displayMessage.id])
        })
    }

    private func updateScrollPosition(items: [ConversationTimelineItem]) {
        scrollAdapter.update(rowMembers: timelineRowMembers(items), isRecent: model.historyIsRecent, rowOrder: items.map(\.id))
    }

    private var remainingPhotoSlots: Int {
        max(
            0,
            PhotoAttachmentDraftPolicy.maximumCount
                - stagedPhotos.count
                - stagedFiles.count
        )
    }

    private var trimmedDraft: String {
        model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasSendableContent: Bool {
        !trimmedDraft.isEmpty || !stagedPhotos.isEmpty || !stagedFiles.isEmpty
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

    private var photoDraftAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.2)
    }

    private var pasteboardContainsAttachment: Bool {
        NSPasteboard.general.types?.contains { type in
            type == .fileURL || UTType(type.rawValue)?.conforms(to: .image) == true
        } == true
    }

    private func presentImporterError(_ error: any Error) {
        let nsError = error as NSError
        guard nsError.code != NSUserCancelledError else { return }
        model.errorMessage = error.localizedDescription
    }

    @MainActor
    private func handleDroppedFiles(_ urls: [URL], target: SecureConversationResetTarget) async {
        guard model.isCurrentAttachmentPreparation(target) else { return }
        let photoURLs = urls.filter(isPhotoFile)
        let otherURLs = urls.filter { !isPhotoFile($0) }

        if !photoURLs.isEmpty {
            await preparePhotoFiles(photoURLs, capturedTarget: target)
        }
        if !otherURLs.isEmpty, model.isCurrentAttachmentPreparation(target) {
            prepareFiles(otherURLs)
        }
    }

    @MainActor
    private func preparePasteboardAttachments(target: SecureConversationResetTarget) async {
        guard model.isCurrentAttachmentPreparation(target) else { return }

        let pasteboard = NSPasteboard.general
        if
            let urls = pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL],
            !urls.isEmpty
        {
            await handleDroppedFiles(urls, target: target)
            return
        }

        guard remainingPhotoSlots > 0 else {
            model.errorMessage = PhotoAttachmentDraftError.tooMany(
                maximum: PhotoAttachmentDraftPolicy.maximumCount
            ).localizedDescription
            return
        }
        guard let photo = MacPasteboardPhotoReader.photo(from: pasteboard) else { return }
        do {
            try PendingShareAttachmentPolicy.validate(byteSize: Int64(photo.data.count),
                maximumBytes: PendingShareAttachmentPolicy.maximumSendingPhotoBytes)
            guard let thumbnail = await MacAttachmentImageCache.decodeImage(from: photo.data) else { return }
            guard !Task.isCancelled, model.isCurrentAttachmentPreparation(target), remainingPhotoSlots > 0 else { return }
            let share = try model.stageAttachmentData(
                photo.data,
                kind: .image,
                suggestedName: "Pasted Image." + (photo.contentType.preferredFilenameExtension ?? "image"),
                preferredExtension: photo.contentType.preferredFilenameExtension,
                contentTypeIdentifier: photo.contentType.identifier
            )
            withAnimation(photoDraftAnimation) {
                stagedPhotos.append(
                    MacStagedPhotoDraft(
                        share: share,
                        thumbnail: thumbnail
                    )
                )
            }
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func preparePhotoFiles(_ urls: [URL], capturedTarget: SecureConversationResetTarget? = nil) async {
        guard let target = capturedTarget ?? model.attachmentPreparationTarget,
              model.isCurrentAttachmentPreparation(target) else { return }
        guard !isPreparingPhotos else { return }
        isPreparingPhotos = true
        defer { isPreparingPhotos = false }

        let availableSlots = remainingPhotoSlots
        var failureMessage: String?
        if urls.count > availableSlots {
            failureMessage = PhotoAttachmentDraftError.tooMany(
                maximum: PhotoAttachmentDraftPolicy.maximumCount
            ).localizedDescription
        }

        for url in urls.prefix(availableSlots) {
            do {
                guard !Task.isCancelled, model.isCurrentAttachmentPreparation(target), remainingPhotoSlots > 0 else { return }
                let draft = try await stagedPhoto(from: url, target: target)
                withAnimation(photoDraftAnimation) {
                    stagedPhotos.append(draft)
                }
            } catch {
                guard !Task.isCancelled, model.isCurrentAttachmentPreparation(target) else { return }
                failureMessage = error.localizedDescription
            }
        }

        if let failureMessage {
            model.errorMessage = failureMessage
        }
    }

    @MainActor
    private func prepareRecentPhotos(_ items: [PhotosPickerItem], target: SecureConversationResetTarget,
                                     lease: AttachmentPreparationLease) async {
        defer {
            if recentPhotoPreparation === lease {
                recentPhotoPreparation = nil
                recentPhotoImportTask = nil
                isPreparingPhotos = false
            }
        }
        var failureMessage: String?
        for item in items.prefix(remainingPhotoSlots) {
            do {
                guard let transfer = try await lease.load({
                    try await item.loadTransferable(type: MacImportedPhotoTransfer.self)
                }) else {
                    failureMessage = "One of the photos couldn’t be prepared."
                    continue
                }
                let photo = try transfer.result.get()
                defer { photo.cleanUp() }
                guard let thumbnail = try await lease.load({
                    await MacAttachmentImageCache.decodeFile(photo.url, maximumPixelSize: 960)
                }) else {
                    failureMessage = "One of the photos couldn’t be prepared."
                    continue
                }
                let share = try lease.stage({
                    try model.stageAttachmentFile(from: photo.url, kind: .image,
                        suggestedName: photo.originalFileName,
                        contentTypeIdentifier: photo.contentTypeIdentifier)
                }, accepts: { share in
                    share.conversationOwnerID?.utf8.elementsEqual(target.accountID.utf8) == true
                        && share.targetConversationID?.utf8.elementsEqual(target.conversationID.utf8) == true
                }, discard: { model.discardAttachmentDrafts(for: [$0]) })
                // The lease and target remain current through admission; there is no suspension before append.
                withAnimation(photoDraftAnimation) {
                    stagedPhotos.append(MacStagedPhotoDraft(share: share, thumbnail: thumbnail))
                }
            } catch {
                guard lease.isCurrent, !Task.isCancelled, recentPhotoPreparation === lease else { return }
                failureMessage = error.localizedDescription
            }
        }
        if lease.isCurrent, !Task.isCancelled, recentPhotoPreparation === lease, let failureMessage {
            model.errorMessage = failureMessage
        }
    }

    private func stagedPhoto(from url: URL, target: SecureConversationResetTarget) async throws -> MacStagedPhotoDraft {
        let isAccessingSecurityScopedResource =
            url.startAccessingSecurityScopedResource()
        defer {
            if isAccessingSecurityScopedResource {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize else {
            throw PhotoAttachmentDraftError.unsupportedItem
        }
        try PendingShareAttachmentPolicy.validate(byteSize: Int64(size),
            maximumBytes: PendingShareAttachmentPolicy.maximumSendingPhotoBytes)
        let contentType =
            UTType(filenameExtension: url.pathExtension) ?? .image
        guard contentType.conforms(to: .image) else {
            throw PhotoAttachmentDraftError.unsupportedItem
        }
        let data = try await Task.detached(priority: .utility) {
            try Data(contentsOf: url, options: .mappedIfSafe)
        }.value
        guard let thumbnail = await MacAttachmentImageCache.decodeImage(from: data) else {
            throw PhotoAttachmentDraftError.unsupportedItem
        }

        guard !Task.isCancelled, model.isCurrentAttachmentPreparation(target), remainingPhotoSlots > 0 else {
            throw CancellationError()
        }
        let share = try model.stageAttachmentFile(
            from: url,
            kind: .image,
            suggestedName: url.lastPathComponent,
            contentTypeIdentifier: contentType.identifier
        )
        return MacStagedPhotoDraft(
            share: share,
            thumbnail: thumbnail
        )
    }

    private func isPhotoFile(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?
            .conforms(to: .image) == true
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
        stagedPhotos = []
    }

    private func prepareFiles(_ urls: [URL]) {
        let availableSlots = remainingPhotoSlots
        var failureMessage: String?
        for url in urls.prefix(availableSlots) {
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
                    stagedFiles.append(MacStagedFileDraft(share: share))
                }
            } catch {
                failureMessage = error.localizedDescription
            }
        }
        if urls.count > availableSlots {
            failureMessage = PhotoAttachmentDraftError.tooMany(
                maximum: PhotoAttachmentDraftPolicy.maximumCount
            ).localizedDescription
        }
        if let failureMessage {
            model.errorMessage = failureMessage
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

    private func replyMessage(for message: ChatMessage) -> ChatMessage? {
        guard let replyToID = message.replyToID else { return nil }
        return model.replyContextMessage(replyToID)
    }

    private func send(deliveryMode: MessageDeliveryMode) {
        guard hasSendableContent else { return }

        let photoShares = stagedPhotos.map(\.share)
        let fileShares = stagedFiles.map(\.share)
        do {
            if !photoShares.isEmpty || !fileShares.isEmpty {
                try model.enqueueComposerAttachments(
                    photoShares: photoShares,
                    fileShares: fileShares,
                    deliveryMode: deliveryMode
                )
                for photo in stagedPhotos where model.encryption == nil {
                    MacAttachmentImageCache.shared.insert(
                        photo.thumbnail,
                        forKey: photo.id.uuidString
                    )
                }
                withAnimation(photoDraftAnimation) {
                    stagedPhotos = []
                    stagedFiles = []
                }
            }
        } catch {
            model.errorMessage = error.localizedDescription
            return
        }

        let preparedMessage = model.prepareDraftForSend(
            deliveryMode: deliveryMode,
            precedingAttachmentIDs: Set((photoShares + fileShares).map(\.id))
        )
        Task {
            if let preparedMessage {
                await model.sendPreparedDraft(preparedMessage)
            }
            if !photoShares.isEmpty || !fileShares.isEmpty {
                await model.sendPendingComposerAttachments()
            }
        }
    }

    private func sendVoiceMessage() {
        guard !model.isUploading, voiceRecorder.state != .requestingPermission else { return }
        // Finish through the recorder's existing validation/persistence path,
        // then hand the exact draft to the operation pinned before capture.
        if voiceRecorder.state == .recording { voiceRecorder.finish() }
        guard let draft = voiceRecorder.draft, let send = pinnedVoiceSend else { return }
        Task {
            await send(draft)
        }
    }
}

private struct MacAttachmentPasteMonitor: NSViewRepresentable {
    let isActive: Bool
    let onPaste: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPaste: onPaste)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isActive = isActive
        context.coordinator.onPaste = onPaste
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator {
        var isActive = false
        var onPaste: () -> Void
        private var monitor: Any?

        init(onPaste: @escaping () -> Void) {
            self.onPaste = onPaste
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: .keyDown
            ) { [weak self] event in
                guard
                    let self,
                    isActive,
                    event.modifierFlags.contains(.command),
                    event.charactersIgnoringModifiers == "v",
                    NSPasteboard.general.availableType(
                        from: [.fileURL, .tiff, .png]
                    ) != nil
                else {
                    return event
                }

                onPaste()
                return nil
            }
        }

        func removeMonitor() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }

        deinit {
            removeMonitor()
        }
    }
}

private struct MacStagedPhotoDraft: Identifiable {
    let share: PendingShare
    let thumbnail: NSImage

    var id: UUID {
        share.id
    }
}

/// Resolve only a currently staged image for the active account and conversation.
@MainActor
enum MacStagedPhotoPreviewSource {
    static func url(for share: PendingShare, target: SecureConversationResetTarget?,
                    resolve: (PendingShare) throws -> URL) throws -> URL {
        guard let target, share.kind == .image,
              share.conversationOwnerID?.utf8.elementsEqual(target.accountID.utf8) == true,
              share.targetConversationID?.utf8.elementsEqual(target.conversationID.utf8) == true else {
            throw PendingShareStoreError.accountMismatch
        }
        return try resolve(share)
    }
}

private struct MacStagedPhotoPreview: View {
    @Environment(MacAppModel.self) private var model
    let photo: MacStagedPhotoDraft
    let dismiss: () -> Void
    @State private var viewingImage: NSImage?
    @State private var detailImage: NSImage?
    @State private var isZoomed = false

    var body: some View {
        VStack(spacing: 0) {
            MacPhotoCanvas(image: detailImage ?? viewingImage ?? photo.thumbnail) {
                isZoomed = true
            }
            .accessibilityLabel(photo.share.originalFileName ?? "Photo")

            Divider()

            HStack {
                Text(photo.share.originalFileName ?? "Photo")
                    .font(.callout)
                    .lineLimit(1)
                Spacer()
                Button("Done", action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(minWidth: 640, minHeight: 520)
        .modifier(MacConversationPreviewReadObscuration())
        .task {
            let target = model.attachmentPreparationTarget
            guard let target, model.isCurrentAttachmentPreparation(target) else { dismiss(); return }
            do {
                let url = try MacStagedPhotoPreviewSource.url(for: photo.share, target: target,
                                                               resolve: model.stagedAttachmentURL)
                let image = await MacAttachmentImageCache.decodeFile(url, maximumPixelSize: 4096)
                guard !Task.isCancelled else { return }
                guard model.isCurrentAttachmentPreparation(target) else { dismiss(); return }
                viewingImage = image
            } catch PendingShareStoreError.accountMismatch {
                dismiss()
            } catch {
                // The admitted thumbnail remains useful if the local original is unavailable.
            }
        }
        .task(id: isZoomed) {
            guard isZoomed, detailImage == nil, let target = model.attachmentPreparationTarget else { return }
            do {
                let url = try MacStagedPhotoPreviewSource.url(for: photo.share, target: target,
                                                               resolve: model.stagedAttachmentURL)
                let image = await MacAttachmentImageCache.decodeFile(url, maximumPixelSize: 8192)
                guard !Task.isCancelled else { return }
                guard model.isCurrentAttachmentPreparation(target) else { dismiss(); return }
                detailImage = image
            } catch {
                // Keep the fitted preview if the original is no longer available.
            }
        }
        .onChange(of: model.attachmentPreparationTarget) { dismiss() }
        .onDisappear { viewingImage = nil; detailImage = nil }
    }
}

private struct MacStagedFileDraft: Identifiable {
    let share: PendingShare

    var id: UUID { share.id }

    var displayName: String {
        share.originalFileName ?? "File"
    }
}

private struct MacStagedFileTray: View {
    let files: [MacStagedFileDraft]
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
                        .buttonStyle(.plain)
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

private struct MacStagedPhotoTray: View {
    @State private var previewPhoto: MacStagedPhotoDraft?
    let photos: [MacStagedPhotoDraft]
    let previewChanged: (Bool) -> Void
    let isPreparing: Bool
    let remove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 10) {
                ForEach(
                    Array(photos.enumerated()),
                    id: \.element.id
                ) { index, photo in
                    ZStack(alignment: .topTrailing) {
                        Button {
                            previewChanged(true)
                            previewPhoto = photo
                        } label: {
                            Image(nsImage: photo.thumbnail)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 76, height: 76)
                                .clipShape(.rect(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Preview photo \(index + 1)")
                        .accessibilityHint("Opens a larger photo. Pinch to zoom.")

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
                        .buttonStyle(.plain)
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
                }

                if isPreparing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 36, height: 76)
                        .transition(.opacity)
                        .accessibilityLabel("Preparing photos")
                }
            }
            .padding(.horizontal, 2)
            .padding(.top, 7)
            .padding(.trailing, 7)
        }
        .frame(height: 90)
        .scrollIndicators(.hidden)
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("staged-photo-tray")
        .sheet(item: $previewPhoto, onDismiss: { previewChanged(false) }) { photo in
            MacStagedPhotoPreview(photo: photo) { previewPhoto = nil }
        }
        .onChange(of: photos.map(\.id)) {
            if let previewPhoto, !photos.contains(where: { $0.id == previewPhoto.id }) {
                self.previewPhoto = nil
            }
        }
    }
}

private struct MacTypingIndicator: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        .padding(.vertical, 10)
        .background(GiftWrapAppearance.incoming(colorScheme == .dark), in: .capsule)
        .accessibilityLabel("\(partnerName) is typing")
        .accessibilityIdentifier("typing-indicator")
    }

    private func dots(at date: Date?) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                let wave =
                    date.map {
                        sin(
                            $0.timeIntervalSinceReferenceDate * 4.5
                                - Double(index) * 0.75
                        )
                    } ?? 0
                Circle()
                    .fill(.secondary)
                    .frame(width: 6, height: 6)
                    .scaleEffect(0.86 + 0.14 * wave)
                    .opacity(0.5 + 0.35 * ((wave + 1) / 2))
            }
        }
    }
}

private struct MacPendingShareBanner: View {
    let isSending: Bool
    let errorMessage: String?
    let retry: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if isSending {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(
                    systemName: errorMessage == nil
                        ? "square.and.arrow.up"
                        : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(
                    errorMessage == nil ? Color.secondary : Color.orange
                )
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(statusText)
                    .font(.caption.weight(.semibold))
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            if !isSending {
                Button("Retry", action: retry)
                    .controlSize(.small)
                if errorMessage != nil {
                    Button("Remove", role: .destructive, action: remove)
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .accessibilityIdentifier("pending-share-banner")
    }

    private var statusText: String {
        if isSending {
            return "Sending shared item…"
        }
        if errorMessage != nil {
            return "Shared item couldn’t send"
        }
        return "Shared item waiting to send"
    }
}

struct MacAvatar: View {
    let person: Person
    let size: CGFloat
    var image: NSImage? = nil

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(person.initials)
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(GiftWrapAppearance.pine)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .accessibilityLabel(person.displayName)
    }
}

private struct MacEditMessageSheet: View {
    @Binding var text: String
    let save: () -> Void
    let cancel: () -> Void
    @FocusState private var fieldIsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Edit Message")
                .font(.title2.bold())

            TextField("Message", text: $text, axis: .vertical)
                .lineLimit(2...8)
                .textFieldStyle(.roundedBorder)
                .focused($fieldIsFocused)

            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        text.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                    )
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear {
            fieldIsFocused = true
        }
    }
}

private struct MacVoiceComposer: View {
    let recorder: MacVoiceRecorder
    let isSending: Bool

    var body: some View {
        HStack(spacing: 12) {
            Button {
                recorder.cancel()
            } label: {
                Image(systemName: "trash")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .help("Discard voice message")
            .disabled(isSending)

            Circle()
                .fill(recorder.state == .recording ? .red : .secondary)
                .frame(width: 9, height: 9)

            if recorder.state == .ready {
                Button {
                    recorder.togglePreview()
                } label: {
                    Image(systemName: recorder.isPreviewPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(recorder.isPreviewPlaying ? "Pause voice message preview" : "Play voice message preview")
                .accessibilityIdentifier("play-voice-message-preview")

                Slider(
                    value: Binding(
                        get: { recorder.previewProgress },
                        set: { recorder.seekPreview(to: $0) }
                    ),
                    in: 0...1
                )
                .accessibilityLabel("Voice message preview position")
                .accessibilityIdentifier("seek-voice-message-preview")
            } else {
                MacRecordingWaveform(samples: recorder.waveformSamples)
                    .frame(height: 28)
                    .accessibilityLabel("Recording voice message")
            }

            Text(
                VoiceMessageDurationText.string(recorder.elapsedTime)
            )
            .font(.callout.monospacedDigit())
            .frame(minWidth: 42)

            if let previewError = recorder.previewErrorMessage {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.red)
                    .help(previewError)
                    .accessibilityLabel(previewError)
            }

            if recorder.state == .recording {
                Button {
                    recorder.finish()
                } label: {
                    Image(systemName: "stop.fill")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .help("Finish recording")
            }
        }
    }
}

/// Blur scrolling content beneath the floating identity without dimming it.
private struct MacConversationTimelineEdge: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
        content.visualEffect { row, geometry in
            let rowTop = Float(geometry.frame(in: .named("conversationTimelineViewport")).minY)
            return row
                .layerEffect(shader(rowTop: rowTop, axis: CGSize(width: 1, height: 0)),
                    maxSampleOffset: CGSize(width: 12, height: 0), isEnabled: !reduceTransparency)
                .layerEffect(shader(rowTop: rowTop, axis: CGSize(width: 0, height: 1)),
                    maxSampleOffset: CGSize(width: 0, height: 12), isEnabled: !reduceTransparency)
        }
    }

    private func shader(rowTop: Float, axis: CGSize) -> Shader {
        ShaderLibrary.conversationEdgeBlur(
            .float(rowTop), .float4(0, 148, 0, 0), .float2(4, 0),
            .float2(axis), .float(12), .float(Float(1 / max(displayScale, 1)))
        )
    }
}
