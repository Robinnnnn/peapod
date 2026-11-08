import CryptoKit
import Foundation
import MinesE2EE

enum EncryptedMessagingError: LocalizedError, Equatable {
    case inactiveSession, untrustedConversation, keyNotReady, invalidRecord, historyLimit, conflictingRecord, unsupportedEdit, missingAttachment, messageNoLongerEditable
    var errorDescription: String? {
        switch self {
        case .inactiveSession: "This encrypted conversation session is no longer active."
        case .untrustedConversation: "The conversation does not match the trusted pairing."
        case .keyNotReady: "The conversation key is not available yet."
        case .invalidRecord: "An encrypted record could not be authenticated or decoded."
        case .historyLimit: "The encrypted history exceeds the supported loading limit."
        case .conflictingRecord: "This message conflicts with an existing encrypted revision."
        case .unsupportedEdit: "Only existing text and link messages can be edited."
        case .missingAttachment: "The encrypted attachment is not prepared for this message."
        case .messageNoLongerEditable: "This message can no longer be edited."
        }
    }
}

/// Authenticated pairing supplies the capsule; server routing only confirms the same scope.
struct SecureConversationBinding: Sendable {
    let conversationID: String
    let encryption: String
    let keyEpoch: UInt32
    let members: [String]
    let isActive: Bool
}

/// Routing only: unlike StoredConversationCapsule, this snapshot contains no epoch key.
struct SecureConversationRouting: Sendable {
    let localAccountID: String
    let creatorID: String
    let recipientID: String
    let conversationID: String
    let keyEpoch: UInt32
    let suite: String
    var scope: KeyScope { KeyScope(accountID: localAccountID, conversationID: conversationID, epoch: keyEpoch) }
    init(_ capsule: StoredConversationCapsule) {
        localAccountID = capsule.localAccountID; creatorID = capsule.creatorID; recipientID = capsule.recipientID
        conversationID = capsule.conversationID; keyEpoch = capsule.keyEpoch; suite = capsule.suite
    }
}

@MainActor
final class SecureConversationSession {
    let capsule: SecureConversationRouting
    private let expectedKeyCommitment: Data
    private let controller: KeyReadinessController
    private let isCurrentSession: @MainActor () -> Bool
    private var token: KeySessionToken?
    private var invalidated = false
    private var activating = false
    private var invalidationCallbacks: [UUID: () -> Void] = [:]
    private struct AttachmentContextID: Hashable {
        let conversation: Data; let record: Data; let sender: Data; let kind: String
        let epoch: UInt32; let revision: UInt64
        init(_ context: RecordContext) {
            conversation = Data(context.conversationID.utf8); record = Data(context.recordID.utf8)
            sender = Data(context.senderID.utf8); kind = context.kind.rawValue
            epoch = context.keyEpoch; revision = context.revision
        }
    }
    private struct AttachmentEntry {
        let context: RecordContext
        let metadata: PrivateAttachment
        var bytes: Data?
        var previewBytes: Data?
        var renditionBytes: [PhotoRendition: Data] = [:]
    }
    private var attachments: [Data: AttachmentEntry] = [:]
    private var attachmentOwners: [UUID: Set<Data>] = [:]
    private var attachmentContexts: [AttachmentContextID: Data] = [:]
    private var attachmentUse: [Data: Int] = [:]
    private var attachmentClock = 0

    init(capsule: StoredConversationCapsule, pinnedReader: PinnedConversationCapsuleReader,
         isCurrentSession: @escaping @MainActor () -> Bool) {
        self.capsule = SecureConversationRouting(capsule)
        expectedKeyCommitment = capsule.expectedKeyCommitment
        controller = KeyReadinessController(reader: pinnedReader)
        self.isCurrentSession = isCurrentSession
    }

    /// Dependency injection for focused lifecycle tests. Production must use the pinned reader.
    init(capsule: StoredConversationCapsule, controller: KeyReadinessController,
         isCurrentSession: @escaping @MainActor () -> Bool) {
        self.capsule = SecureConversationRouting(capsule)
        expectedKeyCommitment = capsule.expectedKeyCommitment; self.controller = controller; self.isCurrentSession = isCurrentSession
    }

    func activate(serverBinding: SecureConversationBinding) async throws {
        guard !invalidated, isCurrentSession(), token == nil, !activating else { throw EncryptedMessagingError.inactiveSession }
        guard serverBinding.isActive, Self.same(serverBinding.conversationID, capsule.conversationID),
              Self.same(serverBinding.encryption, capsule.suite), serverBinding.keyEpoch == capsule.keyEpoch,
              serverBinding.members.count == 2,
              Set(serverBinding.members.map { Data($0.utf8) }) == Set([Data(capsule.creatorID.utf8), Data(capsule.recipientID.utf8)]) else {
            throw EncryptedMessagingError.untrustedConversation
        }
        activating = true
        defer { activating = false }
        let activated = try await controller.activate(TrustedKeyDescriptor(scope: capsule.scope, expectedKeyCommitment: expectedKeyCommitment))
        guard !invalidated, isCurrentSession() else {
            await controller.signOut()
            throw EncryptedMessagingError.inactiveSession
        }
        token = activated
    }

    func requireActive(conversationID: String? = nil, accountID: String? = nil) throws {
        guard !invalidated, token != nil, isCurrentSession() else {
            invalidate()
            throw EncryptedMessagingError.inactiveSession
        }
        if let conversationID, !Self.same(conversationID, capsule.conversationID) { throw EncryptedMessagingError.untrustedConversation }
        if let accountID, !Self.same(accountID, capsule.localAccountID) { throw EncryptedMessagingError.untrustedConversation }
    }

    func validateActive() throws { try requireActive() }

    func makeContext(recordID: String, senderID: String? = nil, kind: RecordKind = .message, revision: UInt64 = 1) throws -> RecordContext {
        try context(recordID: recordID, senderID: senderID, kind: kind, revision: revision)
    }

    func validate(_ context: RecordContext) throws {
        try requireActive(conversationID: context.conversationID)
        guard context.keyEpoch == capsule.keyEpoch,
              [capsule.creatorID, capsule.recipientID].contains(where: { Self.same($0, context.senderID) }),
              context.revision <= 9_007_199_254_740_991 else { throw EncryptedMessagingError.invalidRecord }
    }

    func context(recordID: String, senderID: String? = nil, kind: RecordKind = .message, revision: UInt64 = 1) throws -> RecordContext {
        try requireActive()
        let context = try RecordContext(conversationID: capsule.conversationID, recordID: recordID,
                                        senderID: senderID ?? capsule.localAccountID, kind: kind,
                                        keyEpoch: capsule.keyEpoch, revision: revision)
        try validate(context)
        return context
    }

    /// Each operation gets a fresh pinned read. No asynchronous work may escape this closure.
    func performKeyOperation<T: Sendable>(_ operation: @escaping @Sendable (SymmetricKey) throws -> T) async throws -> T {
        try requireActive()
        guard let token else { throw EncryptedMessagingError.inactiveSession }
        let readiness = await controller.read(token: token)
        try requireActive()
        guard case .ready(let lease) = readiness else {
            switch readiness {
            case .conflictingExpectedKey, .closedConversation, .staleSession, .signedOut, .invalidBytes:
                invalidate()
            default: break // An unavailable native Keychain may become readable again.
            }
            throw EncryptedMessagingError.keyNotReady
        }
        do {
            let result = try await controller.useKey(lease) { key, _ in try operation(key) }
            try requireActive()
            return result
        } catch let error as KeyLifecycleError {
            switch error {
            case .conflictingExpectedKey, .closedConversation, .staleSession, .invalidKey: invalidate()
            case .invalidDescriptor: break
            }
            throw error
        }
    }

    func invalidate() {
        guard !invalidated else { return }
        invalidated = true; token = nil; attachments.removeAll(); attachmentOwners.removeAll(); attachmentUse.removeAll(); attachmentContexts.removeAll()
        let callbacks = Array(invalidationCallbacks.values)
        invalidationCallbacks.removeAll()
        callbacks.forEach { $0() }
        let controller = controller
        Task { await controller.signOut() }
    }

    func observeInvalidation(_ callback: @escaping () -> Void) -> ServiceObservation {
        let id = UUID()
        invalidationCallbacks[id] = callback
        return ServiceObservation { [weak self] in self?.invalidationCallbacks[id] = nil }
    }

    func registerAttachment(_ metadata: PrivateAttachment, context: RecordContext, sealedBytes: Data? = nil, previewBytes: Data? = nil, renditionBytes: [PhotoRendition: Data] = [:]) throws {
        try validate(context)
        guard context.kind == .message else { throw EncryptedMessagingError.invalidRecord }
        if let sealedBytes, sealedBytes.count > POCLimits.attachmentEnvelopeBytes { throw EncryptedMessagingError.invalidRecord }
        if let previewBytes { _ = try PhotoPreviewCipher.open(previewBytes, original: metadata, context: context) }
        for (rendition, bytes) in renditionBytes {
            _ = try PhotoRenditionCipher.open(bytes, original: metadata, context: context, rendition: rendition)
        }
        let id = Data(metadata.attachmentID.utf8)
        let contextID = AttachmentContextID(context)
        if let existing = attachmentContexts[contextID], existing != id { throw EncryptedMessagingError.conflictingRecord }
        if let old = attachments[id], old.context != context || old.metadata != metadata || (sealedBytes != nil && old.bytes != nil && old.bytes != sealedBytes)
            || (previewBytes != nil && old.previewBytes != nil && old.previewBytes != previewBytes)
            || renditionBytes.contains(where: { pair in old.renditionBytes[pair.key].map { $0 != pair.value } ?? false }) {
            throw EncryptedMessagingError.conflictingRecord
        }
        if attachments[id] == nil, attachments.count >= Self.maximumAttachmentDescriptors {
            let protected = attachmentOwners.values.reduce(into: Set<Data>()) { $0.formUnion($1) }
            guard let victim = attachments.keys.filter({ !protected.contains($0) && attachments[$0]?.bytes == nil })
                .min(by: { (attachmentUse[$0] ?? 0) < (attachmentUse[$1] ?? 0) }) else { throw EncryptedMessagingError.historyLimit }
            if let entry = attachments[victim] { attachmentContexts[AttachmentContextID(entry.context)] = nil }
            attachments[victim] = nil; attachmentUse[victim] = nil
        }
        let entry = AttachmentEntry(context: context, metadata: metadata, bytes: sealedBytes ?? attachments[id]?.bytes,
                                    previewBytes: previewBytes ?? attachments[id]?.previewBytes,
                                    renditionBytes: (attachments[id]?.renditionBytes ?? [:]).merging(renditionBytes) { _, new in new })
        let retained = attachments.filter { $0.key != id }.values.reduce(0) { $0 + ($1.bytes?.count ?? 0) + ($1.previewBytes?.count ?? 0) + $1.renditionBytes.values.reduce(0) { $0 + $1.count } }
        guard retained + (entry.bytes?.count ?? 0) + (entry.previewBytes?.count ?? 0) + entry.renditionBytes.values.reduce(0, { $0 + $1.count }) <= POCLimits.attachmentEnvelopeBytes + 64 * 1024 * 1024 else { throw EncryptedMessagingError.missingAttachment }
        attachments[id] = entry
        attachmentContexts[contextID] = id
        attachmentClock &+= 1; attachmentUse[id] = attachmentClock
    }

    // Conservative finite transition budget: accepted timeline+replies600, candidate600,
    // newest+replies200, search100, plus72 active-media descriptor slots =1572 pins.
    // 1700 registry slots leave128 for staged ciphertext; the independent byte cap permits
    // one maximum-size video plus 64 MiB of other staged ciphertext.
    private static let maximumPinnedAttachmentDescriptors = 1572
    private static let maximumAttachmentDescriptors = 1700

    /// Atomically validates a replacement window before evicting its previous descriptors.
    /// A failed fork/association/capacity check leaves the last displayed window usable.
    func replaceHistoryAttachmentMetadata(ownerID: UUID, entries: [(metadata: PrivateAttachment, context: RecordContext)]) throws {
        try requireActive()
        guard entries.count <= 700, attachmentOwners[ownerID] != nil || attachmentOwners.count < 32 else { throw EncryptedMessagingError.historyLimit }
        let ids = Set(entries.map { Data($0.metadata.attachmentID.utf8) })
        guard ids.count == entries.count else { throw EncryptedMessagingError.conflictingRecord }
        let others = attachmentOwners.filter { $0.key != ownerID }.values.reduce(into: Set<Data>()) { $0.formUnion($1) }
        let protected = others.union(ids)
        guard protected.count <= Self.maximumPinnedAttachmentDescriptors else { throw EncryptedMessagingError.historyLimit }
        var candidates = attachments; var contexts = attachmentContexts; var use = attachmentUse; var clock = attachmentClock
        for (metadata, context) in entries {
            try validate(context); guard context.kind == .message else { throw EncryptedMessagingError.invalidRecord }
            let id = Data(metadata.attachmentID.utf8); let contextID = AttachmentContextID(context)
            if let old = candidates[id], old.context != context || old.metadata != metadata { throw EncryptedMessagingError.conflictingRecord }
            if let existing = contexts[contextID], existing != id { throw EncryptedMessagingError.conflictingRecord }
            candidates[id] = AttachmentEntry(context: context, metadata: metadata, bytes: candidates[id]?.bytes,
                                            previewBytes: candidates[id]?.previewBytes, renditionBytes: candidates[id]?.renditionBytes ?? [:])
            contexts[contextID] = id; clock &+= 1; use[id] = clock
        }
        while candidates.count > Self.maximumAttachmentDescriptors {
            guard let victim = candidates.keys.filter({ !protected.contains($0) && candidates[$0]?.bytes == nil })
                .min(by: { (use[$0] ?? 0) < (use[$1] ?? 0) }) else { throw EncryptedMessagingError.historyLimit }
            if let entry = candidates[victim] { contexts[AttachmentContextID(entry.context)] = nil }
            candidates[victim] = nil; use[victim] = nil
        }
        attachments = candidates; attachmentContexts = contexts; attachmentUse = use; attachmentClock = clock
        attachmentOwners[ownerID] = ids
    }

    /// Visible windows, reply targets and active media can pin descriptor IDs. Staged ciphertext
    /// is separately pinned until release; unpinned metadata is evicted at the bounded LRU limit.
    func retainAttachmentMetadata(ownerID: UUID, attachmentIDs: [String]) throws {
        try requireActive()
        guard attachmentIDs.count <= 700, attachmentOwners[ownerID] != nil || attachmentOwners.count < 32 else { throw EncryptedMessagingError.historyLimit }
        let ids = Set(attachmentIDs.map { Data($0.utf8) })
        let others = attachmentOwners.filter { $0.key != ownerID }.values.reduce(into: Set<Data>()) { $0.formUnion($1) }
        guard others.union(ids).count <= Self.maximumPinnedAttachmentDescriptors else { throw EncryptedMessagingError.historyLimit }
        attachmentOwners[ownerID] = ids
    }
    func releaseAttachmentMetadata(ownerID: UUID) { attachmentOwners[ownerID] = nil }
    /// Keep this lease while displaying media outside its timeline window. Cancellation releases
    /// the pin, without claiming memory zeroization or cancelling already-open media bytes.
    func pinAttachmentMetadata(attachmentIDs: [String]) throws -> ServiceObservation {
        guard attachmentIDs.allSatisfy({ attachments[Data($0.utf8)] != nil }) else { throw EncryptedMessagingError.missingAttachment }
        let owner = UUID(); try retainAttachmentMetadata(ownerID: owner, attachmentIDs: attachmentIDs)
        return ServiceObservation { [weak self] in self?.releaseAttachmentMetadata(ownerID: owner) }
    }

    func attachmentContext(for attachmentID: String) throws -> RecordContext? {
        try requireActive(); return attachments[Data(attachmentID.utf8)]?.context
    }
    func privateAttachment(for context: RecordContext) throws -> PrivateAttachment? {
        try validate(context)
        return attachmentContexts[AttachmentContextID(context)].flatMap { attachments[$0]?.metadata }
    }
    func sealedAttachment(for context: RecordContext) throws -> OutboxAttachment? {
        try validate(context)
        guard let id = attachmentContexts[AttachmentContextID(context)], let entry = attachments[id], let bytes = entry.bytes else { return nil }
        return try OutboxAttachment(attachmentID: entry.metadata.attachmentID, bytes: bytes)
    }
    func releaseSealedAttachment(for context: RecordContext) {
        if let id = attachmentContexts[AttachmentContextID(context)] { attachments[id]?.bytes = nil; attachments[id]?.previewBytes = nil; attachments[id]?.renditionBytes.removeAll() }
    }
    func sealedPhotoPreview(for context: RecordContext) throws -> OutboxAttachment? {
        try validate(context)
        guard let id = attachmentContexts[AttachmentContextID(context)], let entry = attachments[id], let bytes = entry.previewBytes else { return nil }
        return try OutboxAttachment(attachmentID: PhotoPreviewCipher.attachmentID(for: entry.metadata, context: context), bytes: bytes)
    }
    func sealedPhotoRenditions(for context: RecordContext) throws -> [OutboxAttachment] {
        try validate(context)
        guard let id = attachmentContexts[AttachmentContextID(context)], let entry = attachments[id] else { return [] }
        return try PhotoRendition.allCases.compactMap { rendition in
            guard let bytes = entry.renditionBytes[rendition] else { return nil }
            return try OutboxAttachment(attachmentID: PhotoRenditionCipher.attachmentID(for: entry.metadata, context: context, rendition: rendition), bytes: bytes)
        }
    }
    static func attachmentPath(context: RecordContext, attachmentID: String) -> String {
        "e2ee:\(context.recordID):\(context.revision):\(attachmentID)"
    }
    static func same(_ lhs: String, _ rhs: String) -> Bool { Data(lhs.utf8) == Data(rhs.utf8) }
}
