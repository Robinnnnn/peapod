export const PAIRING_CREATE_MAX_ATTEMPTS = 5;
export const PAIRING_CREATE_WINDOW_MILLISECONDS = 60 * 60 * 1000;
export const PAIRING_REDEEM_MAX_ATTEMPTS = 10;
export const PAIRING_REDEEM_WINDOW_MILLISECONDS = 15 * 60 * 1000;

// Managed TTL may delete after expiresAt rather than exactly at it. Keeping
// attempt slots for one extra hour guarantees they outlive their rate window.
export const PAIRING_RATE_LIMIT_CLEANUP_GRACE_MILLISECONDS =
  60 * 60 * 1000;

export type PairingRateLimitOperation = "create" | "redeem";

export type PairingRateLimitWindow = {
  operation: PairingRateLimitOperation;
  maximumAttempts: number;
  startedAtMilliseconds: number;
  endsAtMilliseconds: number;
  expiresAtMilliseconds: number;
  attemptDocumentIDs: string[];
};

type RateLimitConfiguration = {
  maximumAttempts: number;
  windowMilliseconds: number;
};

function configuration(
  operation: PairingRateLimitOperation,
): RateLimitConfiguration {
  if (operation === "create") {
    return {
      maximumAttempts: PAIRING_CREATE_MAX_ATTEMPTS,
      windowMilliseconds: PAIRING_CREATE_WINDOW_MILLISECONDS,
    };
  }
  return {
    maximumAttempts: PAIRING_REDEEM_MAX_ATTEMPTS,
    windowMilliseconds: PAIRING_REDEEM_WINDOW_MILLISECONDS,
  };
}

/**
 * Produces deterministic, per-user attempt slots for one fixed rate window.
 *
 * Each admitted callable transaction creates exactly one slot document. Since
 * two transactions cannot create the same Firestore document, concurrent
 * requests cannot exceed the number of slots even if they race.
 */
export function pairingRateLimitWindow(
  operation: PairingRateLimitOperation,
  nowMilliseconds: number,
): PairingRateLimitWindow {
  if (!Number.isFinite(nowMilliseconds)) {
    throw new TypeError("nowMilliseconds must be finite.");
  }

  const {maximumAttempts, windowMilliseconds} = configuration(operation);
  const startedAtMilliseconds =
    Math.floor(nowMilliseconds / windowMilliseconds) * windowMilliseconds;
  const endsAtMilliseconds = startedAtMilliseconds + windowMilliseconds;
  const prefix = `${operation}-${startedAtMilliseconds}`;

  return {
    operation,
    maximumAttempts,
    startedAtMilliseconds,
    endsAtMilliseconds,
    expiresAtMilliseconds:
      endsAtMilliseconds + PAIRING_RATE_LIMIT_CLEANUP_GRACE_MILLISECONDS,
    attemptDocumentIDs: Array.from(
      {length: maximumAttempts},
      (_, slot) => `${prefix}-${slot}`,
    ),
  };
}
