import Foundation
import Security

public enum ConversationKeyStoreError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidScope
    case invalidEncoding
    case unsupportedVersion
    case unsupportedSuite
    case sizeLimitExceeded
    case identityMismatch
    case invalidCommitment
    case conflict
    case missingPrerequisite
    case terminalInvite
    case coordinationFailed
    case securityStatus(OSStatus)
}

/// Explicit namespace selection. There is no default-access-group or shared-auth fallback.
public struct ConversationKeychainNamespace: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let accessGroup: String
    fileprivate let synthetic: Bool

    public init(productionAccessGroup: String, expectedSuffix: String = ".e2ee") throws {
        guard expectedSuffix.hasSuffix(".e2ee") else { throw ConversationKeyStoreError.invalidConfiguration }
        try Self.validate(productionAccessGroup, suffix: expectedSuffix)
        accessGroup = productionAccessGroup
        synthetic = false
    }

    /// Explicit opt-in for synthetic validation only; never use this namespace for app keys.
    public static func syntheticProbe(accessGroup: String, expectedSuffix: String = ".e2ee-probe") throws -> Self {
        guard expectedSuffix.hasSuffix(".e2ee-probe") else { throw ConversationKeyStoreError.invalidConfiguration }
        try validate(accessGroup, suffix: expectedSuffix)
        return Self(accessGroup: accessGroup, synthetic: true)
    }

    private init(accessGroup: String, synthetic: Bool) {
        self.accessGroup = accessGroup
        self.synthetic = synthetic
    }

    func service(_ name: String) -> String {
        "mines.e2ee.\(name).v1" + (synthetic ? ".synthetic" : "")
    }

    private static func validate(_ group: String, suffix: String) throws {
        guard group.utf8.count <= 255, suffix.hasPrefix("."), group.hasSuffix(suffix),
              let separator = group.firstIndex(of: ".") else { throw ConversationKeyStoreError.invalidConfiguration }
        let prefix = group[..<separator]
        let identifier = group[group.index(after: separator)...]
        let components = identifier.split(separator: ".", omittingEmptySubsequences: false)
        let suffixComponents = suffix.dropFirst().split(separator: ".", omittingEmptySubsequences: false)
        func validComponent(_ component: Substring) -> Bool {
            !component.isEmpty && component.utf8.count <= 63 && component.first != "-" && component.last != "-"
                && component.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0)
                    || (48...57).contains($0) || $0 == 45 }
        }
        guard prefix.utf8.count == 10,
              prefix.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }),
              components.count >= 3, components.allSatisfy(validComponent),
              suffixComponents.allSatisfy(validComponent) else {
            throw ConversationKeyStoreError.invalidConfiguration
        }
    }
    public var description: String { "ConversationKeychainNamespace(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Confined by the public store actors. All mutable operations are add-only except exact local cleanup.
final class ImmutableScopedKeychain {
    private let namespace: ConversationKeychainNamespace
    private let service: String
    private let synchronizable: Bool
    private let maximumBytes: Int
    private let backend: any KeychainBackend

    init(namespace: ConversationKeychainNamespace, name: String, synchronizable: Bool,
         maximumBytes: Int, backend: any KeychainBackend) {
        self.namespace = namespace
        service = namespace.service(name)
        self.synchronizable = synchronizable
        self.maximumBytes = maximumBytes
        self.backend = backend
    }

    func read(scope: Data) throws -> Data? {
        var query = scopedQuery(scope)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, result) = backend.copyMatching(query)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ConversationKeyStoreError.securityStatus(status) }
        guard let bytes = result as? Data, !bytes.isEmpty else { throw ConversationKeyStoreError.invalidEncoding }
        guard bytes.count <= maximumBytes else { throw ConversationKeyStoreError.sizeLimitExceeded }
        return bytes
    }

    func insert(_ bytes: Data, scope: Data) throws {
        guard !bytes.isEmpty else { throw ConversationKeyStoreError.invalidEncoding }
        guard bytes.count <= maximumBytes else { throw ConversationKeyStoreError.sizeLimitExceeded }
        if let existing = try read(scope: scope) {
            guard existing == bytes else { throw ConversationKeyStoreError.conflict }
            return
        }
        var attributes = scopedQuery(scope)
        attributes[kSecValueData as String] = bytes
        attributes[kSecAttrAccessible as String] = synchronizable
            ? kSecAttrAccessibleAfterFirstUnlock
            : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = backend.add(attributes)
        if status == errSecDuplicateItem {
            guard let existing = try read(scope: scope), existing == bytes else { throw ConversationKeyStoreError.conflict }
            return
        }
        guard status == errSecSuccess else { throw ConversationKeyStoreError.securityStatus(status) }
    }

    /// The synchronizable store cannot use this operation, even through an accidental internal call.
    func deleteLocal(scope: Data) throws {
        guard !synchronizable else { throw ConversationKeyStoreError.invalidConfiguration }
        let status = backend.delete(scopedQuery(scope))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ConversationKeyStoreError.securityStatus(status)
        }
    }

    private func scopedQuery(_ scope: Data) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrAccessGroup as String: namespace.accessGroup,
         kSecAttrService as String: service,
         kSecAttrAccount as String: scope.base64EncodedString(),
         kSecAttrSynchronizable as String: synchronizable]
    }
}

func validateStoredKeyIdentifier(_ value: String) throws {
    guard !value.utf8.isEmpty, value.utf8.count <= 256 else { throw ConversationKeyStoreError.invalidScope }
}

func storedKeyScope(_ scope: KeyScope) throws -> Data {
    try validateStoredKeyIdentifier(scope.accountID)
    try validateStoredKeyIdentifier(scope.conversationID)
    guard scope.epoch > 0 else { throw ConversationKeyStoreError.invalidScope }
    var writer = BinaryWriter()
    writer.string(scope.accountID)
    writer.string(scope.conversationID)
    writer.uint32(scope.epoch)
    return writer.data
}
