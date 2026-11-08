import assert from "node:assert/strict";
import {after, before, describe, it} from "node:test";

import {deleteApp, initializeApp} from "firebase-admin/app";
import {Timestamp, getFirestore} from "firebase-admin/firestore";

import {badgeSyncLifecycleTestSeam} from "../src/index.js";

assert.match(process.env.FIRESTORE_EMULATOR_HOST ?? "", /^(127\.0\.0\.1|localhost):[0-9]+$/, "Local Firestore emulator required");
const projectId = "demo-peapod";
const app = initializeApp({projectId}, "badge-sync-lifecycle-integration");
const firestore = getFirestore(app);

type Publication = {
  conversationId?: string;
  recipientId: string;
  unreadCount: number;
  tokens: string[];
};

before(async () => {
  await firestore.recursiveDelete(firestore.collection("users"));
  await firestore.recursiveDelete(firestore.collection("conversations"));
});

after(async () => {
  await deleteApp(app);
});

describe("recipient-global badge lifecycle storage", () => {
  it("drains a delayed old zero before the new count and fences its replay", async () => {
    const recipientId = "replacement-recipient";
    const newConversationId = "new-conversation";
    const newSenderId = "new-sender";
    const userRef = firestore.collection("users").doc(recipientId);
    const stateRef = userRef.collection("badgeSyncStates").doc("current");
    const newConversationRef = firestore
      .collection("conversations")
      .doc(newConversationId);
    const publications: Publication[] = [];
    const oldZeroStarted = deferred<void>();
    const finishOldZero = deferred<void>();

    await userRef.set({displayName: "Recipient"});
    await userRef.collection("devices").doc("iphone").set({
      platform: "ios",
      token: "iphone-token",
    });
    await badgeSyncLifecycleTestSeam.request(recipientId);

    const oldCleanup = badgeSyncLifecycleTestSeam.process(
      recipientId,
      "old-cleanup",
      async (conversationId, publishedRecipientId, unreadCount, batch) => {
        if (unreadCount === 0) {
          oldZeroStarted.resolve();
          await finishOldZero.promise;
        }
        publications.push({
          ...(conversationId ? {conversationId} : {}),
          recipientId: publishedRecipientId,
          unreadCount,
          tokens: batch.map((target) => target.token),
        });
      },
    );

    await oldZeroStarted.promise;
    const replacement = firestore.batch();
    replacement.set(newConversationRef, {
      members: [recipientId, newSenderId],
      status: "active",
    });
    replacement.set(userRef, {activeConversationId: newConversationId}, {
      merge: true,
    });
    for (let index = 1; index <= 3; index += 1) {
      replacement.set(
        newConversationRef.collection("messages").doc(`message-${index}`),
        {
          senderId: newSenderId,
          ...(index === 2 ? {delivery: "quiet"} : {}),
          createdAt: Timestamp.fromMillis(index * 1_000),
        },
      );
    }
    await replacement.commit();
    await badgeSyncLifecycleTestSeam.request(recipientId);
    finishOldZero.resolve();
    await oldCleanup;

    assert.deepEqual(
      publications.map(({conversationId, unreadCount}) => ({
        conversationId,
        unreadCount,
      })),
      [
        {conversationId: undefined, unreadCount: 0},
        {conversationId: newConversationId, unreadCount: 3},
      ],
    );

    await badgeSyncLifecycleTestSeam.request(recipientId);
    await badgeSyncLifecycleTestSeam.process(
      recipientId,
      "old-cleanup-replay",
      async (conversationId, publishedRecipientId, unreadCount, batch) => {
        publications.push({
          ...(conversationId ? {conversationId} : {}),
          recipientId: publishedRecipientId,
          unreadCount,
          tokens: batch.map((target) => target.token),
        });
      },
    );

    assert.equal(publications.at(-1)?.conversationId, newConversationId);
    assert.equal(publications.at(-1)?.unreadCount, 3);
    assert.deepEqual(publications.at(-1)?.tokens, ["iphone-token"]);
    assert.equal(publications.slice(1).some(
      (publication) => publication.unreadCount === 0,
    ), false);

    const state = (await stateRef.get()).data();
    assert.equal(state?.lastPublishedConversationId, newConversationId);
    assert.equal(state?.lastPublishedBadgeCount, 3);
    assert.equal(state?.lastPublishedTerminal, false);
    assert.equal(state?.processedGeneration, state?.desiredGeneration);
    assert.equal(state?.leaseOwner, undefined);
  });

  it("durably completes terminal zero and survives duplicate teardown", async () => {
    const recipientId = "terminal-recipient";
    const userRef = firestore.collection("users").doc(recipientId);
    const stateRef = userRef.collection("badgeSyncStates").doc("current");
    const publications: Publication[] = [];
    const publish = async (
      conversationId: string | undefined,
      publishedRecipientId: string,
      unreadCount: number,
      batch: Array<{token: string}>,
    ) => {
      publications.push({
        ...(conversationId ? {conversationId} : {}),
        recipientId: publishedRecipientId,
        unreadCount,
        tokens: batch.map((target) => target.token),
      });
    };

    await userRef.set({displayName: "Recipient"});
    await userRef.collection("devices").doc("iphone").set({
      platform: "ios",
      token: "terminal-iphone-token",
    });
    await badgeSyncLifecycleTestSeam.request(recipientId);
    await badgeSyncLifecycleTestSeam.process(
      recipientId,
      "teardown",
      publish,
    );

    let state = (await stateRef.get()).data();
    assert.equal((await stateRef.get()).exists, true);
    assert.deepEqual(publications.map((entry) => entry.unreadCount), [0]);
    assert.equal(state?.lastPublishedBadgeCount, 0);
    assert.equal(state?.lastPublishedTerminal, true);
    assert.equal(state?.lastPublishedConversationId, undefined);
    assert.equal(state?.processedGeneration, state?.desiredGeneration);

    await badgeSyncLifecycleTestSeam.process(
      recipientId,
      "duplicate-state-event",
      publish,
    );
    assert.deepEqual(publications.map((entry) => entry.unreadCount), [0]);

    await badgeSyncLifecycleTestSeam.request(recipientId);
    await badgeSyncLifecycleTestSeam.process(
      recipientId,
      "duplicate-teardown",
      publish,
    );
    state = (await stateRef.get()).data();

    assert.deepEqual(publications.map((entry) => entry.unreadCount), [0, 0]);
    assert.equal(state?.lastPublishedBadgeCount, 0);
    assert.equal(state?.lastPublishedTerminal, true);
    assert.equal(state?.processedGeneration, state?.desiredGeneration);
    assert.equal(state?.leaseOwner, undefined);
  });
});

function deferred<Value>() {
  let resolve!: (value: Value | PromiseLike<Value>) => void;
  const promise = new Promise<Value>((promiseResolve) => {
    resolve = promiseResolve;
  });
  return {promise, resolve};
}
