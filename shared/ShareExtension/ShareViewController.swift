import Social
import ImageIO
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import UniformTypeIdentifiers

#if os(macOS)
typealias ShareComposerViewController = SLComposeServiceViewController
#endif

@MainActor
final class ShareViewController: ShareComposerViewController {
    private enum ShareError: LocalizedError {
        case unsupportedItem
        case missingItem
        case noConversation

        var errorDescription: String? {
            switch self {
            case .unsupportedItem:
                "This item cannot be shared with Peapod yet."
            case .missingItem:
                "The shared item is no longer available."
            case .noConversation:
                "Create or join a conversation in Peapod before sharing."
            }
        }
    }

    override func isContentValid() -> Bool {
        guard activeConversationID != nil else { return false }
        let hasComposeText = !trimmed(contentText).isEmpty
        let hasAttachments = (extensionContext?.inputItems as? [NSExtensionItem])?
            .contains { !($0.attachments?.isEmpty ?? true) } ?? false
        return hasComposeText || hasAttachments
    }

    override func presentationAnimationDidFinish() {
        super.presentationAnimationDidFinish()
#if os(macOS)
        title = "Peapod"
#else
        navigationItem.title = "Peapod"
        setConversationAvailable(activeConversationID != nil)
#endif
        if activeConversationID == nil {
            placeholder = "Create or join a conversation in Peapod first."
        } else {
            placeholder = "Optional note"
        }
        validateContent()
    }

    override func didSelectPost() {
        Task { @MainActor in
            var shares: [PendingShare] = []
            do {
                let delivery = ShareDeliveryService()
                let target = try await delivery.prepareDestination()
                shares = try await loadShares(conversationID: target.conversationID, accountID: target.accountID)
                guard !shares.isEmpty else { throw ShareError.unsupportedItem }
                guard try SharedConversationStore.currentTarget() == target else { throw ShareError.noConversation }
                do {
                    let delivered = try await delivery.sendOrQueue(shares, target: target)
                    if delivered {
                        extensionContext?.completeRequest(returningItems: nil)
                    } else { handOffToMines() }
                } catch {
                    // Only an already-persisted, explicitly legacy item can use the old handoff.
                    // Missing keys, encryption failures and downgraded encrypted targets fail closed.
                    if target.mode == .legacy,
                       (try? PendingShareStore.pendingItems(for: target.accountID).contains { share in shares.contains { $0.id == share.id } }) == true {
                        handOffToMines()
                    } else { throw error }
                }
            } catch {
                PendingShareStore.discardStagedFiles(for: shares)
#if os(macOS)
                extensionContext?.cancelRequest(withError: error)
#else
                showSendError(error)
#endif
            }
        }
    }

    private func handOffToMines() {
        guard
            let extensionContext,
            let url = URL(string: "peapod://share")
        else {
            self.extensionContext?.completeRequest(returningItems: nil)
            return
        }

        extensionContext.open(url) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.extensionContext?.completeRequest(
                    returningItems: nil
                )
            }
        }
    }

    private var activeConversationID: String? {
        do {
            let target = try SharedConversationStore.currentTarget()
            return target?.conversationID
        } catch {
            return nil
        }
    }

    private func loadShares(
        conversationID: String, accountID: String
    ) async throws -> [PendingShare] {
        let sendTime = Date.now
        var shares: [PendingShare] = []
        var attachmentBytes = 0

        do {
            let extensionItems =
                extensionContext?.inputItems as? [NSExtensionItem] ?? []

            for item in extensionItems {
                for provider in item.attachments ?? [] {
                    shares.append(
                        try await loadShare(from: provider, maximumByteSize: ShareExtensionLimits.remaining(used: attachmentBytes))
                            .scopedToConversation(conversationID, accountID: accountID)
                    )
                    if let share = shares.last, share.localFileName != nil {
                        let url = try PendingShareStore.stagedFileURL(for: share)
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        attachmentBytes = try ShareExtensionLimits.admitAttachment(size, used: attachmentBytes)
                    }
                }
            }

            #if os(iOS)
            // Some hosts supply the same article as both a URL and plain text.
            if let article = shares.first(where: { $0.kind == .url }), let url = article.text {
                shares.removeAll { $0.kind == .text && trimmed($0.text) == url }
            }
            #endif
            let composeText = trimmed(contentText)
            if !composeText.isEmpty,
               !shares.contains(where: {
                   ($0.kind == .text || $0.kind == .url) &&
                       trimmed($0.text) == composeText
               }) {
                var note = composeText
                #if os(iOS)
                if shares.count == 1, let article = shares.first,
                   article.kind == .url || article.kind == .text,
                   let url = ShareURLRepresentation.webURLText(article.text) {
                    // Keep the shared URL first so a second link in the note
                    // cannot become the card destination.
                    let body = ShareURLRepresentation.articleBody(url: url, note: composeText)
                    if body.count <= 10_000 {
                        note = body
                        shares.removeAll()
                    }
                }
                #endif
                shares.insert(
                    try PendingShare(kind: .text, text: note)
                        .scopedToConversation(conversationID, accountID: accountID),
                    at: 0
                )
            }

            let imageIndexes = shares.indices.filter {
                shares[$0].kind == .image
            }
            if imageIndexes.count > 1 {
                let groupedImages = try PhotoAttachmentDraftPolicy
                    .preparedForSend(imageIndexes.map { shares[$0] })
                for (index, groupedImage) in zip(
                    imageIndexes,
                    groupedImages
                ) {
                    shares[index] = groupedImage
                }
            }

            // The outbox sorts by creation time. Provider completion times
            // must not move the optional message behind its attachments.
            return shares.enumerated().map { index, share in
                share.queuedForSending(
                    at: sendTime.addingTimeInterval(Double(index) * 0.001)
                )
            }
        } catch {
            PendingShareStore.discardStagedFiles(for: shares)
            throw error
        }
    }

    private func loadShare(
        from provider: NSItemProvider, maximumByteSize: Int64?
    ) async throws -> PendingShare {
        if let typeIdentifier = registeredType(
            from: provider,
            conformingTo: .image
        ) {
            return try await loadFileBackedShare(
                from: provider,
                typeIdentifier: typeIdentifier,
                kind: .image, maximumByteSize: maximumByteSize
            )
        }

        if let typeIdentifier = registeredType(
            from: provider,
            conformingTo: .movie
        ) {
            return try await loadFileBackedShare(
                from: provider,
                typeIdentifier: typeIdentifier,
                kind: .movie, maximumByteSize: maximumByteSize
            )
        }

        if let typeIdentifier = registeredType(
            from: provider,
            conformingTo: .url
        ) {
            return try await loadURLShare(
                from: provider,
                typeIdentifier: typeIdentifier, maximumByteSize: maximumByteSize
            )
        }

        if let typeIdentifier = registeredType(
            from: provider,
            conformingTo: .plainText
        ) {
            return try await loadTextShare(
                from: provider,
                typeIdentifier: typeIdentifier
            )
        }

        if let typeIdentifier = registeredType(
            from: provider,
            conformingTo: .data
        ) {
            return try await loadFileBackedShare(
                from: provider,
                typeIdentifier: typeIdentifier,
                kind: .file, maximumByteSize: maximumByteSize
            )
        }

        throw ShareError.unsupportedItem
    }

    private func registeredType(
        from provider: NSItemProvider,
        conformingTo expectedType: UTType
    ) -> String? {
        provider.registeredTypeIdentifiers.first { identifier in
            UTType(identifier)?.conforms(to: expectedType) == true
        }
    }

    private func loadURLShare(
        from provider: NSItemProvider,
        typeIdentifier: String, maximumByteSize: Int64?
    ) async throws -> PendingShare {
        let suggestedName = provider.suggestedName

        return try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(
                forTypeIdentifier: typeIdentifier,
                options: nil
            ) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let url = ShareURLRepresentation.decode(value, typeIdentifier: typeIdentifier)

                guard let url else {
                    continuation.resume(throwing: ShareError.missingItem)
                    return
                }

                if url.isFileURL {
                    do {
                        try ShareExtensionLimits.requireRemaining(maximumByteSize)
                        let share = try PendingShareStore.stageFile(
                            from: url,
                            kind: .file,
                            suggestedName: suggestedName,
                            contentTypeIdentifier: typeIdentifier, maximumByteSize: maximumByteSize
                        )
                        continuation.resume(returning: share)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                } else {
                    continuation.resume(
                        returning: PendingShare(
                            kind: .url,
                            text: url.absoluteString,
                            contentTypeIdentifier: typeIdentifier
                        )
                    )
                }
            }
        }
    }

    private func loadTextShare(
        from provider: NSItemProvider,
        typeIdentifier: String
    ) async throws -> PendingShare {
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(
                forTypeIdentifier: typeIdentifier,
                options: nil
            ) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let text: String?
                if let string = value as? String {
                    text = string
                } else if let attributed = value as? NSAttributedString {
                    text = attributed.string
                } else {
                    text = nil
                }

                guard let text, !text.isEmpty else {
                    continuation.resume(throwing: ShareError.missingItem)
                    return
                }

                continuation.resume(
                    returning: PendingShare(
                        kind: .text,
                        text: text,
                        contentTypeIdentifier: typeIdentifier
                    )
                )
            }
        }
    }

    private func loadFileBackedShare(
        from provider: NSItemProvider,
        typeIdentifier: String,
        kind: PendingShare.Kind, maximumByteSize: Int64?
    ) async throws -> PendingShare {
        try ShareExtensionLimits.requireRemaining(maximumByteSize)
        do {
            return try await stageFileRepresentation(
                from: provider,
                typeIdentifier: typeIdentifier,
                kind: kind, maximumByteSize: maximumByteSize
            )
        } catch let error as ShareExtensionLimits.Failure {
            throw error
        } catch let error as PendingShareStoreError {
            // A store error means the provider loaded successfully but Peapod
            // rejected or could not persist the payload. Loading the same
            // item again can materialize a large attachment in extension
            // memory, so preserve the original bounded failure instead.
            throw error
        } catch {
            return try await stageLoadedItem(
                from: provider,
                typeIdentifier: typeIdentifier,
                kind: kind, maximumByteSize: maximumByteSize
            )
        }
    }

    /// The provider's URL is temporary, so copying must finish inside its
    /// completion handler.
    private func stageFileRepresentation(
        from provider: NSItemProvider,
        typeIdentifier: String,
        kind: PendingShare.Kind, maximumByteSize: Int64?
    ) async throws -> PendingShare {
        let suggestedName = provider.suggestedName

        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(
                forTypeIdentifier: typeIdentifier
            ) { sourceURL, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let sourceURL else {
                    continuation.resume(throwing: ShareError.missingItem)
                    return
                }

                do {
                    // Some image providers vend a serialized UIImage as their
                    // generic public.image file representation. Only stage an
                    // encoded image; otherwise load the image object below.
                    let stagedTypeIdentifier = kind == .image
                        ? try Self.imageTypeIdentifier(at: sourceURL)
                        : typeIdentifier
                    let share = try PendingShareStore.stageFile(
                        from: sourceURL,
                        kind: kind,
                        suggestedName: suggestedName,
                        contentTypeIdentifier: stagedTypeIdentifier, maximumByteSize: maximumByteSize
                    )
                    continuation.resume(returning: share)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func stageLoadedItem(
        from provider: NSItemProvider,
        typeIdentifier: String,
        kind: PendingShare.Kind, maximumByteSize: Int64?
    ) async throws -> PendingShare {
        let suggestedName = provider.suggestedName

        return try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(
                forTypeIdentifier: typeIdentifier,
                options: nil
            ) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                do {
                    let share: PendingShare
                    if let url = value as? URL {
                        let stagedTypeIdentifier = kind == .image
                            ? try Self.imageTypeIdentifier(at: url)
                            : typeIdentifier
                        share = try PendingShareStore.stageFile(
                            from: url,
                            kind: kind,
                            suggestedName: suggestedName,
                            contentTypeIdentifier: stagedTypeIdentifier, maximumByteSize: maximumByteSize
                        )
                    } else if let data = value as? Data {
                        if let maximumByteSize { try PendingShareAttachmentPolicy.validate(byteSize: Int64(data.count), maximumBytes: maximumByteSize) }
                        let stagedTypeIdentifier = kind == .image
                            ? try Self.imageTypeIdentifier(in: data)
                            : typeIdentifier
                        share = try PendingShareStore.stageData(
                            data,
                            kind: kind,
                            suggestedName: suggestedName,
                            preferredExtension:
                                UTType(stagedTypeIdentifier)?
                                .preferredFilenameExtension,
                            contentTypeIdentifier: stagedTypeIdentifier, maximumByteSize: maximumByteSize
                        )
                    } else if let data = Self.pngData(from: value) {
                        share = try PendingShareStore.stageData(
                            data,
                            kind: .image,
                            suggestedName: suggestedName,
                            preferredExtension: "png",
                            contentTypeIdentifier: UTType.png.identifier, maximumByteSize: maximumByteSize
                        )
                    } else {
                        throw ShareError.missingItem
                    }
                    continuation.resume(returning: share)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func trimmed(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func imageTypeIdentifier(at url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let byteSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            try PendingShareAttachmentPolicy.validate(byteSize: Int64(byteSize))
        }
        return try imageTypeIdentifier(from: CGImageSourceCreateWithURL(
            url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ))
    }

    private nonisolated static func imageTypeIdentifier(in data: Data) throws -> String {
        try PendingShareAttachmentPolicy.validate(byteSize: Int64(data.count))
        return try imageTypeIdentifier(from: CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ))
    }

    private nonisolated static func imageTypeIdentifier(from source: CGImageSource?) throws -> String {
        guard let source,
            CGImageSourceGetCount(source) > 0,
            let identifier = CGImageSourceGetType(source)
        else { throw ShareError.unsupportedItem }
        return identifier as String
    }

    private nonisolated static func pngData(from value: Any?) -> Data? {
#if os(macOS)
        guard
            let image = value as? NSImage,
            let tiffData = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffData)
        else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
#else
        return (value as? UIImage)?.pngData()
#endif
    }
}
