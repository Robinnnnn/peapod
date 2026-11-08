import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PastedPhoto: Sendable {
    let data: Data
    let contentTypeIdentifier: String
}

enum PasteboardPhotoReader {
    @MainActor
    static func containsPhoto(
        in itemProviders: [NSItemProvider]
    ) -> Bool {
        itemProviders.contains { itemProvider in
            itemProvider.canLoadObject(ofClass: UIImage.self)
                || itemProvider.registeredTypeIdentifiers.contains {
                    UTType($0)?.conforms(to: .image) == true
                }
        }
    }

    @MainActor
    static func photos(from pasteboard: UIPasteboard) -> [PastedPhoto] {
        let photos = photos(from: pasteboard.items)
        guard photos.isEmpty else { return photos }

        return (pasteboard.images ?? []).compactMap { image in
            encodedPhoto(from: image)
        }
    }

    @MainActor
    static func photos(
        from items: [[String: Any]]
    ) -> [PastedPhoto] {
        items.compactMap { item in
            let imageTypes = item.keys
                .filter {
                    UTType($0)?.conforms(to: .image) == true
                }
                .sorted(by: imageTypeIsPreferred)

            for typeIdentifier in imageTypes {
                if
                    let data = item[typeIdentifier] as? Data,
                    CGImageSourceCreateWithData(data as CFData,
                        [kCGImageSourceShouldCache: false] as CFDictionary) != nil
                {
                    return PastedPhoto(
                        data: data,
                        contentTypeIdentifier: typeIdentifier
                    )
                }

                if
                    let image = item[typeIdentifier] as? UIImage,
                    let photo = encodedPhoto(from: image)
                {
                    return photo
                }
            }
            return nil
        }
    }

    private static func imageTypeIsPreferred(
        _ first: String,
        _ second: String
    ) -> Bool {
        imageTypeRank(first) < imageTypeRank(second)
    }

    private static func imageTypeRank(_ identifier: String) -> Int {
        switch UTType(identifier) {
        case .heic:
            0
        case .jpeg:
            1
        case .png:
            2
        default:
            3
        }
    }

    @MainActor
    private static func encodedPhoto(from image: UIImage) -> PastedPhoto? {
        // A UIImage-only clipboard has no original encoded bytes to preserve.
        // Encode pixels losslessly rather than silently lowering JPEG quality.
        guard let data = image.pngData() else { return nil }
        return PastedPhoto(data: data, contentTypeIdentifier: UTType.png.identifier)
    }

}

@MainActor
protocol PasteableMessageTextViewDelegate: AnyObject {
    func messageTextView(
        _ textView: PasteableMessageTextView,
        didPaste photos: [PastedPhoto]
    )
}

final class PasteableMessageTextView: UITextView {
    var isShowingVoicePanel = false

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        !isShowingVoicePanel && super.point(inside: point, with: event)
    }

    var pastedPhotosAreAvailable: @MainActor () -> Bool = {
        UIPasteboard.general.hasImages
    }
    var readPastedPhotos: @MainActor () -> [PastedPhoto] = {
        PasteboardPhotoReader.photos(from: .general)
    }
    weak var photoPasteDelegate:
        (any PasteableMessageTextViewDelegate)?

    override func canPaste(
        _ itemProviders: [NSItemProvider]
    ) -> Bool {
        PasteboardPhotoReader.containsPhoto(in: itemProviders)
            || super.canPaste(itemProviders)
    }

    override func canPerformAction(
        _ action: Selector,
        withSender sender: Any?
    ) -> Bool {
        if
            action
                == #selector(UIResponderStandardEditActions.paste(_:)),
            pastedPhotosAreAvailable()
        {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(itemProviders: [NSItemProvider]) {
        guard PasteboardPhotoReader.containsPhoto(in: itemProviders) else {
            super.paste(itemProviders: itemProviders)
            return
        }
        pastePhotosOrFallBack {
            super.paste(itemProviders: itemProviders)
        }
    }

    override func paste(_ sender: Any?) {
        pastePhotosOrFallBack {
            super.paste(sender)
        }
    }

    private func pastePhotosOrFallBack(
        _ fallBack: () -> Void
    ) {
        let photos = readPastedPhotos()
        guard !photos.isEmpty else {
            fallBack()
            return
        }
        photoPasteDelegate?.messageTextView(
            self,
            didPaste: photos
        )
    }
}

struct PasteableMessageField: UIViewRepresentable {
    private static let minimumHeight: CGFloat = 40
    private static let maximumLineCount: CGFloat = 5

    @Binding var text: String
    @Binding var isFocused: Bool
    let isEnabled: Bool
    var isShowingVoicePanel = false
    let textChanged: () -> Void
    let pastePhotos: ([PastedPhoto]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(field: self)
    }

    func makeUIView(context: Context) -> PasteableMessageTextView {
        let textView = PasteableMessageTextView()
        textView.delegate = context.coordinator
        textView.photoPasteDelegate = context.coordinator
        textView.backgroundColor = .clear
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(
            top: 9,
            left: 0,
            bottom: 8,
            right: 0
        )
        textView.textContainer.lineFragmentPadding = 0
        textView.keyboardDismissMode = .interactive
        textView.accessibilityLabel = "Message"
        textView.accessibilityIdentifier = "message-field"
        textView.pasteConfiguration = UIPasteConfiguration(
            acceptableTypeIdentifiers: [
                UTType.text.identifier,
                UTType.url.identifier,
                UTType.image.identifier,
            ]
        )
        configure(textView)
        return textView
    }

    func updateUIView(
        _ textView: PasteableMessageTextView,
        context: Context
    ) {
        context.coordinator.field = self
        configure(textView)

        if textView.text != text {
            textView.text = text
        }

        if isFocused, !textView.isFirstResponder {
            let coordinator = context.coordinator
            DispatchQueue.main.async { [weak textView] in
                guard coordinator.field.isFocused, let textView, textView.window != nil else { return }
                textView.becomeFirstResponder()
            }
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView textView: PasteableMessageTextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width else { return nil }

        let fittingSize = textView.sizeThatFits(
            CGSize(
                width: width,
                height: CGFloat.greatestFiniteMagnitude
            )
        )
        let lineHeight =
            textView.font?.lineHeight
            ?? UIFont.preferredFont(forTextStyle: .body).lineHeight
        let verticalInsets =
            textView.textContainerInset.top
            + textView.textContainerInset.bottom
        let maximumHeight =
            ceil(lineHeight * Self.maximumLineCount + verticalInsets)
        let height = min(
            maximumHeight,
            max(Self.minimumHeight, ceil(fittingSize.height))
        )
        textView.isScrollEnabled = fittingSize.height > maximumHeight
        return CGSize(width: width, height: height)
    }

    private func configure(_ textView: PasteableMessageTextView) {
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
        textView.isShowingVoicePanel = isShowingVoicePanel
        textView.tintColor = isShowingVoicePanel ? .clear : nil
        textView.textColor = isShowingVoicePanel ? .clear : (isEnabled ? .label : .secondaryLabel)
    }

    @MainActor
    final class Coordinator:
        NSObject,
        UITextViewDelegate,
        PasteableMessageTextViewDelegate
    {
        var field: PasteableMessageField

        init(field: PasteableMessageField) {
            self.field = field
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            field.isFocused = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            field.isFocused = false
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            !field.isShowingVoicePanel
        }

        func textViewDidChange(_ textView: UITextView) {
            field.text = textView.text
            field.textChanged()
            textView.invalidateIntrinsicContentSize()
        }

        func messageTextView(
            _ textView: PasteableMessageTextView,
            didPaste photos: [PastedPhoto]
        ) {
            guard !field.isShowingVoicePanel else { return }
            field.pastePhotos(photos)
        }
    }
}
