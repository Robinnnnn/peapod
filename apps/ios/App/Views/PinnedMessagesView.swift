import SwiftUI

struct PinnedMessagesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let controller: MessagePinsController
    let onShowMessage: (UUID) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if controller.isLoading {
                    ProgressView("Loading pinned messages")
                } else if let error = controller.errorMessage {
                    ContentUnavailableView {
                        Label("Pinned messages unavailable", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Retry") { controller.retry() }
                    }
                } else if controller.messages.isEmpty {
                    ContentUnavailableView {
                        Label("No pinned messages", systemImage: "pin")
                    } description: {
                        Text(controller.messageIDs.isEmpty
                             ? "Pin a message from its message options."
                             : "The messages on this page are no longer available.")
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 20) {
                            ForEach(controller.messages) { message in
                                VStack(spacing: 8) {
                                    Text(message.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption).foregroundStyle(.secondary)
                                    Button {
                                        onShowMessage(message.id)
                                    } label: {
                                        pinnedRow(message).allowsHitTesting(false)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Pinned message: \(message.replyPreviewText)")
                                    .accessibilityHint("Opens in conversation. Touch and hold for more actions.")
                                    .contextMenu {
                                        Button("Show in Conversation", systemImage: "bubble.left") {
                                            onShowMessage(message.id)
                                        }
                                        Button("Unpin", systemImage: "pin.slash") {
                                            Task { await controller.setPinned(false, message: message) }
                                        }
                                        .disabled(controller.pendingMessageIDs.contains(message.id))
                                    }
                                    .accessibilityAction(named: "Unpin") {
                                        Task { await controller.setPinned(false, message: message) }
                                    }
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom) {
                if controller.pageCount > 1 {
                    HStack {
                        Button("Previous", systemImage: "chevron.left") { controller.previousPage() }
                            .disabled(!controller.hasPreviousPage)
                        Spacer()
                        Text("\(controller.pageIndex + 1) of \(controller.pageCount)")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Next", systemImage: "chevron.right") { controller.nextPage() }
                            .disabled(!controller.hasNextPage)
                    }
                    .padding().background(.bar)
                }
            }
            .navigationTitle("Pinned Messages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .onAppear { controller.open() }
        .onDisappear { controller.close() }
    }

    private func pinnedRow(_ message: ChatMessage) -> some View {
        MessageRow(
            message: message, photoGroup: nil,
            isCurrentUser: message.senderID == model.currentUser.id,
            currentUserID: model.currentUser.id,
            showsDeliveryStatus: false, isLatestOutgoing: false,
            pendingShareStatus: nil, groupedWithPrevious: false, groupedWithNext: false,
            replyMessage: message.replyToID.flatMap { controller.replyMessages[$0] },
            timestampReveal: .fixed(0), interactionOffsetY: 0, allowsInteractions: false,
            onShowReply: { if let id = message.replyToID { onShowMessage(id) } },
            onPresentInteractions: {}, onReply: {}, onReact: { _ in },
            onEdit: {}, onUnsend: {}, onRetry: {}, onRemovePendingShare: {},
            isPinned: true
        )
    }
}
