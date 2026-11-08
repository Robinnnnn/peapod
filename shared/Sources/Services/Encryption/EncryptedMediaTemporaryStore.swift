import Darwin
import Foundation

/// App-owned media scratch with an advisory lease per session. Startup removes
/// abandoned sessions only after acquiring their lease; another live process is preserved.
@MainActor
final class EncryptedMediaTemporaryStore {
    // Permit one original video at the attachment limit while keeping each session bounded.
    static let maximumFileBytes = 200 * 1024 * 1024
    static let maximumSessionBytes = 256 * 1024 * 1024
    private let directory: URL
    private let fileByteLimit: Int
    private let lease: Int32
    private var files: [(URL, Int)] = []
    init(root: URL, allowsEnvelopeOverhead: Bool = false) throws {
        fileByteLimit = Self.maximumFileBytes + (allowsEnvelopeOverhead ? 4096 : 0)
        let base = root.appendingPathComponent("MinesEncryptedMedia", isDirectory: true)
        try Self.makePrivateDirectory(base)
        for entry in try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            guard UUID(uuidString: entry.lastPathComponent)?.uuidString == entry.lastPathComponent,
                  try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true,
                  try entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { continue }
            let path = entry.appendingPathComponent(".lease").path
            let fd = Darwin.open(path, O_RDWR | O_NOFOLLOW)
            guard fd >= 0 else { continue }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                try? FileManager.default.removeItem(at: entry)
            }
            Darwin.close(fd)
        }
        directory = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try Self.makePrivateDirectory(directory)
        let path = directory.appendingPathComponent(".lease").path
        let fd = Darwin.open(path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd); throw CocoaError(.fileLocking)
        }
        // If cleanup raced initial creation, the directory no longer exists. Fail closed.
        guard FileManager.default.fileExists(atPath: path) else {
            Darwin.close(fd); throw CocoaError(.fileNoSuchFile)
        }
        lease = fd
    }
    deinit {
        try? FileManager.default.removeItem(at: directory)
        Darwin.close(lease)
    }
    func write(_ data: Data, suffix: String) throws -> URL {
        guard data.count <= fileByteLimit,
              !suffix.isEmpty, suffix.utf8.count <= 16,
              suffix.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        while files.reduce(0, { $0 + $1.1 }) + data.count > Self.maximumSessionBytes, !files.isEmpty {
            try? FileManager.default.removeItem(at: files.removeFirst().0)
        }
        let target = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(suffix)
        do {
#if os(iOS)
            try data.write(to: target, options: [.atomic, .completeFileProtection])
#else
            try data.write(to: target, options: [.atomic])
#endif
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        } catch { try? FileManager.default.removeItem(at: target); throw error }
        files.append((target, data.count))
        return target
    }
    func clear() {
        for (url, _) in files { try? FileManager.default.removeItem(at: url) }
        files.removeAll()
    }
    private static func makePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let info = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard info.isDirectory == true, info.isSymbolicLink != true else { throw CocoaError(.fileWriteNoPermission) }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        var mutable = url, values = URLResourceValues(); values.isExcludedFromBackup = true
        try mutable.setResourceValues(values)
    }
}
