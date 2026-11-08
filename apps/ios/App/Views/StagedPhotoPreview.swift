import SwiftUI
import UIKit

/// Local draft previews use the same account/conversation boundary as staging.
/// No original is uploaded or re-encoded by opening this view.
@MainActor
enum StagedPhotoPreviewSource {
    static func url(for share: PendingShare, target: SecureConversationResetTarget?,
                    resolve: (PendingShare) throws -> URL) throws -> URL {
        guard let target, share.kind == .image,
              share.conversationOwnerID?.utf8.elementsEqual(target.accountID.utf8) == true,
              share.targetConversationID?.utf8.elementsEqual(target.conversationID.utf8) == true else {
            throw PendingShareStoreError.accountMismatch
        }
        return try resolve(share)
    }
}

struct StagedPhotoPreview: View {
    @Environment(AppModel.self) private var model
    @Environment(\.encryptedAttachmentResolver) private var resolver
    let photo: StagedPhotoDraft
    let dismiss: () -> Void
    @State private var viewingImage: UIImage?
    @State private var sourceURL: URL?

    var body: some View {
        PhotoLightbox(
            image: viewingImage ?? photo.thumbnail,
            downloadURL: nil,
            fileName: photo.share.originalFileName ?? "Photo",
            detailDownloadURL: sourceURL,
            showsActionButtons: false,
            onDismiss: dismiss
        )
        .task {
            let target = model.attachmentPreparationTarget
            do {
                let url = try StagedPhotoPreviewSource.url(for: photo.share, target: target,
                                                          resolve: model.stagedAttachmentURL)
                guard let target, model.isCurrentAttachmentPreparation(target) else { dismiss(); return }
                sourceURL = url
                let image = try await PhotoLightboxLocalDetail.image(from: url, maximumPixelSize: 4096)
                try Task.checkCancellation()
                guard model.isCurrentAttachmentPreparation(target) else { dismiss(); return }
                viewingImage = image
            } catch {
                // Keep the admitted thumbnail usable if the local original is unavailable.
                sourceURL = nil
            }
        }
        .onChange(of: model.attachmentPreparationTarget) { dismiss() }
        .encryptedMediaLifetime(resolver) {
            viewingImage = nil
            sourceURL = nil
            dismiss()
        }
        .onAppear {
            model.conversationObscurationDidChange(.photo("staged-\(photo.id)"), isObscured: true)
        }
        .onDisappear {
            viewingImage = nil; sourceURL = nil
            model.conversationObscurationDidChange(.photo("staged-\(photo.id)"), isObscured: false)
        }
    }
}
