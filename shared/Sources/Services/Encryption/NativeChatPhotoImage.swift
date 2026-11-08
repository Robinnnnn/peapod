import Foundation
#if canImport(UIKit)
import UIKit
typealias NativeChatPhotoImage = UIImage
#else
import AppKit
typealias NativeChatPhotoImage = NSImage
#endif

@MainActor
enum NativeChatPhotoDecoding {
    static func decode(_ bytes: Data) async -> NativeChatPhotoImage? {
#if canImport(UIKit)
        await AttachmentImageCache.displayImage(from: bytes)
#else
        await MacAttachmentImageCache.decodeImage(from: bytes)
#endif
    }

    static func cost(_ image: NativeChatPhotoImage) -> Int {
#if canImport(UIKit)
        if let cgImage = image.cgImage { return cgImage.bytesPerRow * cgImage.height }
        return max(1, Int(image.size.width * image.scale * image.size.height * image.scale * 4))
#else
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return cgImage.bytesPerRow * cgImage.height
        }
        return max(1, Int(image.size.width * image.size.height * 4))
#endif
    }
}
