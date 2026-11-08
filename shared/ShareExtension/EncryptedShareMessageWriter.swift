import CryptoKit
import Foundation
import MinesE2EE
import UniformTypeIdentifiers

enum ShareDeliveryError: LocalizedError {
    case keyUnavailable
    case encryptionMismatch
    case conflictingItem
    case firebaseUnavailable
    case notSignedIn
    case noConversation
    case invalidPayload
    case server(statusCode: Int, detail: String)

    var errorDescription: String? {
        switch self {
        case .keyUnavailable:
            "The conversation key is not available. Open Peapod and wait for key sync before sharing."
        case .encryptionMismatch:
            "The conversation no longer matches its trusted encryption state. Open Peapod before sharing."
        case .conflictingItem:
            "This queued share conflicts with an existing encrypted item and cannot be recreated."
        case .firebaseUnavailable:
            "Peapod could not start its secure sharing service."
        case .notSignedIn:
            "Open Peapod and sign in before sharing."
        case .noConversation:
            "Open your conversation in Peapod before sharing."
        case .invalidPayload:
            "This item cannot be sent directly from the Share Sheet."
        case let .server(statusCode, detail):
            "The item could not be sent (server \(statusCode)): \(detail)"
        }
    }
}

/// Pure durable preparation shared by the extension and focused tests. This receives a key only
/// through a freshly validated native lease. It performs no network requests or plaintext queue
/// writes. Retrying a known ID compares the original authenticated content and reuses exact bytes.
enum EncryptedShareMessageWriter {
    /// Logical preparation budget; physical extension memory still requires device measurement.
    static let maximumBatchCiphertextBytes = ShareExtensionLimits.maximumCiphertextBytes
    @discardableResult
    static func enqueue(_ share: PendingShare, target: SharedConversationTarget, epochKey: SymmetricKey,
                        outbox: DurableCiphertextOutbox, attachmentPlaintext: Data? = nil) throws -> UUID {
        let request = try prepare(share, target: target, epochKey: epochKey, outbox: outbox, attachmentPlaintext: attachmentPlaintext)
        guard request.envelope.count + 4 + request.attachments.reduce(0, { $0 + $1.bytes.count + $1.attachmentID.utf8.count + 8 }) <= maximumBatchCiphertextBytes else { throw OutboxError.capacityExceeded }
        _ = try outbox.enqueueBatch([request], scope: scope(target), epochKey: epochKey)
        return share.id
    }

    @discardableResult
    static func enqueueBatch(_ shares: [PendingShare], target: SharedConversationTarget, epochKey: SymmetricKey,
                             outbox: DurableCiphertextOutbox, attachmentURLs: [UUID: URL]) throws -> [UUID] {
        guard !shares.isEmpty, shares.count <= 11 else { throw ShareDeliveryError.invalidPayload }
        let budget = min(maximumBatchCiphertextBytes, outbox.limits.maximumPendingBytes)
        var declaredBytes = shares.count * 4096
        var attachmentBytes = 0
        for share in shares {
            if let url = attachmentURLs[share.id] {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                attachmentBytes = try ShareExtensionLimits.admitAttachment(size, used: attachmentBytes)
                declaredBytes += size
            }
            declaredBytes += (share.text?.utf8.count ?? 0) * 2
            guard declaredBytes <= budget else { throw OutboxError.capacityExceeded }
        }
        var requests: [OutboxEnqueueRequest] = []; var actualBytes = 0
        for share in shares {
            let input = try attachmentURLs[share.id].map(readAttachment)
            guard actualBytes + (input?.count ?? 0) + (share.text?.utf8.count ?? 0) * 2 + 4096 <= budget else { throw OutboxError.capacityExceeded }
            let request = try prepare(share, target: target, epochKey: epochKey, outbox: outbox, attachmentPlaintext: input)
            actualBytes += request.envelope.count + 4 + request.attachments.reduce(0) { $0 + $1.bytes.count + $1.attachmentID.utf8.count + 8 }
            guard actualBytes <= budget else { throw OutboxError.capacityExceeded }
            requests.append(request)
        }
        _ = try outbox.enqueueBatch(requests, scope: scope(target), epochKey: epochKey)
        return shares.map(\.id)
    }
    private static func scope(_ target: SharedConversationTarget) throws -> OutboxScope {
        guard let epoch = target.keyEpoch else { throw ShareDeliveryError.encryptionMismatch }
        return try OutboxScope(accountID: target.accountID, conversationID: target.conversationID, keyEpoch: epoch)
    }
    private static func prepare(_ share: PendingShare, target: SharedConversationTarget, epochKey: SymmetricKey,
                                outbox: DurableCiphertextOutbox, attachmentPlaintext: Data?) throws -> OutboxEnqueueRequest {
        guard target.mode == .encrypted, let epoch = target.keyEpoch,
              share.conversationOwnerID.map({ Data($0.utf8) == Data(target.accountID.utf8) }) == true,
              share.targetConversationID.map({ Data($0.utf8) == Data(target.conversationID.utf8) }) == true else { throw PendingShareStoreError.accountMismatch }
        let context = try RecordContext(conversationID: target.conversationID, recordID: share.id.uuidString.lowercased(), senderID: target.accountID,
                                        keyEpoch: epoch, revision: 1)
        let scope = try OutboxScope(accountID: target.accountID, conversationID: target.conversationID, keyEpoch: epoch)
        let body = share.text ?? ""
        let group: ContentPhotoGroup?
        if let id = share.attachmentGroupID, let index = share.attachmentGroupIndex, let count = share.attachmentGroupCount {
            group = try ContentPhotoGroup(id: id.uuidString.lowercased(), index: index, count: count)
        } else if share.attachmentGroupID != nil || share.attachmentGroupIndex != nil || share.attachmentGroupCount != nil { throw ShareDeliveryError.invalidPayload }
        else { group = nil }
        let delivery: ContentDeliveryMode = share.deliveryMode == .quiet ? .quiet : .normal
        if let pending = try outbox.load(scope: scope, recordID: context.recordID, epochKey: epochKey) {
            guard pending.context == context else { throw ShareDeliveryError.conflictingItem }
            let original = try ConversationMessageCipher.open(pending.envelope, expectedContext: context, epochKey: epochKey)
            guard original.body.utf8.elementsEqual(body.utf8), original.replyToID == nil, original.legacyLocation == nil, original.deliveryMode == delivery, original.photoGroup == group else { throw ShareDeliveryError.conflictingItem }
            switch share.kind {
            case .text, .url:
                guard original.kind == (share.kind == .url ? .link : .text), original.attachment == nil, attachmentPlaintext == nil else { throw ShareDeliveryError.conflictingItem }
            case .image, .movie, .file:
                guard let input = attachmentPlaintext, let metadata = original.attachment, pending.attachments.count == 1,
                      original.kind == .attachment, original.attachmentType == attachmentType(share),
                      metadata.filename.utf8.elementsEqual(filename(share).utf8), metadata.mediaType.utf8.elementsEqual(mediaType(share).utf8),
                      pending.attachments[0].attachmentID.utf8.elementsEqual(metadata.attachmentID.utf8),
                      try AttachmentCipher().open(pending.attachments[0].bytes, privateMetadata: metadata, expectedContext: context) == input else { throw ShareDeliveryError.conflictingItem }
            }
            return try OutboxEnqueueRequest(envelope: pending.envelope, attachments: pending.attachments, context: context)
        }
        // An acknowledged item must be reconciled by the app using its authenticated remote
        // record, never recreated with a fresh nonce/key or treated as delivered from HTTP 409.
        guard try outbox.acknowledgedRevision(scope: scope, recordID: context.recordID) == nil else { throw ShareDeliveryError.conflictingItem }
        let payload: ConversationMessagePayload
        let blobs: [OutboxAttachment]
        switch share.kind {
        case .text, .url:
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, attachmentPlaintext == nil, group == nil else { throw ShareDeliveryError.invalidPayload }
            payload = try ConversationMessagePayload(kind: share.kind == .url ? .link : .text, body: body, deliveryMode: delivery)
            blobs = []
        case .image, .movie, .file:
            guard let input = attachmentPlaintext else { throw PendingShareStoreError.missingStagedFile }
            try ShareExtensionLimits.validateAttachment(input.count)
            let sealed = try AttachmentCipher().seal(input, context: context, attachmentID: UUID().uuidString.lowercased(),
                                                     filename: filename(share), mediaType: mediaType(share))
            payload = try ConversationMessagePayload(kind: .attachment, body: body, photoGroup: group,
                                                     attachment: sealed.privateMetadata, attachmentType: attachmentType(share), deliveryMode: delivery)
            blobs = [try OutboxAttachment(attachmentID: sealed.privateMetadata.attachmentID, bytes: sealed.bytes)]
        }
        let envelope = try ConversationMessageCipher.seal(payload, context: context, epochKey: epochKey)
        return try OutboxEnqueueRequest(envelope: envelope, attachments: blobs, context: context)
    }
    static func readAttachment(at url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size <= UInt64(ShareExtensionLimits.maximumAttachmentBytes) else { throw PendingShareStoreError.attachmentTooLarge(maximumBytes: Int64(ShareExtensionLimits.maximumAttachmentBytes)) }
        try handle.seek(toOffset: 0)
        let data = try handle.read(upToCount: ShareExtensionLimits.maximumAttachmentBytes + 1) ?? Data()
        try PendingShareAttachmentPolicy.validate(byteSize: Int64(data.count), maximumBytes: Int64(ShareExtensionLimits.maximumAttachmentBytes))
        guard UInt64(data.count) == size else { throw ShareDeliveryError.invalidPayload }; return data
    }
    private static func filename(_ share: PendingShare) -> String { share.originalFileName ?? "Shared file" }
    private static func mediaType(_ share: PendingShare) -> String {
        share.contentTypeIdentifier.flatMap(UTType.init)?.preferredMIMEType ?? "application/octet-stream"
    }
    private static func attachmentType(_ share: PendingShare) -> ContentAttachmentType {
        switch share.kind {
        case .image: .image
        case .movie: .video
        default: share.contentTypeIdentifier.flatMap(UTType.init)?.conforms(to: .audio) == true ? .audio : .file
        }
    }
}

/// A legacy create conflict proves nothing by itself. Only the original complete record matches.
/// This policy never authorizes an encrypted/floor account to use a plaintext transport.
enum LegacyShareReplayPolicy {
    static func matches(share: PendingShare, userID: String, existing: [String: Any]) -> Bool {
        guard let fields = existing["fields"] as? [String: Any],
              Set(fields.keys) == Set(["senderId", "clientId", "type", "text", "createdAt"]),
              string(fields["senderId"])?.utf8.elementsEqual(userID.utf8) == true,
              string(fields["clientId"]) == share.id.uuidString,
              string(fields["type"]) == (share.kind == .url ? "link" : "text"),
              string(fields["text"])?.utf8.elementsEqual((share.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").utf8) == true,
              let timestamp = fields["createdAt"] as? [String: Any], timestamp.count == 1,
              let value = timestamp["timestampValue"] as? String, value.utf8.count <= 128,
              validTimestamp(value) else { return false }
        return true
    }
    private static func validTimestamp(_ value: String) -> Bool {
        let fractional = ISO8601DateFormatter(); fractional.formatOptions.insert(.withFractionalSeconds)
        return ISO8601DateFormatter().date(from: value) != nil || fractional.date(from: value) != nil
    }
    private static func string(_ field: Any?) -> String? {
        guard let object = field as? [String: Any], object.count == 1 else { return nil }
        return object["stringValue"] as? String
    }
}

/// Matches the canonical backend profile document; old spellings never select a destination.
enum ShareRoutingWire {
    static func activeConversationID(from profile: [String: Any]) -> String? {
        guard let fields = profile["fields"] as? [String: Any],
              let field = fields["activeConversationId"] as? [String: Any], field.count == 1,
              let id = field["stringValue"] as? String, !id.isEmpty, id.utf8.count <= 256 else { return nil }
        return id
    }
}
