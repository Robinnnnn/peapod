import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The iPhone share surface is a message composer. Keep its small interface
/// compatible with the Mac composer so both use the same durable send path.
@MainActor
class ShareComposerViewController: UIViewController {
    private let composer = ShareComposerModel()
    private var previewTask: Task<Void, Never>?

    var contentText: String? { composer.note }
    var placeholder: String? {
        get { composer.placeholder }
        set { composer.placeholder = newValue ?? "Add a message…" }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        preferredContentSize = CGSize(width: 390, height: 650)

        let host = UIHostingController(rootView: ShareComposerView(
            model: composer,
            send: { [weak self] in self?.send() },
            cancel: { [weak self] in self?.cancel() },
            textChanged: { [weak self] in self?.validateContent() }
        ))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)

        presentationAnimationDidFinish()
        loadPreviews()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        previewTask?.cancel()
    }

    func isContentValid() -> Bool { false }
    func didSelectPost() {}
    func presentationAnimationDidFinish() {}

    func validateContent() {
        composer.canSend = isContentValid() && !composer.isSending
    }

    func setConversationAvailable(_ isAvailable: Bool) {
        composer.hasConversation = isAvailable
    }

    func showSendError(_ error: any Error) {
        composer.isSending = false
        composer.errorMessage = error.localizedDescription
        isModalInPresentation = false
        validateContent()
    }

    private func send() {
        guard !composer.isSending, isContentValid() else { return }
        composer.isSending = true
        composer.canSend = false
        isModalInPresentation = true
        view.endEditing(true)
        didSelectPost()
    }

    private func cancel() {
        guard !composer.isSending else { return }
        previewTask?.cancel()
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }

    private func loadPreviews() {
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        // Some hosts supply selected text directly on the extension item.
        // Social populated that field automatically; preserve it in this UI.
        composer.note = items.filter { $0.attachments?.isEmpty ?? true }
            .compactMap { $0.attributedContentText?.string }
            .joined(separator: "\n\n")
        validateContent()
        composer.previews = providers.map(ShareComposerPreview.init(provider:))
        previewTask = Task { [weak self] in
            for (index, provider) in providers.enumerated() {
                guard !Task.isCancelled else { return }
                let image = await ShareComposerPreviewLoader.image(from: provider)
                guard !Task.isCancelled else { return }
                let summary = image == nil
                    ? await ShareComposerPreviewLoader.summary(from: provider)
                    : nil
                guard !Task.isCancelled, let self else { return }
                self.composer.previews[index].image = image
                self.composer.previews[index].isLoading = false
                if let summary {
                    self.composer.previews[index].title = summary
                }
            }
        }
    }
}

@MainActor
private final class ShareComposerModel: ObservableObject {
    @Published var note = ""
    @Published var placeholder = "Add a message…"
    @Published var previews: [ShareComposerPreview] = []
    @Published var hasConversation = false
    @Published var canSend = false
    @Published var isSending = false
    @Published var errorMessage: String?
}

private struct ShareComposerPreview: Identifiable {
    let id = UUID()
    let isPhoto: Bool
    let symbol: String
    var title: String
    var image: UIImage?
    var isLoading: Bool

    init(provider: NSItemProvider) {
        isPhoto = provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        isLoading = isPhoto
        if isPhoto {
            symbol = "photo"
            title = "Photo"
        } else if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            symbol = "video"
            title = provider.suggestedName ?? "Video"
        } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            symbol = "link"
            title = provider.suggestedName ?? "Shared link"
        } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            symbol = "text.alignleft"
            title = provider.suggestedName ?? "Shared text"
        } else {
            symbol = "doc"
            title = provider.suggestedName ?? "File"
        }
    }
}

private struct ShareComposerView: View {
    @ObservedObject var model: ShareComposerModel
    let send: () -> Void
    let cancel: () -> Void
    let textChanged: () -> Void
    @State private var selectedPreview = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    destination

                    if !model.previews.isEmpty {
                        attachments
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Message")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        ZStack(alignment: .topLeading) {
                            if model.note.isEmpty {
                                Text("Add a message…")
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 8)
                                    .accessibilityHidden(true)
                            }
                            TextEditor(text: $model.note)
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 92)
                                .accessibilityLabel("Optional message")
                                .accessibilityIdentifier("share-message-field")
                        }
                        .font(.body)
                        .padding(10)
                        .background(.background, in: .rect(cornerRadius: 18))
                    }
                    .disabled(model.isSending || !model.hasConversation)
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Peapod")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                        .disabled(model.isSending)
                        .accessibilityIdentifier("share-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: send) {
                        HStack(spacing: 6) {
                            if model.isSending {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(model.isSending ? "Sending…" : "Send")
                                .fontWeight(.semibold)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .disabled(!model.canSend)
                    .accessibilityIdentifier("share-send")
                }
            }
            .onChange(of: model.note) { textChanged() }
            .alert("Couldn’t Send", isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
        .tint(.indigo)
    }

    private var destination: some View {
        HStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.title3)
                .foregroundStyle(.indigo)
                .frame(width: 44, height: 44)
                .background(.indigo.opacity(0.1), in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.hasConversation ? "Your conversation" : "Conversation required")
                    .font(.subheadline.weight(.semibold))
                Text(model.hasConversation ? "Ready to send" : "Open Peapod to create or join a conversation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("share-destination")
    }

    private var attachments: some View {
        VStack(spacing: 12) {
            if model.previews.count == 1, let preview = model.previews.first {
                previewCard(preview)
            } else {
                TabView(selection: $selectedPreview) {
                    ForEach(Array(model.previews.enumerated()), id: \.element.id) { index, preview in
                        previewCard(preview)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: 270)
                Text("\(selectedPreview + 1) of \(model.previews.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("share-attachment-preview")
    }

    @ViewBuilder
    private func previewCard(_ preview: ShareComposerPreview) -> some View {
        if preview.isPhoto {
            ZStack {
                Color(uiColor: .secondarySystemGroupedBackground)
                if let image = preview.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .accessibilityLabel("Shared photo")
                        .accessibilityIdentifier("share-photo-preview")
                } else if preview.isLoading {
                    ProgressView("Loading photo")
                } else {
                    Label("Photo", systemImage: "photo")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 270)
            .clipShape(.rect(cornerRadius: 20))
        } else {
            Label {
                Text(preview.title)
                    .font(.subheadline)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } icon: {
                Image(systemName: preview.symbol)
                    .font(.title2)
                    .foregroundStyle(.indigo)
                    .frame(width: 40, height: 44)
            }
            .padding(14)
            .background(.background, in: .rect(cornerRadius: 18))
        }
    }
}

private enum ShareComposerPreviewLoader {
    private static let maximumPixelSize = 720
    private struct ImageTransfer: @unchecked Sendable {
        let image: UIImage?
    }

    @MainActor
    static func summary(from provider: NSItemProvider) async -> String? {
        guard let type = [UTType.url, .plainText].first(where: {
            provider.hasItemConformingToTypeIdentifier($0.identifier)
        }) else { return nil }
        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { value, _ in
                let summary: String?
                if let url = value as? URL {
                    summary = url.isFileURL ? url.lastPathComponent : url.absoluteString
                } else if let text = value as? String {
                    summary = String(text.prefix(300))
                } else if let text = value as? NSAttributedString {
                    summary = String(text.string.prefix(300))
                } else {
                    summary = nil
                }
                continuation.resume(returning: summary)
            }
        }
    }

    /// Prefer a file so large camera photos never need full-resolution decode.
    /// UIKit image providers may only vend an object/data representation; ask
    /// those for a small image and retain only a downsampled thumbnail.
    @MainActor
    static func image(from provider: NSItemProvider) async -> UIImage? {
        let registeredImageType = provider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .image) == true
        })
        guard let identifier = registeredImageType ?? (
            provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
                ? UTType.image.identifier : nil
        ) else { return nil }

        let transfer: ImageTransfer = await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, _ in
                continuation.resume(returning: ImageTransfer(image: thumbnail(from: url)))
            }
        }
        if let image = transfer.image { return image }
        guard !Task.isCancelled else { return nil }

        let fallback: ImageTransfer = await withCheckedContinuation { continuation in
            provider.loadItem(
                forTypeIdentifier: identifier,
                options: [NSItemProviderPreferredImageSizeKey: NSValue(
                    cgSize: CGSize(
                        width: CGFloat(maximumPixelSize),
                        height: CGFloat(maximumPixelSize)
                    )
                )]
            ) { value, _ in
                continuation.resume(returning: ImageTransfer(image: thumbnail(from: value)))
            }
        }
        return fallback.image
    }

    private static func thumbnail(from value: Any?) -> UIImage? {
        if let url = value as? URL {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let source = CGImageSourceCreateWithURL(
                url as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary
            )
            return thumbnail(from: source)
        }
        if let data = value as? Data {
            guard Int64(data.count) <= PendingShareAttachmentPolicy.maximumByteSize else { return nil }
            let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
            )
            return thumbnail(from: source)
        }
        if let image = value as? UIImage {
            return image.preparingThumbnail(of: CGSize(
                width: CGFloat(maximumPixelSize),
                height: CGFloat(maximumPixelSize)
            ))
        }
        return nil
    }

    private static func thumbnail(from source: CGImageSource?) -> UIImage? {
        guard let source,
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            ] as CFDictionary)
        else { return nil }
        return UIImage(cgImage: thumbnail)
    }
}
