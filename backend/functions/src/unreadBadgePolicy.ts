import {createHash} from "node:crypto";

import type {MulticastMessage} from "firebase-admin/messaging";

export type BadgeMessagePosition = {
  messageId: string;
  seconds: number;
  nanoseconds: number;
};

export type BadgeMessage = BadgeMessagePosition & {
  senderId: string;
};

export type BadgeSyncConversationAssignment = {
  conversationId?: string;
  incomingSenderId?: string;
  terminal: boolean;
};

export function deriveBadgeSyncConversationAssignment(
  recipientId: string,
  activeConversationId: string | undefined,
  conversation: {
    exists: boolean;
    status?: unknown;
    members?: unknown;
  } | undefined,
): BadgeSyncConversationAssignment {
  if (!activeConversationId) {
    return {terminal: true};
  }
  const members = Array.isArray(conversation?.members) ?
    conversation.members.filter(
      (member): member is string => typeof member === "string",
    ) :
    [];
  const incomingSenderIds = members.filter(
    (memberId) => memberId !== recipientId,
  );
  if (
    conversation?.exists &&
    conversation.status === "active" &&
    members.length === 2 &&
    members.includes(recipientId) &&
    incomingSenderIds.length === 1
  ) {
    return {
      conversationId: activeConversationId,
      incomingSenderId: incomingSenderIds[0],
      terminal: false,
    };
  }
  return {conversationId: activeConversationId, terminal: true};
}

export function badgeSyncAssignmentsMatch(
  lhs: BadgeSyncConversationAssignment,
  rhs: BadgeSyncConversationAssignment,
): boolean {
  return lhs.conversationId === rhs.conversationId &&
    lhs.incomingSenderId === rhs.incomingSenderId &&
    lhs.terminal === rhs.terminal;
}

function comparePositions(
  lhs: BadgeMessagePosition,
  rhs: BadgeMessagePosition,
): number {
  if (lhs.seconds !== rhs.seconds) {
    return lhs.seconds - rhs.seconds;
  }
  if (lhs.nanoseconds !== rhs.nanoseconds) {
    return lhs.nanoseconds - rhs.nanoseconds;
  }
  return lhs.messageId.localeCompare(rhs.messageId);
}

/**
 * Pure mirror of the Firestore unread query. Keeping the position policy here
 * makes equal-timestamp behavior and sender filtering independently testable.
 */
export function deriveUnreadIncomingCount(
  messages: readonly BadgeMessage[],
  recipientId: string,
  lastReadPosition?: BadgeMessagePosition,
): number {
  return messages.filter((message) =>
    message.senderId !== recipientId &&
    (
      lastReadPosition === undefined ||
      comparePositions(message, lastReadPosition) > 0
    )
  ).length;
}

export function absoluteBadgeCount(value: number): number {
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new RangeError("Badge counts must be non-negative safe integers.");
  }
  return value;
}

export function shouldSynchronizeBadge(
  previousReadMessageId: unknown,
  currentReadMessageId: unknown,
  readStateExists: boolean,
): boolean {
  return !readStateExists || previousReadMessageId !== currentReadMessageId;
}

export function badgeSyncCollapseId(
  recipientId: string,
): string {
  const digest = createHash("sha256")
    .update(recipientId)
    .digest("hex");
  return `mines-badge-${digest.slice(0, 48)}`;
}

export function badgeSyncMulticast(
  input: {
    tokens: string[];
    conversationId?: string;
    recipientId: string;
    unreadCount: number;
  },
): MulticastMessage {
  const unreadCount = absoluteBadgeCount(input.unreadCount);
  return {
    tokens: input.tokens,
    data: {
      type: "badge-sync",
      ...(input.conversationId ?
        {conversationId: input.conversationId} :
        {}),
      badgeCount: String(unreadCount),
    },
    apns: {
      headers: {
        "apns-collapse-id": badgeSyncCollapseId(input.recipientId),
        "apns-push-type": "alert",
        "apns-priority": "5",
      },
      payload: {
        aps: {
          badge: unreadCount,
        },
      },
    },
  };
}
