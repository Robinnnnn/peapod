import assert from "node:assert/strict";
import {randomUUID} from "node:crypto";
import {after, before, describe, it} from "node:test";

import {deleteApp, initializeApp} from "firebase-admin/app";
import {getFirestore} from "firebase-admin/firestore";
import {getStorage} from "firebase-admin/storage";

const projectId = process.env.PEAPOD_PAIRING_TEST_PROJECT ?? "demo-peapod";
const region = "us-west1";
const authEmulatorHost =
  process.env.FIREBASE_AUTH_EMULATOR_HOST ?? "127.0.0.1:9099";
const functionsEmulatorHost =
  process.env.FUNCTIONS_EMULATOR_HOST ?? "127.0.0.1:5001";
const app = initializeApp({projectId}, "pairing-functions-integration");
const firestore = getFirestore(app);
const bucket = getStorage(app).bucket(`${projectId}.appspot.com`);

type CallableResponse = {
  data?: unknown;
  result?: unknown;
  error?: {
    status?: string;
    message?: string;
    details?: unknown;
  };
};

async function createAuthenticatedUser(
  name: string,
): Promise<{uid: string; idToken: string}> {
  const response = await fetch(
    `http://${authEmulatorHost}/identitytoolkit.googleapis.com/v1/accounts:signUp?key=fake-key`,
    {
      method: "POST",
      headers: {"content-type": "application/json"},
      body: JSON.stringify({
        email: `${name}-${randomUUID()}@example.test`,
        password: "correct-horse-battery-staple",
        returnSecureToken: true,
      }),
    },
  );
  const body = await response.json() as {
    localId?: string;
    idToken?: string;
    error?: unknown;
  };
  assert.equal(response.ok, true, JSON.stringify(body));
  assert.ok(body.localId);
  assert.ok(body.idToken);
  await firestore.collection("users").doc(body.localId).set({
    displayName: name,
  });
  return {uid: body.localId, idToken: body.idToken};
}

async function call(
  functionName: string,
  idToken: string,
  data: Record<string, unknown> = {},
): Promise<{status: number; body: CallableResponse}> {
  const response = await fetch(
    `http://${functionsEmulatorHost}/${projectId}/${region}/${functionName}`,
    {
      method: "POST",
      headers: {
        authorization: `Bearer ${idToken}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({data}),
    },
  );
  return {
    status: response.status,
    body: await response.json() as CallableResponse,
  };
}

before(async () => {
  assert.match(projectId, /^demo-/);
  for (const host of [process.env.FIRESTORE_EMULATOR_HOST,
    process.env.FIREBASE_STORAGE_EMULATOR_HOST]) {
    assert.match(host ?? "", /^(127\.0\.0\.1|localhost):[0-9]+$/,
      "Pairing integration tests require local Firestore and Storage emulators");
  }
  await firestore.recursiveDelete(
    firestore.collection("pairingCodes"),
  );
  await firestore.recursiveDelete(
    firestore.collection("pairingRateLimits"),
  );
  await firestore.recursiveDelete(
    firestore.collection("users"),
  );
  await firestore.recursiveDelete(
    firestore.collection("conversations"),
  );
  await firestore.recursiveDelete(
    firestore.collection("conversationDeletionJobs"),
  );
});

after(async () => {
  await deleteApp(app);
});

describe("pairing callable throttles", () => {
  it("keeps the existing create and redeem response shapes", async () => {
    const creator = await createAuthenticatedUser("shape-creator");
    const redeemer = await createAuthenticatedUser("shape-redeemer");
    const created = await call("createPairingCode", creator.idToken);
    const createData = (created.body.data ?? created.body.result) as {
      code?: string;
      expiresAtMillis?: number;
    };
    assert.match(createData.code ?? "", /^[23456789A-HJ-NP-Z]{8}$/);
    assert.equal(typeof createData.expiresAtMillis, "number");

    const redeemed = await call(
      "redeemPairingCode",
      redeemer.idToken,
      {code: createData.code},
    );
    const redeemData = (
      (redeemed.body.data ?? redeemed.body.result) ?? {}
    ) as {conversationId?: string};
    assert.ok(redeemData.conversationId);

    const conversation = await firestore
      .collection("conversations")
      .doc(redeemData.conversationId)
      .get();
    assert.deepEqual(
      new Set(conversation.data()?.members),
      new Set([creator.uid, redeemer.uid]),
    );
    assert.equal(conversation.data()?.status, "active");
    const [creatorProfile, redeemerProfile] = await Promise.all([
      firestore.collection("users").doc(creator.uid).get(),
      firestore.collection("users").doc(redeemer.uid).get(),
    ]);
    assert.equal(
      creatorProfile.data()?.activeConversationId,
      redeemData.conversationId,
    );
    assert.equal(
      redeemerProfile.data()?.activeConversationId,
      redeemData.conversationId,
    );
  });

  it("cancels a creator's pending code so it cannot be redeemed", async () => {
    const creator = await createAuthenticatedUser("cancel-creator");
    const redeemer = await createAuthenticatedUser("cancel-redeemer");
    const created = await call("createPairingCode", creator.idToken);
    const createData = (created.body.data ?? created.body.result) as {
      code?: string;
    };
    assert.ok(createData.code);

    const cancelled = await call(
      "cancelPairingCode",
      creator.idToken,
      {code: createData.code},
    );
    assert.equal(cancelled.body.error, undefined);
    const cancelData = (cancelled.body.data ?? cancelled.body.result) as {
      cancelled?: boolean;
      conversationId?: string;
    };
    assert.equal(cancelData.cancelled, true);
    assert.equal(cancelData.conversationId, undefined);

    const code = await firestore
      .collection("pairingCodes")
      .doc(createData.code)
      .get();
    assert.equal(code.exists, false);

    const redeemed = await call(
      "redeemPairingCode",
      redeemer.idToken,
      {code: createData.code},
    );
    assert.equal(redeemed.body.error?.status, "NOT_FOUND");
    assert.equal(
      (
        await firestore.collection("users").doc(creator.uid).get()
      ).data()?.activeConversationId,
      undefined,
    );
  });

  it("does not let another account cancel a pending code", async () => {
    const creator = await createAuthenticatedUser("owned-code-creator");
    const other = await createAuthenticatedUser("owned-code-other");
    const redeemer = await createAuthenticatedUser("owned-code-redeemer");
    const created = await call("createPairingCode", creator.idToken);
    const createData = (created.body.data ?? created.body.result) as {
      code?: string;
    };
    assert.ok(createData.code);

    const denied = await call(
      "cancelPairingCode",
      other.idToken,
      {code: createData.code},
    );
    assert.equal(denied.body.error?.status, "PERMISSION_DENIED");

    const redeemed = await call(
      "redeemPairingCode",
      redeemer.idToken,
      {code: createData.code},
    );
    const redeemData = (redeemed.body.data ?? redeemed.body.result) as {
      conversationId?: string;
    };
    assert.ok(redeemData.conversationId);
  });

  it("returns an established conversation when redemption already won", async () => {
    const creator = await createAuthenticatedUser("won-race-creator");
    const redeemer = await createAuthenticatedUser("won-race-redeemer");
    const created = await call("createPairingCode", creator.idToken);
    const createData = (created.body.data ?? created.body.result) as {
      code?: string;
    };
    assert.ok(createData.code);

    const redeemed = await call(
      "redeemPairingCode",
      redeemer.idToken,
      {code: createData.code},
    );
    const redeemData = (redeemed.body.data ?? redeemed.body.result) as {
      conversationId?: string;
    };
    assert.ok(redeemData.conversationId);

    const cancelled = await call(
      "cancelPairingCode",
      creator.idToken,
      {code: createData.code},
    );
    assert.equal(cancelled.body.error, undefined);
    const cancelData = (cancelled.body.data ?? cancelled.body.result) as {
      cancelled?: boolean;
      conversationId?: string;
    };
    assert.equal(cancelData.cancelled, false);
    assert.equal(cancelData.conversationId, redeemData.conversationId);
    assert.equal(
      (
        await firestore
          .collection("conversations")
          .doc(redeemData.conversationId)
          .get()
      ).data()?.status,
      "active",
    );
  });

  it("serializes cancellation with redemption without breaking a pairing", async () => {
    const creator = await createAuthenticatedUser("race-creator");
    const redeemer = await createAuthenticatedUser("race-redeemer");
    const created = await call("createPairingCode", creator.idToken);
    const createData = (created.body.data ?? created.body.result) as {
      code?: string;
    };
    assert.ok(createData.code);

    const [cancelled, redeemed] = await Promise.all([
      call(
        "cancelPairingCode",
        creator.idToken,
        {code: createData.code},
      ),
      call(
        "redeemPairingCode",
        redeemer.idToken,
        {code: createData.code},
      ),
    ]);
    assert.equal(cancelled.body.error, undefined);
    const cancelData = (cancelled.body.data ?? cancelled.body.result) as {
      cancelled?: boolean;
      conversationId?: string;
    };
    const redeemData = (
      (redeemed.body.data ?? redeemed.body.result) ?? {}
    ) as {conversationId?: string};

    if (redeemData.conversationId) {
      assert.equal(cancelData.cancelled, false);
      assert.equal(cancelData.conversationId, redeemData.conversationId);
      const [creatorProfile, redeemerProfile, conversation] =
        await Promise.all([
          firestore.collection("users").doc(creator.uid).get(),
          firestore.collection("users").doc(redeemer.uid).get(),
          firestore
            .collection("conversations")
            .doc(redeemData.conversationId)
            .get(),
        ]);
      assert.equal(
        creatorProfile.data()?.activeConversationId,
        redeemData.conversationId,
      );
      assert.equal(
        redeemerProfile.data()?.activeConversationId,
        redeemData.conversationId,
      );
      assert.equal(conversation.data()?.status, "active");
    } else {
      assert.equal(cancelData.cancelled, true);
      assert.equal(
        redeemed.body.error?.status,
        "NOT_FOUND",
      );
      assert.equal(
        (
          await firestore.collection("users").doc(creator.uid).get()
        ).data()?.activeConversationId,
        undefined,
      );
    }
  });

  it("serializes concurrent create requests at five per user per hour", async () => {
    const creator = await createAuthenticatedUser("creator");
    const responses = await Promise.all(
      Array.from(
        {length: 8},
        () => call("createPairingCode", creator.idToken),
      ),
    );
    const successes = responses.filter(
      (response) => response.body.error === undefined,
    );
    const denied = responses.filter(
      (response) =>
        response.body.error?.status === "RESOURCE_EXHAUSTED",
    );

    const attempts = await firestore
      .collection("pairingRateLimits")
      .doc(creator.uid)
      .collection("pairingAttempts")
      .get();
    const evidence = JSON.stringify({
      responses: responses.map((response) => response.body),
      attempts: attempts.docs.map((document) => document.data()),
    });
    assert.equal(successes.length, 5, evidence);
    assert.equal(denied.length, 3, evidence);
    for (const response of successes) {
      const data = (response.body.data ?? response.body.result) as {
        code?: string;
        expiresAtMillis?: number;
      };
      assert.match(data.code ?? "", /^[23456789A-HJ-NP-Z]{8}$/);
      assert.equal(typeof data.expiresAtMillis, "number");
    }

    assert.equal(attempts.size, 5);
    assert.equal(
      (
        await firestore
          .collection("pairingCodes")
          .where("creatorId", "==", creator.uid)
          .get()
      ).size,
      5,
    );
  });

  it("rejects conversation close and delete requests while retaining both assignments and history", async () => {
    const creator = await createAuthenticatedUser("retained-creator");
    const redeemer = await createAuthenticatedUser("retained-redeemer");
    const created = await call("createPairingCode", creator.idToken);
    const createData = (created.body.data ?? created.body.result) as {code?: string};
    const redeemed = await call("redeemPairingCode", redeemer.idToken, {code: createData.code});
    const redeemData = (redeemed.body.data ?? redeemed.body.result) as {conversationId?: string};
    assert.ok(redeemData.conversationId);
    const conversationId = redeemData.conversationId;
    const conversationRef = firestore.collection("conversations").doc(conversationId);
    const storagePath = `conversations/${conversationId}/attachments/example/photo.png`;
    const blobBytes = Buffer.from("synthetic retained content");
    await Promise.all([
      conversationRef.collection("messages").doc("example").set({senderId: creator.uid, type: "photo"}),
      conversationRef.collection("attachments").doc("example").set({ownerId: creator.uid, messageId: "example", storagePath}),
      bucket.file(storagePath).save(blobBytes),
    ]);
    // Wait for the independent message-created trigger before comparing retained
    // state. Its normal preview update can otherwise race these rejected calls.
    const messageCreatedAt = (await conversationRef.collection("messages").doc("example").get()).createTime;
    await new Promise<void>((resolve, reject) => {
      const timeout = setTimeout(() => {
        unsubscribe();
        reject(new Error("Message-created trigger did not publish its conversation preview"));
      }, 10_000);
      const unsubscribe = conversationRef.onSnapshot((snapshot) => {
        if (snapshot.data()?.lastMessageAt?.isEqual(messageCreatedAt)) {
          clearTimeout(timeout);
          unsubscribe();
          resolve();
        }
      }, (error) => {
        clearTimeout(timeout);
        reject(error);
      });
    });
    const readRetainedState = async () => {
      const refs = [conversationRef,
        firestore.collection("users").doc(creator.uid),
        firestore.collection("users").doc(redeemer.uid),
        conversationRef.collection("messages").doc("example"),
        conversationRef.collection("attachments").doc("example")];
      return Promise.all(refs.map(async (ref) => (await ref.get()).data()));
    };
    const before = await readRetainedState();

    for (const endpoint of ["closeConversation", "deleteConversation"]) {
      for (const data of [{}, {confirmation: "DELETE", expectedConversationId: conversationId},
        {confirmation: "DELETE", expectedConversationId: "stale-conversation"},
        {confirmation: "DELETE", expectedConversationId: null}]) {
        const rejected = await call(endpoint, creator.idToken, data);
        assert.equal(rejected.body.error?.status, "FAILED_PRECONDITION");
      }
      const unauthenticated = await call(endpoint, "", {confirmation: "DELETE"});
      assert.equal(unauthenticated.body.error?.status, "UNAUTHENTICATED");
    }
    assert.deepEqual(await readRetainedState(), before);
    assert.equal((await firestore.collection("conversationDeletionJobs").doc(conversationId).get()).exists, false);
    assert.deepEqual((await bucket.file(storagePath).download())[0], blobBytes);

    // A previously queued purge remains inert too. Invoke the actual exported
    // trigger deterministically, rather than inferring safety from a delay.
    const job = firestore.collection("conversationDeletionJobs").doc(conversationId);
    await job.set({conversationId, requestedBy: creator.uid});
    const {deleteConversationData} = await import("../src/conversationRetention.js");
    await deleteConversationData.run({data: await job.get(), params: {conversationId}} as
      Parameters<typeof deleteConversationData.run>[0]);
    assert.deepEqual(await readRetainedState(), before);
    assert.equal((await job.get()).exists, true);
    assert.deepEqual((await bucket.file(storagePath).download())[0], blobBytes);
  });

  it("also rejects removal for absent assignments, outsider accounts and already-retired generations", async () => {
    const owner = await createAuthenticatedUser("retired-owner");
    const peer = await createAuthenticatedUser("retired-peer");
    const outsider = await createAuthenticatedUser("retired-outsider");
    const id = "retired-retention-conversation";
    const reference = firestore.collection("conversations").doc(id);
    for (const status of ["active", "closed", "deleting"]) {
      await reference.set({members: [owner.uid, peer.uid], status});
      for (const endpoint of ["closeConversation", "deleteConversation"]) {
        for (const token of [owner.idToken, outsider.idToken]) {
          const rejected = await call(endpoint, token,
            {confirmation: "DELETE", expectedConversationId: id});
          assert.equal(rejected.body.error?.status, "FAILED_PRECONDITION");
        }
      }
      assert.equal((await reference.get()).data()?.status, status);
    }
    // An unknown target never yields a success that could clear local keys.
    const absent = await call("deleteConversation", owner.idToken,
      {confirmation: "DELETE", expectedConversationId: "absent-synthetic-conversation"});
    assert.equal(absent.body.error?.status, "FAILED_PRECONDITION");
  });

  it("serializes concurrent failed redemptions at ten per user per window", async () => {
    const redeemer = await createAuthenticatedUser("redeemer");
    const responses = await Promise.all(
      Array.from(
        {length: 14},
        () => call(
          "redeemPairingCode",
          redeemer.idToken,
          {code: "ZZZZZZZZ"},
        ),
      ),
    );
    const missing = responses.filter(
      (response) => response.body.error?.status === "NOT_FOUND",
    );
    const denied = responses.filter(
      (response) =>
        response.body.error?.status === "RESOURCE_EXHAUSTED",
    );

    const attempts = await firestore
      .collection("pairingRateLimits")
      .doc(redeemer.uid)
      .collection("pairingAttempts")
      .get();
    const evidence = JSON.stringify({
      responses: responses.map((response) => response.body),
      attempts: attempts.docs.map((document) => document.data()),
    });
    assert.equal(missing.length, 10, evidence);
    assert.equal(denied.length, 4, evidence);
    assert.equal(attempts.size, 10);
  });
});

it("requires upgraded pairing for accounts with the monotonic encryption floor", async () => {
  const owner = await createAuthenticatedUser("secure-floor-owner");
  await firestore.doc(`users/${owner.uid}`).update({e2eeRequired: true});
  const rejectedCreate = await call("createPairingCode", owner.idToken);
  assert.equal(rejectedCreate.body.error?.status, "FAILED_PRECONDITION");
  const legacy = await createAuthenticatedUser("secure-floor-legacy");
  const created = await call("createPairingCode", legacy.idToken);
  const payload = (created.body.result ?? created.body.data) as {code: string};
  assert.ok(payload.code);
  const rejectedRedeem = await call("redeemPairingCode", owner.idToken, {code: payload.code});
  assert.equal(rejectedRedeem.body.error?.status, "FAILED_PRECONDITION");
  assert.equal((await firestore.doc(`users/${owner.uid}`).get()).data()?.activeConversationId, undefined);
});

it("secure callable requires Firebase authentication and rejects private key fields", async () => {
  const unauthenticated = await call("publishSecureInvite", "invalid-token", {});
  assert.equal(unauthenticated.body.error?.status, "UNAUTHENTICATED");
  const owner = await createAuthenticatedUser("secure-private-boundary");
  const unexpected = await call("publishSecureInvite", owner.idToken, {
    inviteId: "a".repeat(32), conversationId: "00000000-0000-4000-8000-000000000001",
    epoch: 1, offer: Buffer.from("synthetic opaque offer").toString("base64"),
    expiresAtMillis: Date.now() + 60_000, epochKey: "never accept raw keys",
  });
  assert.equal(unexpected.body.error?.status, "INVALID_ARGUMENT");
});
