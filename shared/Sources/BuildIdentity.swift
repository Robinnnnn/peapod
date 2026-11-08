import Foundation
import MinesE2EE

/// Expanded by Xcode from the same settings used by the signed entitlements.
/// AppIdentifierPrefix comes from provisioning; it is never inferred from a team ID.
enum BuildIdentity {
    enum ConfigurationError: Error { case invalidIdentity }

    struct Configuration: Sendable {
        let appGroup: String
        let authKeychainAccessGroup: String
        let e2eeKeychainAccessGroup: String
        let e2eeKeychainSuffix: String
    }

    static func configuration(in bundle: Bundle = .main) throws -> Configuration {
        func value(_ key: String) throws -> String {
            guard let value = bundle.object(forInfoDictionaryKey: key) as? String,
                  !value.isEmpty, value.utf8.count <= 255,
                  !value.contains("$"), !value.contains("*") else {
                throw ConfigurationError.invalidIdentity
            }
            return value
        }
        let appGroup = try value("PeapodAppGroupIdentifier")
        let auth = try value("PeapodAuthKeychainAccessGroup")
        let e2ee = try value("PeapodE2EEKeychainAccessGroup")
        let suffix = try value("PeapodE2EEKeychainSuffix")
        guard appGroup.hasPrefix("group."), validIdentifier(String(appGroup.dropFirst(6))),
              suffix.hasPrefix("."), suffix.hasSuffix(".e2ee"),
              validIdentifier(String(suffix.dropFirst())),
              e2ee.hasSuffix(suffix) else { throw ConfigurationError.invalidIdentity }
        let prefix = String(e2ee.dropLast(suffix.count))
        let base = String(suffix.dropFirst().dropLast(".e2ee".count))
        guard auth == prefix + "." + base + ".shared-auth" else {
            throw ConfigurationError.invalidIdentity
        }
        _ = try ConversationKeychainNamespace(productionAccessGroup: e2ee, expectedSuffix: suffix)
        return Configuration(appGroup: appGroup, authKeychainAccessGroup: auth,
                             e2eeKeychainAccessGroup: e2ee, e2eeKeychainSuffix: suffix)
    }

    static func keychainNamespace() throws -> ConversationKeychainNamespace {
        let identity = try configuration()
        return try ConversationKeychainNamespace(productionAccessGroup: identity.e2eeKeychainAccessGroup,
                                                 expectedSuffix: identity.e2eeKeychainSuffix)
    }

    private static func validIdentifier(_ value: String) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        return components.count >= 2 && components.allSatisfy { component in
            !component.isEmpty && component.utf8.count <= 63
                && component.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0)
                    || (48...57).contains($0) || $0 == 45 }
                && component.first != "-" && component.last != "-"
        }
    }
}
