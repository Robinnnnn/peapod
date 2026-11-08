import AppKit
@preconcurrency import FirebaseStorage

enum MacPhotoOriginalSaver {
    private static let queue = DispatchQueue(label: "mines.mac-photo-save", qos: .utility)

    @MainActor
    static func chooseDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Save Photos"
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func fileName(_ original: String, id: UUID) -> String {
        let safeName = URL(fileURLWithPath: original).lastPathComponent
        return "\(id.uuidString)-\(safeName.isEmpty ? "Photo" : safeName)"
    }

    @MainActor
    static func withOriginalURL<Result>(_ attachment: AttachmentContent, resolver: EncryptedAttachmentResolver?,
                                        use: @MainActor (URL) async throws -> Result) async throws -> Result {
        guard let path = attachment.storagePath else { throw EncryptedMediaError.unavailable }
        if EncryptedMediaLoading.isEncrypted(attachment) {
            let url = try await EncryptedMediaLoading.url(attachment, resolver: resolver) { throw EncryptedMediaError.unavailable }
            let result = try await use(url)
            try EncryptedMediaLoading.validate(attachment, resolver: resolver)
            return result
        }
        let remote = try await Storage.storage().reference(withPath: path).downloadURL()
        let (url, response) = try await URLSession.shared.download(from: remote)
        defer { try? FileManager.default.removeItem(at: url) }
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= EncryptedMediaLoading.maximumOriginalBytes(for: attachment) else {
            throw EncryptedMediaError.tooLarge
        }
        try EncryptedMediaLoading.validate(attachment, resolver: resolver)
        return try await use(url)
    }

    @MainActor
    static func saveOriginal(_ attachment: AttachmentContent, resolver: EncryptedAttachmentResolver?, to destination: URL) async throws {
        try await withOriginalURL(attachment, resolver: resolver) { source in
            try await copyOriginal(from: source, to: destination) {
                try EncryptedMediaLoading.validate(attachment, resolver: resolver)
            }
        }
    }

    @MainActor
    static func copyOriginal(from source: URL, to url: URL,
                             validate: @MainActor () throws -> Void) async throws {
        try await export(to: url, validate: validate) { staged in
            try FileManager.default.copyItem(at: source, to: staged)
        }
    }

    @MainActor
    static func write(_ data: Data, to url: URL,
                      validate: @MainActor () throws -> Void = {}) async throws {
        try await export(to: url, validate: validate) { staged in
            try data.write(to: staged, options: .atomic)
        }
    }

    /// Prepare the large write off-main, then recheck account/cancellation immediately
    /// before the short destination rename. Invalidation during IO cannot export stale data.
    @MainActor
    private static func export(to url: URL, validate: @MainActor () throws -> Void,
                               prepare: @escaping @Sendable (URL) throws -> Void) async throws {
        try Task.checkCancellation()
        let staged: URL = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let staged = url.deletingLastPathComponent().appendingPathComponent(".mines-save-\(UUID().uuidString)")
                do { try prepare(staged); continuation.resume(returning: staged) }
                catch { try? FileManager.default.removeItem(at: staged); continuation.resume(throwing: error) }
            }
        }
        defer { try? FileManager.default.removeItem(at: staged) }
        try Task.checkCancellation()
        try validate()
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            _ = try manager.replaceItemAt(url, withItemAt: staged)
        } else { try manager.moveItem(at: staged, to: url) }
    }
}
