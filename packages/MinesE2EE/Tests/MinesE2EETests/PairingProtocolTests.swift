import CryptoKit
import Foundation
import XCTest
@testable import MinesE2EE

final class PairingProtocolTests: XCTestCase {
    let now: UInt64 = 1_700_000_000_000
    let conversation = "01234567-89ab-cdef-0123-456789abcdef"
    let key = Data(0..<32)

    func creator(creatorID: String = "alice", conversationID: String? = nil) throws -> CreatorPairingState {
        try PairingProtocol.makeCreatorOffer(creatorID: creatorID, conversationID: conversationID ?? conversation,
            epoch: 1, epochKey: key, expiresAtMilliseconds: now + 900_000, nowMilliseconds: now)
    }
    func recipient(_ creator: CreatorPairingState, recipientID: String = "bob") throws -> RecipientPairingState {
        try PairingProtocol.makeAcceptance(publicOffer: creator.publicOfferBytes, invite: PairingInvite(shareFragment: creator.invite.shareFragment()),
            recipientID: recipientID, nowMilliseconds: now)
    }
    func claim(_ creator: CreatorPairingState, _ recipient: RecipientPairingState) throws -> ClaimedCreatorPairingState {
        try creator.pinAcceptance(publicAcceptance: recipient.publicAcceptanceBytes, expectedRecipientID: recipient.recipientID, nowMilliseconds: now)
    }
    func assertError(_ expected: PairingError, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { XCTAssertEqual($0 as? PairingError, expected, file: file, line: line) }
    }

    func testFullRoundTripAndLocalAccountSpecificDescriptors() throws {
        let creator = try creator()
        let recipient = try recipient(creator)
        let claimed = try claim(creator, recipient)
        let grant = try claimed.makeGrant(nowMilliseconds: now)
        let creatorCapsule = try claimed.creatorCapsule(nowMilliseconds: now)
        let recipientCapsule = try recipient.openGrant(grant: grant, nowMilliseconds: now)
        XCTAssertEqual(recipientCapsule.keyMaterialForLocalStorage(), key)
        XCTAssertEqual(creatorCapsule.keyMaterialForLocalStorage(), key)
        XCTAssertEqual(recipientCapsule.creatorID, "alice")
        XCTAssertEqual(recipientCapsule.recipientID, "bob")
        XCTAssertEqual(recipientCapsule.localAccountID, "bob")
        XCTAssertEqual(creatorCapsule.localAccountID, "alice")
        XCTAssertEqual(recipientCapsule.protocolKeyCommitment, creatorCapsule.protocolKeyCommitment)
        XCTAssertEqual(recipientCapsule.transcriptHash, creatorCapsule.transcriptHash)
        XCTAssertEqual(recipientCapsule.contentSuite, "mines-e2ee-v1")
        XCTAssertNotEqual(recipientCapsule.expectedKeyCommitment, creatorCapsule.expectedKeyCommitment)
        let scope = KeyScope(accountID: "bob", conversationID: conversation, epoch: 1)
        XCTAssertEqual(recipientCapsule.expectedKeyCommitment, try TrustedKeyDescriptor.commitment(for: key, scope: scope))
        XCTAssertEqual(try recipientCapsule.trustedDescriptor().scope, scope)
        // Once bytes are persisted, retries reuse exactly one grant; opening it is idempotent.
        XCTAssertEqual(try recipient.openGrant(grant: grant, nowMilliseconds: now).transcriptHash, recipientCapsule.transcriptHash)
        XCTAssertNotEqual(try claimed.makeGrant(nowMilliseconds: now), grant) // Resealing is NOT a retry.
    }

    func testPendingStateRestorationPreservesExactPinnedTranscript() throws {
        let originalCreator = try creator()
        let creator = try CreatorPairingState(localState: originalCreator.encodedForLocalStorage())
        XCTAssertEqual(creator.publicOfferBytes, originalCreator.publicOfferBytes)
        XCTAssertEqual(creator.invite.shareFragment(), originalCreator.invite.shareFragment())
        let originalRecipient = try recipient(creator)
        let recipient = try RecipientPairingState(localState: originalRecipient.encodedForLocalStorage())
        XCTAssertEqual(recipient.publicAcceptanceBytes, originalRecipient.publicAcceptanceBytes)
        XCTAssertEqual(recipient.transcriptHash, originalRecipient.transcriptHash)
        let claimed = try claim(creator, recipient)
        let restoredClaim = try ClaimedCreatorPairingState(localState: claimed.encodedForLocalStorage())
        XCTAssertEqual(restoredClaim.acceptanceHash, claimed.acceptanceHash)
        XCTAssertEqual(restoredClaim.claimIDHex, recipient.claimIDHex)
        let grant = try restoredClaim.makeGrant(nowMilliseconds: now)
        XCTAssertEqual(try recipient.openGrant(grant: grant, nowMilliseconds: now).keyMaterialForLocalStorage(), key)
        var badPrivate = recipient.encodedForLocalStorage()
        let keyOffset = "mines/pairing/local/recipient\0".utf8.count + 4 + 48
        badPrivate[keyOffset + 16] ^= 1
        assertError(.transcriptMismatch) { _ = try RecipientPairingState(localState: badPrivate) }
        var badEpochKey = creator.encodedForLocalStorage()
        badEpochKey["mines/pairing/local/creator\0".utf8.count + 4 + 48] ^= 1
        assertError(.commitmentMismatch) { _ = try CreatorPairingState(localState: badEpochKey) }
    }

    func testRFC9180AppendixA22NativePSKKnownAnswer() throws {
        // Official independent HPKE PSK vector, X25519/HKDF-SHA256/ChaCha20Poly1305:
        // https://www.rfc-editor.org/rfc/rfc9180.html#appendix-A.2.2
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation:
            Data(hex: "77d114e0212be51cb1d76fa99dd41cfd4d0166b08caa09074430a6c59ef17879"))
        let info = Data(hex: "4f6465206f6e2061204772656369616e2055726e")
        let encapsulated = Data(hex: "2261299c3f40a9afc133b969a97f05e95be2c514e54f3de26cbe5644ac735b04")
        let psk = SymmetricKey(data: Data(hex: "0247fd33b913760fa1fa51e1892d9f307fbe65eb171e8132c2af18555a738b82"))
        let pskID = Data(hex: "456e6e796e20447572696e206172616e204d6f726961")
        var recipient = try HPKE.Recipient(privateKey: privateKey, ciphersuite: .Curve25519_SHA256_ChachaPoly,
            info: info, encapsulatedKey: encapsulated, presharedKey: psk, presharedKeyIdentifier: pskID)
        XCTAssertEqual(try recipient.exportSecret(context: Data(), outputByteCount: 32).withUnsafeBytes { Data($0).hex },
                       "813c1bfc516c99076ae0f466671f0ba5ff244a41699f7b2417e4c59d46d39f40")
        let ciphertexts = [
            "4a177f9c0d6f15cfdf533fb65bf84aecdc6ab16b8b85b4cf65a370e07fc1d78d28fb073214525276f4a89608ff",
            "5c3cabae2f0b3e124d8d864c116fd8f20f3f56fda988c3573b40b09997fd6c769e77c8eda6cda4f947f5b704a8",
            "14958900b44bdae9cbe5a528bf933c5c990dbb8e282e6e495adf8205d19da9eb270e3a6f1e0613ab7e757962a4"
        ]
        for (sequence, ciphertext) in ciphertexts.enumerated() {
            XCTAssertEqual(try recipient.open(Data(hex: ciphertext), authenticating: Data("Count-\(sequence)".utf8)).hex,
                           "4265617574792069732074727574682c20747275746820626561757479")
        }
        var wrongPSK = try HPKE.Recipient(privateKey: privateKey, ciphersuite: .Curve25519_SHA256_ChachaPoly,
            info: info, encapsulatedKey: encapsulated, presharedKey: SymmetricKey(size: .bits256), presharedKeyIdentifier: pskID)
        XCTAssertThrowsError(try wrongPSK.open(Data(hex: ciphertexts[0]), authenticating: Data("Count-0".utf8)))
    }

    func testIndependentNodeApplicationOfferFramingFixture() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PairingFixtures/pairing-offer-vector.json")
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as! [String: String]
        let locator = Data(0..<16)
        let secret = Data(32..<64)
        let invite = try PairingInvite(shareFragment: "v1.\(locator.hex).\(PairingWire.base64url(secret))")
        let commitment = try PairingProtocol.epochKeyCommitment(epochKey: key, conversationID: conversation, keyEpoch: 1)
        XCTAssertEqual(commitment.hex, fixture["commitmentHex"])
        XCTAssertEqual(PairingWire.header("offer", locator: locator, binder: nil).hex, fixture["headerHex"])
        XCTAssertEqual(invite.derive("offer-key").withUnsafeBytes { Data($0).hex }, fixture["derivedKeyHex"])
        let envelope = Data(hex: fixture["envelopeHex"]!)
        XCTAssertEqual(PairingWire.hash(envelope).hex, fixture["offerHashHex"])
        let plaintext = try PairingWire.open(envelope, kind: "offer", invite: invite, binder: nil, purpose: "offer-key")
        XCTAssertEqual(plaintext.hex, fixture["plaintextHex"])
        XCTAssertEqual(try PairingOffer.decode(plaintext).encoded, plaintext)
        let recipient = try PairingProtocol.makeAcceptance(publicOffer: envelope, invite: invite, recipientID: "bob", nowMilliseconds: now)
        var stored = PairingWire.localWriter("creator")
        stored.bytes(locator + secret); stored.bytes(key); stored.lengthPrefixed(envelope)
        let creator = try CreatorPairingState(localState: stored.data)
        let grant = try claim(creator, recipient).makeGrant(nowMilliseconds: now)
        XCTAssertEqual(try recipient.openGrant(grant: grant, nowMilliseconds: now).keyMaterialForLocalStorage(), key)
    }

    func testWrongSecretOfferAcceptanceAndGrantTamperFailClosed() throws {
        let creator = try creator()
        let recipient = try recipient(creator)
        let claimed = try claim(creator, recipient)
        let grant = try claimed.makeGrant(nowMilliseconds: now)
        let wrongInvite = try modifiedInvite(creator.invite)
        assertError(.authenticationFailed) {
            _ = try PairingProtocol.makeAcceptance(publicOffer: creator.publicOfferBytes, invite: wrongInvite, recipientID: "bob", nowMilliseconds: now)
        }
        for kind in ["offer", "acceptance", "grant"] {
            let original = kind == "offer" ? creator.publicOfferBytes : kind == "acceptance" ? recipient.publicAcceptanceBytes : grant
            let headerCount = PairingWire.header(kind, locator: creator.invite.locator,
                binder: kind == "offer" ? nil : kind == "acceptance" ? creator.offerHash : recipient.transcriptHash).count
            // Nonce/encapsulation, ciphertext, and tag mutations.
            let positions = kind == "grant" ? [headerCount, headerCount + 32 + 4, original.count - 1] : [headerCount + 4, headerCount + 4 + 12, original.count - 1]
            for position in positions {
                var changed = original; changed[position] ^= 1
                XCTAssertThrowsError(try open(kind: kind, bytes: changed, creator: creator, recipient: recipient))
            }
        }
    }

    func testStolenInviteSecretStillRequiresAcceptedRecipientPrivateKey() throws {
        let creator = try creator()
        let recipient = try recipient(creator)
        let grant = try claim(creator, recipient).makeGrant(nowMilliseconds: now)
        var reader = BinaryReader(grant)
        let header = try PairingWire.readHeader(&reader, kind: "grant", locator: creator.invite.locator, binder: recipient.transcriptHash)
        let encapsulated = try reader.bytes(32)
        let ciphertext = try reader.lengthPrefixed(maximum: PairingProtocol.maximumBoxBytes)
        let stolenInvite = try PairingInvite(shareFragment: creator.invite.shareFragment())
        var attacker = try HPKE.Recipient(privateKey: Curve25519.KeyAgreement.PrivateKey(), ciphersuite: .Curve25519_SHA256_ChachaPoly,
            info: PairingWire.hpkeInfo(locator: stolenInvite.locator, transcript: recipient.transcriptHash),
            encapsulatedKey: encapsulated, presharedKey: stolenInvite.derive("grant-psk"),
            presharedKeyIdentifier: PairingWire.pskID(locator: stolenInvite.locator, transcript: recipient.transcriptHash))
        XCTAssertThrowsError(try attacker.open(ciphertext, authenticating: header))
    }

    func testWrongRecipientChangedClaimAndReplayAcrossInvitesAreRejected() throws {
        let creator = try creator()
        let recipient = try recipient(creator)
        assertError(.recipientMismatch) {
            _ = try creator.pinAcceptance(publicAcceptance: recipient.publicAcceptanceBytes, expectedRecipientID: "eve", nowMilliseconds: now)
        }
        let grant = try claim(creator, recipient).makeGrant(nowMilliseconds: now)
        let differentClaim = try self.recipient(creator)
        XCTAssertNotEqual(differentClaim.claimIDHex, recipient.claimIDHex)
        assertError(.transcriptMismatch) { _ = try differentClaim.openGrant(grant: grant, nowMilliseconds: now) }
        let otherCreator = try self.creator(conversationID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        XCTAssertThrowsError(try otherCreator.pinAcceptance(publicAcceptance: recipient.publicAcceptanceBytes, expectedRecipientID: "bob", nowMilliseconds: now))
        let otherRecipient = try self.recipient(otherCreator)
        XCTAssertThrowsError(try otherRecipient.openGrant(grant: grant, nowMilliseconds: now))
        assertError(.recipientMismatch) { _ = try self.recipient(creator, recipientID: "alice") }
        // This pure API deliberately cannot prevent pinning two copies: durable stage/CAS owns first-claim policy.
        XCTAssertNotEqual(try claim(creator, differentClaim).acceptanceHash, try claim(creator, recipient).acceptanceHash)
    }

    func testAuthenticatedAcceptanceChangesEveryContextFieldAreRejected() throws {
        let creator = try creator()
        let recipient = try recipient(creator)
        let original = try PairingAcceptance.decode(PairingWire.open(recipient.publicAcceptanceBytes, kind: "acceptance",
            invite: creator.invite, binder: creator.offerHash, purpose: "acceptance-key"))
        let otherPublicKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        func copy(locator: Data? = nil, offerHash: Data? = nil, creatorID: String? = nil, recipientID: String? = nil,
                  conversationID: String? = nil, epoch: UInt32? = nil, claimID: Data? = nil, publicKey: Data? = nil) -> PairingAcceptance {
            PairingAcceptance(locator: locator ?? original.locator, offerHash: offerHash ?? original.offerHash,
                creatorID: creatorID ?? original.creatorID, recipientID: recipientID ?? original.recipientID,
                conversationID: conversationID ?? original.conversationID, epoch: epoch ?? original.epoch,
                claimID: claimID ?? original.claimID, recipientPublicKey: publicKey ?? original.recipientPublicKey)
        }
        for changed in [copy(locator: Data(repeating: 0, count: 16)), copy(offerHash: Data(repeating: 0, count: 32)),
                        copy(creatorID: "other"), copy(recipientID: "eve"), copy(conversationID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"), copy(epoch: 2)] {
            let box = try PairingWire.seal(changed.encoded, kind: "acceptance", invite: creator.invite, binder: creator.offerHash, purpose: "acceptance-key")
            XCTAssertThrowsError(try creator.pinAcceptance(publicAcceptance: box, expectedRecipientID: "bob", nowMilliseconds: now))
        }
        // Claim/key changes yield a different pinned transcript and cannot receive the original grant.
        let originalGrant = try claim(creator, recipient).makeGrant(nowMilliseconds: now)
        for changed in [copy(claimID: Data(repeating: 0, count: 16)), copy(publicKey: otherPublicKey)] {
            let box = try PairingWire.seal(changed.encoded, kind: "acceptance", invite: creator.invite, binder: creator.offerHash, purpose: "acceptance-key")
            let different = try creator.pinAcceptance(publicAcceptance: box, expectedRecipientID: "bob", nowMilliseconds: now)
            XCTAssertNotEqual(different.transcriptHash, recipient.transcriptHash)
            let grant = try different.makeGrant(nowMilliseconds: now)
            XCTAssertNotEqual(grant, originalGrant)
            assertError(.transcriptMismatch) { _ = try recipient.openGrant(grant: grant, nowMilliseconds: now) }
        }
        let lowOrder = copy(publicKey: Data(repeating: 0, count: 32))
        let lowOrderBox = try PairingWire.seal(lowOrder.encoded, kind: "acceptance", invite: creator.invite, binder: creator.offerHash, purpose: "acceptance-key")
        assertError(.invalidKey) { _ = try creator.pinAcceptance(publicAcceptance: lowOrderBox, expectedRecipientID: "bob", nowMilliseconds: now) }
    }

    func testCommitmentRejectsAuthenticatedButDifferentEpochKeyGrant() throws {
        let creator = try creator()
        let recipient = try recipient(creator)
        let claimed = try claim(creator, recipient)
        let offer = try PairingOffer.decode(PairingWire.open(creator.publicOfferBytes, kind: "offer", invite: creator.invite, binder: nil, purpose: "offer-key"))
        let acceptance = try PairingAcceptance.decode(PairingWire.open(recipient.publicAcceptanceBytes, kind: "acceptance", invite: creator.invite, binder: creator.offerHash, purpose: "acceptance-key"))
        let mismatched = PairingGrant(offer: offer, acceptance: acceptance, transcriptHash: claimed.transcriptHash, epochKey: Data(repeating: 0xF1, count: 32))
        let grant = try nativeGrant(mismatched.encoded, invite: creator.invite, acceptance: acceptance, transcript: claimed.transcriptHash)
        assertError(.commitmentMismatch) { _ = try recipient.openGrant(grant: grant, nowMilliseconds: now) }
    }

    func testExpiryAtEveryTransitionAndLifetimeBounds() throws {
        let creator = try creator()
        let recipient = try recipient(creator)
        let claimed = try claim(creator, recipient)
        let grant = try claimed.makeGrant(nowMilliseconds: now)
        let expired = creator.expiresAtMilliseconds
        assertError(.expired) { _ = try PairingProtocol.makeAcceptance(publicOffer: creator.publicOfferBytes, invite: creator.invite, recipientID: "bob", nowMilliseconds: expired) }
        assertError(.expired) { _ = try creator.pinAcceptance(publicAcceptance: recipient.publicAcceptanceBytes, expectedRecipientID: "bob", nowMilliseconds: expired) }
        assertError(.expired) { _ = try claimed.makeGrant(nowMilliseconds: expired) }
        assertError(.expired) { _ = try claimed.creatorCapsule(nowMilliseconds: expired) }
        assertError(.expired) { _ = try recipient.openGrant(grant: grant, nowMilliseconds: expired) }
        assertError(.expired) { _ = try PairingProtocol.makeCreatorOffer(creatorID: "alice", conversationID: conversation, epoch: 1, epochKey: key, expiresAtMilliseconds: now, nowMilliseconds: now) }
        assertError(.invalidExpiry) { _ = try PairingProtocol.makeCreatorOffer(creatorID: "alice", conversationID: conversation, epoch: 1, epochKey: key,
            expiresAtMilliseconds: now + PairingProtocol.maximumLifetimeMilliseconds + 1, nowMilliseconds: now) }
        // Clock rollback is a documented external trust boundary, bounded here by max remaining lifetime.
        assertError(.invalidExpiry) { _ = try recipient.openGrant(grant: grant, nowMilliseconds: 0) }
    }

    func testStrictFragmentUUIDIdentityVersionsAndBounds() throws {
        let creator = try creator()
        let fragment = creator.invite.shareFragment()
        XCTAssertEqual(fragment.utf8.count, 79)
        XCTAssertEqual(try PairingInvite(shareFragment: fragment).shareFragment(), fragment)
        for wrong in [fragment.uppercased(), fragment + "=", fragment + "#x", fragment.replacingOccurrences(of: "v1.", with: "v2."), ""] {
            XCTAssertThrowsError(try PairingInvite(shareFragment: wrong))
        }
        XCTAssertThrowsError(try self.creator(conversationID: conversation.uppercased()))
        XCTAssertThrowsError(try self.creator(creatorID: String(repeating: "😀", count: 65)))
        XCTAssertThrowsError(try PairingProtocol.makeCreatorOffer(creatorID: "alice", conversationID: conversation, epoch: 0, epochKey: key, expiresAtMilliseconds: now + 1, nowMilliseconds: now))
        XCTAssertThrowsError(try PairingProtocol.makeCreatorOffer(creatorID: "alice", conversationID: conversation, epoch: 1, epochKey: Data(), expiresAtMilliseconds: now + 1, nowMilliseconds: now))
        let recipient = try recipient(creator)
        let grant = try claim(creator, recipient).makeGrant(nowMilliseconds: now)
        for kind in ["offer", "acceptance", "grant"] {
            let original = kind == "offer" ? creator.publicOfferBytes : kind == "acceptance" ? recipient.publicAcceptanceBytes : grant
            for length in 0..<original.count { XCTAssertThrowsError(try open(kind: kind, bytes: Data(original.prefix(length)), creator: creator, recipient: recipient)) }
            XCTAssertThrowsError(try open(kind: kind, bytes: original + Data([0]), creator: creator, recipient: recipient))
            XCTAssertThrowsError(try open(kind: kind, bytes: Data(repeating: 0, count: PairingProtocol.maximumBoxBytes + 1), creator: creator, recipient: recipient))
            var future = original
            future["mines/pairing/v1/\(kind)\0".utf8.count + 3] = 2
            assertError(.unsupportedVersion) { try open(kind: kind, bytes: future, creator: creator, recipient: recipient) }
            var suite = original
            suite["mines/pairing/v1/\(kind)\0".utf8.count + 8] = 0x58
            assertError(.unsupportedSuite) { try open(kind: kind, bytes: suite, creator: creator, recipient: recipient) }
        }
        for state in [creator.encodedForLocalStorage(), recipient.encodedForLocalStorage(), try claim(creator, recipient).encodedForLocalStorage()] {
            XCTAssertLessThan(state.count, PairingProtocol.maximumLocalStateBytes)
        }
        XCTAssertThrowsError(try CreatorPairingState(localState: creator.encodedForLocalStorage() + Data([0])))
        XCTAssertThrowsError(try RecipientPairingState(localState: Data(repeating: 0, count: PairingProtocol.maximumLocalStateBytes + 1)))
    }

    func testByteExactRecipientIdentityAndRedactedDescriptionsNoRelaySecrets() throws {
        let creator = try self.creator(creatorID: "caf\u{e9}")
        let recipient = try self.recipient(creator, recipientID: "cafe\u{301}")
        XCTAssertEqual(creator.creatorID, recipient.recipientID) // Swift canonical-equivalent equality.
        let claimed = try claim(creator, recipient) // Protocol byte-exact identities are distinct.
        let grant = try claimed.makeGrant(nowMilliseconds: now)
        let capsule = try recipient.openGrant(grant: grant, nowMilliseconds: now)
        assertError(.recipientMismatch) { _ = try creator.pinAcceptance(publicAcceptance: recipient.publicAcceptanceBytes, expectedRecipientID: creator.creatorID, nowMilliseconds: now) }
        let fragment = creator.invite.shareFragment()
        let secret = try secretBytes(creator.invite)
        for publicBytes in [creator.publicOfferBytes, recipient.publicAcceptanceBytes, grant] {
            XCTAssertNil(publicBytes.range(of: secret))
            XCTAssertNil(publicBytes.range(of: key))
            XCTAssertNil(publicBytes.range(of: Data(fragment.utf8)))
        }
        let offerPlaintext = try PairingWire.open(creator.publicOfferBytes, kind: "offer", invite: creator.invite, binder: nil, purpose: "offer-key")
        XCTAssertNil(offerPlaintext.range(of: key)) // The invite-secret-only encrypted offer contains NO epoch key.
        for description in [String(describing: creator.invite), String(reflecting: creator), String(reflecting: recipient), String(reflecting: claimed), String(reflecting: capsule)] {
            XCTAssertTrue(description.contains("redacted"))
            XCTAssertFalse(description.contains(fragment)); XCTAssertFalse(description.contains(key.hex))
        }
        for secretBearingValue: Any in [creator.invite, creator, recipient, claimed, capsule] {
            XCTAssertTrue(Mirror(reflecting: secretBearingValue).children.isEmpty)
            var reflected = ""; dump(secretBearingValue, to: &reflected)
            XCTAssertFalse(reflected.contains(fragment)); XCTAssertFalse(reflected.contains(key.hex))
        }
        XCTAssertNotEqual(creator.invite.derive("offer-key").withUnsafeBytes { Data($0) }, creator.invite.derive("acceptance-key").withUnsafeBytes { Data($0) })
        XCTAssertNotEqual(creator.invite.derive("offer-key").withUnsafeBytes { Data($0) }, creator.invite.derive("grant-psk").withUnsafeBytes { Data($0) })
    }

    func testAuthenticatedPrivateFutureSuiteVersionAndHugeLengthsRejected() throws {
        let creator = try creator()
        let original = try PairingWire.open(creator.publicOfferBytes, kind: "offer", invite: creator.invite, binder: nil, purpose: "offer-key")
        for (position, expected) in [(3, PairingError.unsupportedVersion), (8, PairingError.unsupportedSuite)] {
            var changed = original; changed[position] = position == 3 ? 2 : 0x58
            let bytes = try PairingWire.seal(changed, kind: "offer", invite: creator.invite, binder: nil, purpose: "offer-key")
            assertError(expected) { _ = try PairingProtocol.makeAcceptance(publicOffer: bytes, invite: creator.invite, recipientID: "bob", nowMilliseconds: now) }
        }
        var huge = creator.publicOfferBytes
        let length = PairingWire.header("offer", locator: creator.invite.locator, binder: nil).count
        huge.replaceSubrange(length..<(length + 4), with: [255, 255, 255, 255])
        XCTAssertThrowsError(try PairingProtocol.makeAcceptance(publicOffer: huge, invite: creator.invite, recipientID: "bob", nowMilliseconds: now))
        // An authenticated offer's private locator must equal its public AAD locator.
        var relabeled = original
        let locatorOffset = 8 + PairingProtocol.contentSuite.utf8.count
        relabeled[locatorOffset] ^= 1
        let bytes = try PairingWire.seal(relabeled, kind: "offer", invite: creator.invite, binder: nil, purpose: "offer-key")
        assertError(.transcriptMismatch) { _ = try PairingProtocol.makeAcceptance(publicOffer: bytes, invite: creator.invite, recipientID: "bob", nowMilliseconds: now) }
    }

    private func open(kind: String, bytes: Data, creator: CreatorPairingState, recipient: RecipientPairingState) throws {
        if kind == "offer" { _ = try PairingProtocol.makeAcceptance(publicOffer: bytes, invite: creator.invite, recipientID: recipient.recipientID, nowMilliseconds: now) }
        else if kind == "acceptance" { _ = try creator.pinAcceptance(publicAcceptance: bytes, expectedRecipientID: recipient.recipientID, nowMilliseconds: now) }
        else { _ = try recipient.openGrant(grant: bytes, nowMilliseconds: now) }
    }
    private func secretBytes(_ invite: PairingInvite) throws -> Data {
        let secret = String(invite.shareFragment().split(separator: ".")[2])
        return try XCTUnwrap(Data(base64Encoded: secret.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="))
    }
    private func modifiedInvite(_ invite: PairingInvite) throws -> PairingInvite {
        var secret = try secretBytes(invite); secret[0] ^= 1
        return try PairingInvite(shareFragment: "v1.\(invite.locatorHex).\(PairingWire.base64url(secret))")
    }
    private func nativeGrant(_ plaintext: Data, invite: PairingInvite, acceptance: PairingAcceptance, transcript: Data) throws -> Data {
        let header = PairingWire.header("grant", locator: invite.locator, binder: transcript)
        var sender = try HPKE.Sender(recipientKey: Curve25519.KeyAgreement.PublicKey(rawRepresentation: acceptance.recipientPublicKey),
            ciphersuite: .Curve25519_SHA256_ChachaPoly, info: PairingWire.hpkeInfo(locator: invite.locator, transcript: transcript),
            presharedKey: invite.derive("grant-psk"), presharedKeyIdentifier: PairingWire.pskID(locator: invite.locator, transcript: transcript))
        let ciphertext = try sender.seal(plaintext, authenticating: header)
        var writer = BinaryWriter(); writer.bytes(header); writer.bytes(sender.encapsulatedKey); writer.lengthPrefixed(ciphertext)
        return writer.data
    }
}
