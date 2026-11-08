import assert from "node:assert/strict";
import {randomBytes, randomUUID, createHash} from "node:crypto";
import {after, before, describe, it} from "node:test";
import {deleteApp, initializeApp} from "firebase-admin/app";
import {getFirestore, Timestamp} from "firebase-admin/firestore";
import {SecurePairingService} from "../src/securePairing.js";

assert.match(process.env.FIRESTORE_EMULATOR_HOST ?? "", /^(127\.0\.0\.1|localhost):[0-9]+$/, "Local Firestore emulator required");
const app = initializeApp({projectId: "demo-peapod"}, "secure-pairing-tests");
const db = getFirestore(app), service = new SecurePairingService(db);
const encryptedBox = () => randomBytes(80).toString("base64");
const identifier = () => randomBytes(16).toString("hex");
const hash = (value: string) => createHash("sha256").update(Buffer.from(value, "base64")).digest("hex");
const freshUser = async () => {
  const uid = `synthetic-${identifier()}`;
  await db.doc(`users/${uid}`).set({displayName: "Synthetic"});
  return uid;
};
const request = (op: Parameters<SecurePairingService["handle"]>[0], uid: string, input: Record<string, unknown>, now?: number) => service.handle(op, uid, input, now);
async function offered() {
  const creator = await freshUser(), recipient = await freshUser();
  const now = Date.now(), inviteId = identifier(), conversationId = randomUUID(), offer = encryptedBox();
  const data = {inviteId, conversationId, epoch: 1, offer, expiresAtMillis: now + 10 * 60_000};
  await request("publish", creator, data, now);
  return {creator, recipient, now, inviteId, conversationId, offer, data};
}
async function claimed() {
  const context = await offered();
  const acceptance = encryptedBox(), claimId = identifier();
  const claim = {inviteId: context.inviteId, claimId, acceptance, offerDigest: hash(context.offer)};
  await request("claim", context.recipient, claim, context.now);
  return {...context, acceptance, claim};
}
async function granted() {
  const context = await claimed(), grant = encryptedBox();
  const data = {inviteId: context.inviteId, acceptanceDigest: hash(context.acceptance), grant};
  await request("grant", context.creator, data, context.now);
  return {...context, grant, grantData: data};
}
before(async () => { await db.listCollections(); });
after(async () => { await deleteApp(app); });

describe("opaque secure pairing transaction contract", () => {
  it("activates exactly two accounts only after recipient acknowledgement; exact retries are stable", async () => {
    const c = await granted();
    assert.equal((await db.doc(`conversations/${c.conversationId}`).get()).exists, false);
    const repeat = await request("publish", c.creator, c.data, c.now);
    assert.equal(repeat.state, "grantReady");
    assert.equal((await request("grant", c.creator, c.grantData, c.now)).grant, c.grant);
    const ack = {inviteId: c.inviteId, grantDigest: hash(c.grant)};
    assert.equal((await request("ack", c.recipient, ack, c.now)).state, "complete");
    assert.equal((await request("ack", c.recipient, ack, c.now)).state, "complete");
    const conversation = (await db.doc(`conversations/${c.conversationId}`).get()).data()!;
    assert.deepEqual(conversation.members, [c.creator, c.recipient]);
    assert.equal(conversation.encryption, "mines-e2ee-v1");
    for (const uid of [c.creator, c.recipient]) {
      const user = (await db.doc(`users/${uid}`).get()).data()!;
      assert.equal(user.activeConversationId, c.conversationId);
      assert.equal(user.e2eeRequired, true);
      assert.equal(user.securePairingReservation, undefined);
    }
  });
  it("concurrent distinct claims have one winner and never replace its exact bytes", async () => {
    const c = await offered(), stranger = await freshUser();
    const attempts = [c.recipient, stranger].map((uid) => ({uid, data: {inviteId: c.inviteId, claimId: identifier(), acceptance: encryptedBox(), offerDigest: hash(c.offer)}}));
    const results = await Promise.allSettled(attempts.map((a) => request("claim", a.uid, a.data, c.now)));
    assert.equal(results.filter((r) => r.status === "fulfilled").length, 1);
    const winner = attempts[results.findIndex((r) => r.status === "fulfilled")];
    assert.equal((await request("claim", winner.uid, winner.data, c.now)).acceptance, winner.data.acceptance);
    await assert.rejects(request("claim", winner.uid, {...winner.data, acceptance: encryptedBox()}, c.now));
    const invite = (await db.doc(`securePairingInvites/${c.inviteId}`).get()).data()!;
    assert.equal(invite.claimantId, winner.uid);
  });
  it("rejects unauthorized grant/ack, changed digests, self claim and plaintext-extra fields", async () => {
    const c = await granted();
    await assert.rejects(request("grant", c.recipient, c.grantData, c.now));
    await assert.rejects(request("grant", c.creator, {...c.grantData, grant: encryptedBox()}, c.now));
    await assert.rejects(request("ack", c.creator, {inviteId: c.inviteId, grantDigest: hash(c.grant)}, c.now));
    await assert.rejects(request("ack", c.recipient, {inviteId: c.inviteId, grantDigest: "0".repeat(64)}, c.now));
    await assert.rejects(request("claim", c.creator, c.claim, c.now));
    await assert.rejects(request("publish", c.creator, {...c.data, epochKey: "private-canary"}, c.now));
    await assert.rejects(request("publish", "", c.data, c.now));
    assert.equal((await db.doc(`conversations/${c.conversationId}`).get()).exists, false);
  });
  it("reservations prevent overlapping pairing and monotonic floor survives cancellation", async () => {
    const c = await claimed();
    for (const uid of [c.creator, c.recipient]) {
      await assert.rejects(request("publish", uid, {...c.data, inviteId: identifier(), conversationId: randomUUID()}, c.now));
    }
    await request("cancel", c.recipient, {inviteId: c.inviteId}, c.now);
    for (const uid of [c.creator, c.recipient]) {
      const user = (await db.doc(`users/${uid}`).get()).data()!;
      assert.equal(user.e2eeRequired, true);
      assert.equal(user.securePairingReservation, undefined);
    }
    await assert.rejects(request("claim", c.recipient, c.claim, c.now));
    await assert.rejects(request("publish", c.creator, c.data, c.now));
  });
  it("cancel versus final acknowledgement is atomic and cannot create a partial pair", async () => {
    const c = await granted();
    await Promise.allSettled([
      request("cancel", c.creator, {inviteId: c.inviteId}, c.now),
      request("ack", c.recipient, {inviteId: c.inviteId, grantDigest: hash(c.grant)}, c.now),
    ]);
    const invite = (await db.doc(`securePairingInvites/${c.inviteId}`).get()).data()!;
    const exists = (await db.doc(`conversations/${c.conversationId}`).get()).exists;
    assert.equal(exists, invite.state === "complete");
    for (const uid of [c.creator, c.recipient]) assert.equal(!!(await db.doc(`users/${uid}`).get()).data()?.activeConversationId, exists);
  });
  it("expiry and reset reject delayed claims/grants without activating", async () => {
    const c = await claimed();
    await assert.rejects(request("grant", c.creator, {inviteId: c.inviteId, acceptanceDigest: hash(c.acceptance), grant: encryptedBox()}, c.now + 20 * 60_000));
    await db.doc(`users/${c.creator}`).update({pairingResetAt: Timestamp.fromMillis(c.now)});
    await assert.rejects(request("grant", c.creator, {inviteId: c.inviteId, acceptanceDigest: hash(c.acceptance), grant: encryptedBox()}, c.now));
    assert.equal((await db.doc(`conversations/${c.conversationId}`).get()).exists, false);
  });
  it("permanent generation reservation prevents reuse after cancellation or conversation deletion", async () => {
    const c = await offered();
    await request("cancel", c.creator, {inviteId: c.inviteId}, c.now);
    await assert.rejects(request("publish", c.creator, {...c.data, inviteId: identifier()}, c.now));
    assert.equal((await db.doc(`secureConversationGenerations/${c.conversationId}`).get()).exists, true);
    const d = await granted();
    const ack = {inviteId: d.inviteId, grantDigest: hash(d.grant)};
    await request("ack", d.recipient, ack, d.now);
    await db.doc(`conversations/${d.conversationId}`).delete();
    await db.doc(`users/${d.creator}`).update({activeConversationId: null});
    await db.doc(`users/${d.recipient}`).update({activeConversationId: null});
    await assert.rejects(request("ack", d.recipient, ack, d.now));
    await assert.rejects(request("read", d.creator, {inviteId: d.inviteId}, d.now));
    await assert.rejects(request("publish", d.creator, d.data, d.now));
    await assert.rejects(request("claim", d.recipient, d.claim, d.now));
    await assert.rejects(request("grant", d.creator, d.grantData, d.now));
    await assert.rejects(request("publish", d.creator, {...d.data, inviteId: identifier()}, d.now));
  });
  it("other authenticated locator holders receive only the opaque offer, never acceptance/grant", async () => {
    const c = await granted(), other = await freshUser();
    const result = await request("read", other, {inviteId: c.inviteId}, c.now);
    assert.equal(result.offer, c.offer);
    assert.equal(result.acceptance, undefined);
    assert.equal(result.grant, undefined);
    assert.equal(result.claimantId, undefined);
    assert.equal((await request("read", c.recipient, {inviteId: c.inviteId}, c.now)).grant, c.grant);
  });
  it("bounds canonical inputs and charges rejected valid requests", async () => {
    const creator = await freshUser(), now = Date.now();
    const requestData = {inviteId: identifier(), conversationId: randomUUID(), epoch: 1, expiresAtMillis: now + 60_000, offer: "not-base64!"};
    for (let i = 0; i < 30; i++) await assert.rejects(request("publish", creator, requestData, now));
    await assert.rejects(request("publish", creator, {...requestData, offer: encryptedBox()}, now), (e: {code?: string}) => e.code === "resource-exhausted");
    await assert.rejects(request("publish", await freshUser(), {...requestData, offer: Buffer.alloc(8193).toString("base64")}, now));
    await assert.rejects(request("read", creator, {inviteId: "x/y"}, now));
  });
});
