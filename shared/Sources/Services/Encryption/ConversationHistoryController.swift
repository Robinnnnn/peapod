import Foundation
import Observation

/// Owns three bounded plaintext views: timeline, newest delivery window, and one search page.
/// Cancellation fences callbacks even when a transport delivers an already queued result.
@MainActor @Observable
final class ConversationHistoryController {
    private(set) var window: MessageHistoryWindowSnapshot?
    private(set) var search: MessageHistorySearchSnapshot?
    private(set) var isLoading = false
    private(set) var isSearching = false
    private(set) var query = ""
    private(set) var searchRevision = 0
    private(set) var newestMessageID: UUID?
    private var stopped = false
    private var followingLatest = true
    private var windowGeneration = UUID()
    private var searchGeneration = UUID()
    private var acceptedObservation: HistoryCandidateObservation?
    private var candidateObservation: HistoryCandidateObservation?
    private var newestObservation: ServiceObservation?
    private var searchObservation: ServiceObservation?
    private let provider: any MessageHistoryWindowProviding
    private let conversationID: String
    private let accountID: String
    private let onWindow: (Result<MessageHistorySnapshot, Error>) -> Void
    private let onNewest: ([ChatMessage]) -> Void
    private let onError: (Error) -> Void

    var isRecentVisible: Bool { followingLatest && window?.isRecentWindow == true && query.isEmpty && !isLoading }
    // Navigation intent is separate from readiness: initial/recent refreshes
    // must not look like the user requested an older-history window.
    var isBrowsingHistory: Bool { !followingLatest && window != nil && query.isEmpty }
    var hasOlder: Bool { window?.hasOlder == true }
    var hasNewer: Bool { window?.hasNewer == true }

    init(provider: any MessageHistoryWindowProviding, conversationID: String, accountID: String,
         onWindow: @escaping (Result<MessageHistorySnapshot, Error>) -> Void,
         onNewest: @escaping ([ChatMessage]) -> Void, onError: @escaping (Error) -> Void) {
        self.provider = provider; self.conversationID = conversationID; self.accountID = accountID
        self.onWindow = onWindow; self.onNewest = onNewest; self.onError = onError
    }
    func start() {
        guard !stopped, newestObservation == nil else { return }
        load(.recent())
        guard !stopped else { return }
        let newest = provider.observeHistoryWindow(conversationID: conversationID, currentUserID: accountID,
            request: .recent()) { [weak self] result in
                guard let self, !self.stopped else { return }
                switch result {
                case .success(let value):
                    self.newestMessageID = value.history.messages.last?.id
                    self.onNewest(value.history.messages)
                case .failure(let error): self.onError(error)
                }
            }
        if stopped { newest.cancel() } else { newestObservation = newest }
    }
    func older() { if !isLoading, let request = window?.olderRequest { followingLatest = false; load(request) } }
    func newer() { if !isLoading, let request = window?.newerRequest { load(request) } }
    func latest() { followingLatest = true; load(.recent()) }
    func around(_ id: UUID) { followingLatest = false; load(.around(messageID: id)) }
    func searchFor(_ text: String) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized != query else { return }
        query = normalized
        beginSearch(continuation: nil)
    }
    func moreSearchResults() {
        guard !isSearching, let continuation = search?.continuation else { return }
        beginSearch(continuation: continuation)
    }
    func cancel() {
        stopped = true; windowGeneration = UUID(); searchGeneration = UUID()
        acceptedObservation?.cancel(); candidateObservation?.cancel(); newestObservation?.cancel(); searchObservation?.cancel()
        acceptedObservation = nil; candidateObservation = nil; newestObservation = nil; searchObservation = nil
        window = nil; search = nil; isLoading = false; isSearching = false
    }
    private func load(_ request: MessageHistoryWindowRequest) {
        guard !stopped else { return }
        let generation = UUID(); windowGeneration = generation
        candidateObservation?.cancel()
        let candidate = HistoryCandidateObservation(generation: generation)
        candidateObservation = candidate
        isLoading = true
        let observation = provider.observeHistoryWindow(conversationID: conversationID, currentUserID: accountID,
            request: request) { [weak self, weak candidate] result in
                guard let self, let candidate, !self.stopped,
                      self.windowGeneration == generation || self.acceptedObservation === candidate else { return }
                // The accepted subscription still owns the displayed descriptors. Keep its
                // live snapshots visible during a candidate load so UI and its pins agree.
                if self.candidateObservation === candidate || self.candidateObservation == nil { self.isLoading = false }
                switch result {
                case .success(let value):
                    if self.candidateObservation === candidate {
                        self.acceptedObservation?.cancel()
                        self.acceptedObservation = candidate
                        self.candidateObservation = nil
                    }
                    self.window = value
                    self.onWindow(.success(value.history))
                case .failure(let error):
                    if self.candidateObservation === candidate {
                        candidate.cancel(); self.candidateObservation = nil
                        // Resume the still-pinned accepted subscription after a failed candidate.
                        if let accepted = self.acceptedObservation { self.windowGeneration = accepted.generation }
                    }
                    self.onWindow(.failure(error))
                }
            }
        candidate.install(observation)
    }
    private func beginSearch(continuation: MessageHistorySearchContinuation?) {
        let generation = UUID(); searchGeneration = generation
        searchObservation?.cancel(); searchObservation = nil; search = nil; searchRevision &+= 1
        isSearching = false
        guard !stopped, !query.isEmpty else { return }
        isSearching = true
        let observation = provider.searchHistory(conversationID: conversationID, currentUserID: accountID,
            query: query, continuation: continuation) { [weak self] result in
                guard let self, !self.stopped, self.searchGeneration == generation else { return }
                switch result {
                case .success(let value):
                    self.search = value; self.searchRevision &+= 1
                    self.isSearching = !value.isComplete && value.continuation == nil
                case .failure(let error): self.isSearching = false; self.onError(error)
                }
            }
        if stopped || searchGeneration != generation { observation.cancel() }
        else { searchObservation = observation }
    }
}

/// Handles providers which synchronously publish before returning their cancellation handle.
@MainActor private final class HistoryCandidateObservation {
    let generation: UUID
    private var observation: ServiceObservation?
    private var cancelled = false
    init(generation: UUID) { self.generation = generation }
    func install(_ observation: ServiceObservation) {
        if cancelled { observation.cancel() } else { self.observation = observation }
    }
    func cancel() { cancelled = true; observation?.cancel(); observation = nil }
}
