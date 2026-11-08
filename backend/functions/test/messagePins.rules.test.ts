import {readFileSync} from "node:fs";
import {after, before, beforeEach, describe, it} from "node:test";
import assert from "node:assert/strict";
import {assertFails, assertSucceeds, initializeTestEnvironment, RulesTestEnvironment} from "@firebase/rules-unit-testing";
import {Bytes, Firestore, Timestamp, deleteDoc, doc, getDoc, getDocs, collection, orderBy, query, runTransaction, serverTimestamp, setDoc, updateDoc, writeBatch} from "firebase/firestore";

const projectId = "demo-peapod-message-pins";
const port = Number(process.env.PEAPOD_PINS_RULES_PORT ?? 8189);
const id = "aaaaaaaa-0000-4000-8000-000000000001", legacyID = id.toUpperCase();
let environment: RulesTestEnvironment;
const cipher = Bytes.fromUint8Array(new Uint8Array(128).fill(7));
const pin = (messageId = id, pinnedBy = "alice") => ({messageId, pinnedBy, pinnedAt: serverTimestamp()});
const targetPath = (conversation = "encrypted", messageId = id) => `conversations/${conversation}/messages/${messageId}`;
const pinPath = (conversation = "encrypted", messageId = id) => `conversations/${conversation}/pins/${messageId}`;
const clients = new Map<string, Firestore>();
const db = (user = "alice") => {
  let client = clients.get(user);
  if (!client) { client = environment.authenticatedContext(user).firestore(); clients.set(user, client); }
  return client;
};
const unsend = () => ({ciphertext: Bytes.fromUint8Array(new Uint8Array()), revision: 2, deletedAt: serverTimestamp()});

before(async () => {
  environment = await initializeTestEnvironment({projectId, firestore: {
    host: "127.0.0.1", port, rules: readFileSync("../firestore.rules", "utf8"),
  }});
});
after(async () => { await environment.cleanup(); });
beforeEach(async () => {
  await environment.clearFirestore();
  await environment.withSecurityRulesDisabled(async context => {
    for (const conversation of ["encrypted", "legacy", "closed"]) {
      await setDoc(doc(context.firestore(), `conversations/${conversation}`), {
        members: ["alice", "bob"], status: conversation === "closed" ? "closed" : "active",
        ...(conversation === "legacy" ? {} : {encryption: "mines-e2ee-v1", keyEpoch: 1}),
      });
      const messageId = conversation === "legacy" ? legacyID : id;
      await setDoc(doc(context.firestore(), targetPath(conversation, messageId)), {
        senderId: "alice", clientId: messageId, createdAt: Timestamp.fromMillis(1_700_000_000_000),
        ...(conversation === "legacy" ? {type: "text", text: "private content"} :
          {type: "encrypted", encryption: "mines-e2ee-v1", keyEpoch: 1, revision: 1, ciphertext: cipher}),
      });
    }
  });
});

describe("shared message pin metadata", () => {
  it("allows either member to pin either sender and either member to unpin", async () => {
    for (const user of ["alice", "bob"]) {
      await assertSucceeds(setDoc(doc(db(user), pinPath()), pin(id, user)));
      const other = db(user === "alice" ? "bob" : "alice");
      const stored = (await assertSucceeds(getDoc(doc(other, pinPath())))).data();
      assert.deepEqual(Object.keys(stored!).sort(), ["messageId", "pinnedAt", "pinnedBy"]);
      await assertSucceeds(deleteDoc(doc(other, pinPath())));
    }
  });
  it("supports uppercase legacy IDs and requires canonical encrypted IDs", async () => {
    await assertSucceeds(setDoc(doc(db("bob"), pinPath("legacy", legacyID)), pin(legacyID, "bob")));
    await environment.withSecurityRulesDisabled(async context => {
      await setDoc(doc(context.firestore(), targetPath("encrypted", legacyID)), {senderId: "alice"});
    });
    await assertFails(setDoc(doc(db(), pinPath("encrypted", legacyID)), pin(legacyID)));
  });
  it("rejects strangers, unauthenticated clients, and closed conversations", async () => {
    await assertSucceeds(setDoc(doc(db(), pinPath()), pin()));
    for (const firestore of [db("stranger"), environment.unauthenticatedContext().firestore()]) {
      await assertFails(getDoc(doc(firestore, pinPath())));
      await assertFails(getDocs(collection(firestore, "conversations/encrypted/pins")));
      await assertFails(setDoc(doc(firestore, pinPath()), pin()));
      await assertFails(deleteDoc(doc(firestore, pinPath())));
    }
    await assertFails(setDoc(doc(db(), pinPath("closed")), pin()));
    await assertFails(getDoc(doc(db(), pinPath("closed"))));
    await assertFails(deleteDoc(doc(db(), pinPath("closed"))));
  });
  it("requires exact schema, target ID, acting member and server time", async () => {
    for (const invalid of [
      {...pin(), messageId: legacyID}, {...pin(), pinnedBy: "bob"},
      {...pin(), pinnedAt: Timestamp.fromMillis(1)}, {...pin(), text: "private canary"},
      {...pin(), ciphertext: cipher}, {messageId: id, pinnedBy: "alice"},
      {messageId: id, pinnedAt: serverTimestamp()}, {pinnedBy: "alice", pinnedAt: serverTimestamp()},
    ]) await assertFails(setDoc(doc(db(), pinPath()), invalid));
  });
  it("rejects missing and unsent targets, including atomic create plus unsend", async () => {
    const missing = "aaaaaaaa-0000-4000-8000-000000000099";
    await assertFails(setDoc(doc(db(), pinPath("encrypted", missing)), pin(missing)));
    const batch = writeBatch(db());
    batch.update(doc(db(), targetPath()), unsend());
    batch.set(doc(db(), pinPath()), pin());
    await assertFails(batch.commit());
    await assertSucceeds(updateDoc(doc(db(), targetPath()), unsend()));
    await assertFails(setDoc(doc(db(), pinPath()), pin()));
  });
  it("rejects overwrite but an idempotent transaction preserves original metadata", async () => {
    await assertSucceeds(setDoc(doc(db(), pinPath()), pin()));
    const original = (await getDoc(doc(db(), pinPath()))).data();
    await assertFails(updateDoc(doc(db("bob"), pinPath()), {pinnedBy: "bob", pinnedAt: serverTimestamp()}));
    await assertSucceeds(runTransaction(db("bob"), async transaction => {
      const reference = doc(db("bob"), pinPath());
      if (!(await transaction.get(reference)).exists()) transaction.set(reference, pin(id, "bob"));
    }));
    assert.deepEqual((await getDoc(doc(db(), pinPath()))).data(), original);
  });
  it("preserves ordinary unsend without pin reads/writes, then allows stale pin removal", async () => {
    await assertSucceeds(setDoc(doc(db(), pinPath()), pin()));
    await assertSucceeds(updateDoc(doc(db(), targetPath()), unsend()));
    assert.equal((await getDoc(doc(db(), pinPath()))).exists(), true);
    await assertSucceeds(deleteDoc(doc(db("bob"), pinPath())));
    assert.equal((await getDoc(doc(db(), pinPath()))).exists(), false);
  });
  it("supports member newest-first queries with no copied content", async () => {
    await assertSucceeds(setDoc(doc(db(), pinPath()), pin()));
    const pins = await assertSucceeds(getDocs(query(collection(db("bob"), "conversations/encrypted/pins"), orderBy("pinnedAt", "desc"))));
    assert.deepEqual(pins.docs.map(value => value.id), [id]);
  });
});
