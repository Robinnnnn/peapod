@preconcurrency import AppKit
import CryptoKit
import ImageIO
import MinesE2EE

final class MacAttachmentImageCache: @unchecked Sendable {
    static let shared = MacAttachmentImageCache()

    private let memory = NSCache<NSString, NSImage>()
    private struct Transfer: @unchecked Sendable { let image: NSImage? }
    private static let workQueue = DispatchQueue(label: "mines.mac-image-cache", qos: .utility)
    private let directory: URL

    init(cacheDirectory: URL? = nil) {
        directory =
            cacheDirectory
            ?? FileManager.default.urls(
                for: .cachesDirectory,
                in: .userDomainMask
            )[0]
            .appendingPathComponent(
                "MacAttachmentImageThumbnails",
                isDirectory: true
            )
        memory.countLimit = 80
        memory.totalCostLimit = 64 * 1_024 * 1_024
    }

    func image(forKey key: String) -> NSImage? {
        memory.object(forKey: key as NSString)
    }

    /// Disk IO and thumbnail decoding are serialized and never performed by a row initializer.
    func loadImage(forKey key: String) async -> NSImage? {
        if let image = image(forKey: key) { return image }
        let transfer: Transfer = await withCheckedContinuation { continuation in
            Self.workQueue.async {
                let image = (try? Data(contentsOf: self.fileURL(forKey: key), options: .mappedIfSafe))
                    .flatMap { Self.displayImage(from: $0) }
                continuation.resume(returning: Transfer(image: image))
            }
        }
        guard !Task.isCancelled else { return nil }
        let image = transfer.image
        if let image { memory.setObject(image, forKey: key as NSString, cost: estimatedMemoryCost(of: image)) }
        return image
    }

    static func decodeImage(from data: Data, maximumPixelSize: Int = PhotoRendition.chat.maximumPixelDimension, prefersHDR: Bool = false) async -> NSImage? {
        let transfer: Transfer = await withCheckedContinuation { continuation in
            workQueue.async {
                continuation.resume(returning: Transfer(image: displayImage(from: data, maximumPixelSize: maximumPixelSize, prefersHDR: prefersHDR)))
            }
        }
        return Task.isCancelled ? nil : transfer.image
    }

    static func decodeFile(_ url: URL, maximumPixelSize: Int, prefersHDR: Bool = true) async -> NSImage? {
        let transfer: Transfer = await withCheckedContinuation { continuation in
            workQueue.async {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                    continuation.resume(returning: Transfer(image: nil)); return
                }
                continuation.resume(returning: Transfer(image: displayImage(source: source, maximumPixelSize: maximumPixelSize, prefersHDR: prefersHDR)))
            }
        }
        return Task.isCancelled ? nil : transfer.image
    }

    func insert(_ image: NSImage, forKey key: String) {
        memory.setObject(
            image,
            forKey: key as NSString,
            cost: estimatedMemoryCost(of: image)
        )

        let transfer = Transfer(image: image)
        Self.workQueue.async { if let image = transfer.image { self.persist(image, forKey: key) } }
    }

    /// Awaitable persistence for callers which require a durable cache boundary.
    func storeDownloadedImage(_ image: NSImage, forKey key: String) async {
        memory.setObject(image, forKey: key as NSString, cost: estimatedMemoryCost(of: image))
        let transfer = Transfer(image: image)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Self.workQueue.async {
                if let image = transfer.image { self.persist(image, forKey: key) }
                continuation.resume()
            }
        }
    }

    static func pngData(from image: NSImage) async -> Data? {
        let transfer = Transfer(image: image)
        return await withCheckedContinuation { continuation in
            workQueue.async {
                let data = transfer.image?.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?
                    .representation(using: .png, properties: [:])
                continuation.resume(returning: data)
            }
        }
    }

    private func persist(_ image: NSImage, forKey key: String) {
        guard let data = jpegData(from: image) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var directoryValues = URLResourceValues()
            directoryValues.isExcludedFromBackup = true
            var directoryURL = directory
            try? directoryURL.setResourceValues(directoryValues)
            try data.write(to: fileURL(forKey: key), options: .atomic)
        } catch { /* A cache failure never blocks sending or displaying a photo. */ }
    }

    static func displayImage(from data: Data, maximumPixelSize: Int = PhotoRendition.chat.maximumPixelDimension, prefersHDR: Bool = false) -> NSImage? {
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
            )
        else {
            return nil
        }

        return displayImage(source: source, maximumPixelSize: maximumPixelSize, prefersHDR: prefersHDR)
    }

    private static func displayImage(source: CGImageSource, maximumPixelSize: Int, prefersHDR: Bool) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceDecodeRequest: prefersHDR ? kCGImageSourceDecodeToHDR : kCGImageSourceDecodeToSDR,
        ]
        guard
            let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                options as CFDictionary
            )
        else {
            return nil
        }
        return NSImage(
            cgImage: image,
            size: NSSize(
                width: CGFloat(image.width),
                height: CGFloat(image.height)
            )
        )
    }

    private func fileURL(forKey key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appendingPathComponent(
            "\(digest).jpg",
            isDirectory: false
        )
    }

    private func jpegData(from image: NSImage) -> Data? {
        guard
            let source = image.cgImage(
                forProposedRect: nil,
                context: nil,
                hints: nil
            )
        else {
            return nil
        }
        return NSBitmapImageRep(cgImage: source).representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.94]
        )
    }

    private func estimatedMemoryCost(of image: NSImage) -> Int {
        guard
            let representation = image.representations.first
                as? NSBitmapImageRep
        else {
            return max(
                1,
                Int(image.size.width * image.size.height * 4)
            )
        }
        return max(
            1,
            representation.pixelsWide * representation.pixelsHigh * 4
        )
    }
}
