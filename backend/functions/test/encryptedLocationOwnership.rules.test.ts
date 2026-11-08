import {readFileSync} from "node:fs";
import {after, before, beforeEach, describe, it} from "node:test";
import assert from "node:assert/strict";
import {assertFails, assertSucceeds, initializeTestEnvironment, RulesTestEnvironment} from "@firebase/rules-unit-testing";
import {Bytes, Firestore, doc, getDoc, runTransaction, serverTimestamp, setDoc, writeBatch} from "firebase/firestore";

// Dedicated suite: never clears or reconfigures the normal device-test project/emulators.
const projectId = "demo-peapod-location-ownership";
const port = Number(process.env.PEAPOD_LOCATION_RULES_PORT ?? 8187);
const base = "conversations/ownership-test";
const phoneA = "synthetic-phone-0001", phoneB = "synthetic-phone-0002";
let environment: RulesTestEnvironment;
const cipher = Bytes.fromUint8Array(new Uint8Array(128).fill(7));
const operation = (generation: number) => `00000000-0000-4000-8000-${String(generation).padStart(12, "0")}`;
const intent = (sourceDeviceId: string, sourceGeneration: number, isSharing = true) => ({
  userId: "alice", isSharing, sourceDeviceId, sourceGeneration,
  sourceMutationId: operation(sourceGeneration), updatedAt: serverTimestamp(),
});
const point = (sourceDeviceId: string, sourceGeneration: number, revision = 1) => ({
  userId: "alice", encryption: "mines-e2ee-v1", keyEpoch: 1, sourceDeviceId, sourceGeneration,
  revision, ciphertext: cipher, updatedAt: serverTimestamp(),
});
before(async () => {
  environment = await initializeTestEnvironment({projectId, firestore: {
    host: "127.0.0.1", port, rules: readFileSync("../firestore.rules", "utf8"),
  }});
});
after(async () => { await environment.cleanup(); });
beforeEach(async () => {
  await environment.clearFirestore();
  await environment.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), base), {members: ["alice", "bob"], status: "active", encryption: "mines-e2ee-v1", keyEpoch: 1});
  });
});
function references(db: Firestore) {
  return {consent: doc(db, `${base}/locationSharing/alice`), latest: doc(db, `${base}/locations/alice`)};
}
// Rules authorize the account; the native relay pins the original source/generation and
// implements explicit transfer. They do not infer a phone identity from an auth UID.
describe("encrypted primary phone source", () => {
  it("requires bounded source fields and the exact current source even at a higher revision", async () => {
    const db = environment.authenticatedContext("alice").firestore(), {consent, latest} = references(db);
    for (const invalid of [
      {...intent(phoneA, 1), sourceDeviceId: "short"}, {...intent(phoneA, 1), sourceDeviceId: "x".repeat(129)},
      {...intent(phoneA, 1), sourceGeneration: 0}, {...intent(phoneA, 1), sourceGeneration: 2},
      {...intent(phoneA, 1), sourceGeneration: 1.5}, {...intent(phoneA, 1), sourceMutationId: "bad"},
    ]) await assertFails(setDoc(consent, invalid));
    await assertSucceeds(setDoc(consent, intent(phoneA, 1)));
    await assertFails(setDoc(latest, point(phoneB, 1, 1000)));
    await assertFails(setDoc(latest, point(phoneA, 2, 1000)));
    await assertSucceeds(setDoc(latest, point(phoneA, 1)));
    await assertFails(setDoc(latest, {...point(phoneA, 1, 2), sourceGeneration: Number.MAX_SAFE_INTEGER + 1}));
    const missingSource = point(phoneA, 1, 2) as Record<string, unknown>; delete missingSource.sourceDeviceId;
    await assertFails(setDoc(latest, missingSource));
  });
  it("transfers atomically, rejects old offline writes and cannot batch a point with a new claim", async () => {
    const db = environment.authenticatedContext("alice").firestore(), {consent, latest} = references(db);
    await setDoc(consent, intent(phoneA, 1)); await setDoc(latest, point(phoneA, 1));
    await assertFails(setDoc(consent, intent(phoneB, 2)));
    const transfer = writeBatch(db); transfer.set(consent, intent(phoneB, 2)); transfer.delete(latest);
    await assertSucceeds(transfer.commit());
    await assertFails(setDoc(latest, point(phoneA, 1, 1000000)));
    await assertSucceeds(setDoc(latest, point(phoneB, 2, 2)));
    const staleStop = writeBatch(db); staleStop.set(consent, intent(phoneA, 2)); staleStop.delete(latest);
    await assertFails(staleStop.commit());
    assert.equal((await getDoc(latest)).data()?.sourceDeviceId, phoneB);
    const claimAndPoint = writeBatch(db); claimAndPoint.set(consent, intent(phoneA, 3)); claimAndPoint.set(latest, point(phoneA, 3, 3));
    await assertFails(claimAndPoint.commit());
  });
  it("off from either account device fences old work across reenable and forbids naked delete", async () => {
    const a = environment.authenticatedContext("alice").firestore(), b = environment.authenticatedContext("alice").firestore();
    const first = references(a), second = references(b);
    await setDoc(first.consent, intent(phoneA, 1)); await setDoc(first.latest, point(phoneA, 1));
    const nakedDelete = writeBatch(b); nakedDelete.delete(second.latest); await assertFails(nakedDelete.commit());
    const off = writeBatch(b); off.set(second.consent, intent(phoneA, 2, false)); off.delete(second.latest);
    await assertSucceeds(off.commit());
    await assertFails(setDoc(first.latest, point(phoneA, 1, 10000)));
    await assertSucceeds(setDoc(first.consent, intent(phoneA, 3)));
    await assertFails(setDoc(first.latest, point(phoneA, 1, 10000)));
    await assertFails(setDoc(first.latest, point(phoneA, 2, 10000)));
    await assertSucceeds(setDoc(first.latest, point(phoneA, 3, 10001)));
    // Replaying the already consumed off generation cannot delete the replacement point.
    const lateOff = writeBatch(b); lateOff.set(second.consent, intent(phoneA, 2, false)); lateOff.delete(second.latest);
    await assertFails(lateOff.commit());
    assert.equal((await getDoc(first.latest)).data()?.sourceGeneration, 3);
  });
  it("a source stop bumps generation even if no point exists", async () => {
    const db = environment.authenticatedContext("alice").firestore(), {consent, latest} = references(db);
    const firstEnable = writeBatch(db); firstEnable.set(consent, intent(phoneA, 1)); firstEnable.delete(latest);
    await assertSucceeds(firstEnable.commit());
    const stop = writeBatch(db); stop.set(consent, intent(phoneA, 2)); stop.delete(latest);
    await assertSucceeds(stop.commit());
    await assertFails(setDoc(latest, point(phoneA, 1, 10000)));
    await assertSucceeds(setDoc(latest, point(phoneA, 2, 10001)));
  });
  it("two same-UID claims using pinned absent state have exactly one winner", async () => {
    const a = environment.authenticatedContext("alice").firestore(), b = environment.authenticatedContext("alice").firestore();
    // Both callers captured absent before-state. Retry must never reinterpret the winner as a new claim.
    const claim = async (db: typeof a, source: string) => runTransaction(db, async (transaction) => {
      const reference = references(db).consent, current = await transaction.get(reference);
      if (current.exists()) throw new Error("source changed");
      transaction.set(reference, intent(source, 1));
    });
    const outcomes = await Promise.allSettled([claim(a, phoneA), claim(b, phoneB)]);
    assert.equal(outcomes.filter((result) => result.status === "fulfilled").length, 1);
    assert.equal((await getDoc(references(a).consent)).data()?.sourceGeneration, 1);
  });
  it("an off tombstone fences an initially absent delayed enable without selecting a phone", async () => {
    const db = environment.authenticatedContext("alice").firestore(), {consent, latest} = references(db);
    const off = writeBatch(db); off.set(consent, intent("unclaimed-location-source", 1, false)); off.delete(latest);
    await assertSucceeds(off.commit());
    await assertFails(setDoc(consent, intent(phoneA, 1)));
    await assertFails(setDoc(consent, intent("unclaimed-location-source", 2)));
    await assertSucceeds(setDoc(consent, intent(phoneA, 2)));
    await assertSucceeds(setDoc(latest, point(phoneA, 2)));
  });
  it("rejects another account and incompatible old client consent/points", async () => {
    const alice = environment.authenticatedContext("alice").firestore(), bob = environment.authenticatedContext("bob").firestore();
    await assertFails(setDoc(references(bob).consent, intent(phoneA, 1)));
    await assertFails(setDoc(references(alice).consent, {userId: "alice", isSharing: true, updatedAt: serverTimestamp()}));
    await setDoc(references(alice).consent, intent(phoneA, 1));
    await assertFails(setDoc(references(alice).latest, {userId: "alice", latitude: 1, longitude: 2, horizontalAccuracy: 3, updatedAt: serverTimestamp()}));
    await assertSucceeds(getDoc(references(bob).consent));
  });
});
