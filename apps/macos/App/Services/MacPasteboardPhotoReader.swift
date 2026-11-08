import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Keeps encoded clipboard photos intact. Pixel-only pasteboard objects have no
/// source encoding, so that fallback uses lossless PNG.
@MainActor
enum MacPasteboardPhotoReader {
    struct Photo {
        let data: Data
        let contentType: UTType
    }

    static func photo(from pasteboard: NSPasteboard) -> Photo? {
        let types = (pasteboard.types ?? []).filter {
            UTType($0.rawValue)?.conforms(to: .image) == true
        }.sorted { rank($0.rawValue) < rank($1.rawValue) }
        for type in types {
            guard let data = pasteboard.data(forType: type),
                  let source = CGImageSourceCreateWithData(data as CFData,
                    [kCGImageSourceShouldCache: false] as CFDictionary),
                  let identifier = CGImageSourceGetType(source),
                  let contentType = UTType(identifier as String),
                  contentType.conforms(to: .image) else { continue }
            return Photo(data: data, contentType: contentType)
        }
        guard let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff),
              let png = representation.representation(using: .png, properties: [:]) else { return nil }
        return Photo(data: png, contentType: .png)
    }

    private static func rank(_ identifier: String) -> Int {
        switch UTType(identifier) {
        case .heic: 0
        case .jpeg: 1
        case .png: 2
        default: 3
        }
    }
}
