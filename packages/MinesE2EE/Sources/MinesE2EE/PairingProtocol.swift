import CryptoKit
import Foundation

public enum PairingError: Error, Equatable, Sendable {
    case malformed
    case unsupportedVersion
    case unsupportedSuite
    case sizeLimitExceeded
    case invalidIdentity
    case invalidKey
    case invalidExpiry
    case expired
    case authenticationFailed
    case transcriptMismatch
    case recipientMismatch
    case commitmentMismatch
}

/// Carry only the explicit shareFragment in a link fragment or QR code. Never put it in a
/// URL query, request body, analytics, pasteboard history, or logs. Possession authorizes a claim.
public struct PairingInvite: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let locator: Data
    private let secret: Data
    public var locatorHex: String { PairingWire.hex(locator) }
    public var description: String { "PairingInvite(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }

    public init(shareFragment: String) throws {
        guard shareFragment.utf8.count == 79 else { throw PairingError.malformed }
        let fields = shareFragment.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3, fields[0] == "v1" else { throw PairingError.unsupportedVersion }
        let locator = try PairingWire.unhex(String(fields[1]), bytes: 16)
        let encoded = String(fields[2])
        guard encoded.utf8.count == 43, encoded.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              let secret = Data(base64Encoded: encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="),
              secret.count == 32, PairingWire.base64url(secret) == encoded else { throw PairingError.malformed }
        self.locator = locator; self.secret = secret
    }

    fileprivate init() {
        locator = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }
    fileprivate init(localBytes: Data) throws {
        guard localBytes.count == 48 else { throw PairingError.malformed }
        locator = Data(localBytes.prefix(16)); secret = Data(localBytes.suffix(32))
    }
    fileprivate var localBytes: Data { locator + secret }
    public func shareFragment() -> String { "v1.\(locatorHex).\(PairingWire.base64url(secret))" }

    func derive(_ purpose: String) -> SymmetricKey {
        let salt = Data(SHA256.hash(data: Data("mines/pairing/v1/salt\0".utf8) + locator))
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: salt,
            info: Data("mines/pairing/v1/\(purpose)\0".utf8), outputByteCount: 32)
    }
}

/// Account identities must originate in the caller's authenticated local session, never in
/// an unverified relay response. The relay receives opaque boxes and public routing metadata.
public enum PairingProtocol {
    public static let pairingSuite = "mines-pairing-v1"
    public static let contentSuite = "mines-e2ee-v1"
    public static let maximumBoxBytes = 8192
    public static let maximumLocalStateBytes = 32 * 1024
    public static let maximumLifetimeMilliseconds: UInt64 = 60 * 60 * 1000

    public static func epochKeyCommitment(epochKey: Data, conversationID: String, keyEpoch: UInt32) throws -> Data {
        try PairingWire.validateConversation(conversationID)
        guard epochKey.count == 32, keyEpoch > 0 else { throw PairingError.invalidKey }
        var writer = BinaryWriter()
        writer.bytes(Data("mines/pairing/v1/epoch-key\0".utf8))
        writer.string(conversationID); writer.uint32(keyEpoch); writer.string(contentSuite); writer.bytes(epochKey)
        return Data(SHA256.hash(data: writer.data))
    }

    public static func makeCreatorOffer(creatorID: String, conversationID: String, epoch: UInt32,
        epochKey: Data, expiresAtMilliseconds: UInt64, nowMilliseconds: UInt64) throws -> CreatorPairingState {
        try PairingWire.validateIdentity(creatorID)
        try PairingWire.validateExpiry(expiresAtMilliseconds, now: nowMilliseconds)
        let invite = PairingInvite()
        let commitment = try epochKeyCommitment(epochKey: epochKey, conversationID: conversationID, keyEpoch: epoch)
        let offer = PairingOffer(locator: invite.locator, creatorID: creatorID, conversationID: conversationID,
                                 epoch: epoch, expires: expiresAtMilliseconds, commitment: commitment)
        let bytes = try PairingWire.seal(offer.encoded, kind: "offer", invite: invite, binder: nil, purpose: "offer-key")
        return CreatorPairingState(invite: invite, epochKey: epochKey, offer: offer, publicOfferBytes: bytes)
    }

    public static func makeAcceptance(publicOffer: Data, invite: PairingInvite, recipientID: String,
        nowMilliseconds: UInt64) throws -> RecipientPairingState {
        try PairingWire.validateIdentity(recipientID)
        let offer = try decodeOffer(publicOffer, invite: invite)
        try PairingWire.validateExpiry(offer.expires, now: nowMilliseconds)
        guard !PairingWire.same(offer.creatorID, recipientID) else { throw PairingError.recipientMismatch }
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let acceptance = PairingAcceptance(locator: invite.locator, offerHash: PairingWire.hash(publicOffer),
            creatorID: offer.creatorID, recipientID: recipientID, conversationID: offer.conversationID,
            epoch: offer.epoch, claimID: SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) },
            recipientPublicKey: privateKey.publicKey.rawRepresentation)
        let bytes = try PairingWire.seal(acceptance.encoded, kind: "acceptance", invite: invite,
            binder: acceptance.offerHash, purpose: "acceptance-key")
        return RecipientPairingState(invite: invite, privateKey: privateKey, offer: offer,
            acceptance: acceptance, publicOfferBytes: publicOffer, publicAcceptanceBytes: bytes)
    }

    fileprivate static func decodeOffer(_ bytes: Data, invite: PairingInvite) throws -> PairingOffer {
        let offer = try PairingOffer.decode(PairingWire.open(bytes, kind: "offer", invite: invite, binder: nil, purpose: "offer-key"))
        guard offer.locator == invite.locator else { throw PairingError.transcriptMismatch }
        return offer
    }
    fileprivate static func decodeAcceptance(_ bytes: Data, creator: CreatorPairingState,
                                             expectedRecipientID: String) throws -> PairingAcceptance {
        let acceptance = try PairingAcceptance.decode(PairingWire.open(bytes, kind: "acceptance", invite: creator.invite,
            binder: PairingWire.hash(creator.publicOfferBytes), purpose: "acceptance-key"))
        try PairingWire.validateIdentity(expectedRecipientID)
        try acceptance.matches(offer: creator.offer, offerBytes: creator.publicOfferBytes)
        guard PairingWire.same(expectedRecipientID, acceptance.recipientID) else { throw PairingError.recipientMismatch }
        return acceptance
    }
}

public struct CreatorPairingState: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let invite: PairingInvite
    public let publicOfferBytes: Data
    public var creatorID: String { offer.creatorID }
    public var conversationID: String { offer.conversationID }
    public var keyEpoch: UInt32 { offer.epoch }
    public var expiresAtMilliseconds: UInt64 { offer.expires }
    public var offerHash: Data { PairingWire.hash(publicOfferBytes) }
    fileprivate let epochKey: Data
    fileprivate let offer: PairingOffer
    public var description: String { "CreatorPairingState(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }

    fileprivate init(invite: PairingInvite, epochKey: Data, offer: PairingOffer, publicOfferBytes: Data) {
        self.invite = invite; self.epochKey = epochKey; self.offer = offer; self.publicOfferBytes = publicOfferBytes
    }

    /// Persist this immutable state in device-only protected storage BEFORE publishing the offer.
    public func encodedForLocalStorage() -> Data {
        var writer = PairingWire.localWriter("creator")
        writer.bytes(invite.localBytes); writer.bytes(epochKey); writer.lengthPrefixed(publicOfferBytes)
        return writer.data
    }
    public init(localState: Data) throws {
        var reader = try PairingWire.localReader(localState, kind: "creator")
        let invite = try PairingInvite(localBytes: reader.bytes(48))
        let key = try reader.bytes(32)
        let bytes = try reader.lengthPrefixed(maximum: PairingProtocol.maximumBoxBytes)
        guard reader.isAtEnd else { throw PairingError.malformed }
        let offer = try PairingProtocol.decodeOffer(bytes, invite: invite)
        guard PairingWire.equal(offer.commitment, try PairingProtocol.epochKeyCommitment(epochKey: key,
            conversationID: offer.conversationID, keyEpoch: offer.epoch)) else { throw PairingError.commitmentMismatch }
        self.init(invite: invite, epochKey: key, offer: offer, publicOfferBytes: bytes)
    }

    /// Validate against the authenticated claimed UID. The caller MUST atomically pin the first
    /// returned exact acceptance in device-only storage before making/publishing a grant. Pure
    /// crypto cannot perform one-time redemption or stop reuse of a stale copy of this value.
    public func pinAcceptance(publicAcceptance: Data, expectedRecipientID: String,
        nowMilliseconds: UInt64) throws -> ClaimedCreatorPairingState {
        try PairingWire.validateExpiry(offer.expires, now: nowMilliseconds)
        let acceptance = try PairingProtocol.decodeAcceptance(publicAcceptance, creator: self, expectedRecipientID: expectedRecipientID)
        return ClaimedCreatorPairingState(creator: self, acceptance: acceptance, publicAcceptanceBytes: publicAcceptance)
    }
}

public struct ClaimedCreatorPairingState: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let creator: CreatorPairingState
    public let publicAcceptanceBytes: Data
    fileprivate let acceptance: PairingAcceptance
    public var acceptanceHash: Data { PairingWire.hash(publicAcceptanceBytes) }
    public var transcriptHash: Data { PairingWire.transcript(offer: creator.publicOfferBytes, acceptance: publicAcceptanceBytes) }
    public var recipientID: String { acceptance.recipientID }
    public var claimIDHex: String { PairingWire.hex(acceptance.claimID) }
    public var description: String { "ClaimedCreatorPairingState(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
    fileprivate init(creator: CreatorPairingState, acceptance: PairingAcceptance, publicAcceptanceBytes: Data) {
        self.creator = creator; self.acceptance = acceptance; self.publicAcceptanceBytes = publicAcceptanceBytes
    }
    public func encodedForLocalStorage() -> Data {
        var writer = PairingWire.localWriter("claimed-creator")
        writer.lengthPrefixed(creator.encodedForLocalStorage()); writer.lengthPrefixed(publicAcceptanceBytes)
        return writer.data
    }
    public init(localState: Data) throws {
        var reader = try PairingWire.localReader(localState, kind: "claimed-creator")
        let creator = try CreatorPairingState(localState: reader.lengthPrefixed(maximum: PairingProtocol.maximumLocalStateBytes))
        let bytes = try reader.lengthPrefixed(maximum: PairingProtocol.maximumBoxBytes)
        guard reader.isAtEnd else { throw PairingError.malformed }
        let clear = try PairingWire.open(bytes, kind: "acceptance", invite: creator.invite,
            binder: creator.offerHash, purpose: "acceptance-key")
        let acceptance = try PairingAcceptance.decode(clear)
        try acceptance.matches(offer: creator.offer, offerBytes: creator.publicOfferBytes)
        self.init(creator: creator, acceptance: acceptance, publicAcceptanceBytes: bytes)
    }

    /// Insert the creator's authenticated capsule before publishing a grant.
    public func creatorCapsule(nowMilliseconds: UInt64) throws -> AuthenticatedPairingCapsule {
        try PairingWire.validateExpiry(creator.offer.expires, now: nowMilliseconds)
        return try capsule(localAccountID: creator.creatorID)
    }
    fileprivate func capsule(localAccountID: String) throws -> AuthenticatedPairingCapsule {
        try AuthenticatedPairingCapsule(localAccountID: localAccountID, offer: creator.offer,
            acceptance: acceptance, key: creator.epochKey, transcriptHash: transcriptHash)
    }

    /// One fresh native HPKE sender performs ONE seal. Persist its returned exact bytes BEFORE
    /// publication; retries resend them. Recalling this method creates a different grant.
    public func makeGrant(nowMilliseconds: UInt64) throws -> Data {
        try PairingWire.validateExpiry(creator.offer.expires, now: nowMilliseconds)
        let header = PairingWire.header("grant", locator: creator.invite.locator, binder: transcriptHash)
        do {
            var sender = try HPKE.Sender(recipientKey: Curve25519.KeyAgreement.PublicKey(rawRepresentation: acceptance.recipientPublicKey),
                ciphersuite: .Curve25519_SHA256_ChachaPoly,
                info: PairingWire.hpkeInfo(locator: creator.invite.locator, transcript: transcriptHash),
                presharedKey: creator.invite.derive("grant-psk"),
                presharedKeyIdentifier: PairingWire.pskID(locator: creator.invite.locator, transcript: transcriptHash))
            let plaintext = PairingGrant(offer: creator.offer, acceptance: acceptance, transcriptHash: transcriptHash, epochKey: creator.epochKey).encoded
            let ciphertext = try sender.seal(plaintext, authenticating: header)
            var writer = BinaryWriter(); writer.bytes(header); writer.bytes(sender.encapsulatedKey); writer.lengthPrefixed(ciphertext)
            guard sender.encapsulatedKey.count == 32, writer.data.count <= PairingProtocol.maximumBoxBytes else { throw PairingError.sizeLimitExceeded }
            return writer.data
        } catch let error as PairingError { throw error }
        catch { throw PairingError.authenticationFailed }
    }
}

public struct RecipientPairingState: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let publicOfferBytes: Data
    public let publicAcceptanceBytes: Data
    public var expiresAtMilliseconds: UInt64 { offer.expires }
    public var inviteIDHex: String { invite.locatorHex }
    public var recipientID: String { acceptance.recipientID }
    public var creatorID: String { offer.creatorID }
    public var conversationID: String { offer.conversationID }
    public var keyEpoch: UInt32 { offer.epoch }
    public var claimIDHex: String { PairingWire.hex(acceptance.claimID) }
    public var transcriptHash: Data { PairingWire.transcript(offer: publicOfferBytes, acceptance: publicAcceptanceBytes) }
    fileprivate let invite: PairingInvite
    fileprivate let privateKey: Curve25519.KeyAgreement.PrivateKey
    fileprivate let offer: PairingOffer
    fileprivate let acceptance: PairingAcceptance
    public var description: String { "RecipientPairingState(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
    fileprivate init(invite: PairingInvite, privateKey: Curve25519.KeyAgreement.PrivateKey, offer: PairingOffer,
                     acceptance: PairingAcceptance, publicOfferBytes: Data, publicAcceptanceBytes: Data) {
        self.invite = invite; self.privateKey = privateKey; self.offer = offer; self.acceptance = acceptance
        self.publicOfferBytes = publicOfferBytes; self.publicAcceptanceBytes = publicAcceptanceBytes
    }
    /// Device-only storage BEFORE claiming: losing this private key cannot be repaired by
    /// generating a replacement for the same public acceptance. Never synchronize pending state.
    public func encodedForLocalStorage() -> Data {
        var writer = PairingWire.localWriter("recipient")
        writer.bytes(invite.localBytes); writer.bytes(privateKey.rawRepresentation)
        writer.lengthPrefixed(publicOfferBytes); writer.lengthPrefixed(publicAcceptanceBytes)
        return writer.data
    }
    public init(localState: Data) throws {
        var reader = try PairingWire.localReader(localState, kind: "recipient")
        let invite = try PairingInvite(localBytes: reader.bytes(48))
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: reader.bytes(32))
        let offerBytes = try reader.lengthPrefixed(maximum: PairingProtocol.maximumBoxBytes)
        let acceptanceBytes = try reader.lengthPrefixed(maximum: PairingProtocol.maximumBoxBytes)
        guard reader.isAtEnd else { throw PairingError.malformed }
        let offer = try PairingProtocol.decodeOffer(offerBytes, invite: invite)
        let acceptance = try PairingAcceptance.decode(PairingWire.open(acceptanceBytes, kind: "acceptance", invite: invite,
            binder: PairingWire.hash(offerBytes), purpose: "acceptance-key"))
        try acceptance.matches(offer: offer, offerBytes: offerBytes)
        guard privateKey.publicKey.rawRepresentation == acceptance.recipientPublicKey else { throw PairingError.transcriptMismatch }
        self.init(invite: invite, privateKey: privateKey, offer: offer, acceptance: acceptance,
                  publicOfferBytes: offerBytes, publicAcceptanceBytes: acceptanceBytes)
    }

    /// Only this locally pinned acceptance's private key and the invite PSK can open the grant.
    /// Exact retry is idempotent; replay/single-claim policy belongs to durable state+backend CAS.
    public func openGrant(grant: Data, nowMilliseconds: UInt64) throws -> AuthenticatedPairingCapsule {
        try PairingWire.validateExpiry(offer.expires, now: nowMilliseconds)
        var reader = try PairingWire.boxReader(grant)
        let header = try PairingWire.readHeader(&reader, kind: "grant", locator: invite.locator, binder: transcriptHash)
        let encapsulated = try reader.bytes(32)
        let ciphertext = try reader.lengthPrefixed(maximum: PairingProtocol.maximumBoxBytes)
        guard reader.isAtEnd, ciphertext.count >= 16 else { throw PairingError.malformed }
        let plaintext: Data
        do {
            var recipient = try HPKE.Recipient(privateKey: privateKey, ciphersuite: .Curve25519_SHA256_ChachaPoly,
                info: PairingWire.hpkeInfo(locator: invite.locator, transcript: transcriptHash), encapsulatedKey: encapsulated,
                presharedKey: invite.derive("grant-psk"),
                presharedKeyIdentifier: PairingWire.pskID(locator: invite.locator, transcript: transcriptHash))
            plaintext = try recipient.open(ciphertext, authenticating: header)
        } catch { throw PairingError.authenticationFailed }
        let clear = try PairingGrant.decode(plaintext)
        guard clear.offer.encoded == offer.encoded, clear.acceptance.encoded == acceptance.encoded,
              clear.transcriptHash == transcriptHash else { throw PairingError.transcriptMismatch }
        return try AuthenticatedPairingCapsule(localAccountID: acceptance.recipientID, offer: offer,
            acceptance: acceptance, key: clear.epochKey, transcriptHash: transcriptHash)
    }
}

/// Authenticated result for an explicit protected-storage adapter, not a serializable relay object.
/// Contains no sender authentication stronger than possession of the out-of-band invite secret.
public struct AuthenticatedPairingCapsule: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let localAccountID: String
    public let creatorID: String
    public let recipientID: String
    public let conversationID: String
    public let keyEpoch: UInt32
    public let contentSuite: String
    public let transcriptHash: Data
    public let protocolKeyCommitment: Data
    public let expectedKeyCommitment: Data
    private let key: Data
    public var description: String { "AuthenticatedPairingCapsule(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
    fileprivate init(localAccountID: String, offer: PairingOffer, acceptance: PairingAcceptance, key: Data, transcriptHash: Data) throws {
        guard PairingWire.same(localAccountID, offer.creatorID) || PairingWire.same(localAccountID, acceptance.recipientID),
              transcriptHash.count == 32 else { throw PairingError.recipientMismatch }
        let actual = try PairingProtocol.epochKeyCommitment(epochKey: key, conversationID: offer.conversationID, keyEpoch: offer.epoch)
        guard PairingWire.equal(actual, offer.commitment) else { throw PairingError.commitmentMismatch }
        self.localAccountID = localAccountID; creatorID = offer.creatorID; recipientID = acceptance.recipientID
        conversationID = offer.conversationID; keyEpoch = offer.epoch; contentSuite = PairingProtocol.contentSuite
        self.transcriptHash = transcriptHash; protocolKeyCommitment = offer.commitment; self.key = key
        expectedKeyCommitment = try TrustedKeyDescriptor.commitment(for: key,
            scope: KeyScope(accountID: localAccountID, conversationID: offer.conversationID, epoch: offer.epoch))
    }
    /// Export only for protected capsule storage / explicit local installation. Never send to relay.
    public func keyMaterialForLocalStorage() -> Data { key }
    public func trustedDescriptor() throws -> TrustedKeyDescriptor {
        try TrustedKeyDescriptor(scope: KeyScope(accountID: localAccountID, conversationID: conversationID, epoch: keyEpoch),
                                 expectedKeyCommitment: expectedKeyCommitment)
    }
}
