import assert from "node:assert/strict";
import {describe, it} from "node:test";

import {
  BadgeSyncBusyError,
  BadgeSyncDrainLimitError,
  BadgeSyncLease,
  BadgeSyncState,
  claimBadgeSyncState,
  completeBadgeSyncState,
  drainBadgeSync,
  observeBadgeSyncState,
  preflightBadgeSyncState,
  releaseBadgeSyncState,
} from "../src/badgeSyncCoordinator.js";

const LEASE_MILLISECONDS = 100;

describe("unread badge synchronization coordinator", () => {
  it("coalesces a newer request before the older count can publish", async () => {
    const harness = badgeHarness();
    const computed = deferred<void>();
    const resume = deferred<void>();
    let computationCount = 0;
    harness.request(1);

    const drain = harness.drain("owner-a", {
      compute: async () => {
        const count = harness.canonicalCount;
        computationCount += 1;
        if (computationCount === 1) {
          computed.resolve();
          await resume.promise;
        }
        return count;
      },
    });

    await computed.promise;
    harness.request(2);
    resume.resolve();
    await drain;

    assert.deepEqual(harness.publishedCounts, [2]);
    assert.equal(harness.state.processedGeneration, 2);
  });

  it("finishes a delayed older publication before draining the newer count", async () => {
    const harness = badgeHarness();
    const firstSendStarted = deferred<void>();
    const finishFirstSend = deferred<void>();
    harness.request(1);

    const olderDrain = harness.drain("owner-a", {
      publish: async (count) => {
        if (count === 1) {
          firstSendStarted.resolve();
          await finishFirstSend.promise;
        }
        harness.publishedCounts.push(count);
      },
    });

    await firstSendStarted.promise;
    harness.request(2);
    await assert.rejects(
      harness.drain("owner-b"),
      BadgeSyncBusyError,
    );
    finishFirstSend.resolve();
    await olderDrain;

    assert.deepEqual(harness.publishedCounts, [1, 2]);
    assert.equal(harness.state.processedGeneration, 2);
  });

  it("fences an expired owner from a replacement owner's lease", () => {
    let state = initialState(1);
    const firstClaim = claimBadgeSyncState(
      state,
      "owner-a",
      0,
      LEASE_MILLISECONDS,
    );
    assert.equal(firstClaim.kind, "claimed");
    if (firstClaim.kind !== "claimed") {
      return;
    }
    state = firstClaim.state;

    const replacement = claimBadgeSyncState(
      state,
      "owner-b",
      LEASE_MILLISECONDS,
      LEASE_MILLISECONDS,
    );
    assert.equal(replacement.kind, "claimed");
    if (replacement.kind !== "claimed") {
      return;
    }
    state = replacement.state;

    assert.equal(replacement.lease.fence, firstClaim.lease.fence + 1);
    assert.equal(
      preflightBadgeSyncState(
        state,
        firstClaim.lease,
        LEASE_MILLISECONDS,
        LEASE_MILLISECONDS,
      ).kind,
      "lost",
    );
    assert.equal(
      completeBadgeSyncState(
        state,
        firstClaim.lease,
        LEASE_MILLISECONDS,
        LEASE_MILLISECONDS,
      ).kind,
      "lost",
    );
    assert.strictEqual(
      releaseBadgeSyncState(state, firstClaim.lease),
      state,
    );
    assert.equal(
      preflightBadgeSyncState(
        state,
        replacement.lease,
        LEASE_MILLISECONDS,
        LEASE_MILLISECONDS,
      ).kind,
      "ready",
    );
  });

  it("preflights every batch and restarts with the latest generation", async () => {
    const harness = badgeHarness();
    const publications: string[] = [];
    harness.request(1);

    await harness.drain("owner-a", {
      batches: ["first", "second"],
      publish: async (count, batch) => {
        publications.push(`${count}:${batch}`);
        if (count === 1 && batch === "first") {
          harness.request(2);
        }
      },
    });

    assert.deepEqual(publications, ["1:first", "2:first", "2:second"]);
    assert.equal(harness.state.processedGeneration, 2);
  });

  it("releases a failed publication for a retry of the same generation", async () => {
    const harness = badgeHarness();
    harness.request(4);

    await assert.rejects(
      harness.drain("owner-a", {
        publish: async () => {
          throw new Error("transient transport failure");
        },
      }),
      /transient transport failure/u,
    );
    assert.equal(harness.state.leaseOwner, undefined);
    assert.equal(harness.state.processedGeneration, 0);

    await harness.drain("owner-b");
    assert.deepEqual(harness.publishedCounts, [4]);
    assert.equal(harness.state.processedGeneration, 1);
  });

  it("bounds continuous supersession and releases the lease", async () => {
    const harness = badgeHarness();
    harness.request(1);

    await assert.rejects(
      harness.drain("owner-a", {
        compute: async () => {
          const count = harness.canonicalCount;
          harness.request(count + 1);
          return count;
        },
        maximumPasses: 2,
      }),
      BadgeSyncDrainLimitError,
    );

    assert.deepEqual(harness.publishedCounts, []);
    assert.equal(harness.state.desiredGeneration, 3);
    assert.equal(harness.state.processedGeneration, 0);
    assert.equal(harness.state.leaseOwner, undefined);
  });

  it("fences an old cleanup when the active conversation changes before send", async () => {
    let state = initialState(1);
    let nowMilliseconds = 0;
    let active = {conversationId: "old-conversation", unreadCount: 0};
    let computationCount = 0;
    const publications: Array<{conversationId: string; unreadCount: number}> = [];

    await drainBadgeSync({
      claim: async () => {
        const result = claimBadgeSyncState(
          state, "owner", nowMilliseconds, LEASE_MILLISECONDS,
        );
        if (result.kind === "claimed") state = result.state;
        return result;
      },
      compute: async () => {
        const payload = {...active};
        computationCount += 1;
        if (computationCount === 1) {
          active = {conversationId: "new-conversation", unreadCount: 3};
        }
        return {payload, batches: ["devices"]};
      },
      preflight: async (lease, payload) => {
        if (payload.conversationId !== active.conversationId) {
          state = observeBadgeSyncState(state);
        }
        const result = preflightBadgeSyncState(
          state, lease, nowMilliseconds, LEASE_MILLISECONDS,
        );
        if (result.kind !== "lost") state = result.state;
        return result;
      },
      publishBatch: async (payload) => publications.push(payload),
      complete: async (lease) => {
        const result = completeBadgeSyncState(
          state, lease, nowMilliseconds, LEASE_MILLISECONDS,
        );
        if (result.kind !== "lost") state = result.state;
        return result;
      },
      release: async (lease) => {
        state = releaseBadgeSyncState(state, lease);
      },
    }, 8);

    assert.deepEqual(publications, [
      {conversationId: "new-conversation", unreadCount: 3},
    ]);
    assert.equal(state.processedGeneration, 2);
  });

  it("keeps the new nonzero badge after old cleanup and duplicate replay", async () => {
    const harness = badgeHarness();
    harness.request(3);
    await harness.drain("new-message");

    // Both deletion deliveries share the recipient-global state and recompute
    // the still-active new conversation rather than publishing the old zero.
    harness.request(3);
    await harness.drain("old-cleanup");
    harness.request(3);
    await harness.drain("old-cleanup-replay");

    assert.deepEqual(harness.publishedCounts, [3, 3, 3]);
    assert.equal(harness.state.processedGeneration, 3);
  });
});

function badgeHarness() {
  let state = initialState();
  let nowMilliseconds = 0;
  let canonicalCount = 0;
  const publishedCounts: number[] = [];

  return {
    get state() {
      return state;
    },
    get canonicalCount() {
      return canonicalCount;
    },
    publishedCounts,
    request(count: number) {
      canonicalCount = count;
      state = observeBadgeSyncState(state);
    },
    drain(
      ownerId: string,
      hooks: {
        compute?: () => Promise<number>;
        publish?: (count: number, batch: string) => Promise<void>;
        batches?: string[];
        maximumPasses?: number;
      } = {},
    ) {
      return drainBadgeSync<number, string>({
        claim: async () => {
          const result = claimBadgeSyncState(
            state,
            ownerId,
            nowMilliseconds,
            LEASE_MILLISECONDS,
          );
          if (result.kind === "claimed") {
            state = result.state;
          }
          return result;
        },
        compute: async () => ({
          payload: hooks.compute ?
            await hooks.compute() :
            canonicalCount,
          batches: hooks.batches ?? ["devices"],
        }),
        preflight: async (lease: BadgeSyncLease) => {
          const result = preflightBadgeSyncState(
            state,
            lease,
            nowMilliseconds,
            LEASE_MILLISECONDS,
          );
          if (result.kind !== "lost") {
            state = result.state;
          }
          return result;
        },
        publishBatch: async (count, batch) => {
          if (hooks.publish) {
            await hooks.publish(count, batch);
          } else {
            publishedCounts.push(count);
          }
        },
        complete: async (lease: BadgeSyncLease) => {
          const result = completeBadgeSyncState(
            state,
            lease,
            nowMilliseconds,
            LEASE_MILLISECONDS,
          );
          if (result.kind !== "lost") {
            state = result.state;
          }
          return result;
        },
        release: async (lease: BadgeSyncLease) => {
          state = releaseBadgeSyncState(state, lease);
        },
      }, hooks.maximumPasses ?? 8);
    },
    advance(milliseconds: number) {
      nowMilliseconds += milliseconds;
    },
  };
}

function initialState(desiredGeneration = 0): BadgeSyncState {
  return {
    desiredGeneration,
    processedGeneration: 0,
    leaseFence: 0,
  };
}

function deferred<Value>() {
  let resolve!: (value: Value | PromiseLike<Value>) => void;
  const promise = new Promise<Value>((promiseResolve) => {
    resolve = promiseResolve;
  });
  return {promise, resolve};
}
