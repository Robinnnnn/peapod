export const ORPHAN_ATTACHMENT_MIN_AGE_MILLISECONDS =
  7 * 24 * 60 * 60 * 1000;

export type OrphanAttachmentCleanupResult =
  | "deleted"
  | "retained"
  | "skipped-invalid"
  | "skipped-too-new";

export type OrphanAttachmentCandidate = {
  createdAtMilliseconds: number;
  messageId: string;
  storagePath: string;
  expectedStoragePrefix: string;
};

export type OrphanAttachmentCleanupOperations = {
  messageExists: (messageId: string) => Promise<boolean>;
  deleteBlob: (storagePath: string) => Promise<void>;
  deleteMetadata: () => Promise<void>;
};

export function messageDocumentIsLive(
  data: Record<string, unknown> | undefined,
): boolean {
  return data != null && data.deletedAt == null;
}

/**
 * Deletes one safely aged attachment only when its referenced message is absent.
 *
 * Blob deletion intentionally precedes metadata deletion. Storage rules depend
 * on the metadata document, and retaining metadata after a blob failure keeps
 * the record discoverable for the next scheduled retry.
 */
export async function cleanupOrphanAttachment(
  candidate: OrphanAttachmentCandidate,
  operations: OrphanAttachmentCleanupOperations,
  nowMilliseconds: number = Date.now(),
  minimumAgeMilliseconds: number =
    ORPHAN_ATTACHMENT_MIN_AGE_MILLISECONDS,
): Promise<OrphanAttachmentCleanupResult> {
  if (
    !Number.isFinite(candidate.createdAtMilliseconds) ||
    !Number.isFinite(nowMilliseconds) ||
    !Number.isFinite(minimumAgeMilliseconds) ||
    minimumAgeMilliseconds < 0
  ) {
    return "skipped-invalid";
  }

  if (
    nowMilliseconds - candidate.createdAtMilliseconds <
    minimumAgeMilliseconds
  ) {
    return "skipped-too-new";
  }

  const messageId = candidate.messageId.trim();
  const storagePath = candidate.storagePath.trim();
  if (
    !isValidDocumentId(messageId) ||
    candidate.expectedStoragePrefix.length === 0 ||
    !storagePath.startsWith(candidate.expectedStoragePrefix) ||
    storagePath.length <= candidate.expectedStoragePrefix.length
  ) {
    return "skipped-invalid";
  }

  if (await operations.messageExists(messageId)) {
    return "retained";
  }

  await operations.deleteBlob(storagePath);
  await operations.deleteMetadata();
  return "deleted";
}

function isValidDocumentId(value: string): boolean {
  return (
    value.length > 0 &&
    value.length <= 1_500 &&
    !value.includes("/")
  );
}
