import SwiftUI
import UIKit

struct SessionActionsMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let hasConversation: Bool
    var showsInlineActions = false
    var searchMessages: (() -> Void)? = nil
    var pinnedMessages: (() -> Void)? = nil

    @State private var isConfirmingSignOut = false
    @State private var isConfirmingLocationTransfer = false
    @State private var locationTransferTarget: SecureConversationResetTarget?
    @State private var isPresentingAccessibilityActions = false
    @State private var pendingAccessibilityAction:
        AccessibilityMenuAction?

    var body: some View {
        accountOptionsControl
        .accessibilityLabel("Account options")
        .onChange(of: model.conversationDeletionTarget) { _, _ in
            isConfirmingLocationTransfer = false; locationTransferTarget = nil
        }
        .sheet(
            isPresented: $isPresentingAccessibilityActions,
            onDismiss: performPendingAccessibilityAction
        ) {
            accessibilityActionsSheet
        }
        .confirmationDialog(
            "Use this iPhone for location?",
            isPresented: $isConfirmingLocationTransfer,
            titleVisibility: .visible
        ) {
            Button("Use this iPhone") {
                guard let target = locationTransferTarget else { return }
                model.transferLocationSharingToThisPhone(confirmed: target)
                locationTransferTarget = nil
            }
            Button("Cancel", role: .cancel) { locationTransferTarget = nil }
        } message: {
            Text("Your other iPhone will stop publishing location. Only this iPhone will share new updates.")
        }
        .confirmationDialog(
            "Sign out of Peapod?",
            isPresented: $isConfirmingSignOut,
            titleVisibility: .visible
        ) {
            Button("Sign out", role: .destructive) {
                Task {
                    await model.signOut()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if hasConversation {
                Text(
                    "Signing in again with the same Apple account will reopen "
                        + "this conversation. Unsent shared items will be removed."
                )
            } else {
                Text(
                    "Unsent shared items will be removed. Any invite code "
                        + "you created can still be used until it expires."
                )
            }
        }
        .alert(
            "Location access is off",
            isPresented: Binding(
                get: { model.shouldOfferLocationSettings },
                set: { model.shouldOfferLocationSettings = $0 }
            )
        ) {
            Button("Open Settings") {
                model.shouldOfferLocationSettings = false
                if let settingsURL = URL(
                    string: UIApplication.openSettingsURLString
                ) {
                    openURL(settingsURL)
                }
            }
            Button("Cancel", role: .cancel) {
                model.shouldOfferLocationSettings = false
            }
        } message: {
            Text(
                "Allow location access in Settings to share your current "
                    + "distance with the other person."
            )
        }
        .onChange(
            of: isPresentingConversationObscuration,
            initial: true
        ) { _, isPresented in
            guard hasConversation else { return }
            model.conversationObscurationDidChange(
                .sessionActions,
                isObscured: isPresented
            )
        }
        .onDisappear {
            guard hasConversation else { return }
            model.conversationObscurationDidChange(
                .sessionActions,
                isObscured: false
            )
        }
    }

    private var isPresentingConversationObscuration: Bool {
        var isPresented = isPresentingAccessibilityActions
            || isConfirmingSignOut
            || isConfirmingLocationTransfer
            || shouldPresentLocationSettings
        return isPresented
    }

    private var shouldPresentLocationSettings: Bool {
        hasConversation && model.shouldOfferLocationSettings
    }

    @ViewBuilder
    private var accountOptionsControl: some View {
        if showsInlineActions {
            actionRows
        } else if usesAccessibilityActions {
            Button {
                isPresentingAccessibilityActions = true
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        } else {
            standardMenu
        }
    }

    private var usesAccessibilityActions: Bool {
        SessionActionsPresentationPolicy.usesAccessibilityActions(
            dynamicTypeIsAccessibility:
                dynamicTypeSize.isAccessibilitySize,
            preferredContentSizeCategoryIsAccessibility:
                UIApplication.shared.preferredContentSizeCategory
                    .isAccessibilityCategory
        )
    }

    private var standardMenu: some View {
        Menu {
            if let searchMessages {
                Button(
                    "Search",
                    systemImage: "magnifyingglass",
                    action: searchMessages
                )
                .accessibilityIdentifier("search-messages")
            }

            if let pinnedMessages {
                Button("Pinned Messages", systemImage: "pin", action: pinnedMessages)
                    .accessibilityIdentifier("pinned-messages")
            }
            if hasConversation {
                Toggle(
                    isOn: Binding(
                        get: { model.locationSharingToggleIsOn },
                        set: { model.setLocationSharingEnabled($0) }
                    )
                ) {
                    Label(
                        "Share location",
                        systemImage: "location"
                    )
                }
                .accessibilityIdentifier("share-location-toggle")
                if model.locationSourceIsAnotherDevice {
                    Button("Use this iPhone for location", systemImage: "iphone") {
                        confirmLocationTransfer()
                    }
                    .accessibilityIdentifier("transfer-location-source")
                } else if model.canResumeLocationSharing {
                    Button("Resume location sharing", systemImage: "location") {
                        model.setLocationSharingEnabled(true)
                    }
                    .accessibilityIdentifier("resume-location-source")
                }
            }

            Button(
                "Sign out",
                systemImage: "rectangle.portrait.and.arrow.right"
            ) {
                isConfirmingSignOut = true
            }
            .accessibilityIdentifier("sign-out")
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    private var accessibilityActionsSheet: some View {
        NavigationStack {
            ScrollView {
                actionRows
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
            }
            .accessibilityIdentifier(
                "account-actions-accessibility-sheet"
            )
            .navigationTitle("Account options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        isPresentingAccessibilityActions = false
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var actionRows: some View {
        LazyVStack(spacing: 0) {
            if searchMessages != nil {
                accessibilityActionButton(
                    title: "Search",
                    systemImage: "magnifyingglass",
                    identifier: "search-messages",
                    action: .searchMessages
                )
                actionDivider
            }

            if pinnedMessages != nil {
                accessibilityActionButton(title: "Pinned Messages", systemImage: "pin", identifier: "pinned-messages", action: .pinnedMessages)
                actionDivider
            }
            if hasConversation {
                Toggle(
                    isOn: Binding(
                        get: {
                            model.locationSharingToggleIsOn
                        },
                        set: {
                            model.setLocationSharingEnabled($0)
                        }
                    )
                ) {
                    accessibilityActionLabel(
                        title: "Share location",
                        systemImage: "location"
                    )
                }
                .padding(.vertical, 14)
                .accessibilityIdentifier(
                    "share-location-toggle"
                )
                if model.locationSourceIsAnotherDevice {
                    accessibilityActionButton(
                        title: "Use this iPhone for location",
                        systemImage: "iphone",
                        identifier: "transfer-location-source",
                        action: .transferLocationSource
                    )
                } else if model.canResumeLocationSharing {
                    accessibilityActionButton(
                        title: "Resume location sharing",
                        systemImage: "location",
                        identifier: "resume-location-source",
                        action: .resumeLocationSource
                    )
                }

                actionDivider
            }

            accessibilityActionButton(
                title: "Sign out",
                systemImage:
                    "rectangle.portrait.and.arrow.right",
                identifier: "sign-out",
                action: .signOut,
                role: .destructive
            )
        }
    }

    @ViewBuilder
    private var actionDivider: some View {
        if !showsInlineActions {
            Divider()
        }
    }

    private func accessibilityActionButton(
        title: String,
        systemImage: String,
        identifier: String,
        action: AccessibilityMenuAction,
        role: ButtonRole? = nil
    ) -> some View {
        Button(role: role) {
            if showsInlineActions {
                performAction(action)
            } else {
                pendingAccessibilityAction = action
                isPresentingAccessibilityActions = false
            }
        } label: {
            accessibilityActionLabel(
                title: title,
                systemImage: systemImage
            )
            .foregroundStyle(
                role == .destructive
                    ? Color.red
                    : Color.primary
            )
            .padding(.vertical, 14)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    private func accessibilityActionLabel(
        title: String,
        systemImage: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Image(systemName: systemImage)
                .frame(width: 32)

            accessibilityActionTitle(title)

            Spacer(minLength: 0)
        }
        .font(.body)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func accessibilityActionTitle(_ title: String) -> some View {
        let lines = title.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )

        if lines.count > 1 {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) {
                    _, line in
                    Text(String(line))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .allowsTightening(true)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(title)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func performPendingAccessibilityAction() {
        guard let action = pendingAccessibilityAction else {
            return
        }
        pendingAccessibilityAction = nil
        performAction(action)
    }

    private func performAction(_ action: AccessibilityMenuAction) {
        switch action {
        case .pinnedMessages:
            pinnedMessages?()
        case .searchMessages:
            searchMessages?()
        case .transferLocationSource:
            confirmLocationTransfer()
        case .resumeLocationSource:
            model.setLocationSharingEnabled(true)
        case .signOut:
            isConfirmingSignOut = true
        }
    }

    private func confirmLocationTransfer() {
        guard let target = model.locationSourceTransferTarget else { return }
        locationTransferTarget = target
        isConfirmingLocationTransfer = true
    }
}

private enum AccessibilityMenuAction {
    case pinnedMessages
    case searchMessages
    case transferLocationSource
    case resumeLocationSource
    case signOut
}

struct SessionActionsPresentationPolicy {
    static func usesAccessibilityActions(
        dynamicTypeIsAccessibility: Bool,
        preferredContentSizeCategoryIsAccessibility: Bool
    ) -> Bool {
        dynamicTypeIsAccessibility
            || preferredContentSizeCategoryIsAccessibility
    }
}
