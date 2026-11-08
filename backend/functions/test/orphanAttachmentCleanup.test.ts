import assert from "node:assert/strict";
import {describe, it} from "node:test";

import {
  ORPHAN_ATTACHMENT_MIN_AGE_MILLISECONDS,
  OrphanAttachmentCandidate,
  cleanupOrphanAttachment,
  messageDocumentIsLive,
} from "../src/orphanAttachmentCleanup.js";

const nowMilliseconds = Date.UTC(2026, 6, 25, 12);
const expectedStoragePrefix =
  "conversations/conversation-one/attachments/attachment-one/";

function candidate(
  overrides: Partial<OrphanAttachmentCandidate> = {},
): OrphanAttachmentCandidate {
  return {
    createdAtMilliseconds:
      nowMilliseconds - ORPHAN_ATTACHMENT_MIN_AGE_MILLISECONDS,
    messageId: "message-one",
    storagePath: `${expectedStoragePrefix}voice.m4a`,
    expectedStoragePrefix,
    ...overrides,
  };
}

describe("orphan attachment cleanup", () => {
  it("treats unsent message tombstones as absent", () => {
    assert.equal(messageDocumentIsLive(undefined), false);
    assert.equal(messageDocumentIsLive({text: "hello"}), true);
    assert.equal(messageDocumentIsLive({deletedAt: null}), true);
    assert.equal(
      messageDocumentIsLive({deletedAt: {seconds: 1}}),
      false,
    );
  });

  it("deletes an old orphan blob before deleting its metadata", async () => {
    const calls: string[] = [];

    const result = await cleanupOrphanAttachment(
      candidate(),
      {
        messageExists: async (messageId) => {
          calls.push(`message:${messageId}`);
          return false;
        },
        deleteBlob: async (storagePath) => {
          calls.push(`blob:${storagePath}`);
        },
        deleteMetadata: async () => {
          calls.push("metadata");
        },
      },
      nowMilliseconds,
    );

    assert.equal(result, "deleted");
    assert.deepEqual(calls, [
      "message:message-one",
      `blob:${expectedStoragePrefix}voice.m4a`,
      "metadata",
    ]);
  });

  it("retains an attachment whose referenced message exists", async () => {
    let blobDeleteCount = 0;
    let metadataDeleteCount = 0;

    const result = await cleanupOrphanAttachment(
      candidate(),
      {
        messageExists: async () => true,
        deleteBlob: async () => {
          blobDeleteCount += 1;
        },
        deleteMetadata: async () => {
          metadataDeleteCount += 1;
        },
      },
      nowMilliseconds,
    );

    assert.equal(result, "retained");
    assert.equal(blobDeleteCount, 0);
    assert.equal(metadataDeleteCount, 0);
  });

  it("does not inspect or delete an attachment inside the safety window", async () => {
    let operationCount = 0;

    const result = await cleanupOrphanAttachment(
      candidate({
        createdAtMilliseconds:
          nowMilliseconds - ORPHAN_ATTACHMENT_MIN_AGE_MILLISECONDS + 1,
      }),
      {
        messageExists: async () => {
          operationCount += 1;
          return false;
        },
        deleteBlob: async () => {
          operationCount += 1;
        },
        deleteMetadata: async () => {
          operationCount += 1;
        },
      },
      nowMilliseconds,
    );

    assert.equal(result, "skipped-too-new");
    assert.equal(operationCount, 0);
  });

  it("rejects a storage path outside the attachment directory", async () => {
    let operationCount = 0;

    const result = await cleanupOrphanAttachment(
      candidate({
        storagePath: "conversations/other/attachments/other/private.m4a",
      }),
      {
        messageExists: async () => {
          operationCount += 1;
          return false;
        },
        deleteBlob: async () => {
          operationCount += 1;
        },
        deleteMetadata: async () => {
          operationCount += 1;
        },
      },
      nowMilliseconds,
    );

    assert.equal(result, "skipped-invalid");
    assert.equal(operationCount, 0);
  });

  it("retains metadata when blob deletion fails so a retry can find it", async () => {
    const calls: string[] = [];
    const failure = new Error("storage unavailable");

    await assert.rejects(
      cleanupOrphanAttachment(
        candidate(),
        {
          messageExists: async () => false,
          deleteBlob: async () => {
            calls.push("blob");
            throw failure;
          },
          deleteMetadata: async () => {
            calls.push("metadata");
          },
        },
        nowMilliseconds,
      ),
      failure,
    );

    assert.deepEqual(calls, ["blob"]);
  });
});
