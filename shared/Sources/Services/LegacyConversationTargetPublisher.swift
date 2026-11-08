import Foundation

/// Publishes attachment routing independently of the development-only encryption factory.
/// A retained target is previously verified metadata, never an inferred mode from a conversation ID.
@MainActor
final class LegacyConversationTargetPublisher {
    struct Dependencies {
        let currentAccountID: () -> String?
        let readTarget: () throws -> SharedConversationTarget?
        let publish: (SharedConversationTarget) throws -> Void
        let clear: (String) throws -> Void
        let requiresEncryption: (String) throws -> Bool
        let verify: (String, String) async throws -> SharedConversationTarget
    }
    private let dependencies: Dependencies
    private var retained: SharedConversationTarget?
    init(dependencies: Dependencies) { self.dependencies = dependencies }

    /// Called before model teardown clears the active route. Never carries another account's target.
    func prepareForAccountRestoration(_ accountID: String) {
        retained = nil
        do {
            guard let candidate = try dependencies.readTarget(), candidate.accountID.utf8.elementsEqual(accountID.utf8),
                  candidate.mode == .legacy, try !dependencies.requiresEncryption(accountID) else { return }
            retained = candidate
        } catch { /* Corrupt or unavailable metadata is not a reusable target. */ }
    }
    @discardableResult
    func restoreVerifiedTarget(accountID: String, conversationID: String) throws -> Bool {
        try requireAccount(accountID)
        guard try !dependencies.requiresEncryption(accountID) else { throw LegacyConversationTargetError.encryptionRequired }
        guard let retained, retained.conversationID.utf8.elementsEqual(conversationID.utf8),
              retained.accountID.utf8.elementsEqual(accountID.utf8) else { return false }
        try LegacyConversationTargetValidation.requireLegacyRoute(target: retained, accountID: accountID,
            conversationID: conversationID, requiresEncryption: false)
        try publishIdempotently(retained)
        return true
    }
    func verifyAndPublish(accountID: String, conversationID: String, isCurrent: @escaping () -> Bool) async throws {
        try requireAccount(accountID)
        let target: SharedConversationTarget
        do { target = try await dependencies.verify(accountID, conversationID) }
        catch {
            guard isCurrent() else { throw CancellationError() }
            try requireAccount(accountID)
            if Self.revokesRoute(error) { retained = nil; try dependencies.clear(accountID) }
            throw error
        }
        guard isCurrent() else { throw CancellationError() }
        try requireAccount(accountID)
        try LegacyConversationTargetValidation.requireLegacyRoute(target: target, accountID: accountID,
            conversationID: conversationID, requiresEncryption: dependencies.requiresEncryption(accountID))
        try publishIdempotently(target)
        retained = target
    }
    private func publishIdempotently(_ target: SharedConversationTarget) throws {
        if let existing = try dependencies.readTarget(), existing.mode == target.mode,
           existing.accountID.utf8.elementsEqual(target.accountID.utf8),
           existing.conversationID.utf8.elementsEqual(target.conversationID.utf8), existing.keyEpoch == target.keyEpoch,
           Set(existing.members.map { Data($0.utf8) }) == Set(target.members.map { Data($0.utf8) }) {
            return // Do not invalidate an in-progress staged-file check with a needless new generation.
        }
        try dependencies.publish(target)
    }
    private func requireAccount(_ id: String) throws {
        guard dependencies.currentAccountID()?.utf8.elementsEqual(id.utf8) == true else {
            throw LegacyConversationTargetError.assignmentChanged
        }
    }
    static func revokesRoute(_ error: Error) -> Bool {
        if error is LegacyConversationTargetError { return true }
        if let storeError = error as? PendingShareStoreError, case .encryptionRequired = storeError { return true }
        return false
    }
}
