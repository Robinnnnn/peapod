import Foundation

struct PhotoGroupImageLoadKey: Hashable {
    struct Message: Hashable {
        let id: UUID
        let storagePath: String?
        let cloudReady: Bool
    }

    let groupID: UUID
    let messages: [Message]

    init(group: PhotoMessageGroup) {
        groupID = group.id
        messages = group.messages.map { message in
            Message(
                id: message.id,
                storagePath: message.attachment?.storagePath,
                cloudReady: EncryptedPhotoPreviewPolicy.isReady(message.attachment, deliveryState: message.deliveryState)
            )
        }
    }
}

/// Loads a small number at once so a slow first photo cannot hold up the stack,
/// without retaining every full-size photo download simultaneously.
@MainActor
enum PhotoGroupImageLoading {
    static func load(
        _ messages: [ChatMessage],
        loadImage: @escaping @MainActor @Sendable (ChatMessage) async -> Void
    ) async {
        await withTaskGroup(of: Void.self) { tasks in
            var pending = messages.makeIterator()
            for _ in 0..<3 {
                guard let message = pending.next() else { break }
                tasks.addTask { [message, loadImage] in await loadImage(message) }
            }
            for await _ in tasks {
                guard !Task.isCancelled, let message = pending.next() else { continue }
                tasks.addTask { [message, loadImage] in await loadImage(message) }
            }
        }
    }
}

enum PhotoGroupAvailability {
    struct Summary {
        let expectedCount: Int
        let availableImageIDs: Set<UUID>
        let failedCount: Int
        let loadingCount: Int

        var availableCount: Int { availableImageIDs.count }
        var countLabel: String {
            availableCount == expectedCount ? "\(expectedCount)" : "\(availableCount)/\(expectedCount)"
        }
    }

    static func summary(
        group: PhotoMessageGroup,
        loadedImageIDs: Set<UUID>,
        failedImageIDs: Set<UUID>
    ) -> Summary {
        let availableIDs = Set(group.messages.filter {
            isAvailable(hasImage: loadedImageIDs.contains($0.id),
                        deliveryState: $0.deliveryState,
                        imageLoadFailed: failedImageIDs.contains($0.id))
        }.map(\.id))
        let failedCount = group.messages.count {
            isUnavailable(deliveryState: $0.deliveryState,
                          imageLoadFailed: failedImageIDs.contains($0.id))
        }
        return Summary(expectedCount: group.expectedCount,
                       availableImageIDs: availableIDs,
                       failedCount: failedCount,
                       loadingCount: max(0, group.expectedCount - availableIDs.count - failedCount))
    }

    static func isAvailable(
        hasImage: Bool,
        deliveryState: DeliveryState,
        imageLoadFailed: Bool
    ) -> Bool {
        hasImage && !isUnavailable(
            deliveryState: deliveryState,
            imageLoadFailed: imageLoadFailed
        )
    }

    static func isUnavailable(
        deliveryState: DeliveryState,
        imageLoadFailed: Bool
    ) -> Bool {
        deliveryState == .failed || imageLoadFailed
    }
}
