export type BadgeSyncState = {
  desiredGeneration: number;
  processedGeneration: number;
  leaseFence: number;
  leaseOwner?: string;
  leaseExpiresAtMilliseconds?: number;
};

export type BadgeSyncLease = {
  ownerId: string;
  fence: number;
  generation: number;
};

export type BadgeSyncClaimResult =
  | {kind: "no-work"}
  | {kind: "busy"}
  | {kind: "claimed"; lease: BadgeSyncLease; state: BadgeSyncState};

export type BadgeSyncPreflightResult =
  | {kind: "lost"}
  | {kind: "ready"; lease: BadgeSyncLease; state: BadgeSyncState}
  | {kind: "superseded"; lease: BadgeSyncLease; state: BadgeSyncState};

export type BadgeSyncCompletionResult =
  | {kind: "lost"}
  | {kind: "done"; state: BadgeSyncState}
  | {kind: "next"; lease: BadgeSyncLease; state: BadgeSyncState};

export class BadgeSyncBusyError extends Error {
  constructor() {
    super("Unread badge synchronization is already leased.");
    this.name = "BadgeSyncBusyError";
  }
}

export class BadgeSyncLeaseLostError extends Error {
  constructor() {
    super("Unread badge synchronization lease was lost.");
    this.name = "BadgeSyncLeaseLostError";
  }
}

export class BadgeSyncDrainLimitError extends Error {
  constructor() {
    super("Unread badge synchronization exceeded its bounded drain limit.");
    this.name = "BadgeSyncDrainLimitError";
  }
}

function leaseIsCurrent(
  state: BadgeSyncState,
  lease: BadgeSyncLease,
  nowMilliseconds: number,
): boolean {
  return state.leaseOwner === lease.ownerId &&
    state.leaseFence === lease.fence &&
    state.leaseExpiresAtMilliseconds !== undefined &&
    state.leaseExpiresAtMilliseconds > nowMilliseconds;
}

function renewLease(
  state: BadgeSyncState,
  lease: BadgeSyncLease,
  nowMilliseconds: number,
  leaseMilliseconds: number,
): BadgeSyncState {
  return {
    ...state,
    leaseOwner: lease.ownerId,
    leaseFence: lease.fence,
    leaseExpiresAtMilliseconds: nowMilliseconds + leaseMilliseconds,
  };
}

export function observeBadgeSyncState(
  state: BadgeSyncState,
): BadgeSyncState {
  const desiredGeneration = state.desiredGeneration + 1;
  if (!Number.isSafeInteger(desiredGeneration)) {
    throw new RangeError("Unread badge generation exhausted.");
  }
  return {...state, desiredGeneration};
}

export function claimBadgeSyncState(
  state: BadgeSyncState,
  ownerId: string,
  nowMilliseconds: number,
  leaseMilliseconds: number,
): BadgeSyncClaimResult {
  if (state.desiredGeneration <= state.processedGeneration) {
    return {kind: "no-work"};
  }
  if (
    state.leaseOwner !== undefined &&
    state.leaseExpiresAtMilliseconds !== undefined &&
    state.leaseExpiresAtMilliseconds > nowMilliseconds
  ) {
    return {kind: "busy"};
  }

  const fence = state.leaseFence + 1;
  if (!Number.isSafeInteger(fence)) {
    throw new RangeError("Unread badge lease fence exhausted.");
  }
  const lease = {
    ownerId,
    fence,
    generation: state.desiredGeneration,
  };
  return {
    kind: "claimed",
    lease,
    state: renewLease(
      {...state, leaseFence: fence},
      lease,
      nowMilliseconds,
      leaseMilliseconds,
    ),
  };
}

export function preflightBadgeSyncState(
  state: BadgeSyncState,
  lease: BadgeSyncLease,
  nowMilliseconds: number,
  leaseMilliseconds: number,
): BadgeSyncPreflightResult {
  if (
    !leaseIsCurrent(state, lease, nowMilliseconds) ||
    state.desiredGeneration < lease.generation
  ) {
    return {kind: "lost"};
  }

  const currentLease = {
    ...lease,
    generation: state.desiredGeneration,
  };
  const renewedState = renewLease(
    state,
    currentLease,
    nowMilliseconds,
    leaseMilliseconds,
  );
  if (state.desiredGeneration > lease.generation) {
    return {kind: "superseded", lease: currentLease, state: renewedState};
  }
  return {kind: "ready", lease: currentLease, state: renewedState};
}

export function completeBadgeSyncState(
  state: BadgeSyncState,
  lease: BadgeSyncLease,
  nowMilliseconds: number,
  leaseMilliseconds: number,
): BadgeSyncCompletionResult {
  if (
    !leaseIsCurrent(state, lease, nowMilliseconds) ||
    state.desiredGeneration < lease.generation
  ) {
    return {kind: "lost"};
  }
  if (state.desiredGeneration > lease.generation) {
    const nextLease = {
      ...lease,
      generation: state.desiredGeneration,
    };
    return {
      kind: "next",
      lease: nextLease,
      state: renewLease(
        state,
        nextLease,
        nowMilliseconds,
        leaseMilliseconds,
      ),
    };
  }

  const completedState = {...state};
  completedState.processedGeneration = lease.generation;
  delete completedState.leaseOwner;
  delete completedState.leaseExpiresAtMilliseconds;
  return {kind: "done", state: completedState};
}

export function releaseBadgeSyncState(
  state: BadgeSyncState,
  lease: BadgeSyncLease,
): BadgeSyncState {
  if (
    state.leaseOwner !== lease.ownerId ||
    state.leaseFence !== lease.fence
  ) {
    return state;
  }
  const releasedState = {...state};
  delete releasedState.leaseOwner;
  delete releasedState.leaseExpiresAtMilliseconds;
  return releasedState;
}

export type BadgeSyncWork<Payload, Batch> = {
  payload: Payload;
  batches: readonly Batch[];
};

export type BadgeSyncDrainDependencies<Payload, Batch> = {
  claim: () => Promise<BadgeSyncClaimResult>;
  compute: (
    lease: BadgeSyncLease,
  ) => Promise<BadgeSyncWork<Payload, Batch>>;
  preflight: (
    lease: BadgeSyncLease,
    payload: Payload,
  ) => Promise<BadgeSyncPreflightResult>;
  publishBatch: (
    payload: Payload,
    batch: Batch,
    lease: BadgeSyncLease,
  ) => Promise<void>;
  complete: (
    lease: BadgeSyncLease,
    payload: Payload,
  ) => Promise<BadgeSyncCompletionResult>;
  release: (lease: BadgeSyncLease) => Promise<void>;
};

export async function drainBadgeSync<Payload, Batch>(
  dependencies: BadgeSyncDrainDependencies<Payload, Batch>,
  maximumPasses: number,
): Promise<"no-work" | "drained"> {
  if (!Number.isSafeInteger(maximumPasses) || maximumPasses < 1) {
    throw new RangeError("Unread badge drain limit must be positive.");
  }

  const claim = await dependencies.claim();
  if (claim.kind === "no-work") {
    return "no-work";
  }
  if (claim.kind === "busy") {
    throw new BadgeSyncBusyError();
  }

  let lease = claim.lease;
  try {
    drainPasses: for (let pass = 0; pass < maximumPasses; pass += 1) {
      const work = await dependencies.compute(lease);
      for (const batch of work.batches) {
        const preflight = await dependencies.preflight(lease, work.payload);
        if (preflight.kind === "lost") {
          throw new BadgeSyncLeaseLostError();
        }
        lease = preflight.lease;
        if (preflight.kind === "superseded") {
          continue drainPasses;
        }
        await dependencies.publishBatch(work.payload, batch, lease);
      }

      const completion = await dependencies.complete(lease, work.payload);
      if (completion.kind === "lost") {
        throw new BadgeSyncLeaseLostError();
      }
      if (completion.kind === "done") {
        return "drained";
      }
      lease = completion.lease;
    }
    throw new BadgeSyncDrainLimitError();
  } catch (error) {
    await dependencies.release(lease);
    throw error;
  }
}
