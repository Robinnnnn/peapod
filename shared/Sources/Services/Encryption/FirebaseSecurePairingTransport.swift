@preconcurrency import FirebaseAuth
@preconcurrency import FirebaseFirestore
@preconcurrency import FirebaseFunctions
import CoreFoundation
import Foundation
import MinesE2EE

/// One authenticated app session. The owner invalidates this object before sign-out;
/// restoring the same account creates a new instance. No request/response is logged.
@MainActor
final class FirebaseSecurePairingTransport: SecurePairingTransport {
    private let accountID: String
    private let auth: Auth
    private let functions: Functions
    private let firestore: Firestore
    private var active = true

    init(accountID: String, auth: Auth = .auth(),
         functions: Functions = .functions(region: "us-west1"), firestore: Firestore = .firestore()) {
        self.accountID = accountID
        self.auth = auth
        self.functions = functions
        self.firestore = firestore
    }

    func invalidate() { active = false }

    func perform(_ request: SecurePairingRequest) async throws -> SecurePairingResponse {
        try checkSession()
        let encoded = try SecurePairingWire.encode(request)
        do {
            let result = try await functions.httpsCallable(encoded.function).call(encoded.body)
            try checkSession()
            return try SecurePairingWire.decode(result.data)
        } catch {
            try checkSession()
            throw Self.safeFailure(error)
        }
    }

    func confirmActiveConversation(conversationID: String, creatorID: String, recipientID: String,
                                   keyEpoch: UInt32, inviteID: String, grantDigest: Data) async throws -> Bool {
        try checkSession()
        guard Self.same(accountID, creatorID) || Self.same(accountID, recipientID),
              !Self.same(creatorID, recipientID), grantDigest.count == 32 else { return false }
        let conversation = try await firestore.collection("conversations").document(conversationID)
            .getDocument(source: .server)
        try checkSession()
        guard let data = conversation.data(),
              data["status"] as? String == "active",
              data["encryption"] as? String == "mines-e2ee-v1",
              try SecurePairingWire.integer(data["keyEpoch"]) == UInt64(keyEpoch),
              Self.same(data["pairingInviteId"] as? String ?? "", inviteID),
              Self.same(data["pairingGrantDigest"] as? String ?? "", SecurePairingWire.hex(grantDigest)),
              let members = data["members"] as? [String], members.count == 2,
              members.contains(where: { Self.same($0, creatorID) }),
              members.contains(where: { Self.same($0, recipientID) }) else { return false }
        for member in [creatorID, recipientID] {
            let user = try await firestore.collection("users").document(member).getDocument(source: .server)
            try checkSession()
            guard Self.same(user.data()?["activeConversationId"] as? String ?? "", conversationID) else { return false }
        }
        return true
    }

    static func safeFailure(_ error: any Error) -> any Error {
        if error is SecurePairingCoordinatorError { return error }
        let error = error as NSError
        guard error.domain == FunctionsErrorDomain, let code = FunctionsErrorCode(rawValue: error.code) else {
            return SecurePairingTransportFailure.unavailable
        }
        switch code {
        case .notFound: return SecurePairingTransportFailure.notFound
        case .alreadyExists, .failedPrecondition: return SecurePairingTransportFailure.conflict
        case .permissionDenied, .invalidArgument, .unauthenticated: return SecurePairingTransportFailure.rejected
        // A transport timeout can have committed. Retain the handle and exact retry bytes.
        default: return SecurePairingTransportFailure.unavailable
        }
    }

    private func checkSession() throws {
        guard active, let uid = auth.currentUser?.uid, Self.same(uid, accountID) else {
            throw SecurePairingCoordinatorError.invalidSession
        }
    }
    private static func same(_ lhs: String, _ rhs: String) -> Bool { Data(lhs.utf8) == Data(rhs.utf8) }
}

/// Strict public relay projection. Raw private keys and invite secrets have no wire field.
enum SecurePairingWire {
    struct Request { let function: String; let body: [String: Any] }
    static func encode(_ request: SecurePairingRequest) throws -> Request {
        switch request {
        case let .publish(id, conversation, epoch, offer, expiry):
            guard expiry <= 9_007_199_254_740_991, epoch == 1 else { throw invalid }
            return Request(function: "publishSecureInvite", body: ["inviteId": try locator(id),
                "conversationId": try uuid(conversation), "epoch": epoch,
                "offer": try box(offer), "expiresAtMillis": expiry])
        case let .read(id):
            return Request(function: "readSecureInvite", body: ["inviteId": try locator(id)])
        case let .claim(id, claim, acceptance, offerDigest):
            return Request(function: "claimSecureInvite", body: ["inviteId": try locator(id),
                "claimId": try locator(claim), "acceptance": try box(acceptance), "offerDigest": try digest(offerDigest)])
        case let .grant(id, acceptanceDigest, grant):
            return Request(function: "finalizeSecureInvite", body: ["inviteId": try locator(id),
                "acceptanceDigest": try digest(acceptanceDigest), "grant": try box(grant)])
        case let .acknowledge(id, grantDigest):
            return Request(function: "ackSecureGrant", body: ["inviteId": try locator(id), "grantDigest": try digest(grantDigest)])
        case let .cancel(id):
            return Request(function: "cancelSecureInvite", body: ["inviteId": try locator(id)])
        }
    }

    static func decode(_ raw: Any) throws -> SecurePairingResponse {
        guard let data = raw as? [String: Any], data.count <= 15,
              let stateText = data["state"] as? String,
              let state = SecurePairingSnapshot.State(rawValue: stateText) else { throw invalid }
        if state == .cancelled {
            guard data.count == 1 else { throw invalid }
            return .cancelled
        }
        let allowed: Set<String> = ["creatorId", "conversationId", "epoch", "protocol", "expiresAtMillis",
            "state", "offer", "offerDigest", "claimantId", "claimId", "acceptance", "acceptanceDigest", "grant", "grantDigest"]
        guard Set(data.keys).isSubset(of: allowed), data["protocol"] as? String == "mines-e2ee-v1",
              try integer(data["epoch"]) == 1 else { throw invalid }
        return .snapshot(SecurePairingSnapshot(creatorID: try identifier(data["creatorId"]),
            conversationID: try uuid(try identifier(data["conversationId"])), keyEpoch: 1,
            protocolID: "mines-e2ee-v1", expiresAtMilliseconds: try integer(data["expiresAtMillis"]),
            state: state, offer: try decodeBox(data["offer"]), offerDigest: try decodeDigest(data["offerDigest"]),
            claimantID: try optional(data["claimantId"], identifier), claimID: try optional(data["claimId"], { try locator(try identifier($0)) }),
            acceptance: try optional(data["acceptance"], decodeBox), acceptanceDigest: try optional(data["acceptanceDigest"], decodeDigest),
            grant: try optional(data["grant"], decodeBox), grantDigest: try optional(data["grantDigest"], decodeDigest)))
    }

    static func integer(_ raw: Any?) throws -> UInt64 {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { throw invalid }
        let value = number.doubleValue
        guard value.isFinite, value >= 0, value <= 9_007_199_254_740_991, value.rounded(.towardZero) == value else { throw invalid }
        return UInt64(value)
    }
    static func hex(_ bytes: Data) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
    private static var invalid: SecurePairingCoordinatorError { .invalidRelay }
    private static func identifier(_ raw: Any?) throws -> String {
        guard let text = raw as? String, !text.isEmpty, text.utf8.count <= 256,
              !text.contains("/"), !text.contains("\0") else { throw invalid }
        return text
    }
    private static func locator(_ text: String) throws -> String {
        guard text.utf8.count == 32, text.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw invalid }
        return text
    }
    private static func uuid(_ text: String) throws -> String {
        guard UUID(uuidString: text)?.uuidString.lowercased() == text else { throw invalid }
        return text
    }
    private static func box(_ bytes: Data) throws -> String {
        guard !bytes.isEmpty, bytes.count <= 8192 else { throw invalid }
        return bytes.base64EncodedString()
    }
    private static func digest(_ bytes: Data) throws -> String {
        guard bytes.count == 32 else { throw invalid }; return hex(bytes)
    }
    private static func decodeBox(_ raw: Any?) throws -> Data {
        guard let text = raw as? String, !text.isEmpty, text.utf8.count <= 10924,
              let bytes = Data(base64Encoded: text), !bytes.isEmpty, bytes.count <= 8192,
              bytes.base64EncodedString() == text else { throw invalid }
        return bytes
    }
    static func decodeDigest(_ raw: Any?) throws -> Data {
        guard let text = raw as? String, text.utf8.count == 64,
              text.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw invalid }
        let bytes = Array(text.utf8)
        func nibble(_ value: UInt8) -> UInt8 { value <= 57 ? value - 48 : value - 87 }
        return Data(stride(from: 0, to: 64, by: 2).map { nibble(bytes[$0]) * 16 + nibble(bytes[$0 + 1]) })
    }
    private static func optional<T>(_ value: Any?, _ decode: (Any?) throws -> T) throws -> T? {
        guard let value else { return nil }; return try decode(value)
    }
}
