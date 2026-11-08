import Foundation

/// Safe adapter failures; never carry raw Firebase messages, request bodies or identifiers.
public enum SecurePairingTransportFailure: Error, Sendable {
    case unavailable, expired, notFound, conflict, rejected
}

/// Relay ciphertexts and their exact SHA-256 digests. Adapters must bound base64/hex before decoding.
public enum SecurePairingRequest: Sendable, CustomStringConvertible, CustomReflectable {
    case publish(inviteID: String, conversationID: String, keyEpoch: UInt32, offer: Data, expiresAtMilliseconds: UInt64)
    case read(inviteID: String)
    case claim(inviteID: String, claimID: String, acceptance: Data, offerDigest: Data)
    case grant(inviteID: String, acceptanceDigest: Data, grant: Data)
    case acknowledge(inviteID: String, grantDigest: Data)
    case cancel(inviteID: String)
    public var description: String { "SecurePairingRequest(redacted)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public struct SecurePairingSnapshot: Sendable, CustomStringConvertible, CustomReflectable {
    public enum State: String, Sendable { case offered, claimed, grantReady, complete, cancelled, unavailable }
    public let creatorID: String
    public let conversationID: String
    public let keyEpoch: UInt32
    public let protocolID: String
    public let expiresAtMilliseconds: UInt64
    public let state: State
    public let offer: Data
    public let offerDigest: Data
    public let claimantID: String?
    public let claimID: String?
    public let acceptance: Data?
    public let acceptanceDigest: Data?
    public let grant: Data?
    public let grantDigest: Data?
    public init(creatorID: String, conversationID: String, keyEpoch: UInt32, protocolID: String,
                expiresAtMilliseconds: UInt64, state: State, offer: Data, offerDigest: Data,
                claimantID: String? = nil, claimID: String? = nil, acceptance: Data? = nil,
                acceptanceDigest: Data? = nil, grant: Data? = nil, grantDigest: Data? = nil) {
        self.creatorID = creatorID; self.conversationID = conversationID; self.keyEpoch = keyEpoch
        self.protocolID = protocolID; self.expiresAtMilliseconds = expiresAtMilliseconds; self.state = state
        self.offer = offer; self.offerDigest = offerDigest; self.claimantID = claimantID; self.claimID = claimID
        self.acceptance = acceptance; self.acceptanceDigest = acceptanceDigest
        self.grant = grant; self.grantDigest = grantDigest
    }
    public var description: String { "SecurePairingSnapshot(redacted)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public enum SecurePairingResponse: Sendable, CustomStringConvertible, CustomReflectable {
    case snapshot(SecurePairingSnapshot)
    case cancelled
    public var description: String { "SecurePairingResponse(redacted)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// The adapter binds every request to its immutable authenticated account session. A cancelled
/// task may already have reached the relay; local invalidation cannot revoke remote side effects.
public protocol SecurePairingTransport: Sendable {
    func perform(_ request: SecurePairingRequest) async throws -> SecurePairingResponse
    /// Independently confirm current active assignment, both exact members, generation and epoch.
    func confirmActiveConversation(conversationID: String, creatorID: String, recipientID: String,
                                   keyEpoch: UInt32, inviteID: String, grantDigest: Data) async throws -> Bool
}
