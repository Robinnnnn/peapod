import Combine
import Foundation
import Photos
import UniformTypeIdentifiers

/// Selection remains local until Add; removing and reselecting puts a photo at the end.
struct RecentPhotoSelection {
    let maximumCount: Int
    private(set) var identifiers: [String] = []

    init(maximumCount: Int) { self.maximumCount = max(0, maximumCount) }

    mutating func toggle(_ identifier: String) {
        if let index = identifiers.firstIndex(of: identifier) {
            identifiers.remove(at: index)
        } else if identifiers.count < maximumCount {
            identifiers.append(identifier)
        }
    }

    mutating func retainAvailable(_ available: Set<String>) {
        identifiers.removeAll { !available.contains($0) }
    }
}

@MainActor final class RecentPhotoLibrary: ObservableObject {
    @Published private(set) var assets: [PHAsset] = []
    @Published private(set) var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)

    func open() async {
        if authorization == .notDetermined {
            authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard !Task.isCancelled else { return }
        refresh()
    }

    func refresh() {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard authorization == .authorized || authorization == .limited else {
            assets = []
            return
        }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 40
        options.includeHiddenAssets = false
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var recent: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in recent.append(asset) }
        assets = recent
    }

    /// Only explicit Add initiates original access. Photos streams bytes to disk; no image decoding
    /// or re-encoding occurs. Prefer the edited full-size representation when Photos provides it.
    nonisolated static func importPhoto(identifier: String) async throws -> ImportedMediaFile {
        try Task.checkCancellation()
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = result.firstObject, asset.mediaType == .image, !asset.isHidden else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .fullSizePhoto })
                ?? resources.first(where: { $0.type == .photo }),
              let type = UTType(resource.uniformTypeIdentifier), type.conforms(to: .image),
              let suffix = type.preferredFilenameExtension else {
            throw CocoaError(.fileReadUnknown)
        }
        let stream = try RecentPhotoResourceStream(filename: resource.originalFilename, suffix: suffix,
            maximumBytes: PendingShareAttachmentPolicy.maximumSendingPhotoBytes)
        defer { stream.cleanUp() }
        let manager = PHAssetResourceManager.default()
        let url = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard stream.begin(continuation) else { return }
                let options = PHAssetResourceRequestOptions()
                options.isNetworkAccessAllowed = true
                let request = manager.requestData(for: resource, options: options,
                    dataReceivedHandler: { stream.receive($0) },
                    completionHandler: { stream.finish(error: $0) })
                stream.registerCancellation { manager.cancelDataRequest(request) }
            }
        } onCancel: {
            stream.cancel()
        }
        try Task.checkCancellation()
        return try ImportedMediaFile.copy(from: url,
            maximumBytes: PendingShareAttachmentPolicy.maximumSendingPhotoBytes,
            temporaryRoot: FileManager.default.temporaryDirectory.appendingPathComponent("mines-picked-photos", isDirectory: true),
            kind: .image)
    }
}

/// The callback seam owns a protected file, caps every chunk before writing, and settles once.
/// Photos callbacks and task cancellation may race; late chunks/completions cannot reopen the file.
final class RecentPhotoResourceStream: @unchecked Sendable {
    let directory: URL
    let url: URL
    private let lock = NSLock()
    private var output: FileHandle?
    private let maximumBytes: Int64
    private var byteCount: Int64 = 0
    private var continuation: CheckedContinuation<URL, any Error>?
    private var outcome: Result<URL, any Error>?
    private var cancelRequest: (() -> Void)?

    init(filename: String, suffix: String, maximumBytes: Int64,
         temporaryRoot: URL = FileManager.default.temporaryDirectory.appendingPathComponent("mines-recent-photos", isDirectory: true)) throws {
        self.maximumBytes = maximumBytes
        guard maximumBytes > 0, maximumBytes <= ImportedMediaFile.maximumByteSize else {
            throw CocoaError(.fileWriteUnknown)
        }
        directory = temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        // Normalize only an absent/unusable extension; resource bytes are never transformed.
        let basename = URL(fileURLWithPath: filename).lastPathComponent
        let safeName = basename.isEmpty || basename == "." || basename == ".." ? "photo.\(suffix)" : basename
        let candidate = directory.appendingPathComponent(safeName)
        let existingType = UTType(filenameExtension: candidate.pathExtension)
        let requestedType = UTType(filenameExtension: suffix)
        url = existingType != nil && existingType == requestedType
            ? candidate : candidate.deletingPathExtension().appendingPathExtension(suffix)
        do {
            try SharedProtectedFiles.prepareDirectory(temporaryRoot)
            try SharedProtectedFiles.prepareDirectory(directory)
            guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                                attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try SharedProtectedFiles.protectFile(url)
            output = try FileHandle(forWritingTo: url)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func begin(_ continuation: CheckedContinuation<URL, any Error>) -> Bool {
        lock.lock()
        if let outcome {
            lock.unlock()
            continuation.resume(with: outcome)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func registerCancellation(_ action: @escaping () -> Void) {
        lock.lock()
        if outcome != nil {
            lock.unlock()
            action()
        } else {
            cancelRequest = action
            lock.unlock()
        }
    }

    func receive(_ bytes: Data) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        do {
            // Validate without permitting overflow, including an arbitrarily large provider chunk.
            guard Int64(bytes.count) <= maximumBytes - byteCount else {
                try PendingShareAttachmentPolicy.validate(byteSize: maximumBytes + 1, maximumBytes: maximumBytes)
                throw CocoaError(.fileWriteUnknown)
            }
            try output?.write(contentsOf: bytes)
            byteCount += Int64(bytes.count)
            lock.unlock()
        } catch {
            settleLocked(.failure(error), cancel: true)
        }
    }

    func finish(error: (any Error)?) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        if let error { settleLocked(.failure(error), cancel: false) }
        else if byteCount == 0 { settleLocked(.failure(CocoaError(.fileReadCorruptFile)), cancel: false) }
        else { settleLocked(.success(url), cancel: false) }
    }

    func cancel() {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        settleLocked(.failure(CancellationError()), cancel: true)
    }

    /// Caller holds lock; all external callbacks run after unlocking.
    private func settleLocked(_ result: Result<URL, any Error>, cancel: Bool) {
        var result = result
        do { try output?.close() } catch { result = .failure(error) }
        output = nil
        outcome = result
        let continuation = continuation
        self.continuation = nil
        let cancellation = cancel ? cancelRequest : nil
        cancelRequest = nil
        if case .failure = result { try? FileManager.default.removeItem(at: directory) }
        lock.unlock()
        cancellation?()
        continuation?.resume(with: result)
    }

    func cleanUp() {
        cancel()
        try? FileManager.default.removeItem(at: directory)
    }

    deinit { cleanUp() }
}
