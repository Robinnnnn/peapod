import AuthenticationServices
import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class MacAppModel {
    enum Phase: Equatable {
        case welcome
        case restoringConversation
        case pairing
        case waitingForPartner
        case conversation
        case configurationError
    }

    var phase: Phase = .welcome
    var currentUser = Person(
        id: "signed-out",
        displayName: "You",
        initials: "Y"
    )
    var partner = Person(
        id: "partner",
        displayName: "Your person",
        initials: "YP"
    )
    private struct PartnerIdentityScope: Equatable {
        let accountID: String
        let conversationID: String
    }
    private var resolvedPartnerScope: PartnerIdentityScope?
    /// Only an accepted profile for this route may supply the header identity.
    var conversationPartnerIdentity: Person? {
        guard let conversationID,
              resolvedPartnerScope == PartnerIdentityScope(
                accountID: currentUser.id, conversationID: conversationID
              ) else { return nil }
        return partner
    }
    var messages: [ChatMessage] = []
    private var submissionLedger = LocalSubmissionLedger()
    private var composerSubmissionFence = ComposerSubmissionFence()
    private var preparedDraftAttachmentIDs: [UUID: Set<UUID>] = [:]
    private var composerTextDisplayDate: Date?
    private(set) var pendingShareTimelineStatuses: [UUID: PendingShareTimelineStatus] = [:]
    private(set) var reactionBurstEvent: ReactionBurstEvent?
    private var observedReactionSnapshot: ReactionBurstDetection.Snapshot?
    private var reactionSnapshotIsCurrent = false
    private var pendingReactionBursts: [ReactionBurstCandidate] = []
    private(set) var replyContextMessages: [UUID: ChatMessage] = [:]
    var draft = ""
    private var composerReply = MacConversationReplyContext()
    var replyToMessageID: UUID? {
        get { composerReply.selectedID }
        set { composerReply.setSelectedID(newValue) }
    }
    private(set) var composerSendRevision = 0
    var pairingCode = ""
    var pairingCodeExpiresAt: Date?
    var conversationID: String?
    var isPartnerTyping = false
    private(set) var locationSnapshot = ConnectionLocationSnapshot.empty
    var isWorking = false
    var isUploading = false
    var pendingShare: PendingShare?
    private(set) var isSendingQueuedShares = false
    var queuedShareErrorMessage: String?
    var errorMessage: String?

    let voiceRecorder: MacVoiceRecorder
    let partnerPhotoStore = PartnerPhotoStore()
    let usesFirebase: Bool

    let encryption: EncryptedAppServices?
    private let legacyRouting: LegacyConversationTargetPublisher?
    private var legacyRoutingTask: Task<Void, Never>?
    private var legacyRoutingOperation = UUID()
    private(set) var secureConversationWaitingID: String?
    private(set) var secureConversationIsOpening = false
    var isPreparingAccount: Bool {
        isAuthenticated && errorMessage == nil
            && (phase == .welcome || !profileIsReady || !conversationAssignmentResolved)
    }
    private var pendingSecureInvite: String?
    private var secureInvitationAssignmentID: String?

    var hasPendingSecureInvitation: Bool { pendingSecureInvite != nil }
    private var secureOpeningGeneration = UUID()
    private var sessionGeneration = UUID()
    private var conversationAssignmentGeneration = UUID()
    private let auth: any AuthProviding
    private let pairing: any PairingProviding
    private let messaging: any MessagingProviding
    private let profiles: any ProfileProviding
    private let attachmentDrafts: AttachmentDraftDependencies
    private let attachments: any AttachmentProviding
    private let clipboard: any ClipboardProviding
    private let notificationCoordinator: any MacNotificationCoordinating
    private let locationViewer: any MacConnectionLocationViewing
    private let enqueuePendingShares: ([PendingShare]) throws -> Void
    private let loadPendingShares: () throws -> [PendingShare]
    private let acknowledgePendingShares: (Set<UUID>) throws -> Void
    private let discardPendingShares: () -> Void
    private let configurationIssue: String?
    private let notificationRetryConfiguration: NotificationRetryConfiguration

    private var profileObservation: ServiceObservation?
    private var historyViewportAtLatest = false
    func historyViewportDidChange(isAtLatest: Bool) {
        historyViewportAtLatest = isAtLatest
        refreshConversationReadVisibility()
        guard conversationReadVisibility.allowsReadAcknowledgment,
              let incoming = messages.last(where: { $0.senderID != currentUser.id }) else { return }
        acknowledge(incoming, markAsRead: true)
    }
    private(set) var messagePins: MessagePinsController?
    private(set) var historyController: ConversationHistoryController?
    var usesBoundedHistory: Bool { historyController != nil }
    var historyIsLoading: Bool { historyController?.isLoading ?? false }
    var historyHasOlder: Bool { historyController?.hasOlder ?? false }
    var historyHasNewer: Bool { historyController?.hasNewer ?? false }
    var historyIsRecent: Bool { historyController?.isRecentVisible ?? true }
    func searchMessageHistory(_ query: String) {
        conversationIsSearching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        historyController?.searchFor(query)
    }
    func loadMoreSearchResults() { historyController?.moreSearchResults() }
    func loadNewerMessages() { historyController?.newer() }
    func showMessageInHistory(_ id: UUID) {
        guard let historyController else { return }
        historyController.searchFor("")
        historyController.around(id)
    }
    private var messageObservation: ServiceObservation?
    private var typingObservation: ServiceObservation?
    private var locationObservation: ServiceObservation?
    private var locationObservationGeneration = UUID()
    private var openingConversationID: String?
    private var pendingPairingCode: String?
    private var isAuthenticated = false
    private var profileIsReady = false
    private var conversationAssignmentResolved = false
    private var lastTypingRefreshAt: Date?
    private var typingStopTask: Task<Void, Never>?
    private var lastMarkedDeliveredMessageID: UUID?
    private var lastMarkedReadMessageID: UUID?
    private var conversationIsVisible = false
    private var appIsActive = true
    private var conversationIsSearching = false
    private var conversationObscurations: Set<MacConversationObscuration> = []
    private var attachmentPreviewSources: Set<UUID> = []

    private var conversationReadVisibility: MacConversationReadVisibility {
        var obscurations = conversationObscurations
        if !attachmentPreviewSources.isEmpty { obscurations.insert(.attachmentPreview) }
        return MacConversationReadVisibility(
            isVisible: conversationIsVisible, isAppActive: appIsActive,
            isAtLatest: historyViewportAtLatest, isRecent: historyIsRecent,
            isSearching: conversationIsSearching, obscurations: obscurations
        )
    }

    func conversationObscurationsDidChange(_ sources: Set<MacConversationObscuration>) {
        conversationObscurations = sources
        refreshConversationReadVisibility()
    }

    func conversationAttachmentPreviewDidChange(_ source: UUID, isPresented: Bool) {
        if isPresented { attachmentPreviewSources.insert(source) }
        else { attachmentPreviewSources.remove(source) }
        refreshConversationReadVisibility()
    }

    private func refreshConversationReadVisibility() {
        if conversationReadVisibility.suppressesForegroundAlerts { presentNextReactionBurstIfPossible() }
        else { reactionBurstEvent = nil }
        notificationCoordinator.setActiveConversation(
            conversationReadVisibility.suppressesForegroundAlerts ? conversationID : nil
        )
        if !conversationReadVisibility.suppressesForegroundAlerts { stopPublishingTyping() }
        guard conversationReadVisibility.allowsReadAcknowledgment,
              let incoming = messages.last(where: { $0.senderID != currentUser.id }) else { return }
        acknowledge(incoming, markAsRead: true)
    }
    private var failedAttachmentShares: [UUID: PendingShare] = [:]
    private var pendingDeviceToken: String?
    private var notificationAuthorizationRequested = false
    private var deviceTokenSaveOperationID = UUID()
    private var queuedShares: [PendingShare] = []
    private var composerShareIDs: Set<UUID> = []
    private var preparedDraftConversationIDs: [UUID: String] = [:]

    var pendingExternalShare: PendingShare? {
        queuedShares.first { !composerShareIDs.contains($0.id) }
    }
    private var conversationBeingTornDownID: String?
    private var conversationDeletionWasObserved = false
    private var deletedConversationIDAwaitingAssignmentClear: String?

    init(
        auth: any AuthProviding,
        pairing: any PairingProviding,
        messaging: any MessagingProviding,
        profiles: any ProfileProviding,
        attachments: any AttachmentProviding,
        encryption: EncryptedAppServices? = nil,
        attachmentDrafts: AttachmentDraftDependencies = .native,
        legacyRouting: LegacyConversationTargetPublisher? = nil,
        locationViewer: (any MacConnectionLocationViewing)? = nil,
        clipboard: any ClipboardProviding = MacClipboard(),
        notificationCoordinator: any MacNotificationCoordinating =
            MacPushNotificationCoordinator.shared,
        enqueuePendingShares: @escaping ([PendingShare]) throws -> Void = {
            try PendingShareStore.enqueue($0)
        },
        loadPendingShares: @escaping () throws -> [PendingShare] = {
            try PendingShareStore.pendingItems()
        },
        acknowledgePendingShares: @escaping (Set<UUID>) throws -> Void = {
            _ = try PendingShareStore.acknowledgeProcessed($0)
        },
        discardPendingShares: @escaping () -> Void = {
            PendingShareStore.removeAll()
        },
        usesFirebase: Bool,
        voiceRecorder: MacVoiceRecorder? = nil,
        configurationIssue: String? = nil,
        notificationRetryConfiguration: NotificationRetryConfiguration = .production
    ) {
        self.voiceRecorder = voiceRecorder ?? MacVoiceRecorder()
        self.attachmentDrafts = attachmentDrafts
        self.encryption = encryption
        self.legacyRouting = encryption == nil ? legacyRouting : nil
        self.auth = auth
        self.pairing = pairing
        self.messaging = encryption.map(EncryptedMessagingRouter.init) ?? messaging
        self.profiles = profiles
        self.attachments = encryption.map(EncryptedAttachmentRouter.init) ?? attachments
        self.clipboard = clipboard
        self.notificationCoordinator = notificationCoordinator
        if let locationViewer { self.locationViewer = locationViewer }
        else if let encryption { self.locationViewer = MacEncryptedConnectionLocationViewer(encryption) }
        else { self.locationViewer = MacEmptyConnectionLocationViewer() }
        self.enqueuePendingShares = encryption.map { services in { try services.enqueueDrafts($0) } } ?? enqueuePendingShares
        self.loadPendingShares = encryption.map { services in { try services.pendingDrafts() } } ?? loadPendingShares
        self.acknowledgePendingShares = encryption.map { services in { try services.acknowledgeDrafts($0) } } ?? acknowledgePendingShares
        self.discardPendingShares = encryption == nil ? discardPendingShares : {}
        self.usesFirebase = usesFirebase
        self.configurationIssue = configurationIssue
        self.notificationRetryConfiguration = notificationRetryConfiguration
    }

    func start() async {
        if let configurationIssue {
            errorMessage = configurationIssue
            phase = .configurationError
            return
        }

        if let user = await auth.restoreCurrentUser() {
            await completeAuthentication(with: user)
        }
        reloadPendingShares()
    }

    func finishSignIn(
        authorization: ASAuthorization,
        rawNonce: String?
    ) async {
        guard
            let credential =
                authorization.credential as? ASAuthorizationAppleIDCredential
        else {
            errorMessage =
                AuthenticationError.invalidAuthorization.localizedDescription
            return
        }
        guard let rawNonce else {
            errorMessage = AuthenticationError.missingNonce.localizedDescription
            return
        }

        isWorking = true
        defer { isWorking = false }

        do {
            let user = try await auth.signIn(
                credential: credential,
                rawNonce: rawNonce
            )
            await completeAuthentication(with: user)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createConversation() async {
        guard encryption == nil || profileIsReady else {
            errorMessage = "Account setup is still finishing. Try again."
            return
        }
        guard encryption?.requiresSecurePairing != true else {
            errorMessage = "Use a secure invitation to connect in this version of Peapod."
            phase = .pairing
            return
        }
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        do {
            let createdAt = Date()
            let result = try await pairing.createConversation()
            if let conversationID = result.conversationID {
                await enterConversation(conversationID)
                return
            }
            guard
                let code = result.code,
                let canonicalCode = PairingCode.canonicalValue(code)
            else {
                throw PairingError.invalidResponse
            }
            pairingCode = canonicalCode
            pairingCodeExpiresAt = createdAt.addingTimeInterval(
                PairingCode.lifetime
            )
            phase = .waitingForPartner
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func joinConversation(code: String) async {
        guard encryption == nil || profileIsReady else {
            errorMessage = "Account setup is still finishing. Try again."
            return
        }
        guard encryption?.requiresSecurePairing != true else {
            errorMessage = "Use a secure invitation to connect in this version of Peapod."
            phase = .pairing
            return
        }
        guard !isWorking else { return }
        guard let canonicalCode = PairingCode.canonicalValue(code) else {
            errorMessage = PairingCodeInputError.invalid.localizedDescription
            return
        }

        isWorking = true
        defer { isWorking = false }

        do {
            let result = try await pairing.joinConversation(
                code: canonicalCode
            )
            guard let conversationID = result.conversationID else {
                throw PairingError.invalidResponse
            }
            await enterConversation(conversationID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancelPairing() async {
        guard
            !isWorking,
            phase == .waitingForPartner,
            let canonicalCode = PairingCode.canonicalValue(pairingCode)
        else {
            return
        }

        isWorking = true
        defer { isWorking = false }

        do {
            let result = try await pairing.cancelPairingCode(
                code: canonicalCode
            )
            if let conversationID = result.conversationID {
                await enterConversation(conversationID)
                return
            }
            guard
                conversationID == nil,
                phase != .conversation
            else {
                return
            }
            pairingCode = ""
            pairingCodeExpiresAt = nil
            phase = .pairing
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signOut() async {
        guard isAuthenticated, !isWorking else { return }
        let signingOutSession = sessionGeneration
        let signingOutUserID = currentUser.id
        isWorking = true
        defer { if sessionGeneration == signingOutSession { isWorking = false } }

        await stopPublishingTypingAndWait()
        guard sessionGeneration == signingOutSession else { return }
        do {
            try await profiles.removeDeviceRegistration(userID: signingOutUserID)
            guard sessionGeneration == signingOutSession else { return }
            try auth.signOut()
            // Revoke model entry points before notification cleanup can suspend.
            // The still-mounted conversation must not reattach a discarded recorder.
            isAuthenticated = false
            messagePins?.stop(); messagePins = nil
            deviceTokenSaveOperationID = UUID()
            notificationCoordinator.invalidateSession()
            // Revoke recording and permission callbacks before awaiting notification cleanup.
            do { try voiceRecorder.discardAccount(signingOutUserID) }
            catch { errorMessage = "Signed out, but a local voice draft could not be removed. " + error.localizedDescription }
            await notificationCoordinator.resetForSignOut()
            guard sessionGeneration == signingOutSession else { return }
            notificationAuthorizationRequested = false
            isWorking = false
            resetForSignedOutSession()
        } catch {
            guard sessionGeneration == signingOutSession else { return }
            errorMessage = error.localizedDescription
        }
    }

    func deleteConversation() async {
        errorMessage = "Conversation deletion is unavailable."
    }

    func sendDraft(
        deliveryMode: MessageDeliveryMode = .normal
    ) async {
        guard let pending = prepareDraftForSend(deliveryMode: deliveryMode) else { return }
        await sendPreparedDraft(pending)
    }

    func prepareDraftForSend(
        deliveryMode: MessageDeliveryMode = .normal,
        precedingAttachmentIDs: Set<UUID> = []
    ) -> ChatMessage? {
        let submittedDraft = draft
        let submittedReply = replyToMessageID
        let trimmed = submittedDraft.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty, let conversationID else { return nil }

        draft = ""
        replyToMessageID = nil
        stopPublishingTyping()

        let pending = ChatMessage(
            senderID: currentUser.id,
            kind: .forText(trimmed),
            body: trimmed,
            deliveryState: .sending,
            replyToID: submittedReply,
            deliveryMode: deliveryMode
        )
        if let attachmentIndex = messages.firstIndex(where: {
            precedingAttachmentIDs.contains($0.id)
        }) {
            messages.insert(pending, at: attachmentIndex)
        } else {
            messages.append(pending)
        }
        submissionLedger.register(pending, after: messages.filter { !precedingAttachmentIDs.contains($0.id) })
        if let date = composerTextDisplayDate { submissionLedger.displayDates[pending.id] = date }
        composerTextDisplayDate = nil
        messages = submissionLedger.ordered(messages)
        // The composer hands these IDs to this text submission synchronously.
        let assigned = Set(preparedDraftAttachmentIDs.values.flatMap { $0 })
        preparedDraftAttachmentIDs[pending.id] = composerSubmissionFence.waiting.subtracting(assigned)
        preparedDraftConversationIDs[pending.id] = conversationID
        composerSendRevision &+= 1
        return pending
    }

    func sendPreparedDraft(_ pending: ChatMessage) async {
        let sendingSession = sessionGeneration

        guard let targetConversationID = preparedDraftConversationIDs.removeValue(forKey: pending.id),
            conversationID == targetConversationID else { return }
        defer {
            if sessionGeneration == sendingSession, conversationID == targetConversationID {
                composerSubmissionFence.release(preparedDraftAttachmentIDs.removeValue(forKey: pending.id) ?? [])
                Task { await sendQueuedSharesIfPossible() }
            }
        }
        do {
            let sent = try await messaging.send(
                pending,
                conversationID: targetConversationID
            )
            guard sessionGeneration == sendingSession, conversationID == targetConversationID else { return }
            replaceMessage(sent)
        } catch {
            guard sessionGeneration == sendingSession, conversationID == targetConversationID else { return }
            var failed = pending
            failed.deliveryState = .failed
            replaceMessage(failed)
            errorMessage = error.localizedDescription
        }
    }

    func retryMessage(_ message: ChatMessage) async {
        let sendingSession = sessionGeneration

        guard
            message.senderID == currentUser.id,
            message.deliveryState == .failed,
            let conversationID,
            let index = messages.firstIndex(where: { $0.id == message.id })
        else {
            return
        }

        if queuedShares.contains(where: { $0.id == message.id }) {
            await retryPendingShare(message.id)
            return
        }

        messages[index].deliveryState = .sending
        submissionLedger.register(messages[index], after: messages)
        var retry = messages[index]
        do {
            if let share = failedAttachmentShares[message.id] {
                let attachment = try await attachments.upload(
                    share,
                    messageID: message.id,
                    conversationID: conversationID,
                    ownerID: currentUser.id
                )
                guard sessionGeneration == sendingSession else { return }
                retry.attachment = attachment
            }
            let sent = try await messaging.send(
                retry,
                conversationID: conversationID
            )
            guard sessionGeneration == sendingSession else { return }
            replaceMessage(sent)
            discardFailedAttachmentShare(message.id)
        } catch {
            guard sessionGeneration == sendingSession else { return }
            if let currentIndex = messages.firstIndex(
                where: { $0.id == message.id }
            ) {
                messages[currentIndex].deliveryState = .failed
                submissionLedger.pending[message.id] = messages[currentIndex]
            }
            errorMessage = error.localizedDescription
        }
    }

    func sendFiles(_ urls: [URL]) async {

        let sendingSession = sessionGeneration

        guard
            !urls.isEmpty,
            let conversationID,
            !isUploading
        else {
            return
        }

        isUploading = true
        defer { if sessionGeneration == sendingSession { isUploading = false } }

        for url in urls.prefix(PhotoAttachmentDraftPolicy.maximumCount) {
            guard sessionGeneration == sendingSession else { return }
            let isAccessingSecurityScopedResource =
                url.startAccessingSecurityScopedResource()
            defer {
                if isAccessingSecurityScopedResource {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let contentType = UTType(
                    filenameExtension: url.pathExtension
                )
                let share = try stageAttachmentFile(
                    from: url,
                    kind: Self.pendingShareKind(for: contentType),
                    suggestedName: url.lastPathComponent,
                    contentTypeIdentifier: contentType?.identifier
                )
                let pending = ChatMessage(
                    id: share.id,
                    senderID: currentUser.id,
                    kind: .attachment,
                    body: share.originalFileName ?? url.lastPathComponent,
                    deliveryState: .sending
                )
                submissionLedger.register(pending, after: messages)
                messages.append(pending)
                failedAttachmentShares[pending.id] = share

                do {
                    let attachment = try await attachments.upload(
                        share,
                        messageID: pending.id,
                        conversationID: conversationID,
                        ownerID: currentUser.id
                    )
                    guard sessionGeneration == sendingSession else { return }
                    var ready = pending
                    ready.attachment = attachment
                    replaceMessage(ready)
                    let sent = try await messaging.send(
                        ready,
                        conversationID: conversationID
                    )
                    guard sessionGeneration == sendingSession else { return }
                    replaceMessage(sent)
                    discardFailedAttachmentShare(pending.id)
                } catch {
                    guard sessionGeneration == sendingSession else { return }
                    var failed = pending
                    failed.deliveryState = .failed
                    replaceMessage(failed)
                    errorMessage = error.localizedDescription
                }
            } catch {
                guard sessionGeneration == sendingSession else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    func enqueueStagedPhotoAttachments(
        _ shares: [PendingShare],
        deliveryMode: MessageDeliveryMode = .normal
    ) throws {
        try enqueueComposerAttachments(
            photoShares: shares,
            fileShares: [],
            deliveryMode: deliveryMode
        )
    }

    func enqueueComposerAttachments(
        photoShares: [PendingShare],
        fileShares: [PendingShare],
        deliveryMode: MessageDeliveryMode
    ) throws {
        do {
            let preparedShares = photoShares.isEmpty
                ? []
                : try PhotoAttachmentDraftPolicy
                    .preparedForSend(photoShares)
            guard fileShares.allSatisfy({ $0.kind != .image }) else {
                throw PhotoAttachmentDraftError.unsupportedItem
            }
            guard
                preparedShares.count + fileShares.count
                    <= PhotoAttachmentDraftPolicy.maximumCount
            else {
                throw PhotoAttachmentDraftError.tooMany(
                    maximum: PhotoAttachmentDraftPolicy.maximumCount
                )
            }
            guard let conversationID else {
                throw PendingShareStoreError.missingConversationTarget
            }
            let outgoingShares = try (preparedShares + fileShares).map { share in
                try AttachmentDraftDependencies.validateProvenance(share, accountID: currentUser.id, conversationID: conversationID,
                    requiresBound: encryption != nil)
                return try share.delivered(deliveryMode).scopedToConversation(conversationID)
            }
            try enqueuePendingShares(outgoingShares)
            if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                composerSubmissionFence.hold(Set(outgoingShares.map(\.id)))
                composerTextDisplayDate = max(Date(), (submissionLedger.displayDates.values.max() ?? messages.last?.createdAt ?? .distantPast).addingTimeInterval(0.000_001))
            }
            if !outgoingShares.isEmpty { composerSendRevision &+= 1 }
            composerShareIDs.formUnion(outgoingShares.map(\.id))
            reloadPendingShares()
            presentComposerAttachments()
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    /// Display accepted composer attachments before their uploads begin.
    private func presentComposerAttachments() {
        synchronizePendingShareMessages()
    }

    private func synchronizePendingShareMessages() {
        for share in queuedShares where share.targetConversationID == conversationID {
            let pending = pendingMessage(for: share)
            if submissionLedger.displayDates[share.id] == nil, let textDate = composerTextDisplayDate {
                submissionLedger.displayDates[share.id] = max(textDate, submissionLedger.displayDates.values.max() ?? .distantPast).addingTimeInterval(0.000_001)
            }
            if let index = messages.firstIndex(where: { $0.id == share.id }) {
                messages[index].deliveryState = pending.deliveryState
                if submissionLedger.pending[share.id] != nil { submissionLedger.pending[share.id] = messages[index] }
            } else { upsertMessage(pending) }
        }
        messages = submissionLedger.ordered(messages)
    }

    private func pendingMessage(for share: PendingShare) -> ChatMessage {
        if share.kind == .text || share.kind == .url {
            return ChatMessage(id: share.id, senderID: currentUser.id,
                kind: .forText(share.text ?? ""), body: share.text ?? "",
                createdAt: share.createdAt,
                deliveryState: (pendingShareTimelineStatuses[share.id] ?? .waiting).deliveryState, deliveryMode: share.deliveryMode)
        }
        return ChatMessage(
            id: share.id,
            senderID: currentUser.id,
            kind: share.isVoiceMessage ? .voice : .attachment,
            body: share.originalFileName ?? "Attachment",
            createdAt: share.createdAt,
            deliveryState: (pendingShareTimelineStatuses[share.id] ?? .waiting).deliveryState,
            attachment: AttachmentContent(
                id: share.id.uuidString,
                type: LocalAttachmentService.attachmentType(for: share),
                storagePath: nil,
                fileName: share.originalFileName ?? "Attachment",
                contentType: share.contentTypeIdentifier.flatMap { UTType($0)?.preferredMIMEType }
                    ?? "application/octet-stream",
                byteSize: 0
            ),
            attachmentGroupID: share.attachmentGroupID,
            attachmentGroupIndex: share.attachmentGroupIndex,
            attachmentGroupCount: share.attachmentGroupCount,
            deliveryMode: share.deliveryMode
        )
    }

    /// Restore only the authenticated conversation's local drafts. Already accepted
    /// outbox IDs reconcile a process exit between enqueue and source consumption.
    private func restoreVoiceMessageDraft() {
        guard isAuthenticated,
              let conversationID, phase == .conversation else { return }
        let scope = MacVoiceMessageDraftStore.Scope(accountID: currentUser.id, conversationID: conversationID)
        let accepted = (try? loadPendingShares())?.filter {
            $0.isVoiceMessage && $0.conversationOwnerID?.utf8.elementsEqual(scope.accountID.utf8) == true
                && $0.targetConversationID?.utf8.elementsEqual(scope.conversationID.utf8) == true
        } ?? []
        voiceRecorder.configure(scope: scope, acceptedDraftIDs: Set(accepted.map(\.id)))
    }

    /// Capture before recording or when restoring a ready draft. A later account,
    /// conversation, or session must never adopt this callback's recording.
    func makeVoiceMessageSendOperation() -> (VoiceMessageDraft) async -> Void {
        restoreVoiceMessageDraft()
        let recordingSession = sessionGeneration
        let owner = currentUser.id
        let target = conversationID
        return { [weak self] draft in
            guard let self, self.sessionGeneration == recordingSession,
                  self.currentUser.id == owner, let target,
                  self.conversationID == target else { return }
            await self.sendVoiceMessage(draft)
        }
    }

    func sendVoiceMessage(_ draft: VoiceMessageDraft) async {

        guard isAuthenticated, let target = attachmentPreparationTarget,
              isCurrentAttachmentPreparation(target),
              let scope = voiceRecorder.scope,
              scope == .init(accountID: target.accountID, conversationID: target.conversationID),
              voiceRecorder.draft?.id == draft.id else { return }
        do {
            let handoff = MacVoiceMessageHandoff(scope: scope,
                isCurrent: { [self] in isCurrentAttachmentPreparation(target) },
                stage: { [self] draft in
                    try stageAttachmentFile(from: draft.fileURL, kind: .file,
                        suggestedName: draft.suggestedFileName,
                        contentTypeIdentifier: VoiceMessageDraft.contentTypeIdentifier)
                }, pendingItems: loadPendingShares, enqueue: enqueuePendingShares,
                discard: attachmentDrafts.discard)
            let share = try handoff.stageAndEnqueue(draft)
            guard isCurrentAttachmentPreparation(target), voiceRecorder.scope == scope,
                  voiceRecorder.draft?.id == draft.id else { return }
            // No suspension between durable acceptance and consumption. Preparation or
            // enqueue failure leaves the original ready draft playable and retryable.
            voiceRecorder.markDraftConsumed()
            composerSendRevision &+= 1
            composerShareIDs.insert(share.id)
            reloadPendingShares()
            presentComposerAttachments()
            await sendQueuedSharesIfPossible()
        } catch {
            guard isCurrentAttachmentPreparation(target) else { return }
            errorMessage = error.localizedDescription
        }
    }

    func beginReply(to message: ChatMessage) {
        guard !message.isUnsent else { return }
        composerReply.select(message)
    }

    func cancelReply() {
        replyToMessageID = nil
    }

    var replyTarget: ChatMessage? {
        composerReply.target(messages: replyLookupMessages, context: replyContextMessages)
    }

    private var replyLookupMessages: [ChatMessage] {
        messages + (historyController?.search?.messages ?? [])
    }

    func refreshSelectedReplyContext() {
        composerReply.accept(messages: replyLookupMessages, context: replyContextMessages)
    }

    func replyContextMessage(_ id: UUID) -> ChatMessage? {
        replyLookupMessages.first { $0.id == id } ?? replyContextMessages[id]
            ?? (replyToMessageID == id ? replyTarget : nil)
    }

    func editMessage(_ message: ChatMessage, body: String) async {
        let trimmed = body.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard
            !trimmed.isEmpty,
            message.senderID == currentUser.id,
            !message.isUnsent,
            message.kind == .text || message.kind == .link,
            let conversationID,
            let index = messages.firstIndex(where: { $0.id == message.id })
        else {
            return
        }

        let original = messages[index]
        messages[index].body = trimmed
        messages[index].kind = .forText(trimmed)
        messages[index].editedAt = .now
        do {
            try await messaging.editMessage(
                conversationID: conversationID,
                messageID: message.id.uuidString,
                body: trimmed
            )
        } catch {
            messages[index] = original
            errorMessage = error.localizedDescription
        }
    }

    func unsendMessage(_ message: ChatMessage) async {
        guard
            message.senderID == currentUser.id,
            !message.isUnsent,
            let conversationID,
            let index = messages.firstIndex(where: { $0.id == message.id })
        else {
            return
        }

        let original = messages[index]
        messages[index].body = ""
        messages[index].deletedAt = .now
        messages[index].reactions = [:]
        if replyToMessageID == message.id {
            replyToMessageID = nil
        }
        do {
            try await messaging.unsendMessage(
                conversationID: conversationID,
                messageID: message.id.uuidString
            )
        } catch {
            messages[index] = original
            errorMessage = error.localizedDescription
        }
    }

    private func receiveObservedReactions(_ rows: [ChatMessage]) {
        let current = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.reactions) })
        if let previous = observedReactionSnapshot {
            pendingReactionBursts = ReactionBurstReplayPolicy.reconciledMappedCandidates(
                pendingReactionBursts, from: previous, to: current, currentUserID: currentUser.id)
        }
        if let event = reactionBurstEvent, current[event.messageID] == nil { reactionBurstEvent = nil }
        observedReactionSnapshot = current
        reactionSnapshotIsCurrent = true
        presentNextReactionBurstIfPossible()
    }

    private func presentNextReactionBurstIfPossible() {
        guard phase == .conversation,
              conversationReadVisibility.suppressesForegroundAlerts,
              reactionBurstEvent == nil, !pendingReactionBursts.isEmpty,
              reactionSnapshotIsCurrent || pendingReactionBursts.first?.reactorID == currentUser.id else { return }
        let candidate = pendingReactionBursts.removeFirst()
        reactionBurstEvent = ReactionBurstEvent(messageID: candidate.messageID,
            reactorID: candidate.reactorID, emoji: candidate.emoji)
    }

    func reactionBurstDidFinish(_ id: UUID) {
        guard reactionBurstEvent?.id == id else { return }
        reactionBurstEvent = nil
        presentNextReactionBurstIfPossible()
    }

    func toggleReaction(_ emoji: String, on message: ChatMessage) async {
        let session = sessionGeneration
        let account = currentUser.id
        guard
            !message.isUnsent,
            let conversationID,
            let index = messages.firstIndex(where: { $0.id == message.id })
        else {
            return
        }

        let original = messages[index].reactions[currentUser.id]
        let updated = original == emoji ? nil : emoji
        messages[index].reactions[currentUser.id] = updated
        if observedReactionSnapshot?[message.id] != nil { observedReactionSnapshot?[message.id]?[account] = updated }
        if let updated {
            pendingReactionBursts.removeAll { $0.messageID == message.id && $0.reactorID == account }
            pendingReactionBursts.insert(.init(messageID: message.id, reactorID: account, emoji: updated), at: 0)
            pendingReactionBursts = Array(pendingReactionBursts.prefix(ReactionBurstReplayPolicy.maximumMappedPendingCandidates))
            presentNextReactionBurstIfPossible()
        }
        do {
            try await messaging.setReaction(
                conversationID: conversationID,
                messageID: message.id.uuidString,
                userID: currentUser.id,
                emoji: updated
            )
        } catch {
            guard sessionGeneration == session, self.conversationID == conversationID,
                  currentUser.id == account,
                  let currentIndex = messages.firstIndex(where: { $0.id == message.id }) else { return }
            messages[currentIndex].reactions[account] = original
            observedReactionSnapshot?[message.id]?[account] = original
            pendingReactionBursts.removeAll { $0.messageID == message.id && $0.reactorID == account }
            errorMessage = error.localizedDescription
        }
    }

    func draftDidChange() {
        guard let conversationID else { return }
        typingStopTask?.cancel()

        let hasText = !draft.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty
        guard hasText else {
            stopPublishingTyping()
            return
        }

        let now = Date.now
        if
            lastTypingRefreshAt == nil
                || now.timeIntervalSince(
                    lastTypingRefreshAt ?? .distantPast
                ) >= 4
        {
            lastTypingRefreshAt = now
            Task {
                try? await messaging.setTyping(
                    conversationID: conversationID,
                    userID: currentUser.id,
                    isTyping: true
                )
            }
        }

        typingStopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.stopPublishingTyping()
        }
    }

    func conversationVisibilityDidChange(
        isVisible: Bool,
        isAppActive: Bool
    ) {
        conversationIsVisible = isVisible
        appIsActive = isAppActive
        refreshConversationReadVisibility()
        notificationCoordinator.setActiveConversation(
            conversationReadVisibility.suppressesForegroundAlerts ? conversationID : nil
        )
        if !isVisible || !isAppActive {
            stopPublishingTyping()
        }
        if isVisible, isAppActive {
            refreshLegacyConversationRouting()
            reloadPendingShares()
            Task {
                await configureNotifications()
                await sendQueuedSharesIfPossible()
            }
        }
        guard
            conversationReadVisibility.allowsReadAcknowledgment,
            let latestIncoming = messages.last(
                where: { $0.senderID != currentUser.id }
            )
        else {
            return
        }
        acknowledge(latestIncoming, markAsRead: true)
    }

    func copyPairingCode() -> Bool {
        guard let code = PairingCode.canonicalValue(pairingCode) else {
            return false
        }
        clipboard.setString(code)
        return true
    }

    var pairingLink: URL? {
        guard let code = PairingCode.canonicalValue(pairingCode) else {
            return nil
        }
        return URL(string: "peapod://join/\(code)")
    }

    private var secureInvitationConnectionIsOccupied: Bool {
        conversationID != nil || secureConversationWaitingID != nil || secureInvitationAssignmentID != nil
            || encryption?.pairingClient?.pendingHandle != nil || encryption?.pairingClient?.completedCapsule != nil
            || encryption?.pairingClient?.isBusy == true || encryption?.resetRecoveryBlocked == true
    }

    private func rejectSecureInvitationForExistingConnection() {
        guard pendingSecureInvite != nil, isAuthenticated, profileIsReady else { return }
        if encryption?.requiresSecurePairing != true {
            pendingSecureInvite = nil
            errorMessage = "Encrypted conversations are not enabled for this account yet."
        } else if secureInvitationConnectionIsOccupied {
            pendingSecureInvite = nil
            errorMessage = "You’re already connected or connecting. This invitation was not opened."
        }
    }

    func dismissSecureInvitation() { pendingSecureInvite = nil }

    func acceptSecureInvitation() async {
        rejectSecureInvitationForExistingConnection()
        guard let invitation = pendingSecureInvite, isAuthenticated, profileIsReady,
              conversationAssignmentResolved, !isWorking, !secureInvitationConnectionIsOccupied,
              let encryption, encryption.requiresSecurePairing, let client = encryption.pairingClient,
              client.state != .keyUnavailable, client.state != .signedOut else { return }
        let generation = sessionGeneration, account = currentUser.id
        // Explicit Join consumes the in-memory secret before protocol suspension.
        pendingSecureInvite = nil
        await client.joinInvite(invitation)
        guard sessionGeneration == generation, currentUser.id == account,
              self.encryption?.pairingClient === client else { return }
        await refreshSecureConnection()
    }

    func handle(_ url: URL) {
        if url.absoluteString.hasPrefix("peapod://secure-pair") {
            guard encryption != nil else { errorMessage = "Secure invitations are unavailable in this build."; return }
            do { _ = try SecurePairingInviteInput.parse(url.absoluteString) }
            catch { errorMessage = "This secure invite is invalid."; return }
            if isAuthenticated, profileIsReady, encryption?.requiresSecurePairing != true {
                pendingSecureInvite = nil
                errorMessage = "Encrypted conversations are not enabled for this account yet."
                return
            }
            if isAuthenticated, secureInvitationConnectionIsOccupied {
                errorMessage = "You’re already connected or connecting. This invitation was not opened."
                return
            }
            if let pendingSecureInvite, pendingSecureInvite != url.absoluteString {
                errorMessage = "An invitation is already open. Join it or choose Not now before opening another."
                return
            }
            pendingSecureInvite = url.absoluteString
            return
        }
        guard url.scheme == "peapod" else {
            return
        }

        if
            url.host == "join",
            let code = url.pathComponents.last,
            let canonicalCode = PairingCode.canonicalValue(code)
        {
            guard isAuthenticated else {
                pendingPairingCode = canonicalCode
                return
            }
            Task {
                await joinConversation(code: canonicalCode)
            }
        } else if url.host == "share" {
            reloadPendingShares()
            Task {
                await sendQueuedSharesIfPossible()
            }
        }
    }

    func pendingShareTimelineStatus(for id: UUID) -> PendingShareTimelineStatus? {
        pendingShareTimelineStatuses[id]
    }

    func sendPendingComposerAttachments() async { await sendQueuedSharesIfPossible() }

    func retryPendingShares() async {
        await retryPendingShares(Set(queuedShares.map(\.id)))
    }

    func retryPendingShare(_ id: UUID) async { await retryPendingShares([id]) }

    func retryPendingShares(_ ids: Set<UUID>) async {
        guard !isSendingQueuedShares else { return }
        for id in ids where pendingShareTimelineStatuses[id] != nil {
            pendingShareTimelineStatuses[id] = .waiting
        }
        queuedShareErrorMessage = nil
        reloadPendingShares()
        synchronizePendingShareMessages()
        await sendQueuedSharesIfPossible()
    }

    func discardPendingShare() async {
        guard let item = pendingExternalShare ?? pendingShare else { return }
        await discardPendingShare(item.id)
    }

    func discardPendingShare(_ id: UUID) async { await discardPendingShares([id]) }

    func discardPendingShares(_ ids: Set<UUID>) async {
        // Never remove an item whose network operation is in flight.
        guard !isSendingQueuedShares else { return }
        let removable = ids.intersection(queuedShares.map(\.id))
        do {
            try acknowledgePendingShares(removable)
            for id in removable {
                pendingShareTimelineStatuses[id] = nil
                submissionLedger.remove(id)
            }
            composerSubmissionFence.release(removable)
            messages.removeAll { removable.contains($0.id) }
            queuedShareErrorMessage = nil
            reloadPendingShares()
            await sendQueuedSharesIfPossible()
        } catch { queuedShareErrorMessage = error.localizedDescription }
    }

    func configureNotifications() async {
        let notificationSession = sessionGeneration
        guard usesFirebase else { return }

        notificationCoordinator.configure(
            tokenHandler: { [weak self] token in
                guard let self, self.sessionGeneration == notificationSession else { return }
                await self.receiveDeviceToken(token)
            },
            actionHandler: { [weak self] action in
                guard let self, self.sessionGeneration == notificationSession else { return }
                await self.handleNotificationAction(action)
            }
        )

        guard
            isAuthenticated,
            !notificationAuthorizationRequested
        else {
            return
        }
        notificationAuthorizationRequested = true
        do {
            _ = try await notificationCoordinator
                .requestAuthorizationAndRegister()
        } catch {
            guard sessionGeneration == notificationSession else { return }
            notificationAuthorizationRequested = false
        }
    }

    private func completeAuthentication(with user: Person) async {
        if isAuthenticated, currentUser.id != user.id { pendingSecureInvite = nil }
        secureInvitationAssignmentID = nil
        legacyRouting?.prepareForAccountRestoration(user.id)
        // Keep interactive sign-in on its original button while account setup finishes.
        let retainWelcome = phase == .welcome && isWorking
        // Revoke the old UI and callbacks before any throwing storage setup.
        sessionGeneration = UUID()
        notificationCoordinator.invalidateSession()
        isWorking = false
        let authentication = sessionGeneration
        deviceTokenSaveOperationID = UUID()
        notificationAuthorizationRequested = false
        profileObservation?.cancel(); profileObservation = nil
        resetConversationState(discardShares: false)
        encryption?.invalidate()
        currentUser = user
        isAuthenticated = true
        profileIsReady = false
        conversationAssignmentResolved = false
        phase = retainWelcome ? .welcome : .restoringConversation
        do { try encryption?.beginAccountSession(user.id) }
        catch {
            phase = .pairing
            errorMessage = "Secure storage is unavailable. Try again or sign out."
            return
        }
        observeConversationAssignment()

        do {
            try await profiles.saveProfile(user)
            guard sessionGeneration == authentication else { return }
            try await encryption?.refreshAccountRequirements()
            guard sessionGeneration == authentication else { return }
            profileIsReady = true
            routeResolvedConversationAssignment()
            if let pendingDeviceToken {
                await receiveDeviceToken(pendingDeviceToken)
                guard sessionGeneration == authentication else { return }
            }
            await configureNotifications()
        } catch {
            guard sessionGeneration == authentication else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func observeConversationAssignment() {
        profileObservation?.cancel()
        let session = sessionGeneration
        profileObservation = profiles.observeConversationID(
            for: currentUser.id
        ) { [weak self] result in
            guard let self, self.isAuthenticated, self.sessionGeneration == session else { return }
            let assignment = UUID()
            self.conversationAssignmentGeneration = assignment
            switch result {
            case let .success(conversationID):
                self.conversationAssignmentResolved = true
                self.secureInvitationAssignmentID = conversationID
                self.routeResolvedConversationAssignment()
            case let .failure(error):
                self.errorMessage = error.localizedDescription
                if self.phase == .restoringConversation {
                    self.phase = .pairing
                }
            }
        }
    }

    private func routeResolvedConversationAssignment() {
        guard conversationAssignmentResolved, encryption == nil || profileIsReady else { return }
        let session = sessionGeneration, assignment = conversationAssignmentGeneration
        let conversationID = secureInvitationAssignmentID
        self.rejectSecureInvitationForExistingConnection()
        if self.encryption?.resetRecoveryBlocked == true {
            self.phase = .pairing
            return
        }
        if self.encryption != nil, conversationID == nil,
           let departed = self.conversationID ?? self.secureConversationWaitingID
            ?? self.encryption?.pairingClient?.completedCapsule?.conversationID {
            // A profile callback may be cached. Revoke the route, then require independent server proof.
            self.resetConversationState(discardShares: false)
            self.secureConversationWaitingID = departed
            self.phase = .pairing
            Task {
                guard self.sessionGeneration == session,
                      self.conversationAssignmentGeneration == assignment else { return }
                await self.finishSecureConversationDeletion(departed)
            }
            return
        }
        if let opening = self.secureConversationWaitingID, opening != conversationID {
            self.secureOpeningGeneration = UUID()
            self.openingConversationID = nil
            self.secureConversationIsOpening = false
            self.encryption?.cancelOpeningConversation()
            self.secureConversationWaitingID = nil
            self.phase = .pairing
        }
        if let conversationID {
            guard
                conversationID
                    != self.deletedConversationIDAwaitingAssignmentClear
            else {
                return
            }
            self.deletedConversationIDAwaitingAssignmentClear = nil
            self.pendingPairingCode = nil
            Task {
                guard self.sessionGeneration == session, self.conversationAssignmentGeneration == assignment else { return }
                await self.enterConversation(conversationID)
            }
        } else if self.conversationID != nil {
            self.beginConversationTeardown(
                self.conversationID,
                deletionWasObserved: true
            )
            self.transitionToPairing()
        } else if self.replayPendingPairingCodeIfPossible() {
            return
        } else if self.phase == .restoringConversation || self.phase == .welcome {
            self.phase = .pairing
        }
    }

    @discardableResult
    private func replayPendingPairingCodeIfPossible() -> Bool {
        guard encryption?.requiresSecurePairing != true else { pendingPairingCode = nil; return false }
        guard
            profileIsReady,
            conversationAssignmentResolved,
            let pendingPairingCode
        else {
            return false
        }

        self.pendingPairingCode = nil
        phase = .pairing
        Task {
            await joinConversation(code: pendingPairingCode)
        }
        return true
    }

    /// Reconcile an SDK auth-change event without mutating the new account's remote state.
    /// Key conflicts use secureSessionInvalidated() and remain in the waiting/retry flow.
    func reconcileSecureAuthentication() async {
        sessionGeneration = UUID()
        notificationCoordinator.invalidateSession()
        let recovery = sessionGeneration
        profileObservation?.cancel(); profileObservation = nil
        resetConversationState(discardShares: false)
        encryption?.invalidate()
        deviceTokenSaveOperationID = UUID()
        notificationAuthorizationRequested = false
        isWorking = false
        isAuthenticated = false
        profileIsReady = false
        conversationAssignmentResolved = false
        pendingSecureInvite = nil
        secureInvitationAssignmentID = nil
        pendingPairingCode = nil
        currentUser = Person(id: "signed-out", displayName: "You", initials: "Y")
        phase = .restoringConversation
        let restored = await auth.restoreCurrentUser()
        guard sessionGeneration == recovery else { return }
        let current = auth.currentUser
        let actual = current?.id == restored?.id ? restored : current
        if let actual {
            await completeAuthentication(with: actual)
        } else {
            await notificationCoordinator.resetForSignOut()
            guard sessionGeneration == recovery else { return }
            resetForSignedOutSession()
        }
    }

    func secureSessionInvalidated() {
        guard encryption?.session == nil, phase == .conversation, let target = conversationID else { return }
        resetConversationState()
        secureConversationWaitingID = target
        phase = .pairing
    }

    func finishSecureConversationDeletion(_ target: String) async {
        guard let encryption, isAuthenticated, !isWorking, !encryption.resetRecoveryBlocked else { return }
        let token = sessionGeneration, owner = currentUser.id
        isWorking = true
        defer { if sessionGeneration == token { isWorking = false } }
        do {
            try await encryption.verifyAndFinishConversationDeletion(expectedConversationID: target)
            guard sessionGeneration == token, currentUser.id == owner else { return }
            if let current = conversationID ?? secureConversationWaitingID, current != target { return }
            resetConversationState()
            deletedConversationIDAwaitingAssignmentClear = target
            phase = .pairing
        } catch {
            guard sessionGeneration == token, currentUser.id == owner else { return }
            if let current = conversationID ?? secureConversationWaitingID, current != target { return }
            // Cached disappearance and unavailable proof remain non-destructive waits.
            if encryption.resetRecoveryBlocked {
                secureConversationWaitingID = target
                phase = .pairing
                errorMessage = encryption.resetErrorMessage
            }
        }
    }

    var secureResetConversationID: String? {
        encryption?.resetCheckpoint?.conversationID ?? conversationID ?? secureConversationWaitingID
            ?? encryption?.pairingClient?.completedCapsule?.conversationID
    }

    var secureResetTarget: SecureConversationResetTarget? {
        guard let conversation = secureResetConversationID else { return nil }
        return SecureConversationResetTarget(accountID: currentUser.id, conversationID: conversation, sessionID: sessionGeneration)
    }

    /// Existing settings dialogs capture this even for legacy conversations.
    func stageAttachmentData(_ data: Data, kind: PendingShare.Kind, suggestedName: String? = nil,
                             preferredExtension: String? = nil, contentTypeIdentifier: String? = nil) throws -> PendingShare {
        guard let target = attachmentPreparationTarget, isCurrentAttachmentPreparation(target) else { throw PendingShareStoreError.accountMismatch }
        let staged = try attachmentDrafts.stageData(.init(bytes: data, kind: kind, suggestedName: suggestedName,
            preferredExtension: preferredExtension, contentTypeIdentifier: contentTypeIdentifier), target)
        guard isCurrentAttachmentPreparation(target), staged.conversationOwnerID?.utf8.elementsEqual(target.accountID.utf8) == true,
            staged.targetConversationID?.utf8.elementsEqual(target.conversationID.utf8) == true else {
            attachmentDrafts.discard([staged]); throw PendingShareStoreError.accountMismatch
        }
        return staged
    }
    func stageAttachmentFile(from url: URL, kind: PendingShare.Kind, suggestedName: String? = nil,
                             contentTypeIdentifier: String? = nil) throws -> PendingShare {
        guard let target = attachmentPreparationTarget, isCurrentAttachmentPreparation(target) else { throw PendingShareStoreError.accountMismatch }
        let staged = try attachmentDrafts.stageFile(.init(url: url, kind: kind, suggestedName: suggestedName,
            contentTypeIdentifier: contentTypeIdentifier), target)
        guard isCurrentAttachmentPreparation(target), staged.conversationOwnerID?.utf8.elementsEqual(target.accountID.utf8) == true,
            staged.targetConversationID?.utf8.elementsEqual(target.conversationID.utf8) == true else {
            attachmentDrafts.discard([staged]); throw PendingShareStoreError.accountMismatch
        }
        return staged
    }
    func stagedAttachmentURL(for share: PendingShare) throws -> URL { try attachmentDrafts.resolve(share) }
    func discardAttachmentDrafts(for shares: [PendingShare]) { attachmentDrafts.discard(shares) }

    var attachmentPreparationTarget: SecureConversationResetTarget? { conversationDeletionTarget }
    func isCurrentAttachmentPreparation(_ target: SecureConversationResetTarget) -> Bool {
        phase == .conversation && target == attachmentPreparationTarget
    }

    var conversationDeletionTarget: SecureConversationResetTarget? {
        guard let conversationID else { return nil }
        return SecureConversationResetTarget(accountID: currentUser.id, conversationID: conversationID, sessionID: sessionGeneration)
    }
    func deleteConversation(confirmed target: SecureConversationResetTarget) async {
        guard target == conversationDeletionTarget else { return }
        await deleteConversation()
    }

    /// Retained for stale callers; conversation destruction is no longer a product action.
    func resetSecureConversation(confirmation: String) async {
        guard let target = secureResetTarget else { return }
        await resetSecureConversation(target, confirmation: confirmation)
    }

    func resetSecureConversation(_ target: SecureConversationResetTarget, confirmation: String) async {
        errorMessage = "Conversation deletion is unavailable."
    }

    func retrySecureReset() async {
        guard let encryption, encryption.resetRecoveryBlocked, isAuthenticated, !isWorking else { return }
        guard encryption.resetCheckpoint?.phase == .localCleanup else {
            errorMessage = "Conversation deletion is unavailable."
            return
        }
        await performSecureReset(target: encryption.resetCheckpoint?.conversationID, retry: true, services: encryption)
    }

    private func performSecureReset(target: String?, retry: Bool, services: EncryptedAppServices) async {
        let token = sessionGeneration, owner = currentUser.id
        isWorking = true
        defer { if sessionGeneration == token { isWorking = false } }
        errorMessage = nil
        // Revoke visible plaintext immediately. Durable drafts are removed only after confirmed deletion.
        resetConversationState(discardShares: false)
        secureConversationWaitingID = target
        phase = .pairing
        let deleteRemote: @MainActor (String) async throws -> String = { [weak self] expected in
            guard let self, self.sessionGeneration == token, self.currentUser.id == owner,
                  self.isAuthenticated else { throw EncryptedMessagingError.inactiveSession }
            // The native scoped implementation validates the callable's exact returned conversation ID.
            try await self.pairing.deleteConversation(expectedConversationID: expected)
            guard self.sessionGeneration == token, self.currentUser.id == owner,
                  self.isAuthenticated else { throw EncryptedMessagingError.inactiveSession }
            return expected
        }
        do {
            if retry { try await services.retryConversationReset(deleteRemote: deleteRemote) }
            else if let target { try await services.resetConversation(expectedConversationID: target, deleteRemote: deleteRemote) }
            guard sessionGeneration == token, currentUser.id == owner else { return }
            resetConversationState()
            deletedConversationIDAwaitingAssignmentClear = target
            phase = .pairing
        } catch {
            guard sessionGeneration == token, currentUser.id == owner else { return }
            secureConversationWaitingID = target
            phase = .pairing
            errorMessage = services.resetErrorMessage ?? "The reset could not finish. Try again."
        }
    }

    func refreshSecureConnection() async {
        guard let encryption, !isWorking, !encryption.resetRecoveryBlocked else { return }
        if encryption.pairingClient == nil {
            await completeAuthentication(with: currentUser)
            return
        }
        await encryption.pairingClient?.advance()
        if let target = secureConversationWaitingID ?? encryption.pairingClient?.completedCapsule?.conversationID {
            await enterConversation(target)
        }
    }

    private func refreshLegacyConversationRouting() {
        guard let legacyRouting, encryption == nil, phase == .conversation,
              let target = conversationID, legacyRoutingTask == nil else { return }
        let token = sessionGeneration, account = currentUser.id, operation = UUID()
        legacyRoutingOperation = operation
        legacyRoutingTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.legacyRoutingOperation == operation { self.legacyRoutingTask = nil } }
            let current = { [weak self] in
                guard let self else { return false }
                return self.sessionGeneration == token && self.legacyRoutingOperation == operation
                    && self.currentUser.id.utf8.elementsEqual(account.utf8)
                    && self.conversationID?.utf8.elementsEqual(target.utf8) == true
            }
            do {
                try await legacyRouting.verifyAndPublish(accountID: account, conversationID: target, isCurrent: current)
                guard current() else { return }
                self.reloadPendingShares()
                await self.sendQueuedSharesIfPossible()
            } catch {
                guard current() else { return }
                if LegacyConversationTargetPublisher.revokesRoute(error) {
                    self.resetConversationState(discardShares: false)
                    self.phase = .pairing
                    self.errorMessage = error.localizedDescription
                }
                // Offline proof failure keeps an already verified local draft route and cached timeline.
            }
        }
    }

    private func enterConversation(_ conversationID: String) async {
        guard
            conversationID
                != self.deletedConversationIDAwaitingAssignmentClear
        else {
            return
        }
        guard openingConversationID != conversationID else { return }
        if self.conversationID == conversationID, phase == .conversation {
            refreshLegacyConversationRouting()
            return
        }

        // Revoke the old viewer before any asynchronous opening or partner lookup.
        messagePins?.stop(); messagePins = nil
        clearLocationObservation()
        resolvedPartnerScope = nil
        let profileScope = PartnerIdentityScope(accountID: currentUser.id, conversationID: conversationID)
        let profileSession = sessionGeneration
        let secureOpening = UUID()
        secureOpeningGeneration = secureOpening
        openingConversationID = conversationID
        secureConversationIsOpening = encryption != nil
        defer {
            if secureOpeningGeneration == secureOpening {
                openingConversationID = nil
                secureConversationIsOpening = false
            }
        }
        if let encryption {
            secureConversationWaitingID = conversationID
            do {
                try await encryption.openConversation(conversationID)
                guard secureOpeningGeneration == secureOpening else { return }
                secureConversationWaitingID = nil
            } catch {
                guard secureOpeningGeneration == secureOpening else { return }
                // Keep the assignment while iCloud may still be delivering its key.
                // No content service is selected on failure.
                phase = .pairing
                return
            }
        }

        do {
            try legacyRouting?.restoreVerifiedTarget(accountID: currentUser.id, conversationID: conversationID)
        } catch {
            if LegacyConversationTargetPublisher.revokesRoute(error) {
                resetConversationState(discardShares: false)
                phase = .pairing; errorMessage = error.localizedDescription
                return
            }
            // Unavailable local routing must not hold the cached text timeline behind I/O.
        }
        self.conversationID = conversationID
        SharedConversationStore.activeConversationID = conversationID
        notificationCoordinator.setActiveConversation(
            conversationReadVisibility.suppressesForegroundAlerts ? conversationID : nil
        )
        lastMarkedDeliveredMessageID = nil
        lastMarkedReadMessageID = nil

        observeConversationContent(conversationID)
        pairingCode = ""
        pairingCodeExpiresAt = nil
        phase = .conversation
        restoreVoiceMessageDraft()
        refreshLegacyConversationRouting()
        // The verified chat is already visible; a slow name lookup cannot replace
        // onboarding or delay content. Awaiting here retains navigation fencing.
        do {
            let fetched = try await profiles.fetchPartner(conversationID: conversationID, currentUserID: profileScope.accountID)
            guard !Task.isCancelled, secureOpeningGeneration == secureOpening,
                  sessionGeneration == profileSession, currentUser.id == profileScope.accountID,
                  self.conversationID == profileScope.conversationID else { return }
            partner = fetched
            resolvedPartnerScope = profileScope
        } catch {
            guard secureOpeningGeneration == secureOpening else { return }
            // Keep the neutral placeholder without interrupting verified content.
        }
        reloadPendingShares()
        await encryption?.retryPendingMessages()
        guard secureOpeningGeneration == secureOpening else { return }
        await sendQueuedSharesIfPossible()
    }

    /// Distance is between the two published primary-phone points, never this Mac's position.
    func mutualLocationPresentation(at date: Date = .now) -> MutualLocationPresentation? {
        guard phase == .conversation else { return nil }
        return locationSnapshot.mutualPresentation(currentUserID: currentUser.id,
            partnerID: partner.id, now: date)
    }

    private func clearLocationObservation() {
        locationObservationGeneration = UUID()
        locationObservation?.cancel()
        locationObservation = nil
        locationSnapshot = .empty
    }

    private func observeLocations(_ conversationID: String) {
        clearLocationObservation()
        let observation = locationObservationGeneration
        let session = sessionGeneration
        let account = currentUser.id
        let subscription = locationViewer.observe(accountID: account, conversationID: conversationID) { [weak self] result in
            guard let self, self.isAuthenticated, self.sessionGeneration == session,
                  self.currentUser.id == account, self.conversationID == conversationID,
                  self.locationObservationGeneration == observation else { return }
            switch result {
            case .success(let snapshot):
                self.locationSnapshot = snapshot
            case .failure(let error):
                self.clearLocationObservation()
                self.presentConversationError(error, conversationID: conversationID)
            }
        }
        // A provider can fail synchronously before returning its cancellation handle.
        guard locationObservationGeneration == observation else { subscription.cancel(); return }
        locationObservation = subscription
    }

    func loadOlderMessages() { historyController?.older() }
    func returnToRecentMessageHistory() { historyController?.latest() }

    private func observeConversationContent(_ conversationID: String) {
        let session = sessionGeneration
        messagePins?.stop()
        let account = currentUser.id
        let pins = MessagePinsController(provider: messaging, conversationID: conversationID, currentUserID: account) { [weak self] error in
            guard let self, self.sessionGeneration == session, self.currentUser.id == account,
                  self.conversationID == conversationID else { return }
            self.errorMessage = error.localizedDescription
        }
        messagePins = pins
        pins.start()
        observeLocations(conversationID)
        messageObservation?.cancel()
        let receive: (Result<MessageHistorySnapshot, Error>) -> Void = { [weak self] result in
            guard
                let self,
                self.conversationID == conversationID,
                self.sessionGeneration == session
            else {
                return
            }
            switch result {
            case let .success(snapshot):
                let messages = snapshot.messages
                if !snapshot.isFromCache, !snapshot.reactionsAreFromCache {
                    self.receiveObservedReactions(messages)
                } else { self.reactionSnapshotIsCurrent = false }
                self.replyContextMessages = snapshot.replyMessages
                self.submissionLedger.observe(messages, queuedIDs: Set(self.queuedShares.map(\.id)))
                var merged = messages
                let remoteIDs = Set(messages.map(\.id))
                merged += self.submissionLedger.pending.values.filter { !remoteIDs.contains($0.id) }
                self.messages = self.submissionLedger.ordered(merged)
                self.presentComposerAttachments()
                self.composerReply.accept(messages: self.messages, context: self.replyContextMessages)
                if self.historyIsRecent,
                    let latestIncoming = messages.last(
                        where: { $0.senderID != self.currentUser.id }
                    )
                {
                    self.acknowledge(
                        latestIncoming,
                        markAsRead: self.conversationIsVisible
                            && self.appIsActive
                    )
                }
            case let .failure(error):
                self.presentConversationError(
                    error,
                    conversationID: conversationID
                )
            }
        }

        do {
            if let provider = messaging as? any MessageHistoryWindowProviding,
               try provider.supportsHistoryWindows(conversationID: conversationID) {
                historyController?.cancel()
                let controller = ConversationHistoryController(provider: provider, conversationID: conversationID,
                    accountID: currentUser.id, onWindow: { [weak self] result in
                        guard let self, self.sessionGeneration == session, self.conversationID == conversationID else { return }
                        switch result {
                        case .success(let snapshot): receive(.success(snapshot))
                        case .failure(let error): receive(.failure(error))
                        }
                    }, onNewest: { [weak self] rows in
                        guard let self, self.sessionGeneration == session, self.conversationID == conversationID,
                              let incoming = rows.last(where: { $0.senderID != self.currentUser.id }) else { return }
                        self.acknowledge(incoming, markAsRead: self.conversationIsVisible && self.appIsActive && self.historyIsRecent)
                    }, onError: { [weak self] error in
                        guard let self, self.sessionGeneration == session else { return }
                        self.presentConversationError(error, conversationID: conversationID)
                    })
                historyController = controller; controller.start()
            } else {
                messageObservation = messaging.observeMessageHistory(conversationID: conversationID,
                    currentUserID: currentUser.id, messageLimit: nil, onChange: receive)
            }
        } catch { receive(.failure(error)) }

        typingObservation?.cancel()
        typingObservation = messaging.observeTyping(
            conversationID: conversationID,
            currentUserID: currentUser.id
        ) { [weak self] result in
            guard
                let self,
                self.conversationID == conversationID,
                self.sessionGeneration == session
            else {
                return
            }
            switch result {
            case let .success(isTyping):
                self.isPartnerTyping = isTyping
            case let .failure(error):
                self.presentConversationError(
                    error,
                    conversationID: conversationID
                )
            }
        }
    }

    private func transitionToPairing() {
        guard isAuthenticated else { return }
        resetConversationState()
        phase = .pairing
    }

    private func resetForSignedOutSession() {
        sessionGeneration = UUID()
        notificationCoordinator.invalidateSession()
        deviceTokenSaveOperationID = UUID()
        notificationAuthorizationRequested = false
        encryption?.invalidate()
        pendingSecureInvite = nil
        secureInvitationAssignmentID = nil
        profileObservation?.cancel()
        profileObservation = nil
        resetConversationState()
        isAuthenticated = false
        profileIsReady = false
        conversationAssignmentResolved = false
        pendingPairingCode = nil
        deletedConversationIDAwaitingAssignmentClear = nil
        currentUser = Person(
            id: "signed-out",
            displayName: "You",
            initials: "Y"
        )
        phase = .welcome
    }

    private func resetConversationState(discardShares: Bool = true) {
        resolvedPartnerScope = nil
        voiceRecorder.detach()
        clearLocationObservation()
        legacyRoutingOperation = UUID()
        legacyRoutingTask?.cancel(); legacyRoutingTask = nil
        secureOpeningGeneration = UUID()
        openingConversationID = nil
        secureConversationIsOpening = false
        if let conversationID { try? encryption?.closeConversation(conversationID, deleted: false) }
        secureConversationWaitingID = nil
        messageObservation?.cancel()
        messageObservation = nil
        messagePins?.stop()
        messagePins = nil
        historyController?.cancel()
        historyController = nil
        historyViewportAtLatest = false
        typingObservation?.cancel()
        typingObservation = nil
        typingStopTask?.cancel()
        typingStopTask = nil
        lastTypingRefreshAt = nil
        conversationID = nil
        openingConversationID = nil
        SharedConversationStore.activeConversationID = nil
        notificationCoordinator.setActiveConversation(nil)
        messages = []
        submissionLedger = LocalSubmissionLedger()
        composerSubmissionFence = ComposerSubmissionFence()
        preparedDraftAttachmentIDs = [:]
        composerTextDisplayDate = nil
        pendingShareTimelineStatuses = [:]
        observedReactionSnapshot = nil
        reactionSnapshotIsCurrent = false
        pendingReactionBursts = []
        reactionBurstEvent = nil
        replyContextMessages = [:]
        composerReply.clear()
        conversationIsSearching = false
        conversationObscurations = []
        attachmentPreviewSources = []
        draft = ""
        replyToMessageID = nil
        isPartnerTyping = false
        pairingCode = ""
        pairingCodeExpiresAt = nil
        partner = Person(
            id: "partner",
            displayName: "Your person",
            initials: "YP"
        )
        lastMarkedDeliveredMessageID = nil
        lastMarkedReadMessageID = nil
        conversationIsVisible = false
        for share in failedAttachmentShares.values {
            discardAttachmentDrafts(for: [share])
        }
        failedAttachmentShares = [:]
        if discardShares { discardPendingShares() }
        queuedShares = []
        composerShareIDs = []
        preparedDraftConversationIDs = [:]
        pendingShare = nil
        queuedShareErrorMessage = nil
        isSendingQueuedShares = false
        isUploading = false
        conversationBeingTornDownID = nil
        conversationDeletionWasObserved = false
    }

    private func beginConversationTeardown(
        _ conversationID: String?,
        deletionWasObserved: Bool
    ) {
        guard let conversationID else { return }

        if conversationBeingTornDownID != conversationID {
            conversationBeingTornDownID = conversationID
            composerReply.clear()
            clearLocationObservation()
            messageObservation?.cancel()
            messageObservation = nil
            messagePins?.stop()
            messagePins = nil
            historyController?.cancel()
            historyController = nil
            historyViewportAtLatest = false
            typingObservation?.cancel()
            typingObservation = nil
            typingStopTask?.cancel()
            typingStopTask = nil
            isPartnerTyping = false
            notificationCoordinator.setActiveConversation(nil)
        }
        if deletionWasObserved {
            conversationDeletionWasObserved = true
            deletedConversationIDAwaitingAssignmentClear = conversationID
        }
    }

    private func cancelConversationTeardownAfterFailure(
        _ conversationID: String
    ) {
        guard self.conversationID == conversationID else { return }
        conversationBeingTornDownID = nil
        conversationDeletionWasObserved = false
        deletedConversationIDAwaitingAssignmentClear = nil
        if encryption != nil {
            phase = .restoringConversation
            Task { await self.enterConversation(conversationID) }
        } else {
            observeConversationContent(conversationID)
        }
        notificationCoordinator.setActiveConversation(
            conversationReadVisibility.suppressesForegroundAlerts ? conversationID : nil
        )
    }

    private func presentConversationError(
        _ error: any Error,
        conversationID: String
    ) {
        if
            (
                conversationBeingTornDownID == conversationID
                    || deletedConversationIDAwaitingAssignmentClear
                        == conversationID
            ),
            ConversationTeardownErrorPolicy.isExpectedLateFailure(error)
        {
            return
        }
        errorMessage = error.localizedDescription
    }

    private func replaceMessage(_ replacement: ChatMessage) {
        if submissionLedger.pending[replacement.id] != nil { submissionLedger.pending[replacement.id] = replacement }
        // Listener content can arrive before send returns; preserve its server data.
        guard
            let index = messages.firstIndex(
                where: { $0.id == replacement.id }
            )
        else {
            return
        }
        if submissionLedger.observedIDs.contains(replacement.id), replacement.deliveryState == .sent {
            if messages[index].deliveryState == .sending {
                messages[index].deliveryState = .sent
                if messages[index].attachment?.storagePath == nil { messages[index].attachment = replacement.attachment }
            }
            return
        }
        messages[index] = replacement
    }

    private func upsertMessage(_ message: ChatMessage) {
        submissionLedger.register(message, after: messages)
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            if submissionLedger.observedIDs.contains(message.id) {
                messages[index].deliveryState = message.deliveryState
                if messages[index].attachment?.storagePath == nil { messages[index].attachment = message.attachment }
            } else { messages[index] = message }
        } else {
            messages.append(message)
        }
    }

    private func reloadPendingShares() {
        do {
            queuedShares = try loadPendingShares().filter {
                $0.conversationOwnerID == nil || $0.conversationOwnerID == currentUser.id
            }
            composerShareIDs.formIntersection(queuedShares.map(\.id))
            pendingShare = queuedShares.first
            let ids = Set(queuedShares.map(\.id))
            pendingShareTimelineStatuses = pendingShareTimelineStatuses.filter { ids.contains($0.key) }
            for share in queuedShares where pendingShareTimelineStatuses[share.id] == nil {
                pendingShareTimelineStatuses[share.id] = .waiting
            }
            presentComposerAttachments()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func sendQueuedSharesIfPossible() async {
        let sendingSession = sessionGeneration
        let sendingUserID = currentUser.id
        guard
            isAuthenticated,
            let targetConversationID = conversationID?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !targetConversationID.isEmpty
        else {
            return
        }

        let staleShares = queuedShares.filter {
            $0.targetConversationID != targetConversationID
        }
        if !staleShares.isEmpty {
            do {
                let staleIDs = Set(staleShares.map(\.id))
                try acknowledgePendingShares(staleIDs)
                queuedShares.removeAll { staleIDs.contains($0.id) }
                messages.removeAll { staleIDs.contains($0.id) }
                for id in staleIDs { submissionLedger.remove(id); pendingShareTimelineStatuses[id] = nil }
                composerSubmissionFence.release(staleIDs)
                errorMessage =
                    "A shared item was not sent because its original conversation is no longer active."
                reloadPendingShares()
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }

        guard queuedShareErrorMessage == nil else {
            return
        }
        let sendableShares = queuedShares.prefix { composerSubmissionFence.allows($0.id) }.filter {
            $0.targetConversationID == targetConversationID
        }
        guard !sendableShares.isEmpty, !isSendingQueuedShares else {
            return
        }

        isSendingQueuedShares = true
        queuedShareErrorMessage = nil
        let attemptedShareIDs = Set(sendableShares.map(\.id))
        defer {
            if sessionGeneration == sendingSession {
                isSendingQueuedShares = false
                reloadPendingShares()
                if queuedShareErrorMessage == nil, queuedShares.contains(
                    where: {
                        !attemptedShareIDs.contains($0.id)
                            && $0.targetConversationID == targetConversationID
                            && composerSubmissionFence.allows($0.id)
                    }
                ) {
                    Task {
                        guard sessionGeneration == sendingSession else { return }
                        await sendQueuedSharesIfPossible()
                    }
                }
            }
        }

        for share in sendableShares {
            guard sessionGeneration == sendingSession else { return }
            guard conversationID == targetConversationID else {
                errorMessage =
                    "A shared item was not sent because its original conversation is no longer active."
                break
            }
            guard composerSubmissionFence.allows(share.id) else { break }
            if case .failed? = pendingShareTimelineStatuses[share.id] { break }
            do {
                try AttachmentDraftDependencies.validateProvenance(share, accountID: sendingUserID,
                    conversationID: targetConversationID, requiresBound: encryption != nil)
            } catch {
                pendingShareTimelineStatuses[share.id] = .failed(error.localizedDescription)
                queuedShareErrorMessage = error.localizedDescription
                break
            }
            pendingShareTimelineStatuses[share.id] = .sending
            var outgoingMessage: ChatMessage?
            if share.kind != .text && share.kind != .url {
                let pending = messages.first { $0.id == share.id } ?? pendingMessage(for: share)
                var sending = pending
                sending.deliveryState = .sending
                outgoingMessage = sending
                upsertMessage(sending)
            }
            do {
                let message: ChatMessage
                if share.kind == .text || share.kind == .url {
                    guard let body = share.text, !body.isEmpty else {
                        throw PendingShareStoreError.emptyAttachment
                    }
                    message = ChatMessage(
                        id: share.id,
                        senderID: sendingUserID,
                        kind: .forText(body),
                        body: body,
                        deliveryState: .sending,
                        deliveryMode: share.deliveryMode
                    )
                } else {
                    let attachment = try await attachments.upload(
                        share,
                        messageID: share.id,
                        conversationID: targetConversationID,
                        ownerID: sendingUserID
                    )
                    var ready = outgoingMessage ?? pendingMessage(for: share)
                    ready.attachment = attachment
                    ready.body = attachment.fileName
                    message = ready
                }
                guard sessionGeneration == sendingSession else { return }
                guard conversationID == targetConversationID else {
                    try? acknowledgePendingShares([share.id])
                    queuedShares.removeAll { $0.id == share.id }
                    messages.removeAll { $0.id == share.id }
                    errorMessage =
                        "A shared item was not sent because its original conversation is no longer active."
                    break
                }

                outgoingMessage = message
                upsertMessage(message)
                let sent = try await messaging.send(
                    message,
                    conversationID: targetConversationID
                )
                guard sessionGeneration == sendingSession else { return }
                try acknowledgePendingShares([share.id])
                pendingShareTimelineStatuses[share.id] = nil
                queuedShares.removeAll { $0.id == share.id }
                if conversationID == targetConversationID {
                    replaceMessage(sent)
                } else {
                    messages.removeAll { $0.id == share.id }
                    errorMessage =
                        "A shared item finished sending to its original conversation after the active conversation changed."
                    break
                }
            } catch {
                guard sessionGeneration == sendingSession else { return }
                if conversationID != targetConversationID {
                    try? acknowledgePendingShares([share.id])
                    queuedShares.removeAll { $0.id == share.id }
                    messages.removeAll { $0.id == share.id }
                    errorMessage =
                        "A shared item was not retried after the active conversation changed."
                    break
                }
                if var failed = outgoingMessage {
                    failed.deliveryState = .failed
                    replaceMessage(failed)
                }
                pendingShareTimelineStatuses[share.id] = .failed(error.localizedDescription)
                queuedShareErrorMessage = error.localizedDescription
                break
            }
        }
    }

    private func discardFailedAttachmentShare(_ messageID: UUID) {
        guard let share = failedAttachmentShares.removeValue(
            forKey: messageID
        ) else {
            return
        }
        discardAttachmentDrafts(for: [share])
    }

    private func stopPublishingTyping() {
        typingStopTask?.cancel()
        typingStopTask = nil
        lastTypingRefreshAt = nil
        guard let conversationID else { return }
        Task {
            try? await messaging.setTyping(
                conversationID: conversationID,
                userID: currentUser.id,
                isTyping: false
            )
        }
    }

    private func stopPublishingTypingAndWait() async {
        typingStopTask?.cancel()
        typingStopTask = nil
        lastTypingRefreshAt = nil
        guard let conversationID else { return }
        try? await messaging.setTyping(
            conversationID: conversationID,
            userID: currentUser.id,
            isTyping: false
        )
    }

    private func acknowledge(
        _ message: ChatMessage,
        markAsRead: Bool
    ) {
        guard let conversationID else { return }
        let needsDelivered = lastMarkedDeliveredMessageID != message.id
        let needsRead = markAsRead && conversationReadVisibility.allowsReadAcknowledgment && lastMarkedReadMessageID != message.id
        if needsDelivered {
            lastMarkedDeliveredMessageID = message.id
        }
        guard needsDelivered || needsRead else { return }

        let receiptSession = sessionGeneration
        let receiptUserID = currentUser.id
        Task {
            guard sessionGeneration == receiptSession, currentUser.id == receiptUserID,
                  self.conversationID == conversationID else { return }
            do {
                if needsDelivered {
                    try await messaging.markDelivered(
                        conversationID: conversationID,
                        userID: receiptUserID,
                        messageID: message.id.uuidString
                    )
                }
                guard sessionGeneration == receiptSession, currentUser.id == receiptUserID,
                      self.conversationID == conversationID else { return }
                if needsRead, conversationReadVisibility.allowsReadAcknowledgment {
                    lastMarkedReadMessageID = message.id
                    try await messaging.markRead(
                        conversationID: conversationID,
                        userID: receiptUserID,
                        messageID: message.id.uuidString
                    )
                }
            } catch {
                guard sessionGeneration == receiptSession, currentUser.id == receiptUserID,
                      self.conversationID == conversationID || self.conversationID == nil else { return }
                if needsDelivered, lastMarkedDeliveredMessageID == message.id {
                    lastMarkedDeliveredMessageID = nil
                }
                if needsRead, lastMarkedReadMessageID == message.id {
                    lastMarkedReadMessageID = nil
                }
                presentConversationError(
                    error,
                    conversationID: conversationID
                )
            }
        }
    }

    private func receiveDeviceToken(_ token: String) async {
        let tokenSession = sessionGeneration
        let operation = UUID()
        deviceTokenSaveOperationID = operation
        pendingDeviceToken = token
        guard isAuthenticated else { return }
        do {
            let owner = currentUser.id
            try await BoundedNotificationRetry.run(configuration: notificationRetryConfiguration) { [self] in
                guard sessionGeneration == tokenSession, deviceTokenSaveOperationID == operation,
                      isAuthenticated, currentUser.id == owner else { throw CancellationError() }
                try await profiles.saveDeviceToken(token, userID: owner)
            }
            guard sessionGeneration == tokenSession, deviceTokenSaveOperationID == operation else { return }
            if pendingDeviceToken == token {
                pendingDeviceToken = nil
            }
        } catch {
            guard sessionGeneration == tokenSession, deviceTokenSaveOperationID == operation else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func handleNotificationAction(
        _ action: MessageNotificationAction
    ) async {
        let notificationSession = sessionGeneration
        let notificationAccountID = currentUser.id
        switch action {
        case let .open(conversationID, _):
            if let conversationID {
                await enterConversation(conversationID)
            }

        case let .reply(text, notificationConversationID, _):
            guard
                let targetConversationID =
                    notificationConversationID ?? conversationID
            else {
                return
            }
            let trimmed = text.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !trimmed.isEmpty else { return }

            if targetConversationID != conversationID {
                await enterConversation(targetConversationID)
            }

            guard sessionGeneration == notificationSession,
                  currentUser.id == notificationAccountID,
                  conversationID == targetConversationID else { return }
            let queuedReply = PendingShare(
                kind: .text,
                text: trimmed,
                conversationID: targetConversationID,
                conversationOwnerID: notificationAccountID
            )
            do {
                try enqueuePendingShares([queuedReply])
                reloadPendingShares()
                await sendQueuedSharesIfPossible()
            } catch {
                guard sessionGeneration == notificationSession else { return }
                errorMessage = error.localizedDescription
            }

        case let .markRead(notificationConversationID, messageID):
            guard
                let targetConversationID =
                    notificationConversationID ?? conversationID
            else {
                return
            }

            if let messageID {
                do {
                    try await messaging.markRead(
                        conversationID: targetConversationID,
                        userID: currentUser.id,
                        messageID: messageID
                    )
                    lastMarkedReadMessageID = UUID(uuidString: messageID)
                } catch {
                    errorMessage = error.localizedDescription
                }
                return
            }

            if targetConversationID != conversationID {
                await enterConversation(targetConversationID)
            }
            let message =
                messages.last {
                    $0.senderID != currentUser.id
                }
            if let message {
                acknowledge(message, markAsRead: true)
            }
        }
    }

    private static func pendingShareKind(
        for contentType: UTType?
    ) -> PendingShare.Kind {
        if contentType?.conforms(to: .image) == true {
            return .image
        }
        if contentType?.conforms(to: .movie) == true {
            return .movie
        }
        return .file
    }
}
