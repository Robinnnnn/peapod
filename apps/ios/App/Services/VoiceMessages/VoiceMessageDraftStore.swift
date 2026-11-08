import Foundation

struct VoiceMessageDraftStore {
    private static let filenameSeparator = "--"

    private let fileManager: FileManager
    private let rootDirectory: URL

    init(
        fileManager: FileManager = .default,
        rootDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.rootDirectory = rootDirectory
            ?? fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0].appendingPathComponent(
                "Mines/VoiceMessageDrafts",
                isDirectory: true
            )
    }

    var recordingsDirectory: URL {
        rootDirectory.appendingPathComponent("Recording", isDirectory: true)
    }

    private var finalizedDirectory: URL {
        rootDirectory.appendingPathComponent("Finalized", isDirectory: true)
    }

    /// Moves a completed recording to a filename that contains all metadata
    /// needed to recover it after process termination. Recovery does not
    /// depend on process memory or a separately written metadata file.
    func persist(_ draft: VoiceMessageDraft) throws -> VoiceMessageDraft {
        guard fileManager.fileExists(atPath: draft.fileURL.path) else {
            throw VoiceMessageError.missingRecording
        }
        guard draft.byteSize > 0 else {
            throw VoiceMessageError.emptyRecording
        }

        try createDirectory(finalizedDirectory)
        let destination = finalizedDirectory.appendingPathComponent(
            persistedFilename(for: draft),
            isDirectory: false
        )

        if draft.fileURL.standardizedFileURL != destination.standardizedFileURL {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: draft.fileURL)
            } else {
                try fileManager.moveItem(at: draft.fileURL, to: destination)
            }
        }

        let byteSize = Int64(
            try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        )
        guard byteSize > 0 else {
            try? fileManager.removeItem(at: destination)
            throw VoiceMessageError.emptyRecording
        }

        return VoiceMessageDraft(
            id: draft.id,
            fileURL: destination,
            duration: draft.duration,
            byteSize: byteSize,
            createdAt: draft.createdAt
        )
    }

    func load() throws -> [VoiceMessageDraft] {
        guard fileManager.fileExists(atPath: finalizedDirectory.path) else {
            return []
        }

        return try fileManager.contentsOfDirectory(
            at: finalizedDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        .compactMap(draft(at:))
        .sorted { $0.createdAt < $1.createdAt }
    }

    func remove(_ draft: VoiceMessageDraft) {
        try? fileManager.removeItem(at: draft.fileURL)
        removePersistedFiles(withID: draft.id)
    }

    private func createDirectory(_ directory: URL) throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [
                .protectionKey:
                    FileProtectionType.completeUntilFirstUserAuthentication,
            ]
        )
    }

    private func persistedFilename(for draft: VoiceMessageDraft) -> String {
        let durationMilliseconds = draft.durationMilliseconds
        let createdAtMilliseconds = Int64(
            (draft.createdAt.timeIntervalSince1970 * 1_000).rounded()
        )
        return [
            draft.id.uuidString,
            String(durationMilliseconds),
            String(createdAtMilliseconds),
        ].joined(separator: Self.filenameSeparator)
            + ".\(VoiceMessageDraft.preferredFilenameExtension)"
    }

    private func draft(at url: URL) -> VoiceMessageDraft? {
        guard
            url.pathExtension == VoiceMessageDraft.preferredFilenameExtension
        else {
            return nil
        }

        let components = url.deletingPathExtension().lastPathComponent
            .components(separatedBy: Self.filenameSeparator)
        guard
            components.count == 3,
            let id = UUID(uuidString: components[0]),
            let durationMilliseconds = Int(components[1]),
            durationMilliseconds >= 0,
            let createdAtMilliseconds = Int64(components[2]),
            let fileSize = try? url.resourceValues(
                forKeys: [.fileSizeKey]
            ).fileSize,
            fileSize > 0
        else {
            return nil
        }

        return VoiceMessageDraft(
            id: id,
            fileURL: url,
            duration: TimeInterval(durationMilliseconds) / 1_000,
            byteSize: Int64(fileSize),
            createdAt: Date(
                timeIntervalSince1970:
                    TimeInterval(createdAtMilliseconds) / 1_000
            )
        )
    }

    private func removePersistedFiles(withID id: UUID) {
        guard
            let urls = try? fileManager.contentsOfDirectory(
                at: finalizedDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else {
            return
        }

        let prefix = id.uuidString + Self.filenameSeparator
        for url in urls
        where url.deletingPathExtension().lastPathComponent.hasPrefix(prefix) {
            try? fileManager.removeItem(at: url)
        }
    }
}

struct VoiceMessageDraftRecovery {
    private let loadDrafts: () throws -> [VoiceMessageDraft]
    private let stageDraft: (VoiceMessageDraft) throws -> StagedVoiceMessage

    init(
        draftStore: VoiceMessageDraftStore = VoiceMessageDraftStore(),
        stager: VoiceMessageStager? = nil
    ) {
        let resolvedStager = stager
            ?? VoiceMessageStager(draftStore: draftStore)
        loadDrafts = draftStore.load
        stageDraft = resolvedStager.stageAndEnqueue
    }

    @discardableResult
    func recoverAndEnqueue() throws -> [StagedVoiceMessage] {
        try loadDrafts().map(stageDraft)
    }
}
