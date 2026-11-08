import Foundation
import Photos

@MainActor
struct PhotoLibrarySaver {
    enum Result: Equatable {
        case saved
        case accessDenied
    }

    struct BatchResult {
        var savedIndices: [Int] = []
        var failedIndices: [Int] = []
        var accessDenied = false
        var cancelled = false
    }

    var authorizationStatus: () -> PHAuthorizationStatus = {
        PHPhotoLibrary.authorizationStatus(for: .addOnly)
    }
    var requestAuthorization: () async -> PHAuthorizationStatus = {
        await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    }
    var writePhoto: (Data) async throws -> Void = { data in
        try await writeToLibrary(data)
    }

    func save(
        prepareData: () async throws -> Data
    ) async throws -> Result {
        guard await hasPhotoAccess() else { return .accessDenied }

        let data = try await prepareData()
        try Task.checkCancellation()
        try await writePhoto(data)
        return .saved
    }

    /// Authorize once, then give every available photo an independent save attempt.
    /// Returning completed indices also lets a retry skip photos already saved.
    func saveAll<Photo>(
        _ photos: [Photo],
        prepareData: @MainActor (Photo) async throws -> Data
    ) async -> BatchResult {
        guard !photos.isEmpty else { return BatchResult() }
        guard await hasPhotoAccess() else { return BatchResult(accessDenied: true) }
        var result = BatchResult()
        for (index, photo) in photos.enumerated() {
            do {
                try Task.checkCancellation()
                let data = try await prepareData(photo)
                try Task.checkCancellation()
                try await writePhoto(data)
                result.savedIndices.append(index)
            } catch {
                if Task.isCancelled || error is CancellationError {
                    result.cancelled = true
                    break
                }
                result.failedIndices.append(index)
            }
        }
        return result
    }

    private func hasPhotoAccess() async -> Bool {
        var status = authorizationStatus()
        if PhotoSaveAuthorizationPolicy.decision(for: status) == .request {
            status = await requestAuthorization()
        }
        return PhotoSaveAuthorizationPolicy.decision(for: status) == .save
    }

    nonisolated private static func writeToLibrary(_ data: Data) async throws {
        // Photos runs this callback on its own serial queue. A callback created
        // in a MainActor view inherits that isolation and traps in Swift 6.
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: nil)
        }
    }
}

struct PhotoSaveAuthorizationPolicy {
    enum Decision: Equatable {
        case request
        case save
        case showSettings
    }

    static func decision(for status: PHAuthorizationStatus) -> Decision {
        switch status {
        case .notDetermined:
            .request
        case .authorized, .limited:
            .save
        case .denied, .restricted:
            .showSettings
        @unknown default:
            .showSettings
        }
    }
}
