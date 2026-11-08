import Foundation
import MinesE2EE

/// Keys stay in the active registry; app Codable models contain only display content and an
/// opaque reference. Decrypted filenames are display strings, never filesystem components.
@MainActor
enum EncryptedMessageBridge {
    static func payload(from message: ChatMessage, context: RecordContext, session: SecureConversationSession) throws -> ConversationMessagePayload {
        guard SecureConversationSession.same(message.senderID, context.senderID), message.deletedAt == nil,
              message.editedAt == nil || context.revision > 1 else { throw EncryptedMessagingError.invalidRecord }
        var group: ContentPhotoGroup?
        if let id = message.attachmentGroupID, let index = message.attachmentGroupIndex, let count = message.attachmentGroupCount {
            group = try ContentPhotoGroup(id: id.uuidString.lowercased(), index: index, count: count)
        } else if message.attachmentGroupID != nil || message.attachmentGroupIndex != nil || message.attachmentGroupCount != nil {
            throw EncryptedMessagingError.invalidRecord
        }
        var privateAttachment: PrivateAttachment?
        if let attachment = message.attachment {
            guard let metadata = try session.privateAttachment(for: context),
                  SecureConversationSession.same(metadata.attachmentID, attachment.id),
                  attachment.storagePath == SecureConversationSession.attachmentPath(context: context, attachmentID: metadata.attachmentID) else {
                throw EncryptedMessagingError.missingAttachment
            }
            privateAttachment = metadata
        }
        let location = try message.liveLocation.map {
            try LegacyMessageLocation(latitude: $0.latitude, longitude: $0.longitude,
                                      updatedAtMilliseconds: milliseconds($0.updatedAt),
                                      expiresAtMilliseconds: $0.expiresAt.map(milliseconds))
        }
        guard let kind = ContentMessageKind.allCases.first(where: { appKind($0) == message.kind }) else { throw EncryptedMessagingError.invalidRecord }
        return try ConversationMessagePayload(kind: kind, body: message.body,
                                              replyToID: message.replyToID?.uuidString.lowercased(), photoGroup: group,
                                              attachment: privateAttachment, attachmentType: message.attachment.map { contentType($0.type) },
                                              legacyLocation: location, deliveryMode: message.resolvedDeliveryMode == .quiet ? .quiet : .normal)
    }

    static func message(from payload: ConversationMessagePayload, record: EncryptedMessageRecord,
                        session: SecureConversationSession, registerAttachment: Bool = true) throws -> ChatMessage {
        try session.validate(record.context)
        guard let id = UUID(uuidString: record.context.recordID) else { throw EncryptedMessagingError.invalidRecord }
        var attachment: AttachmentContent?
        if let metadata = payload.attachment, let type = payload.attachmentType {
            if registerAttachment { try session.registerAttachment(metadata, context: record.context) }
            attachment = AttachmentContent(id: metadata.attachmentID, type: appType(type),
                                           storagePath: SecureConversationSession.attachmentPath(context: record.context, attachmentID: metadata.attachmentID),
                                           fileName: metadata.filename, contentType: metadata.mediaType, byteSize: Int64(metadata.originalByteCount),
                                           audioDurationMilliseconds: metadata.voiceDurationMilliseconds.map(Int.init))
        }
        return ChatMessage(id: id, senderID: record.context.senderID, kind: appKind(payload.kind), body: payload.body,
                           createdAt: record.createdAt, editedAt: record.editedAt, deletedAt: record.deletedAt,
                           deliveryState: record.hasPendingWrites ? .sending : .sent,
                           replyToID: payload.replyToID.flatMap(UUID.init(uuidString:)), attachment: attachment,
                           attachmentGroupID: payload.photoGroup.flatMap { UUID(uuidString: $0.id) },
                           attachmentGroupIndex: payload.photoGroup?.index, attachmentGroupCount: payload.photoGroup?.count,
                           liveLocation: payload.legacyLocation.map {
                               LiveLocationContent(latitude: $0.latitude, longitude: $0.longitude,
                                                   updatedAt: date($0.updatedAtMilliseconds), expiresAt: $0.expiresAtMilliseconds.map(date))
                           }, deliveryMode: payload.deliveryMode == .quiet ? .quiet : nil)
    }
    static func milliseconds(_ date: Date) throws -> UInt64 {
        let value = date.timeIntervalSince1970 * 1000
        guard value.isFinite, value >= 0, value <= Double(ContentLimits.maximumTimestampMilliseconds) else { throw ContentError.invalidTimestamp }
        return UInt64(value.rounded(.down))
    }
    static func date(_ milliseconds: UInt64) -> Date { Date(timeIntervalSince1970: Double(milliseconds) / 1000) }
    private static func appKind(_ value: ContentMessageKind) -> MessageKind {
        switch value { case .text: .text; case .link: .link; case .attachment: .attachment; case .voice: .voice; case .liveLocation: .liveLocation }
    }
    private static func contentType(_ value: AttachmentType) -> ContentAttachmentType {
        switch value { case .image: .image; case .video: .video; case .audio: .audio; case .file: .file }
    }
    private static func appType(_ value: ContentAttachmentType) -> AttachmentType {
        switch value { case .image: .image; case .video: .video; case .audio: .audio; case .file: .file }
    }
}
