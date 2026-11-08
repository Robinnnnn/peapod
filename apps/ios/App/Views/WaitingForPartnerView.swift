import SwiftUI

struct WaitingForPartnerView: View {
    @Environment(AppModel.self) private var model
    @State private var didCopyCode = false

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                ScrollView {
                    Group {
                        if isExpired(at: context.date) {
                            expiredContent
                        } else {
                            activeInviteContent
                        }
                    }
                    .frame(maxWidth: 520)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 48)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Pair")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        Task {
                            await model.cancelPairing()
                        }
                    }
                    .accessibilityIdentifier("cancel-pairing")
                    .accessibilityLabel("Cancel pairing")
                    .accessibilityHint(
                        "Invalidates this invite and returns to pairing choices."
                    )
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SessionActionsMenu(hasConversation: false)
                }
            }
            .disabled(model.isWorking)
            .overlay {
                if model.isWorking {
                    ProgressView()
                        .padding()
                        .background(.regularMaterial, in: .rect(cornerRadius: 16))
                }
            }
        }
    }

    private var activeInviteContent: some View {
        VStack(spacing: 28) {
            Image(systemName: "person.badge.clock")
                .font(.system(size: 48))
                .foregroundStyle(.indigo)

            VStack(spacing: 10) {
                Text("Invite your person")
                    .font(.largeTitle.bold())
                Text(
                    "Open Peapod on their phone and enter this one-time code."
                )
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            }

            Text(PairingCode.formatted(model.pairingCode))
                .font(.system(.title, design: .monospaced, weight: .bold))
                .textSelection(.enabled)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(.quaternary, in: .rect(cornerRadius: 16))
                .accessibilityLabel(
                    "Pairing code \(PairingCode.formatted(model.pairingCode))"
                )

            ViewThatFits(in: .horizontal) {
                HStack {
                    inviteActionButtons
                }
                VStack {
                    inviteActionButtons
                }
            }

            HStack(spacing: 8) {
                ProgressView()
                Text("Waiting for them to join…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var expiredContent: some View {
        VStack(spacing: 28) {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.system(size: 48))
                .foregroundStyle(.orange)

            VStack(spacing: 10) {
                Text("Invite code expired")
                    .font(.largeTitle.bold())
                Text(
                    "Generate a new one-time code, then share that code instead."
                )
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            }

            Button {
                didCopyCode = false
                Task {
                    await model.createConversation()
                }
            } label: {
                Label("Generate new code", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    @ViewBuilder
    private var inviteActionButtons: some View {
        Button(action: copyCode) {
            Label(
                didCopyCode ? "Copied" : "Copy code",
                systemImage: didCopyCode ? "checkmark" : "doc.on.doc"
            )
        }
        .buttonStyle(.bordered)

        if let pairingLink = model.pairingLink {
            ShareLink(
                item: pairingLink,
                subject: Text("Join me on Peapod"),
                message: Text(
                    "Open this link on your iPhone, or enter code "
                        + "\(PairingCode.formatted(model.pairingCode))."
                )
            ) {
                Label("Share invite", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func isExpired(at date: Date) -> Bool {
        guard let expiration = model.pairingCodeExpiresAt else {
            return true
        }
        return date >= expiration
    }

    private func copyCode() {
        guard model.copyPairingCode() else { return }
        withAnimation {
            didCopyCode = true
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation {
                didCopyCode = false
            }
        }
    }
}
