import Foundation

/// A small neighborhood outside the viewport. It never searches through history
/// for the next photo or fetches originals on behalf of the full-screen viewer.
enum ChatPhotoPrefetchHorizon {
    static func attachments(
        itemCount: Int, visibleIndices: [Int], itemAt: (Int) -> ConversationTimelineItem
    ) -> [AttachmentContent] {
        guard let first = visibleIndices.min(), let last = visibleIndices.max(),
              first >= 0, last < itemCount else { return [] }
        var candidates: [Int] = []
        for distance in 1...6 {
            if first - distance >= 0 { candidates.append(first - distance) }
            if last + distance < itemCount { candidates.append(last + distance) }
            if candidates.count >= 6 { break }
        }
        var result: [AttachmentContent] = []
        var seen: Set<AttachmentContent> = []
        for index in candidates.prefix(6) {
            let item = itemAt(index)
            var rowAttachments: [AttachmentContent] = []
            for message in item.photoGroup?.messages ?? [item.displayMessage] {
                guard message.deletedAt == nil,
                      let attachment = message.attachment, attachment.type == .image,
                      attachment.storagePath?.hasPrefix("e2ee:") == true,
                      EncryptedPhotoPreviewPolicy.isReady(attachment, deliveryState: message.deliveryState),
                      seen.insert(attachment).inserted else { continue }
                rowAttachments.append(attachment)
            }
            // Keep a stack complete rather than warming only its front card.
            guard result.count + rowAttachments.count <= 12 else { continue }
            result.append(contentsOf: rowAttachments)
            if result.count == 12 { return result }
        }
        return result
    }
}

/// Pending work is replaced with the latest horizon; already running work is
/// allowed to finish so scrolling does not repeatedly cancel/restart downloads.
@MainActor
final class ChatPhotoPrefetcher {
    private weak var resolver: EncryptedAttachmentResolver?
    private var pending: [AttachmentContent] = []
    private var attempted: Set<AttachmentContent> = []
    private var running: [AttachmentContent: Task<Void, Never>] = [:]
    private var generation = UUID()

    func update(_ attachments: [AttachmentContent], resolver: EncryptedAttachmentResolver?) {
        if self.resolver !== resolver {
            stop()
            self.resolver = resolver
        }
        guard resolver != nil else { return }
        let horizon = Array(attachments.prefix(12))
        attempted.formIntersection(Set(horizon))
        pending = horizon.filter { !attempted.contains($0) && running[$0] == nil }
        startPending()
    }

    func stop() {
        generation = UUID()
        pending.removeAll()
        attempted.removeAll()
        for task in running.values { task.cancel() }
        running.removeAll()
        resolver = nil
    }

    private func startPending() {
        guard let resolver else { return }
        while running.count < 2, !pending.isEmpty {
            let attachment = pending.removeFirst()
            guard !attempted.contains(attachment), running[attachment] == nil else { continue }
            attempted.insert(attachment)
            guard resolver.cachedChatPhoto(attachment) == nil else { continue }
            let generation = generation
            running[attachment] = Task { [weak self, weak resolver] in
                if let resolver, !Task.isCancelled { _ = try? await resolver.chatPhoto(attachment, prefetch: true) }
                guard let self, self.generation == generation else { return }
                self.running[attachment] = nil
                self.startPending()
            }
        }
    }
}
