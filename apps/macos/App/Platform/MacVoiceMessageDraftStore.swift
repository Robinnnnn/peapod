import CryptoKit
import Foundation

/// Ready recordings are local composer drafts, separate from the existing delivery outbox.
/// Scope directories and self-describing filenames survive process termination without a
/// metadata-file/audio-file transaction. Neither account nor conversation IDs become paths.
struct MacVoiceMessageDraftStore {
    struct Scope: Hashable {
        let accountID: String
        let conversationID: String
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.accountID.utf8.elementsEqual(rhs.accountID.utf8)
                && lhs.conversationID.utf8.elementsEqual(rhs.conversationID.utf8)
        }
        func hash(into hasher: inout Hasher) {
            hasher.combine(Data(accountID.utf8)); hasher.combine(Data(conversationID.utf8))
        }
    }

    private let rootDirectory: URL
    private let fileManager: FileManager

    init(rootDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.rootDirectory = rootDirectory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mines/MacVoiceMessageDrafts", isDirectory: true)
    }

    func recordingURL(id: UUID, createdAt: Date, in scope: Scope) throws -> URL {
        let directory = directory(in: scope).appendingPathComponent("Recording", isDirectory: true)
        try createDirectory(directory)
        return directory.appendingPathComponent(filename(id: id, duration: 0, createdAt: createdAt))
    }

    func persist(_ draft: VoiceMessageDraft, in scope: Scope) throws -> VoiceMessageDraft {
        guard draft.duration.isFinite, draft.duration >= VoiceMessagePolicy.minimumDuration else {
            throw VoiceMessageError.recordingTooShort
        }
        let byteSize = Int64(try draft.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        guard byteSize > 0 else { throw VoiceMessageError.emptyRecording }
        let directory = directory(in: scope).appendingPathComponent("Finalized", isDirectory: true)
        try createDirectory(directory)
        let destination = directory.appendingPathComponent(filename(id: draft.id, duration: draft.duration, createdAt: draft.createdAt))
        if destination.standardizedFileURL != draft.fileURL.standardizedFileURL {
            // Never delete the only source when finalization fails.
            try fileManager.moveItem(at: draft.fileURL, to: destination)
        }
        return VoiceMessageDraft(id: draft.id, fileURL: destination, duration: draft.duration, byteSize: byteSize, createdAt: draft.createdAt)
    }

    func load(in scope: Scope, unfinishedDuration: (URL) throws -> TimeInterval) throws -> [VoiceMessageDraft] {
        var drafts: [VoiceMessageDraft] = []
        for folder in ["Finalized", "Recording"] {
            let directory = directory(in: scope).appendingPathComponent(folder, isDirectory: true)
            guard fileManager.fileExists(atPath: directory.path) else { continue }
            for url in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles]) {
                let parts = url.deletingPathExtension().lastPathComponent.components(separatedBy: "--")
                guard url.pathExtension == VoiceMessageDraft.preferredFilenameExtension, parts.count == 3,
                      let id = UUID(uuidString: parts[0]), let milliseconds = Int(parts[1]), milliseconds >= 0,
                      let createdAt = Int64(parts[2]),
                      let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                      values.isRegularFile == true, let size = values.fileSize, size > 0 else { continue }
                // A failure during finalization can leave valid audio in Recording. Decode
                // its duration rather than silently losing it on the next launch.
                let duration: TimeInterval
                if folder == "Recording" {
                    guard let decoded = try? unfinishedDuration(url), decoded.isFinite else { continue }
                    duration = decoded
                } else { duration = TimeInterval(milliseconds) / 1_000 }
                guard duration >= VoiceMessagePolicy.minimumDuration, duration <= VoiceMessagePolicy.maximumDuration else { continue }
                drafts.append(VoiceMessageDraft(id: id, fileURL: url, duration: duration, byteSize: Int64(size),
                    createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt) / 1_000)))
            }
        }
        return drafts.sorted { $0.createdAt < $1.createdAt }
    }

    func remove(_ draft: VoiceMessageDraft, in scope: Scope) {
        // An arbitrary URL supplied to a send callback must never become a delete target.
        let scopePath = directory(in: scope).standardizedFileURL.path + "/"
        guard draft.fileURL.standardizedFileURL.path.hasPrefix(scopePath) else { return }
        try? fileManager.removeItem(at: draft.fileURL)
    }

    func removeAccount(_ accountID: String) throws {
        let directory = rootDirectory.appendingPathComponent(digest(accountID), isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }

    private func directory(in scope: Scope) -> URL {
        rootDirectory.appendingPathComponent(digest(scope.accountID), isDirectory: true)
            .appendingPathComponent(digest(scope.conversationID), isDirectory: true)
    }
    private func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func createDirectory(_ directory: URL) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    private func filename(id: UUID, duration: TimeInterval, createdAt: Date) -> String {
        [id.uuidString, String(Int((duration * 1_000).rounded())), String(Int64((createdAt.timeIntervalSince1970 * 1_000).rounded()))]
            .joined(separator: "--") + "." + VoiceMessageDraft.preferredFilenameExtension
    }
}
