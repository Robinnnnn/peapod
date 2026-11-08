import assert from "node:assert/strict";
import {describe, it} from "node:test";
import {deriveUnreadIncomingCount} from "../src/unreadBadgePolicy.js";

import {
  MAX_NOTIFICATION_DELIVERY_ATTEMPTS,
  canRetryDelivery,
  classifyMessagingResult,
  hashDeliveryToken,
  messagingErrorCode,
  notificationCollapseId,
  selectPendingTokens,
  shouldSendMessageAlert,
  messageNotificationPreview,
  messageNotificationPayload,
  MAX_NOTIFICATION_PREVIEW_BYTES,
  MAX_MODELED_APNS_PAYLOAD_BYTES,
  notificationPreviewForMessage,
  messageAlertCurrentState,
} from "../src/notificationDeliveryPolicy.js";

describe("notification delivery policy", () => {
  it("suppresses only the exact quiet delivery value", () => {
    assert.equal(shouldSendMessageAlert("quiet"), false);
    assert.equal(shouldSendMessageAlert(undefined), true);
    assert.equal(shouldSendMessageAlert("normal"), true);
    assert.equal(shouldSendMessageAlert("future-mode"), true);
    assert.equal(shouldSendMessageAlert({mode: "quiet"}), true);
  });

  it("alerts only for the anchor of a photo send, regardless of event order", () => {
    const group = [0, 1, 2].map((index) => ({
      type: "image",
      attachmentGroupId: "11111111-1111-4111-8111-111111111111",
      attachmentGroupIndex: index,
      attachmentGroupCount: 3,
      senderId: "sender",
      messageId: `photo-${index}`,
      seconds: 10 + index,
      nanoseconds: 0,
    }));
    for (const messages of [group, [...group].reverse()]) {
      assert.deepEqual(
        messages.filter((message) => shouldSendMessageAlert(undefined, message))
          .map((message) => message.messageId),
        ["photo-0"],
      );
      assert.equal(deriveUnreadIncomingCount(messages, "recipient"), 3);
      assert.equal(deriveUnreadIncomingCount(messages, "recipient", group[1]), 1);
      assert.ok(messages.every((message) => !shouldSendMessageAlert("quiet", message)));
    }
  });

  it("preserves alerts for separate photos, non-photos and malformed grouping", () => {
    const grouped = {
      type: "image",
      attachmentGroupId: "11111111-1111-4111-8111-111111111111",
      attachmentGroupIndex: 1,
      attachmentGroupCount: 3,
    };
    for (const message of [
      {type: "image"}, {type: "image"},
      ...["text", "link", "video", "file", "audio", "location", "encrypted"]
        .map((type) => ({...grouped, type})),
      {...grouped, attachmentGroupId: undefined},
      {...grouped, attachmentGroupId: ""},
      {...grouped, attachmentGroupId: "invalid-group"},
      {...grouped, attachmentGroupIndex: -1},
      {...grouped, attachmentGroupIndex: 3},
      {...grouped, attachmentGroupIndex: "1"},
      {...grouped, attachmentGroupIndex: 0.5},
      {...grouped, attachmentGroupIndex: NaN},
      {...grouped, attachmentGroupCount: 1},
      {...grouped, attachmentGroupCount: 11},
      {...grouped, attachmentGroupCount: "3"},
    ]) {
      assert.equal(shouldSendMessageAlert(undefined, message), true);
    }
  });

  it("classifies delivery outcomes", () => {
    assert.equal(classifyMessagingResult(true), "delivered");
    assert.equal(
      classifyMessagingResult(
        false,
        "messaging/registration-token-not-registered",
      ),
      "invalid-token",
    );
    assert.equal(
      classifyMessagingResult(false, "messaging/server-unavailable"),
      "transient",
    );
    assert.equal(
      classifyMessagingResult(false, "messaging/message-rate-exceeded"),
      "transient",
    );
    assert.equal(classifyMessagingResult(false), "transient");
    assert.equal(
      classifyMessagingResult(false, "messaging/invalid-argument"),
      "permanent",
    );
  });

  it("extracts messaging error codes without trusting arbitrary errors", () => {
    assert.equal(
      messagingErrorCode({code: "messaging/internal-error"}),
      "messaging/internal-error",
    );
    assert.equal(messagingErrorCode({code: 500}), undefined);
    assert.equal(messagingErrorCode(new Error("network")), undefined);
  });

  it("deduplicates tokens and excludes prior terminal outcomes", () => {
    const delivered = hashDeliveryToken("already-delivered");
    const invalid = hashDeliveryToken("invalid-token");

    assert.deepEqual(
      selectPendingTokens(
        [
          "new-token",
          "already-delivered",
          "new-token",
          "invalid-token",
        ],
        [delivered],
        [invalid],
      ),
      ["new-token"],
    );
  });

  it("bounds retry attempts", () => {
    assert.equal(canRetryDelivery(1), true);
    assert.equal(
      canRetryDelivery(MAX_NOTIFICATION_DELIVERY_ATTEMPTS - 1),
      true,
    );
    assert.equal(
      canRetryDelivery(MAX_NOTIFICATION_DELIVERY_ATTEMPTS),
      false,
    );
  });

  it("creates stable message-scoped APNs collapse identifiers", () => {
    const first = notificationCollapseId("conversation", "message-one");
    const repeated = notificationCollapseId("conversation", "message-one");
    const second = notificationCollapseId("conversation", "message-two");

    assert.equal(first, repeated);
    assert.notEqual(first, second);
    assert.ok(first.length <= 64);
  });
});

it("never derives encrypted notification or conversation previews from private fields", () => {
  for (const marker of ["mines-e2ee-v1", "future-encryption", false]) {
    assert.equal(messageNotificationPreview(marker, {type: "text", text: "private"}), "New message");
  }
  assert.equal(messageNotificationPreview(undefined, {type: "encrypted", text: "private"}), "New message");
  assert.equal(messageNotificationPreview(undefined, {type: "text", encryption: "mines-e2ee-v1", text: "private"}), "New message");
  assert.equal(messageNotificationPreview(undefined, {type: "text", text: "legacy"}), "legacy");
});

describe("encrypted notification preview transport", () => {
  const message = () => ({
    senderId: "sender", type: "encrypted", encryption: "mines-e2ee-v1",
    keyEpoch: 1, revision: 1, notificationPreview: Buffer.from([0, 127, 255]),
    text: "private-text-canary", attachmentName: "private-filename-canary",
    ciphertext: Buffer.from("private-message-ciphertext-canary"),
  });
  const payload = (value = message(), marker: unknown = "mines-e2ee-v1", conversation = "conversation") =>
    messageNotificationPayload(marker, value, conversation, "message", "Sender");

  it("accepts only a sidecar bound to the exact original message metadata", () => {
    const value = message();
    const sidecar = {senderId: value.senderId, encryption: value.encryption,
      keyEpoch: value.keyEpoch, revision: value.revision, ciphertext: value.notificationPreview};
    assert.equal(notificationPreviewForMessage(value, sidecar), value.notificationPreview);
    assert.equal(notificationPreviewForMessage(value, undefined), undefined);
    for (const fields of [
      {senderId: "other"}, {encryption: "future"}, {keyEpoch: 2}, {keyEpoch: "1"},
      {revision: 2}, {revision: "1"}, {revision: undefined},
    ]) assert.equal(notificationPreviewForMessage(value, {...sidecar, ...fields}), undefined);
    assert.equal(notificationPreviewForMessage({...value, revision: 2}, {...sidecar, revision: 2}), undefined);
    assert.equal(notificationPreviewForMessage({...value, type: "text"}, sidecar), undefined);
    assert.equal(notificationPreviewForMessage({...value, encryption: "future"}, {...sidecar, encryption: "future"}), undefined);
    const malformed = notificationPreviewForMessage(value, {...sidecar, ciphertext: "private"});
    assert.equal(payload({...value, notificationPreview: malformed as Buffer}).data.notificationPreview, undefined);
  });

  it("suppresses delayed alerts after unsend even when an old client retains the sidecar", () => {
    const original = message();
    const sidecar = {senderId: original.senderId, encryption: original.encryption,
      keyEpoch: 1, revision: 1, ciphertext: original.notificationPreview};
    for (const current of [undefined, {...original, ciphertext: Buffer.alloc(0), revision: 2, deletedAt: {}}]) {
      const state = messageAlertCurrentState(original, current, sidecar);
      assert.equal(state.shouldAlert, false);
      assert.equal(state.notificationPreview, undefined);
    }
    assert.equal(messageAlertCurrentState(original, {...original}, sidecar).notificationPreview,
      original.notificationPreview);
  });

  it("omits stale original previews after edits or changes to message scope or bytes", () => {
    const original = message();
    const sidecar = {senderId: original.senderId, encryption: original.encryption,
      keyEpoch: 1, revision: 1, ciphertext: original.notificationPreview};
    for (const change of [
      {revision: 2}, {ciphertext: Buffer.from("edited")}, {ciphertext: undefined},
      {ciphertext: Buffer.alloc(0)}, {senderId: "other"}, {keyEpoch: 2},
      {encryption: "future"}, {type: "text"},
    ]) {
      const state = messageAlertCurrentState(original, {...original, ...change}, sidecar);
      assert.equal(state.shouldAlert, true);
      assert.equal(state.notificationPreview, undefined);
      assert.equal(payload({...original, notificationPreview: state.notificationPreview as Buffer})
        .notification.body, "New message");
    }
    // Equal byte contents are accepted even when Firestore returns a new Buffer.
    assert.equal(messageAlertCurrentState(original, {...original, ciphertext: Buffer.from(original.ciphertext)}, sidecar)
      .notificationPreview, original.notificationPreview);
    assert.equal(messageAlertCurrentState({...original, type: "text", encryption: undefined},
      {...original, type: "text", encryption: undefined}, sidecar).notificationPreview, undefined);
  });

  it("forwards only public routing and base64 opaque bytes with canonical context", () => {
    const result = payload();
    assert.deepEqual(result.notification, {title: "Sender", body: "New message"});
    assert.deepEqual(result.data, {
      conversationId: "conversation", messageId: "message", senderId: "sender",
      senderName: "Sender", type: "encrypted", notificationPreview: "AH//", keyEpoch: "1", revision: "1",
    });
    assert.equal(result.apns.payload.aps.mutableContent, true);
    assert.equal(result.apns.payload.aps.threadId, "conversation");
    assert.ok(!JSON.stringify(result).includes("private-"));
    assert.equal(payload({...message(), keyEpoch: Number.MAX_SAFE_INTEGER}).data.keyEpoch,
      String(Number.MAX_SAFE_INTEGER));
  });

  it("accepts both byte boundaries and omits missing, malformed or oversized previews", () => {
    for (const size of [1, MAX_NOTIFICATION_PREVIEW_BYTES]) {
      const bytes = Buffer.alloc(size, 255);
      assert.equal(payload({...message(), notificationPreview: bytes}).data.notificationPreview, bytes.toString("base64"));
    }
    for (const invalid of [undefined, null, "plaintext", "AH//", [], {}, Buffer.alloc(0), Buffer.alloc(MAX_NOTIFICATION_PREVIEW_BYTES + 1)]) {
      const result = payload({...message(), notificationPreview: invalid as Buffer});
      assert.equal(result.data.notificationPreview, undefined);
      assert.equal(result.data.keyEpoch, undefined);
      assert.equal(result.data.revision, undefined);
      assert.equal(result.notification.body, "New message");
    }
  });

  it("fails closed for invalid suite, type, context numbers, edited and deleted records", () => {
    const invalidRecords = [
      {encryption: undefined}, {encryption: "future-suite"}, {type: "text"},
      ...[undefined, "1", 0, -1, 1.5, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1]
        .map((keyEpoch) => ({keyEpoch})),
      ...[undefined, "1", 0, -1, 1.5, 2, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1]
        .map((revision) => ({revision})),
      {deletedAt: {}},
    ];
    for (const fields of invalidRecords) {
      const result = payload({...message(), ...fields} as ReturnType<typeof message>);
      assert.equal(result.data.notificationPreview, undefined);
      assert.equal(result.notification.body, "New message");
      assert.ok(!JSON.stringify(result).includes("private-"));
    }
    for (const marker of [undefined, null, false, "future-suite"]) {
      assert.equal(messageNotificationPayload(marker, message(), "conversation", "message", "Sender")
        .data.notificationPreview, undefined);
    }
  });

  it("keeps the complete modeled Apple payload below its budget, including Unicode routing", () => {
    const bytes = Buffer.alloc(MAX_NOTIFICATION_PREVIEW_BYTES, 255);
    const value = {...message(), notificationPreview: bytes};
    assert.ok(payload(value).data.notificationPreview);
    // JSON byte length, rather than JavaScript character count, decides the
    // fallback. All routing and the generic alert survive preview omission.
    const conversation = "🛡️".repeat(200);
    const result = payload(value, "mines-e2ee-v1", conversation);
    assert.equal(result.data.notificationPreview, undefined);
    assert.equal(result.data.conversationId, conversation);
    assert.equal(result.apns.payload.aps.threadId, conversation);
    assert.equal(result.notification.body, "New message");
    const normal = payload(value);
    const modeled = {...normal.data, aps: {
      alert: normal.notification, sound: "default", category: "MESSAGE",
      "thread-id": "conversation", "mutable-content": 1, "interruption-level": "time-sensitive",
    }};
    assert.ok(Buffer.byteLength(JSON.stringify(modeled)) <= MAX_MODELED_APNS_PAYLOAD_BYTES);
    assert.ok(MAX_MODELED_APNS_PAYLOAD_BYTES <= 4096 - 512);
  });

  it("preserves legacy alerts and the quiet opt-out independently of preview bytes", () => {
    const legacy = payload({...message(), type: "text", encryption: undefined, text: "legacy"} as ReturnType<typeof message>, null);
    assert.equal(legacy.notification.body, "legacy");
    assert.equal(legacy.data.notificationPreview, undefined);
    for (const delivery of [undefined, "normal", "future-mode", "quiet"]) {
      assert.equal(shouldSendMessageAlert(delivery, message()), delivery !== "quiet");
    }
  });
});
