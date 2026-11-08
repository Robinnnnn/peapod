@preconcurrency import FirebaseFirestore
@preconcurrency import FirebaseStorage
import Foundation
import UniformTypeIdentifiers

@MainActor
protocol AttachmentProviding: AnyObject {
    func upload(
        _ share: PendingShare,
        messageID: UUID,
        conversationID: String,
        ownerID: String
    ) async throws -> AttachmentContent
}

@MainActor
final class LocalAttachmentService: AttachmentProviding {
    func upload(
        _ share: PendingShare,
        messageID: UUID,
        conversationID: String,
        ownerID: String
    ) async throws -> AttachmentContent {
        let url = try PendingShareStore.stagedFileURL(for: share)
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        let byteSize = Int64(values.fileSize ?? 0)
        try PendingShareAttachmentPolicy.validate(byteSize: byteSize,
            maximumBytes: PendingShareAttachmentPolicy.maximumBytes(for: share.kind, mode: .legacy))
        return AttachmentContent(
            id: messageID.uuidString,
            type: Self.attachmentType(for: share),
            storagePath: nil,
            fileName: share.originalFileName ?? url.lastPathComponent,
            contentType: Self.contentType(for: share, url: url),
            byteSize: byteSize,
            audioDurationMilliseconds: share.voiceMessageDuration.map {
                Int(($0 * 1_000).rounded())
            }
        )
    }

    /// Preserve photo/movie admission when selected through Files or drag/drop.
    static func fileKind(for contentType: UTType?) -> PendingShare.Kind {
        if contentType?.conforms(to: .movie) == true { return .movie }
        if contentType?.conforms(to: .image) == true { return .image }
        return .file
    }

    static func attachmentType(
        for share: PendingShare
    ) -> AttachmentType {
        switch share.kind {
        case .image:
            return .image
        case .movie:
            return .video
        default:
            return share.isVoiceMessage ? .audio : .file
        }
    }

    static func contentType(
        for share: PendingShare,
        url: URL
    ) -> String {
        if
            let identifier = share.contentTypeIdentifier,
            let type = UTType(identifier),
            let mimeType = type.preferredMIMEType
        {
            return mimeType
        }
        return UTType(filenameExtension: url.pathExtension)?
            .preferredMIMEType ?? "application/octet-stream"
    }
}

struct AttachmentUploadRecord: Equatable, Sendable {
    let ownerID: String
    let messageID: String
    let storagePath: String
    let fileName: String
    let contentType: String
    let byteSize: Int64
    let audioDurationMilliseconds: Int?
}

struct AttachmentUploadBlob: Equatable, Sendable {
    let byteSize: Int64
    let contentType: String?
}

enum AttachmentUploadReplayState: Equatable, Sendable {
    case missing
    case matching
    case conflicting
}

enum AttachmentUploadReplayPolicy {
    static func metadataState(
        existing: AttachmentUploadRecord?,
        expected: AttachmentUploadRecord
    ) -> AttachmentUploadReplayState {
        guard let existing else { return .missing }
        return existing == expected ? .matching : .conflicting
    }

    static func blobState(
        existing: AttachmentUploadBlob?,
        expected: AttachmentUploadRecord
    ) -> AttachmentUploadReplayState {
        guard let existing else { return .missing }
        guard
            existing.byteSize == expected.byteSize,
            existing.contentType == expected.contentType
        else {
            return .conflicting
        }
        return .matching
    }
}

@MainActor
protocol AttachmentUploadStoring: AnyObject {
    func metadataState(
        for record: AttachmentUploadRecord,
        conversationID: String
    ) async throws -> AttachmentUploadReplayState

    func createMetadata(
        for record: AttachmentUploadRecord,
        conversationID: String
    ) async throws

    func blobState(
        for record: AttachmentUploadRecord
    ) async throws -> AttachmentUploadReplayState

    func uploadBlob(
        from localURL: URL,
        record: AttachmentUploadRecord
    ) async throws -> AttachmentUploadBlob
}

@MainActor
final class FirebaseAttachmentService: AttachmentProviding {
    private let uploadStore: any AttachmentUploadStoring
    private let stagedFileURL: (PendingShare) throws -> URL
    private let requireLegacyRoute: (String, String) throws -> Void

    init(
        database: Firestore = Firestore.firestore(),
        storage: Storage = Storage.storage()
    ) {
        uploadStore = FirebaseAttachmentUploadStore(
            database: database,
            storage: storage
        )
        stagedFileURL = PendingShareStore.stagedFileURL
        requireLegacyRoute = { conversation, account in try LegacyContentWriteGuard.require(conversationID: conversation, accountID: account) }
    }

    init(
        uploadStore: any AttachmentUploadStoring,
        stagedFileURL: @escaping (PendingShare) throws -> URL,
        requireLegacyRoute: @escaping (String, String) throws -> Void = { _, _ in }
    ) {
        self.uploadStore = uploadStore
        self.stagedFileURL = stagedFileURL
        self.requireLegacyRoute = requireLegacyRoute
    }

    func upload(
        _ share: PendingShare,
        messageID: UUID,
        conversationID: String,
        ownerID: String
    ) async throws -> AttachmentContent {
        try requireLegacyRoute(conversationID, ownerID)
        let localURL = try stagedFileURL(share)
        let values = try localURL.resourceValues(forKeys: [.fileSizeKey])
        let byteSize = Int64(values.fileSize ?? 0)
        try PendingShareAttachmentPolicy.validate(byteSize: byteSize,
            maximumBytes: PendingShareAttachmentPolicy.maximumBytes(for: share.kind, mode: .legacy))

        // The durable outbox ID is also the message and attachment ID. A retry
        // therefore resumes the same upload instead of creating orphan blobs
        // or duplicate message metadata.
        let attachmentID = messageID.uuidString
        let fileName = safeFileName(
            share.originalFileName ?? localURL.lastPathComponent
        )
        let storagePath = """
        conversations/\(conversationID)/attachments/\(attachmentID)/\(fileName)
        """
        let contentType = LocalAttachmentService.contentType(
            for: share,
            url: localURL
        )
        let attachment = AttachmentContent(
            id: attachmentID,
            type: LocalAttachmentService.attachmentType(for: share),
            storagePath: storagePath,
            fileName: fileName,
            contentType: contentType,
            byteSize: byteSize,
            audioDurationMilliseconds: share.voiceMessageDuration.map {
                Int(($0 * 1_000).rounded())
            }
        )

        let record = AttachmentUploadRecord(
            ownerID: ownerID,
            messageID: attachmentID,
            storagePath: storagePath,
            fileName: fileName,
            contentType: contentType,
            byteSize: byteSize,
            audioDurationMilliseconds:
                attachment.audioDurationMilliseconds
        )
        switch try await uploadStore.metadataState(
            for: record,
            conversationID: conversationID
        ) {
        case .missing:
            try requireLegacyRoute(conversationID, ownerID)
            try await uploadStore.createMetadata(
                for: record,
                conversationID: conversationID
            )
        case .matching:
            break
        case .conflicting:
            throw AttachmentError.conflictingQueuedItem
        }

        switch try await uploadStore.blobState(for: record) {
        case .matching:
            return attachment
        case .missing:
            break
        case .conflicting:
            throw AttachmentError.conflictingQueuedItem
        }

        try requireLegacyRoute(conversationID, ownerID)
        let uploadedBlob: AttachmentUploadBlob
        do {
            uploadedBlob = try await uploadStore.uploadBlob(
                from: localURL,
                record: record
            )
        } catch let uploadError {
            // Storage may commit the object before the client receives the
            // acknowledgement. Keep the Firestore metadata so a retry remains
            // authorized under the create-only Storage rules, and reconcile
            // immediately when the committed blob is already visible.
            let replayState = try? await uploadStore.blobState(for: record)
            if replayState == .matching {
                return attachment
            }
            if replayState == .conflicting {
                throw AttachmentError.conflictingQueuedItem
            }
            throw uploadError
        }
        guard
            AttachmentUploadReplayPolicy.blobState(
                existing: uploadedBlob,
                expected: record
            ) == .matching
        else {
            throw AttachmentError.conflictingQueuedItem
        }
        return attachment
    }

    private func safeFileName(_ proposed: String) -> String {
        let lastComponent = URL(fileURLWithPath: proposed).lastPathComponent
        return lastComponent.isEmpty ? "attachment" : lastComponent
    }
}

@MainActor
private final class FirebaseAttachmentUploadStore:
    AttachmentUploadStoring
{
    private let database: Firestore
    private let storage: Storage

    init(database: Firestore, storage: Storage) {
        self.database = database
        self.storage = storage
    }

    func metadataState(
        for record: AttachmentUploadRecord,
        conversationID: String
    ) async throws -> AttachmentUploadReplayState {
        let snapshot = try await metadataDocument(
            conversationID: conversationID,
            attachmentID: record.messageID
        ).getDocument(source: .server)
        guard snapshot.exists else { return .missing }
        guard
            let data = snapshot.data(),
            let existing = Self.record(from: data)
        else {
            return .conflicting
        }
        return AttachmentUploadReplayPolicy.metadataState(
            existing: existing,
            expected: record
        )
    }

    func createMetadata(
        for record: AttachmentUploadRecord,
        conversationID: String
    ) async throws {
        var data: [String: Any] = [
            "ownerId": record.ownerID,
            "messageId": record.messageID,
            "storagePath": record.storagePath,
            "fileName": record.fileName,
            "contentType": record.contentType,
            "byteSize": record.byteSize,
            "createdAt": FieldValue.serverTimestamp(),
        ]
        if let duration = record.audioDurationMilliseconds {
            data["audioDurationMs"] = duration
        }
        try await metadataDocument(
            conversationID: conversationID,
            attachmentID: record.messageID
        ).setData(data)
    }

    func blobState(
        for record: AttachmentUploadRecord
    ) async throws -> AttachmentUploadReplayState {
        do {
            let metadata = try await storage
                .reference(withPath: record.storagePath)
                .getMetadata()
            return AttachmentUploadReplayPolicy.blobState(
                existing: AttachmentUploadBlob(
                    byteSize: metadata.size,
                    contentType: metadata.contentType
                ),
                expected: record
            )
        } catch let error as NSError
        where error.domain == StorageErrorDomain
            && error.code == StorageErrorCode.objectNotFound.rawValue
        {
            return .missing
        }
    }

    func uploadBlob(
        from localURL: URL,
        record: AttachmentUploadRecord
    ) async throws -> AttachmentUploadBlob {
        let metadata = StorageMetadata()
        metadata.contentType = record.contentType
        metadata.customMetadata = [
            "ownerId": record.ownerID,
            "attachmentId": record.messageID,
        ]
        let uploaded = try await storage
            .reference(withPath: record.storagePath)
            .putFileAsync(from: localURL, metadata: metadata)
        return AttachmentUploadBlob(
            byteSize: uploaded.size,
            contentType: uploaded.contentType
        )
    }

    private func metadataDocument(
        conversationID: String,
        attachmentID: String
    ) -> DocumentReference {
        database
            .collection("conversations")
            .document(conversationID)
            .collection("attachments")
            .document(attachmentID)
    }

    private static func record(
        from data: [String: Any]
    ) -> AttachmentUploadRecord? {
        guard
            let ownerID = data["ownerId"] as? String,
            let messageID = data["messageId"] as? String,
            let storagePath = data["storagePath"] as? String,
            let fileName = data["fileName"] as? String,
            let contentType = data["contentType"] as? String,
            let byteSize = (data["byteSize"] as? NSNumber)?.int64Value
        else {
            return nil
        }
        let duration: Int?
        if let rawDuration = data["audioDurationMs"] {
            guard let number = rawDuration as? NSNumber else { return nil }
            duration = number.intValue
        } else {
            duration = nil
        }
        return AttachmentUploadRecord(
            ownerID: ownerID,
            messageID: messageID,
            storagePath: storagePath,
            fileName: fileName,
            contentType: contentType,
            byteSize: byteSize,
            audioDurationMilliseconds: duration
        )
    }
}

enum AttachmentError: LocalizedError {
    case conflictingQueuedItem

    var errorDescription: String? {
        "This queued attachment conflicts with an earlier upload. Remove it and share the item again."
    }
}
