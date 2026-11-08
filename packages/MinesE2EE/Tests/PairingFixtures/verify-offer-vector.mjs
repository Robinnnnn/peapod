// Independent application framing/AEAD fixture; Node standard crypto, synthetic data only.
import assert from "node:assert/strict";
import { createHash, hkdfSync, createCipheriv } from "node:crypto";
import { readFile } from "node:fs/promises";
const expected = JSON.parse(await readFile(new URL("./pairing-offer-vector.json", import.meta.url), "utf8"));
const utf8 = (value) => Buffer.from(value, "utf8");
const uint32 = (value) => { const bytes = Buffer.alloc(4); bytes.writeUInt32BE(value); return bytes; };
const uint64 = (value) => { const bytes = Buffer.alloc(8); bytes.writeBigUInt64BE(BigInt(value)); return bytes; };
const lp = (value) => { const bytes = utf8(value); return Buffer.concat([uint32(bytes.length), bytes]); };
const hash = (value) => createHash("sha256").update(value).digest();
const locator = Buffer.from(Array.from({ length: 16 }, (_, index) => index));
const secret = Buffer.from(Array.from({ length: 32 }, (_, index) => index + 32));
const epochKey = Buffer.from(Array.from({ length: 32 }, (_, index) => index));
const conversation = "01234567-89ab-cdef-0123-456789abcdef";
const commitment = hash(Buffer.concat([utf8("mines/pairing/v1/epoch-key\0"), lp(conversation), uint32(1), lp("mines-e2ee-v1"), epochKey]));
const header = Buffer.concat([utf8("mines/pairing/v1/offer\0"), uint32(1), lp("mines-pairing-v1"), locator]);
const plaintext = Buffer.concat([uint32(1), lp("mines-e2ee-v1"), locator, lp("alice"), lp(conversation), uint32(1), uint64(1700000900000), commitment]);
const salt = hash(Buffer.concat([utf8("mines/pairing/v1/salt\0"), locator]));
const derivedKey = Buffer.from(hkdfSync("sha256", secret, salt, utf8("mines/pairing/v1/offer-key\0"), 32));
const nonce = Buffer.from(Array.from({ length: 12 }, (_, index) => index));
const cipher = createCipheriv("chacha20-poly1305", derivedKey, nonce, { authTagLength: 16 });
cipher.setAAD(header);
const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final()]);
const combined = Buffer.concat([nonce, ciphertext, cipher.getAuthTag()]);
const envelope = Buffer.concat([header, uint32(combined.length), combined]);
for (const [name, bytes] of Object.entries({ commitment, header, plaintext, salt, derivedKey, envelope, offerHash: hash(envelope) })) {
  assert.equal(bytes.toString("hex"), expected[`${name}Hex`]);
}
console.log("Pairing Offer independent vector passed: framing, commitment, HKDF, AEAD, exact hash.");
