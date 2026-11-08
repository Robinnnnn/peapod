import Photos
import SwiftUI

struct RecentPhotoAttachmentSheet: View {
    let maximumSelectionCount: Int
    let onSelect: ([String]) -> Void
    let onLibrary: () -> Void
    let onFiles: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var library = RecentPhotoLibrary()
    @State private var selection: RecentPhotoSelection
    @State private var sizing = RecentPhotoAttachmentSizing()

    init(maximumSelectionCount: Int, onSelect: @escaping ([String]) -> Void,
         onLibrary: @escaping () -> Void, onFiles: @escaping () -> Void) {
        self.maximumSelectionCount = maximumSelectionCount
        self.onSelect = onSelect
        self.onLibrary = onLibrary
        self.onFiles = onFiles
        _selection = State(initialValue: RecentPhotoSelection(maximumCount: maximumSelectionCount))
    }

    var body: some View {
        ScrollView(.vertical) {
            RecentPhotoAttachmentContent(
                selectionCount: selection.identifiers.count,
                onSelect: { onSelect(selection.identifiers) },
                onLibrary: onLibrary,
                onFiles: onFiles
            ) {
                photoRow
            }
            // Measure the padded content, not the scroll viewport. The viewport
            // can stay scrollable when accessibility text exceeds the sheet.
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                sizing.fit(height: height)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .task { await library.open() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { library.refresh() }
        }
        .onChange(of: library.assets.map(\.localIdentifier)) { _, identifiers in
            selection.retainAvailable(Set(identifiers))
        }
        .presentationDetents([.height(sizing.contentHeight), .large], selection: $sizing.selection)
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var photoRow: some View {
        if library.assets.isEmpty {
            Text(emptyLibraryMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
                .padding(.horizontal, 24)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(library.assets, id: \.localIdentifier) { asset in
                        let index = selection.identifiers.firstIndex(of: asset.localIdentifier)
                        Button {
                            selection.toggle(asset.localIdentifier)
                        } label: {
                            RecentPhotoThumbnail(asset: asset)
                                .overlay(alignment: .topTrailing) {
                                    selectionIndicator(index: index)
                                        .padding(7)
                                }
                        }
                        .buttonStyle(.plain)
                        .disabled(index == nil && selection.identifiers.count >= selection.maximumCount)
                        .accessibilityLabel(photoLabel(asset))
                        .accessibilityValue(index.map { "Selected, photo \($0 + 1)" } ?? "Not selected")
                        .accessibilityAddTraits(index == nil ? [] : .isSelected)
                    }
                }
                .padding(.horizontal, 24)
            }
            .frame(height: 112)
        }
    }

    private var emptyLibraryMessage: String {
        switch library.authorization {
        case .denied, .restricted: "Choose photos with See all."
        case .limited: "No recent photos in your selection."
        case .notDetermined: "Your recent photos appear here."
        default: "No recent photos."
        }
    }

    private func photoLabel(_ asset: PHAsset) -> String {
        guard let date = asset.creationDate else { return "Photo" }
        return "Photo, \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private func selectionIndicator(index: Int?) -> some View {
        ZStack {
            Circle().fill(index == nil ? Color.black.opacity(0.25) : Color.accentColor)
            Circle().strokeBorder(.white, lineWidth: 2)
            if let index {
                Text("\(index + 1)").font(.caption.bold()).foregroundStyle(.white)
            }
        }
        .frame(width: 25, height: 25)
        .accessibilityHidden(true)
    }
}

/// Keep the compact detent in sync with content changes without collapsing a
/// sheet the person deliberately expanded. Heights exclude the system safe area.
struct RecentPhotoAttachmentSizing {
    // Preserve the previous usable compact presentation until the first
    // content measurement arrives, rather than presenting a collapsed sheet.
    private(set) var contentHeight: CGFloat = 250
    var selection: PresentationDetent = .height(250)

    mutating func fit(height: CGFloat) {
        guard height.isFinite, height > 0 else { return }
        contentHeight = ceil(height)
        if selection != .large {
            selection = .height(contentHeight)
        }
    }
}

/// The production layout is independent of Photos access so its intrinsic
/// height can be exercised with synthetic media in layout unit tests.
struct RecentPhotoAttachmentContent<Photos: View>: View {
    let selectionCount: Int
    let onSelect: () -> Void
    let onLibrary: () -> Void
    let onFiles: () -> Void
    @ViewBuilder var photos: () -> Photos

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    Text("Library").font(.headline)
                    Spacer(minLength: 8)
                    headerActions.fixedSize()
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Library").font(.headline)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) { headerActions.fixedSize() }
                        VStack(alignment: .leading, spacing: 12) {
                            headerActions.fixedSize(horizontal: false, vertical: true)
                        }
                        .multilineTextAlignment(.leading)
                    }
                }
            }
            .padding(.horizontal, 24)

            photos()

            if selectionCount > 0 {
                Button(action: onSelect) {
                    Text("Add \(selectionCount) \(selectionCount == 1 ? "photo" : "photos")")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 24)
            }
        }
        .padding(.top, 32)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
    }

    var headerActions: some View {
        Group {
            Button(action: onFiles) {
                Text("Attach File")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Attach File")
            Button("See All", action: onLibrary)
        }
        .font(.subheadline.weight(.semibold))
    }
}

private struct RecentPhotoThumbnail: View {
    let asset: PHAsset
    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?
    @State private var generation: UUID?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(.quaternary)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: 112, height: 112)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .onAppear(perform: requestThumbnail)
        .onDisappear {
            generation = nil
            if let requestID { PHImageManager.default().cancelImageRequest(requestID) }
            requestID = nil
        }
        .accessibilityHidden(true)
    }

    private func requestThumbnail() {
        let token = UUID()
        generation = token
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        let size = 112 * UIScreen.main.scale
        requestID = PHImageManager.default().requestImage(for: asset,
            targetSize: CGSize(width: size, height: size), contentMode: .aspectFill,
            options: options) { result, info in
                guard let result, info?[PHImageCancelledKey] as? Bool != true else { return }
                Task { @MainActor in
                    guard generation == token else { return }
                    image = result
                }
            }
    }
}
