import SwiftUI
import Observation
import UIKit

struct PhotoLightboxItem: Identifiable {
    let id: UUID
    let image: UIImage
    let downloadURL: URL?
    let fileName: String
    var encryptedAttachment: AttachmentContent? = nil
}

struct PhotoLightboxDownloadRequest: Identifiable {
    let id: UUID
    let image: UIImage
    let downloadURL: URL?
    var encryptedAttachment: AttachmentContent? = nil
}

/// Shared by the stack context menu and gallery action. It retains IDs only;
/// decrypted photo bytes stay within each existing authenticated save request.
@MainActor @Observable
final class PhotoGroupSaveOperation {
    private(set) var isSaving = false
    private(set) var savedPhotoIDs: Set<UUID> = []
    var alert: PhotoSaveAlert?

    func canSave(_ items: [PhotoLightboxItem]) -> Bool {
        !isSaving && items.contains { !savedPhotoIDs.contains($0.id) }
    }

    func save(
        _ items: [PhotoLightboxItem],
        resolver: (any EncryptedMediaResolving)?,
        saver: PhotoLibrarySaver = PhotoLibrarySaver()
    ) async {
        guard canSave(items) else { return }
        let requests = items.filter { !savedPhotoIDs.contains($0.id) }.map {
            PhotoLightboxDownloadRequest(id: $0.id, image: $0.image,
                                        downloadURL: $0.downloadURL,
                                        encryptedAttachment: $0.encryptedAttachment)
        }
        isSaving = true
        defer { isSaving = false }
        let result = await saver.saveAll(requests) { request in
            if request.encryptedAttachment != nil || request.downloadURL?.isFileURL == true {
                guard let resolver else { throw EncryptedMediaError.unavailable }
                try resolver.validateActive()
            }
            let bytes = try await PhotoLightboxDownloadPreparation.data(for: request, resolver: resolver)
            if request.encryptedAttachment != nil || request.downloadURL?.isFileURL == true {
                try resolver?.validateActive()
            }
            return bytes
        }
        result.savedIndices.forEach { savedPhotoIDs.insert(requests[$0].id) }
        guard !result.cancelled else { return }
        alert = result.accessDenied ? .photoAccessRequired
            : .groupSaveResult(saved: result.savedIndices.count, failed: result.failedIndices.count)
    }
}

struct PhotoGroupFullResolutionImage {
    let id: UUID
    let image: UIImage
}

struct PhotoGroupFullResolutionState {
    private(set) var loadedImage: PhotoGroupFullResolutionImage?

    mutating func release() {
        loadedImage = nil
    }

    mutating func store(
        _ loadedImage: PhotoGroupFullResolutionImage,
        selectedPhotoID: UUID?
    ) {
        guard loadedImage.id == selectedPhotoID else { return }
        self.loadedImage = loadedImage
    }

    func image(for photoID: UUID) -> UIImage? {
        guard loadedImage?.id == photoID else { return nil }
        return loadedImage?.image
    }
}

struct PhotoGroupFullResolutionRequest: Hashable {
    let id: UUID
    let downloadURL: URL?
    var encryptedAttachment: AttachmentContent? = nil
}

@MainActor
enum PhotoGroupFullResolutionLoading {
    static func request(
        in items: [PhotoLightboxItem],
        selectedPhotoID: UUID?
    ) -> PhotoGroupFullResolutionRequest? {
        guard
            let selectedPhotoID,
            let item = items.first(where: { $0.id == selectedPhotoID }),
            item.downloadURL != nil || EncryptedMediaLoading.isEncrypted(item.encryptedAttachment)
        else {
            return nil
        }
        return PhotoGroupFullResolutionRequest(
            id: item.id,
            downloadURL: item.downloadURL, encryptedAttachment: item.encryptedAttachment
        )
    }

    static func image(
        for request: PhotoGroupFullResolutionRequest,
        resolver: (any EncryptedMediaResolving)? = nil,
        remoteLoader: (URL) async throws -> Data
    ) async throws -> PhotoGroupFullResolutionImage {
        let data: Data
        if let attachment = request.encryptedAttachment, EncryptedMediaLoading.isEncrypted(attachment) {
            data = try await EncryptedMediaLoading.photoDisplayData(attachment, rendition: .viewer, resolver: resolver) { throw EncryptedMediaError.unavailable }
        } else {
            guard let url = request.downloadURL else { throw EncryptedMediaError.unavailable }
            data = try await remoteLoader(url)
        }
        guard let image = await ImageDecoding.thumbnail(from: data, maximumPixelSize: 4096, prefersHDR: true) else {
            throw URLError(.cannotDecodeContentData)
        }
        if let attachment = request.encryptedAttachment { try EncryptedMediaLoading.validate(attachment, resolver: resolver) }
        return PhotoGroupFullResolutionImage(id: request.id, image: image)
    }
}

@MainActor
enum PhotoLightboxDownloadPreparation {
    static func selectedRequest(
        in items: [PhotoLightboxItem],
        selectedPhotoID: UUID?,
        fullResolutionImage: PhotoGroupFullResolutionImage? = nil
    ) -> PhotoLightboxDownloadRequest? {
        guard
            let selectedPhotoID,
            let item = items.first(where: { $0.id == selectedPhotoID })
        else {
            return nil
        }
        let selectedImage =
            fullResolutionImage?.id == item.id
                ? fullResolutionImage?.image ?? item.image
                : item.image
        return PhotoLightboxDownloadRequest(
            id: item.id,
            image: selectedImage,
            downloadURL: item.downloadURL, encryptedAttachment: item.encryptedAttachment
        )
    }

    static func data(
        for request: PhotoLightboxDownloadRequest,
        resolver: (any EncryptedMediaResolving)? = nil
    ) async throws -> Data {
        if let attachment = request.encryptedAttachment, EncryptedMediaLoading.isEncrypted(attachment) {
            let bytes = try await EncryptedMediaLoading.data(attachment, resolver: resolver) { throw EncryptedMediaError.unavailable }
            guard await ImageDecoding.validatedData(bytes) != nil else { throw URLError(.cannotDecodeContentData) }
            try EncryptedMediaLoading.validate(attachment, resolver: resolver)
            return bytes
        }
        return try await data(for: request) { url in
            if url.isFileURL { return try EncryptedMediaLoading.localData(url, maximumBytes: 200 * 1024 * 1024) }
            let (data, response) = try await URLSession.shared.data(from: url)
            if
                let response = response as? HTTPURLResponse,
                !(200..<300).contains(response.statusCode)
            {
                throw URLError(.badServerResponse)
            }
            return data
        }
    }

    static func data(
        for request: PhotoLightboxDownloadRequest,
        remoteLoader: (URL) async throws -> Data
    ) async throws -> Data {
        guard !EncryptedMediaLoading.isEncrypted(request.encryptedAttachment) else { throw EncryptedMediaError.unavailable }
        if let downloadURL = request.downloadURL {
            do {
                let remoteData = try await remoteLoader(downloadURL)
                guard
                    await ImageDecoding.validatedData(remoteData) != nil
                else {
                    throw URLError(.cannotDecodeContentData)
                }
                return remoteData
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if downloadURL.isFileURL { throw error }
                // Saving the displayed image is a safe offline fallback.
            }
        }

        guard
            let data = await ImageDecoding.jpegData(
                from: request.image,
                compressionQuality: 0.96
            )
        else {
            throw PhotoLightboxDownloadError.cannotPrepareImage
        }
        return data
    }
}

private enum PhotoLightboxDownloadError: LocalizedError {
    case cannotPrepareImage

    var errorDescription: String? {
        "The photo couldn’t be prepared."
    }
}

struct PhotoGroupLightbox: View {
    @Environment(\.encryptedAttachmentResolver) private var encryptedResolver
    @Environment(\.openURL) private var openURL
    @State private var saveOperation = PhotoGroupSaveOperation()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let items: [PhotoLightboxItem]
    @Binding private var isPresented: Bool

    @State private var selectedPhotoID: UUID?
    @State private var zoomedPhotoIDs: Set<UUID> = []
    @State private var dismissalOffset: CGFloat = 0
    @State private var fullResolutionState = PhotoGroupFullResolutionState()
    @State private var failedViewingPhotoIDs: Set<UUID> = []

    init(
        items: [PhotoLightboxItem],
        initialPhotoID: UUID?,
        isPresented: Binding<Bool>
    ) {
        self.items = items
        _isPresented = isPresented
        _selectedPhotoID = State(
            initialValue: initialPhotoID
                ?? items.first?.id
        )
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 0) {
                galleryHeader

                GeometryReader { geometry in
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 0) {
                            ForEach(items) { item in
                                PhotoLightbox(
                                    image:
                                        fullResolutionState.image(for: item.id)
                                            ?? item.image,
                                    downloadURL: nil,
                                    fileName: item.fileName,
                                    detailAttachment: selectedPhotoID == item.id ? item.encryptedAttachment : nil,
                                    detailDownloadURL: selectedPhotoID == item.id ? item.downloadURL : nil,
                                    isAwaitingDisplayImage: selectedPhotoID == item.id
                                        && selectedFullResolutionRequest != nil
                                        && fullResolutionState.image(for: item.id) == nil
                                        && !failedViewingPhotoIDs.contains(item.id),
                                    supportsDragGestures: true,
                                    allowsUnmagnifiedDismissal: false,
                                    showsCloseButton: false,
                                    showsActionButtons: false,
                                    onZoomStateChanged: { isZoomed in
                                        if isZoomed {
                                            zoomedPhotoIDs.insert(item.id)
                                        } else {
                                            zoomedPhotoIDs.remove(item.id)
                                        }
                                    },
                                    onDismiss: requestDismissal
                                )
                                .frame(width: geometry.size.width)
                                .id(item.id)
                                .accessibilityIdentifier(
                                    "photo-group-item-\(item.id.uuidString)"
                                )
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollIndicators(.hidden)
                    .scrollTargetBehavior(.paging)
                    .scrollPosition(id: $selectedPhotoID)
                    .scrollDisabled(!allowsHorizontalPaging)
                    .contentShape(.rect)
                    .simultaneousGesture(
                        groupDismissalGesture,
                        including: isSelectedPhotoZoomed ? .none : .gesture
                    )
                    .accessibilityIdentifier("photo-group-lightbox")
                    .overlay(alignment: .bottomTrailing) {
                        if let selectedDownloadRequest {
                            PhotoLightboxActionPanel(
                                request: selectedDownloadRequest
                            )
                            .id(selectedDownloadRequest.id)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 16)
                        }
                    }
                }
            }
        }
        .scaleEffect(dismissalScale)
        .offset(y: dismissalOffset)
        .statusBarHidden()
        .presentationBackground(.clear)
        .onAppear {
            dismissalOffset = 0
            keepSelectionAvailable()
        }
        .onChange(of: items.map(\.id)) {
            keepSelectionAvailable()
        }
        .onChange(of: selectedPhotoID) {
            fullResolutionState.release()
        }
        .encryptedMediaLifetime(encryptedResolver) {
            if items.contains(where: { $0.encryptedAttachment != nil || $0.downloadURL?.isFileURL == true }) { fullResolutionState.release(); isPresented = false }
        }
        .task(id: selectedFullResolutionRequest) {
            await loadSelectedFullResolutionImage()
        }
        .alert(item: $saveOperation.alert) { alert in
            alert.presentation {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
        }
    }

    private var galleryHeader: some View {
        ZStack {
            if items.count > 1 {
                Text(positionLabel)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.58), in: .capsule)
                    .accessibilityLabel(
                        "Photo \(selectedIndex + 1) of \(items.count)"
                    )
            }

            HStack {
                Button {
                    Task { await saveOperation.save(items, resolver: encryptedResolver) }
                } label: {
                    if saveOperation.isSaving { ProgressView().tint(.white) }
                    else { Label("Save All", systemImage: "square.and.arrow.down.on.square") }
                }
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .disabled(!saveOperation.canSave(items))
                .accessibilityLabel("Save all available photos")
                .accessibilityIdentifier("save-all-photos")
                Spacer()
                PhotoLightboxCloseButton(action: requestDismissal)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 60)
    }

    private var selectedIndex: Int {
        items.firstIndex(where: { $0.id == selectedPhotoID }) ?? 0
    }

    private var selectedDownloadRequest: PhotoLightboxDownloadRequest? {
        PhotoLightboxDownloadPreparation.selectedRequest(
            in: items,
            selectedPhotoID: selectedPhotoID,
            fullResolutionImage: fullResolutionState.loadedImage
        )
    }

    private var selectedFullResolutionRequest: PhotoGroupFullResolutionRequest? {
        PhotoGroupFullResolutionLoading.request(
            in: items,
            selectedPhotoID: selectedPhotoID
        )
    }

    private var isSelectedPhotoZoomed: Bool {
        guard let selectedPhotoID else { return false }
        return zoomedPhotoIDs.contains(selectedPhotoID)
    }

    private var allowsHorizontalPaging: Bool {
        PhotoGroupInteractionPolicy.allowsHorizontalPaging(
            isSelectedPhotoZoomed: isSelectedPhotoZoomed
        )
    }

    private var positionLabel: String {
        "\(selectedIndex + 1) of \(items.count)"
    }

    private var dismissalProgress: CGFloat {
        min(
            dismissalOffset
                / PhotoLightboxDismissalPolicy.distanceThreshold,
            1
        )
    }

    private var dismissalScale: CGFloat {
        1 - (dismissalProgress * 0.06)
    }

    private var groupDismissalGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                if PhotoGroupInteractionPolicy.intent(
                    for: value.translation
                ) == .verticalDismissal {
                    dismissalOffset = value.translation.height
                } else {
                    dismissalOffset = 0
                }
            }
            .onEnded { value in
                if PhotoLightboxDismissalPolicy.shouldDismiss(
                    translation: value.translation,
                    predictedEndTranslation: value.predictedEndTranslation,
                    scale: 1
                ) {
                    requestDismissal()
                } else {
                    withAnimation(
                        reduceMotion
                            ? .easeOut(duration: 0.12)
                            : .spring(
                                response: 0.28,
                                dampingFraction: 0.86
                            )
                    ) {
                        dismissalOffset = 0
                    }
                }
            }
    }

    private func requestDismissal() {
        isPresented = false
    }

    private func keepSelectionAvailable() {
        guard
            let selectedPhotoID,
            items.contains(where: { $0.id == selectedPhotoID })
        else {
            selectedPhotoID = items.first?.id
            return
        }
    }

    private func loadSelectedFullResolutionImage() async {
        fullResolutionState.release()
        guard let request = selectedFullResolutionRequest else { return }
        failedViewingPhotoIDs.remove(request.id)

        do {
            let loadedImage = try await PhotoGroupFullResolutionLoading.image(
                for: request, resolver: encryptedResolver
            ) { url in
                if url.isFileURL {
                    guard let encryptedResolver else { throw EncryptedMediaError.unavailable }
                    try encryptedResolver.validateActive()
                    return try EncryptedMediaLoading.localData(url, maximumBytes: 200 * 1024 * 1024)
                }
                let (data, response) = try await URLSession.shared.data(
                    from: url
                )
                if
                    let response = response as? HTTPURLResponse,
                    !(200..<300).contains(response.statusCode)
                {
                    throw URLError(.badServerResponse)
                }
                return data
            }
            guard !Task.isCancelled else { return }
            if request.encryptedAttachment != nil || request.downloadURL?.isFileURL == true {
                guard let encryptedResolver else { throw EncryptedMediaError.unavailable }
                try encryptedResolver.validateActive()
            }
            fullResolutionState.store(
                loadedImage,
                selectedPhotoID: selectedPhotoID
            )
        } catch {
            guard !Task.isCancelled, selectedPhotoID == request.id else { return }
            failedViewingPhotoIDs.insert(request.id)
            // Keep the selected chat image available offline.
        }
    }
}

struct PhotoGroupInteractionPolicy {
    enum Intent: Equatable {
        case undecided
        case horizontalPaging
        case verticalDismissal
    }

    static func allowsHorizontalPaging(
        isSelectedPhotoZoomed: Bool
    ) -> Bool {
        !isSelectedPhotoZoomed
    }

    static func intent(for translation: CGSize) -> Intent {
        let horizontalDistance = abs(translation.width)
        let verticalDistance = abs(translation.height)
        guard max(horizontalDistance, verticalDistance) >= 8 else {
            return .undecided
        }
        guard translation.height > 0 else {
            return .horizontalPaging
        }
        return verticalDistance >= horizontalDistance * 1.15
            ? .verticalDismissal
            : .horizontalPaging
    }
}

struct PhotoLightbox: View {
    @Environment(\.encryptedAttachmentResolver) private var encryptedResolver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let downloadURL: URL?
    let fileName: String
    let encryptedAttachment: AttachmentContent?
    let detailAttachment: AttachmentContent?
    let detailDownloadURL: URL?
    let isAwaitingDisplayImage: Bool
    let supportsDragGestures: Bool
    let allowsUnmagnifiedDismissal: Bool
    let showsCloseButton: Bool
    let showsActionButtons: Bool
    let onZoomStateChanged: (Bool) -> Void
    let onDismiss: () -> Void

    let previewImage: UIImage
    @State private var fullResolutionImage: UIImage?
    @State private var originalDetailImage: UIImage?
    @State private var isLoadingViewingImage = false
    @State private var baseScale: CGFloat = 1
    @State private var gestureScale: CGFloat = 1
    @State private var baseOffset: CGSize = .zero
    @State private var gestureOffset: CGSize = .zero
    @State private var dismissalOffset: CGFloat = 0
    @State private var isMagnifying = false
    @State private var isDismissing = false
    @State private var itemID = UUID()

    init(
        image: UIImage,
        downloadURL: URL?,
        fileName: String,
        encryptedAttachment: AttachmentContent? = nil,
        detailAttachment: AttachmentContent? = nil,
        detailDownloadURL: URL? = nil,
        isAwaitingDisplayImage: Bool = false,
        supportsDragGestures: Bool = true,
        allowsUnmagnifiedDismissal: Bool = true,
        showsCloseButton: Bool = true,
        showsActionButtons: Bool = true,
        onZoomStateChanged: @escaping (Bool) -> Void = { _ in },
        onDismiss: @escaping () -> Void
    ) {
        self.downloadURL = downloadURL
        self.fileName = fileName
        self.encryptedAttachment = encryptedAttachment
        self.detailAttachment = detailAttachment
        self.detailDownloadURL = detailDownloadURL
        self.isAwaitingDisplayImage = isAwaitingDisplayImage
        _isLoadingViewingImage = State(initialValue: encryptedAttachment != nil || downloadURL != nil)
        self.supportsDragGestures = supportsDragGestures
        self.allowsUnmagnifiedDismissal = allowsUnmagnifiedDismissal
        self.showsCloseButton = showsCloseButton
        self.showsActionButtons = showsActionButtons
        self.onZoomStateChanged = onZoomStateChanged
        self.onDismiss = onDismiss
        previewImage = image
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity(backgroundOpacity)
                .ignoresSafeArea()
                .accessibilityElement()
                .accessibilityLabel("Photo viewer")
                .accessibilityIdentifier("photo-lightbox")

            ZStack {
                Image(uiImage: displayedImage)
                    .allowedDynamicRange(.constrainedHigh)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .contentShape(.rect)
                    .gesture(magnifyGesture)
                    .simultaneousGesture(
                        dragGesture,
                        including:
                            supportsDragGestures
                                && (
                                    allowsUnmagnifiedDismissal
                                        || scale > 1
                                )
                                ? .all
                                : .none
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.snappy(duration: 0.25)) {
                            if baseScale > 1 {
                                resetZoom()
                            } else {
                                baseScale = 2
                            }
                        }
                    }
                    .accessibilityLabel(fileName)

                if isLoadingViewingImage || isAwaitingDisplayImage {
                    ProgressView()
                        .tint(.white)
                        .padding(10)
                        .background(.black.opacity(0.45), in: .circle)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(16)
                        .allowsHitTesting(false)
                        .accessibilityLabel("Loading higher resolution photo")
                }
                controls
            }
            .scaleEffect(dismissalScale)
            .offset(y: dismissalOffset)
        }
        .statusBarHidden()
        .presentationBackground(.clear)
        .encryptedMediaLifetime(encryptedResolver) {
            if encryptedAttachment != nil || downloadURL?.isFileURL == true { fullResolutionImage = nil; originalDetailImage = nil; onDismiss() }
        }
        .task(id: EncryptedMediaTaskIdentity(resource: encryptedAttachment?.storagePath ?? downloadURL?.absoluteString, resolver: encryptedResolver.map(ObjectIdentifier.init))) {
            await loadFullResolutionImage()
        }
        .task(id: scale > 1) {
            await loadOriginalDetailIfZoomed()
        }
        .onAppear {
            isDismissing = false
        }
        .onChange(of: scale > 1) {
            onZoomStateChanged(scale > 1)
        }
        .onDisappear {
            onZoomStateChanged(false)
            fullResolutionImage = nil
            originalDetailImage = nil
        }
    }

    private var controls: some View {
        VStack {
            HStack {
                Spacer()

                if showsCloseButton {
                    PhotoLightboxCloseButton(action: requestDismissal)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Spacer()

            HStack {
                Spacer()

                if showsActionButtons {
                    PhotoLightboxActionPanel(
                        request: PhotoLightboxDownloadRequest(
                            id: itemID,
                            image: displayedImage,
                            downloadURL: downloadURL, encryptedAttachment: encryptedAttachment
                        )
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private var scale: CGFloat {
        min(max(baseScale * gestureScale, 1), 5)
    }

    private var displayedImage: UIImage {
        (scale > 1 ? originalDetailImage : nil) ?? fullResolutionImage ?? previewImage
    }

    private var offset: CGSize {
        guard scale > 1 else { return .zero }
        return CGSize(
            width: baseOffset.width + gestureOffset.width,
            height: baseOffset.height + gestureOffset.height
        )
    }

    private var dismissalProgress: CGFloat {
        min(dismissalOffset / PhotoLightboxDismissalPolicy.distanceThreshold, 1)
    }

    private var dismissalScale: CGFloat {
        1 - (dismissalProgress * 0.06)
    }

    private var backgroundOpacity: CGFloat {
        1 - (dismissalProgress * 0.7)
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                isMagnifying = true
                dismissalOffset = 0
                gestureScale = value.magnification
            }
            .onEnded { value in
                baseScale = min(
                    max(baseScale * value.magnification, 1),
                    5
                )
                gestureScale = 1
                if baseScale == 1 {
                    baseOffset = .zero
                    gestureOffset = .zero
                }
                isMagnifying = false
            }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                if scale > 1 || isMagnifying {
                    dismissalOffset = 0
                    gestureOffset = value.translation
                } else if PhotoLightboxDismissalPolicy.shouldTrack(
                    translation: value.translation
                ) {
                    dismissalOffset = value.translation.height
                } else {
                    dismissalOffset = 0
                }
            }
            .onEnded { value in
                if scale > 1 || isMagnifying {
                    baseOffset = CGSize(
                        width: baseOffset.width + value.translation.width,
                        height: baseOffset.height + value.translation.height
                    )
                    gestureOffset = .zero
                    return
                }

                gestureOffset = .zero
                if PhotoLightboxDismissalPolicy.shouldDismiss(
                    translation: value.translation,
                    predictedEndTranslation: value.predictedEndTranslation,
                    scale: scale
                ) {
                    requestDismissal()
                } else {
                    withAnimation(
                        reduceMotion
                            ? .easeOut(duration: 0.12)
                            : .spring(response: 0.28, dampingFraction: 0.86)
                    ) {
                        dismissalOffset = 0
                    }
                }
            }
    }

    private func requestDismissal() {
        guard !isDismissing else { return }
        isDismissing = true
        onDismiss()
    }

    private func resetZoom() {
        baseScale = 1
        gestureScale = 1
        baseOffset = .zero
        gestureOffset = .zero
    }

    private func loadOriginalDetailIfZoomed() async {
        guard scale > 1 else { originalDetailImage = nil; return }
        guard originalDetailImage == nil else { return }
        do {
            let attachment = encryptedAttachment ?? detailAttachment
            let decoded: UIImage?
            if let attachment, EncryptedMediaLoading.isEncrypted(attachment) {
                let bytes = try await EncryptedMediaLoading.data(attachment, resolver: encryptedResolver) { throw EncryptedMediaError.unavailable }
                decoded = await ImageDecoding.thumbnail(from: bytes, maximumPixelSize: 8192, prefersHDR: true)
            } else if let url = downloadURL ?? detailDownloadURL {
                if url.isFileURL {
                    decoded = try await PhotoLightboxLocalDetail.image(from: url)
                } else {
                    let bytes = try await URLSession.shared.data(from: url).0
                    decoded = await ImageDecoding.thumbnail(from: bytes, maximumPixelSize: 8192, prefersHDR: true)
                }
            } else { return }
            try Task.checkCancellation()
            if let attachment { try EncryptedMediaLoading.validate(attachment, resolver: encryptedResolver) }
            guard scale > 1 else { return }
            originalDetailImage = decoded
        } catch { /* The sharp viewing image remains usable if original detail is unavailable. */ }
    }

    private func loadFullResolutionImage() async {
        guard encryptedAttachment != nil || downloadURL != nil else { return }
        isLoadingViewingImage = true
        defer { isLoadingViewingImage = false }
        fullResolutionImage = nil
        if let attachment = encryptedAttachment {
            do {
                let bytes = try await EncryptedMediaLoading.photoDisplayData(attachment, rendition: .viewer, resolver: encryptedResolver) { throw EncryptedMediaError.unavailable }
                let decoded = await ImageDecoding.thumbnail(from: bytes, maximumPixelSize: 4096, prefersHDR: true)
                try EncryptedMediaLoading.validate(attachment, resolver: encryptedResolver)
                fullResolutionImage = decoded
            } catch { /* The authenticated thumbnail remains visible until session invalidation. */ }
            return
        }
        guard let downloadURL else { return }

        do {
            if downloadURL.isFileURL {
                guard let encryptedResolver else { throw EncryptedMediaError.unavailable }
                try encryptedResolver.validateActive()
                let bytes = try EncryptedMediaLoading.localData(downloadURL, maximumBytes: 200 * 1024 * 1024)
                let decoded = await ImageDecoding.thumbnail(from: bytes, maximumPixelSize: 4096, prefersHDR: true)
                try Task.checkCancellation(); try encryptedResolver.validateActive()
                fullResolutionImage = decoded
                return
            }
            let (data, response) = try await URLSession.shared.data(
                from: downloadURL
            )
            if
                let response = response as? HTTPURLResponse,
                !(200..<300).contains(response.statusCode)
            {
                return
            }
            guard
                !Task.isCancelled,
                let loadedImage = await ImageDecoding.image(from: data)
            else {
                return
            }
            fullResolutionImage = loadedImage
        } catch {
            // The cached display image is still fully usable offline.
        }
    }
}

/// Downsample an admitted local original without materializing its encoded bytes in memory.
enum PhotoLightboxLocalDetail {
    static func image(from url: URL, maximumPixelSize: Int = 8192) async throws -> UIImage? {
        try Task.checkCancellation()
        guard url.isFileURL else { throw EncryptedMediaError.unavailable }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize else {
            throw EncryptedMediaError.unavailable
        }
        guard size <= 200 * 1024 * 1024 else { throw EncryptedMediaError.tooLarge }
        let image = await ImageDecoding.thumbnail(from: url, maximumPixelSize: maximumPixelSize, prefersHDR: true)
        try Task.checkCancellation()
        return image
    }
}

private struct PhotoLightboxActionPanel: View {
    @Environment(\.encryptedAttachmentResolver) private var encryptedResolver
    @Environment(\.openURL) private var openURL

    let request: PhotoLightboxDownloadRequest

    @State private var isSharing = false
    @State private var isSaving = false
    @State private var didSave = false
    @State private var saveAlert: PhotoSaveAlert?

    var body: some View {
        panel
            .sheet(isPresented: $isSharing) {
                PhotoActivityView(image: request.image)
                    .presentationDetents([.medium, .large])
            }
            .alert(item: $saveAlert) { alert in
                alert.presentation {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
            .encryptedMediaLifetime(encryptedResolver) {
                if request.encryptedAttachment != nil || request.downloadURL?.isFileURL == true { isSharing = false }
            }
            .sensoryFeedback(.success, trigger: didSave)
    }

    @ViewBuilder
    private var panel: some View {
        if #available(iOS 26.0, *) {
            actionButtons
                .padding(4)
                .glassEffect(.regular.interactive(), in: .capsule)
        } else {
            actionButtons
                .padding(4)
                .background(.ultraThinMaterial, in: .capsule)
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 4) {
            Button {
                Task {
                    await savePhoto()
                }
            } label: {
                Group {
                    if isSaving {
                        ProgressView()
                            .tint(.white)
                    } else if didSave {
                        Image(systemName: "checkmark")
                    } else {
                        Image(systemName: "square.and.arrow.down")
                    }
                }
                .frame(width: 40, height: 40)
                .contentShape(.circle)
            }
            .disabled(isSaving || didSave)
            .accessibilityLabel(didSave ? "Photo saved" : "Save photo")
            .accessibilityIdentifier("save-photo")

            Button {
                if request.encryptedAttachment != nil || request.downloadURL?.isFileURL == true {
                    guard let encryptedResolver, (try? encryptedResolver.validateActive()) != nil else { return }
                }
                isSharing = true
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .frame(width: 40, height: 40)
                    .contentShape(.circle)
            }
            .accessibilityLabel("Share photo")
            .accessibilityIdentifier("share-photo")
        }
        .font(.body.weight(.semibold))
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    @MainActor
    private func savePhoto() async {
        isSaving = true
        defer { isSaving = false }

        do {
            let result = try await PhotoLibrarySaver().save {
                if request.encryptedAttachment != nil || request.downloadURL?.isFileURL == true {
                    guard let encryptedResolver else { throw EncryptedMediaError.unavailable }
                    try encryptedResolver.validateActive()
                }
                let bytes = try await PhotoLightboxDownloadPreparation.data(for: request, resolver: encryptedResolver)
                if request.encryptedAttachment != nil || request.downloadURL?.isFileURL == true { try encryptedResolver?.validateActive() }
                return bytes
            }
            switch result {
            case .saved:
                didSave = true
            case .accessDenied:
                saveAlert = .photoAccessRequired
            }
        } catch is CancellationError {
            return
        } catch {
            saveAlert = .saveFailed(error.localizedDescription)
        }
    }
}

private struct PhotoLightboxCloseButton: View {
    let action: () -> Void
    private let controlPadding: CGFloat = 2

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                button
                    .padding(controlPadding)
                    .glassEffect(.regular.interactive(), in: .circle)
            } else {
                button
                    .padding(controlPadding)
                    .background(.ultraThinMaterial, in: .circle)
            }
        }
    }

    private var button: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .font(.body.weight(.semibold))
        .buttonStyle(.plain)
        .frame(width: 44, height: 44)
        .contentShape(.circle)
        .foregroundStyle(.white)
        .accessibilityLabel("Close photo")
        .accessibilityIdentifier("close-photo-lightbox")
    }
}

enum PhotoSaveAlert: Identifiable {
    case photoAccessRequired
    case saveFailed(String)
    case groupSaveResult(saved: Int, failed: Int)

    var id: String {
        switch self {
        case .photoAccessRequired:
            "photo-access-required"
        case .saveFailed:
            "save-failed"
        case .groupSaveResult:
            "group-save-result"
        }
    }

    @MainActor
    func presentation(openSettings: @escaping () -> Void) -> Alert {
        switch self {
        case .photoAccessRequired:
            Alert(title: Text("Photo Access Is Off"),
                  message: Text("Allow Peapod to add photos in Settings to save photos."),
                  primaryButton: .default(Text("Open Settings"), action: openSettings),
                  secondaryButton: .cancel(Text("Not Now")))
        case let .saveFailed(message):
            Alert(title: Text("Couldn’t Save Photo"), message: Text(message),
                  dismissButton: .cancel(Text("OK")))
        case let .groupSaveResult(saved, failed):
            Alert(title: Text(failed == 0 ? "Photos Saved" : "Some Photos Couldn’t Be Saved"),
                  message: Text(failed == 0 ? "Saved \(saved) photos." : "Saved \(saved) photos. \(failed) couldn’t be saved. Try again to save the remaining photos."),
                  dismissButton: .default(Text("OK")))
        }
    }
}

struct PhotoLightboxDismissalPolicy {
    static let distanceThreshold: CGFloat = 120
    static let projectedDistanceThreshold: CGFloat = 260
    private static let verticalDominance: CGFloat = 1.15

    static func shouldTrack(translation: CGSize) -> Bool {
        isDownwardAndVertical(translation)
    }

    static func shouldDismiss(
        translation: CGSize,
        predictedEndTranslation: CGSize,
        scale: CGFloat
    ) -> Bool {
        guard scale <= 1 else { return false }
        guard isDownwardAndVertical(translation) else { return false }

        let crossedDistance = translation.height >= distanceThreshold
        let crossedProjectedDistance =
            isDownwardAndVertical(predictedEndTranslation)
                && predictedEndTranslation.height
                    >= projectedDistanceThreshold
        return crossedDistance || crossedProjectedDistance
    }

    private static func isDownwardAndVertical(_ translation: CGSize) -> Bool {
        translation.height > 0
            && translation.height
                >= abs(translation.width) * verticalDominance
    }
}

private struct PhotoActivityView: UIViewControllerRepresentable {
    let image: UIImage

    func makeUIViewController(
        context: Context
    ) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: [image],
            applicationActivities: nil
        )
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}
