import {createHash} from "node:crypto";

export const MAX_NOTIFICATION_DELIVERY_ATTEMPTS = 5;
export const NOTIFICATION_LEASE_MILLISECONDS = 2 * 60 * 1000;
export const MAX_NOTIFICATION_PREVIEW_BYTES = 2048;
// APNs permits 4096 bytes. Reserve space for FCM's generated identifiers and
// wire-key translation in addition to the entire modeled Apple payload below.
export const MAX_MODELED_APNS_PAYLOAD_BYTES = 4096 - 512;

const INVALID_TOKEN_CODES = new Set([
  "messaging/invalid-registration-token",
  "messaging/registration-token-not-registered",
]);

const TRANSIENT_CODES = new Set([
  "messaging/device-message-rate-exceeded",
  "messaging/internal-error",
  "messaging/message-rate-exceeded",
  "messaging/network-error",
  "messaging/quota-exceeded",
  "messaging/server-unavailable",
  "messaging/topics-message-rate-exceeded",
  "messaging/unavailable",
  "messaging/unknown-error",
]);

export type DeliveryDisposition =
  | "delivered"
  | "invalid-token"
  | "transient"
  | "permanent";

export type MessageAlertMetadata = {
  type?: unknown;
  attachmentGroupId?: unknown;
  attachmentGroupIndex?: unknown;
  attachmentGroupCount?: unknown;
};

export function shouldSendMessageAlert(
  delivery: unknown,
  message: MessageAlertMetadata = {},
): boolean {
  // Missing and future/invalid delivery values retain normal semantics;
  // only the exact supported quiet value opts out before the group policy.
  if (delivery === "quiet") return false;
  // Legacy photo groups have public, rules-validated metadata. Only their
  // anchor alerts; its existing message-scoped lease/outcomes handle retries.
  // Encrypted clients derive quiet delivery privately before publishing.
  const index = message.attachmentGroupIndex;
  const count = message.attachmentGroupCount;
  const groupedPhoto = message.type === "image" &&
    typeof message.attachmentGroupId === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
      .test(message.attachmentGroupId) &&
    typeof index === "number" && Number.isInteger(index) &&
    typeof count === "number" && Number.isInteger(count) &&
    count >= 2 && count <= 10 && index >= 0 && index < count;
  return !groupedPhoto || index === 0;
}

export function classifyMessagingResult(
  success: boolean,
  errorCode?: string,
): DeliveryDisposition {
  if (success) {
    return "delivered";
  }
  if (!errorCode || TRANSIENT_CODES.has(errorCode)) {
    return "transient";
  }
  if (INVALID_TOKEN_CODES.has(errorCode)) {
    return "invalid-token";
  }
  return "permanent";
}

export function messagingErrorCode(error: unknown): string | undefined {
  if (
    typeof error === "object" &&
    error !== null &&
    "code" in error &&
    typeof error.code === "string"
  ) {
    return error.code;
  }
  return undefined;
}

export function hashDeliveryToken(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}

export function selectPendingTokens(
  tokens: readonly string[],
  deliveredTokenHashes: readonly string[],
  terminalTokenHashes: readonly string[],
): string[] {
  const terminal = new Set([
    ...deliveredTokenHashes,
    ...terminalTokenHashes,
  ]);
  const seen = new Set<string>();

  return tokens.filter((token) => {
    const hash = hashDeliveryToken(token);
    if (seen.has(hash) || terminal.has(hash)) {
      return false;
    }
    seen.add(hash);
    return true;
  });
}

export function canRetryDelivery(attemptCount: number): boolean {
  return attemptCount < MAX_NOTIFICATION_DELIVERY_ATTEMPTS;
}

export function notificationCollapseId(
  conversationId: string,
  messageId: string,
): string {
  const digest = createHash("sha256")
    .update(`${conversationId}/${messageId}`)
    .digest("hex");
  return `mines-${digest.slice(0, 48)}`;
}

/** The conversation marker wins even if a malformed record contains plaintext. */
export function messageNotificationPreview(
  conversationEncryption: unknown,
  message: {type?: unknown; text?: unknown; encryption?: unknown},
): string {
  if (conversationEncryption != null || message.encryption != null || message.type === "encrypted") {
    return "New message";
  }
  if (message.type === "text" || message.type === "link") {
    return typeof message.text === "string" ? message.text.slice(0, 180) : "New message";
  }
  return typeof message.type === "string" ? `Sent ${message.type}` : "New message";
}

type NotificationMessage = {
  senderId: string;
  type: string;
  text?: unknown;
  encryption?: unknown;
  keyEpoch?: unknown;
  revision?: unknown;
  notificationPreview?: unknown;
  ciphertext?: unknown;
  deletedAt?: unknown;
};

/** Sidecars cannot substitute a different sender, epoch, suite or revision. */
export function notificationPreviewForMessage(
  message: NotificationMessage,
  sidecar: Record<string, unknown> | undefined,
): unknown {
  if (
    !sidecar || message.type !== "encrypted" || message.encryption !== "mines-e2ee-v1" ||
    sidecar.senderId !== message.senderId || sidecar.encryption !== message.encryption ||
    sidecar.keyEpoch !== message.keyEpoch || sidecar.revision !== message.revision ||
    sidecar.revision !== 1
  ) return undefined;
  return sidecar.ciphertext;
}

/** A delayed create event must not reveal content that was edited or unsent. */
export function messageAlertCurrentState(
  original: NotificationMessage,
  current: NotificationMessage | undefined,
  sidecar: Record<string, unknown> | undefined,
): {shouldAlert: boolean; notificationPreview?: unknown} {
  if (!current || current.deletedAt != null) return {shouldAlert: false};
  const originalBytes = original.ciphertext;
  const currentBytes = current.ciphertext;
  const stillOriginal = original.type === "encrypted" &&
    original.encryption === "mines-e2ee-v1" && original.revision === 1 &&
    current.type === original.type && current.encryption === original.encryption &&
    current.senderId === original.senderId && current.keyEpoch === original.keyEpoch &&
    current.revision === original.revision &&
    originalBytes instanceof Uint8Array && originalBytes.byteLength > 0 &&
    currentBytes instanceof Uint8Array &&
    Buffer.from(originalBytes).equals(Buffer.from(currentBytes));
  return {
    shouldAlert: true,
    notificationPreview: stillOriginal ? notificationPreviewForMessage(original, sidecar) : undefined,
  };
}

/** Whitelist public routing and an optional opaque, client-authenticated preview. */
export function messageNotificationPayload(
  conversationEncryption: unknown,
  message: NotificationMessage,
  conversationId: string,
  messageId: string,
  senderName: string,
) {
  const notification = {
    title: senderName,
    body: messageNotificationPreview(conversationEncryption, message) || "New message",
  };
  const data: Record<string, string> = {
    conversationId,
    messageId,
    senderId: message.senderId,
    senderName,
    type: conversationEncryption != null ? "encrypted" : message.type,
  };
  const aps = {
    sound: "default",
    category: "MESSAGE",
    threadId: conversationId,
    mutableContent: true,
    "interruption-level": "time-sensitive",
  };
  const bytes = message.notificationPreview;
  if (
    conversationEncryption === "mines-e2ee-v1" &&
    message.type === "encrypted" && message.encryption === "mines-e2ee-v1" &&
    typeof message.keyEpoch === "number" && Number.isSafeInteger(message.keyEpoch) &&
    message.keyEpoch > 0 && message.revision === 1 && message.deletedAt == null &&
    bytes instanceof Uint8Array && bytes.byteLength > 0 &&
    bytes.byteLength <= MAX_NOTIFICATION_PREVIEW_BYTES
  ) {
    const candidate = {
      ...data,
      notificationPreview: Buffer.from(bytes).toString("base64"),
      keyEpoch: String(message.keyEpoch),
      revision: "1",
    };
    // Model the flattened APNs data and its final wire names, not just FCM's
    // data dictionary. No content fields from the message are spread here.
    const applePayload = {
      ...candidate,
      aps: {
        alert: notification,
        sound: aps.sound,
        category: aps.category,
        "thread-id": conversationId,
        "mutable-content": 1,
        "interruption-level": aps["interruption-level"],
      },
    };
    if (Buffer.byteLength(JSON.stringify(applePayload), "utf8") <= MAX_MODELED_APNS_PAYLOAD_BYTES) {
      Object.assign(data, candidate);
    }
  }
  return {notification, data, apns: {payload: {aps}}};
}
