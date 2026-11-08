import CryptoKit
import Foundation

enum PairingWire {
    static func same(_ lhs: String, _ rhs: String) -> Bool { Data(lhs.utf8) == Data(rhs.utf8) }
    static func equal(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    static func hash(_ bytes: Data) -> Data { Data(SHA256.hash(data: bytes)) }
    static func hex(_ bytes: Data) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
    static func unhex(_ string: String, bytes: Int) throws -> Data {
        guard string.utf8.count == bytes * 2, string.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw PairingError.malformed }
        let characters = Array(string.utf8)
        var data = Data()
        for index in stride(from: 0, to: characters.count, by: 2) {
            func nibble(_ byte: UInt8) -> UInt8 { byte < 58 ? byte - 48 : byte - 87 }
            data.append(nibble(characters[index]) << 4 | nibble(characters[index + 1]))
        }
        return data
    }
    static func base64url(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func validateIdentity(_ identity: String) throws {
        guard !identity.isEmpty, identity.utf8.count <= 256 else { throw PairingError.invalidIdentity }
    }
    static func validateConversation(_ conversation: String) throws {
        guard conversation.utf8.count == 36, let uuid = UUID(uuidString: conversation),
              same(uuid.uuidString.lowercased(), conversation) else { throw PairingError.invalidIdentity }
    }
    static func validateExpiry(_ expiry: UInt64, now: UInt64) throws {
        guard expiry > now else { throw PairingError.expired }
        guard expiry - now <= PairingProtocol.maximumLifetimeMilliseconds else { throw PairingError.invalidExpiry }
    }
    static func transcript(offer: Data, acceptance: Data) -> Data {
        hash(Data("mines/pairing/v1/transcript\0".utf8) + hash(offer) + hash(acceptance))
    }
    static func hpkeInfo(locator: Data, transcript: Data) -> Data {
        Data("mines/pairing/v1/grant-info\0".utf8) + locator + transcript
    }
    static func pskID(locator: Data, transcript: Data) -> Data {
        Data("mines/pairing/v1/grant-psk-id\0".utf8) + locator + transcript
    }
    static func header(_ kind: String, locator: Data, binder: Data?) -> Data {
        var writer = BinaryWriter()
        writer.bytes(Data("mines/pairing/v1/\(kind)\0".utf8)); writer.uint32(1)
        writer.string(PairingProtocol.pairingSuite); writer.bytes(locator)
        if let binder { writer.bytes(binder) }
        return writer.data
    }
    static func boxReader(_ bytes: Data) throws -> BinaryReader {
        guard bytes.count <= PairingProtocol.maximumBoxBytes else { throw PairingError.sizeLimitExceeded }
        return BinaryReader(bytes)
    }
    static func readHeader(_ reader: inout BinaryReader, kind: String, locator: Data, binder: Data?) throws -> Data {
        try reader.expect(Data("mines/pairing/v1/\(kind)\0".utf8))
        guard try reader.uint32() == 1 else { throw PairingError.unsupportedVersion }
        guard same(try reader.string(maximum: 64), PairingProtocol.pairingSuite) else { throw PairingError.unsupportedSuite }
        guard try reader.bytes(16) == locator else { throw PairingError.transcriptMismatch }
        if let binder, try reader.bytes(32) != binder { throw PairingError.transcriptMismatch }
        return header(kind, locator: locator, binder: binder)
    }
    static func seal(_ plaintext: Data, kind: String, invite: PairingInvite, binder: Data?, purpose: String) throws -> Data {
        guard plaintext.count <= 4096 else { throw PairingError.sizeLimitExceeded }
        let aad = header(kind, locator: invite.locator, binder: binder)
        let box = try ChaChaPoly.seal(plaintext, using: invite.derive(purpose), nonce: ChaChaPoly.Nonce(), authenticating: aad)
        var writer = BinaryWriter(); writer.bytes(aad); writer.lengthPrefixed(box.combined)
        guard writer.data.count <= PairingProtocol.maximumBoxBytes else { throw PairingError.sizeLimitExceeded }
        return writer.data
    }
    static func open(_ bytes: Data, kind: String, invite: PairingInvite, binder: Data?, purpose: String) throws -> Data {
        var reader = try boxReader(bytes)
        let aad = try readHeader(&reader, kind: kind, locator: invite.locator, binder: binder)
        let combined = try reader.lengthPrefixed(maximum: 4096 + 28)
        guard reader.isAtEnd, combined.count >= 28 else { throw PairingError.malformed }
        do {
            return try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: combined), using: invite.derive(purpose), authenticating: aad)
        } catch { throw PairingError.authenticationFailed }
    }
    static func localWriter(_ kind: String) -> BinaryWriter {
        var writer = BinaryWriter(); writer.bytes(Data("mines/pairing/local/\(kind)\0".utf8)); writer.uint32(1); return writer
    }
    static func localReader(_ bytes: Data, kind: String) throws -> BinaryReader {
        guard bytes.count <= PairingProtocol.maximumLocalStateBytes else { throw PairingError.sizeLimitExceeded }
        var reader = BinaryReader(bytes); try reader.expect(Data("mines/pairing/local/\(kind)\0".utf8))
        guard try reader.uint32() == 1 else { throw PairingError.unsupportedVersion }
        return reader
    }
    static func privatePrefix(_ writer: inout BinaryWriter) {
        writer.uint32(1); writer.string(PairingProtocol.contentSuite)
    }
    static func readPrivatePrefix(_ reader: inout BinaryReader) throws {
        guard try reader.uint32() == 1 else { throw PairingError.unsupportedVersion }
        guard same(try reader.string(maximum: 64), PairingProtocol.contentSuite) else { throw PairingError.unsupportedSuite }
    }
}

struct PairingOffer: Sendable {
    let locator: Data
    let creatorID: String
    let conversationID: String
    let epoch: UInt32
    let expires: UInt64
    let commitment: Data
    var encoded: Data {
        var writer = BinaryWriter(); PairingWire.privatePrefix(&writer)
        writer.bytes(locator); writer.string(creatorID); writer.string(conversationID)
        writer.uint32(epoch); writer.uint64(expires); writer.bytes(commitment); return writer.data
    }
    static func decode(_ bytes: Data) throws -> Self {
        var reader = BinaryReader(bytes); try PairingWire.readPrivatePrefix(&reader)
        let locator = try reader.bytes(16)
        let creator = try reader.string(maximum: 256)
        let conversation = try reader.string(maximum: 256)
        let epoch = try reader.uint32(); let expires = try reader.uint64(); let commitment = try reader.bytes(32)
        try PairingWire.validateIdentity(creator); try PairingWire.validateConversation(conversation)
        guard epoch > 0, expires > 0, reader.isAtEnd else { throw PairingError.malformed }
        return Self(locator: locator, creatorID: creator, conversationID: conversation, epoch: epoch, expires: expires, commitment: commitment)
    }
}

struct PairingAcceptance: Sendable {
    let locator: Data
    let offerHash: Data
    let creatorID: String
    let recipientID: String
    let conversationID: String
    let epoch: UInt32
    let claimID: Data
    let recipientPublicKey: Data
    var encoded: Data {
        var writer = BinaryWriter(); PairingWire.privatePrefix(&writer)
        writer.bytes(locator); writer.bytes(offerHash); writer.string(creatorID); writer.string(recipientID)
        writer.string(conversationID); writer.uint32(epoch); writer.bytes(claimID); writer.bytes(recipientPublicKey)
        return writer.data
    }
    static func decode(_ bytes: Data) throws -> Self {
        var reader = BinaryReader(bytes); try PairingWire.readPrivatePrefix(&reader)
        let locator = try reader.bytes(16); let offerHash = try reader.bytes(32)
        let creator = try reader.string(maximum: 256); let recipient = try reader.string(maximum: 256)
        let conversation = try reader.string(maximum: 256); let epoch = try reader.uint32()
        let claim = try reader.bytes(16); let publicKey = try reader.bytes(32)
        try PairingWire.validateIdentity(creator); try PairingWire.validateIdentity(recipient)
        try PairingWire.validateConversation(conversation)
        guard epoch > 0, !PairingWire.same(creator, recipient), reader.isAtEnd else { throw PairingError.malformed }
        do {
            // CryptoKit's DH rejects low-order/all-zero public keys, not just bad lengths.
            _ = try Curve25519.KeyAgreement.PrivateKey().sharedSecretFromKeyAgreement(with:
                Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey))
        } catch { throw PairingError.invalidKey }
        return Self(locator: locator, offerHash: offerHash, creatorID: creator, recipientID: recipient,
                    conversationID: conversation, epoch: epoch, claimID: claim, recipientPublicKey: publicKey)
    }
    func matches(offer: PairingOffer, offerBytes: Data) throws {
        guard locator == offer.locator, offerHash == PairingWire.hash(offerBytes), PairingWire.same(creatorID, offer.creatorID),
              PairingWire.same(conversationID, offer.conversationID), epoch == offer.epoch else { throw PairingError.transcriptMismatch }
    }
}

struct PairingGrant {
    let offer: PairingOffer
    let acceptance: PairingAcceptance
    let transcriptHash: Data
    let epochKey: Data
    var encoded: Data {
        var writer = BinaryWriter(); PairingWire.privatePrefix(&writer)
        writer.lengthPrefixed(offer.encoded); writer.lengthPrefixed(acceptance.encoded)
        writer.bytes(transcriptHash); writer.bytes(epochKey); return writer.data
    }
    static func decode(_ bytes: Data) throws -> Self {
        guard bytes.count <= 4096 else { throw PairingError.sizeLimitExceeded }
        var reader = BinaryReader(bytes); try PairingWire.readPrivatePrefix(&reader)
        let offer = try PairingOffer.decode(reader.lengthPrefixed(maximum: 2048))
        let acceptance = try PairingAcceptance.decode(reader.lengthPrefixed(maximum: 2048))
        let transcript = try reader.bytes(32); let key = try reader.bytes(32)
        guard reader.isAtEnd else { throw PairingError.malformed }
        return Self(offer: offer, acceptance: acceptance, transcriptHash: transcript, epochKey: key)
    }
}
