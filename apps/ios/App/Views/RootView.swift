import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.phase {
            case .welcome:
                WelcomeView()
            case .restoringConversation:
                RestoringConversationView()
            case .pairing:
                if let encryption = model.encryption,
                   encryption.requiresSecurePairing || encryption.resetRecoveryBlocked || model.secureConversationWaitingID != nil {
                    SecureConnectionView(services: encryption,
                        waitingForKey: model.secureConversationWaitingID != nil,
                        hasInvitation: model.hasPendingSecureInvitation,
                        acceptInvitation: model.acceptSecureInvitation,
                        dismissInvitation: model.dismissSecureInvitation,
                        refresh: model.refreshSecureConnection, signOut: model.signOut,
                        isWorking: model.isWorking || model.isPreparingAccount, retryReset: model.retrySecureReset,
                        isOpeningConversation: model.secureConversationIsOpening)
                } else { PairingView() }
            case .waitingForPartner:
                WaitingForPartnerView()
            case .conversation:
                ConversationView()
                    .id(ConversationScreenIdentity(accountID: model.currentUser.id, conversationID: model.conversationID))
            case .configurationError:
                ConfigurationErrorView()
            }
        }
        .environment(\.encryptedAttachmentResolver, model.encryption?.resolver)
        .onChange(of: model.encryption?.verifiedConversationDeletionID) { _, target in
            guard let target else { return }
            Task { await model.finishSecureConversationDeletion(target) }
        }
        .onChange(of: model.encryption?.accountInvalidationID) { _, event in
            guard event != nil else { return }
            Task { await model.reconcileSecureAuthentication() }
        }
        .onChange(of: model.encryption?.contentErrorMessage) { _, message in
            if message != nil { model.secureSessionInvalidated() }
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: {
                    model.errorMessage != nil
                        && model.phase != .configurationError
                },
                set: { isPresented in
                    if !isPresented {
                        model.errorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                model.errorMessage = nil
            }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onChange(of: isPresentingRootAlert, initial: true) {
            _, isPresented in
            model.conversationObscurationDidChange(
                .rootAlert,
                isObscured: isPresented
            )
        }
        .onDisappear {
            model.conversationObscurationDidChange(
                .rootAlert,
                isObscured: false
            )
        }
    }

    private var isPresentingRootAlert: Bool {
        model.errorMessage != nil
            && model.phase != .configurationError
    }
}

private struct RestoringConversationView: View {
    var body: some View {
        OnboardingWelcomeContent {
            ProgressView().frame(maxWidth: .infinity, minHeight: 50)
                .accessibilityLabel("Opening your conversation")
        }
    }
}

private struct ConfigurationErrorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("Setup needed", systemImage: "wrench.and.screwdriver")
        } description: {
            Text(model.errorMessage ?? "Peapod is not connected to its service.")
        }
        .padding()
    }
}

private struct ConversationScreenIdentity: Hashable {
    let accountID: String
    let conversationID: String?
}
