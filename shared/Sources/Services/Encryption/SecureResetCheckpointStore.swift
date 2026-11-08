import CryptoKit
import Darwin
import Foundation

/// No key or invite secret is stored here. A checkpoint is not proof of remote deletion.
struct SecureResetCheckpoint: Codable, Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    enum Phase: String, Codable, Sendable { case requestingDeletion, localCleanup }
    let version: Int
    let accountID: String
    let conversationID: String
    let phase: Phase
    var description: String { "SecureResetCheckpoint(redacted)" }
    var customMirror: Mirror { Mirror(self, children: [:]) }
    static func == (left: Self, right: Self) -> Bool {
        left.version == right.version && left.phase == right.phase
            && Data(left.accountID.utf8) == Data(right.accountID.utf8)
            && Data(left.conversationID.utf8) == Data(right.conversationID.utf8)
    }
    init(accountID: String, conversationID: String, phase: Phase) throws {
        guard !accountID.isEmpty, accountID.utf8.count <= 256,
              !conversationID.isEmpty, conversationID.utf8.count <= 256, !conversationID.contains("/") else { throw SecureResetError.invalidCheckpoint }
        self.version = 1; self.accountID = accountID; self.conversationID = conversationID; self.phase = phase
    }
}

enum SecureResetError: Error { case invalidCheckpoint, pendingReset, storageUnavailable, assignmentChanged }

/// Serialized account-scoped file operations, atomic replacement and file+directory fsync.
/// Refuses symlinks and nonregular files; callers never store cryptographic material here.
struct SecureAccountMetadataFile {
    let directory: URL
    let url: URL
    init(account: String, directory: URL) throws {
        guard !account.isEmpty, account.utf8.count <= 256, directory.isFileURL, directory.path.hasPrefix("/") else { throw SecureResetError.invalidCheckpoint }
        self.directory = directory
        url = directory.appendingPathComponent(SHA256.hash(data: Data(account.utf8)).map { String(format: "%02x", $0) }.joined() + ".json")
    }
    func locked<T>(_ body: () throws -> T) throws -> T {
        // Persist every newly created directory entry as well as later file renames.
        var missing: [URL] = [], ancestor = directory
        var status = stat()
        while lstat(ancestor.path, &status) != 0 {
            guard errno == ENOENT, ancestor.path != "/" else { throw SecureResetError.storageUnavailable }
            missing.append(ancestor); ancestor = ancestor.deletingLastPathComponent()
        }
        try SharedProtectedFiles.prepareDirectory(directory)
        for created in missing.reversed() { try syncDirectory(created.deletingLastPathComponent()) }
        let lock = Darwin.open(url.path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard lock >= 0 else { throw SecureResetError.storageUnavailable }
        defer { _ = Darwin.close(lock) }
        guard fstat(lock, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              flock(lock, LOCK_EX) == 0 else { throw SecureResetError.storageUnavailable }
        defer { _ = flock(lock, LOCK_UN) }
        return try body()
    }
    func read(maximum: Int) throws -> Data? {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        if fd < 0 { if errno == ENOENT { return nil }; throw SecureResetError.storageUnavailable }
        defer { _ = Darwin.close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_size > 0, status.st_size <= maximum else { throw SecureResetError.invalidCheckpoint }
        var bytes = Data(count: Int(status.st_size)); let count = bytes.count
        guard bytes.withUnsafeMutableBytes({ Darwin.read(fd, $0.baseAddress, count) }) == count else { throw SecureResetError.storageUnavailable }
        return bytes
    }
    func replace(_ bytes: Data) throws {
        // A directory/symlink occupying the target must fail rather than be silently replaced.
        var status = stat()
        if lstat(url.path, &status) == 0, status.st_mode & S_IFMT != S_IFREG { throw SecureResetError.storageUnavailable }
        let temporary = directory.appendingPathComponent(".write-" + UUID().uuidString.lowercased())
        let fd = Darwin.open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw SecureResetError.storageUnavailable }
        defer { _ = Darwin.close(fd); _ = unlink(temporary.path) }
        try SharedProtectedFiles.protectFile(temporary)
        guard bytes.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, bytes.count) }) == bytes.count,
              fsync(fd) == 0, rename(temporary.path, url.path) == 0 else { throw SecureResetError.storageUnavailable }
        try syncDirectory()
    }
    func remove() throws {
        var status = stat()
        if lstat(url.path, &status) != 0 { if errno == ENOENT { return }; throw SecureResetError.storageUnavailable }
        guard status.st_mode & S_IFMT == S_IFREG, unlink(url.path) == 0 else { throw SecureResetError.storageUnavailable }
        try syncDirectory()
    }
    private func syncDirectory() throws { try syncDirectory(directory) }
    private func syncDirectory(_ directory: URL) throws {
        let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw SecureResetError.storageUnavailable }
        defer { _ = Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw SecureResetError.storageUnavailable }
    }
}

struct SecureResetCheckpointStore {
    let accountID: String
    let file: SecureAccountMetadataFile
    init(accountID: String, directory: URL) throws {
        self.accountID = accountID; file = try SecureAccountMetadataFile(account: accountID, directory: directory)
    }
    func load() throws -> SecureResetCheckpoint? { try file.locked { try read() } }
    func save(conversationID: String, phase: SecureResetCheckpoint.Phase) throws -> SecureResetCheckpoint {
        try file.locked {
            let checkpoint = try SecureResetCheckpoint(accountID: accountID, conversationID: conversationID, phase: phase)
            if let old = try read() {
                guard Data(old.conversationID.utf8) == Data(conversationID.utf8),
                      old.phase != .localCleanup || phase == .localCleanup else { throw SecureResetError.pendingReset }
            }
            try file.replace(try encode(checkpoint)); return checkpoint
        }
    }
    func remove(conversationID: String) throws {
        try file.locked {
            guard let checkpoint = try read() else { return }
            guard Data(checkpoint.conversationID.utf8) == Data(conversationID.utf8), checkpoint.phase == .localCleanup else { throw SecureResetError.pendingReset }
            try file.remove()
        }
    }
    private func read() throws -> SecureResetCheckpoint? {
        guard let bytes = try file.read(maximum: 2048) else { return nil }
        let checkpoint = try JSONDecoder().decode(SecureResetCheckpoint.self, from: bytes)
        guard checkpoint.version == 1, Data(checkpoint.accountID.utf8) == Data(accountID.utf8),
              try encode(checkpoint) == bytes else { throw SecureResetError.invalidCheckpoint }
        _ = try SecureResetCheckpoint(accountID: checkpoint.accountID, conversationID: checkpoint.conversationID, phase: checkpoint.phase)
        return checkpoint
    }
    private func encode(_ checkpoint: SecureResetCheckpoint) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(checkpoint)
    }
}
