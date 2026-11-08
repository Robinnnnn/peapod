import SwiftUI

struct PairingView: View {
    @Environment(AppModel.self) private var model
    @State private var joinCode = ""
    @State private var showingJoin = false
    @FocusState private var joinFieldIsFocused: Bool
    private let contentTopPadding: CGFloat = 38
    private let contentBottomPadding: CGFloat = 8

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Begin your convo")
                                .font(.system(size: 34, weight: .bold))
                                .foregroundStyle(.primary)

                            Text(
                                "Create a channel or join with a code."
                            )
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }

                        VStack(spacing: 14) {
                            PairingActionCard(
                                title: "Create a conversation",
                                detail: "Get a one-time code to share",
                                systemImage: "sparkles"
                            ) {
                                Task {
                                    await model.createConversation()
                                }
                            }
                            .accessibilityIdentifier("create-conversation")
                            .accessibilityLabel("Create a conversation")
                            .accessibilityHint(
                                "Gets a one-time code to share."
                            )

                            PairingActionCard(
                                title: "Enter code",
                                detail: "Join the conversation",
                                systemImage: "number"
                            ) {
                                showingJoin = true
                            }
                            .accessibilityIdentifier("enter-pairing-code")
                            .accessibilityLabel("Enter code")
                            .accessibilityHint(
                                "Joins the conversation."
                            )
                        }
                        .padding(.top, 28)

                        Spacer(minLength: 40)

                        HStack(spacing: 7) {
                            Circle()
                                .fill(.indigo.opacity(0.72))
                                .frame(width: 6, height: 6)

                            Text("made for you and boo")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.secondary)

                            Circle()
                                .fill(.indigo.opacity(0.72))
                                .frame(width: 6, height: 6)
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("made for you and boo")
                    }
                    .frame(
                        maxWidth: 520,
                        minHeight: max(
                            proxy.size.height
                                - contentTopPadding
                                - contentBottomPadding,
                            0
                        ),
                        alignment: .top
                    )
                    .padding(.horizontal, 24)
                    .padding(.top, contentTopPadding)
                    .padding(.bottom, contentBottomPadding)
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .background(pairingBackground.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SessionActionsMenu(hasConversation: false)
                }
            }
            .sheet(isPresented: $showingJoin) {
                joinSheet
            }
            .onChange(of: showingJoin) { _, isShowing in
                if isShowing {
                    joinFieldIsFocused = true
                }
            }
            .disabled(model.isWorking)
            .overlay {
                if model.isWorking {
                    ProgressView()
                        .padding()
                        .background(
                            .regularMaterial,
                            in: .rect(cornerRadius: 16)
                        )
                }
            }
        }
    }

    private var pairingBackground: some View {
        Color(uiColor: .systemGroupedBackground)
            .overlay {
                Color.indigo.opacity(0.055)
            }
    }

    private var joinSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        "ABCD 1234",
                        text: joinCodeBinding
                    )
                    .font(.system(.title3, design: .monospaced))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .textContentType(.oneTimeCode)
                    .submitLabel(.join)
                    .focused($joinFieldIsFocused)
                    .accessibilityIdentifier("pairing-code-field")
                    .onSubmit(submitJoin)
                } footer: {
                    Text(
                        "Enter the 8-character code shown on the other phone."
                    )
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Enter code")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showingJoin = false
                        joinCode = ""
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Join", action: submitJoin)
                        .disabled(
                            canonicalJoinCode == nil || model.isWorking
                        )
                        .accessibilityIdentifier("join-conversation")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(model.isWorking)
    }

    private var joinCodeBinding: Binding<String> {
        Binding(
            get: {
                PairingCode.formatted(joinCode)
            },
            set: { newValue in
                joinCode = PairingCode.editableValue(newValue)
            }
        )
    }

    private var canonicalJoinCode: String? {
        PairingCode.canonicalValue(joinCode)
    }

    private func submitJoin() {
        guard
            let canonicalJoinCode,
            !model.isWorking
        else {
            return
        }
        Task {
            await model.joinConversation(code: canonicalJoinCode)
        }
    }
}

private struct PairingActionCard: View {
    let title: String
    let detail: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.indigo)
                    .frame(width: 36, height: 36)
                    .background(
                        .indigo.opacity(0.1),
                        in: .rect(cornerRadius: 11)
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Image(systemName: "arrow.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.indigo)
                    .accessibilityHidden(true)
            }
            .multilineTextAlignment(.leading)
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: .rect(cornerRadius: 18)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(.indigo.opacity(0.16), lineWidth: 1)
            }
            .contentShape(.rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }
}
