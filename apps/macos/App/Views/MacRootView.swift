import AuthenticationServices
import SwiftUI

struct MacRootView: View {
    @Environment(MacAppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch model.phase {
            case .welcome:
                MacWelcomeView()
            case .restoringConversation:
                OnboardingWelcomeContent {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 50)
                        .accessibilityLabel("Opening your conversation")
                }
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
                } else { MacPairingView() }
            case .waitingForPartner:
                MacWaitingForPartnerView()
            case .conversation:
                MacConversationView()
            case .configurationError:
                MacConfigurationErrorView()
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
        .frame(minWidth: 440, minHeight: 520)
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        model.errorMessage = nil
                    }
                }
            )
        ) {
            Button("OK") {
                model.errorMessage = nil
            }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.conversationVisibilityDidChange(
                isVisible: model.phase == .conversation,
                isAppActive: phase == .active
            )
        }
    }
}

private struct MacWelcomeView: View {
    @Environment(MacAppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @State private var currentNonce: String?

    var body: some View {
        OnboardingWelcomeContent {
            SignInWithAppleButton(.continue) { request in
                request.requestedScopes = [.fullName, .email]
                do {
                    let nonce = try SignInNonce.random()
                    currentNonce = nonce
                    request.nonce = SignInNonce.hash(nonce)
                } catch {
                    model.errorMessage = error.localizedDescription
                }
            } onCompletion: { result in
                switch result {
                case let .success(authorization):
                    Task {
                        await model.finishSignIn(
                            authorization: authorization,
                            rawNonce: currentNonce
                        )
                    }
                case let .failure(error):
                    model.errorMessage = error.localizedDescription
                }
            }
            .signInWithAppleButtonStyle(scheme == .dark ? .white : .black)
            .frame(height: 50)
            .clipShape(.rect(cornerRadius: 13))
            .overlay(alignment: .leading) {
                if model.isWorking || model.isPreparingAccount {
                    ProgressView().controlSize(.small)
                        .tint(scheme == .dark ? .black : .white)
                        .frame(width: 18, height: 18).padding(.leading, 14)
                        .accessibilityHidden(true)
                }
            }
            .disabled(model.isWorking || model.isPreparingAccount)
        }
    }
}

private struct MacPairingView: View {
    @Environment(MacAppModel.self) private var model
    @State private var code = ""

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "person.2.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.indigo)

            VStack(spacing: 8) {
                Text("Connect your conversation")
                    .font(.largeTitle.bold())
                Text(
                    "Invite someone or join with their invitation."
                )
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)
            }

            VStack(spacing: 12) {
                Button {
                    Task {
                        await model.createConversation()
                    }
                } label: {
                    Label("Create a pairing code", systemImage: "qrcode")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                HStack {
                    Rectangle()
                        .frame(height: 1)
                        .foregroundStyle(.quaternary)
                    Text("or")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Rectangle()
                        .frame(height: 1)
                        .foregroundStyle(.quaternary)
                }

                TextField("8-character code", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3.monospaced())
                    .multilineTextAlignment(.center)
                    .onChange(of: code) { _, newValue in
                        code = PairingCode.editableValue(newValue)
                    }
                    .onSubmit(join)

                Button("Join conversation", action: join)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(
                        PairingCode.canonicalValue(code) == nil
                            || model.isWorking
                    )
            }
            .frame(width: 340)

            Spacer()

            Button("Sign Out") {
                Task {
                    await model.signOut()
                }
            }
            .buttonStyle(.link)
            .disabled(model.isWorking)
        }
        .padding(36)
        .overlay {
            if model.isWorking {
                ProgressView()
                    .controlSize(.large)
            }
        }
    }

    private func join() {
        guard PairingCode.canonicalValue(code) != nil else { return }
        Task {
            await model.joinConversation(code: code)
        }
    }
}

private struct MacWaitingForPartnerView: View {
    @Environment(MacAppModel.self) private var model
    @State private var copied = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            ProgressView()
                .controlSize(.large)

            VStack(spacing: 8) {
                Text("Waiting for the other person")
                    .font(.largeTitle.bold())
                Text("Share this one-time code with them.")
                    .foregroundStyle(.secondary)
            }

            Button {
                copied = model.copyPairingCode()
            } label: {
                Text(PairingCode.formatted(model.pairingCode))
                    .font(.system(.title, design: .monospaced).bold())
                    .padding(.horizontal, 22)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.bordered)
            .help("Copy pairing code")

            if copied {
                Label("Copied", systemImage: "checkmark")
                    .foregroundStyle(.secondary)
            }

            if let link = model.pairingLink {
                ShareLink(
                    item: link,
                    subject: Text("Join me on Peapod"),
                    message: Text(
                        "Open this link to join our Peapod conversation."
                    )
                ) {
                    Label("Share invitation", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
            }

            if let expiresAt = model.pairingCodeExpiresAt {
                Text("Expires \(expiresAt, style: .relative)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Button("Cancel pairing", role: .cancel) {
                Task {
                    await model.cancelPairing()
                }
            }
            .disabled(model.isWorking)
            .accessibilityHint(
                "Invalidates this invite and returns to pairing choices."
            )

            Spacer()

            Button("Sign Out") {
                Task {
                    await model.signOut()
                }
            }
            .buttonStyle(.link)
        }
        .padding(36)
    }
}

private struct MacProgressView: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 18) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .font(.title2.bold())
            Text(subtitle)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MacConfigurationErrorView: View {
    @Environment(MacAppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label(
                "Firebase configuration required",
                systemImage: "wrench.and.screwdriver"
            )
        } description: {
            Text(
                model.errorMessage
                    ?? "This build is missing its Firebase configuration."
            )
        }
        .padding(40)
    }
}
