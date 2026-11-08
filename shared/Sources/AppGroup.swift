import CryptoKit
import Darwin
import Foundation

enum AppGroup {
    // An invalid build has no shared container and cannot select an auth keychain.
    static var identifier: String {
        (try? BuildIdentity.configuration().appGroup) ?? "invalid.peapod.app-group"
    }
    static var firebaseAuthAccessGroup: String {
        get throws { try BuildIdentity.configuration().authKeychainAccessGroup }
    }

    static var containerURL: URL? {
        guard let identity = try? BuildIdentity.configuration() else { return nil }
        return FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: identity.appGroup
        )
    }

    static var messageStorageURL: URL? {
        return containerURL
    }
}

enum SharedConversationMode: String, Codable, Sendable { case legacy, encrypted }

struct SharedConversationTarget: Codable, Sendable, Equatable {
    let version: UInt32
    let accountID: String
    let conversationID: String
    let mode: SharedConversationMode
    let keyEpoch: UInt32?
    let members: [String]
    let generation: UUID

    init(accountID: String, conversationID: String, mode: SharedConversationMode,
         keyEpoch: UInt32? = nil, members: [String], generation: UUID = UUID()) throws {
        guard [accountID, conversationID].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }),
              members.count == 2, members.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }),
              Data(members[0].utf8) != Data(members[1].utf8), members.contains(where: { Data($0.utf8) == Data(accountID.utf8) }) else {
            throw PendingShareStoreError.invalidSharedState
        }
        if mode == .encrypted {
            guard let id = UUID(uuidString: conversationID), id.uuidString.lowercased() == conversationID,
                  let keyEpoch, keyEpoch > 0 else { throw PendingShareStoreError.invalidSharedState }
        } else if keyEpoch != nil { throw PendingShareStoreError.invalidSharedState }
        version = 1; self.accountID = accountID; self.conversationID = conversationID; self.mode = mode
        self.keyEpoch = keyEpoch; self.members = members; self.generation = generation
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.version == rhs.version && Data(lhs.accountID.utf8) == Data(rhs.accountID.utf8)
            && Data(lhs.conversationID.utf8) == Data(rhs.conversationID.utf8) && lhs.mode == rhs.mode
            && lhs.keyEpoch == rhs.keyEpoch && lhs.members.map { Data($0.utf8) } == rhs.members.map { Data($0.utf8) }
            && lhs.generation == rhs.generation
    }
    fileprivate static func decode(_ data: Data) throws -> Self {
        guard data.count <= 4096,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["version", "accountID", "conversationID", "mode", "keyEpoch", "members", "generation"]) else {
            throw PendingShareStoreError.invalidSharedState
        }
        let decoded = try JSONDecoder().decode(Self.self, from: data)
        guard decoded.version == 1 else { throw PendingShareStoreError.invalidSharedState }
        return try Self(accountID: decoded.accountID, conversationID: decoded.conversationID, mode: decoded.mode,
                        keyEpoch: decoded.keyEpoch, members: decoded.members, generation: decoded.generation)
    }
}

/// App Group state is routing metadata only. A target is never authority for keys or server
/// membership. The app publishes it after trusted open; the extension revalidates remotely.
enum SharedConversationStore {
    /// Trusted native build policy, shared by the containing apps and extensions.
    /// Durable per-account markers cannot downgrade a newly installed encrypted build.
    static let encryptionRequiredByBuild = true
    private static let activeConversationKey = "activeConversationID"
    private static func store() throws -> SharedConversationStateStore {
        guard let root = AppGroup.messageStorageURL else { throw PendingShareStoreError.appGroupUnavailable }
        return SharedConversationStateStore(rootDirectory: root.appendingPathComponent("E2EE/SharedState", isDirectory: true),
                                            defaults: UserDefaults(suiteName: AppGroup.identifier))
    }
    static func currentTarget() throws -> SharedConversationTarget? {
        return try currentTarget(in: store())
    }
    /// Explicit storage injection keeps native policy tests isolated from real App Group state.
    static func currentTarget(in state: SharedConversationStateStore) throws -> SharedConversationTarget? {
        try requireBuildPolicy(state.currentTarget())
    }
    private static func requireBuildPolicy(_ target: SharedConversationTarget?) throws -> SharedConversationTarget? {
        if encryptionRequiredByBuild, let target, target.mode != .encrypted {
            throw PendingShareStoreError.encryptionRequired
        }
        return target
    }
    static func target(forAccountID id: String) throws -> SharedConversationTarget? {
        guard let target = try currentTarget(), Data(target.accountID.utf8) == Data(id.utf8) else { return nil }; return target
    }
    static func publishTrusted(_ target: SharedConversationTarget) throws {
        _ = try requireBuildPolicy(target)
        try publishTrusted(target, in: store())
    }
    static func publishTrusted(_ target: SharedConversationTarget, in state: SharedConversationStateStore) throws {
        _ = try requireBuildPolicy(target)
        try state.publish(target)
    }
    static func clearActiveTarget(accountID: String? = nil) throws { try store().clear(accountID: accountID) }
    static func requiresEncryption(accountID: String) throws -> Bool {
        if encryptionRequiredByBuild { return true }
        return try store().requiresEncryption(accountID: accountID)
    }
    static func markEncryptionRequired(accountID: String) throws { try store().markEncryptionRequired(accountID: accountID) }
    static var activeConversationID: String? {
        get {
            // A corrupt durable state must not fall back to the old preference.
            do {
                if let target = try currentTarget() { return target.conversationID }
                guard !encryptionRequiredByBuild else { return nil }
                return PendingShare.normalizedConversationID(UserDefaults(suiteName: AppGroup.identifier)?.string(forKey: activeConversationKey))
            } catch { return nil }
        }
        set {
            let normalized = PendingShare.normalizedConversationID(newValue)
            if let target = try? currentTarget(), normalized.map({ Data($0.utf8) == Data(target.conversationID.utf8) }) != true {
                try? clearActiveTarget(accountID: target.accountID)
            }
            let defaults = UserDefaults(suiteName: AppGroup.identifier)
            if let normalized { defaults?.set(normalized, forKey: activeConversationKey) }
            else { defaults?.removeObject(forKey: activeConversationKey) }
        }
    }
}


/// Dedicated protected atomic state. Filesystem ancestors are trusted App Group storage.
/// Marker creation and target replacement fsync before returning; floors are add-only.
struct SharedConversationStateStore: @unchecked Sendable {
    let rootDirectory: URL
    let defaults: UserDefaults?
    private var targetURL: URL { rootDirectory.appendingPathComponent("active-target.json") }
    static func floorKey(_ accountID: String) -> String {
        "e2eeRequired." + SHA256.hash(data: Data(accountID.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func floorURL(_ accountID: String) throws -> URL {
        guard !accountID.isEmpty, accountID.utf8.count <= 256 else { throw PendingShareStoreError.invalidSharedState }
        return rootDirectory.appendingPathComponent(Self.floorKey(accountID) + ".required")
    }
    func currentTarget() throws -> SharedConversationTarget? {
        try locked {
            guard let bytes = try read(targetURL, maximum: 4096) else { return nil }
            return try SharedConversationTarget.decode(bytes)
        }
    }
    func publish(_ target: SharedConversationTarget) throws {
        try locked {
            let target = try SharedConversationTarget.decode(JSONEncoder().encode(target))
            if target.mode == .encrypted { try writeFloor(target.accountID) }
            else if try hasFloor(target.accountID) { throw PendingShareStoreError.encryptionRequired }
            let bytes = try JSONEncoder().encode(target)
            try replace(bytes, at: targetURL)
        }
    }
    func clear(accountID: String?) throws {
        try locked {
            if let accountID, let bytes = try read(targetURL, maximum: 4096) {
                let target = try SharedConversationTarget.decode(bytes)
                guard Data(target.accountID.utf8) == Data(accountID.utf8) else { return }
            }
            if unlink(targetURL.path) != 0, errno != ENOENT { throw PendingShareStoreError.invalidSharedState }
            try syncDirectory()
        }
    }
    func requiresEncryption(accountID: String) throws -> Bool { try locked { try hasFloor(accountID) } }
    func markEncryptionRequired(accountID: String) throws { try locked { try writeFloor(accountID) } }
    private func hasFloor(_ id: String) throws -> Bool {
        let url = try floorURL(id)
        if let bytes = try read(url, maximum: 4) {
            guard bytes == Data("MEF1".utf8) else { throw PendingShareStoreError.invalidSharedState }; return true
        }
        if defaults?.bool(forKey: Self.floorKey(id)) == true { try writeFloor(id); return true }
        return false
    }
    private func writeFloor(_ id: String) throws {
        let url = try floorURL(id)
        if let bytes = try read(url, maximum: 4) {
            guard bytes == Data("MEF1".utf8) else { throw PendingShareStoreError.invalidSharedState }; return
        }
        try replace(Data("MEF1".utf8), at: url)
        defaults?.set(true, forKey: Self.floorKey(id)) // compatibility, never the authoritative marker
    }
    private func locked<T>(_ body: () throws -> T) throws -> T {
        try SharedProtectedFiles.prepareDirectory(rootDirectory)
        let lockURL = rootDirectory.appendingPathComponent(".state.lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw PendingShareStoreError.couldNotLock(errno) }
        defer { _ = Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw PendingShareStoreError.couldNotLock(errno) }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }
    private func read(_ url: URL, maximum: Int) throws -> Data? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        if descriptor < 0 { if errno == ENOENT { return nil }; throw PendingShareStoreError.invalidSharedState }
        defer { _ = Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_size >= 0, status.st_size <= maximum else { throw PendingShareStoreError.invalidSharedState }
        var data = Data(count: Int(status.st_size))
        let expected = data.count
        let count = data.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, expected) }
        guard count == expected else { throw PendingShareStoreError.invalidSharedState }
        return data
    }
    private func replace(_ data: Data, at target: URL) throws {
        let temporary = rootDirectory.appendingPathComponent(UUID().uuidString.lowercased())
        let descriptor = Darwin.open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw PendingShareStoreError.invalidSharedState }
        defer { _ = Darwin.close(descriptor); _ = unlink(temporary.path) }
        try SharedProtectedFiles.protectFile(temporary)
        let count = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, data.count) }
        guard count == data.count, fsync(descriptor) == 0, rename(temporary.path, target.path) == 0 else { throw PendingShareStoreError.invalidSharedState }
        try syncDirectory()
    }
    private func syncDirectory() throws {
        let descriptor = Darwin.open(rootDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw PendingShareStoreError.invalidSharedState }
        defer { _ = Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw PendingShareStoreError.invalidSharedState }
    }
}

enum SharedProtectedFiles {
    static func prepareDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw error
        }
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw PendingShareStoreError.invalidSharedState
        }
        guard status.st_mode & S_IFMT == S_IFDIR else {
            throw PendingShareStoreError.invalidSharedState
        }
        guard chmod(url.path, S_IRWXU) == 0 else {
            throw PendingShareStoreError.invalidSharedState
        }
        var protected = url; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try protected.setResourceValues(values)
#if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
#endif
    }
    static func protectFile(_ url: URL) throws {
        guard chmod(url.path, S_IRUSR | S_IWUSR) == 0 else { throw PendingShareStoreError.invalidSharedState }
        var protected = url; var values = URLResourceValues(); values.isExcludedFromBackup = true; try protected.setResourceValues(values)
#if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
#endif
    }
}

/// Controls whether creation of a message should produce the ordinary alert
/// notification. This lives beside the shared outbox model so extension
/// targets can decode legacy and future queue records without pulling in the
/// app's complete chat model.
enum MessageDeliveryMode: String, Codable, Hashable, Sendable {
    case normal
    case quiet

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try? container.decode(String.self)
        self = value == Self.quiet.rawValue ? .quiet : .normal
    }

    init(storedValue: Any?) {
        self = storedValue as? String == Self.quiet.rawValue
            ? .quiet
            : .normal
    }

    var storedValue: String? {
        self == .quiet ? rawValue : nil
    }
}


struct PendingShare: Codable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case text
        case url
        case image
        case movie
        case file
    }

    let id: UUID
    let kind: Kind
    let text: String?
    /// The immutable destination selected when this outbox item was accepted.
    ///
    /// This remains optional so older queue files can still decode.
    /// `PendingShareStore` rejects new unscoped conversation shares.
    let conversationID: String?
    let conversationOwnerID: String?
    /// A filename relative to the outbox's staging directory.
    let localFileName: String?
    let originalFileName: String?
    let contentTypeIdentifier: String?
    let attachmentGroupID: UUID?
    let attachmentGroupIndex: Int?
    let attachmentGroupCount: Int?
    /// Absent for normal delivery and for every legacy/Share-extension item.
    let deliveryMode: MessageDeliveryMode?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        kind: Kind,
        text: String? = nil,
        conversationID: String? = nil,
        conversationOwnerID: String? = nil,
        localFileName: String? = nil,
        originalFileName: String? = nil,
        contentTypeIdentifier: String? = nil,
        attachmentGroupID: UUID? = nil,
        attachmentGroupIndex: Int? = nil,
        attachmentGroupCount: Int? = nil,
        deliveryMode: MessageDeliveryMode? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.conversationID = conversationID
        self.conversationOwnerID = conversationOwnerID
        self.localFileName = localFileName
        self.originalFileName = originalFileName
        self.contentTypeIdentifier = contentTypeIdentifier
        self.attachmentGroupID = attachmentGroupID
        self.attachmentGroupIndex = attachmentGroupIndex
        self.attachmentGroupCount = attachmentGroupCount
        self.deliveryMode = deliveryMode?.storedValue == nil
            ? nil
            : deliveryMode
        self.createdAt = createdAt
    }

    func groupedWithPhotos(
        id groupID: UUID,
        index: Int,
        count: Int
    ) -> PendingShare {
        PendingShare(
            id: id,
            kind: kind,
            text: text,
            conversationID: conversationID,
            conversationOwnerID: conversationOwnerID,
            localFileName: localFileName,
            originalFileName: originalFileName,
            contentTypeIdentifier: contentTypeIdentifier,
            attachmentGroupID: groupID,
            attachmentGroupIndex: index,
            attachmentGroupCount: count,
            deliveryMode: deliveryMode,
            createdAt: createdAt
        )
    }

    func scopedToConversation(_ conversationID: String) throws -> PendingShare {
        guard
            let conversationID = Self.normalizedConversationID(conversationID)
        else {
            throw PendingShareStoreError.missingConversationTarget
        }
        return PendingShare(
            id: id,
            kind: kind,
            text: text,
            conversationID: conversationID,
            conversationOwnerID: conversationOwnerID,
            localFileName: localFileName,
            originalFileName: originalFileName,
            contentTypeIdentifier: contentTypeIdentifier,
            attachmentGroupID: attachmentGroupID,
            attachmentGroupIndex: attachmentGroupIndex,
            attachmentGroupCount: attachmentGroupCount,
            deliveryMode: deliveryMode,
            createdAt: createdAt
        )
    }

    func scopedToConversation(_ conversationID: String, accountID: String) throws -> PendingShare {
        guard !accountID.isEmpty, accountID.utf8.count <= 256,
              conversationOwnerID == nil || Data(conversationOwnerID!.utf8) == Data(accountID.utf8) else { throw PendingShareStoreError.accountMismatch }
        let scoped = try scopedToConversation(conversationID)
        return PendingShare(id: scoped.id, kind: scoped.kind, text: scoped.text, conversationID: scoped.conversationID,
                            conversationOwnerID: accountID, localFileName: scoped.localFileName, originalFileName: scoped.originalFileName,
                            contentTypeIdentifier: scoped.contentTypeIdentifier, attachmentGroupID: scoped.attachmentGroupID,
                            attachmentGroupIndex: scoped.attachmentGroupIndex, attachmentGroupCount: scoped.attachmentGroupCount,
                            deliveryMode: scoped.deliveryMode, createdAt: scoped.createdAt)
    }

    func delivered(_ mode: MessageDeliveryMode) -> PendingShare {
        PendingShare(
            id: id,
            kind: kind,
            text: text,
            conversationID: conversationID,
            conversationOwnerID: conversationOwnerID,
            localFileName: localFileName,
            originalFileName: originalFileName,
            contentTypeIdentifier: contentTypeIdentifier,
            attachmentGroupID: attachmentGroupID,
            attachmentGroupIndex: attachmentGroupIndex,
            attachmentGroupCount: attachmentGroupCount,
            deliveryMode: mode,
            createdAt: createdAt
        )
    }

    /// Staging can precede Send by minutes. Persist the submission time when
    /// the draft enters the outbox, without changing its durable identity.
    func queuedForSending(at date: Date) -> PendingShare {
        PendingShare(
            id: id,
            kind: kind,
            text: text,
            conversationID: conversationID,
            conversationOwnerID: conversationOwnerID,
            localFileName: localFileName,
            originalFileName: originalFileName,
            contentTypeIdentifier: contentTypeIdentifier,
            attachmentGroupID: attachmentGroupID,
            attachmentGroupIndex: attachmentGroupIndex,
            attachmentGroupCount: attachmentGroupCount,
            deliveryMode: deliveryMode,
            createdAt: date
        )
    }

    var targetConversationID: String? {
        Self.normalizedConversationID(conversationID)
    }

    static func normalizedConversationID(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return normalized.isEmpty ? nil : normalized
    }
}

enum PhotoAttachmentDraftError: LocalizedError {
    case empty
    case tooMany(maximum: Int)
    case unsupportedItem

    var errorDescription: String? {
        switch self {
        case .empty:
            "Choose at least one photo to send."
        case let .tooMany(maximum):
            "You can send up to \(maximum) photos at a time."
        case .unsupportedItem:
            "Only photos can be included in this draft."
        }
    }
}

enum PhotoAttachmentDraftPolicy {
    static let maximumCount = 10

    static func validate(_ shares: [PendingShare]) throws {
        guard !shares.isEmpty else {
            throw PhotoAttachmentDraftError.empty
        }
        guard shares.count <= maximumCount else {
            throw PhotoAttachmentDraftError.tooMany(maximum: maximumCount)
        }
        guard shares.allSatisfy({ $0.kind == .image }) else {
            throw PhotoAttachmentDraftError.unsupportedItem
        }
    }

    static func preparedForSend(
        _ shares: [PendingShare]
    ) throws -> [PendingShare] {
        try validate(shares)
        guard shares.count > 1, let groupID = shares.first?.id else {
            return shares
        }
        return shares.enumerated().map { index, share in
            share.groupedWithPhotos(
                id: groupID,
                index: index,
                count: shares.count
            )
        }
    }
}

enum PendingShareStoreError: LocalizedError {
    case appGroupUnavailable
    case invalidSharedState
    case accountMismatch
    case encryptionRequired
    case couldNotLock(Int32)
    case missingConversationTarget
    case missingStagedFile
    case emptyAttachment
    case attachmentTooLarge(maximumBytes: Int64)

    var errorDescription: String? {
        switch self {
        case .invalidSharedState:
            "The shared conversation state is unavailable or invalid. Open Peapod before sharing."
        case .accountMismatch:
            "This share belongs to a different signed-in account."
        case .encryptionRequired:
            "This account requires an encrypted conversation. Open Peapod before sharing."
        case .appGroupUnavailable:
            "The shared app container is unavailable."
        case let .couldNotLock(code):
            "The share outbox could not be locked (error \(code))."
        case .missingConversationTarget:
            "Create or join a conversation before sharing."
        case .missingStagedFile:
            "The shared attachment is no longer available."
        case .emptyAttachment:
            "The shared attachment is empty."
        case let .attachmentTooLarge(maximumBytes):
            "The shared attachment is larger than the \(Self.limitDescription(maximumBytes)) limit."
        }
    }

    private static func limitDescription(_ bytes: Int64) -> String {
        bytes % (1024 * 1024) == 0
            ? "\(bytes / (1024 * 1024)) MiB"
            : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

enum PendingShareAttachmentPolicy {
    static let maximumByteSize: Int64 = 200 * 1_024 * 1_024
    static let maximumEncryptedNonVideoBytes: Int64 = 20 * 1_024 * 1_024
    static let maximumSendingPhotoBytes: Int64 = maximumByteSize
    static let maximumSendingVideoBytes: Int64 = maximumByteSize

    static func maximumBytes(for kind: PendingShare.Kind, mode: SharedConversationMode) -> Int64 {
        if kind == .image { return maximumSendingPhotoBytes }
        if kind == .movie { return maximumSendingVideoBytes }
        return mode == .encrypted ? maximumEncryptedNonVideoBytes : 100 * 1_024 * 1_024
    }

    static func validate(byteSize: Int64, maximumBytes: Int64 = maximumByteSize) throws {
        guard maximumBytes > 0, maximumBytes <= maximumByteSize else { throw PendingShareStoreError.invalidSharedState }
        guard byteSize > 0 else {
            throw PendingShareStoreError.emptyAttachment
        }
        guard byteSize <= maximumBytes else {
            throw PendingShareStoreError.attachmentTooLarge(
                maximumBytes: maximumBytes
            )
        }
    }
}

/// A file-backed outbox shared by the app and its Share extension.
///
/// All queue mutations take an advisory file lock and replace the queue file
/// atomically. This prevents simultaneous extension and app processes from
/// dropping one another's items.
struct PendingShareOutbox: Sendable {
    private let rootDirectory: URL

    private var queueURL: URL {
        rootDirectory.appendingPathComponent("outbox.json", isDirectory: false)
    }

    private var lockURL: URL {
        rootDirectory.appendingPathComponent(".outbox.lock", isDirectory: false)
    }

    private var stagingDirectoryURL: URL {
        rootDirectory.appendingPathComponent("attachments", isDirectory: true)
    }

    init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    func load() throws -> [PendingShare] {
        try withExclusiveLock {
            try readQueueWithoutLock()
        }
    }

    func load(for accountID: String) throws -> [PendingShare] {
        try load().filter { $0.conversationOwnerID.map { Data($0.utf8) == Data(accountID.utf8) } == true }
    }

    func enqueue(_ shares: [PendingShare]) throws {
        guard !shares.isEmpty else { return }

        try withExclusiveLock {
            var queued = try readQueueWithoutLock()
            guard queued.count + shares.count <= 256 else { throw PendingShareStoreError.invalidSharedState }
            queued.append(contentsOf: shares)
            try writeQueueWithoutLock(queued)
        }
    }

    /// Supplies a stable queue snapshot and removes only the IDs the caller
    /// returns. Items the caller cannot process remain queued.
    ///
    /// The handler should synchronously copy or persist any staged attachment
    /// it accepts. Acknowledged staged files are deleted after the queue update.
    @discardableResult
    func drain(
        _ process: ([PendingShare]) throws -> Set<UUID>
    ) throws -> [PendingShare] {
        try withExclusiveLock {
            let queued = try readQueueWithoutLock()
            guard !queued.isEmpty else { return [] }

            let requestedIDs = try process(queued)
            let queuedIDs = Set(queued.map(\.id))
            let acknowledgedIDs = requestedIDs.intersection(queuedIDs)
            guard !acknowledgedIDs.isEmpty else { return [] }

            let acknowledged = queued.filter { acknowledgedIDs.contains($0.id) }
            let remaining = queued.filter { !acknowledgedIDs.contains($0.id) }
            try writeQueueWithoutLock(remaining)

            for item in acknowledged {
                try? removeStagedFileWithoutLock(for: item)
            }
            return acknowledged
        }
    }

    /// Copies a provider-owned file into the App Group while the provider URL
    /// is valid and returns an item ready to enqueue.
    func stageFile(
        from sourceURL: URL,
        kind: PendingShare.Kind,
        suggestedName: String? = nil,
        contentTypeIdentifier: String? = nil,
        maximumByteSize: Int64 = PendingShareAttachmentPolicy.maximumByteSize
    ) throws -> PendingShare {
        try ensureDirectories()

        let originalName = usableFilename(suggestedName)
            ?? usableFilename(sourceURL.lastPathComponent)
        let destination = uniqueStagingURL(
            originalName: originalName,
            fallbackExtension: sourceURL.pathExtension
        )

        let accessedSecurityScopedResource =
            sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScopedResource {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        if
            let sourceSize = try? sourceURL.resourceValues(
                forKeys: [.fileSizeKey]
            ).fileSize
        {
            try PendingShareAttachmentPolicy.validate(
                byteSize: Int64(sourceSize), maximumBytes: maximumByteSize
            )
        }

        do {
            try Data().write(to: destination, options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication])
            try SharedProtectedFiles.protectFile(destination)
            let input = try FileHandle(forReadingFrom: sourceURL)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            var copied: Int64 = 0
            while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
                copied += Int64(chunk.count)
                guard copied <= maximumByteSize else { throw PendingShareStoreError.attachmentTooLarge(maximumBytes: maximumByteSize) }
                try output.write(contentsOf: chunk)
            }
            try output.synchronize()
            let stagedSize = try destination.resourceValues(
                forKeys: [.fileSizeKey]
            ).fileSize ?? 0
            try PendingShareAttachmentPolicy.validate(
                byteSize: Int64(stagedSize), maximumBytes: maximumByteSize
            )
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }

        return PendingShare(
            kind: kind,
            localFileName: destination.lastPathComponent,
            originalFileName: originalName,
            contentTypeIdentifier: contentTypeIdentifier
        )
    }

    /// Stages an in-memory representation returned by an item provider.
    func stageData(
        _ data: Data,
        kind: PendingShare.Kind,
        suggestedName: String? = nil,
        preferredExtension: String? = nil,
        contentTypeIdentifier: String? = nil,
        maximumByteSize: Int64 = PendingShareAttachmentPolicy.maximumByteSize
    ) throws -> PendingShare {
        try PendingShareAttachmentPolicy.validate(
            byteSize: Int64(data.count), maximumBytes: maximumByteSize
        )
        try ensureDirectories()

        let originalName = usableFilename(suggestedName)
        let destination = uniqueStagingURL(
            originalName: originalName,
            fallbackExtension: preferredExtension
        )
        try data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try SharedProtectedFiles.protectFile(destination)

        return PendingShare(
            kind: kind,
            localFileName: destination.lastPathComponent,
            originalFileName: originalName,
            contentTypeIdentifier: contentTypeIdentifier
        )
    }

    func stagedFileURL(for share: PendingShare) throws -> URL {
        guard let localFileName = share.localFileName else {
            throw PendingShareStoreError.missingStagedFile
        }

        let safeFilename = URL(fileURLWithPath: localFileName).lastPathComponent
        guard safeFilename == localFileName else {
            throw PendingShareStoreError.missingStagedFile
        }

        let url = stagingDirectoryURL.appendingPathComponent(
            safeFilename,
            isDirectory: false
        )
        var status = stat()
        guard lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
            throw PendingShareStoreError.missingStagedFile
        }
        return url
    }

    func discardStagedFiles(for shares: [PendingShare]) {
        for share in shares {
            try? removeStagedFileWithoutLock(for: share)
        }
    }


    private func withExclusiveLock<T>(
        createDirectories: Bool = true,
        _ operation: () throws -> T
    ) throws -> T {
        if createDirectories { try ensureDirectories() }

        let descriptor = lockURL.path.withCString {
            Darwin.open($0, (createDirectories ? O_CREAT : 0) | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw PendingShareStoreError.couldNotLock(errno)
        }
        defer {
            _ = Darwin.close(descriptor)
        }

        guard flock(descriptor, LOCK_EX) == 0 else {
            throw PendingShareStoreError.couldNotLock(errno)
        }
        defer {
            _ = flock(descriptor, LOCK_UN)
        }

        return try operation()
    }

    private func ensureDirectories() throws {
        try SharedProtectedFiles.prepareDirectory(rootDirectory)
        try SharedProtectedFiles.prepareDirectory(stagingDirectoryURL)
    }

    private func readQueueWithoutLock() throws -> [PendingShare] {
        guard FileManager.default.fileExists(atPath: queueURL.path) else {
            return []
        }

        let size = try queueURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 4 * 1024 * 1024 else { throw PendingShareStoreError.invalidSharedState }
        let data = try Data(contentsOf: queueURL)
        guard data.count <= 4 * 1024 * 1024 else { throw PendingShareStoreError.invalidSharedState }
        let decoded = try JSONDecoder().decode([PendingShare].self, from: data)
        guard decoded.count <= 256 else { throw PendingShareStoreError.invalidSharedState }
        return decoded
    }

    private func writeQueueWithoutLock(_ items: [PendingShare]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(items)
        guard items.count <= 256, data.count <= 4 * 1024 * 1024 else { throw PendingShareStoreError.invalidSharedState }
        try data.write(to: queueURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try SharedProtectedFiles.protectFile(queueURL)
    }

    private func uniqueStagingURL(
        originalName: String?,
        fallbackExtension: String?
    ) -> URL {
        stagingDirectoryURL.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: false)
    }

    private func usableFilename(_ value: String?) -> String? {
        guard let value else { return nil }

        let filename = URL(fileURLWithPath: value).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filename.isEmpty, filename != ".", filename != "/" else {
            return nil
        }
        return String(filename.suffix(180))
    }

    private func removeStagedFileWithoutLock(for share: PendingShare) throws {
        guard let localFileName = share.localFileName else { return }
        let safeFilename = URL(fileURLWithPath: localFileName).lastPathComponent
        guard safeFilename == localFileName else { return }

        let url = stagingDirectoryURL.appendingPathComponent(
            safeFilename,
            isDirectory: false
        )
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

enum PendingShareStore {
    private static func sharedOutbox() throws -> PendingShareOutbox {
        guard let root = AppGroup.messageStorageURL else { throw PendingShareStoreError.appGroupUnavailable }
        return PendingShareOutbox(rootDirectory: root.appendingPathComponent("PendingShares", isDirectory: true))
    }
    private static func target() throws -> SharedConversationTarget {
        guard let target = try SharedConversationStore.currentTarget() else { throw PendingShareStoreError.missingConversationTarget }
        return target
    }
    /// Legacy unowned queue items remain quarantined; never adopt them into the current account.
    static func pendingItems(for accountID: String) throws -> [PendingShare] {
        try sharedOutbox().load(for: accountID)
    }
    static func pendingItems() throws -> [PendingShare] { try pendingItems(for: target().accountID) }
    static func load() -> [PendingShare] { (try? pendingItems()) ?? [] }
    static func enqueue(_ shares: [PendingShare]) throws {
        let target = try target()
        guard target.mode == .legacy, try !SharedConversationStore.requiresEncryption(accountID: target.accountID) else { throw PendingShareStoreError.encryptionRequired }
        let scoped = try shares.map { share in
            guard share.targetConversationID.map({ Data($0.utf8) == Data(target.conversationID.utf8) }) == true else { throw PendingShareStoreError.missingConversationTarget }
            return try share.scopedToConversation(target.conversationID, accountID: target.accountID)
        }
        try sharedOutbox().enqueue(scoped)
    }
    /// Explicit endpoint draft storage for the containing app's synchronous composer workflow.
    /// This is protected local plaintext, never a transport fallback or an encryption claim.
    static func enqueueProtectedDrafts(_ shares: [PendingShare], accountID: String, conversationID: String) throws {
        let target = try target()
        guard Data(target.accountID.utf8) == Data(accountID.utf8), Data(target.conversationID.utf8) == Data(conversationID.utf8) else { throw PendingShareStoreError.accountMismatch }
        if target.mode == .encrypted { guard try SharedConversationStore.requiresEncryption(accountID: accountID) else { throw PendingShareStoreError.invalidSharedState } }
        else if try SharedConversationStore.requiresEncryption(accountID: accountID) { throw PendingShareStoreError.encryptionRequired }
        let scoped = try shares.map { share in
            guard share.targetConversationID.map({ Data($0.utf8) == Data(conversationID.utf8) }) == true else { throw PendingShareStoreError.missingConversationTarget }
            if target.mode == .encrypted, share.kind != .text && share.kind != .url {
                let url = try sharedOutbox().stagedFileURL(for: share)
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                try PendingShareAttachmentPolicy.validate(byteSize: Int64(size),
                    maximumBytes: PendingShareAttachmentPolicy.maximumBytes(for: share.kind, mode: .encrypted))
            }
            return try share.scopedToConversation(conversationID, accountID: accountID)
        }
        try sharedOutbox().enqueue(scoped)
    }

    static func stageFile(from sourceURL: URL, kind: PendingShare.Kind, suggestedName: String? = nil,
                          contentTypeIdentifier: String? = nil, maximumByteSize: Int64? = nil) throws -> PendingShare {
        let target = try target(); let outbox = try sharedOutbox()
        let staged = try outbox.stageFile(from: sourceURL, kind: kind, suggestedName: suggestedName,
                                          contentTypeIdentifier: contentTypeIdentifier,
                                          maximumByteSize: min(maximumByteSize ?? PendingShareAttachmentPolicy.maximumByteSize,
                                            PendingShareAttachmentPolicy.maximumBytes(for: kind, mode: target.mode)))
        do {
            guard try SharedConversationStore.currentTarget() == target else { throw PendingShareStoreError.accountMismatch }
            return try staged.scopedToConversation(target.conversationID, accountID: target.accountID)
        } catch { outbox.discardStagedFiles(for: [staged]); throw error }
    }
    static func stageData(_ data: Data, kind: PendingShare.Kind, suggestedName: String? = nil, preferredExtension: String? = nil,
                          contentTypeIdentifier: String? = nil, maximumByteSize: Int64? = nil) throws -> PendingShare {
        let target = try target(); let outbox = try sharedOutbox()
        let staged = try outbox.stageData(data, kind: kind, suggestedName: suggestedName, preferredExtension: preferredExtension,
                                          contentTypeIdentifier: contentTypeIdentifier,
                                          maximumByteSize: min(maximumByteSize ?? PendingShareAttachmentPolicy.maximumByteSize,
                                            PendingShareAttachmentPolicy.maximumBytes(for: kind, mode: target.mode)))
        do {
            guard try SharedConversationStore.currentTarget() == target else { throw PendingShareStoreError.accountMismatch }
            return try staged.scopedToConversation(target.conversationID, accountID: target.accountID)
        } catch { outbox.discardStagedFiles(for: [staged]); throw error }
    }
    static func stagedFileURL(for share: PendingShare) throws -> URL {
        let target = try target()
        guard share.conversationOwnerID.map({ Data($0.utf8) == Data(target.accountID.utf8) }) == true else { throw PendingShareStoreError.accountMismatch }
        return try sharedOutbox().stagedFileURL(for: share)
    }
    @discardableResult
    static func acknowledgeProcessed(_ ids: Set<UUID>, accountID: String) throws -> [PendingShare] {
        try sharedOutbox().drain { items in
            Set(items.filter { $0.conversationOwnerID.map({ Data($0.utf8) == Data(accountID.utf8) }) == true && ids.contains($0.id) }.map(\.id))
        }
    }
    @discardableResult
    static func acknowledgeProcessed(_ ids: Set<UUID>) throws -> [PendingShare] { try acknowledgeProcessed(ids, accountID: target().accountID) }
    @discardableResult
    static func drain(_ process: ([PendingShare]) throws -> Set<UUID>) throws -> [PendingShare] {
        let account = try target().accountID
        return try sharedOutbox().drain { all in
            let owned = all.filter { $0.conversationOwnerID.map({ Data($0.utf8) == Data(account.utf8) }) == true }
            return try process(owned).intersection(Set(owned.map(\.id)))
        }
    }
    static func discardStagedFiles(for shares: [PendingShare]) { try? sharedOutbox().discardStagedFiles(for: shares) }
    static func append(_ share: PendingShare) { try? enqueue([share]) }
    static func removeAll() { _ = try? drain { Set($0.map(\.id)) } }
}
