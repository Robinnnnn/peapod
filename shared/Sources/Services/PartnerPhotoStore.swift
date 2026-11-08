import CryptoKit
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
typealias PartnerPhotoImage = NSImage
#else
import UIKit
typealias PartnerPhotoImage = UIImage
#endif

/// Device-local photo and nickname overrides. Neither identifiers nor profile data leave the device.
@MainActor @Observable
final class PartnerPhotoStore {
    enum PhotoError: LocalizedError, Equatable {
        case invalidImage

        var errorDescription: String? {
            "This photo couldn’t be opened. Choose another photo."
        }
    }

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var cachedImages: [String: PartnerPhotoImage] = [:]
    @ObservationIgnored private var loadedKeys: Set<String> = []
    @ObservationIgnored private var cachedNicknames: [String: String] = [:]
    @ObservationIgnored private var loadedNicknameKeys: Set<String> = []
    private var revision = 0

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("PartnerPhotos", isDirectory: true)
    }

    func image(accountID: String, partnerID: String) -> PartnerPhotoImage? {
        // Reading this revision makes callers observe successful saves and removals.
        _ = revision
        let key = storageKey(accountID: accountID, partnerID: partnerID)
        if !loadedKeys.contains(key) {
            loadedKeys.insert(key)
            if let data = try? Data(contentsOf: photoURL(key: key)),
               let image = Self.thumbnail(data: data) {
                cachedImages[key] = image
            }
        }
        return cachedImages[key]
    }

    func savePhoto(data: Data, accountID: String, partnerID: String) throws {
        guard let image = Self.thumbnail(data: data),
              let encoded = Self.jpegData(image) else {
            throw PhotoError.invalidImage
        }

        try prepareDirectory()

        let key = storageKey(accountID: accountID, partnerID: partnerID)
        try encoded.write(to: photoURL(key: key), options: [.atomic, .completeFileProtection])
        cachedImages[key] = image
        loadedKeys.insert(key)
        revision &+= 1
    }

    func removePhoto(accountID: String, partnerID: String) throws {
        let key = storageKey(accountID: accountID, partnerID: partnerID)
        let url = photoURL(key: key)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        cachedImages.removeValue(forKey: key)
        loadedKeys.insert(key)
        revision &+= 1
    }

    func nickname(accountID: String, partnerID: String) -> String? {
        _ = revision
        let key = storageKey(accountID: accountID, partnerID: partnerID)
        if !loadedNicknameKeys.contains(key) {
            loadedNicknameKeys.insert(key)
            if let stored = try? String(contentsOf: nicknameURL(key: key), encoding: .utf8) {
                let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    cachedNicknames[key] = trimmed
                }
            }
        }
        return cachedNicknames[key]
    }

    /// An empty nickname restores the person's original display name.
    func saveNickname(_ nickname: String, accountID: String, partnerID: String) throws {
        let key = storageKey(accountID: accountID, partnerID: partnerID)
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = nicknameURL(key: key)
        if trimmed.isEmpty {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            cachedNicknames.removeValue(forKey: key)
        } else {
            try prepareDirectory()
            try Data(trimmed.utf8).write(to: url, options: [.atomic, .completeFileProtection])
            cachedNicknames[key] = trimmed
        }
        loadedNicknameKeys.insert(key)
        revision &+= 1
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var localDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try localDirectory.setResourceValues(values)
    }

    private func storageKey(accountID: String, partnerID: String) -> String {
        // A length prefix keeps pairs such as ("ab", "c") and ("a", "bc") distinct.
        let identity = Data("\(accountID.utf8.count):\(accountID)\(partnerID)".utf8)
        return SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
    }

    private func photoURL(key: String) -> URL {
        directory.appendingPathComponent(key).appendingPathExtension("jpg")
    }

    private func nicknameURL(key: String) -> URL {
        directory.appendingPathComponent(key).appendingPathExtension("txt")
    }

    private static func jpegData(_ image: PartnerPhotoImage) -> Data? {
#if os(macOS)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return bytes as Data
#else
        return image.jpegData(compressionQuality: 0.88)
#endif
    }

    private static func thumbnail(data: Data) -> PartnerPhotoImage? {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ),
        let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 512,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary
        ) else { return nil }
        #if os(macOS)
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
#else
        return UIImage(cgImage: image)
#endif
    }
}
