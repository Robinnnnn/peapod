import assert from "node:assert/strict";
import {describe, it} from "node:test";

import {
  badgeSyncAssignmentsMatch,
  badgeSyncCollapseId,
  badgeSyncMulticast,
  deriveBadgeSyncConversationAssignment,
  deriveUnreadIncomingCount,
  shouldSynchronizeBadge,
} from "../src/unreadBadgePolicy.js";

describe("unread badge policy", () => {
  it("matches descending endBefore semantics at an equal timestamp", () => {
    const messages = [
      message("message-a", "partner", 10),
      message("message-b", "partner", 20),
      message("message-c", "current-user", 30),
      message("message-d", "partner", 30),
      message("message-e", "partner", 30),
    ];

    assert.equal(
      deriveUnreadIncomingCount(
        messages,
        "current-user",
        position("message-d", 30),
      ),
      1,
    );
  });

  it("counts every incoming message when there is no read position", () => {
    assert.equal(
      deriveUnreadIncomingCount(
        [
          message("incoming-one", "partner", 10),
          message("outgoing", "current-user", 20),
          message("incoming-two", "partner", 30),
        ],
        "current-user",
      ),
      2,
    );
    assert.equal(
      deriveUnreadIncomingCount(
        [message("outgoing", "current-user", 20)],
        "current-user",
      ),
      0,
    );
  });

  it("retries carry the same absolute count instead of an increment", () => {
    const firstAttempt = badgeSyncMulticast({
      tokens: ["iphone"],
      conversationId: "conversation",
      recipientId: "current-user",
      unreadCount: 2,
    });
    const retry = badgeSyncMulticast({
      tokens: ["iphone"],
      conversationId: "conversation",
      recipientId: "current-user",
      unreadCount: 2,
    });
    const readUpdate = badgeSyncMulticast({
      tokens: ["iphone-one", "iphone-two"],
      conversationId: "conversation",
      recipientId: "current-user",
      unreadCount: 1,
    });

    assert.equal(firstAttempt.apns?.payload?.aps.badge, 2);
    assert.equal(retry.apns?.payload?.aps.badge, 2);
    assert.equal(readUpdate.apns?.payload?.aps.badge, 1);
    assert.equal(readUpdate.data?.badgeCount, "1");
  });

  it("sends zero-count read synchronization to every iPhone token", () => {
    const payload = badgeSyncMulticast({
      tokens: ["iphone-one", "iphone-two"],
      conversationId: "conversation",
      recipientId: "current-user",
      unreadCount: 0,
    });

    assert.deepEqual(payload.tokens, ["iphone-one", "iphone-two"]);
    assert.equal(payload.apns?.payload?.aps.badge, 0);
    assert.equal(payload.apns?.payload?.aps.contentAvailable, undefined);
    assert.equal(payload.apns?.headers?.["apns-push-type"], "alert");
    assert.equal(payload.apns?.headers?.["apns-priority"], "5");
  });

  it("synchronizes only canonical read changes and read-state deletion", () => {
    assert.equal(
      shouldSynchronizeBadge("message-one", "message-one", true),
      false,
    );
    assert.equal(
      shouldSynchronizeBadge("message-one", "message-two", true),
      true,
    );
    assert.equal(
      shouldSynchronizeBadge("message-two", undefined, false),
      true,
    );
  });

  it("uses a stable recipient-scoped collapse identifier", () => {
    const first = badgeSyncCollapseId("current-user");
    const repeated = badgeSyncCollapseId("current-user");
    const otherUser = badgeSyncCollapseId("partner");

    assert.equal(first, repeated);
    assert.notEqual(first, otherUser);
    assert.ok(first.length <= 64);
  });

  it("collapses badge updates across conversation lifecycles", () => {
    const oldConversation = badgeSyncMulticast({
      tokens: ["iphone"],
      conversationId: "old-conversation",
      recipientId: "current-user",
      unreadCount: 0,
    });
    const newConversation = badgeSyncMulticast({
      tokens: ["iphone"],
      conversationId: "new-conversation",
      recipientId: "current-user",
      unreadCount: 3,
    });

    assert.equal(
      oldConversation.apns?.headers?.["apns-collapse-id"],
      newConversation.apns?.headers?.["apns-collapse-id"],
    );
  });

  it("derives badge ownership from the recipient's active conversation", () => {
    const assignment = deriveBadgeSyncConversationAssignment(
      "current-user",
      "new-conversation",
      {
        exists: true,
        status: "active",
        members: ["current-user", "new-partner"],
      },
    );

    assert.deepEqual(assignment, {
      conversationId: "new-conversation",
      incomingSenderId: "new-partner",
      terminal: false,
    });
    assert.equal(
      badgeSyncAssignmentsMatch(assignment, {
        conversationId: "old-conversation",
        terminal: true,
      }),
      false,
    );
  });
});

function message(
  messageId: string,
  senderId: string,
  seconds: number,
  nanoseconds = 0,
) {
  return {messageId, senderId, seconds, nanoseconds};
}

function position(
  messageId: string,
  seconds: number,
  nanoseconds = 0,
) {
  return {messageId, seconds, nanoseconds};
}
