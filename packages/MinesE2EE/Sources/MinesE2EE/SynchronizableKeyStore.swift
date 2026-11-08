import Foundation
import Security

/// Synthetic POC scope. Identifiers are never interpolated into error messages.
public struct KeyScope: Codable, Equatable, Sendable {
    public let accountID: String
    public let conversationID: String
    public let epoch: UInt32

    public init(accountID: String, conversationID: String, epoch: UInt32) {
        self.accountID = accountID
        self.conversationID = conversationID
        self.epoch = epoch
    }
}

public enum KeyStoreError: Error, Equatable {
    case invalidConfiguration
    case invalidScope
    case invalidKey
    case conflict
    case unexpectedResult
    /// Preserves explicit locked/unavailable, entitlement and authentication statuses.
    case securityStatus(OSStatus)
}

/// Narrow adapter permits deterministic query tests without signing or iCloud entitlements.
protocol KeychainBackend {
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Any?)
    func add(_ attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

struct SecurityKeychainBackend: KeychainBackend {
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Any?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
    }
    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

/// Dedicated synchronizable generic-password store for this isolated experiment only.
/// Read never creates a key. There is deliberately no update, replace or sign-out operation.
public final class SynchronizableKeyStore {
    public static let service = "mines.poc.icloud-e2ee.synthetic-key.v1"
    private let accessGroup: String
    private let backend: any KeychainBackend

    public convenience init(accessGroup: String) throws {
        try self.init(accessGroup: accessGroup, backend: SecurityKeychainBackend())
    }

    init(accessGroup: String, backend: any KeychainBackend) throws {
        guard !accessGroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              accessGroup.hasSuffix(".mines.e2ee-probe") else {
            throw KeyStoreError.invalidConfiguration
        }
        self.accessGroup = accessGroup
        self.backend = backend
    }

    /// nil means no visible item; synchronization and entitlement state remain unproven.
    public func read(scope: KeyScope) throws -> Data? {
        var query = try scopedQuery(scope)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, result) = backend.copyMatching(query)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeyStoreError.securityStatus(status) }
        guard let data = result as? Data, data.count == 32 else {
            throw KeyStoreError.unexpectedResult
        }
        return data
    }

    /// Idempotent only for identical bytes. Duplicate races are checked, never overwritten.
    public func insert(_ key: Data, scope: KeyScope) throws {
        guard key.count == 32 else { throw KeyStoreError.invalidKey }
        if let existing = try read(scope: scope) {
            guard existing == key else { throw KeyStoreError.conflict }
            return
        }
        var attributes = try scopedQuery(scope)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        attributes[kSecValueData as String] = key
        let status = backend.add(attributes)
        if status == errSecDuplicateItem {
            guard let existing = try read(scope: scope) else {
                throw KeyStoreError.securityStatus(status)
            }
            guard existing == key else { throw KeyStoreError.conflict }
            return
        }
        guard status == errSecSuccess else { throw KeyStoreError.securityStatus(status) }
    }

    /// Explicit probe cleanup only: this synchronized deletion propagates to other devices.
    public func deleteForExplicitProbeCleanup(scope: KeyScope) throws {
        let status = backend.delete(try scopedQuery(scope))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeyStoreError.securityStatus(status)
        }
    }

    private func scopedQuery(_ scope: KeyScope) throws -> [String: Any] {
        guard scope.epoch > 0, !scope.accountID.isEmpty, !scope.conversationID.isEmpty,
              scope.accountID.utf8.count <= 256, scope.conversationID.utf8.count <= 256 else {
            throw KeyStoreError.invalidScope
        }
        // JSON encoding avoids separator collisions and includes all three scope dimensions.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let account = try encoder.encode(scope).base64EncodedString()
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: true
        ]
    }
}
