import SwiftUI
import Observation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The invitation is recovered only on an explicit copy action, never retained in UI state.
struct SecureConnectionView: View {
    let services: EncryptedAppServices
    let waitingForKey: Bool
    let hasInvitation: Bool
    let acceptInvitation: @MainActor () async -> Void
    let dismissInvitation: @MainActor () -> Void
    let refresh: @MainActor () async -> Void
    let signOut: @MainActor () async -> Void
    let isWorking: Bool
    let retryReset: @MainActor () async -> Void
    var isOpeningConversation = false
    @Environment(\.colorScheme) private var scheme
    @State private var showingJoin = false
    @State private var showingHelp = false
    @State private var input = ""
    @State private var isVisible = false
    @State private var copyState = SecureInvitationCopyState()
    @State private var lastInvitationWasCreator: Bool?
    @State private var work: Work?
    @State private var workID: UUID?
    @State private var refreshTask: Task<Void, Never>?
    @State private var refreshID: UUID?
    private enum Work { case begin, copy, cancel, join, accept, retry }

    private var busy: Bool {
        work != nil || isWorking || copyState.isCopying
            || (refreshTask == nil && services.pairingClient?.isBusy == true)
    }

    private var preparingConnection: Bool {
        work == .begin || work == .join || work == .accept
    }

    // The SDK consumes its pending handle before trusted content activation.
    // Retain the waiting presentation across that handoff, never a choice-page flash.
    private var invitationWasCreator: Bool? {
        guard let client = services.pairingClient else { return nil }
        if let handle = client.pendingHandle { return handle.scope.role == .creator }
        if client.completedCapsule != nil || isOpeningConversation { return lastInvitationWasCreator }
        return nil
    }
    private var isCompletingConnection: Bool {
        isOpeningConversation || services.pairingClient?.completedCapsule != nil
    }
    private var showingKeyRecovery: Bool {
        waitingForKey && !isOpeningConversation && !preparingConnection
    }

    var body: some View {
        OnboardingFrame {
            HStack {
                if showingJoin && !hasInvitation && (services.pairingClient?.pendingHandle == nil || preparingConnection) && !waitingForKey {
                    Button { input = ""; showingJoin = false } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .disabled(busy)
                }
                Spacer()
                Menu {
                    Button("Sign out") {
                        clearPresentation()
                        Task { await signOut() }
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.title3)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Account options")
                .disabled(busy)
            }
        } hero: {
            statusContent
            if let error = services.pairingClient?.errorMessage, !services.resetRecoveryBlocked {
                Text(error).font(.callout).foregroundStyle(OnboardingStyle.secondary(scheme))
            }
            if let error = copyState.errorMessage {
                Text(error).font(.callout).foregroundStyle(OnboardingStyle.secondary(scheme))
            }
        } actions: {
            actions
        }
        .onAppear {
            isVisible = true
            if let handle = services.pairingClient?.pendingHandle { lastInvitationWasCreator = handle.scope.role == .creator }
        }
        .alert("Can’t open your chat?", isPresented: $showingHelp) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(services.needsFreshEncryptedConversation
                 ? "This account is assigned to a conversation that this build cannot open. Contact your deployment operator before pairing again. Your existing messages and media stay stored."
                 : "Check your connection and make sure Passwords & Keychain is turned on in iCloud Settings. Use the same Apple Account in iCloud as your other Peapod device. Your conversation stays in place while you restore access.")
        }
        .onChange(of: services.pairingClient?.pendingHandle?.scope.inviteID) { _, _ in
            // Local persistence precedes the first relay request. Keep the
            // originating page until that explicit request has finished.
            if let handle = services.pairingClient?.pendingHandle { lastInvitationWasCreator = handle.scope.role == .creator }
            if !preparingConnection && !isCompletingConnection { clearPresentation() }
        }
        .onChange(of: hasInvitation) { _, _ in clearPresentation() }
        .onChange(of: services.resetRecoveryBlocked) { _, blocked in if blocked { clearPresentation() } }
        .task {
            while !Task.isCancelled {
                if !busy {
                    let id = UUID()
                    let task = Task { await refresh() }
                    refreshID = id
                    refreshTask = task
                    await task.value
                    if refreshID == id {
                        refreshTask = nil
                        refreshID = nil
                    }
                }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
        .onDisappear {
            isVisible = false
            workID = nil; work = nil
            refreshTask?.cancel()
            refreshTask = nil; refreshID = nil
            clearPresentation()
        }
    }

    @ViewBuilder private var statusContent: some View {
        if services.resetRecoveryBlocked {
            OnboardingHeading(title: "Finish conversation reset", symbol: "arrow.clockwise")
            Text(services.resetErrorMessage ?? "A reset is in progress. Finish it before making a new connection.")
                .foregroundStyle(OnboardingStyle.secondary(scheme))
        } else if showingKeyRecovery {
            if services.needsFreshEncryptedConversation {
                OnboardingHeading(title: "Existing conversation needs attention", symbol: "bubble.left.and.bubble.right")
                Text("Contact your deployment operator to resolve this account’s existing conversation before pairing again. Your history stays stored.")
                    .foregroundStyle(OnboardingStyle.secondary(scheme))
            } else {
                ProgressView().controlSize(.large).accessibilityLabel("Waiting for your conversation key")
                Text("Opening your conversation").font(.title2.bold())
                Text("Waiting for your conversation key. Check your connection and keep iCloud Passwords & Keychain turned on.")
                    .foregroundStyle(OnboardingStyle.secondary(scheme))
            }
        } else if let client = services.pairingClient {
            if let isCreator = invitationWasCreator, !preparingConnection {
                OnboardingWaitingIndicator()
                Text("Waiting for your person")
                    .font(.system(size: 23, weight: .semibold)).tracking(-0.5)
                Text(isCreator
                     ? "Your chat opens when they join."
                     : "They’re finishing the connection.")
                    .font(.subheadline).foregroundStyle(OnboardingStyle.secondary(scheme))
            } else if hasInvitation || work == .accept {
                OnboardingHeading(title: "You’re invited", symbol: "bubble.left.and.bubble.right")
            } else if showingJoin {
                OnboardingHeading(title: "Paste your invitation", symbol: "link")
            } else {
                OnboardingHeading(title: "Who’s your person?", symbol: "bubble.left.and.bubble.right")
            }
        } else {
            OnboardingHeading(title: "Secure storage is unavailable", symbol: "key")
            Text("Try again to open your conversation.").foregroundStyle(OnboardingStyle.secondary(scheme))
        }
    }

    @ViewBuilder private var actions: some View {
        if services.resetRecoveryBlocked {
            OnboardingActionButton(title: "Retry reset cleanup", isLoading: work == .retry) {
                perform(.retry, retryReset)
            }.disabled(busy)
        } else if showingKeyRecovery {
            OnboardingActionButton(title: "Try again", isLoading: work == .retry) {
                perform(.retry, refresh)
            }.disabled(busy)
            OnboardingActionButton(title: "Get help", secondary: true) { showingHelp = true }.disabled(busy)
        } else if let client = services.pairingClient {
            if let isCreator = invitationWasCreator, !preparingConnection {
                if isCreator {
                    let invitationID = client.pendingHandle?.scope.inviteID
                    OnboardingActionButton(title: copyState.copied ? "Copied" : "Copy link",
                        isLoading: work == .copy || copyState.isCopying, checkmark: copyState.copied,
                        dimsWhenDisabled: !isCompletingConnection) {
                        perform(.copy) {
                            await copyState.copy(load: { await client.sharingURL()?.absoluteString },
                                isCurrent: {
                                    isVisible && services.pairingClient === client && !services.resetRecoveryBlocked
                                        && invitationID != nil && client.pendingHandle?.scope.inviteID == invitationID
                                        && client.pendingHandle?.scope.role == .creator
                                }, write: Self.copyInvitation)
                        }
                    }
                    .disabled(busy || isCompletingConnection)
                    .accessibilityIdentifier("secure-invitation-copy")
                }
                OnboardingActionButton(title: "Cancel", isLoading: work == .cancel, secondary: true,
                    dimsWhenDisabled: !isCompletingConnection) {
                    perform(.cancel) { clearPresentation(); await client.cancel() }
                }
                .disabled(busy || isCompletingConnection)
                .accessibilityIdentifier("secure-invitation-cancel")
            } else if hasInvitation || work == .accept {
                OnboardingActionButton(title: "Join conversation", isLoading: work == .accept) {
                    perform(.accept, acceptInvitation)
                }.disabled(busy)
                OnboardingActionButton(title: "Not now", secondary: true) { dismissInvitation() }.disabled(busy)
            } else if showingJoin {
                TextField("peapod://secure-pair#…", text: $input)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .padding(14)
                    .background(OnboardingStyle.background(scheme), in: .rect(cornerRadius: 12))
                    .overlay { RoundedRectangle(cornerRadius: 12).stroke(OnboardingStyle.secondary(scheme).opacity(0.3)) }
                    .autocorrectionDisabled()
#if os(iOS)
                    .textInputAutocapitalization(.never)
#endif
                    .privacySensitive()
                    .accessibilityLabel("Invitation link")
                    .accessibilityIdentifier("secure-invitation-input")
                    .onSubmit { join(client) }
                    .disabled(busy)
                OnboardingActionButton(title: "Join conversation", isLoading: work == .join) { join(client) }
                    .disabled(busy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                OnboardingActionButton(title: "Begin encrypted chat", isLoading: work == .begin) {
                    perform(.begin) { copyState.reset(); await client.createInvite() }
                }
                .disabled(busy)
                .accessibilityIdentifier("secure-invitation-create")
                OnboardingActionButton(title: "I have an invitation", secondary: true) { showingJoin = true }
                    .disabled(busy)
                    .accessibilityIdentifier("secure-invitation-enter")
            }
        } else {
            OnboardingActionButton(title: "Try again", isLoading: work == .retry) { perform(.retry, refresh) }.disabled(busy)
        }
    }

    private func perform(_ operation: Work, _ action: @escaping @MainActor () async -> Void) {
        guard !busy else { return }
        let id = UUID()
        let pendingRefresh = refreshTask
        workID = id
        if operation == .begin { lastInvitationWasCreator = true }
        if operation == .join || operation == .accept { lastInvitationWasCreator = false }
        work = operation
        Task {
            defer {
                if workID == id { work = nil; workID = nil }
            }
            // The facade serializes operations. A Copy tap waits for an
            // in-flight poll instead of failing its busy guard. Cancel already
            // safely supersedes an in-flight advance in the facade.
            if operation != .cancel { await pendingRefresh?.value }
            guard isVisible, workID == id else { return }
            await action()
            guard workID == id else { return }
            if preparingConnection, services.pairingClient?.pendingHandle != nil {
                clearPresentation()
            }
        }
    }

    private func join(_ client: SecurePairingClient) {
        guard !busy, !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let invitation = input.trimmingCharacters(in: .whitespacesAndNewlines)
        perform(.join) { await client.joinInvite(invitation); await refresh() }
    }

    private func clearPresentation() {
        input = ""; showingJoin = false; showingHelp = false; copyState.reset()
    }

    private static func copyInvitation(_ value: String) -> Bool {
#if os(iOS)
        UIPasteboard.general.setItems([["public.utf8-plain-text": value]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(15 * 60)])
        return true
#elseif os(macOS)
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(value, forType: .string)
#else
        return false
#endif
    }
}

/// Only presentation status is retained; cancellation/account changes fence delayed secret reads.
@MainActor @Observable
final class SecureInvitationCopyState {
    private(set) var copied = false
    private(set) var isCopying = false
    private(set) var errorMessage: String?
    @ObservationIgnored private var generation = UUID()

    func reset() {
        generation = UUID(); copied = false; isCopying = false; errorMessage = nil
    }

    func copy(load: @MainActor () async -> String?, isCurrent: @MainActor () -> Bool,
              write: @MainActor (String) -> Bool) async {
        guard !isCopying, isCurrent() else { return }
        let pinned = generation
        isCopying = true; errorMessage = nil; copied = false
        defer { if generation == pinned { isCopying = false } }
        let invitation = await load()
        guard generation == pinned, !Task.isCancelled, isCurrent() else { return }
        guard let invitation, write(invitation) else {
            errorMessage = "The invitation could not be copied. Try again."
            return
        }
        copied = true
    }
}
