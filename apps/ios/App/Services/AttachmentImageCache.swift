import CryptoKit
import ImageIO
import MinesE2EE
import UIKit

final class AttachmentImageCache: @unchecked Sendable {
    static let shared = AttachmentImageCache()

    private let memory = NSCache<NSString, UIImage>()
    private let directory: URL

    init(cacheDirectory: URL? = nil) {
        directory =
            cacheDirectory
            ?? FileManager.default.urls(
                for: .cachesDirectory,
                in: .userDomainMask
            )[0]
            .appendingPathComponent(
                "AttachmentImageThumbnails",
                isDirectory: true
            )
        memory.countLimit = 80
        memory.totalCostLimit = 48 * 1_024 * 1_024
    }

    func image(forKey key: String) -> UIImage? {
        let cacheKey = key as NSString
        if let image = memory.object(forKey: cacheKey) {
            return image
        }

        guard
            let data = try? Data(
                contentsOf: fileURL(forKey: key),
                options: .mappedIfSafe
            ),
            let image = UIImage(data: data)
        else {
            return nil
        }

        memory.setObject(
            image,
            forKey: cacheKey,
            cost: estimatedMemoryCost(of: image)
        )
        return image
    }

    func memoryImage(forKey key: String) -> UIImage? {
        memory.object(forKey: key as NSString)
    }

    func loadImage(forKey key: String) async -> UIImage? {
        if let image = memoryImage(forKey: key) {
            return image
        }

        let fileURL = fileURL(forKey: key)
        guard
            let data = await Task.detached(priority: .utility, operation: {
                try? Data(contentsOf: fileURL, options: .mappedIfSafe)
            }).value,
            let image = await ImageDecoding.thumbnail(
                from: data,
                maximumPixelSize: PhotoRendition.chat.maximumPixelDimension
            )
        else {
            return nil
        }

        memory.setObject(
            image,
            forKey: key as NSString,
            cost: estimatedMemoryCost(of: image)
        )
        return image
    }

    func insertInMemory(_ image: UIImage, forKey key: String) {
        memory.setObject(
            image,
            forKey: key as NSString,
            cost: estimatedMemoryCost(of: image)
        )
    }

    func insert(_ image: UIImage, forKey key: String) {
        insertInMemory(image, forKey: key)

        guard let data = image.jpegData(compressionQuality: 0.94) else {
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            var directoryValues = URLResourceValues()
            directoryValues.isExcludedFromBackup = true
            var directoryURL = directory
            try? directoryURL.setResourceValues(directoryValues)
            try data.write(to: fileURL(forKey: key), options: .atomic)
        } catch {
            // A cache write must never prevent the message from sending.
        }
    }

    /// Encoding and persisting downloaded thumbnails must not block scrolling.
    /// Awaiting this also bounds each row's work before its next image loads.
    func storeDownloadedImage(_ image: UIImage, forKey key: String) async {
        await Task.detached(priority: .utility) { [self] in
            insert(image, forKey: key)
        }.value
    }

    static func displayImage(from data: Data) async -> UIImage? {
        await ImageDecoding.thumbnail(
            from: data,
            maximumPixelSize: PhotoRendition.chat.maximumPixelDimension
        )
    }

    static func displayImage(from data: Data) -> UIImage? {
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
            )
        else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: PhotoRendition.chat.maximumPixelDimension,
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
        return UIImage(cgImage: image)
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

    private func estimatedMemoryCost(of image: UIImage) -> Int {
        let pixelWidth = Int(image.size.width * image.scale)
        let pixelHeight = Int(image.size.height * image.scale)
        return max(1, pixelWidth * pixelHeight * 4)
    }
}
