import {createHash} from "node:crypto";
import {FieldValue, Firestore, Timestamp, Transaction} from "firebase-admin/firestore";
import {HttpsError, onCall} from "firebase-functions/v2/https";

export const SECURE_PAIRING_PROTOCOL = "mines-e2ee-v1";
const TTL = 15 * 60 * 1000;
const MAX_BOX = 8192;
type Operation = "publish" | "read" | "claim" | "grant" | "ack" | "cancel";
type Input = Record<string, unknown>;
type Invite = {
  creatorId: string; conversationId: string; epoch: number; protocol: string;
  createdAtMillis: number; expiresAtMillis: number; state: string;
  offer: string; offerDigest: string; claimantId?: string; claimId?: string;
  acceptance?: string; acceptanceDigest?: string; grant?: string; grantDigest?: string;
};
const digest = (bytes: Buffer) => createHash("sha256").update(bytes).digest("hex");
function fail(message: string, code: "invalid-argument" | "failed-precondition" | "permission-denied" | "not-found" | "already-exists" | "deadline-exceeded" = "failed-precondition"): never {
  throw new HttpsError(code, message);
}
function hex(value: unknown): string {
  if (typeof value !== "string" || !/^[0-9a-f]{32}$/.test(value)) fail("Invalid pairing identifier.", "invalid-argument");
  return value;
}
function uuid(value: unknown): string {
  if (typeof value !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value)) fail("Invalid conversation identifier.", "invalid-argument");
  return value;
}
function box(value: unknown): {bytes: string; hash: string} {
  if (typeof value !== "string" || value.length > Math.ceil(MAX_BOX / 3) * 4 || value.length === 0) fail("Invalid encrypted pairing object.", "invalid-argument");
  const bytes = Buffer.from(value, "base64");
  if (bytes.length === 0 || bytes.length > MAX_BOX || bytes.toString("base64") !== value) fail("Invalid encrypted pairing object.", "invalid-argument");
  return {bytes: value, hash: digest(bytes)};
}
function hash(value: unknown): string {
  if (typeof value !== "string" || !/^[0-9a-f]{64}$/.test(value)) fail("Invalid object digest.", "invalid-argument");
  return value;
}
function exactFields(data: Input, allowed: string[]) {
  if (Object.keys(data).some((key) => !allowed.includes(key))) fail("Unexpected pairing field.", "invalid-argument");
}
function checkUnpaired(user: FirebaseFirestore.DocumentSnapshot, now: number, locator: string) {
  if (!user.exists) fail("Finish creating your profile before pairing.");
  const data = user.data()!;
  if (data.activeConversationId) fail("This account is already paired.");
  const reservation = data.securePairingReservation;
  if (reservation && reservation.inviteId !== locator && reservation.expiresAtMillis > now) fail("Finish or cancel the existing secure invite.");
}
function checkReset(user: FirebaseFirestore.DocumentSnapshot, invite: Invite) {
  const reset = user.data()?.pairingResetAt;
  if (reset instanceof Timestamp && reset.toMillis() >= invite.createdAtMillis) fail("This invite is no longer valid.");
}

/** Server stores opaque client-authenticated objects only. It cannot validate or create keys.
 * The clients MUST authenticate each object and persist their local capsule before acknowledgement.
 * No function logs request data, invite secrets, ciphertext, or private identifiers.
 */
export class SecurePairingService {
  constructor(private readonly db: Firestore) {}

  async handle(operation: Operation, uid: string, input: unknown, now = Date.now()): Promise<Input> {
    if (!uid || Buffer.byteLength(uid) > 256) throw new HttpsError("unauthenticated", "Sign in to continue.");
    if (!input || typeof input !== "object" || Array.isArray(input)) fail("Invalid pairing request.", "invalid-argument");
    const data = input as Input;
    const locator = hex(data.inviteId);
    // Bounded per-account operation windows; failed valid requests consume an attempt too.
    const window = Math.floor(now / 60_000);
    const rate = this.db.collection("securePairingRateLimits").doc(digest(Buffer.from(`${uid}\0${operation}\0${window}`)));
    const result = await this.db.runTransaction(async (tx) => {
      const rateSnapshot = await tx.get(rate);
      const count = rateSnapshot.data()?.count ?? 0;
      if (count >= (operation === "read" ? 120 : 30)) throw new HttpsError("resource-exhausted", "Please wait before trying again.");
      // Use a result instead of throwing so rejected requests still commit the rate counter.
      let value: Input | undefined;
      let rejection: HttpsError | undefined;
      try { value = await this.perform(tx, operation, uid, locator, data, now); }
      catch (error) {
        if (!(error instanceof HttpsError)) throw error;
        rejection = error;
      }
      tx.set(rate, {count: count + 1, expiresAt: Timestamp.fromMillis((window + 2) * 60_000)});
      return {value, rejection};
    });
    if (result.rejection) throw result.rejection;
    return result.value!;
  }

  private async perform(tx: Transaction, operation: Operation, uid: string, locator: string, data: Input, now: number): Promise<Input> {
    const ref = this.db.collection("securePairingInvites").doc(locator);
    const snapshot = await tx.get(ref);
    const invite = snapshot.data() as Invite | undefined;
    const caller = this.db.collection("users").doc(uid);
    if (operation === "publish") {
      exactFields(data, ["inviteId", "conversationId", "epoch", "offer", "expiresAtMillis"]);
      const conversationId = uuid(data.conversationId);
      const offer = box(data.offer);
      const expires = data.expiresAtMillis;
      if (data.epoch !== 1 || typeof expires !== "number" || !Number.isSafeInteger(expires)) fail("Invalid invite metadata.", "invalid-argument");
      if (invite) {
        if (invite.creatorId !== uid || invite.conversationId !== conversationId || invite.offer !== offer.bytes || invite.expiresAtMillis !== expires) fail("Invite identifier already used.", "already-exists");
        if (invite.state === "complete") await this.requireActiveCompletion(tx, invite);
        if (invite.state === "cancelled") fail("Invite cancelled.");
        if (invite.state !== "complete" && invite.expiresAtMillis <= now) fail("Invite expired.", "deadline-exceeded");
        return this.publicState(invite);
      }
      if (expires <= now || expires > now + TTL) fail("Invalid invite expiration.", "invalid-argument");
      const [user, conversation, generation] = await tx.getAll(caller, this.db.collection("conversations").doc(conversationId), this.db.collection("secureConversationGenerations").doc(conversationId));
      checkUnpaired(user, now, locator);
      if (conversation.exists || generation.exists) fail("Conversation identifier already used.", "already-exists");
      const created: Invite = {creatorId: uid, conversationId, epoch: 1, protocol: SECURE_PAIRING_PROTOCOL, createdAtMillis: now, expiresAtMillis: expires, state: "offered", offer: offer.bytes, offerDigest: offer.hash};
      tx.create(ref, created);
      // Permanent, content-free generation reservation survives later conversation deletion.
      tx.create(generation.ref, {inviteId: locator, createdAt: FieldValue.serverTimestamp()});
      tx.update(caller, {e2eeRequired: true, securePairingReservation: {inviteId: locator, expiresAtMillis: expires}});
      return this.publicState(created);
    }
    if (!invite) fail("Invite not found.", "not-found");
    if (invite.protocol !== SECURE_PAIRING_PROTOCOL) fail("Unsupported pairing protocol.");
    if (invite.state === "complete") await this.requireActiveCompletion(tx, invite);
    if (operation === "read") {
      exactFields(data, ["inviteId"]);
      if (invite.state === "cancelled") fail("Invite cancelled.");
      if (invite.state !== "complete" && invite.expiresAtMillis <= now) fail("Invite expired.", "deadline-exceeded");
      // A high-entropy public locator permits fetching an opaque offer. Accepted objects only go
      // to their authenticated participants; possession of a locator never permits decryption.
      if (uid !== invite.creatorId && uid !== invite.claimantId) return {state: invite.state === "offered" ? "offered" : "unavailable", creatorId: invite.creatorId, conversationId: invite.conversationId, epoch: invite.epoch, protocol: invite.protocol, expiresAtMillis: invite.expiresAtMillis, offer: invite.offer, offerDigest: invite.offerDigest};
      return this.publicState(invite);
    }
    if (operation === "cancel") {
      exactFields(data, ["inviteId"]);
      if (uid !== invite.creatorId && uid !== invite.claimantId) fail("Not an invite participant.", "permission-denied");
      if (invite.state === "complete") return this.publicState(invite);
      const ids = [invite.creatorId, invite.claimantId].filter((id): id is string => !!id);
      const users = await tx.getAll(...ids.map((id) => this.db.collection("users").doc(id)));
      tx.update(ref, {state: "cancelled"});
      for (const user of users) if (user.data()?.securePairingReservation?.inviteId === locator) tx.update(user.ref, {securePairingReservation: FieldValue.delete()});
      return {state: "cancelled"};
    }
    if (invite.state === "cancelled") fail("Invite cancelled.");
    if (invite.state !== "complete" && invite.expiresAtMillis <= now) fail("Invite expired.", "deadline-exceeded");
    if (operation === "claim") {
      exactFields(data, ["inviteId", "claimId", "acceptance", "offerDigest"]);
      const claimId = hex(data.claimId), acceptance = box(data.acceptance);
      if (hash(data.offerDigest) !== invite.offerDigest) fail("Offer changed.");
      if (uid === invite.creatorId) fail("Open the invite on the other person's device.");
      if (invite.claimantId) {
        if (invite.claimantId !== uid || invite.claimId !== claimId || invite.acceptance !== acceptance.bytes) fail("Invite already claimed.", "already-exists");
        return this.publicState(invite);
      }
      const [creator, recipient] = await tx.getAll(this.db.collection("users").doc(invite.creatorId), caller);
      checkUnpaired(creator, now, locator); checkUnpaired(recipient, now, locator);
      checkReset(creator, invite); checkReset(recipient, invite);
      const changed: Invite = {...invite, state: "claimed", claimantId: uid, claimId, acceptance: acceptance.bytes, acceptanceDigest: acceptance.hash};
      tx.update(ref, {state: changed.state, claimantId: uid, claimId, acceptance: acceptance.bytes, acceptanceDigest: acceptance.hash});
      tx.update(caller, {e2eeRequired: true, securePairingReservation: {inviteId: locator, expiresAtMillis: invite.expiresAtMillis}});
      return this.publicState(changed);
    }
    if (!invite.claimantId) fail("Waiting for the other person.");
    if (operation === "grant") {
      exactFields(data, ["inviteId", "acceptanceDigest", "grant"]);
      if (uid !== invite.creatorId) fail("Only the invite creator can grant access.", "permission-denied");
      if (hash(data.acceptanceDigest) !== invite.acceptanceDigest) fail("Claim changed.");
      const grant = box(data.grant);
      if (invite.grant) {
        if (invite.grant !== grant.bytes) fail("Grant already fixed.", "already-exists");
        return this.publicState(invite);
      }
      const users = await tx.getAll(caller, this.db.collection("users").doc(invite.claimantId));
      for (const user of users) { checkUnpaired(user, now, locator); checkReset(user, invite); }
      tx.update(ref, {state: "grantReady", grant: grant.bytes, grantDigest: grant.hash});
      return this.publicState({...invite, state: "grantReady", grant: grant.bytes, grantDigest: grant.hash});
    }
    exactFields(data, ["inviteId", "grantDigest"]);
    if (uid !== invite.claimantId) fail("Only the recipient can acknowledge this grant.", "permission-denied");
    if (!invite.grant || hash(data.grantDigest) !== invite.grantDigest) fail("Grant changed or unavailable.");
    const conversationRef = this.db.collection("conversations").doc(invite.conversationId);
    const [creator, recipient, conversation] = await tx.getAll(this.db.collection("users").doc(invite.creatorId), caller, conversationRef);
    if (invite.state === "complete") {
      if (!conversation.exists || conversation.data()?.status !== "active" || creator.data()?.activeConversationId !== invite.conversationId || recipient.data()?.activeConversationId !== invite.conversationId) fail("Conversation is no longer active.");
      return this.publicState(invite);
    }
    for (const user of [creator, recipient]) { checkUnpaired(user, now, locator); checkReset(user, invite); }
    if (conversation.exists) fail("Conversation identifier already used.", "already-exists");
    tx.create(conversationRef, {members: [invite.creatorId, invite.claimantId], status: "active", createdBy: invite.creatorId, createdAt: FieldValue.serverTimestamp(), updatedAt: FieldValue.serverTimestamp(), encryption: SECURE_PAIRING_PROTOCOL, keyEpoch: invite.epoch, pairingInviteId: locator, pairingGrantDigest: invite.grantDigest, lastMessageAt: null, lastMessagePreview: null});
    for (const user of [creator, recipient]) tx.update(user.ref, {activeConversationId: invite.conversationId, e2eeRequired: true, securePairingReservation: FieldValue.delete(), updatedAt: FieldValue.serverTimestamp()});
    tx.update(ref, {state: "complete", completedAt: FieldValue.serverTimestamp()});
    return this.publicState({...invite, state: "complete"});
  }

  private async requireActiveCompletion(tx: Transaction, invite: Invite) {
    if (!invite.claimantId) fail("Malformed completed invite.");
    const [conversation, creator, recipient] = await tx.getAll(
      this.db.collection("conversations").doc(invite.conversationId),
      this.db.collection("users").doc(invite.creatorId),
      this.db.collection("users").doc(invite.claimantId));
    if (conversation.data()?.status !== "active" || conversation.data()?.encryption !== SECURE_PAIRING_PROTOCOL ||
        creator.data()?.activeConversationId !== invite.conversationId || recipient.data()?.activeConversationId !== invite.conversationId) fail("Conversation is no longer active.");
  }

  private publicState(invite: Invite): Input {
    // Explicit projection: no newly-added internal fields can leak through this API.
    const fields = ["creatorId", "conversationId", "epoch", "protocol", "expiresAtMillis", "state", "offer", "offerDigest", "claimantId", "claimId", "acceptance", "acceptanceDigest", "grant", "grantDigest"] as const;
    return Object.fromEntries(fields.filter((field) => invite[field] !== undefined).map((field) => [field, invite[field]]));
  }
}

export function securePairingCallable(service: SecurePairingService, operation: Operation) {
  return onCall({region: "us-west1", enforceAppCheck: false}, async (request) => {
    if (!request.auth?.uid) throw new HttpsError("unauthenticated", "Sign in to continue.");
    return service.handle(operation, request.auth.uid, request.data);
  });
}
