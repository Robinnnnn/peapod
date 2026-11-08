import Foundation
import Observation
#if os(iOS)
import UIKit
typealias LinkPreviewDisplayImage = UIImage
#else
import AppKit
typealias LinkPreviewDisplayImage = NSImage
#endif

/// Metadata and its decoded image are published together, so a warm lazy row
/// can use its final preview dimensions on its first layout pass.
@MainActor
final class LinkPreviewDisplaySnapshot {
    let url: URL
    let metadata: LinkPreviewMetadata
    let image: LinkPreviewDisplayImage?

    init(url: URL, metadata: LinkPreviewMetadata, image: LinkPreviewDisplayImage?) {
        self.url = url
        self.metadata = metadata
        self.image = image
    }
}

@MainActor
final class LinkPreviewDisplayCache {
    static let shared = LinkPreviewDisplayCache()

    private final class Entry {
        let snapshot: LinkPreviewDisplaySnapshot
        let createdAt: Date

        init(snapshot: LinkPreviewDisplaySnapshot, createdAt: Date) {
            self.snapshot = snapshot
            self.createdAt = createdAt
        }
    }

    private let entries = NSCache<NSString, Entry>()
    private var inFlight: [URL: Task<LinkPreviewDisplaySnapshot?, Never>] = [:]
    private let fetch: @MainActor (URL) async -> LinkPreviewContent?
    private let decode: @MainActor (Data) async -> LinkPreviewDisplayImage?
    private let now: @MainActor () -> Date
    private let cacheLifetime: TimeInterval

    init(
        maximumEntries: Int = 64,
        maximumImageBytes: Int = 32 * 1_024 * 1_024,
        cacheLifetime: TimeInterval = 24 * 60 * 60,
        now: @escaping @MainActor () -> Date = Date.init,
        fetch: @escaping @MainActor (URL) async -> LinkPreviewContent? = {
            await LinkPreviewProvider.shared.preview(for: $0.absoluteString)
        },
        decode: @escaping @MainActor (Data) async -> LinkPreviewDisplayImage? = {
#if os(iOS)
            await ImageDecoding.thumbnail(from: $0, maximumPixelSize: 720)
#else
            await Task.detached(priority: .userInitiated) { [data = $0] in
                DecodedImage(image: MacAttachmentImageCache.displayImage(from: data))
            }.value.image
#endif
        }
    ) {
        entries.countLimit = max(1, maximumEntries)
        entries.totalCostLimit = max(1, maximumImageBytes)
        self.cacheLifetime = cacheLifetime
        self.now = now
        self.fetch = fetch
        self.decode = decode
    }

    func cached(for url: URL) -> LinkPreviewDisplaySnapshot? {
        let key = url.absoluteString as NSString
        guard let entry = entries.object(forKey: key) else { return nil }
        guard now().timeIntervalSince(entry.createdAt) < cacheLifetime else {
            entries.removeObject(forKey: key)
            return nil
        }
        return entry.snapshot
    }

    /// Also supports seeding deterministic, already-decoded local previews.
    func insert(_ snapshot: LinkPreviewDisplaySnapshot) {
#if os(iOS)
        let imageBytes = snapshot.image?.cgImage.map {
            $0.bytesPerRow * $0.height
        } ?? 0
#else
        let imageBytes = snapshot.image.map {
            Int($0.size.width * $0.size.height * 4)
        } ?? 0
#endif
        entries.setObject(
            Entry(snapshot: snapshot, createdAt: now()),
            forKey: snapshot.url.absoluteString as NSString,
            cost: imageBytes
        )
    }

    func load(for url: URL) async -> LinkPreviewDisplaySnapshot? {
        guard !Task.isCancelled, LinkPreviewURLPolicy.isAllowed(url) else {
            return nil
        }
        if let cached = cached(for: url) { return cached }

        let request: Task<LinkPreviewDisplaySnapshot?, Never>
        if let existing = inFlight[url] {
            request = existing
        } else {
            // The cache owns this work. One disappearing row must not cancel
            // another row's request or discard a useful prepared result.
            request = Task { [self] in
                defer { inFlight[url] = nil }
                // A completed failure is a final, restrained card too. Cache
                // it so a returning row does not flash through loading again.
                let content = await fetch(url) ?? LinkPreviewContent(
                    metadata: LinkPreviewMetadata(
                        originalURL: url, resolvedURL: url,
                        title: nil, description: nil, imageURL: nil
                    ),
                    imageData: nil
                )
                let image: LinkPreviewDisplayImage?
                if let data = content.imageData {
                    image = await decode(data)
                } else {
                    image = nil
                }
                let snapshot = LinkPreviewDisplaySnapshot(
                    url: url,
                    metadata: content.metadata,
                    image: image
                )
                insert(snapshot)
                return snapshot
            }
            inFlight[url] = request
        }

        let snapshot = await request.value
        return Task.isCancelled ? nil : snapshot
    }
}

#if os(macOS)
// NSImage crosses back only after ImageIO has prepared the thumbnail.
private struct DecodedImage: @unchecked Sendable {
    let image: NSImage?
}
#endif

/// Retains a same-URL preview across task restarts, while preventing an edited
/// message or a cancelled offscreen row from receiving an older async result.
@MainActor
@Observable
final class LinkPreviewDisplayState {
    private(set) var url: URL?
    private(set) var snapshot: LinkPreviewDisplaySnapshot?
    @ObservationIgnored private let cache: LinkPreviewDisplayCache
    @ObservationIgnored private var requestGeneration = UUID()

    init(url: URL?, cache: LinkPreviewDisplayCache = .shared) {
        self.url = url
        self.cache = cache
        snapshot = url.flatMap { cache.cached(for: $0) }
    }

    /// A view's input may change before its task runs. Never show the previous
    /// URL's content during that intervening layout pass.
    func snapshot(for url: URL?) -> LinkPreviewDisplaySnapshot? {
        if self.url == url, let snapshot { return snapshot }
        return url.flatMap { cache.cached(for: $0) }
    }

    func load(for url: URL?) async {
        guard !Task.isCancelled else { return }
        let generation = UUID()
        requestGeneration = generation
        if self.url != url {
            self.url = url
            snapshot = url.flatMap { cache.cached(for: $0) }
        }
        guard let url else { return }
        // A visible card is final for this row. Refreshing an expired cache
        // must not replace its text or dimensions during presentation.
        guard snapshot == nil else { return }
        guard let loaded = await cache.load(for: url) else { return }
        guard
            !Task.isCancelled,
            requestGeneration == generation,
            self.url == url
        else {
            return
        }
        snapshot = loaded
    }
}
