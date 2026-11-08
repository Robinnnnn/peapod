import Foundation
import ImageIO
import MinesE2EE

/// Bounded display copies only. The staged source and its color space remain untouched.
/// A quota miss omits the copy instead of repeatedly reducing visual quality.
enum EncryptedPhotoRenditionImage {
    static func make(from original: Data, rendition: PhotoRendition) -> Data? {
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithData(original as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              (properties[kCGImagePropertyDepth] as? Int ?? 8) <= 8,
              properties[kCGImagePropertyIsFloat] as? Bool != true,
              !hasAuxiliaryImageMetadata(properties),
              !hasAuxiliaryImageMetadata(CGImageSourceCopyProperties(source, nil) as? [CFString: Any] ?? [:]) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: rendition.maximumPixelDimension]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              image.width > 0, image.height > 0,
              max(image.width, image.height) <= rendition.maximumPixelDimension, !Task.isCancelled else { return nil }
        let alpha = [.first, .last, .premultipliedFirst, .premultipliedLast].contains(image.alphaInfo)
        // PNG screenshots/text and transparent art stay lossless. JPEG/HEIC photos
        // retain the thumbnail's original CGColorSpace, including wide-gamut profiles.
        let lossless = alpha || CGImageSourceGetType(source) == "public.png" as CFString
        let formats = lossless ? ["public.png"] : ["public.heic", "public.jpeg"]
        for format in formats {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, format as CFString, 1, nil) else { continue }
            let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.94,
                                               kCGImagePropertyOrientation: 1]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination), !Task.isCancelled else { continue }
            if output.length <= rendition.maximumBytes { return output as Data }
        }
        return nil
    }

    // Metadata only: copying auxiliary data itself can materialize an unbounded
    // decoded gain map. Until HDR encoding is verified, use the untouched original
    // for high-bit-depth, floating-point, gain-map and auxiliary-image sources.
    static func hasAuxiliaryImageMetadata(_ properties: [CFString: Any]) -> Bool {
        // ImageIO wraps single-image HEIC/JPEG gain-map metadata here. ImageCount
        // and the primary image's8-bit depth do not rule out an HDR auxiliary image.
        if let contents = properties[kCGImagePropertyFileContentsDictionary] as? [CFString: Any],
           hasAuxiliaryImageMetadata(contents) { return true }
        if let auxiliary = properties[kCGImagePropertyAuxiliaryData] as? [Any], !auxiliary.isEmpty { return true }
        if properties[kCGImagePropertyAuxiliaryDataType] != nil { return true }
        if let images = properties[kCGImagePropertyImages] as? [[CFString: Any]], images.contains(where: hasAuxiliaryImageMetadata) { return true }
        return false
    }

    static func isDecodable(_ bytes: Data, rendition: PhotoRendition) -> Bool {
        guard !bytes.isEmpty, bytes.count <= rendition.maximumBytes,
              let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...rendition.maximumPixelDimension).contains(width),
              (1...rendition.maximumPixelDimension).contains(height) else { return false }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) != nil
    }
}
