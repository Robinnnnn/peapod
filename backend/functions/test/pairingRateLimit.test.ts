import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import {describe, it} from "node:test";

import {
  PAIRING_CREATE_MAX_ATTEMPTS,
  PAIRING_CREATE_WINDOW_MILLISECONDS,
  PAIRING_RATE_LIMIT_CLEANUP_GRACE_MILLISECONDS,
  PAIRING_REDEEM_MAX_ATTEMPTS,
  PAIRING_REDEEM_WINDOW_MILLISECONDS,
  pairingRateLimitWindow,
} from "../src/pairingRateLimit.js";

const nowMilliseconds = Date.UTC(2026, 6, 25, 12, 7);

describe("pairing rate limit", () => {
  it("allocates exactly five deterministic create slots per hour", () => {
    const window = pairingRateLimitWindow("create", nowMilliseconds);

    assert.equal(window.maximumAttempts, PAIRING_CREATE_MAX_ATTEMPTS);
    assert.equal(
      window.attemptDocumentIDs.length,
      PAIRING_CREATE_MAX_ATTEMPTS,
    );
    assert.equal(
      new Set(window.attemptDocumentIDs).size,
      PAIRING_CREATE_MAX_ATTEMPTS,
    );
    assert.ok(
      window.attemptDocumentIDs.every((id) =>
        id.startsWith(`create-${window.startedAtMilliseconds}-`),
      ),
    );
    assert.equal(
      window.endsAtMilliseconds - window.startedAtMilliseconds,
      PAIRING_CREATE_WINDOW_MILLISECONDS,
    );
  });

  it("allocates exactly ten deterministic redeem slots per fifteen minutes", () => {
    const window = pairingRateLimitWindow("redeem", nowMilliseconds);

    assert.equal(window.maximumAttempts, PAIRING_REDEEM_MAX_ATTEMPTS);
    assert.equal(
      window.attemptDocumentIDs.length,
      PAIRING_REDEEM_MAX_ATTEMPTS,
    );
    assert.equal(
      window.endsAtMilliseconds - window.startedAtMilliseconds,
      PAIRING_REDEEM_WINDOW_MILLISECONDS,
    );
  });

  it("keeps callers in the same fixed window until the exact boundary", () => {
    const first = pairingRateLimitWindow("redeem", nowMilliseconds);
    const last = pairingRateLimitWindow(
      "redeem",
      first.endsAtMilliseconds - 1,
    );
    const next = pairingRateLimitWindow(
      "redeem",
      first.endsAtMilliseconds,
    );

    assert.deepEqual(last.attemptDocumentIDs, first.attemptDocumentIDs);
    assert.notDeepEqual(next.attemptDocumentIDs, first.attemptDocumentIDs);
    assert.equal(next.startedAtMilliseconds, first.endsAtMilliseconds);
  });

  it("retains attempt slots beyond the full rate window", () => {
    const window = pairingRateLimitWindow("create", nowMilliseconds);

    assert.equal(
      window.expiresAtMilliseconds,
      window.endsAtMilliseconds +
        PAIRING_RATE_LIMIT_CLEANUP_GRACE_MILLISECONDS,
    );
  });

  it("rejects a non-finite clock value", () => {
    assert.throws(
      () => pairingRateLimitWindow("create", Number.NaN),
      /must be finite/,
    );
  });

  it("checks in managed TTL fields for ephemeral records", () => {
    const configuration = JSON.parse(
      readFileSync("../firestore.indexes.json", "utf8"),
    ) as {
      fieldOverrides?: Array<{
        collectionGroup?: string;
        fieldPath?: string;
        ttl?: boolean;
      }>;
    };
    const ttlCollections = new Set(
      (configuration.fieldOverrides ?? [])
        .filter((override) =>
          override.fieldPath === "expiresAt" && override.ttl === true,
        )
        .map((override) => override.collectionGroup),
    );

    assert.equal(ttlCollections.has("pairingCodes"), true);
    assert.equal(ttlCollections.has("pairingAttempts"), true);
    assert.equal(ttlCollections.has("locations"), true);
  });
});
