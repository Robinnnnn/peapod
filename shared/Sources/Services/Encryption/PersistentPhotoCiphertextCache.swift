import CryptoKit
import Darwin
import Foundation
import MinesE2EE

/// Rebuildable photo envelopes only. Neither the filename nor the file header
/// contains account IDs, attachment descriptors, keys, URLs or plaintext.
/// A hit is not trusted content: the resolver must authenticate it again.
actor PersistentPhotoCiphertextCache {
    enum Role: String, Sendable { case original, preview, chat, viewer }

    struct Key: Hashable, Sendable {
        let filename: String

        init(accountID: String, context: RecordContext, metadata: PrivateAttachment,
             blobID: String, role: Role) {
            var identity = Data("mines/photo-ciphertext-cache/v1".utf8)
            // Length framing preserves byte-exact protocol identities, including
            // Unicode forms and values that would collide under string joining.
            for field in [Data(accountID.utf8), Data(context.conversationID.utf8),
                          Data(context.recordID.utf8), Data(context.senderID.utf8),
                          Data(context.kind.rawValue.utf8), Data(String(context.keyEpoch).utf8),
                          Data(String(context.revision).utf8), Data(metadata.attachmentID.utf8),
                          metadata.key, Data(metadata.filename.utf8), Data(metadata.mediaType.utf8),
                          Data(String(metadata.originalByteCount).utf8),
                          Data((metadata.voiceDurationMilliseconds.map { String($0) } ?? "").utf8),
                          Data(blobID.utf8), Data(role.rawValue.utf8)] {
                var count = UInt64(field.count).bigEndian
                withUnsafeBytes(of: &count) { identity.append(contentsOf: $0) }
                identity.append(field)
            }
            filename = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined() + ".blob"
        }
    }

    private static let magic = Data("MPCACHE1".utf8)
    private static let headerBytes = magic.count + SHA256.byteCount
    private let directory: URL
    private let maximumBytes: Int
    private let maximumEntries: Int
    private let maximumEntryBytes: Int
    private var swept = false

    init(directory: URL, maximumBytes: Int = 512 * 1024 * 1024,
         maximumEntries: Int = 512, maximumEntryBytes: Int = POCLimits.attachmentEnvelopeBytes) {
        self.directory = directory
        self.maximumBytes = max(0, maximumBytes)
        self.maximumEntries = max(0, maximumEntries)
        self.maximumEntryBytes = min(max(0, maximumEntryBytes), POCLimits.attachmentEnvelopeBytes)
    }

    func read(_ key: Key, maximumBytes limit: Int) -> Data? {
        guard limit > 0, limit <= maximumEntryBytes else { return nil }
        return withDirectory { parent in
            let fd = openat(parent, key.filename, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else { return nil }
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? file.close() }
            var info = stat()
            guard fstat(fd, &info) == 0, Self.isOwnedRegular(info),
                  info.st_size > Self.headerBytes,
                  info.st_size <= min(limit, maximumEntryBytes) + Self.headerBytes else {
                unlinkat(parent, key.filename, 0)
                return nil
            }
            do {
                let header = try Self.readExactly(Self.headerBytes, from: file)
                let payload = try Self.readExactly(Int(info.st_size) - Self.headerBytes, from: file)
                guard try file.read(upToCount: 1)?.isEmpty != false,
                      header.prefix(Self.magic.count) == Self.magic,
                      Data(header.suffix(SHA256.byteCount)) == Data(SHA256.hash(data: payload)) else {
                    unlinkat(parent, key.filename, 0)
                    return nil
                }
                // The inode is still open, so touching it cannot follow a link.
                _ = futimes(fd, nil)
                return payload
            } catch {
                unlinkat(parent, key.filename, 0)
                return nil
            }
        }
    }

    func store(_ bytes: Data, for key: Key, maximumBytes limit: Int) {
        guard !bytes.isEmpty, limit > 0, limit <= maximumEntryBytes,
              bytes.count <= limit,
              bytes.count + Self.headerBytes <= maximumBytes,
              maximumEntries > 0 else { return }
        let _: Bool? = withDirectory { parent in
            // Replacing an optional cache entry need not retain a second complete
            // envelope. Its old copy is disposable if this write fails.
            unlinkat(parent, key.filename, 0)
            guard self.prune(parent, reserving: bytes.count + Self.headerBytes, adding: 1) else { return false }
            let name = ".tmp-" + UUID().uuidString
            let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
            guard fd >= 0 else { return false }
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? file.close() }
            defer { unlinkat(parent, name, 0) }
            do {
                try file.write(contentsOf: Self.magic)
                try file.write(contentsOf: Data(SHA256.hash(data: bytes)))
                try file.write(contentsOf: bytes)
                try file.synchronize()
                // Directory protection is inherited; set the file's explicit
                // backup/protection policy before its atomic publication.
                guard self.isCurrentDirectory(parent) else { return false }
                try SharedProtectedFiles.protectFile(self.directory.appendingPathComponent(name))
                guard self.isCurrentDirectory(parent),
                      renameat(parent, name, parent, key.filename) == 0 else { return false }
                return true
            } catch { return false }
        }
    }

    func remove(_ key: Key) {
        let _: Bool? = withDirectory { parent in
            unlinkat(parent, key.filename, 0) == 0
        }
    }

    /// All filesystem work runs on this actor, never on the main actor. A busy
    /// cross-process cache is a miss; no network call is made under its lock.
    private func withDirectory<T>(_ operation: (Int32) -> T?) -> T? {
        guard maximumBytes > Self.headerBytes, maximumEntries > 0 else { return nil }
        do { try SharedProtectedFiles.prepareDirectory(directory) } catch { return nil }
        let parent = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { return nil }
        defer { Darwin.close(parent) }
        var info = stat()
        guard fstat(parent, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), isCurrentDirectory(parent) else { return nil }
        let lock = openat(parent, ".lock", O_RDWR | O_CREAT | O_NOFOLLOW, mode_t(0o600))
        guard lock >= 0 else { return nil }
        defer { Darwin.close(lock) }
        guard fstat(lock, &info) == 0, Self.isOwnedRegular(info),
              flock(lock, LOCK_EX | LOCK_NB) == 0 else { return nil }
        defer { _ = flock(lock, LOCK_UN) }
        if !swept {
            guard prune(parent, reserving: 0, adding: 0) else { return nil }
            swept = true
        }
        return operation(parent)
    }

    private func isCurrentDirectory(_ parent: Int32) -> Bool {
        var opened = stat(), current = stat()
        return fstat(parent, &opened) == 0 && lstat(directory.path, &current) == 0
            && current.st_mode & S_IFMT == S_IFDIR && current.st_uid == getuid()
            && opened.st_dev == current.st_dev && opened.st_ino == current.st_ino
    }

    private struct Entry {
        let name: String
        let size: Int
        let seconds: Int
        let nanoseconds: Int
    }

    private func prune(_ parent: Int32, reserving bytes: Int, adding count: Int) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
              isCurrentDirectory(parent) else { return false }
        var entries: [Entry] = []
        for name in names {
            var info = stat()
            guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  Self.isOwnedRegular(info) else { continue }
            if name.hasPrefix(".tmp-"), UUID(uuidString: String(name.dropFirst(5))) != nil {
                // No other writer can own a temporary file while we hold the lock.
                unlinkat(parent, name, 0)
            } else if Self.isEntryName(name) {
                guard info.st_size > Self.headerBytes,
                      info.st_size <= maximumEntryBytes + Self.headerBytes else {
                    unlinkat(parent, name, 0)
                    continue
                }
                entries.append(Entry(name: name, size: Int(info.st_size),
                    seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec))
            }
        }
        entries.sort { ($0.seconds, $0.nanoseconds, $0.name) < ($1.seconds, $1.nanoseconds, $1.name) }
        var total = entries.reduce(0) { $0 + $1.size }
        while total + bytes > maximumBytes || entries.count + count > maximumEntries {
            guard !entries.isEmpty else { return false }
            let victim = entries.removeFirst()
            guard unlinkat(parent, victim.name, 0) == 0 else { return false }
            total -= victim.size
        }
        return true
    }

    private static func isEntryName(_ name: String) -> Bool {
        name.utf8.count == 69 && name.hasSuffix(".blob")
            && name.dropLast(5).utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func isOwnedRegular(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFREG && info.st_uid == getuid() && info.st_nlink == 1
    }

    private static func readExactly(_ count: Int, from file: FileHandle) throws -> Data {
        guard var bytes = try file.read(upToCount: count), !bytes.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        while bytes.count < count {
            guard let next = try file.read(upToCount: count - bytes.count), !next.isEmpty else {
                throw CocoaError(.fileReadCorruptFile)
            }
            bytes.append(next)
        }
        return bytes
    }
}
