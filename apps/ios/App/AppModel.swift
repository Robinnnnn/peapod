import Foundation
import Observation
import AuthenticationServices
import UIKit
import UniformTypeIdentifiers

enum ConversationObscurationSource: Hashable {
    case rootAlert
    case conversationPresentation
    case sessionActions
    case photo(String)
    case photoGroup(UUID)
}

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case welcome
        case restoringConversation
        case pairing
        case waitingForPartner
        case conversation
        case configurationError
    }

    var phase: Phase = .welcome
    var currentUser = Person(id: "local-user", displayName: "You", initials: "Y")
    var partner = Person(id: "partner", displayName: "Your person", initials: "YP")
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
    var messages: [ChatMessage] = [] {
        didSet {
            if !messages.isEmpty { messageHistoryIsReady = true; messageHistoryLoadFailed = false }
            refreshPinnedReplyTarget()
            messagesRevision &+= 1
        }
    }
    private(set) var messagesRevision = 0
    /// Accepted local rows can be displayed before the network is fresh.
    private(set) var messageHistoryIsReady = false
    private(set) var messageHistoryLoadFailed = false
    private(set) var replyContextMessages: [UUID: ChatMessage] = [:]
    private(set) var hasMoreMessages = false
    private(set) var isLoadingOlderMessages = false
    private(set) var reactionBurstEvent: ReactionBurstEvent?
    var draft = ""
    var replyToMessageID: UUID? {
        didSet {
            if let replyToMessageID {
                if let target = messages.first(where: { $0.id == replyToMessageID })
                    ?? replyContextMessages[replyToMessageID]
                {
                    pinnedReplyTarget = target
                } else if pinnedReplyTarget?.id != replyToMessageID {
                    pinnedReplyTarget = nil
                }
            } else {
                pinnedReplyTarget = nil
            }
        }
    }
    private var pinnedReplyTarget: ChatMessage?
    var isPartnerTyping = false
    var pairingCode = ""
    var pairingCodeExpiresAt: Date?
    var pendingShare: PendingShare?
    var conversationID: String?
    var isWorking = false
    var locationSnapshot = ConnectionLocationSnapshot.empty
    var isPreparingLocationSharing = false
    var shouldOfferLocationSettings = false
    private(set) var isSendingQueuedShares = false
    var queuedShareErrorMessage: String?
    var errorMessage: String?
    private(set) var pendingShareTimelineStatuses:
        [UUID: PendingShareTimelineStatus] = [:]

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
    private var openingConversationID: String?
    private let auth: any AuthProviding
    private let pairing: any PairingProviding
    private let messaging: any MessagingProviding
    private let profiles: any ProfileProviding
    private let attachmentDrafts: AttachmentDraftDependencies
    private let attachments: any AttachmentProviding
    private let outgoingMessageIntentDonor: any OutgoingMessageIntentDonating
    private let notificationCoordinator: any PushNotificationCoordinating
    private let notificationRetryConfiguration:
        NotificationRetryConfiguration
    private let usesFirebase: Bool
    private let configurationIssue: String?
    private let recoverVoiceMessageDrafts: () throws -> Void
    private let enqueuePendingShares: ([PendingShare]) throws -> Void
    private let loadPendingShares: () throws -> [PendingShare]
    private let acknowledgePendingShares: (Set<UUID>) throws -> Void
    private let discardPendingShares: () -> Void
    private let liveLocationService: LiveLocationService
    private let connectionLocations: any ConnectionLocationProviding
    private let reactionBurstReplayStore:
        any ReactionBurstReplayStoring
    private var profileObservation: ServiceObservation?
    private var historyViewportAtLatest = false
    func historyViewportDidChange(isAtLatest: Bool) {
        historyViewportAtLatest = isAtLatest
        guard isAtLatest, historyIsRecent, conversationIsActuallyVisible,
              let incoming = messages.last(where: { $0.senderID != currentUser.id }) else { return }
        acknowledge(incoming, markAsRead: true)
    }
    private(set) var messagePins: MessagePinsController?
    private(set) var historyController: ConversationHistoryController?
    var usesBoundedHistory: Bool { historyController != nil }
    var historyIsLoading: Bool { historyController?.isLoading ?? isLoadingOlderMessages }
    var historyHasOlder: Bool { historyController?.hasOlder ?? hasMoreMessages }
    var historyHasNewer: Bool { historyController?.hasNewer ?? false }
    var historyIsRecent: Bool { historyController?.isRecentVisible ?? true }
    /// Recency of the accepted rows, independent of a pending refresh/search.
    var historyWindowIsRecent: Bool { historyController?.window?.isRecentWindow ?? (historyController == nil) }
    func searchMessageHistory(_ query: String) { historyController?.searchFor(query) }
    func loadMoreSearchResults() { historyController?.moreSearchResults() }
    func loadNewerMessages() { historyController?.newer() }
    func showMessageInHistory(_ id: UUID) {
        searchReturnWindow = nil
        guard let historyController else { loadFullMessageHistory(); return }
        historyController.searchFor("")
        historyController.around(id)
    }
    private var messageObservation: ServiceObservation?
    private var typingObservation: ServiceObservation?
    private var locationObservation: ServiceObservation?
    private var partnerRefreshTask: Task<Void, Never>?
    private var partnerRefreshGeneration = UUID()
    private var sessionGeneration = UUID()
    private var conversationAssignmentGeneration = UUID()
    private var messageObservationGeneration = UUID()
    private var messageLimit: Int? = ConversationHistoryPolicy.pageSize
    private var resolvedMessageLimit: Int? = ConversationHistoryPolicy.pageSize
    private struct SearchReturnWindow { let limit: Int? }
    private var searchReturnWindow: SearchReturnWindow?
    // Presentation positions live only for locally submitted rows in the
    // loaded window. Server timestamps remain authoritative message data.
    private var submissionLedger = LocalSubmissionLedger()
    private var outgoingMessageDisplayDates: [UUID: Date] {
        get { submissionLedger.displayDates }
        set { submissionLedger.displayDates = newValue }
    }
    private var locallyPendingMessages: [UUID: ChatMessage] {
        get { submissionLedger.pending }
        set { submissionLedger.pending = newValue }
    }
    private var observedMessageIDs: Set<UUID> {
        get { submissionLedger.observedIDs }
        set { submissionLedger.observedIDs = newValue }
    }
    private var composerSubmissionFence = ComposerSubmissionFence()
    private var composerAttachmentsWaitingForText: Set<UUID> {
        get { composerSubmissionFence.waiting }
        set {
            composerSubmissionFence = ComposerSubmissionFence()
            composerSubmissionFence.hold(newValue)
        }
    }
    private var queuedShares: [PendingShare] = []
    private var notificationHandlersInstalled = false
    private var notificationRegistrationInFlight = false
    private var notificationRegistrationSucceeded = false
    private var notificationRetryAttempt = 0
    private var notificationRetryTask: Task<Void, Never>?
    private var deviceTokenSaveTask: Task<Bool, Never>?
    private var deviceTokenSaveOperationID: UUID?
    private var pendingDeviceToken: String?
    private var lastMarkedDeliveredMessageID: UUID?
    private var lastMarkedReadMessageID: UUID?
    private var lastTypingRefreshAt: Date?
    private var typingStopTask: Task<Void, Never>?
    private var locationSharingTask: Task<Void, Never>?
    private var locationSharingOperationID: UUID?
    private var locationSharingSourceGeneration: UInt64?
    private var didAttemptLocationSharingRestore = false
    private var hasResolvedLocationSnapshot = false
    private var orphanedLocationCleanupInFlight = false
    private var conversationIsVisible = false
    private var appIsActive = true
    private var conversationObscurationSources:
        Set<ConversationObscurationSource> = []
    private var isAuthenticated = false
    private var pendingPairingCode: String?
    private var profileIsReady = false
    private var conversationAssignmentResolved = false
    private var conversationBeingTornDownID: String?
    private var conversationDeletionWasObserved = false
    private var deletedConversationIDAwaitingAssignmentClear: String?
    private var observedReactionSnapshot: ReactionBurstDetection.Snapshot?
    private var reactionReplayStateIsCurrent = false
    private var pendingReceivedReactionBursts: [ReactionBurstCandidate] = []
    private var pendingLocalReactionBursts: [ReactionBurstCandidate] = []

    init(
        auth: any AuthProviding = LocalAuthService(),
        pairing: any PairingProviding = LocalPairingService(),
        messaging: any MessagingProviding = LocalMessagingService(),
        profiles: any ProfileProviding = LocalProfileService(),
        attachments: any AttachmentProviding = LocalAttachmentService(),
        encryption: EncryptedAppServices? = nil,
        attachmentDrafts: AttachmentDraftDependencies = .native,
        legacyRouting: LegacyConversationTargetPublisher? = nil,
        outgoingMessageIntentDonor: any OutgoingMessageIntentDonating =
            OutgoingMessageIntentDonor(),
        notificationCoordinator: any PushNotificationCoordinating =
            PushNotificationCoordinator.shared,
        notificationRetryConfiguration: NotificationRetryConfiguration =
            .production,
        usesFirebase: Bool = false,
        configurationIssue: String? = nil,
        recoverVoiceMessageDrafts: @escaping () throws -> Void = {
            try VoiceMessageDraftRecovery().recoverAndEnqueue()
        },
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
        liveLocationService: LiveLocationService? = nil,
        connectionLocations: (any ConnectionLocationProviding)? = nil,
        reactionBurstReplayStore:
            (any ReactionBurstReplayStoring)? = nil
    ) {
        self.attachmentDrafts = attachmentDrafts
        self.encryption = encryption
        self.legacyRouting = encryption == nil ? legacyRouting : nil
        self.auth = auth
        self.pairing = pairing
        self.messaging = encryption.map(EncryptedMessagingRouter.init) ?? messaging
        self.profiles = profiles
        self.attachments = encryption.map(EncryptedAttachmentRouter.init) ?? attachments
        self.outgoingMessageIntentDonor = outgoingMessageIntentDonor
        self.notificationCoordinator = notificationCoordinator
        self.notificationRetryConfiguration =
            notificationRetryConfiguration
        self.usesFirebase = usesFirebase
        self.configurationIssue = configurationIssue
        self.recoverVoiceMessageDrafts = recoverVoiceMessageDrafts
        self.enqueuePendingShares = encryption.map { services in { try services.enqueueDrafts($0) } } ?? enqueuePendingShares
        self.loadPendingShares = encryption.map { services in { try services.pendingDrafts() } } ?? loadPendingShares
        self.acknowledgePendingShares = encryption.map { services in { try services.acknowledgeDrafts($0) } } ?? acknowledgePendingShares
        self.discardPendingShares = encryption == nil ? discardPendingShares : {}
        self.liveLocationService =
            liveLocationService ?? LiveLocationService(restorePersistedSessionOnInit: encryption == nil)
        let locationProvider = connectionLocations ?? LocalConnectionLocationService()
        self.connectionLocations = encryption.map { EncryptedLocationRouter($0, legacy: locationProvider) } ?? locationProvider
        self.reactionBurstReplayStore =
            reactionBurstReplayStore
                ?? UserDefaultsReactionBurstReplayStore()
        self.liveLocationService.stateDidChange = { [weak self] state in
            if case .ended(_, .authorizationDenied) = state {
                self?.shouldOfferLocationSettings = true
                self?.isPreparingLocationSharing = false
                Task { [weak self] in
                    await self?.disableLocationSharingAfterRevocation()
                }
            }
        }
    }

    func start() async {

        do {
            try recoverVoiceMessageDrafts()
        } catch {
            errorMessage = error.localizedDescription
        }

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
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            errorMessage = AuthenticationError.invalidAuthorization.localizedDescription
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

    /// Shared post-authentication transition used by restored sessions and
    /// Sign in with Apple. Keeping it separate also lets the invite-link
    /// handoff be verified without constructing a system authorization UI.
    func completeAuthentication(with user: Person) async {
        if isAuthenticated, currentUser.id != user.id { pendingSecureInvite = nil }
        secureInvitationAssignmentID = nil
        legacyRouting?.prepareForAccountRestoration(user.id)
        // Keep interactive sign-in on its original button while account setup finishes.
        let retainWelcome = phase == .welcome && isWorking
        // Revoke the old UI and callbacks before any throwing storage setup.
        sessionGeneration = UUID()
        isWorking = false
        resetNotificationOperationsForAccountChange()
        profileObservation?.cancel(); profileObservation = nil
        resetConversationState(discardShares: false)
        encryption?.invalidate()
        currentUser = user
        installNotificationHandlersIfNeeded()
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
        profileIsReady = false
        conversationAssignmentResolved = false
        await finishAuthenticatedStartup()
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
        isWorking = true
        defer { isWorking = false }

        do {
            let createdAt = Date()
            let result = try await pairing.createConversation()
            if let conversationID = result.conversationID {
                await enterConversation(conversationID)
            } else {
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
            }
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
        guard let canonicalCode = PairingCode.canonicalValue(code) else {
            errorMessage = PairingCodeInputError.invalid.localizedDescription
            return
        }

        isWorking = true
        defer { isWorking = false }

        do {
            let result = try await pairing.joinConversation(code: canonicalCode)
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
        messagePins?.stop(); messagePins = nil
        isWorking = true
        defer { if sessionGeneration == signingOutSession { isWorking = false } }

        await stopPublishingTypingAndWait()
        guard sessionGeneration == signingOutSession else { return }
        do {
            try await stopLocationSharingBeforeLeavingConversation()
            guard sessionGeneration == signingOutSession else { return }
            try await profiles.removeDeviceRegistration(userID: signingOutUserID)
            guard sessionGeneration == signingOutSession else { return }
            try auth.signOut()
        } catch {
            guard sessionGeneration == signingOutSession else { return }
            errorMessage = error.localizedDescription
            if let conversationID { startMessagePins(conversationID) }
            notificationCoordinator.setTokenHandler(nil)
            notificationHandlersInstalled = false
            notificationRegistrationSucceeded = false
            installNotificationHandlersIfNeeded()
            await configureNotifications()
            return
        }
        guard sessionGeneration == signingOutSession else { return }
        isWorking = false
        await resetForSignedOutSession()
    }

    func deleteConversation() async {
        errorMessage = "Conversation deletion is unavailable."
    }

    private func stopLocationSharingBeforeLeavingConversation() async throws {
        locationSharingOperationID = nil
        locationSharingTask?.cancel()
        locationSharingTask = nil
        isPreparingLocationSharing = false
        let hadActiveLocalSharing =
            liveLocationService.state.activeSession != nil
        liveLocationService.stop()

        guard let conversationID else { return }
        let needsRemoteCleanup =
            !hasResolvedLocationSnapshot
                || locationSnapshot.sharingUserIDs.contains(currentUser.id)
                || locationSnapshot.latestPoints[currentUser.id] != nil
                || hadActiveLocalSharing
        guard needsRemoteCleanup else { return }
        if let secureLocations = encryption?.locations {
            try await secureLocations.abandonSharingSource(conversationID: conversationID, userID: currentUser.id)
        } else {
            try await connectionLocations.setSharingEnabled(false, conversationID: conversationID, userID: currentUser.id)
        }
    }

    func sendDraft() async {
        await sendDraft(
            draft,
            replyingTo: replyToMessageID,
            deliveryMode: .normal
        )
    }

    func sendDraft(
        _ submittedDraft: String,
        replyingTo submittedReplyToID: UUID?,
        deliveryMode: MessageDeliveryMode = .normal
    ) async {
        guard let pending = prepareDraftMessage(
            submittedDraft,
            replyingTo: submittedReplyToID,
            deliveryMode: deliveryMode
        ) else { return }
        registerOutgoingMessage(pending)
        messages.append(pending)
        await sendPreparedDraft(pending)
    }

    private func prepareDraftMessage(
        _ submittedDraft: String,
        replyingTo submittedReplyToID: UUID?,
        deliveryMode: MessageDeliveryMode,
        createdAt: Date = .now
    ) -> ChatMessage? {
        let trimmed = submittedDraft.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else { return nil }

        if draft == submittedDraft {
            draft = ""
        }
        if replyToMessageID == submittedReplyToID {
            replyToMessageID = nil
        }
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            stopPublishingTyping()
        }
        return ChatMessage(
            senderID: currentUser.id,
            kind: .forText(trimmed),
            body: trimmed,
            createdAt: createdAt,
            deliveryState: .sending,
            replyToID: submittedReplyToID,
            deliveryMode: deliveryMode
        )
    }

    private func sendPreparedDraft(_ pending: ChatMessage) async {
        let session = sessionGeneration
        let targetConversationID = conversationID
        do {
            guard let targetConversationID else {
                throw MessagingError.missingConversation
            }
            let sent = try await sendConfirmedMessage(
                pending,
                conversationID: targetConversationID
            )
            guard sessionGeneration == session,
                conversationID == targetConversationID else { return }
            replaceMessage(sent)
        } catch {
            guard sessionGeneration == session,
                conversationID == targetConversationID,
                locallyPendingMessages[pending.id] != nil else { return }
            var failed = pending
            failed.deliveryState = .failed
            replaceMessage(failed)
        }
    }

    func retryMessage(_ message: ChatMessage) async {
        if pendingShareTimelineStatuses[message.id] != nil {
            await retryPendingShare(message.id)
            return
        }
        guard
            message.senderID == currentUser.id,
            message.deliveryState == .failed,
            !message.isUnsent,
            message.kind != .liveLocation,
            let conversationID,
            let index = messages.firstIndex(where: { $0.id == message.id })
        else {
            return
        }

        messages[index].deliveryState = .sending
        registerOutgoingMessage(messages[index])
        let session = sessionGeneration
        do {
            let sent = try await sendConfirmedMessage(
                messages[index],
                conversationID: conversationID
            )
            guard sessionGeneration == session,
                self.conversationID == conversationID else { return }
            replaceMessage(sent)
            try? acknowledgePendingShares([message.id])
            queuedShareErrorMessage = nil
            reloadPendingShares()
        } catch {
            guard sessionGeneration == session,
                self.conversationID == conversationID,
                locallyPendingMessages[message.id] != nil else { return }
            if let failedIndex = messages.firstIndex(
                where: { $0.id == message.id }
            ) {
                messages[failedIndex].deliveryState = .failed
                locallyPendingMessages[message.id] = messages[failedIndex]
            }
            errorMessage = error.localizedDescription
        }
    }

    func retryPendingShares() async {
        queuedShareErrorMessage = nil
        reloadPendingShares()
        for id in Array(pendingShareTimelineStatuses.keys) {
            pendingShareTimelineStatuses[id] = .waiting
        }
        synchronizePendingShareMessages()
        await sendQueuedSharesIfPossible()
    }

    func discardPendingShare() async {
        guard let pendingShare else { return }
        await discardPendingShare(pendingShare.id)
    }

    func retryPendingShare(_ id: UUID) async {
        guard pendingShareTimelineStatuses[id] != nil else { return }
        queuedShareErrorMessage = nil
        pendingShareTimelineStatuses[id] = .waiting
        synchronizePendingShareMessages()
        await sendQueuedSharesIfPossible()
    }

    func discardPendingShare(_ id: UUID) async {
        await discardPendingShares([id])
    }

    func discardPendingShares(_ ids: Set<UUID>) async {
        let queuedIDs = Set(queuedShares.map(\.id)).intersection(ids)
        guard !queuedIDs.isEmpty else { return }

        do {
            try acknowledgePendingShares(queuedIDs)
            messages.removeAll {
                queuedIDs.contains($0.id)
            }
            for id in queuedIDs {
                pendingShareTimelineStatuses[id] = nil
                locallyPendingMessages[id] = nil
                outgoingMessageDisplayDates[id] = nil
                composerAttachmentsWaitingForText.remove(id)
            }
            queuedShareErrorMessage = nil
            reloadPendingShares()
            await sendQueuedSharesIfPossible()
        } catch {
            queuedShareErrorMessage = error.localizedDescription
        }
    }

    var replyTarget: ChatMessage? {
        guard let replyToMessageID else { return nil }
        return pinnedReplyTarget?.id == replyToMessageID
            ? pinnedReplyTarget
            : messages.first { $0.id == replyToMessageID }
                ?? replyContextMessages[replyToMessageID]
    }

    func beginReply(to message: ChatMessage) {
        guard !message.isUnsent else { return }
        replyToMessageID = message.id
        pinnedReplyTarget = message
    }

    func cancelReply() {
        replyToMessageID = nil
    }

    private func refreshPinnedReplyTarget() {
        guard
            let replyToMessageID,
            let target = messages.first(where: { $0.id == replyToMessageID })
                ?? replyContextMessages[replyToMessageID]
        else { return }
        if target.isUnsent {
            self.replyToMessageID = nil
        } else {
            pinnedReplyTarget = target
        }
    }

    func editMessage(_ message: ChatMessage, body: String) async {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
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
            if let currentIndex = messages.firstIndex(
                where: { $0.id == message.id }
            ) {
                messages[currentIndex] = original
            }
            errorMessage = error.localizedDescription
        }
    }

    func unsendMessage(_ message: ChatMessage) async {
        guard
            message.senderID == currentUser.id,
            !message.isUnsent,
            let conversationID,
            messages.contains(where: { $0.id == message.id })
        else {
            return
        }

        let groupMessageIDs: [UUID]
        if
            let groupID = message.attachmentGroupID,
            (message.attachmentGroupCount ?? 0) > 1
        {
            groupMessageIDs = messages
                .filter { $0.attachmentGroupID == groupID }
                .map(\.id)
        } else {
            groupMessageIDs = [message.id]
        }
        let groupMessageIDSet = Set(groupMessageIDs)
        let originals = Dictionary(
            uniqueKeysWithValues: messages
                .filter { groupMessageIDSet.contains($0.id) }
                .map { ($0.id, $0) }
        )
        let deletionDate = Date.now
        for index in messages.indices
            where groupMessageIDSet.contains(messages[index].id)
        {
            messages[index].body = ""
            messages[index].deletedAt = deletionDate
            messages[index].reactions = [:]
        }
        if
            let currentReplyID = replyToMessageID,
            groupMessageIDSet.contains(currentReplyID)
        {
            replyToMessageID = nil
        }

        var firstError: Error?
        for messageID in groupMessageIDs {
            do {
                try await messaging.unsendMessage(
                    conversationID: conversationID,
                    messageID: messageID.uuidString
                )
            } catch {
                if
                    let original = originals[messageID],
                    let currentIndex = messages.firstIndex(
                        where: { $0.id == messageID }
                    )
                {
                    messages[currentIndex] = original
                }
                if firstError == nil {
                    firstError = error
                }
            }
        }
        if let firstError {
            errorMessage = firstError.localizedDescription
        }
    }

    func toggleReaction(_ emoji: String, on message: ChatMessage) async {
        guard
            !message.isUnsent,
            let conversationID,
            let index = messages.firstIndex(where: { $0.id == message.id })
        else {
            return
        }

        let originalReaction = messages[index].reactions[currentUser.id]
        let reaction = originalReaction == emoji ? nil : emoji
        messages[index].reactions[currentUser.id] = reaction
        updateObservedReactionBaseline(
            messageID: message.id,
            reactorID: currentUser.id,
            emoji: reaction
        )
        if let reaction {
            enqueueLocalReactionBurst(
                ReactionBurstCandidate(
                    messageID: message.id,
                    reactorID: currentUser.id,
                    emoji: reaction
                )
            )
        }

        do {
            try await messaging.setReaction(
                conversationID: conversationID,
                messageID: message.id.uuidString,
                userID: currentUser.id,
                emoji: reaction
            )
        } catch {
            if let currentIndex = messages.firstIndex(
                where: { $0.id == message.id }
            ) {
                messages[currentIndex].reactions[currentUser.id] = originalReaction
            }
            updateObservedReactionBaseline(
                messageID: message.id,
                reactorID: currentUser.id,
                emoji: originalReaction
            )
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
            || now.timeIntervalSince(lastTypingRefreshAt ?? .distantPast) >= 4
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
        if !isVisible || !isAppActive {
            reactionBurstEvent = nil
            pendingLocalReactionBursts = []
        } else if conversationIsActuallyVisible {
            presentNextReactionBurstIfPossible()
        }
        updateForegroundNotificationConversation()
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
            conversationIsActuallyVisible,
            let latestIncoming = messages.last(
                where: { $0.senderID != currentUser.id }
            )
        else {
            return
        }
        acknowledge(latestIncoming, markAsRead: true)
    }

    func conversationObscurationDidChange(
        _ source: ConversationObscurationSource,
        isObscured: Bool
    ) {
        if isObscured {
            conversationObscurationSources.insert(source)
        } else {
            conversationObscurationSources.remove(source)
        }

        updateForegroundNotificationConversation()
        guard conversationIsActuallyVisible else {
            if isObscured {
                stopPublishingTyping()
            }
            return
        }

        presentNextReactionBurstIfPossible()
        if
            let latestIncoming = messages.last(
                where: { $0.senderID != currentUser.id }
            )
        {
            acknowledge(latestIncoming, markAsRead: true)
        }
    }

    func reactionBurstDidFinish(_ eventID: UUID) {
        guard reactionBurstEvent?.id == eventID else { return }
        reactionBurstEvent = nil
        presentNextReactionBurstIfPossible()
    }

    @discardableResult
    func copyPairingCode() -> Bool {
        guard let code = PairingCode.canonicalValue(pairingCode) else {
            return false
        }
        UIPasteboard.general.string = code
        return true
    }

    var pairingLink: URL? {
        guard let code = PairingCode.canonicalValue(pairingCode) else {
            return nil
        }
        return URL(string: "peapod://join/\(code)")
    }

    var locationSharingToggleIsOn: Bool {
        isPreparingLocationSharing
            || locationSnapshot.sharingUserIDs.contains(currentUser.id)
    }

    func mutualLocationPresentation(
        at date: Date = .now
    ) -> MutualLocationPresentation? {
        locationSnapshot.mutualPresentation(
            currentUserID: currentUser.id,
            partnerID: partner.id,
            now: date
        )
    }

    var locationSourceIsAnotherDevice: Bool {
        guard let local = encryption?.locations?.localDeviceID,
              let source = locationSnapshot.sourceDeviceIDs[currentUser.id] else { return false }
        return source != local
    }

    var canResumeLocationSharing: Bool {
        guard let local = encryption?.locations?.localDeviceID else { return false }
        return locationSnapshot.sourceDeviceIDs[currentUser.id] == local
            && locationSnapshot.sharingUserIDs.contains(currentUser.id)
            && liveLocationService.state.activeSession == nil && !isPreparingLocationSharing
    }

    var locationSourceTransferTarget: SecureConversationResetTarget? {
        guard phase == .conversation, locationSourceIsAnotherDevice else { return nil }
        return conversationDeletionTarget
    }

    func transferLocationSharingToThisPhone(confirmed target: SecureConversationResetTarget) {
        guard target == locationSourceTransferTarget else { return }
        startLocationSharingChange(true, transferSource: true)
    }

    func setLocationSharingEnabled(_ isEnabled: Bool) {
        startLocationSharingChange(isEnabled, transferSource: false)
    }

    private func startLocationSharingChange(_ isEnabled: Bool, transferSource: Bool) {
        locationSharingTask?.cancel()
        locationSharingSourceGeneration = nil
        if isEnabled, transferSource || encryption?.locations != nil { liveLocationService.stop() }
        let operationID = UUID()
        locationSharingOperationID = operationID
        locationSharingTask = Task { [weak self] in
            guard let self else { return }
            await self.performLocationSharingChange(
                isEnabled,
                operationID: operationID,
                transferSource: transferSource
            )
        }
    }

    private func performLocationSharingChange(
        _ isEnabled: Bool,
        operationID: UUID,
        transferSource: Bool = false
    ) async {
        guard let conversationID, let target = conversationDeletionTarget else {
            errorMessage = MessagingError.missingConversation.localizedDescription
            return
        }

        if !isEnabled {
            isPreparingLocationSharing = false
            liveLocationService.stop()
            do {
                try await connectionLocations.setSharingEnabled(
                    false,
                    conversationID: conversationID,
                    userID: currentUser.id
                )
            } catch {
                errorMessage = error.localizedDescription
            }
            finishLocationSharingOperation(operationID)
            return
        }

        shouldOfferLocationSettings = false
        isPreparingLocationSharing = true
        let secureLocations = encryption?.locations
        do {
            // The explicit intent selects/fences the source before any GPS or permission request.
            if let secureLocations {
                if transferSource {
                    try await secureLocations.transferSharingSource(conversationID: conversationID, userID: target.accountID)
                } else {
                    try await secureLocations.setSharingEnabled(true, conversationID: conversationID, userID: target.accountID)
                }
            }
            try Task.checkCancellation()
            guard locationSharingOperationID == operationID, conversationDeletionTarget == target else { throw CancellationError() }
            locationSharingSourceGeneration = secureLocations?.activeSourceGeneration
            if let generation = locationSharingSourceGeneration, encryptedLocationSourceWasRevoked(generation: generation) {
                throw EncryptedLocationError.sourceOwnedByAnotherDevice
            }
            if connectionLocations.requiresDeviceLocation {
                let preparation = try await liveLocationService.prepare(duration: .untilStopped)
                try Task.checkCancellation()
                guard locationSharingOperationID == operationID, conversationDeletionTarget == target else { throw CancellationError() }
                if secureLocations == nil {
                    try await connectionLocations.setSharingEnabled(true, conversationID: conversationID, userID: target.accountID)
                    guard locationSharingOperationID == operationID, conversationDeletionTarget == target else { throw CancellationError() }
                }
                try await liveLocationService.activate(preparation)
            } else if secureLocations == nil {
                try await connectionLocations.setSharingEnabled(true, conversationID: conversationID, userID: target.accountID)
            }
        } catch {
            guard locationSharingOperationID == operationID, conversationDeletionTarget == target else { return }
            liveLocationService.stop()
            if let secureLocations {
                // Failed claims and delayed permission callbacks must not revoke another phone.
                try? await secureLocations.abandonSharingSource(conversationID: conversationID, userID: target.accountID)
            } else {
                try? await connectionLocations.setSharingEnabled(false, conversationID: conversationID, userID: target.accountID)
            }
            guard locationSharingOperationID == operationID, conversationDeletionTarget == target else { return }
            if error as? LiveLocationStartError == .authorizationDenied {
                shouldOfferLocationSettings = true
            } else if !(error is CancellationError) {
                errorMessage = error.localizedDescription
            }
        }
        finishLocationSharingOperation(operationID)
    }

    private func finishLocationSharingOperation(_ operationID: UUID) {
        guard locationSharingOperationID == operationID else { return }
        locationSharingOperationID = nil
        locationSharingTask = nil
        isPreparingLocationSharing = false
    }

    private func encryptedLocationSourceWasRevoked(generation: UInt64) -> Bool {
        guard let observed = locationSnapshot.sourceGenerations[currentUser.id], observed >= generation else { return false }
        return observed > generation || locationSourceIsAnotherDevice
            || !locationSnapshot.sharingUserIDs.contains(currentUser.id)
    }

    private func disableLocationSharingAfterRevocation() async {
        guard let conversationID else { return }
        if let secureLocations = encryption?.locations {
            try? await secureLocations.abandonSharingSource(conversationID: conversationID, userID: currentUser.id)
        } else {
            try? await connectionLocations.setSharingEnabled(false, conversationID: conversationID, userID: currentUser.id)
        }
    }

    private func reconcileOrphanedLocationPoint(
        conversationID: String
    ) {
        // Encrypted off/transfer atomically removes its point; independent listener snapshots
        // may briefly disagree and never authorize an account-wide cleanup from this viewer.
        guard encryption?.locations == nil, !orphanedLocationCleanupInFlight else { return }
        orphanedLocationCleanupInFlight = true
        let userID = currentUser.id
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.connectionLocations.setSharingEnabled(
                    false,
                    conversationID: conversationID,
                    userID: userID
                )
            } catch {
                if self.conversationID == conversationID {
                    self.presentConversationError(
                        error,
                        conversationID: conversationID
                    )
                }
            }
            self.orphanedLocationCleanupInFlight = false
        }
    }

    func sendAttachmentData(
        _ data: Data,
        kind: PendingShare.Kind,
        suggestedName: String?,
        contentTypeIdentifier: String?
    ) async {
        var stagedShare: PendingShare?

        do {
            guard let conversationID else {
                throw PendingShareStoreError.missingConversationTarget
            }
            let type = contentTypeIdentifier.flatMap(UTType.init)
            let staged = try stageAttachmentData(
                data,
                kind: kind,
                suggestedName: suggestedName,
                preferredExtension: type?.preferredFilenameExtension,
                contentTypeIdentifier: contentTypeIdentifier
            )
            stagedShare = staged
            let share = try staged.scopedToConversation(conversationID)
            try enqueuePendingShares([share])
            stagedShare = nil
            reloadPendingShares()
            await sendQueuedSharesIfPossible()
        } catch {
            if let stagedShare {
                discardAttachmentDrafts(for: [stagedShare])
            }
            errorMessage = error.localizedDescription
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
            let prepared = try preparedComposerAttachments(
                photoShares: photoShares,
                fileShares: fileShares,
                deliveryMode: deliveryMode,
                queuedAt: .now
            )
            try enqueuePendingShares(prepared)
            reloadPendingShares()
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    /// Publish a submitted text/photo draft in the same order it is sent.
    /// Persistence and validation finish before any draft is cleared or row
    /// appears, so an enqueue failure leaves the composer retryable.
    func submitComposerMessage(
        _ submittedDraft: String,
        replyingTo submittedReplyToID: UUID?,
        photoShares: [PendingShare],
        fileShares: [PendingShare],
        deliveryMode: MessageDeliveryMode
    ) throws {
        do {
            let queuedAt = Date()
            let prepared = try preparedComposerAttachments(
                photoShares: photoShares,
                fileShares: fileShares,
                deliveryMode: deliveryMode,
                queuedAt: queuedAt
            )
            try enqueuePendingShares(prepared)
            let pending = prepareDraftMessage(
                submittedDraft,
                replyingTo: submittedReplyToID,
                deliveryMode: deliveryMode,
                createdAt: queuedAt
            )
            if let pending {
                composerAttachmentsWaitingForText.formUnion(prepared.map(\.id))
                registerOutgoingMessage(pending)
                messages.append(pending)
            }
            reloadPendingShares()
            let session = sessionGeneration
            let targetConversationID = conversationID
            Task { [weak self] in
                guard let self,
                    self.sessionGeneration == session,
                    self.conversationID == targetConversationID else { return }
                if let pending { await self.sendPreparedDraft(pending) }
                guard self.sessionGeneration == session,
                    self.conversationID == targetConversationID else { return }
                self.composerAttachmentsWaitingForText.subtract(prepared.map(\.id))
                await self.sendQueuedSharesIfPossible()
            }
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    private func preparedComposerAttachments(
        photoShares: [PendingShare],
        fileShares: [PendingShare],
        deliveryMode: MessageDeliveryMode,
        queuedAt: Date
    ) throws -> [PendingShare] {
        let photos = photoShares.isEmpty
            ? [] : try PhotoAttachmentDraftPolicy.preparedForSend(photoShares)
        guard fileShares.allSatisfy({ $0.kind != .image }) else {
            throw PhotoAttachmentDraftError.unsupportedItem
        }
        guard photos.count + fileShares.count <= PhotoAttachmentDraftPolicy.maximumCount else {
            throw PhotoAttachmentDraftError.tooMany(
                maximum: PhotoAttachmentDraftPolicy.maximumCount
            )
        }
        guard let conversationID else {
            throw PendingShareStoreError.missingConversationTarget
        }
        return try (photos + fileShares).enumerated().map { index, share in
            try AttachmentDraftDependencies.validateProvenance(share, accountID: currentUser.id, conversationID: conversationID,
                requiresBound: encryption != nil)
            return try share
                .queuedForSending(at: queuedAt.addingTimeInterval(Double(index + 1) / 1_000))
                .delivered(deliveryMode)
                .scopedToConversation(conversationID)
        }
    }

    func sendAttachmentFile(
        _ url: URL,
        contentTypeIdentifier: String?
    ) async {
        var stagedShare: PendingShare?

        do {
            guard let conversationID else {
                throw PendingShareStoreError.missingConversationTarget
            }
            let staged = try stageAttachmentFile(
                from: url,
                kind: .file,
                suggestedName: url.lastPathComponent,
                contentTypeIdentifier: contentTypeIdentifier
            )
            stagedShare = staged
            let share = try staged.scopedToConversation(conversationID)
            try enqueuePendingShares([share])
            stagedShare = nil
            reloadPendingShares()
            await sendQueuedSharesIfPossible()
        } catch {
            if let stagedShare {
                discardAttachmentDrafts(for: [stagedShare])
            }
            errorMessage = error.localizedDescription
        }
    }

    /// Capture this operation on the record-button tap, before microphone permission awaits.
    /// A recording from an earlier account/session must never become a new account's draft.
    func makeVoiceMessageStagingOperation() -> (VoiceMessageDraft) throws -> StagedVoiceMessage {
        let recordingSession = sessionGeneration
        let ownerID = currentUser.id
        let target = conversationID
        return { [weak self] draft in

            guard let self, self.sessionGeneration == recordingSession,
                  self.currentUser.id == ownerID, let target,
                  self.conversationID == target else {
                throw PendingShareStoreError.accountMismatch
            }
            let stager = VoiceMessageStager(
                enqueue: self.enqueuePendingShares,
                pendingItems: self.loadPendingShares
            )
            return try stager.stageAndEnqueue(draft)
        }
    }

    func sendStagedVoiceMessage(_ staged: StagedVoiceMessage) async {
        if let owner = staged.pendingShare.conversationOwnerID, owner != currentUser.id { return }
        reloadPendingShares()
        guard queuedShares.contains(where: { $0.id == staged.pendingShare.id }) else {
            errorMessage = "The voice message could not be found in the send queue."
            return
        }
        await sendQueuedSharesIfPossible()
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
        guard url.scheme == "peapod" else { return }
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

    private func replaceMessage(_ replacement: ChatMessage) {
        if locallyPendingMessages[replacement.id] != nil {
            locallyPendingMessages[replacement.id] = replacement
        }
        guard let index = messages.firstIndex(where: { $0.id == replacement.id }) else {
            return
        }
        if observedMessageIDs.contains(replacement.id),
            replacement.deliveryState == .sent
        {
            // Firestore may publish its timestamp/content before send()
            // returns the original optimistic value. Keep that newer data.
            if messages[index].deliveryState == .sending {
                messages[index].deliveryState = .sent
                if messages[index].attachment?.storagePath == nil {
                    messages[index].attachment = replacement.attachment
                }
            }
            return
        }
        messages[index] = replacement
    }

    private func upsertMessage(_ message: ChatMessage) {
        if locallyPendingMessages[message.id] != nil {
            locallyPendingMessages[message.id] = message
        }
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            if observedMessageIDs.contains(message.id) {
                messages[index].deliveryState = message.deliveryState
                if messages[index].attachment?.storagePath == nil {
                    messages[index].attachment = message.attachment
                }
            } else {
                messages[index] = message
            }
        } else {
            messages.append(message)
        }
    }

    private func receiveObservedReactions(from messages: [ChatMessage]) {
        // A limited query only describes its current window. Preserve the
        // replay baseline for other rows so paging away and back neither
        // replays old reactions nor forgets genuine changes to those rows.
        var currentSnapshot = observedReactionSnapshot ?? [:]
        if usesBoundedHistory {
            let visibleIDs = Set(messages.map(\.id))
            currentSnapshot = currentSnapshot.filter { visibleIDs.contains($0.key) }
            pendingReceivedReactionBursts = pendingReceivedReactionBursts.filter { visibleIDs.contains($0.messageID) }
        }
        for message in messages {
            currentSnapshot[message.id] = message.reactions
        }
        guard let previousSnapshot = observedReactionSnapshot else {
            observedReactionSnapshot = currentSnapshot
            reactionReplayStateIsCurrent = true
            persistReactionBurstReplayState()
            presentNextReactionBurstIfPossible()
            return
        }
        pendingReceivedReactionBursts =
            ReactionBurstReplayPolicy.reconciledPendingCandidates(
                pendingReceivedReactionBursts,
                from: previousSnapshot,
                to: currentSnapshot,
                currentUserID: currentUser.id
            )
        observedReactionSnapshot = currentSnapshot
        reactionReplayStateIsCurrent = true
        persistReactionBurstReplayState()
        presentNextReactionBurstIfPossible()
    }

    private func updateObservedReactionBaseline(
        messageID: UUID,
        reactorID: String,
        emoji: String?
    ) {
        guard var observedReactionSnapshot else { return }
        var reactions = observedReactionSnapshot[messageID] ?? [:]
        reactions[reactorID] = emoji
        observedReactionSnapshot[messageID] = reactions
        self.observedReactionSnapshot = observedReactionSnapshot
        persistReactionBurstReplayState()
    }

    private func enqueueLocalReactionBurst(
        _ candidate: ReactionBurstCandidate
    ) {
        pendingLocalReactionBursts.append(candidate)
        presentNextReactionBurstIfPossible()
    }

    private func presentNextReactionBurstIfPossible() {
        guard
            phase == .conversation,
            conversationIsActuallyVisible,
            reactionReplayStateIsCurrent || !pendingLocalReactionBursts.isEmpty,
            reactionBurstEvent == nil
        else {
            return
        }

        let candidate: ReactionBurstCandidate
        if !pendingLocalReactionBursts.isEmpty {
            candidate = pendingLocalReactionBursts.removeFirst()
        } else if !pendingReceivedReactionBursts.isEmpty {
            candidate = pendingReceivedReactionBursts.removeFirst()
            persistReactionBurstReplayState()
        } else {
            return
        }
        reactionBurstEvent = ReactionBurstEvent(
            messageID: candidate.messageID,
            reactorID: candidate.reactorID,
            emoji: candidate.emoji
        )
    }

    private func persistReactionBurstReplayState() {
        // Encrypted reaction plaintext stays in the bounded in-memory presentation.
        guard !usesBoundedHistory, encryption?.requiresSecurePairing != true else { return }
        guard
            let conversationID,
            let observedReactionSnapshot
        else {
            return
        }
        reactionBurstReplayStore.save(
            ReactionBurstReplayState(
                snapshot: observedReactionSnapshot,
                pendingCandidates: pendingReceivedReactionBursts
            ),
            conversationID: conversationID,
            userID: currentUser.id
        )
    }

    private func finishAuthenticatedStartup() async {
        let generation = sessionGeneration
        observeConversationAssignment()
        do {
            try await profiles.saveProfile(currentUser)
            guard generation == sessionGeneration else { return }
            try await encryption?.refreshAccountRequirements()
            guard sessionGeneration == generation else { return }
            profileIsReady = true
            routeResolvedConversationAssignment()
        } catch {
            guard generation == sessionGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func observeConversationAssignment() {
        profileObservation?.cancel()
        let session = sessionGeneration
        profileObservation = profiles.observeConversationID(
            for: currentUser.id
        ) { [weak self] result in
            guard
                let self,
                self.isAuthenticated,
                self.sessionGeneration == session
            else { return }
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
        if self.conversationID != conversationID || encryption?.resetRecoveryBlocked == true {
            messagePins?.stop(); messagePins = nil
        }
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
                guard
                    self.sessionGeneration == session,
                    self.conversationAssignmentGeneration == assignment
                else { return }
                await self.enterConversation(conversationID)
            }
        } else if self.conversationID != nil {
            self.beginConversationTeardown(
                self.conversationID,
                deletionWasObserved: true
            )
            Task {
                guard
                    self.sessionGeneration == session,
                    self.conversationAssignmentGeneration == assignment
                else { return }
                await self.transitionToPairing()
            }
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
        let recovery = sessionGeneration
        profileObservation?.cancel(); profileObservation = nil
        resetConversationState(discardShares: false)
        encryption?.invalidate()
        resetNotificationOperationsForAccountChange()
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
            await resetForSignedOutSession()
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

        if let previousConversationID = self.conversationID,
           previousConversationID != conversationID
        {
            // The new conversation can render before its first snapshot.
            // Never leave the previous conversation's rows or person there.
            resetConversationState()
        }

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

        partnerRefreshTask?.cancel()
        messageHistoryIsReady = false
        messageHistoryLoadFailed = false
        historyViewportAtLatest = false
        messageLimit = ConversationHistoryPolicy.pageSize
        resolvedMessageLimit = ConversationHistoryPolicy.pageSize
        hasMoreMessages = false
        isLoadingOlderMessages = false
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
        updateForegroundNotificationConversation()
        lastMarkedDeliveredMessageID = nil
        lastMarkedReadMessageID = nil
        if let publisher = encryption?.locations {
            liveLocationService.configure(publisher: publisher)
        } else if usesFirebase {
            liveLocationService.configure(
                publisher: FirestoreLiveLocationPublisher(
                    conversationID: conversationID,
                    userID: currentUser.id
                )
            )
        }

        // The owner-scoped profile listener can restore the assignment from
        // Firestore's disk cache. Start the timeline immediately; fetching the
        // partner's display name must not put two network reads before it.
        observeConversationContent(conversationID)
        pairingCode = ""
        pairingCodeExpiresAt = nil
        phase = .conversation
        refreshLegacyConversationRouting()
        refreshPartner(conversationID: conversationID)
        await configureNotifications()
        guard secureOpeningGeneration == secureOpening else { return }
        await encryption?.retryPendingMessages()
        guard secureOpeningGeneration == secureOpening else { return }
        await sendQueuedSharesIfPossible()
    }

    func refreshPartner(conversationID: String) {
        guard isAuthenticated, self.conversationID == conversationID,
              conversationBeingTornDownID != conversationID else { return }
        let session = sessionGeneration
        let userID = currentUser.id
        let scope = PartnerIdentityScope(accountID: userID, conversationID: conversationID)
        if resolvedPartnerScope != scope { resolvedPartnerScope = nil }
        let refresh = UUID()
        partnerRefreshGeneration = refresh
        partnerRefreshTask?.cancel()
        partnerRefreshTask = Task { [weak self, profiles] in
            do {
                let partner = try await profiles.fetchPartner(
                    conversationID: conversationID,
                    currentUserID: userID
                )
                guard
                    !Task.isCancelled,
                    let self,
                    self.sessionGeneration == session,
                    self.currentUser.id == userID,
                    self.conversationID == conversationID,
                    self.partnerRefreshGeneration == refresh,
                    self.conversationBeingTornDownID != conversationID
                else { return }
                self.partner = partner
                self.resolvedPartnerScope = scope
            } catch {
                guard
                    !Task.isCancelled,
                    let self,
                    self.sessionGeneration == session,
                    self.currentUser.id == userID,
                    self.conversationID == conversationID,
                    self.partnerRefreshGeneration == refresh,
                    self.conversationBeingTornDownID != conversationID
                else { return }
                self.presentConversationError(
                    error,
                    conversationID: conversationID
                )
            }
        }
    }

    func loadOlderMessages() {
        if let historyController { historyController.older(); return }
        guard
            phase == .conversation,
            hasMoreMessages,
            !isLoadingOlderMessages,
            let conversationID,
            let messageLimit
        else { return }
        self.messageLimit = messageLimit + ConversationHistoryPolicy.pageSize
        isLoadingOlderMessages = true
        observeMessageContent(conversationID, expandingHistory: true)
    }

    func beginMessageHistorySearch() {
        guard historyController == nil else { return }
        if searchReturnWindow == nil { searchReturnWindow = SearchReturnWindow(limit: messageLimit) }
        loadFullMessageHistory()
    }

    func finishMessageHistorySearch(restoringWindow: Bool = true) {
        guard let saved = searchReturnWindow else { return }
        searchReturnWindow = nil
        guard restoringWindow, phase == .conversation, let conversationID, messageLimit != saved.limit else { return }
        messageLimit = saved.limit
        isLoadingOlderMessages = true
        observeMessageContent(conversationID)
    }

    func retryMessageHistory() {
        guard phase == .conversation, let conversationID else { return }
        messageHistoryLoadFailed = false
        observeMessageContent(conversationID)
    }

    func loadFullMessageHistory() {
        guard historyController == nil else { return }
        guard
            phase == .conversation,
            messageLimit != nil,
            let conversationID
        else { return }
        messageLimit = nil
        isLoadingOlderMessages = true
        observeMessageContent(conversationID, expandingHistory: true)
    }

    func returnToRecentMessageHistory() {
        searchReturnWindow = nil
        if let historyController { historyController.latest(); return }
        guard
            phase == .conversation,
            messageLimit != ConversationHistoryPolicy.pageSize,
            let conversationID
        else { return }
        messageLimit = ConversationHistoryPolicy.pageSize
        isLoadingOlderMessages = true
        observeMessageContent(conversationID)
    }

    private func startMessagePins(_ conversationID: String) {
        let session = sessionGeneration
        messagePins?.stop()
        let account = currentUser.id
        let pins = MessagePinsController(provider: messaging, conversationID: conversationID, currentUserID: account) { [weak self] error in
            guard let self, self.sessionGeneration == session, self.currentUser.id == account,
                  self.conversationID == conversationID, self.conversationBeingTornDownID != conversationID else { return }
            self.presentConversationError(error, conversationID: conversationID)
        }
        messagePins = pins
        pins.start()
    }

    private func observeConversationContent(_ conversationID: String) {
        let session = sessionGeneration
        startMessagePins(conversationID)
        locationObservation?.cancel()
        locationObservation = connectionLocations.observe(
            conversationID: conversationID
        ) { [weak self] result in
            guard
                let self,
                self.conversationID == conversationID,
                self.sessionGeneration == session
            else {
                return
            }
            switch result {
            case let .success(snapshot):
                self.hasResolvedLocationSnapshot = true
                self.locationSnapshot = snapshot
                let currentUserIsSharing =
                    snapshot.sharingUserIDs.contains(self.currentUser.id)
                if self.encryption?.locations != nil {
                    // Server intent identifies the primary; it never silently starts GPS on launch.
                    // Ignore a listener event older than the lease just claimed by this operation.
                    if let generation = self.locationSharingSourceGeneration,
                       self.encryptedLocationSourceWasRevoked(generation: generation) {
                        self.locationSharingOperationID = nil
                        self.locationSharingTask?.cancel(); self.locationSharingTask = nil
                        self.isPreparingLocationSharing = false
                        self.locationSharingSourceGeneration = nil
                        self.liveLocationService.stop() // also cancels awaiting/preparing sessions
                    }
                } else if !currentUserIsSharing {
                    self.didAttemptLocationSharingRestore = false
                    if self.liveLocationService.state.activeSession != nil {
                        self.liveLocationService.stop()
                    }
                    if
                        snapshot.latestPoints[self.currentUser.id] != nil
                    {
                        self.reconcileOrphanedLocationPoint(
                            conversationID: conversationID
                        )
                    }
                } else if
                    self.connectionLocations.requiresDeviceLocation,
                    self.liveLocationService.state.activeSession == nil,
                    !self.isPreparingLocationSharing,
                    !self.didAttemptLocationSharingRestore
                {
                    self.didAttemptLocationSharingRestore = true
                    self.setLocationSharingEnabled(true)
                }
            case let .failure(error):
                self.presentConversationError(
                    error,
                    conversationID: conversationID
                )
            }
        }

        let replayState = reactionBurstReplayStore.load(
            conversationID: conversationID,
            userID: currentUser.id
        )
        observedReactionSnapshot = replayState?.snapshot
        pendingReceivedReactionBursts =
            replayState?.pendingCandidates ?? []
        pendingLocalReactionBursts = []
        reactionBurstEvent = nil
        reactionReplayStateIsCurrent = false
        observeMessageContent(conversationID)
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

    private func observeMessageContent(
        _ conversationID: String,
        expandingHistory: Bool = false
    ) {
        messageObservation?.cancel()
        let generation = UUID()
        messageObservationGeneration = generation
        let session = sessionGeneration
        let limit = messageLimit
        let historyBoundary = expandingHistory
            ? messages.first?.createdAt
            : nil
        var knownMessageIDs = Set(messages.map(\.id))
        let receive: (Result<MessageHistorySnapshot, Error>) -> Void = { [weak self] result in
            guard
                let self,
                self.conversationID == conversationID,
                self.sessionGeneration == session,
                self.messageObservationGeneration == generation,
                self.conversationBeingTornDownID != conversationID
            else {
                return
            }
            switch result {
            case let .success(snapshot):
                let messages = snapshot.messages
                if !messages.isEmpty || !snapshot.isFromCache { self.messageHistoryIsReady = true }
                self.messageLimit = limit
                let fillsRequestedWindow = limit.map {
                    messages.count >= $0
                } ?? false
                if !snapshot.isFromCache || fillsRequestedWindow {
                    self.resolvedMessageLimit = limit
                    self.hasMoreMessages = fillsRequestedWindow
                    self.isLoadingOlderMessages = false
                }
                if !snapshot.isFromCache, !snapshot.reactionsAreFromCache {
                    if self.usesBoundedHistory {
                        // Historical arrivals are a baseline, not new reaction events.
                        if !self.historyIsRecent {
                            for message in messages where !knownMessageIDs.contains(message.id) {
                                self.observedReactionSnapshot?[message.id] = message.reactions
                            }
                        }
                        knownMessageIDs = Set(messages.map(\.id))
                    }
                    if let historyBoundary {
                        // Seed newly loaded historical rows only after their
                        // reaction queries catch up. Empty cached metadata
                        // does not establish an empty historical baseline.
                        for message in messages where
                            !knownMessageIDs.contains(message.id)
                                && message.createdAt <= historyBoundary
                                && self.observedReactionSnapshot?[message.id] == nil
                        {
                            self.observedReactionSnapshot?[message.id] =
                                message.reactions
                        }
                        knownMessageIDs.formUnion(messages.map(\.id))
                    }
                    self.receiveObservedReactions(from: messages)
                } else {
                    // Cached rows are immediately usable, but comparing a
                    // partial cache with the saved replay baseline can invent
                    // removals and replay unchanged reactions on reconnect.
                    self.reactionReplayStateIsCurrent = false
                }
                // Context never adds timeline rows. Assign it before the
                // messages revision changes so one presentation refresh sees
                // both the window and its referenced originals together.
                self.replyContextMessages = snapshot.replyMessages
                self.submissionLedger.observe(messages, queuedIDs: Set(self.queuedShares.map(\.id)))
                self.messages = self.mergingPendingShareMessages(
                    into: messages
                )
                if self.historyIsRecent,
                    let latestIncoming = messages.last(
                        where: { $0.senderID != self.currentUser.id }
                    )
                {
                    self.acknowledge(
                        latestIncoming,
                        markAsRead: self.conversationIsActuallyVisible
                    )
                }
            case let .failure(error):
                if !self.messageHistoryIsReady { self.messageHistoryLoadFailed = true }
                // Restore the successful window so the next paging/search
                // attempt retries the failed request instead of skipping it
                // or treating an unsuccessful full-history load as complete.
                self.messageLimit = self.resolvedMessageLimit
                self.isLoadingOlderMessages = false
                self.presentConversationError(
                    error,
                    conversationID: conversationID
                )
            }
        }
        if let provider = messaging as? any MessageHistoryWindowProviding {
            do {
                if try provider.supportsHistoryWindows(conversationID: conversationID) {
                    historyController?.cancel()
                    let controller = ConversationHistoryController(provider: provider, conversationID: conversationID,
                        accountID: currentUser.id, onWindow: receive, onNewest: { [weak self] rows in
                            guard let self, self.sessionGeneration == session, self.conversationID == conversationID,
                                  let incoming = rows.last(where: { $0.senderID != self.currentUser.id }) else { return }
                            self.acknowledge(incoming, markAsRead: self.conversationIsActuallyVisible && self.historyIsRecent)
                        }, onError: { [weak self] error in
                            guard let self, self.sessionGeneration == session else { return }
                            self.presentConversationError(error, conversationID: conversationID)
                        })
                    historyController = controller
                    controller.start()
                    return
                }
            } catch { receive(.failure(error)); return }
        }
        messageObservation = messaging.observeMessageHistory(conversationID: conversationID,
            currentUserID: currentUser.id, messageLimit: limit, onChange: receive)
    }

    private func transitionToPairing() async {
        guard isAuthenticated else { return }
        let session = sessionGeneration
        let departingConversationID = conversationID
        await stopPublishingTypingAndWait()
        guard
            isAuthenticated,
            sessionGeneration == session,
            conversationID == departingConversationID
        else { return }
        resetConversationState()
        await notificationCoordinator.clearConversationNotifications()
        guard
            sessionGeneration == session,
            conversationID == nil
        else { return }
        phase = .pairing
    }

    private func resetForSignedOutSession() async {
        encryption?.invalidate()
        pendingSecureInvite = nil
        secureInvitationAssignmentID = nil
        sessionGeneration = UUID()
        profileObservation?.cancel()
        profileObservation = nil
        resetConversationState()
        notificationRetryTask?.cancel()
        notificationRetryTask = nil
        deviceTokenSaveTask?.cancel()
        deviceTokenSaveTask = nil
        deviceTokenSaveOperationID = nil
        pendingDeviceToken = nil
        notificationRegistrationInFlight = false
        notificationRegistrationSucceeded = false
        notificationRetryAttempt = 0
        notificationHandlersInstalled = false
        let signedOutGeneration = sessionGeneration
        await notificationCoordinator.resetForSignOut()
        guard sessionGeneration == signedOutGeneration else { return }

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
        messagePins?.stop(); messagePins = nil
        legacyRoutingOperation = UUID()
        legacyRoutingTask?.cancel(); legacyRoutingTask = nil
        secureOpeningGeneration = UUID()
        openingConversationID = nil
        secureConversationIsOpening = false
        if let conversationID { try? encryption?.closeConversation(conversationID, deleted: false) }
        secureConversationWaitingID = nil
        partnerRefreshTask?.cancel()
        partnerRefreshTask = nil
        partnerRefreshGeneration = UUID()
        resolvedPartnerScope = nil
        messageObservationGeneration = UUID()
        messageObservation?.cancel()
        messageObservation = nil
        historyController?.cancel()
        historyController = nil
        historyViewportAtLatest = false
        observedReactionSnapshot = nil
        reactionReplayStateIsCurrent = false
        reactionBurstEvent = nil
        pendingReceivedReactionBursts = []
        pendingLocalReactionBursts = []
        conversationObscurationSources = []
        typingObservation?.cancel()
        typingObservation = nil
        locationObservation?.cancel()
        locationObservation = nil
        typingStopTask?.cancel()
        typingStopTask = nil
        locationSharingTask?.cancel()
        locationSharingTask = nil
        locationSharingOperationID = nil
        isPreparingLocationSharing = false
        didAttemptLocationSharingRestore = false
        hasResolvedLocationSnapshot = false
        orphanedLocationCleanupInFlight = false
        liveLocationService.stop()

        conversationID = nil
        messageLimit = ConversationHistoryPolicy.pageSize
        resolvedMessageLimit = ConversationHistoryPolicy.pageSize
        hasMoreMessages = false
        isLoadingOlderMessages = false
        SharedConversationStore.activeConversationID = nil
        replyContextMessages = [:]
        locallyPendingMessages = [:]
        outgoingMessageDisplayDates = [:]
        observedMessageIDs = []
        composerAttachmentsWaitingForText = []
        messageHistoryIsReady = false
        messageHistoryLoadFailed = false
        searchReturnWindow = nil
        messages = []
        draft = ""
        replyToMessageID = nil
        isPartnerTyping = false
        locationSnapshot = .empty
        locationSharingSourceGeneration = nil
        shouldOfferLocationSettings = false
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
        updateForegroundNotificationConversation()

        if discardShares { discardPendingShares() }
        queuedShares = []
        pendingShare = nil
        pendingShareTimelineStatuses = [:]
        queuedShareErrorMessage = nil
        isSendingQueuedShares = false
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
            partnerRefreshTask?.cancel()
            partnerRefreshTask = nil
            messageObservationGeneration = UUID()
            messageObservation?.cancel()
            messageObservation = nil
            messagePins?.stop(); messagePins = nil
            historyController?.cancel()
            historyController = nil
            historyViewportAtLatest = false
            observedReactionSnapshot = nil
            typingObservation?.cancel()
            typingObservation = nil
            locationObservation?.cancel()
            locationObservation = nil
            typingStopTask?.cancel()
            typingStopTask = nil
            isPartnerTyping = false
            notificationCoordinator
                .setActiveConversationForForegroundNotifications(nil)
        }
        if deletionWasObserved {
            reactionBurstReplayStore.remove(
                conversationID: conversationID,
                userID: currentUser.id
            )
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
        refreshPartner(conversationID: conversationID)
        updateForegroundNotificationConversation()
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

    private func reloadPendingShares() {
        do {
            queuedShares = try loadPendingShares()
            pendingShare = queuedShares.first
            let queuedIDs = Set(queuedShares.map(\.id))
            pendingShareTimelineStatuses =
                pendingShareTimelineStatuses.filter {
                    queuedIDs.contains($0.key)
                }
            for share in queuedShares
                where pendingShareTimelineStatuses[share.id] == nil
            {
                pendingShareTimelineStatuses[share.id] = .waiting
            }
            synchronizePendingShareMessages()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func sendQueuedSharesIfPossible() async {
        let sendingSession = sessionGeneration
        let sendingUserID = currentUser.id
        guard
            !isSendingQueuedShares,
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
                for id in staleIDs {
                    pendingShareTimelineStatuses[id] = nil
                    locallyPendingMessages[id] = nil
                    outgoingMessageDisplayDates[id] = nil
                }
                errorMessage =
                    "A shared item was not sent because its original conversation is no longer active."
                reloadPendingShares()
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }

        // Another drain may already be uploading when this draft arrives.
        // Keep its attachments behind the draft's text until that send has
        // completed, including drains started automatically by older batches.
        let sendableShares = queuedShares.prefix {
            !composerAttachmentsWaitingForText.contains($0.id)
        }.filter {
            $0.targetConversationID == targetConversationID
        }
        guard !sendableShares.isEmpty, !isSendingQueuedShares else {
            return
        }
        guard !sendableShares.contains(where: {
            if case .failed? = pendingShareTimelineStatuses[$0.id] {
                return true
            }
            return false
        }) else {
            synchronizePendingShareMessages()
            return
        }

        isSendingQueuedShares = true
        queuedShareErrorMessage = nil
        let attemptedShareIDs = Set(sendableShares.map(\.id))
        defer {
            if sessionGeneration == sendingSession {
                isSendingQueuedShares = false
                reloadPendingShares()
                let hasFailedShare = pendingShareTimelineStatuses.values
                    .contains {
                        if case .failed = $0 { return true }
                        return false
                    }
                if
                    !hasFailedShare,
                    queuedShares.contains(where: {
                        !attemptedShareIDs.contains($0.id)
                            && $0.targetConversationID == targetConversationID
                    })
                {
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
            pendingShareTimelineStatuses[share.id] = .sending
            let optimisticMessage = pendingShareMessage(for: share)
            registerOutgoingMessage(optimisticMessage)
            upsertMessage(optimisticMessage)

            do {
                var message = optimisticMessage
                if share.kind == .text || share.kind == .url {
                    guard
                        let body = share.text?.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ),
                        !body.isEmpty
                    else {
                        throw ShareMessageCommitRequestError.invalidPayload
                    }
                    message.body = body
                } else {
                    let attachment = try await attachments.upload(
                        share,
                        messageID: share.id,
                        conversationID: targetConversationID,
                        ownerID: sendingUserID
                    )
                    message.body = attachment.fileName
                    message.attachment = attachment
                }
                guard sessionGeneration == sendingSession else { return }
                guard conversationID == targetConversationID else {
                    try? acknowledgePendingShares([share.id])
                    queuedShares.removeAll { $0.id == share.id }
                    messages.removeAll { $0.id == share.id }
                    pendingShareTimelineStatuses[share.id] = nil
                    locallyPendingMessages[share.id] = nil
                    outgoingMessageDisplayDates[share.id] = nil
                    errorMessage =
                        "A shared item was not sent because its original conversation is no longer active."
                    break
                }
                upsertMessage(message)
                let sent = try await sendConfirmedMessage(
                    message,
                    conversationID: targetConversationID
                )
                guard sessionGeneration == sendingSession else { return }
                try acknowledgePendingShares([share.id])
                pendingShareTimelineStatuses[share.id] = nil
                queuedShares.removeAll { $0.id == share.id }
                pendingShare = queuedShares.first
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
                    pendingShareTimelineStatuses[share.id] = nil
                    locallyPendingMessages[share.id] = nil
                    outgoingMessageDisplayDates[share.id] = nil
                    errorMessage =
                        "A shared item was not retried after the active conversation changed."
                    break
                }
                let detail = error.localizedDescription
                pendingShareTimelineStatuses[share.id] = .failed(detail)
                if
                    let index = messages.firstIndex(
                        where: { $0.id == share.id }
                    )
                {
                    messages[index].deliveryState = .failed
                    locallyPendingMessages[share.id] = messages[index]
                }
                queuedShareErrorMessage = detail
                break
            }
        }
    }

    func pendingShareTimelineStatus(
        for messageID: UUID
    ) -> PendingShareTimelineStatus? {
        pendingShareTimelineStatuses[messageID]
    }

    private func synchronizePendingShareMessages() {
        messages = mergingPendingShareMessages(into: messages)
    }

    private func mergingPendingShareMessages(
        into sourceMessages: [ChatMessage]
    ) -> [ChatMessage] {
        guard let conversationID else { return sourceMessages }
        var merged = sourceMessages
        var presentIDs = Set(merged.map(\.id))
        for pending in locallyPendingMessages.values
            where presentIDs.insert(pending.id).inserted
        {
            merged.append(pending)
        }
        for share in queuedShares
            where share.targetConversationID == conversationID
        {
            let status =
                pendingShareTimelineStatuses[share.id] ?? .waiting
            let message = pendingShareMessage(for: share)
            if outgoingMessageDisplayDates[share.id] == nil {
                registerOutgoingMessage(message)
            }
            if let index = merged.firstIndex(where: { $0.id == share.id }) {
                merged[index].deliveryState = status.deliveryState
                continue
            }

            merged.append(message)
        }
        // Only local rows retain their presentation position while uploads
        // acquire a later server timestamp. Other rows keep server chronology,
        // including its original tie order. The message's actual date is
        // never overwritten for sorting.
        return submissionLedger.ordered(merged)
    }

    private func registerOutgoingMessage(_ message: ChatMessage) {
        submissionLedger.register(message, after: messages)
    }

    private func pendingShareMessage(
        for share: PendingShare
    ) -> ChatMessage {
        let status =
            pendingShareTimelineStatuses[share.id] ?? .waiting
        if share.kind == .text || share.kind == .url {
            let body = share.text ?? "Shared item"
            return ChatMessage(
                id: share.id,
                senderID: currentUser.id,
                kind: .forText(body),
                body: body,
                createdAt: share.createdAt,
                deliveryState: status.deliveryState,
                deliveryMode: share.deliveryMode
            )
        }

        let fileURL = try? stagedAttachmentURL(for: share)
        let byteSize: Int64
        if
            let fileURL,
            let values = try? fileURL.resourceValues(
                forKeys: [.fileSizeKey]
            )
        {
            byteSize = Int64(values.fileSize ?? 0)
        } else {
            byteSize = 0
        }
        let attachment = AttachmentContent(
            id: share.id.uuidString,
            type: LocalAttachmentService.attachmentType(for: share),
            storagePath: nil,
            fileName:
                share.originalFileName
                    ?? (share.isVoiceMessage
                        ? "Voice Message.m4a"
                        : "Shared attachment"),
            contentType:
                share.contentTypeIdentifier
                    .flatMap(UTType.init)?
                    .preferredMIMEType
                    ?? "application/octet-stream",
            byteSize: byteSize,
            audioDurationMilliseconds: share.voiceMessageDuration.map {
                Int(($0 * 1_000).rounded())
            }
        )
        return ChatMessage(
            id: share.id,
            senderID: currentUser.id,
            kind: share.isVoiceMessage ? .voice : .attachment,
            body: attachment.fileName,
            createdAt: share.createdAt,
            deliveryState: status.deliveryState,
            attachment: attachment,
            attachmentGroupID: share.attachmentGroupID,
            attachmentGroupIndex: share.attachmentGroupIndex,
            attachmentGroupCount: share.attachmentGroupCount,
            deliveryMode: share.deliveryMode
        )
    }

    func configureNotifications() async {
        let notificationSession = sessionGeneration
        guard usesFirebase else { return }
        installNotificationHandlersIfNeeded()
        if
            let pendingDeviceToken,
            deviceTokenSaveTask == nil
        {
            await persistDeviceToken(pendingDeviceToken)
            guard sessionGeneration == notificationSession else { return }
        }
        guard
            !notificationRegistrationSucceeded,
            !notificationRegistrationInFlight
        else {
            return
        }

        notificationRegistrationInFlight = true
        defer {
            if sessionGeneration == notificationSession { notificationRegistrationInFlight = false }
        }

        do {
            _ = try await notificationCoordinator
                .requestAuthorizationAndRegister()
        } catch {
            guard sessionGeneration == notificationSession else { return }
            errorMessage = error.localizedDescription
            scheduleNotificationRegistrationRetry()
        }
    }

    private func resetNotificationOperationsForAccountChange() {
        notificationRetryTask?.cancel(); notificationRetryTask = nil
        deviceTokenSaveTask?.cancel(); deviceTokenSaveTask = nil
        deviceTokenSaveOperationID = nil
        notificationRegistrationInFlight = false
        notificationRegistrationSucceeded = false
        notificationRetryAttempt = 0
        notificationHandlersInstalled = false
        // Retain any unpersisted device token so the new account can register it.
    }

    private func installNotificationHandlersIfNeeded() {
        guard !notificationHandlersInstalled else { return }
        notificationHandlersInstalled = true
        let notificationSession = sessionGeneration

        notificationCoordinator.setTokenHandler { [weak self] token in
            guard let self, self.sessionGeneration == notificationSession else { return }
            await self.persistDeviceToken(token)
        }
        notificationCoordinator.setActionHandler { [weak self] action in
            guard let self, self.sessionGeneration == notificationSession else { return }
            await self.handleNotificationAction(action)
        }
        notificationCoordinator.setRegistrationSuccessHandler { [weak self] in
            guard let self, self.sessionGeneration == notificationSession else { return }
            notificationRegistrationSucceeded = true
            notificationRetryAttempt = 0
            notificationRetryTask?.cancel()
            notificationRetryTask = nil
        }
        notificationCoordinator.setRegistrationErrorHandler {
            [weak self] error in
            guard let self, self.sessionGeneration == notificationSession else { return }
            notificationRegistrationSucceeded = false
            errorMessage = error.localizedDescription
            scheduleNotificationRegistrationRetry()
        }
    }

    private func persistDeviceToken(_ token: String) async {
        let tokenSession = sessionGeneration
        pendingDeviceToken = token
        deviceTokenSaveTask?.cancel()
        let operationID = UUID()
        deviceTokenSaveOperationID = operationID
        let userID = currentUser.id
        let task = Task { [weak self, profiles] in
            guard let self else { return false }
            do {
                try await BoundedNotificationRetry.run(
                    configuration: notificationRetryConfiguration
                ) {
                    guard self.sessionGeneration == tokenSession, self.deviceTokenSaveOperationID == operationID else { throw CancellationError() }
                    try await profiles.saveDeviceToken(
                        token,
                        userID: userID
                    )
                }
                return true
            } catch is CancellationError {
                return false
            } catch {
                guard self.sessionGeneration == tokenSession, self.deviceTokenSaveOperationID == operationID else { return false }
                errorMessage = error.localizedDescription
                return false
            }
        }
        deviceTokenSaveTask = task
        let saved = await task.value
        guard sessionGeneration == tokenSession, deviceTokenSaveOperationID == operationID else { return }
        deviceTokenSaveTask = nil
        deviceTokenSaveOperationID = nil
        if saved, pendingDeviceToken == token {
            pendingDeviceToken = nil
        }
    }

    private func scheduleNotificationRegistrationRetry() {
        let notificationSession = sessionGeneration
        notificationRetryTask?.cancel()
        guard
            notificationRetryAttempt
                < notificationRetryConfiguration.delays.count
        else {
            return
        }

        let delay = notificationRetryConfiguration.delays[
            notificationRetryAttempt
        ]
        notificationRetryAttempt += 1
        notificationRetryTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await notificationRetryConfiguration.sleep(delay)
            } catch {
                return
            }
            guard !Task.isCancelled, sessionGeneration == notificationSession else { return }
            await configureNotifications()
        }
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

    private func updateForegroundNotificationConversation() {
        notificationCoordinator
            .setActiveConversationForForegroundNotifications(
                conversationIsActuallyVisible
                    ? conversationID
                    : nil
            )
    }

    private var conversationIsActuallyVisible: Bool {
        conversationIsVisible
            && appIsActive
            && conversationObscurationSources.isEmpty
    }

    private func acknowledge(
        _ message: ChatMessage,
        markAsRead: Bool
    ) {
        guard let conversationID else { return }
        let needsDelivered = lastMarkedDeliveredMessageID != message.id
        let needsRead = markAsRead && historyIsRecent && (historyController == nil || historyViewportAtLatest) && lastMarkedReadMessageID != message.id
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
                if needsRead, historyIsRecent, historyController == nil || historyViewportAtLatest {
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

    func handleNotificationAction(
        _ action: MessageNotificationAction
    ) async {
        let notificationSession = sessionGeneration
        let notificationAccountID = currentUser.id
        switch action {
        case let .open(conversationID, _):
            if let conversationID {
                await enterConversation(conversationID)
            }

        case let .reply(text, conversationID, _):
            guard let conversationID = conversationID ?? self.conversationID else {
                return
            }
            let trimmed = text.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !trimmed.isEmpty else { return }
            if conversationID != self.conversationID {
                await enterConversation(conversationID)
            }
            guard sessionGeneration == notificationSession,
                  currentUser.id == notificationAccountID,
                  self.conversationID == conversationID else { return }
            let queuedReply = PendingShare(
                kind: .text,
                text: trimmed,
                conversationID: conversationID,
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

        case let .markRead(conversationID, messageID):
            guard
                let conversationID = conversationID ?? self.conversationID,
                let messageID
            else {
                return
            }
            do {
                try await messaging.markRead(
                    conversationID: conversationID,
                    userID: currentUser.id,
                    messageID: messageID
                )
            } catch {
                guard sessionGeneration == notificationSession else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func sendConfirmedMessage(
        _ message: ChatMessage,
        conversationID: String
    ) async throws -> ChatMessage {
        let sendingSession = sessionGeneration
        let recipient = partner
        let sent = try await messaging.send(
            message,
            conversationID: conversationID
        )
        guard sessionGeneration == sendingSession else { throw CancellationError() }
        outgoingMessageIntentDonor.donate(
            message: sent,
            conversationID: conversationID,
            recipient: recipient
        )
        return sent
    }
}
