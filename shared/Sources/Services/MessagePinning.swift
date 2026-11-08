import Foundation
import Observation

enum MessagePinningError: LocalizedError {
    case unavailable
    case invalidPage

    var errorDescription: String? {
        switch self {
        case .unavailable: "Pinned messages are unavailable. Please try again."
        case .invalidPage: "This pinned message page could not be loaded."
        }
    }
}

enum MessagePinningPolicy {
    /// A Firestore document-ID query can hydrate one bounded page independently of the timeline.
    static let pageSize = 30

    static func canPin(_ message: ChatMessage) -> Bool {
        !message.isUnsent && message.deliveryState != .sending && message.deliveryState != .failed
    }
}

extension MessagingProviding {
    func observeMessagePins(conversationID: String, currentUserID: String,
                            onChange: @escaping (Result<[UUID], Error>) -> Void) -> ServiceObservation {
        onChange(.success([]))
        return ServiceObservation()
    }

    func setMessagePinned(_ pinned: Bool, conversationID: String, messageID: UUID,
                          currentUserID: String) async throws {
        throw MessagePinningError.unavailable
    }

    func observeMessagesByID(conversationID: String, currentUserID: String, messageIDs: [UUID],
                             onChange: @escaping (Result<MessageHistorySnapshot, Error>) -> Void) -> ServiceObservation {
        onChange(.failure(MessagePinningError.unavailable))
        return ServiceObservation()
    }
}

/// Pin membership is lightweight conversation metadata. Decrypted contents and their attachment
/// leases exist only while the list is open, one independently hydrated page at a time.
@MainActor @Observable
final class MessagePinsController {
    private(set) var messageIDs: [UUID] = []
    private(set) var messages: [ChatMessage] = []
    private(set) var replyMessages: [UUID: ChatMessage] = [:]
    private(set) var isLoading = false
    var errorMessage: String? { membershipError ?? contentError ?? actionError }
    private var membershipError: String?
    private var contentError: String?
    private var actionError: String?
    private(set) var pendingMessageIDs: Set<UUID> = []
    private(set) var pageIndex = 0
    private var isOpen = false
    private var stopped = false
    private var started = false
    private var membershipIsLoading = true
    private var actionGeneration = UUID()
    private var membershipGeneration = UUID()
    private var pageGeneration = UUID()
    private var membership: ServiceObservation?
    private var contents: ServiceObservation?
    private let provider: any MessagingProviding
    private let conversationID: String
    private let currentUserID: String
    private let onError: (Error) -> Void

    var pageCount: Int { max(1, (messageIDs.count + MessagePinningPolicy.pageSize - 1) / MessagePinningPolicy.pageSize) }
    var hasPreviousPage: Bool { pageIndex > 0 }
    var hasNextPage: Bool { pageIndex + 1 < pageCount }

    init(provider: any MessagingProviding, conversationID: String, currentUserID: String,
         onError: @escaping (Error) -> Void = { _ in }) {
        self.provider = provider
        self.conversationID = conversationID
        self.currentUserID = currentUserID
        self.onError = onError
    }

    func isPinned(_ id: UUID) -> Bool { messageIDs.contains(id) }

    func start() {
        guard !stopped, !started else { return }
        started = true
        observeMembership()
    }

    func open() {
        guard !stopped, !isOpen else { return }
        isOpen = true
        start()
        loadPage()
    }

    func close() {
        isOpen = false
        pageGeneration = UUID()
        contents?.cancel(); contents = nil
        messages = []; replyMessages = [:]; isLoading = false
        contentError = nil; actionError = nil
    }

    func nextPage() { guard hasNextPage else { return }; pageIndex += 1; loadPage() }
    func previousPage() { guard hasPreviousPage else { return }; pageIndex -= 1; loadPage() }

    func retry() {
        guard !stopped else { return }
        actionError = nil
        observeMembership()
        loadPage()
    }

    func setPinned(_ pinned: Bool, message: ChatMessage) async {
        guard !stopped, !pendingMessageIDs.contains(message.id),
              !pinned || MessagePinningPolicy.canPin(message) else { return }
        let generation = actionGeneration
        actionError = nil
        pendingMessageIDs.insert(message.id)
        defer { if actionGeneration == generation { pendingMessageIDs.remove(message.id) } }
        do {
            try await provider.setMessagePinned(pinned, conversationID: conversationID,
                                                messageID: message.id, currentUserID: currentUserID)
        } catch {
            guard !stopped, actionGeneration == generation else { return }
            actionError = error.localizedDescription
            onError(error)
        }
    }

    func stop() {
        stopped = true
        actionGeneration = UUID()
        membershipGeneration = UUID()
        membership?.cancel(); membership = nil
        close()
        messageIDs = []; pendingMessageIDs = []; membershipError = nil
    }

    private func observeMembership() {
        membership?.cancel()
        let generation = UUID(); membershipGeneration = generation
        membershipIsLoading = true
        let observation = provider.observeMessagePins(conversationID: conversationID, currentUserID: currentUserID) { [weak self] result in
            guard let self, !self.stopped, self.membershipGeneration == generation else { return }
            switch result {
            case .success(let ids):
                self.membershipIsLoading = false
                guard Set(ids).count == ids.count else {
                    self.membershipError = MessagePinningError.invalidPage.localizedDescription
                    self.isLoading = false
                    return
                }
                self.membershipError = nil
                if self.messageIDs != ids {
                    self.messageIDs = ids
                    self.pageIndex = min(self.pageIndex, self.pageCount - 1)
                    self.loadPage()
                } else if self.contents == nil {
                    self.loadPage()
                }
            case .failure(let error):
                self.membershipIsLoading = false
                self.membershipError = error.localizedDescription
                self.isLoading = false
            }
        }
        if stopped || membershipGeneration != generation { observation.cancel() }
        else { membership = observation }
    }

    private func loadPage() {
        guard !stopped, isOpen else { return }
        let generation = UUID(); pageGeneration = generation
        contents?.cancel(); contents = nil
        messages = []; replyMessages = [:]
        contentError = nil
        let ids = Array(messageIDs.dropFirst(pageIndex * MessagePinningPolicy.pageSize).prefix(MessagePinningPolicy.pageSize))
        isLoading = !ids.isEmpty || membershipIsLoading
        guard !ids.isEmpty else { return }
        let observation = provider.observeMessagesByID(conversationID: conversationID, currentUserID: currentUserID, messageIDs: ids) { [weak self] result in
            guard let self, !self.stopped, self.isOpen, self.pageGeneration == generation else { return }
            self.isLoading = false
            switch result {
            case .success(let snapshot):
                let allowed = Set(ids)
                guard snapshot.messages.count <= ids.count,
                      Set(snapshot.messages.map(\.id)).count == snapshot.messages.count,
                      snapshot.messages.allSatisfy({ allowed.contains($0.id) }) else {
                    self.contentError = MessagePinningError.invalidPage.localizedDescription
                    self.messages = []; self.replyMessages = [:]
                    return
                }
                self.contentError = nil
                let byID = Dictionary(uniqueKeysWithValues: snapshot.messages.map { ($0.id, $0) })
                self.messages = ids.compactMap { byID[$0] }.filter { !$0.isUnsent }
                self.replyMessages = snapshot.replyMessages
            case .failure(let error):
                self.contentError = error.localizedDescription
                self.messages = []; self.replyMessages = [:]
            }
        }
        if stopped || pageGeneration != generation || !isOpen { observation.cancel() }
        else { contents = observation }
    }
}
