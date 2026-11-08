import assert from "node:assert/strict";
import {describe, it} from "node:test";
import {HttpsError} from "firebase-functions/v2/https";

import {
  closeConversation,
  deleteConversation,
  deleteConversationData,
} from "../src/conversationRetention.js";

describe("retired conversation removal endpoints", () => {
  for (const [name, endpoint] of Object.entries({closeConversation, deleteConversation})) {
    it(`${name} still requires authentication`, async () => {
      await assert.rejects(endpoint.run({auth: undefined} as Parameters<typeof endpoint.run>[0]),
        (error: unknown) => error instanceof HttpsError && error.code === "unauthenticated");
    });

    it(`${name} rejects a signed-in legacy client without inspecting its payload`, async () => {
      // A removed endpoint needs neither account state nor a valid DELETE body.
      // Accessing data would fail this test before the expected refusal.
      const request = {
        auth: {uid: "synthetic-retention-account"},
        get data(): never { throw new Error("Payload must not be inspected"); },
      } as Parameters<typeof endpoint.run>[0];
      await assert.rejects(endpoint.run(request),
        (error: unknown) => error instanceof HttpsError && error.code === "failed-precondition");
    });
  }

  it("retains an already queued purge without reading its document or target", async () => {
    const event = new Proxy({}, {
      get() { throw new Error("Retired purge must not inspect or delete queued data"); },
    }) as Parameters<typeof deleteConversationData.run>[0];
    await deleteConversationData.run(event);
  });
});
