import SwiftUI

struct MacPinnedMessagesView: View {
    @Environment(\.dismiss) private var dismiss
    let controller: MessagePinsController
    let currentUserID: String
    let partnerName: String
    let showInConversation: (UUID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Pinned Messages", systemImage: "pin")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            if controller.isLoading {
                ProgressView("Loading pinned messages…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = controller.errorMessage {
                ContentUnavailableView {
                    Label("Couldn’t Load Pinned Messages", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { controller.retry() }
                }
            } else if controller.messages.isEmpty {
                ContentUnavailableView("No Pinned Messages", systemImage: "pin", description:
                    Text(controller.messageIDs.isEmpty ? "Pin a message from its context menu." : "No messages are available on this page."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 20) {
                        ForEach(controller.messages) { message in
                            MacMessageRow(message: message, photoGroup: nil,
                                replyMessage: message.replyToID.flatMap { controller.replyMessages[$0] },
                                isCurrentUser: message.senderID == currentUserID,
                                currentUserID: currentUserID, partnerName: partnerName,
                                grouping: MessageGroupPosition(joinsPrevious: false, joinsNext: false), showsDeliveryStatus: false, isLatestOutgoing: false,
                                timestampsRevealed: true, groupTailHasPersistentMetadata: true,
                                showReply: { if let replyID = message.replyToID { showInConversation(replyID) } }, toggleTimestamps: {},
                                reply: { showInConversation(message.id) }, edit: {}, unsend: {}, react: { _ in }, retry: {},
                                isPinned: true, pinIsPending: controller.pendingMessageIDs.contains(message.id),
                                togglePin: { Task { await controller.setPinned(false, message: message) } },
                                allowsMessageActions: false,
                                showInConversation: { showInConversation(message.id) })
                        }
                    }
                    .padding()
                }
                .id(controller.pageIndex)
            }
            if controller.pageCount > 1 {
                Divider()
                HStack {
                    Button("Previous", systemImage: "chevron.left") { controller.previousPage() }
                        .disabled(!controller.hasPreviousPage)
                    Spacer()
                    Text("Page \(controller.pageIndex + 1) of \(controller.pageCount)")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Next", systemImage: "chevron.right") { controller.nextPage() }
                        .disabled(!controller.hasNextPage)
                }
                .padding()
            }
        }
        .frame(minWidth: 560, idealWidth: 660, minHeight: 420, idealHeight: 580)
        .onAppear { controller.open() }
        .onDisappear { controller.close() }
    }
}
