import ImageIO
@preconcurrency import UIKit

enum ImageDecoding {
    private struct Transfer: @unchecked Sendable {
        let image: UIImage?
    }

    static func image(from data: Data) async -> UIImage? {
        let transfer = await Task.detached(priority: .userInitiated) {
            let image = UIImage(data: data)
            return Transfer(image: image?.preparingForDisplay() ?? image)
        }.value
        return transfer.image
    }

    static func thumbnail(
        from data: Data,
        maximumPixelSize: Int,
        prefersHDR: Bool = false
    ) async -> UIImage? {
        let transfer = await Task.detached(priority: .userInitiated) {
            guard
                let source = CGImageSourceCreateWithData(
                    data as CFData,
                    [kCGImageSourceShouldCache: false] as CFDictionary
                )
            else {
                return Transfer(image: nil)
            }

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
                return Transfer(image: nil)
            }
            return Transfer(image: UIImage(cgImage: image))
        }.value
        return transfer.image
    }

    static func thumbnail(from url: URL, maximumPixelSize: Int, prefersHDR: Bool = false) async -> UIImage? {
        let transfer = await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary),
                let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                    kCGImageSourceDecodeRequest: prefersHDR ? kCGImageSourceDecodeToHDR : kCGImageSourceDecodeToSDR,
                ] as CFDictionary) else { return Transfer(image: nil) }
            return Transfer(image: UIImage(cgImage: image))
        }.value
        return transfer.image
    }

    static func validatedData(_ data: Data) async -> Data? {
        await thumbnail(from: data, maximumPixelSize: 64) == nil
            ? nil
            : data
    }

    static func jpegData(
        from image: UIImage,
        compressionQuality: CGFloat
    ) async -> Data? {
        let transfer = Transfer(image: image)
        return await Task.detached(priority: .userInitiated) {
            transfer.image?.jpegData(
                compressionQuality: compressionQuality
            )
        }.value
    }
}
