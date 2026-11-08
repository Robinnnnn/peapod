import Foundation
import SwiftUI
import Observation
import MinesE2EE

@MainActor
protocol EncryptedMediaResolving: AnyObject {
    func decryptData(_ attachment: AttachmentContent) async throws -> Data
    func temporaryURL(_ attachment: AttachmentContent) async throws -> URL
    func validateActive() throws
    func photoRenditionData(_ attachment: AttachmentContent, rendition: PhotoRendition) async throws -> Data?
    func photoPreviewData(_ attachment: AttachmentContent) async throws -> Data?
    func cachedPhotoDisplayData(_ attachment: AttachmentContent, rendition: PhotoRendition) async throws -> Data?
}

extension EncryptedMediaResolving {
    func photoRenditionData(_ attachment: AttachmentContent, rendition: PhotoRendition) async throws -> Data? { nil }
    func photoPreviewData(_ attachment: AttachmentContent) async throws -> Data? { nil }
    func cachedPhotoDisplayData(_ attachment: AttachmentContent, rendition: PhotoRendition) async throws -> Data? { nil }
}

extension EncryptedAttachmentResolver: EncryptedMediaResolving {}

private struct EncryptedAttachmentResolverKey: EnvironmentKey {
    static let defaultValue: EncryptedAttachmentResolver? = nil
}
extension EnvironmentValues {
    var encryptedAttachmentResolver: EncryptedAttachmentResolver? {
        get { self[EncryptedAttachmentResolverKey.self] }
        set { self[EncryptedAttachmentResolverKey.self] = newValue }
    }
}

struct EncryptedMediaTaskIdentity<Resource: Hashable>: Hashable {
    let resource: Resource
    let resolver: ObjectIdentifier?
}

enum EncryptedMediaError: LocalizedError {
    case unavailable, tooLarge
    var errorDescription: String? { "This encrypted attachment is unavailable. Try opening the conversation again." }
}

/// The encrypted branch never invokes a legacy loader or a plaintext image cache.
@MainActor
enum EncryptedMediaLoading {
    /// Leaving a recycled row is expected and must not become a retry/error card.
    static func shouldPublishFailure(_ error: Error) -> Bool {
        !Task.isCancelled && !(error is CancellationError)
            && (error as? URLError)?.code != .cancelled
    }
    // Audio/file reads keep their 20 MiB policy; photo/video originals may be 200 MiB.
    static let maximumBytes = 20 * 1024 * 1024
    static func maximumOriginalBytes(for attachment: AttachmentContent) -> Int {
        attachment.type == .image || attachment.type == .video ? POCLimits.attachmentPlaintextBytes : maximumBytes
    }
    static func isEncrypted(_ attachment: AttachmentContent?) -> Bool {
        attachment?.storagePath?.hasPrefix("e2ee:") == true
    }
    static func validate(_ attachment: AttachmentContent, resolver: (any EncryptedMediaResolving)?) throws {
        try Task.checkCancellation()
        if isEncrypted(attachment) {
            guard let resolver else { throw EncryptedMediaError.unavailable }
            try resolver.validateActive()
        }
    }
    static func data(_ attachment: AttachmentContent, resolver: (any EncryptedMediaResolving)?,
                     legacy: () async throws -> Data) async throws -> Data {
        try validate(attachment, resolver: resolver)
        let bytes: Data
        if isEncrypted(attachment) {
            guard let resolver else { throw EncryptedMediaError.unavailable }
            bytes = try await resolver.decryptData(attachment)
            guard bytes.count <= maximumOriginalBytes(for: attachment) else { throw EncryptedMediaError.tooLarge }
        } else { bytes = try await legacy() }
        try validate(attachment, resolver: resolver)
        return bytes
    }
    /// A missing chat copy may use the larger viewer copy. Optional legacy32KiB
    /// previews remain available to old clients, never a modern display's final image.
    static func photoDisplayData(_ attachment: AttachmentContent, rendition: PhotoRendition,
                                 resolver: (any EncryptedMediaResolving)?, legacy: () async throws -> Data) async throws -> Data {
        try validate(attachment, resolver: resolver)
        if isEncrypted(attachment), let resolver {
            if let cached = try await resolver.cachedPhotoDisplayData(attachment, rendition: rendition) {
                try validate(attachment, resolver: resolver)
                return cached
            }
            let preferences: [PhotoRendition] = rendition == .chat ? [.chat, .viewer] : [.viewer]
            for candidate in preferences {
                do {
                    if let bytes = try await resolver.photoRenditionData(attachment, rendition: candidate),
                       EncryptedPhotoRenditionImage.isDecodable(bytes, rendition: candidate) {
                        try validate(attachment, resolver: resolver)
                        return bytes
                    }
                } catch {
                    try validate(attachment, resolver: resolver)
                }
            }
        }
        return try await data(attachment, resolver: resolver, legacy: legacy)
    }
    static func photoPreviewData(_ attachment: AttachmentContent, resolver: (any EncryptedMediaResolving)?,
                                 legacy: () async throws -> Data) async throws -> Data {
        try await photoDisplayData(attachment, rendition: .chat, resolver: resolver, legacy: legacy)
    }
    static func url(_ attachment: AttachmentContent, resolver: (any EncryptedMediaResolving)?,
                    legacy: () async throws -> URL) async throws -> URL {
        try validate(attachment, resolver: resolver)
        let url: URL
        if isEncrypted(attachment) {
            guard let resolver else { throw EncryptedMediaError.unavailable }
            url = try await resolver.temporaryURL(attachment)
            guard url.isFileURL else { throw EncryptedMediaError.unavailable }
        } else { url = try await legacy() }
        try validate(attachment, resolver: resolver)
        return url
    }
    /// Owned protected media URLs cannot be fetched through URLSession. Bound the read itself.
    static func localData(_ url: URL, maximumBytes: Int = EncryptedMediaLoading.maximumBytes) throws -> Data {
        guard maximumBytes > 0, maximumBytes <= POCLimits.attachmentPlaintextBytes else { throw EncryptedMediaError.tooLarge }
        try Task.checkCancellation()
        guard url.isFileURL else { throw EncryptedMediaError.unavailable }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw EncryptedMediaError.tooLarge }
        try Task.checkCancellation()
        return data
    }
}

/// Also reacts to invalidation of the same resolver instance, before an environment update.
private struct EncryptedMediaLifetime: ViewModifier {
    let resolver: EncryptedAttachmentResolver?
    let clear: () -> Void
    @State private var observation: ServiceObservation?
    func body(content: Content) -> some View {
        content
            .task(id: resolver.map(ObjectIdentifier.init)) {
                observation?.cancel()
                guard let resolver else { return }
                observation = resolver.observeInvalidation(clear)
                do { try resolver.validateActive() } catch { clear() }
            }
            .onChange(of: resolver.map(ObjectIdentifier.init)) { _, _ in clear() }
            .onDisappear { observation?.cancel(); observation = nil }
    }
}
extension View {
    func encryptedMediaLifetime(_ resolver: EncryptedAttachmentResolver?, clear: @escaping () -> Void) -> some View {
        modifier(EncryptedMediaLifetime(resolver: resolver, clear: clear))
    }
}

/// A preview acquires this synchronously before presentation, while its source window still owns metadata.
@MainActor @Observable
final class EncryptedMediaPresentationLease {
    private var lease: ServiceObservation?
    func acquire(_ attachments: [AttachmentContent], resolver: EncryptedAttachmentResolver?) throws {
        let encrypted = attachments.filter { EncryptedMediaLoading.isEncrypted($0) }
        guard !encrypted.isEmpty else { release(); return }
        guard let resolver else { throw EncryptedMediaError.unavailable }
        let next = try resolver.pinAttachments(encrypted)
        release(); lease = next
    }
    func release() { lease?.cancel(); lease = nil }
}
