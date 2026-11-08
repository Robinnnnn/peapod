import {randomBytes} from "node:crypto";
import {SecurePairingService, securePairingCallable} from "./securePairing.js";

import {initializeApp} from "firebase-admin/app";
import {
  DocumentReference,
  FieldPath,
  FieldValue,
  Timestamp,
  Transaction,
  getFirestore,
} from "firebase-admin/firestore";
import {getMessaging} from "firebase-admin/messaging";
import {getStorage} from "firebase-admin/storage";
import {HttpsError, onCall} from "firebase-functions/v2/https";
import {
  onDocumentCreated,
  onDocumentUpdated,
  onDocumentWritten,
} from "firebase-functions/v2/firestore";
import {onSchedule} from "firebase-functions/v2/scheduler";
import {logger} from "firebase-functions";

import {
  MAX_NOTIFICATION_DELIVERY_ATTEMPTS,
  NOTIFICATION_LEASE_MILLISECONDS,
  canRetryDelivery,
  classifyMessagingResult,
  hashDeliveryToken,
  messagingErrorCode,
  notificationCollapseId,
  selectPendingTokens,
  shouldSendMessageAlert,
  messageNotificationPreview,
  messageNotificationPayload,
  messageAlertCurrentState,
} from "./notificationDeliveryPolicy.js";
import {
  BadgeSyncConversationAssignment,
  badgeSyncAssignmentsMatch,
  badgeSyncMulticast,
  deriveBadgeSyncConversationAssignment,
  shouldSynchronizeBadge,
} from "./unreadBadgePolicy.js";
import {
  BadgeSyncCompletionResult,
  BadgeSyncLease,
  BadgeSyncPreflightResult,
  BadgeSyncState,
  claimBadgeSyncState,
  completeBadgeSyncState,
  drainBadgeSync,
  observeBadgeSyncState,
  preflightBadgeSyncState,
  releaseBadgeSyncState,
} from "./badgeSyncCoordinator.js";
import {
  ORPHAN_ATTACHMENT_MIN_AGE_MILLISECONDS,
  OrphanAttachmentCleanupResult,
  cleanupOrphanAttachment,
  messageDocumentIsLive,
} from "./orphanAttachmentCleanup.js";
import {
  PairingRateLimitOperation,
  PairingRateLimitWindow,
  pairingRateLimitWindow,
} from "./pairingRateLimit.js";
initializeApp();

const db = getFirestore();
const storage = getStorage();
const securePairing = new SecurePairingService(db);
export const publishSecureInvite = securePairingCallable(securePairing, "publish");
export const readSecureInvite = securePairingCallable(securePairing, "read");
export const claimSecureInvite = securePairingCallable(securePairing, "claim");
export const finalizeSecureInvite = securePairingCallable(securePairing, "grant");
export const ackSecureGrant = securePairingCallable(securePairing, "ack");
export const cancelSecureInvite = securePairingCallable(securePairing, "cancel");
const PAIRING_CODE_TTL_MS = 15 * 60 * 1000;
const PAIRING_ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ";
const BADGE_SYNC_LEASE_MILLISECONDS = 90 * 1000;
const BADGE_SYNC_MAXIMUM_PASSES = 8;

type MessageDocument = {
  senderId: string;
  type: string;
  text?: string;
  deletedAt?: Timestamp | null;
  delivery?: unknown;
  attachmentGroupId?: unknown;
  attachmentGroupIndex?: unknown;
  attachmentGroupCount?: unknown;
  encryption?: unknown;
  keyEpoch?: unknown;
  revision?: unknown;
  ciphertext?: unknown;
};

type DeviceTarget = {
  token: string;
  tokenHash: string;
  refs: DocumentReference[];
};

type DeliveryClaim =
  | {kind: "busy"}
  | {kind: "complete"}
  | {kind: "exhausted"}
  | {
      kind: "claimed";
      attemptCount: number;
      targets: DeviceTarget[];
    };

type BadgeSyncPayload = {
  conversationId?: string;
  incomingSenderId?: string;
  unreadCount: number;
  terminal: boolean;
};

function stringArray(value: unknown): string[] {
  if (!Array.isArray(value)) {
    return [];
  }
  return value.filter((item): item is string => typeof item === "string");
}

async function loadIOSDeviceTargets(
  recipientId: string,
): Promise<DeviceTarget[]> {
  const deviceSnapshot = await db
    .collection("users")
    .doc(recipientId)
    .collection("devices")
    .get();
  const devicesByToken = new Map<string, DeviceTarget>();
  deviceSnapshot.docs.forEach((document) => {
    const data = document.data();
    const token = data.token;
    if (
      data.platform === "macos" ||
      typeof token !== "string" ||
      token.length === 0
    ) {
      return;
    }
    const existing = devicesByToken.get(token);
    if (existing) {
      existing.refs.push(document.ref);
    } else {
      devicesByToken.set(token, {
        token,
        tokenHash: hashDeliveryToken(token),
        refs: [document.ref],
      });
    }
  });
  return [...devicesByToken.values()];
}

async function unreadIncomingMessageCount(
  conversationRef: DocumentReference,
  recipientId: string,
  incomingSenderId: string,
): Promise<number> {
  const messages = conversationRef.collection("messages");
  const incomingMessages = messages
    .where("senderId", "==", incomingSenderId)
    // Match the checked-in senderId ASC / createdAt DESC composite index.
    // In descending position order, documents before the canonical read
    // cursor are newer, including a same-timestamp document with a greater ID.
    .orderBy("createdAt", "desc")
    .orderBy(FieldPath.documentId(), "desc");
  const readState = await conversationRef
    .collection("readStates")
    .doc(recipientId)
    .get();
  const lastReadMessageId = readState.data()?.lastReadMessageId;

  if (
    typeof lastReadMessageId !== "string" ||
    lastReadMessageId.length === 0
  ) {
    return (await incomingMessages.count().get()).data().count;
  }

  const lastReadMessage = await messages.doc(lastReadMessageId).get();
  const lastReadAt = lastReadMessage.data()?.createdAt;
  if (!(lastReadAt instanceof Timestamp)) {
    throw new Error(
      `Canonical read position ${lastReadMessageId} is unavailable.`,
    );
  }

  return (
    await incomingMessages
      .endBefore(lastReadAt, lastReadMessageId)
      .count()
      .get()
  ).data().count;
}

async function claimNotificationDelivery(
  deliveryRef: DocumentReference,
  targets: DeviceTarget[],
  attemptId: string,
  eventId: string,
): Promise<DeliveryClaim> {
  return db.runTransaction(async (transaction) => {
    const stateSnapshot = await transaction.get(deliveryRef);
    const state = stateSnapshot.data() ?? {};
    if (state.completedAt) {
      return {kind: "complete"};
    }

    const now = Timestamp.now();
    const leaseExpiresAt = state.leaseExpiresAt;
    if (
      leaseExpiresAt instanceof Timestamp &&
      leaseExpiresAt.toMillis() > now.toMillis() &&
      state.leaseOwner !== attemptId
    ) {
      return {kind: "busy"};
    }

    const previousAttempts =
      typeof state.attemptCount === "number" ? state.attemptCount : 0;
    if (previousAttempts >= MAX_NOTIFICATION_DELIVERY_ATTEMPTS) {
      transaction.set(deliveryRef, {
        status: "abandoned",
        completedAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
        leaseOwner: FieldValue.delete(),
        leaseExpiresAt: FieldValue.delete(),
      }, {merge: true});
      return {kind: "exhausted"};
    }

    const pendingTokens = selectPendingTokens(
      targets.map((target) => target.token),
      stringArray(state.deliveredTokenHashes),
      stringArray(state.terminalTokenHashes),
    );
    const targetsByToken = new Map(
      targets.map((target) => [target.token, target]),
    );
    const pendingTargets = pendingTokens.flatMap((token) => {
      const target = targetsByToken.get(token);
      return target ? [target] : [];
    });

    if (pendingTargets.length === 0) {
      transaction.set(deliveryRef, {
        status: "complete",
        completedAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
        leaseOwner: FieldValue.delete(),
        leaseExpiresAt: FieldValue.delete(),
      }, {merge: true});
      return {kind: "complete"};
    }

    const attemptCount = previousAttempts + 1;
    transaction.set(deliveryRef, {
      status: "sending",
      attemptCount,
      eventId,
      leaseOwner: attemptId,
      leaseExpiresAt: Timestamp.fromMillis(
        now.toMillis() + NOTIFICATION_LEASE_MILLISECONDS,
      ),
      updatedAt: FieldValue.serverTimestamp(),
    }, {merge: true});

    return {
      kind: "claimed",
      attemptCount,
      targets: pendingTargets,
    };
  });
}

async function recordDeliveryHashes(
  deliveryRef: DocumentReference,
  deliveredTokenHashes: string[],
  terminalTokenHashes: string[],
): Promise<void> {
  if (deliveredTokenHashes.length === 0 && terminalTokenHashes.length === 0) {
    return;
  }

  const update: Record<string, unknown> = {
    updatedAt: FieldValue.serverTimestamp(),
  };
  if (deliveredTokenHashes.length > 0) {
    update.deliveredTokenHashes = FieldValue.arrayUnion(
      ...deliveredTokenHashes,
    );
  }
  if (terminalTokenHashes.length > 0) {
    update.terminalTokenHashes = FieldValue.arrayUnion(
      ...terminalTokenHashes,
    );
  }
  await deliveryRef.set(update, {merge: true});
}

async function deleteDeviceRefs(refs: DocumentReference[]): Promise<void> {
  const uniqueRefs = [...new Map(refs.map((ref) => [ref.path, ref])).values()];
  for (let start = 0; start < uniqueRefs.length; start += 450) {
    const cleanup = db.batch();
    uniqueRefs.slice(start, start + 450).forEach((ref) => cleanup.delete(ref));
    await cleanup.commit();
  }
}

function badgeSyncStateReference(
  recipientId: string,
): DocumentReference {
  return db
    .collection("users")
    .doc(recipientId)
    .collection("badgeSyncStates")
    .doc("current");
}

function storedNonnegativeInteger(
  value: unknown,
  fieldName: string,
): number {
  if (value === undefined) {
    return 0;
  }
  if (!Number.isSafeInteger(value) || (value as number) < 0) {
    throw new TypeError(`Invalid unread badge ${fieldName}.`);
  }
  return value as number;
}

function storedBadgeSyncState(
  value: Record<string, unknown> | undefined,
): BadgeSyncState {
  if (!value) {
    return {
      desiredGeneration: 0,
      processedGeneration: 0,
      leaseFence: 0,
    };
  }
  const desiredGeneration = storedNonnegativeInteger(
    value.desiredGeneration,
    "desired generation",
  );
  const processedGeneration = storedNonnegativeInteger(
    value.processedGeneration,
    "processed generation",
  );
  const leaseFence = storedNonnegativeInteger(
    value.leaseFence,
    "lease fence",
  );
  if (processedGeneration > desiredGeneration) {
    throw new TypeError(
      "Unread badge processed generation exceeds desired generation.",
    );
  }
  if (value.leaseOwner === undefined && value.leaseExpiresAt === undefined) {
    return {desiredGeneration, processedGeneration, leaseFence};
  }
  if (
    typeof value.leaseOwner !== "string" ||
    value.leaseOwner.length === 0 ||
    !(value.leaseExpiresAt instanceof Timestamp)
  ) {
    throw new TypeError("Unread badge lease state is incomplete.");
  }
  return {
    desiredGeneration,
    processedGeneration,
    leaseFence,
    leaseOwner: value.leaseOwner,
    leaseExpiresAtMilliseconds: value.leaseExpiresAt.toMillis(),
  };
}

async function requestUnreadBadgeSync(
  recipientId: string,
): Promise<void> {
  const stateRef = badgeSyncStateReference(recipientId);
  await db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(stateRef);
    const state = observeBadgeSyncState(
      storedBadgeSyncState(snapshot.data()),
    );
    transaction.set(stateRef, {
      desiredGeneration: state.desiredGeneration,
      processedGeneration: state.processedGeneration,
      leaseFence: state.leaseFence,
      requestedAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    }, {merge: true});
  });
}

async function claimBadgeSyncLease(
  stateRef: DocumentReference,
  ownerId: string,
) {
  return db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(stateRef);
    const claim = claimBadgeSyncState(
      storedBadgeSyncState(snapshot.data()),
      ownerId,
      Timestamp.now().toMillis(),
      BADGE_SYNC_LEASE_MILLISECONDS,
    );
    if (claim.kind === "claimed") {
      transaction.set(stateRef, {
        leaseOwner: claim.state.leaseOwner,
        leaseFence: claim.state.leaseFence,
        leaseExpiresAt: Timestamp.fromMillis(
          claim.state.leaseExpiresAtMilliseconds as number,
        ),
        updatedAt: FieldValue.serverTimestamp(),
      }, {merge: true});
    }
    return claim;
  });
}

function storedActiveConversationId(
  userData: Record<string, unknown> | undefined,
): string | undefined {
  const value = userData?.activeConversationId;
  if (value === undefined) {
    return undefined;
  }
  if (typeof value !== "string" || value.length === 0) {
    throw new TypeError("The active conversation assignment is malformed.");
  }
  return value;
}

function badgeSyncPayloadAssignment(
  payload: BadgeSyncPayload,
): BadgeSyncConversationAssignment {
  return {
    ...(payload.conversationId ?
      {conversationId: payload.conversationId} :
      {}),
    ...(payload.incomingSenderId ?
      {incomingSenderId: payload.incomingSenderId} :
      {}),
    terminal: payload.terminal,
  };
}

async function transactionBadgeSyncAssignment(
  transaction: Transaction,
  recipientId: string,
): Promise<BadgeSyncConversationAssignment> {
  const userSnapshot = await transaction.get(
    db.collection("users").doc(recipientId),
  );
  const activeConversationId = storedActiveConversationId(
    userSnapshot.data(),
  );
  if (!activeConversationId) {
    return deriveBadgeSyncConversationAssignment(
      recipientId,
      undefined,
      undefined,
    );
  }
  const conversationSnapshot = await transaction.get(
    db.collection("conversations").doc(activeConversationId),
  );
  return deriveBadgeSyncConversationAssignment(
    recipientId,
    activeConversationId,
    {
      exists: conversationSnapshot.exists,
      status: conversationSnapshot.data()?.status,
      members: conversationSnapshot.data()?.members,
    },
  );
}

async function preflightBadgeSyncLease(
  stateRef: DocumentReference,
  recipientId: string,
  lease: BadgeSyncLease,
  payload: BadgeSyncPayload,
): Promise<BadgeSyncPreflightResult> {
  return db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(stateRef);
    let state = storedBadgeSyncState(snapshot.data());
    const assignment = await transactionBadgeSyncAssignment(
      transaction,
      recipientId,
    );
    const assignmentChanged = !badgeSyncAssignmentsMatch(
      assignment,
      badgeSyncPayloadAssignment(payload),
    );
    if (assignmentChanged) {
      state = observeBadgeSyncState(state);
    }
    const result = preflightBadgeSyncState(
      state,
      lease,
      Timestamp.now().toMillis(),
      BADGE_SYNC_LEASE_MILLISECONDS,
    );
    if (result.kind !== "lost") {
      transaction.set(stateRef, {
        ...(assignmentChanged ?
          {desiredGeneration: state.desiredGeneration} :
          {}),
        leaseExpiresAt: Timestamp.fromMillis(
          result.state.leaseExpiresAtMilliseconds as number,
        ),
        updatedAt: FieldValue.serverTimestamp(),
      }, {merge: true});
    }
    return result;
  });
}

async function completeBadgeSyncLease(
  stateRef: DocumentReference,
  recipientId: string,
  lease: BadgeSyncLease,
  payload: BadgeSyncPayload,
): Promise<BadgeSyncCompletionResult> {
  return db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(stateRef);
    let state = storedBadgeSyncState(snapshot.data());
    const assignment = await transactionBadgeSyncAssignment(
      transaction,
      recipientId,
    );
    const assignmentChanged = !badgeSyncAssignmentsMatch(
      assignment,
      badgeSyncPayloadAssignment(payload),
    );
    if (assignmentChanged) {
      state = observeBadgeSyncState(state);
    }
    const result = completeBadgeSyncState(
      state,
      lease,
      Timestamp.now().toMillis(),
      BADGE_SYNC_LEASE_MILLISECONDS,
    );
    if (result.kind === "next") {
      transaction.set(stateRef, {
        ...(assignmentChanged ?
          {desiredGeneration: state.desiredGeneration} :
          {}),
        leaseExpiresAt: Timestamp.fromMillis(
          result.state.leaseExpiresAtMilliseconds as number,
        ),
        updatedAt: FieldValue.serverTimestamp(),
      }, {merge: true});
    } else if (result.kind === "done") {
      transaction.set(stateRef, {
        processedGeneration: result.state.processedGeneration,
        lastPublishedBadgeCount: payload.unreadCount,
        lastPublishedConversationId: payload.conversationId ??
          FieldValue.delete(),
        lastPublishedIncomingSenderId: payload.incomingSenderId ??
          FieldValue.delete(),
        lastPublishedTerminal: payload.terminal,
        publishedAt: FieldValue.serverTimestamp(),
        leaseOwner: FieldValue.delete(),
        leaseExpiresAt: FieldValue.delete(),
        updatedAt: FieldValue.serverTimestamp(),
      }, {merge: true});
    }
    return result;
  });
}

async function releaseBadgeSyncLease(
  stateRef: DocumentReference,
  lease: BadgeSyncLease,
): Promise<void> {
  await db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(stateRef);
    const state = storedBadgeSyncState(snapshot.data());
    if (releaseBadgeSyncState(state, lease) === state) {
      return;
    }
    transaction.set(stateRef, {
      leaseOwner: FieldValue.delete(),
      leaseExpiresAt: FieldValue.delete(),
      updatedAt: FieldValue.serverTimestamp(),
    }, {merge: true});
  });
}

async function sendBadgeCountBatch(
  conversationId: string | undefined,
  recipientId: string,
  unreadCount: number,
  batch: DeviceTarget[],
): Promise<void> {
  let transientFailureCount = 0;
  let response;
  try {
    response = await getMessaging().sendEachForMulticast(
      badgeSyncMulticast({
        tokens: batch.map((target) => target.token),
        conversationId,
        recipientId,
        unreadCount,
      }),
    );
  } catch (error) {
    const code = messagingErrorCode(error);
    if (classifyMessagingResult(false, code) === "transient") {
      logger.warn("Transient badge-sync multicast request failure", {
        conversationId,
        recipientId,
        code,
        tokenCount: batch.length,
      });
      throw error;
    }
    logger.error("Permanent badge-sync multicast request failure", {
      conversationId,
      recipientId,
      code,
      tokenCount: batch.length,
    });
    return;
  }

  const invalidTargets: DeviceTarget[] = [];
  response.responses.forEach((result, index) => {
    const target = batch[index];
    const code = result.error?.code;
    switch (classifyMessagingResult(result.success, code)) {
      case "delivered":
        break;
      case "invalid-token":
        invalidTargets.push(target);
        break;
      case "transient":
        transientFailureCount += 1;
        break;
      case "permanent":
        logger.error("Permanent badge-sync notification token failure", {
          conversationId,
          recipientId,
          code,
          tokenHash: target.tokenHash,
        });
        break;
    }
  });

  if (invalidTargets.length > 0) {
    await deleteDeviceRefs(invalidTargets.flatMap((target) => target.refs));
    logger.info("Pruned invalid badge-sync notification tokens", {
      conversationId,
      recipientId,
      count: invalidTargets.length,
    });
  }
  if (transientFailureCount > 0) {
    throw new Error(
      `Transient badge-sync failure for ${conversationId}/${recipientId}.`,
    );
  }
}

function deviceTargetBatches(targets: DeviceTarget[]): DeviceTarget[][] {
  const batches: DeviceTarget[][] = [];
  for (let start = 0; start < targets.length; start += 500) {
    batches.push(targets.slice(start, start + 500));
  }
  return batches;
}

async function badgeSyncWork(
  recipientId: string,
): Promise<{payload: BadgeSyncPayload; batches: DeviceTarget[][]}> {
  const userSnapshot = await db.collection("users").doc(recipientId).get();
  const activeConversationId = storedActiveConversationId(
    userSnapshot.data(),
  );
  const conversationRef = activeConversationId ?
    db.collection("conversations").doc(activeConversationId) :
    undefined;
  const conversation = conversationRef ?
    await conversationRef.get() :
    undefined;
  const assignment = deriveBadgeSyncConversationAssignment(
    recipientId,
    activeConversationId,
    conversation ? {
      exists: conversation.exists,
      status: conversation.data()?.status,
      members: conversation.data()?.members,
    } : undefined,
  );
  const unreadCount =
    !assignment.terminal &&
    conversationRef &&
    assignment.incomingSenderId ?
    await unreadIncomingMessageCount(
      conversationRef,
      recipientId,
      assignment.incomingSenderId,
    ) :
    0;
  if (assignment.terminal) {
    logger.info("Publishing terminal zero unread badge count", {
      conversationId: assignment.conversationId,
      recipientId,
      conversationExists: conversation?.exists ?? false,
      conversationStatus: conversation?.data()?.status,
    });
  }
  const targets = await loadIOSDeviceTargets(recipientId);
  return {
    payload: {...assignment, unreadCount},
    batches: deviceTargetBatches(targets),
  };
}

async function processBadgeSyncState(
  recipientId: string,
  eventId: string,
  publishBatch: typeof sendBadgeCountBatch = sendBadgeCountBatch,
): Promise<void> {
  const stateRef = badgeSyncStateReference(recipientId);
  const ownerId = `${eventId}:${randomBytes(16).toString("hex")}`;
  await drainBadgeSync({
    claim: () => claimBadgeSyncLease(stateRef, ownerId),
    compute: () => badgeSyncWork(recipientId),
    preflight: (lease, payload) => preflightBadgeSyncLease(
      stateRef,
      recipientId,
      lease,
      payload,
    ),
    publishBatch: (payload, batch) => publishBatch(
      payload.conversationId,
      recipientId,
      payload.unreadCount,
      batch,
    ),
    complete: (lease, payload) => completeBadgeSyncLease(
      stateRef,
      recipientId,
      lease,
      payload,
    ),
    release: async (lease) => {
      try {
        await releaseBadgeSyncLease(stateRef, lease);
      } catch (error) {
        logger.error("Failed to release unread badge synchronization lease", {
          recipientId,
          code: messagingErrorCode(error),
        });
      }
    },
  }, BADGE_SYNC_MAXIMUM_PASSES);
}

// This exported seam lets emulator tests exercise the production Firestore
// state, assignment, count, batching, and drain path without contacting FCM.
// It has no Cloud Functions trigger metadata and is ignored during deployment.
export const badgeSyncLifecycleTestSeam = {
  request: requestUnreadBadgeSync,
  process: processBadgeSyncState,
};

function requireUid(auth: {uid: string} | undefined): string {
  if (!auth?.uid) {
    throw new HttpsError("unauthenticated", "Sign in before pairing.");
  }
  return auth.uid;
}

function normalizeCode(value: unknown): string {
  if (typeof value !== "string") {
    throw new HttpsError("invalid-argument", "A pairing code is required.");
  }

  const code = value.toUpperCase().replace(/[^A-Z0-9]/g, "");
  if (code.length !== 8) {
    throw new HttpsError("invalid-argument", "The pairing code is invalid.");
  }
  return code;
}

function makeCode(): string {
  const bytes = randomBytes(8);
  return Array.from(bytes, (byte) =>
    PAIRING_ALPHABET[byte % PAIRING_ALPHABET.length],
  ).join("");
}

function timestampMilliseconds(value: unknown): number | undefined {
  if (
    typeof value !== "object" ||
    value === null ||
    !("toMillis" in value) ||
    typeof value.toMillis !== "function"
  ) {
    return undefined;
  }
  const milliseconds = value.toMillis();
  return Number.isFinite(milliseconds) ? milliseconds : undefined;
}

function timestampIsAtOrBefore(
  value: unknown,
  limit: unknown,
): boolean {
  if (!(value instanceof Timestamp) || !(limit instanceof Timestamp)) {
    return false;
  }
  if (value.seconds !== limit.seconds) {
    return value.seconds < limit.seconds;
  }
  return value.nanoseconds <= limit.nanoseconds;
}

function rateLimitError(
  window: PairingRateLimitWindow,
  nowMilliseconds: number,
): HttpsError {
  const retryAfterSeconds = Math.max(
    1,
    Math.ceil((window.endsAtMilliseconds - nowMilliseconds) / 1000),
  );
  const requestDescription = window.operation === "create" ?
    "pairing code requests" :
    "pairing code attempts";
  return new HttpsError(
    "resource-exhausted",
    `Too many ${requestDescription}. Try again in ${retryAfterSeconds} seconds.`,
    {retryAfterSeconds},
  );
}

async function consumePairingAttempt<Result>(
  uid: string,
  operation: PairingRateLimitOperation,
  nowMilliseconds: number,
  perform: (transaction: Transaction) => Promise<Result>,
): Promise<Result> {
  const window = pairingRateLimitWindow(operation, nowMilliseconds);
  const attempts = db
    .collection("pairingRateLimits")
    .doc(uid)
    .collection("pairingAttempts");
  const attemptRefs = window.attemptDocumentIDs.map((id) => attempts.doc(id));
  let lastCollision: unknown;

  for (
    let collisionRetry = 0;
    collisionRetry <= window.maximumAttempts + 2;
    collisionRetry += 1
  ) {
    try {
      const outcome = await db.runTransaction(async (transaction) => {
        const snapshots = await transaction.getAll(...attemptRefs);
        const availableIndex = snapshots.findIndex(
          (snapshot) => !snapshot.exists,
        );
        if (availableIndex < 0) {
          return {kind: "rate-limited" as const};
        }

        const result = await perform(transaction);
        transaction.create(attemptRefs[availableIndex], {
          operation,
          slot: availableIndex,
          windowStartedAt: Timestamp.fromMillis(
            window.startedAtMilliseconds,
          ),
          createdAt: FieldValue.serverTimestamp(),
          expiresAt: Timestamp.fromMillis(window.expiresAtMilliseconds),
        });
        return {kind: "completed" as const, result};
      });

      if (outcome.kind === "rate-limited") {
        throw rateLimitError(window, nowMilliseconds);
      }
      return outcome.result;
    } catch (error) {
      if (
        isAlreadyExistsError(error) &&
        collisionRetry < window.maximumAttempts + 2
      ) {
        lastCollision = error;
        continue;
      }
      throw error;
    }
  }

  if (lastCollision) {
    throw lastCollision;
  }
  throw rateLimitError(window, nowMilliseconds);
}

function isAlreadyExistsError(error: unknown): boolean {
  const code = (error as {code?: number | string})?.code;
  return code === 6 || code === "already-exists";
}

export const createPairingCode = onCall(
  {region: "us-west1", enforceAppCheck: false},
  async (request) => {
    const uid = requireUid(request.auth);
    const userRef = db.collection("users").doc(uid);
    const nowMilliseconds = Date.now();
    const expiresAt = Timestamp.fromMillis(
      nowMilliseconds + PAIRING_CODE_TTL_MS,
    );

    for (let attempt = 0; attempt < 8; attempt += 1) {
      const code = makeCode();
      const codeRef = db.collection("pairingCodes").doc(code);

      try {
        const outcome = await consumePairingAttempt(
          uid,
          "create",
          nowMilliseconds,
          async (transaction) => {
            const userSnapshot = await transaction.get(userRef);
            if (!userSnapshot.exists) {
              return {
                kind: "failed" as const,
                error: new HttpsError(
                  "failed-precondition",
                  "Finish creating your profile before pairing.",
                ),
              };
            }
            if (userSnapshot.data()?.e2eeRequired === true) {
              return {kind: "failed" as const, error: new HttpsError("failed-precondition", "Update Peapod to use secure pairing.")};
            }
            if (userSnapshot.data()?.activeConversationId) {
              return {
                kind: "failed" as const,
                error: new HttpsError(
                  "failed-precondition",
                  "This account is already paired.",
                ),
              };
            }

            transaction.create(codeRef, {
              creatorId: uid,
              createdAt: FieldValue.serverTimestamp(),
              expiresAt,
              consumedAt: null,
              consumedBy: null,
            });
            return {kind: "created" as const};
          },
        );

        if (outcome.kind === "failed") {
          throw outcome.error;
        }
        return {code, expiresAtMillis: expiresAt.toMillis()};
      } catch (error) {
        if (!isAlreadyExistsError(error)) {
          throw error;
        }
      }
    }

    logger.error("Failed to allocate a unique pairing code", {uid});
    throw new HttpsError("resource-exhausted", "Please try again.");
  },
);

export const redeemPairingCode = onCall(
  {region: "us-west1", enforceAppCheck: false},
  async (request) => {
    const redeemerId = requireUid(request.auth);
    const nowMilliseconds = Date.now();
    let code: string;
    try {
      code = normalizeCode(request.data?.code);
    } catch (error) {
      await consumePairingAttempt(
        redeemerId,
        "redeem",
        nowMilliseconds,
        async () => undefined,
      );
      throw error;
    }

    const codeRef = db.collection("pairingCodes").doc(code);
    const conversationRef = db.collection("conversations").doc();

    const outcome = await consumePairingAttempt(
      redeemerId,
      "redeem",
      nowMilliseconds,
      async (transaction) => {
        const codeSnapshot = await transaction.get(codeRef);
        const fail = (error: HttpsError) => {
          return {kind: "failed" as const, error};
        };

        if (!codeSnapshot.exists) {
          return fail(
            new HttpsError("not-found", "The pairing code was not found."),
          );
        }

        const codeData = codeSnapshot.data();
        const creatorId = codeData?.creatorId as string | undefined;
        const createdAt = codeData?.createdAt;
        const expiresAt = codeData?.expiresAt;
        const expiresAtMilliseconds = timestampMilliseconds(expiresAt);

        if (
          !creatorId ||
          !(createdAt instanceof Timestamp) ||
          expiresAtMilliseconds === undefined
        ) {
          return fail(
            new HttpsError("data-loss", "The pairing code is malformed."),
          );
        }
        if (creatorId === redeemerId) {
          return fail(
            new HttpsError(
              "failed-precondition",
              "Use this code on the other person's device.",
            ),
          );
        }
        if (codeData?.consumedAt) {
          return fail(
            new HttpsError(
              "failed-precondition",
              "The pairing code has already been used.",
            ),
          );
        }
        if (expiresAtMilliseconds <= nowMilliseconds) {
          return fail(
            new HttpsError(
              "deadline-exceeded",
              "The pairing code has expired.",
            ),
          );
        }

        const creatorRef = db.collection("users").doc(creatorId);
        const redeemerRef = db.collection("users").doc(redeemerId);
        const [creatorSnapshot, redeemerSnapshot] = await Promise.all([
          transaction.get(creatorRef),
          transaction.get(redeemerRef),
        ]);

        if (!creatorSnapshot.exists || !redeemerSnapshot.exists) {
          return fail(
            new HttpsError(
              "failed-precondition",
              "Both people must finish creating their profiles before pairing.",
            ),
          );
        }
        if (
          timestampIsAtOrBefore(
            createdAt,
            creatorSnapshot.data()?.pairingResetAt,
          )
        ) {
          return fail(
            new HttpsError(
              "failed-precondition",
              "The pairing code is no longer valid.",
            ),
          );
        }
        if (creatorSnapshot.data()?.e2eeRequired === true || redeemerSnapshot.data()?.e2eeRequired === true) {
          return fail(new HttpsError("failed-precondition", "Update Peapod to use secure pairing."));
        }
        if (
          creatorSnapshot.data()?.activeConversationId ||
          redeemerSnapshot.data()?.activeConversationId
        ) {
          return fail(
            new HttpsError(
              "failed-precondition",
              "One of these accounts is already paired.",
            ),
          );
        }

        transaction.create(conversationRef, {
          members: [creatorId, redeemerId],
          status: "active",
          createdBy: creatorId,
          createdAt: FieldValue.serverTimestamp(),
          updatedAt: FieldValue.serverTimestamp(),
          lastMessageAt: null,
          lastMessagePreview: null,
        });
        transaction.set(
          creatorRef,
          {
            activeConversationId: conversationRef.id,
            updatedAt: FieldValue.serverTimestamp(),
          },
          {merge: true},
        );
        transaction.set(
          redeemerRef,
          {
            activeConversationId: conversationRef.id,
            updatedAt: FieldValue.serverTimestamp(),
          },
          {merge: true},
        );
        transaction.update(codeRef, {
          consumedAt: FieldValue.serverTimestamp(),
          consumedBy: redeemerId,
          conversationId: conversationRef.id,
        });

        return {
          kind: "paired" as const,
          conversationId: conversationRef.id,
        };
      },
    );

    if (outcome.kind === "failed") {
      throw outcome.error;
    }
    return {conversationId: outcome.conversationId};
  },
);

export const cancelPairingCode = onCall(
  {region: "us-west1", enforceAppCheck: false},
  async (request) => {
    const uid = requireUid(request.auth);
    const code = normalizeCode(request.data?.code);
    const codeRef = db.collection("pairingCodes").doc(code);
    const userRef = db.collection("users").doc(uid);

    const outcome = await db.runTransaction(async (transaction) => {
      const [codeSnapshot, userSnapshot] = await transaction.getAll(
        codeRef,
        userRef,
      );
      const activeConversationId =
        userSnapshot.data()?.activeConversationId as unknown;
      const conversationId =
        typeof activeConversationId === "string" &&
          activeConversationId.length > 0 ?
          activeConversationId :
          undefined;

      if (!codeSnapshot.exists) {
        return conversationId ?
          {kind: "paired" as const, conversationId} :
          {kind: "cancelled" as const};
      }

      const codeData = codeSnapshot.data();
      if (codeData?.creatorId !== uid) {
        return {
          kind: "failed" as const,
          error: new HttpsError(
            "permission-denied",
            "This account cannot cancel that pairing code.",
          ),
        };
      }

      if (codeData?.consumedAt) {
        const consumedConversationId =
          typeof codeData.conversationId === "string" &&
            codeData.conversationId.length > 0 ?
            codeData.conversationId :
            conversationId;
        if (!consumedConversationId) {
          return {
            kind: "failed" as const,
            error: new HttpsError(
              "data-loss",
              "The completed pairing could not be found.",
            ),
          };
        }
        return {
          kind: "paired" as const,
          conversationId: consumedConversationId,
        };
      }

      transaction.delete(codeRef);

      return conversationId ?
        {kind: "paired" as const, conversationId} :
        {kind: "cancelled" as const};
    });

    if (outcome.kind === "failed") {
      throw outcome.error;
    }
    if (outcome.kind === "paired") {
      return {
        cancelled: false,
        conversationId: outcome.conversationId,
      };
    }
    return {cancelled: true};
  },
);

// Keep retired endpoint names deployed so older clients cannot destroy a chat.
export {
  closeConversation,
  deleteConversation,
  deleteConversationData,
} from "./conversationRetention.js";

export const synchronizeUnreadBadgeOnMessageCreated = onDocumentCreated(
  {
    document: "conversations/{conversationId}/messages/{messageId}",
    region: "us-west1",
    retry: true,
  },
  async (event) => {
    const snapshot = event.data;
    if (!snapshot) {
      return;
    }

    const message = snapshot.data() as MessageDocument;
    const conversationId = event.params.conversationId;
    const messageId = event.params.messageId;
    const conversationRef = db.collection("conversations").doc(conversationId);
    const conversation = await conversationRef.get();
    const conversationData = conversation.data();
    if (conversationData?.status === "closed") {
      logger.info("Ignoring badge sync for message in closed conversation", {
        conversationId,
        messageId,
      });
      return;
    }

    const members = stringArray(conversationData?.members);
    const recipientIds = members.filter(
      (memberId) => memberId !== message.senderId,
    );
    if (
      !members.includes(message.senderId) ||
      recipientIds.length !== 1
    ) {
      logger.warn("Ignoring message badge sync with invalid membership", {
        conversationId,
        messageId,
        senderId: message.senderId,
      });
      return;
    }

    const recipientId = recipientIds[0];
    await requestUnreadBadgeSync(recipientId);
  },
);

export const notifyMessageCreated = onDocumentCreated(
  {
    document: "conversations/{conversationId}/messages/{messageId}",
    region: "us-west1",
    retry: true,
  },
  async (event) => {
    const snapshot = event.data;
    if (!snapshot) {
      return;
    }

    const message = snapshot.data() as MessageDocument;
    const conversationId = event.params.conversationId;
    const messageId = event.params.messageId;
    const conversationRef = db.collection("conversations").doc(conversationId);
    const [conversationSnapshot, senderSnapshot] = await Promise.all([
      conversationRef.get(),
      db.collection("users").doc(message.senderId).get(),
    ]);
    const conversationData = conversationSnapshot.data();
    if (conversationData?.status === "closed") {
      logger.info("Ignoring message in a closed conversation", {
        conversationId,
        messageId,
      });
      return;
    }
    const members = conversationData?.members;

    if (!Array.isArray(members) || !members.includes(message.senderId)) {
      logger.warn("Ignoring message with invalid conversation membership", {
        conversationId,
        messageId,
        senderId: message.senderId,
      });
      return;
    }

    const recipientIds = members.filter(
      (member): member is string =>
        typeof member === "string" && member !== message.senderId,
    );
    const preview = messageNotificationPreview(conversationData?.encryption, message);
    const senderDisplayName = senderSnapshot.data()?.displayName;
    const senderName =
      typeof senderDisplayName === "string" && senderDisplayName.length > 0
        ? senderDisplayName.slice(0, 80)
        : "New message";

    await conversationRef.update({
      lastMessageAt: snapshot.createTime,
      lastMessagePreview: preview,
      updatedAt: FieldValue.serverTimestamp(),
    });

    if (!shouldSendMessageAlert(message.delivery, message)) {
      logger.info("Suppressed message alert delivery", {
        conversationId,
        messageId,
      });
      return;
    }

    const [currentSnapshot, previewSnapshot] = await Promise.all([
      snapshot.ref.get(),
      conversationData?.encryption === "mines-e2ee-v1"
        ? conversationRef.collection("notificationPreviews").doc(messageId).get()
        : Promise.resolve(undefined),
    ]);
    const alertState = messageAlertCurrentState(
      message, currentSnapshot.data() as MessageDocument | undefined, previewSnapshot?.data(),
    );
    if (!alertState.shouldAlert) {
      logger.info("Suppressed alert for removed message", {conversationId, messageId});
      return;
    }
    const notificationPreview = alertState.notificationPreview;

    const deviceSnapshots = await Promise.all(
      recipientIds.map((uid) =>
        db.collection("users").doc(uid).collection("devices").get(),
      ),
    );
    const devicesByToken = new Map<string, DeviceTarget>();
    deviceSnapshots.forEach((deviceSnapshot) => {
      deviceSnapshot.docs.forEach((document) => {
        const token = document.data().token;
        if (typeof token !== "string" || token.length === 0) {
          return;
        }
        const existing = devicesByToken.get(token);
        if (existing) {
          existing.refs.push(document.ref);
        } else {
          devicesByToken.set(token, {
            token,
            tokenHash: hashDeliveryToken(token),
            refs: [document.ref],
          });
        }
      });
    });
    const devices = [...devicesByToken.values()];
    const deliveryRef = conversationRef
      .collection("notificationDeliveries")
      .doc(messageId);
    const attemptId = `${event.id}-${randomBytes(8).toString("hex")}`;
    const claim = await claimNotificationDelivery(
      deliveryRef,
      devices,
      attemptId,
      event.id,
    );

    if (claim.kind === "complete") {
      logger.info("Notification delivery already complete", {
        conversationId,
        messageId,
      });
      return;
    }
    if (claim.kind === "exhausted") {
      logger.error("Notification delivery exhausted its retry budget", {
        conversationId,
        messageId,
        maximumAttempts: MAX_NOTIFICATION_DELIVERY_ATTEMPTS,
      });
      return;
    }
    if (claim.kind === "busy") {
      throw new Error(
        `Notification delivery ${conversationId}/${messageId} is leased.`,
      );
    }

    let transientFailureCount = 0;
    let permanentFailureCount = 0;
    const collapseId = notificationCollapseId(conversationId, messageId);
    const payload = messageNotificationPayload(
      conversationData?.encryption, {...message, notificationPreview}, conversationId, messageId, senderName,
    );

    for (let start = 0; start < claim.targets.length; start += 500) {
      const batch = claim.targets.slice(start, start + 500);
      let response;
      try {
        response = await getMessaging().sendEachForMulticast({
          tokens: batch.map((device) => device.token),
          ...payload,
          apns: {
            ...payload.apns,
            headers: {
              "apns-collapse-id": collapseId,
            },
          },
        });
      } catch (error) {
        const code = messagingErrorCode(error);
        const disposition = classifyMessagingResult(false, code);
        if (disposition === "transient") {
          transientFailureCount += batch.length;
          logger.warn("Transient multicast request failure", {
            conversationId,
            messageId,
            attemptCount: claim.attemptCount,
            code,
            tokenCount: batch.length,
          });
          break;
        }

        permanentFailureCount += batch.length;
        await recordDeliveryHashes(
          deliveryRef,
          [],
          batch.map((target) => target.tokenHash),
        );
        logger.error("Permanent multicast request failure", {
          conversationId,
          messageId,
          attemptCount: claim.attemptCount,
          code,
          tokenCount: batch.length,
        });
        continue;
      }

      const deliveredHashes: string[] = [];
      const permanentHashes: string[] = [];
      const invalidTargets: DeviceTarget[] = [];

      response.responses.forEach((result, index) => {
        const target = batch[index];
        const code = result.error?.code;
        switch (classifyMessagingResult(result.success, code)) {
          case "delivered":
            deliveredHashes.push(target.tokenHash);
            break;
          case "invalid-token":
            invalidTargets.push(target);
            break;
          case "transient":
            transientFailureCount += 1;
            break;
          case "permanent":
            permanentFailureCount += 1;
            permanentHashes.push(target.tokenHash);
            logger.error("Permanent notification token failure", {
              conversationId,
              messageId,
              attemptCount: claim.attemptCount,
              code,
              tokenHash: target.tokenHash,
            });
            break;
        }
      });

      await recordDeliveryHashes(
        deliveryRef,
        deliveredHashes,
        permanentHashes,
      );
      if (invalidTargets.length > 0) {
        await deleteDeviceRefs(
          invalidTargets.flatMap((target) => target.refs),
        );
        await recordDeliveryHashes(
          deliveryRef,
          [],
          invalidTargets.map((target) => target.tokenHash),
        );
        logger.info("Pruned invalid notification tokens", {
          conversationId,
          messageId,
          count: invalidTargets.length,
        });
      }
    }

    if (
      transientFailureCount > 0 &&
      canRetryDelivery(claim.attemptCount)
    ) {
      await deliveryRef.set({
        status: "retrying",
        transientFailureCount,
        permanentFailureCount,
        leaseOwner: FieldValue.delete(),
        leaseExpiresAt: FieldValue.delete(),
        updatedAt: FieldValue.serverTimestamp(),
      }, {merge: true});
      logger.warn("Retrying transient notification failures", {
        conversationId,
        messageId,
        attemptCount: claim.attemptCount,
        transientFailureCount,
      });
      throw new Error(
        `Transient notification failure for ${conversationId}/${messageId}.`,
      );
    }

    const exhausted = transientFailureCount > 0;
    await deliveryRef.set({
      status: exhausted ? "abandoned" : "complete",
      transientFailureCount,
      permanentFailureCount,
      completedAt: FieldValue.serverTimestamp(),
      leaseOwner: FieldValue.delete(),
      leaseExpiresAt: FieldValue.delete(),
      updatedAt: FieldValue.serverTimestamp(),
    }, {merge: true});

    if (exhausted) {
      logger.error("Notification delivery reached its retry limit", {
        conversationId,
        messageId,
        attemptCount: claim.attemptCount,
        transientFailureCount,
      });
    }
  },
);

export const synchronizeUnreadBadge = onDocumentWritten(
  {
    document: "conversations/{conversationId}/readStates/{recipientId}",
    region: "us-west1",
    retry: true,
  },
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    const conversationId = event.params.conversationId;
    const recipientId = event.params.recipientId;
    const previousReadMessageId = before?.lastReadMessageId;
    const currentReadMessageId = after?.lastReadMessageId;

    if (!shouldSynchronizeBadge(
      previousReadMessageId,
      currentReadMessageId,
      Boolean(after),
    )) {
      return;
    }

    if (!after) {
      await requestUnreadBadgeSync(recipientId);
      return;
    }

    const conversationRef = db.collection("conversations").doc(conversationId);
    const conversation = await conversationRef.get();
    const conversationData = conversation.data();
    const members = stringArray(conversationData?.members);
    const incomingSenderIds = members.filter(
      (memberId) => memberId !== recipientId,
    );
    if (
      !conversation.exists ||
      !members.includes(recipientId) ||
      incomingSenderIds.length !== 1
    ) {
      logger.warn("Ignoring badge sync with invalid conversation membership", {
        conversationId,
        recipientId,
      });
      return;
    }

    await requestUnreadBadgeSync(recipientId);
  },
);

export const processUnreadBadgeSync = onDocumentWritten(
  {
    document: "users/{recipientId}/badgeSyncStates/current",
    region: "us-west1",
    retry: true,
    timeoutSeconds: 60,
  },
  async (event) => {
    const after = event.data?.after.data();
    if (!after) {
      return;
    }
    const desiredGeneration = storedNonnegativeInteger(
      after.desiredGeneration,
      "desired generation",
    );
    const previousDesiredGeneration = event.data?.before.exists ?
      storedNonnegativeInteger(
        event.data.before.data()?.desiredGeneration,
        "desired generation",
      ) :
      undefined;
    if (previousDesiredGeneration === desiredGeneration) {
      return;
    }

    await processBadgeSyncState(
      event.params.recipientId,
      event.id,
    );
  },
);

export const cleanupUnsentMessage = onDocumentUpdated(
  {
    document: "conversations/{conversationId}/messages/{messageId}",
    region: "us-west1",
    retry: true,
  },
  async (event) => {
    const before = event.data?.before.data() as MessageDocument | undefined;
    const after = event.data?.after.data() as MessageDocument | undefined;
    if (!before || !after || before.deletedAt || !after.deletedAt) {
      return;
    }

    const conversationId = event.params.conversationId;
    const messageId = event.params.messageId;
    const conversationRef = db.collection("conversations").doc(conversationId);
    const [attachments, reactions] = await Promise.all([
      conversationRef
        .collection("attachments")
        .where("messageId", "==", messageId)
        .get(),
      conversationRef
        .collection("reactions")
        .where("messageId", "==", messageId)
        .get(),
    ]);

    await Promise.all(
      attachments.docs.map(async (document) => {
        const storagePath = document.data().storagePath;
        if (typeof storagePath === "string" && storagePath.length > 0) {
          await storage.bucket().file(storagePath).delete({
            ignoreNotFound: true,
          });
        }
      }),
    );

    const cleanup = db.batch();
    attachments.docs.forEach((document) => cleanup.delete(document.ref));
    reactions.docs.forEach((document) => cleanup.delete(document.ref));
    await cleanup.commit();

    logger.info("Cleaned up data for unsent message", {
      conversationId,
      messageId,
      attachmentCount: attachments.size,
      reactionCount: reactions.size,
    });
  },
);

export const cleanupOrphanAttachments = onSchedule(
  {
    schedule: "0 3 * * *",
    timeZone: "Etc/UTC",
    region: "us-west1",
    retryCount: 3,
  },
  async () => {
    const nowMilliseconds = Date.now();
    const cutoff = Timestamp.fromMillis(
      nowMilliseconds - ORPHAN_ATTACHMENT_MIN_AGE_MILLISECONDS,
    );
    const snapshot = await db
      .collectionGroup("attachments")
      .where("createdAt", "<=", cutoff)
      .get();
    const counts: Record<OrphanAttachmentCleanupResult, number> = {
      deleted: 0,
      retained: 0,
      "skipped-invalid": 0,
      "skipped-too-new": 0,
    };
    let failureCount = 0;

    for (const document of snapshot.docs) {
      const conversationRef = document.ref.parent.parent;
      if (!conversationRef) {
        counts["skipped-invalid"] += 1;
        logger.warn("Skipping attachment without a conversation parent", {
          attachmentPath: document.ref.path,
        });
        continue;
      }

      const data = document.data();
      const createdAt = data.createdAt;
      const messageId = data.messageId;
      const storagePath = data.storagePath;
      if (
        !(createdAt instanceof Timestamp) ||
        typeof messageId !== "string" ||
        typeof storagePath !== "string"
      ) {
        counts["skipped-invalid"] += 1;
        logger.warn("Skipping malformed attachment cleanup candidate", {
          attachmentPath: document.ref.path,
        });
        continue;
      }

      try {
        const result = await cleanupOrphanAttachment(
          {
            createdAtMilliseconds: createdAt.toMillis(),
            messageId,
            storagePath,
            expectedStoragePrefix:
              `${conversationRef.path}/attachments/${document.id}/`,
          },
          {
            messageExists: async (candidateMessageId) => {
              const message = await conversationRef
                .collection("messages")
                .doc(candidateMessageId)
                .get();
              return message.exists &&
                messageDocumentIsLive(message.data());
            },
            deleteBlob: async (candidateStoragePath) => {
              await storage.bucket().file(candidateStoragePath).delete({
                ignoreNotFound: true,
              });
            },
            deleteMetadata: async () => {
              await document.ref.delete();
            },
          },
          nowMilliseconds,
        );
        counts[result] += 1;
      } catch (error) {
        failureCount += 1;
        logger.error("Failed to clean up orphan attachment", {
          attachmentPath: document.ref.path,
          error,
        });
      }
    }

    logger.info("Finished orphan attachment cleanup", {
      cutoff: cutoff.toDate().toISOString(),
      scannedCount: snapshot.size,
      failureCount,
      ...counts,
    });

    if (failureCount > 0) {
      throw new Error(
        `Failed to clean up ${failureCount} orphan attachment(s).`,
      );
    }
  },
);
