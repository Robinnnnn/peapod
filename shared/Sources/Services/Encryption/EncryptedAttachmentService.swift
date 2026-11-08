@preconcurrency import FirebaseFirestore
@preconcurrency import FirebaseStorage
import CryptoKit
import Foundation
import MinesE2EE
import UniformTypeIdentifiers

enum EncryptedAttachmentError: LocalizedError {
    case preparationBusy, tooLarge
    var errorDescription: String? {
        switch self {
        case .preparationBusy: "Another attachment is being prepared. Try sending again in a moment."
        case .tooLarge: "Photos and videos can be up to 200 MiB. Other encrypted attachments can be up to 20 MiB."
        }
    }
}

@MainActor
protocol EncryptedBlobStoring: AnyObject {
    func upload(bytes: Data, attachmentID: String, context: RecordContext) async throws
    func download(attachmentID: String, context: RecordContext) async throws -> Data
    func download(attachmentID: String, context: RecordContext, maximumBytes: Int) async throws -> Data
}

extension EncryptedBlobStoring {
    func download(attachmentID: String, context: RecordContext, maximumBytes: Int) async throws -> Data {
        let bytes = try await download(attachmentID: attachmentID, context: context)
        guard bytes.count <= maximumBytes else { throw EncryptedAttachmentError.tooLarge }
        return bytes
    }
}

/// Local preparation only: the message outbox must persist descriptor and exact
/// ciphertext before its transport invokes uploadPersistedBlob.
@MainActor
final class EncryptedAttachmentService: AttachmentProviding {
    private let session: SecureConversationSession
    private let blobs: any EncryptedBlobStoring
    private let stagedFile: (PendingShare) throws -> URL
    private let restorePendingAttachment: (UUID) async throws -> AttachmentContent?
    private let ciphertextCache: PersistentPhotoCiphertextCache?
    private var preparing: Set<UUID> = []
    init(session: SecureConversationSession, blobs: any EncryptedBlobStoring,
         restorePendingAttachment: @escaping (UUID) async throws -> AttachmentContent?,
         stagedFile: @escaping (PendingShare) throws -> URL = PendingShareStore.stagedFileURL,
         ciphertextCache: PersistentPhotoCiphertextCache? = nil) {
        self.session = session; self.blobs = blobs; self.stagedFile = stagedFile
        self.restorePendingAttachment = restorePendingAttachment
        self.ciphertextCache = ciphertextCache
    }
    func upload(_ share: PendingShare, messageID: UUID, conversationID: String, ownerID: String) async throws -> AttachmentContent {
        try session.requireActive(conversationID: conversationID, accountID: ownerID)
        guard preparing.isEmpty else { throw EncryptedAttachmentError.preparationBusy }
        preparing.insert(messageID)
        defer { preparing.remove(messageID) }
        let context = try session.context(recordID: messageID.uuidString.lowercased())
        if let restored = try await restorePendingAttachment(messageID) {
            try session.validate(context)
            return restored
        }
        try session.validate(context)
        if let existing = try session.privateAttachment(for: context) {
            return content(existing, context, LocalAttachmentService.attachmentType(for: share))
        }
        let url = try stagedFile(share)
        let maximumBytes = Int(PendingShareAttachmentPolicy.maximumBytes(for: share.kind, mode: .encrypted))
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize,
              size >= 0, size <= maximumBytes else { throw EncryptedAttachmentError.tooLarge }
        // Staged files are app-owned and immutable. Mapping avoids retaining a second
        // full-size plaintext allocation while CryptoKit seals an original video.
        let bytes = try Data(contentsOf: url, options: .alwaysMapped)
        guard bytes.count <= maximumBytes else { throw EncryptedAttachmentError.tooLarge }
        guard bytes.count == size else {
            throw EncryptedMessagingError.conflictingRecord
        }
        let filename = share.originalFileName ?? url.lastPathComponent
        let mediaType = LocalAttachmentService.contentType(for: share, url: url)
        let duration: UInt64?
        if let seconds = share.voiceMessageDuration {
            guard seconds.isFinite, seconds > 0, seconds <= 86_400 else { throw E2EEError.invalidAttachmentMetadata }
            duration = UInt64((seconds * 1000).rounded())
        } else { duration = nil }
        let cipher = try AttachmentCipher()
        let isPhoto = LocalAttachmentService.attachmentType(for: share) == .image
        let (sealed, preview, renditions) = try await session.performKeyOperation { _ in
            let sealed = try cipher.seal(bytes, context: context, attachmentID: UUID().uuidString.lowercased(),
                            filename: filename, mediaType: mediaType, voiceDurationMilliseconds: duration)
            let preview = isPhoto ? EncryptedPhotoPreviewImage.make(from: bytes).flatMap {
                try? PhotoPreviewCipher.seal($0, original: sealed.privateMetadata, context: context)
            } : nil
            var renditions: [PhotoRendition: Data] = [:]
            if isPhoto {
                for rendition in PhotoRendition.allCases {
                    if let image = EncryptedPhotoRenditionImage.make(from: bytes, rendition: rendition) {
                        renditions[rendition] = try PhotoRenditionCipher.seal(image, original: sealed.privateMetadata, context: context, rendition: rendition).bytes
                    }
                }
            }
            return (sealed, preview, renditions)
        }
        try session.registerAttachment(sealed.privateMetadata, context: context, sealedBytes: sealed.bytes, previewBytes: preview?.bytes, renditionBytes: renditions)
        if isPhoto, let ciphertextCache {
            // A sent photo may have been shown only from its staged image, never
            // downloaded. Retain its already authenticated display envelopes now.
            // The original is needed here only when no suitable display copy
            // could be made (for example an HDR/auxiliary-image original).
            if renditions.isEmpty {
                let key = PersistentPhotoCiphertextCache.Key(accountID: session.capsule.localAccountID,
                    context: context, metadata: sealed.privateMetadata, blobID: sealed.privateMetadata.attachmentID, role: .original)
                await ciphertextCache.store(sealed.bytes, for: key, maximumBytes: POCLimits.attachmentEnvelopeBytes)
            } else {
                for rendition in [PhotoRendition.viewer, .chat] {
                    guard let bytes = renditions[rendition] else { continue }
                    try Task.checkCancellation()
                    try session.validate(context)
                    let id = PhotoRenditionCipher.attachmentID(for: sealed.privateMetadata, context: context, rendition: rendition)
                    let key = PersistentPhotoCiphertextCache.Key(accountID: session.capsule.localAccountID,
                        context: context, metadata: sealed.privateMetadata, blobID: id, role: rendition == .chat ? .chat : .viewer)
                    await ciphertextCache.store(bytes, for: key, maximumBytes: rendition.maximumEnvelopeBytes)
                }
            }
            try Task.checkCancellation()
            try session.validate(context)
        }
        return content(sealed.privateMetadata, context, LocalAttachmentService.attachmentType(for: share))
    }
    func uploadPersistedBlob(context: RecordContext, attachmentID: String, bytes: Data) async throws {
        try session.validate(context)
        guard SecureConversationSession.same(context.senderID, session.capsule.localAccountID) else {
            throw EncryptedMessagingError.untrustedConversation
        }
        try await blobs.upload(bytes: bytes, attachmentID: attachmentID, context: context)
        try session.validate(context)
    }
    private func content(_ m: PrivateAttachment, _ c: RecordContext, _ type: AttachmentType) -> AttachmentContent {
        AttachmentContent(id: m.attachmentID, type: type,
            storagePath: SecureConversationSession.attachmentPath(context: c, attachmentID: m.attachmentID),
            fileName: m.filename, contentType: m.mediaType, byteSize: Int64(m.originalByteCount),
            audioDurationMilliseconds: m.voiceDurationMilliseconds.map(Int.init))
    }
}

/// Fresh metadata only; never copy source filenames, HTTP headers or download tokens.
@MainActor
final class FirebaseEncryptedBlobStore: EncryptedBlobStoring {
    private let session: SecureConversationSession
    private let database: Firestore
    private let storage: Storage
    init(session: SecureConversationSession, database: Firestore = .firestore(), storage: Storage = .storage()) {
        self.session = session; self.database = database; self.storage = storage
    }
    static func uploadMetadata() -> StorageMetadata {
        let value = StorageMetadata()
        value.contentType = "application/octet-stream"
        // The Apple SDK serializes nil custom metadata as JSON null. Use an
        // empty object so Storage can validate that no private metadata leaks.
        value.customMetadata = [:]
        return value
    }
    func upload(bytes: Data, attachmentID: String, context: RecordContext) async throws {
        try check(attachmentID, context)
        guard SecureConversationSession.same(context.senderID, session.capsule.localAccountID),
              !bytes.isEmpty, bytes.count <= POCLimits.attachmentEnvelopeBytes else { throw EncryptedMessagingError.invalidRecord }
        let digest = Data(SHA256.hash(data: bytes))
        let document = database.collection("conversations").document(context.conversationID).collection("encryptedBlobs").document(attachmentID)
        let existing = try await document.getDocument(source: .server)
        try check(attachmentID, context)
        if existing.exists { try validate(existing.data(), context, bytes.count, digest) }
        else {
            do {
                try await document.setData(["ownerId": context.senderID, "messageId": context.recordID,
                    "keyEpoch": context.keyEpoch, "revision": context.revision, "byteSize": bytes.count,
                    "digest": SecurePairingWire.hex(digest), "createdAt": FieldValue.serverTimestamp()])
            } catch {
                try check(attachmentID, context)
                let retry = try await document.getDocument(source: .server)
                try check(attachmentID, context)
                try validate(retry.data(), context, bytes.count, digest)
            }
            try check(attachmentID, context)
        }
        let reference = blob(attachmentID, context)
        do {
            _ = try await reference.getMetadata()
            try check(attachmentID, context)
            let previous = try await downloadFile(reference, attachmentID: attachmentID, context: context)
            try check(attachmentID, context)
            guard Data(SHA256.hash(data: previous)) == digest else { throw EncryptedMessagingError.conflictingRecord }
            return
        } catch let error as NSError where error.domain == StorageErrorDomain && error.code == StorageErrorCode.objectNotFound.rawValue {
            try check(attachmentID, context)
        }
        let uploadFile = try EncryptedBlobTransferFile(bytes: bytes)
        defer { withExtendedLifetime(uploadFile) {} }
        do {
            try await transfer { completion in
                reference.putFile(from: uploadFile.url, metadata: Self.uploadMetadata()) { metadata, error in
                    completion(error ?? (metadata == nil ? EncryptedMessagingError.invalidRecord : nil))
                }
            }
        }
        catch let uploadError {
            try check(attachmentID, context)
            let retry: Data
            do {
                retry = try await downloadFile(reference, attachmentID: attachmentID, context: context)
            } catch {
                try check(attachmentID, context)
                // A failed reconciliation must not hide the upload failure
                // behind an object-not-found or transient download error.
                throw uploadError
            }
            try check(attachmentID, context)
            guard Data(SHA256.hash(data: retry)) == digest else { throw EncryptedMessagingError.conflictingRecord }
        }
        try check(attachmentID, context)
    }
    func download(attachmentID: String, context: RecordContext) async throws -> Data {
        try await download(attachmentID: attachmentID, context: context, maximumBytes: POCLimits.attachmentEnvelopeBytes)
    }
    func download(attachmentID: String, context: RecordContext, maximumBytes: Int) async throws -> Data {
        try check(attachmentID, context)
        let bytes = try await downloadFile(blob(attachmentID, context), attachmentID: attachmentID, context: context, maximumBytes: maximumBytes)
        try check(attachmentID, context)
        return bytes // Decrypt using the descriptor from the authenticated message, never relay metadata.
    }
    private func downloadFile(_ reference: StorageReference, attachmentID: String, context: RecordContext,
                              maximumBytes: Int = POCLimits.attachmentEnvelopeBytes) async throws -> Data {
        let metadata = try await reference.getMetadata()
        try check(attachmentID, context)
        guard maximumBytes > 0, maximumBytes <= POCLimits.attachmentEnvelopeBytes,
              metadata.size > 0, metadata.size <= maximumBytes else {
            throw EncryptedAttachmentError.tooLarge
        }
        let file = try EncryptedBlobTransferFile()
        try await transfer { completion in
            reference.write(toFile: file.url) { url, error in
                completion(error ?? (url == nil ? EncryptedMessagingError.invalidRecord : nil))
            }
        }
        try check(attachmentID, context)
        // The SDK moves a URLSession temporary file over our placeholder inode.
        try SharedProtectedFiles.protectFile(file.url)
        let bytes = try file.read(maximumBytes: maximumBytes)
        guard bytes.count == metadata.size else { throw EncryptedMessagingError.conflictingRecord }
        return bytes
    }
    private func transfer(_ start: (@escaping (Error?) -> Void) -> any StorageTaskManagement) async throws {
        let cancellation = EncryptedBlobTransferCancellation()
        let invalidation = session.observeInvalidation { cancellation.cancel() }
        defer { invalidation.cancel() }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                cancellation.register(start { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                })
            }
        } onCancel: { cancellation.cancel() }
        try Task.checkCancellation()
    }
    private func check(_ id: String, _ c: RecordContext) throws {
        try session.validate(c)
        guard UUID(uuidString: id)?.uuidString.lowercased() == id,
              UUID(uuidString: c.recordID)?.uuidString.lowercased() == c.recordID,
              c.kind == .message else { throw EncryptedMessagingError.invalidRecord }
    }
    private func blob(_ id: String, _ c: RecordContext) -> StorageReference {
        storage.reference(withPath: "conversations/\(c.conversationID)/encryptedBlobs/\(id)/blob")
    }
    private func validate(_ data: [String: Any]?, _ c: RecordContext, _ size: Int, _ digest: Data) throws {
        guard let data, Set(data.keys) == ["ownerId", "messageId", "keyEpoch", "revision", "byteSize", "digest", "createdAt"],
              SecureConversationSession.same(data["ownerId"] as? String ?? "", c.senderID),
              SecureConversationSession.same(data["messageId"] as? String ?? "", c.recordID),
              try SecurePairingWire.integer(data["keyEpoch"]) == UInt64(c.keyEpoch),
              try SecurePairingWire.integer(data["revision"]) == c.revision,
              try SecurePairingWire.integer(data["byteSize"]) == UInt64(size),
              data["digest"] as? String == SecurePairingWire.hex(digest), data["createdAt"] is Timestamp else {
            throw EncryptedMessagingError.conflictingRecord
        }
    }
}

/// File-backed Firebase transfer avoids a second large HTTP body/download buffer.
/// The mapped ciphertext remains valid after unlinking; its lifetime belongs to the returned Data.
@MainActor
private final class EncryptedBlobTransferFile {
    let url: URL
    private let store: EncryptedMediaTemporaryStore

    init(bytes: Data? = nil) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mines-blob-transfers", isDirectory: true)
        try SharedProtectedFiles.prepareDirectory(root)
        store = try EncryptedMediaTemporaryStore(root: root, allowsEnvelopeOverhead: true)
        url = try store.write(bytes ?? Data(), suffix: "blob")
        try SharedProtectedFiles.protectFile(url)
    }
    func read(maximumBytes: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= maximumBytes else {
            throw EncryptedAttachmentError.tooLarge
        }
        let bytes = try Data(contentsOf: url, options: .alwaysMapped)
        guard bytes.count == size else { throw EncryptedMessagingError.conflictingRecord }
        return bytes
    }
}

/// Firebase documents StorageTask as thread-safe. The lock also handles cancellation
/// arriving before the SDK has returned its upload/download handle.
private final class EncryptedBlobTransferCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: (any StorageTaskManagement)?
    private var cancelled = false
    func register(_ value: any StorageTaskManagement) {
        lock.lock()
        task = value
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { value.cancel?() }
    }
    func cancel() {
        lock.lock()
        cancelled = true
        let value = task
        lock.unlock()
        value?.cancel?()
    }
}

/// Shared image/file/video/voice resolver. No Firebase download URLs or plaintext
/// image disk cache. Temporary media files have random names and session lifetime.
@MainActor
final class EncryptedAttachmentResolver {
    private let chatImages = SessionPhotoImageCache<AttachmentContent, NativeChatPhotoImage>(
        maximumCost: 96 * 1024 * 1024, cost: NativeChatPhotoDecoding.cost
    )
    private let session: SecureConversationSession
    private let blobs: any EncryptedBlobStoring
    private let temporaryRoot: URL
    private let ciphertextCache: PersistentPhotoCiphertextCache?
    private var temporaryStore: EncryptedMediaTemporaryStore?
    private var invalidation: ServiceObservation?
    private var decrypting = false
    private var decryptWaiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []
    private var photoPreviews: [String: Data] = [:]
    private var displayCacheUse: [String: UInt64] = [:]
    private var displayCacheClock: UInt64 = 0
    private var displayCacheBytes = 0
    private static let maximumDisplayCacheBytes = 16 * 1024 * 1024
    private var previewLoads = 0
    private var previewWaiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []
    init(session: SecureConversationSession, blobs: any EncryptedBlobStoring,
         temporaryRoot: URL = FileManager.default.temporaryDirectory,
         ciphertextCache: PersistentPhotoCiphertextCache? = nil) throws {
        self.session = session; self.blobs = blobs
        self.temporaryRoot = temporaryRoot
        self.ciphertextCache = ciphertextCache
        temporaryStore = try EncryptedMediaTemporaryStore(root: temporaryRoot)
        invalidation = session.observeInvalidation { [weak self] in self?.invalidateResources() }
    }
    /// Retain authenticated descriptors for an active preview, never every thumbnail row.
    func pinAttachments(_ attachments: [AttachmentContent]) throws -> ServiceObservation {
        try session.requireActive()
        guard attachments.count <= 10 else { throw EncryptedMessagingError.invalidRecord }
        for attachment in attachments {
            guard let context = try session.attachmentContext(for: attachment.id),
                  let metadata = try session.privateAttachment(for: context),
                  attachment.storagePath == SecureConversationSession.attachmentPath(context: context, attachmentID: attachment.id),
                  SecureConversationSession.same(metadata.attachmentID, attachment.id),
                  SecureConversationSession.same(metadata.filename, attachment.fileName),
                  SecureConversationSession.same(metadata.mediaType, attachment.contentType),
                  attachment.byteSize == Int64(metadata.originalByteCount),
                  attachment.audioDurationMilliseconds == metadata.voiceDurationMilliseconds.map(Int.init) else {
                throw EncryptedMessagingError.invalidRecord
            }
        }
        return try session.pinAttachmentMetadata(attachmentIDs: attachments.map(\.id))
    }
    func decryptData(_ attachment: AttachmentContent) async throws -> Data {
        let metadataLease = try pinAttachments([attachment])
        defer { metadataLease.cancel() }
        try session.requireActive()
        try await acquireDecryptSlot()
        defer { releaseDecryptSlot() }
        try session.requireActive()
        guard let context = try session.attachmentContext(for: attachment.id),
              let m = try session.privateAttachment(for: context),
              SecureConversationSession.same(m.attachmentID, attachment.id),
              attachment.storagePath == SecureConversationSession.attachmentPath(context: context, attachmentID: attachment.id),
              SecureConversationSession.same(attachment.fileName, m.filename),
              SecureConversationSession.same(attachment.contentType, m.mediaType),
              attachment.byteSize == Int64(m.originalByteCount),
              attachment.audioDurationMilliseconds == m.voiceDurationMilliseconds.map(Int.init) else {
            throw EncryptedMessagingError.invalidRecord
        }
        let maximumBytes = m.mediaType.hasPrefix("video/") || m.mediaType.hasPrefix("image/")
            ? POCLimits.attachmentPlaintextBytes : Int(PendingShareAttachmentPolicy.maximumEncryptedNonVideoBytes)
        guard m.originalByteCount <= maximumBytes else { throw EncryptedAttachmentError.tooLarge }
        let maximumEnvelopeBytes = min(POCLimits.attachmentEnvelopeBytes, maximumBytes + 4096)
        if attachment.type == .image, m.mediaType.hasPrefix("image/") {
            return try await photoData(blobID: attachment.id, context: context, metadata: m,
                                       role: .original, maximumBytes: maximumEnvelopeBytes)
        }
        let bytes = try await blobs.download(attachmentID: attachment.id, context: context, maximumBytes: maximumEnvelopeBytes)
        guard bytes.count <= maximumEnvelopeBytes else { throw EncryptedAttachmentError.tooLarge }
        try Task.checkCancellation()
        try session.validate(context)
        let cipher = try AttachmentCipher()
        let clear = try await session.performKeyOperation { _ in try cipher.open(bytes, privateMetadata: m, expectedContext: context) }
        try Task.checkCancellation()
        try session.validate(context)
        return clear
    }
    /// A missing/invalid optional sidecar falls back to the unchanged original path.
    /// Authenticated previews are bounded and live only with this active resolver.
    func photoPreviewData(_ attachment: AttachmentContent) async throws -> Data? {
        guard attachment.type == .image else { return nil }
        let lease = try pinAttachments([attachment])
        defer { lease.cancel() }
        guard let context = try session.attachmentContext(for: attachment.id),
              let metadata = try session.privateAttachment(for: context) else { throw EncryptedMessagingError.missingAttachment }
        let id = PhotoPreviewCipher.attachmentID(for: metadata, context: context)
        try Task.checkCancellation()
        if let cached = cachedDisplay(id) { try session.validate(context); return cached }
        try await acquirePreviewSlot()
        defer { releasePreviewSlot() }
        do {
            try Task.checkCancellation()
            try session.validate(context)
            let bytes = try await photoData(blobID: id, context: context, metadata: metadata,
                                           role: .preview, maximumBytes: PhotoPreviewCipher.maximumEnvelopeBytes)
            try Task.checkCancellation()
            try session.validate(context)
            cacheDisplay(bytes, id: id)
            return bytes
        } catch {
            try Task.checkCancellation()
            try session.validate(context)
            return nil
        }
    }
    func photoRenditionData(_ attachment: AttachmentContent, rendition: PhotoRendition) async throws -> Data? {
        guard attachment.type == .image else { return nil }
        let lease = try pinAttachments([attachment])
        defer { lease.cancel() }
        guard let context = try session.attachmentContext(for: attachment.id),
              let metadata = try session.privateAttachment(for: context) else { throw EncryptedMessagingError.missingAttachment }
        let id = PhotoRenditionCipher.attachmentID(for: metadata, context: context, rendition: rendition)
        try Task.checkCancellation()
        if let cached = cachedDisplay(id) { try session.validate(context); return cached }
        try await acquirePreviewSlot()
        defer { releasePreviewSlot() }
        do {
            try Task.checkCancellation()
            try session.validate(context)
            if let cached = cachedDisplay(id) { return cached }
            let bytes = try await photoData(blobID: id, context: context, metadata: metadata,
                role: rendition == .chat ? .chat : .viewer, maximumBytes: rendition.maximumEnvelopeBytes)
            try Task.checkCancellation()
            try session.validate(context)
            cacheDisplay(bytes, id: id)
            return bytes
        } catch {
            try Task.checkCancellation()
            try session.validate(context)
            return nil
        }
    }

    /// Prefer an authenticated local copy before probing optional remote sidecars.
    /// This matters for older/HDR photos that only have an original: a warm
    /// original must not wait for two object-not-found network responses.
    func cachedPhotoDisplayData(_ attachment: AttachmentContent, rendition: PhotoRendition) async throws -> Data? {
        guard attachment.type == .image, let ciphertextCache else { return nil }
        let lease = try pinAttachments([attachment])
        defer { lease.cancel() }
        guard let context = try session.attachmentContext(for: attachment.id),
              let metadata = try session.privateAttachment(for: context),
              metadata.mediaType.hasPrefix("image/") else { throw EncryptedMessagingError.invalidRecord }
        let roles: [PersistentPhotoCiphertextCache.Role] = rendition == .chat ? [.chat, .viewer, .original] : [.viewer, .original]
        for role in roles {
            if role == .original { try await acquireDecryptSlot() }
            else { try await acquirePreviewSlot() }
            do {
                defer {
                    if role == .original { releaseDecryptSlot() }
                    else { releasePreviewSlot() }
                }
                try Task.checkCancellation()
                try session.validate(context)
                let (id, maximum) = photoBlob(role: role, metadata: metadata, context: context)
                if role != .original, let bytes = cachedDisplay(id) { return bytes }
                let key = PersistentPhotoCiphertextCache.Key(accountID: session.capsule.localAccountID,
                    context: context, metadata: metadata, blobID: id, role: role)
                let cached = await ciphertextCache.read(key, maximumBytes: maximum)
                try Task.checkCancellation()
                try session.validate(context)
                guard let envelope = cached else { continue }
                do {
                    let bytes = try await openPhotoData(envelope, context: context, metadata: metadata, role: role)
                    if role != .original { cacheDisplay(bytes, id: id) }
                    return bytes
                } catch {
                    try Task.checkCancellation()
                    try session.validate(context)
                    if Self.requiresKeyRetry(error) { throw error }
                    await ciphertextCache.remove(key)
                    try Task.checkCancellation()
                    try session.validate(context)
                }
            }
        }
        return nil
    }

    private func photoBlob(role: PersistentPhotoCiphertextCache.Role, metadata: PrivateAttachment,
                           context: RecordContext) -> (String, Int) {
        switch role {
        case .original: (metadata.attachmentID, min(POCLimits.attachmentEnvelopeBytes, POCLimits.attachmentPlaintextBytes + 4096))
        case .preview: (PhotoPreviewCipher.attachmentID(for: metadata, context: context), PhotoPreviewCipher.maximumEnvelopeBytes)
        case .chat: (PhotoRenditionCipher.attachmentID(for: metadata, context: context, rendition: .chat), PhotoRendition.chat.maximumEnvelopeBytes)
        case .viewer: (PhotoRenditionCipher.attachmentID(for: metadata, context: context, rendition: .viewer), PhotoRendition.viewer.maximumEnvelopeBytes)
        }
    }

    /// Caller owns the existing original/preview transfer slot and metadata lease.
    /// Only successfully authenticated image envelopes enter persistent storage.
    private func photoData(blobID: String, context: RecordContext, metadata: PrivateAttachment,
                           role: PersistentPhotoCiphertextCache.Role, maximumBytes: Int) async throws -> Data {
        guard metadata.mediaType.hasPrefix("image/") else { throw EncryptedMessagingError.invalidRecord }
        let key = PersistentPhotoCiphertextCache.Key(accountID: session.capsule.localAccountID,
            context: context, metadata: metadata, blobID: blobID, role: role)
        try Task.checkCancellation()
        try session.validate(context)
        if let ciphertextCache {
            let cached = await ciphertextCache.read(key, maximumBytes: maximumBytes)
            try Task.checkCancellation()
            try session.validate(context)
            if let envelope = cached {
                do { return try await openPhotoData(envelope, context: context, metadata: metadata, role: role) }
                catch {
                    try Task.checkCancellation()
                    try session.validate(context)
                    if Self.requiresKeyRetry(error) { throw error }
                    await ciphertextCache.remove(key)
                    try Task.checkCancellation()
                    try session.validate(context)
                }
            }
        }
        try Task.checkCancellation()
        try session.validate(context)
        let envelope = try await blobs.download(attachmentID: blobID, context: context, maximumBytes: maximumBytes)
        guard envelope.count <= maximumBytes else { throw EncryptedAttachmentError.tooLarge }
        let bytes = try await openPhotoData(envelope, context: context, metadata: metadata, role: role)
        if let ciphertextCache {
            await ciphertextCache.store(envelope, for: key, maximumBytes: maximumBytes)
            try Task.checkCancellation()
            try session.validate(context)
        }
        return bytes
    }

    private func openPhotoData(_ envelope: Data, context: RecordContext, metadata: PrivateAttachment,
                               role: PersistentPhotoCiphertextCache.Role) async throws -> Data {
        try Task.checkCancellation()
        try session.validate(context)
        let bytes = try await session.performKeyOperation { _ in
            switch role {
            case .original: try AttachmentCipher().open(envelope, privateMetadata: metadata, expectedContext: context)
            case .preview: try PhotoPreviewCipher.open(envelope, original: metadata, context: context)
            case .chat: try PhotoRenditionCipher.open(envelope, original: metadata, context: context, rendition: .chat)
            case .viewer: try PhotoRenditionCipher.open(envelope, original: metadata, context: context, rendition: .viewer)
            }
        }
        try Task.checkCancellation()
        try session.validate(context)
        switch role {
        case .original: break
        case .preview:
            guard EncryptedPhotoPreviewImage.isDecodable(bytes) else { throw EncryptedMediaError.unavailable }
        case .chat, .viewer:
            guard EncryptedPhotoRenditionImage.isDecodable(bytes, rendition: role == .chat ? .chat : .viewer) else {
                throw EncryptedMediaError.unavailable
            }
        }
        return bytes
    }

    private static func requiresKeyRetry(_ error: Error) -> Bool {
        error as? EncryptedMessagingError == .keyNotReady || error is KeyLifecycleError
    }
    private func cachedDisplay(_ id: String) -> Data? {
        guard let bytes = photoPreviews[id] else { return nil }
        displayCacheClock &+= 1; displayCacheUse[id] = displayCacheClock
        return bytes
    }
    private func cacheDisplay(_ bytes: Data, id: String) {
        guard bytes.count <= Self.maximumDisplayCacheBytes else { return }
        displayCacheBytes -= photoPreviews.removeValue(forKey: id)?.count ?? 0
        while displayCacheBytes + bytes.count > Self.maximumDisplayCacheBytes,
              let victim = displayCacheUse.min(by: { $0.value < $1.value })?.key {
            displayCacheBytes -= photoPreviews.removeValue(forKey: victim)?.count ?? 0
            displayCacheUse[victim] = nil
        }
        photoPreviews[id] = bytes; displayCacheBytes += bytes.count
        displayCacheClock &+= 1; displayCacheUse[id] = displayCacheClock
    }
    func temporaryURL(_ attachment: AttachmentContent) async throws -> URL {
        let data = try await decryptData(attachment)
        try session.requireActive()
        if temporaryStore == nil { temporaryStore = try EncryptedMediaTemporaryStore(root: temporaryRoot) }
        let suffix = UTType(mimeType: attachment.contentType)?.preferredFilenameExtension ?? "bin"
        guard let temporaryStore else { throw CocoaError(.fileWriteUnknown) }
        return try temporaryStore.write(data, suffix: suffix)
    }
    /// Synchronous lookup avoids a loading frame when a previously viewed row returns.
    /// The complete authenticated descriptor is the key, never an attachment ID alone.
    func cachedChatPhoto(_ attachment: AttachmentContent) -> NativeChatPhotoImage? {
        guard attachment.type == .image, (try? session.requireActive()) != nil else { return nil }
        return chatImages.image(for: attachment)
    }

    func chatPhoto(_ attachment: AttachmentContent, prefetch: Bool = false) async throws -> NativeChatPhotoImage {
        try session.requireActive()
        let image = try await chatImages.load(for: attachment, prefetch: prefetch) { [self] in
            let bytes = try await EncryptedMediaLoading.photoPreviewData(attachment, resolver: self) {
                throw EncryptedMediaError.unavailable
            }
            guard let image = await NativeChatPhotoDecoding.decode(bytes) else {
                throw URLError(.cannotDecodeContentData)
            }
            try validateActive()
            return image
        }
        try Task.checkCancellation()
        try session.requireActive()
        return image
    }

    func validateActive() throws { try session.requireActive() }
    func observeInvalidation(_ callback: @escaping () -> Void) -> ServiceObservation {
        session.observeInvalidation(callback)
    }
    func clearTemporaryFiles() { temporaryStore?.clear(); temporaryStore = nil }
    private func invalidateResources() {
        chatImages.invalidate()
        photoPreviews.removeAll(); displayCacheUse.removeAll(); displayCacheBytes = 0
        clearTemporaryFiles()
        let waiting = decryptWaiters; decryptWaiters.removeAll()
        waiting.forEach { $0.continuation.resume(throwing: EncryptedMessagingError.inactiveSession) }
        let previews = previewWaiters; previewWaiters.removeAll()
        previews.forEach { $0.continuation.resume(throwing: EncryptedMessagingError.inactiveSession) }
    }
    // Three bounded display-copy transfers may proceed while the single original-file
    // slot is occupied. Queued cancellation never consumes or leaks a preview slot.
    private func acquirePreviewSlot() async throws {
        try Task.checkCancellation()
        if previewLoads < 3 { previewLoads += 1; return }
        guard previewWaiters.count < 32 else { throw EncryptedAttachmentError.preparationBusy }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { previewWaiters.append((id, continuation)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, let index = self.previewWaiters.firstIndex(where: { $0.id == id }) else { return }
                self.previewWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
            }
        }
    }
    private func releasePreviewSlot() {
        if !previewWaiters.isEmpty { previewWaiters.removeFirst().continuation.resume() }
        else { previewLoads -= 1 }
    }
    // This bounds download/open buffers, not images retained by UI consumers.
    private func acquireDecryptSlot() async throws {
        try Task.checkCancellation()
        if !decrypting { decrypting = true; return }
        guard decryptWaiters.count < 32 else { throw EncryptedAttachmentError.preparationBusy }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { decryptWaiters.append((id, continuation)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, let index = self.decryptWaiters.firstIndex(where: { $0.id == id }) else { return }
                self.decryptWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
            }
        }
    }
    private func releaseDecryptSlot() {
        if !decryptWaiters.isEmpty { decryptWaiters.removeFirst().continuation.resume() }
        else { decrypting = false }
    }
}
