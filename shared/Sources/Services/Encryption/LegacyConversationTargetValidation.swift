import CoreFoundation
import Foundation

/// A definitive metadata result, distinct from a transport's unavailable/offline error.
/// No account IDs, private content, or cryptographic material appear in error descriptions.
enum LegacyConversationTargetError: LocalizedError, Equatable, Sendable {
    case encryptionRequired, assignmentChanged, invalidMetadata
    var errorDescription: String? {
        switch self {
        case .encryptionRequired: "This conversation requires a compatible secure version of Peapod."
        case .assignmentChanged: "The conversation changed. Open it again before sharing."
        case .invalidMetadata: "The conversation could not be verified for sharing."
        }
    }
}

/// Validates uncached server metadata supplied by the native publisher. This does not fetch
/// metadata or authorize a plaintext fallback. A cached target can authorize protected local
/// drafts only; network delivery still obeys the server's current protocol and membership.
enum LegacyConversationTargetValidation {
    /// Call immediately after the uncached profile read, before a conversation fetch can
    /// turn a definitive reassignment or malformed floor into an apparent offline failure.
    static func validateProfile(accountID: String, conversationID: String, profile: [String: Any]?) throws {
        guard identifier(accountID), identifier(conversationID), !conversationID.contains("/") else {
            throw LegacyConversationTargetError.invalidMetadata
        }
        guard let profile else { throw LegacyConversationTargetError.assignmentChanged }
        if let requirement = profile["e2eeRequired"] {
            guard let value = requirement as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
                throw LegacyConversationTargetError.invalidMetadata
            }
            if value.boolValue { throw LegacyConversationTargetError.encryptionRequired }
        }
        guard let assigned = profile["activeConversationId"] as? String,
              exact(assigned, conversationID) else { throw LegacyConversationTargetError.assignmentChanged }
    }

    static func target(accountID: String, conversationID: String, profile: [String: Any]?,
                       conversation: [String: Any]?, hasSyncedCapsule: Bool) throws -> SharedConversationTarget {
        try validateProfile(accountID: accountID, conversationID: conversationID, profile: profile)
        // Marker presence is significant even when its value is null or malformed. Never
        // reinterpret an unknown/future encrypted format as a legacy conversation.
        if hasSyncedCapsule || conversation?["encryption"] != nil || conversation?["keyEpoch"] != nil {
            throw LegacyConversationTargetError.encryptionRequired
        }
        guard let conversation, conversation["status"] as? String == "active",
              let members = conversation["members"] as? [String], members.count == 2,
              members.allSatisfy(identifier), !exact(members[0], members[1]),
              members.contains(where: { exact($0, accountID) }) else {
            throw LegacyConversationTargetError.invalidMetadata
        }
        return try SharedConversationTarget(accountID: accountID, conversationID: conversationID, mode: .legacy,
            members: members.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) })
    }

    /// Synchronous preflight for a legacy sender/stager. Absence is not legacy evidence;
    /// callers may use an earlier verified exact-scope target for protected offline drafts.
    /// Read the durable floor immediately before calling; a read error must propagate.
    static func requireLegacyRoute(target: SharedConversationTarget?, accountID: String,
                                   conversationID: String, requiresEncryption: Bool) throws {
        if requiresEncryption || target?.mode == .encrypted { throw LegacyConversationTargetError.encryptionRequired }
        guard let target, exact(target.accountID, accountID), exact(target.conversationID, conversationID) else {
            throw LegacyConversationTargetError.assignmentChanged
        }
        guard target.mode == .legacy, target.keyEpoch == nil else { throw LegacyConversationTargetError.encryptionRequired }
    }

    /// Reverification of an unchanged binding must not invalidate an in-progress local draft
    /// solely by generating another UUID. Publication still enforces the durable floor atomically.
    static func preservingGeneration(of existing: SharedConversationTarget?, for verified: SharedConversationTarget) throws -> SharedConversationTarget {
        guard let existing, exact(existing.accountID, verified.accountID), exact(existing.conversationID, verified.conversationID),
              existing.mode == verified.mode, existing.keyEpoch == verified.keyEpoch,
              Set(existing.members.map { Data($0.utf8) }) == Set(verified.members.map { Data($0.utf8) }) else { return verified }
        return try SharedConversationTarget(accountID: verified.accountID, conversationID: verified.conversationID,
            mode: verified.mode, keyEpoch: verified.keyEpoch, members: verified.members, generation: existing.generation)
    }
    private static func identifier(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 256 }
    private static func exact(_ left: String, _ right: String) -> Bool { left.utf8.elementsEqual(right.utf8) }
}
