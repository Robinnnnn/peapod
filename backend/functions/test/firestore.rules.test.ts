import {readFileSync} from "node:fs";
import {after, before, beforeEach, describe, it} from "node:test";
import assert from "node:assert/strict";

import {
  RulesTestEnvironment,
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from "@firebase/rules-unit-testing";
import {
  Timestamp,
  Bytes,
  deleteDoc,
  doc,
  getDoc,
  serverTimestamp,
  setDoc,
  updateDoc,
  writeBatch,
} from "firebase/firestore";
import {
  deleteObject,
  getBytes,
  ref,
  uploadBytes,
} from "firebase/storage";

const projectId = process.env.PEAPOD_RULES_PROJECT_ID ?? "demo-peapod";
const messageIds = {
  one: "00000000-0000-4000-8000-000000000001",
  two: "00000000-0000-4000-8000-000000000002",
  three: "00000000-0000-4000-8000-000000000003",
  target: "00000000-0000-4000-8000-000000000004",
  reply: "00000000-0000-4000-8000-000000000005",
  badReply: "00000000-0000-4000-8000-000000000006",
  missing: "00000000-0000-4000-8000-000000000007",
  voice: "00000000-0000-4000-8000-000000000008",
  badDuration: "00000000-0000-4000-8000-000000000009",
  aliceImage: "00000000-0000-4000-8000-000000000010",
  different: "00000000-0000-4000-8000-000000000011",
  bobImage: "00000000-0000-4000-8000-000000000012",
  claimedByBob: "00000000-0000-4000-8000-000000000013",
  attachment: "00000000-0000-4000-8000-000000000014",
  tombstone: "00000000-0000-4000-8000-000000000015",
};
let environment: RulesTestEnvironment;

before(async () => {
  environment = await initializeTestEnvironment({
    projectId,
    firestore: {
      host: "127.0.0.1",
      port: Number(process.env.PEAPOD_RULES_FIRESTORE_PORT ?? 8080),
      rules: readFileSync("../firestore.rules", "utf8"),
    },
    storage: {
      host: "127.0.0.1",
      port: Number(process.env.PEAPOD_RULES_STORAGE_PORT ?? 9199),
      rules: readFileSync("../storage.rules", "utf8"),
    },
  });
});

beforeEach(async () => {
  await environment.clearFirestore();
  await environment.clearStorage();
  await environment.withSecurityRulesDisabled(async (context) => {
    const firestore = context.firestore();
    await setDoc(doc(firestore, "users/alice"), {
      displayName: "Alice",
      activeConversationId: "conversation-one",
    });
    await setDoc(doc(firestore, "users/bob"), {
      displayName: "Bob",
      activeConversationId: "conversation-one",
    });
    await setDoc(doc(firestore, "users/mallory"), {
      displayName: "Mallory",
    });
    await setDoc(doc(firestore, "conversations/conversation-one"), {
      members: ["alice", "bob"],
      status: "active",
      createdBy: "alice",
      createdAt: Timestamp.now(),
      lastMessageAt: null,
    });
  });
});

after(async () => {
  await environment.cleanup();
});

describe("conversation membership", () => {
  it("allows a member and rejects an outsider", async () => {
    const alice = environment.authenticatedContext("alice").firestore();
    const mallory = environment.authenticatedContext("mallory").firestore();

    await assertSucceeds(
      getDoc(doc(alice, "conversations/conversation-one")),
    );
    await assertFails(
      getDoc(doc(mallory, "conversations/conversation-one")),
    );
    await assertSucceeds(getDoc(doc(alice, "users/bob")));
    await assertFails(getDoc(doc(mallory, "users/bob")));
  });

  it("rejects client-created conversations and direct pairing state access", async () => {
    const alice = environment.authenticatedContext("alice").firestore();

    await assertFails(
      setDoc(doc(alice, "conversations/another"), {
        members: ["alice", "mallory"],
      }),
    );
    await assertFails(deleteDoc(doc(alice, "conversations/conversation-one")));
    await assertFails(updateDoc(doc(alice, "conversations/conversation-one"), {
      status: "closed",
    }));
    await assertFails(setDoc(doc(alice, "conversationDeletionJobs/conversation-one"), {
      conversationId: "conversation-one",
      requestedBy: "alice",
    }));
    await assertFails(getDoc(doc(alice, "pairingCodes/ABCDEFGH")));
    await assertFails(getDoc(doc(alice, "pairingRateLimits/alice")));
    await assertFails(
      setDoc(
        doc(
          alice,
          "pairingRateLimits/alice/pairingAttempts/redeem-window-0",
        ),
        {expiresAt: Timestamp.now()},
      ),
    );
  });

  it("blocks conversation data and attachment blobs after closure", async () => {
    const messagePath =
      `conversations/conversation-one/messages/${messageIds.attachment}`;
    const attachmentPath =
      `conversations/conversation-one/attachments/${messageIds.attachment}`;
    const blobPath = `${attachmentPath}/photo.jpg`;
    const bytes = new Uint8Array([1, 2, 3, 4]);

    await environment.withSecurityRulesDisabled(async (context) => {
      const firestore = context.firestore();
      await setDoc(doc(firestore, messagePath), {
        senderId: "alice",
        clientId: messageIds.attachment,
        type: "image",
        text: "photo.jpg",
        createdAt: Timestamp.now(),
      });
      await setDoc(doc(firestore, attachmentPath), {
        ownerId: "alice",
        messageId: messageIds.attachment,
        storagePath: blobPath,
        fileName: "photo.jpg",
        contentType: "image/jpeg",
        byteSize: bytes.byteLength,
        createdAt: Timestamp.now(),
      });
    });

    const aliceContext = environment.authenticatedContext("alice");
    await assertSucceeds(
      uploadBytes(
        ref(aliceContext.storage(), blobPath),
        bytes,
        {contentType: "image/jpeg"},
      ),
    );

    await environment.withSecurityRulesDisabled(async (context) => {
      await updateDoc(
        doc(context.firestore(), "conversations/conversation-one"),
        {status: "closed"},
      );
    });

    const alice = aliceContext.firestore();
    await assertFails(
      getDoc(doc(alice, "conversations/conversation-one")),
    );
    await assertFails(getDoc(doc(alice, messagePath)));
    await assertFails(getDoc(doc(alice, "users/bob")));
    await assertFails(
      setDoc(
        doc(
          alice,
          `conversations/conversation-one/messages/${messageIds.one}`,
        ),
        {
          senderId: "alice",
          clientId: messageIds.one,
          type: "text",
          text: "after closure",
          createdAt: serverTimestamp(),
        },
      ),
    );
    await assertFails(getBytes(ref(aliceContext.storage(), blobPath)));
  });
});

describe("device registrations", () => {
  function deviceRegistration(platform: string) {
    return {
      token: "a".repeat(64),
      platform,
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    };
  }

  it("allows iOS and macOS tokens owned by the signed-in user", async () => {
    const alice = environment.authenticatedContext("alice").firestore();

    await assertSucceeds(
      setDoc(
        doc(alice, "users/alice/devices/iphone"),
        deviceRegistration("ios"),
      ),
    );
    await assertSucceeds(
      setDoc(
        doc(alice, "users/alice/devices/mac"),
        deviceRegistration("macos"),
      ),
    );
  });

  it("rejects unknown platforms and another user's token", async () => {
    const alice = environment.authenticatedContext("alice").firestore();

    await assertFails(
      setDoc(
        doc(alice, "users/alice/devices/browser"),
        deviceRegistration("web"),
      ),
    );
    await assertFails(
      setDoc(
        doc(alice, "users/bob/devices/mac"),
        deviceRegistration("macos"),
      ),
    );
  });
});

describe("messages", () => {
  it("rejects encrypted notification previews on legacy messages", async () => {
    const alice = environment.authenticatedContext("alice").firestore();
    await assertFails(setDoc(doc(alice, `conversations/conversation-one/messages/${messageIds.one}`), {
      senderId: "alice", clientId: messageIds.one, type: "text", text: "hello",
      createdAt: serverTimestamp(), notificationPreview: Bytes.fromUint8Array(new Uint8Array([7])),
    }));
  });
  it("allows a member to send a well-formed message", async () => {
    const alice = environment.authenticatedContext("alice").firestore();

    await assertSucceeds(
      setDoc(
        doc(
          alice,
          `conversations/conversation-one/messages/${messageIds.one}`,
        ),
        {
          senderId: "alice",
          clientId: messageIds.one,
          type: "text",
          text: "hello",
          createdAt: serverTimestamp(),
        },
      ),
    );
  });

  it("allows only an omitted or exact quiet delivery field", async () => {
    const alice = environment.authenticatedContext("alice").firestore();

    await assertSucceeds(
      setDoc(
        doc(
          alice,
          `conversations/conversation-one/messages/${messageIds.two}`,
        ),
        {
          senderId: "alice",
          clientId: messageIds.two,
          type: "text",
          text: "quiet hello",
          delivery: "quiet",
          createdAt: serverTimestamp(),
        },
      ),
    );
    await assertFails(
      setDoc(
        doc(
          alice,
          `conversations/conversation-one/messages/${messageIds.three}`,
        ),
        {
          senderId: "alice",
          clientId: messageIds.three,
          type: "text",
          text: "normal stays omitted",
          delivery: "normal",
          createdAt: serverTimestamp(),
        },
      ),
    );
    await assertFails(
      setDoc(
        doc(
          alice,
          `conversations/conversation-one/messages/${messageIds.missing}`,
        ),
        {
          senderId: "alice",
          clientId: messageIds.missing,
          type: "text",
          text: "unknown delivery",
          delivery: "future-mode",
          createdAt: serverTimestamp(),
        },
      ),
    );
  });

  it("rejects sender spoofing and outsiders", async () => {
    const alice = environment.authenticatedContext("alice").firestore();
    const mallory = environment.authenticatedContext("mallory").firestore();
    const spoofed = {
      senderId: "bob",
      clientId: messageIds.two,
      type: "text",
      text: "not from Bob",
      createdAt: serverTimestamp(),
    };

    await assertFails(
      setDoc(
        doc(
          alice,
          `conversations/conversation-one/messages/${messageIds.two}`,
        ),
        spoofed,
      ),
    );
    await assertFails(
      setDoc(
        doc(
          mallory,
          `conversations/conversation-one/messages/${messageIds.three}`,
        ),
        {
          ...spoofed,
          senderId: "mallory",
          clientId: messageIds.three,
        },
      ),
    );
  });

  it("rejects non-UUID and mismatched message identities", async () => {
    const alice = environment.authenticatedContext("alice").firestore();
    const payload = {
      senderId: "alice",
      type: "text",
      text: "must stay decodable",
      createdAt: serverTimestamp(),
    };

    await assertFails(
      setDoc(
        doc(alice, "conversations/conversation-one/messages/not-a-uuid"),
        {...payload, clientId: "not-a-uuid"},
      ),
    );
    await assertFails(
      setDoc(
        doc(
          alice,
          `conversations/conversation-one/messages/${messageIds.one}`,
        ),
        {...payload, clientId: messageIds.two},
      ),
    );
  });

  it("lets only the sender edit message text", async () => {
    await environment.withSecurityRulesDisabled(async (context) => {
      await setDoc(
        doc(
          context.firestore(),
          `conversations/conversation-one/messages/${messageIds.one}`,
        ),
        {
          senderId: "alice",
          clientId: messageIds.one,
          type: "text",
          text: "hello",
          createdAt: Timestamp.now(),
        },
      );
    });
    const alice = environment.authenticatedContext("alice").firestore();
    const bob = environment.authenticatedContext("bob").firestore();

    await assertSucceeds(
      updateDoc(
        doc(
          alice,
          `conversations/conversation-one/messages/${messageIds.one}`,
        ),
        {
          text: "https://example.com",
          type: "link",
          editedAt: serverTimestamp(),
        },
      ),
    );
    await assertFails(
      updateDoc(
        doc(
          bob,
          `conversations/conversation-one/messages/${messageIds.one}`,
        ),
        {text: "tampered", editedAt: serverTimestamp()},
      ),
    );
    await assertSucceeds(
      updateDoc(
        doc(
          alice,
          `conversations/conversation-one/messages/${messageIds.one}`,
        ),
        {text: "", deletedAt: serverTimestamp()},
      ),
    );
    await assertFails(
      updateDoc(
        doc(
          alice,
          `conversations/conversation-one/messages/${messageIds.one}`,
        ),
        {text: "restored", editedAt: serverTimestamp()},
      ),
    );
  });

  it("requires replies to reference a message in the conversation", async () => {
    const alice = environment.authenticatedContext("alice").firestore();

    await assertSucceeds(
      setDoc(
        doc(
          alice,
          `conversations/conversation-one/messages/${messageIds.target}`,
        ),
        {
          senderId: "alice",
          clientId: messageIds.target,
          type: "text",
          text: "target",
          createdAt: serverTimestamp(),
        },
      ),
    );
    await assertSucceeds(
      setDoc(
        doc(
          alice,
          `conversations/conversation-one/messages/${messageIds.reply}`,
        ),
        {
          senderId: "alice",
          clientId: messageIds.reply,
          type: "text",
          text: "reply",
          replyToId: messageIds.target,
          createdAt: serverTimestamp(),
        },
      ),
    );
    await assertFails(
      setDoc(
        doc(
          alice,
          `conversations/conversation-one/messages/${messageIds.badReply}`,
        ),
        {
          senderId: "alice",
          clientId: messageIds.badReply,
          type: "text",
          text: "reply",
          replyToId: messageIds.missing,
          createdAt: serverTimestamp(),
        },
      ),
    );
  });

  it("allows one owned reaction per participant and message", async () => {
    await environment.withSecurityRulesDisabled(async (context) => {
      await setDoc(
        doc(
          context.firestore(),
          `conversations/conversation-one/messages/${messageIds.one}`,
        ),
        {
          senderId: "alice",
          clientId: messageIds.one,
          type: "text",
          text: "hello",
          createdAt: Timestamp.now(),
        },
      );
    });
    const alice = environment.authenticatedContext("alice").firestore();
    const bob = environment.authenticatedContext("bob").firestore();
    const reactionPath =
      `conversations/conversation-one/reactions/${messageIds.one}--alice`;

    await assertSucceeds(setDoc(doc(alice, reactionPath), {
      messageId: messageIds.one,
      userId: "alice",
      emoji: "❤️",
      updatedAt: serverTimestamp(),
    }));
    await assertSucceeds(updateDoc(doc(alice, reactionPath), {
      emoji: "👍",
      updatedAt: serverTimestamp(),
    }));
    await assertFails(updateDoc(doc(bob, reactionPath), {
      emoji: "👎",
      updatedAt: serverTimestamp(),
    }));
    await assertSucceeds(updateDoc(
      doc(
        alice,
        `conversations/conversation-one/messages/${messageIds.one}`,
      ),
      {text: "", deletedAt: serverTimestamp()},
    ));
    await assertFails(updateDoc(doc(alice, reactionPath), {
      emoji: "😂",
      updatedAt: serverTimestamp(),
    }));
    await assertSucceeds(deleteDoc(doc(alice, reactionPath)));
  });
});

describe("participant state", () => {
  it("allows participants to update only their own read and typing state", async () => {
    const alice = environment.authenticatedContext("alice").firestore();
    const receipt = doc(
      alice,
      "conversations/conversation-one/readStates/alice",
    );

    await assertSucceeds(
      setDoc(receipt, {
        userId: "alice",
        lastDeliveredMessageId: messageIds.one,
        lastDeliveredAt: serverTimestamp(),
      }),
    );
    await assertSucceeds(
      setDoc(receipt, {
        userId: "alice",
        lastReadMessageId: messageIds.one,
        lastReadAt: serverTimestamp(),
      }, {merge: true}),
    );
    await assertFails(
      setDoc(doc(alice, "conversations/conversation-one/readStates/bob"), {
        userId: "bob",
        lastReadMessageId: messageIds.one,
        lastReadAt: serverTimestamp(),
      }),
    );
    await assertSucceeds(
      setDoc(doc(alice, "conversations/conversation-one/typing/alice"), {
        userId: "alice",
        isTyping: true,
        updatedAt: serverTimestamp(),
        expiresAt: Timestamp.fromMillis(Date.now() + 60_000),
      }),
    );
  });

  it("validates latest live location and attachment metadata ownership", async () => {
    const alice = environment.authenticatedContext("alice").firestore();

    await assertFails(
      setDoc(doc(alice, "conversations/conversation-one/locations/alice"), {
        userId: "alice",
        latitude: 37.7749,
        longitude: -122.4194,
        horizontalAccuracy: 12,
        recordedAt: Timestamp.now(),
        updatedAt: serverTimestamp(),
      }),
    );
    await assertSucceeds(
      setDoc(
        doc(
          alice,
          "conversations/conversation-one/locationSharing/alice",
        ),
        {
          userId: "alice",
          isSharing: true,
          updatedAt: serverTimestamp(),
        },
      ),
    );
    await assertSucceeds(
      setDoc(doc(alice, "conversations/conversation-one/locations/alice"), {
        userId: "alice",
        latitude: 37.7749,
        longitude: -122.4194,
        horizontalAccuracy: 12,
        recordedAt: Timestamp.now(),
        updatedAt: serverTimestamp(),
      }),
    );
    await assertFails(
      setDoc(doc(alice, "conversations/conversation-one/locations/alice"), {
        userId: "alice",
        latitude: 37.7749,
        longitude: -122.4194,
        horizontalAccuracy: 12,
        recordedAt: "not-a-timestamp",
        updatedAt: serverTimestamp(),
      }),
    );
    await assertFails(
      setDoc(doc(alice, "conversations/conversation-one/locations/bob"), {
        userId: "bob",
        latitude: 37.7749,
        longitude: -122.4194,
        horizontalAccuracy: 12,
        updatedAt: serverTimestamp(),
      }),
    );
    await assertFails(
      setDoc(
        doc(
          alice,
          "conversations/conversation-one/locationSharing/bob",
        ),
        {
          userId: "bob",
          isSharing: true,
          updatedAt: serverTimestamp(),
        },
      ),
    );
    await assertFails(
      setDoc(
        doc(
          alice,
          "conversations/conversation-one/locationSharing/alice",
        ),
        {
          userId: "alice",
          isSharing: false,
          updatedAt: serverTimestamp(),
        },
      ),
    );
    await assertFails(
      deleteDoc(
        doc(
          alice,
          "conversations/conversation-one/locationSharing/alice",
        ),
      ),
    );
    const disableBatch = writeBatch(alice);
    disableBatch.set(
      doc(
        alice,
        "conversations/conversation-one/locationSharing/alice",
      ),
      {
        userId: "alice",
        isSharing: false,
        updatedAt: serverTimestamp(),
      },
    );
    disableBatch.delete(
      doc(alice, "conversations/conversation-one/locations/alice"),
    );
    await assertSucceeds(disableBatch.commit());
    await assertSucceeds(
      setDoc(
        doc(
          alice,
          `conversations/conversation-one/attachments/${messageIds.one}`,
        ),
        {
          ownerId: "alice",
          messageId: messageIds.one,
          storagePath:
            `conversations/conversation-one/attachments/${messageIds.one}/photo.jpg`,
          fileName: "photo.jpg",
          contentType: "image/jpeg",
          byteSize: 1024,
          createdAt: serverTimestamp(),
        },
      ),
    );
    await assertSucceeds(
      setDoc(
        doc(
          alice,
          `conversations/conversation-one/attachments/${messageIds.voice}`,
        ),
        {
          ownerId: "alice",
          messageId: messageIds.voice,
          storagePath:
            `conversations/conversation-one/attachments/${messageIds.voice}/voice.m4a`,
          fileName: "voice.m4a",
          contentType: "audio/mp4",
          byteSize: 4096,
          audioDurationMs: 4250,
          createdAt: serverTimestamp(),
        },
      ),
    );
    await assertFails(
      setDoc(
        doc(
          alice,
          `conversations/conversation-one/attachments/${messageIds.badDuration}`,
        ),
        {
          ownerId: "alice",
          messageId: messageIds.badDuration,
          storagePath:
            `conversations/conversation-one/attachments/${messageIds.badDuration}/photo.jpg`,
          fileName: "photo.jpg",
          contentType: "image/jpeg",
          byteSize: 1024,
          audioDurationMs: 4250,
          createdAt: serverTimestamp(),
        },
      ),
    );
  });

  it("allows original photos and videos up to 200 MiB while retaining other attachment limits", async () => {
    const alice = environment.authenticatedContext("alice").firestore();
    for (const [contentType, maximum] of [["video/mp4", 200], ["video/quicktime", 200],
      ["image/jpeg", 200], ["image/heic", 200], ["application/octet-stream", 100],
      ["audio/mp4", 100], ["application/x-video/mp4", 100], ["application/x-image/jpeg", 100]] as const) {
      const target = doc(alice, `conversations/conversation-one/attachments/${messageIds.attachment}`);
      const value = {ownerId: "alice", messageId: messageIds.attachment,
        storagePath: `conversations/conversation-one/attachments/${messageIds.attachment}/original`,
        fileName: "original", contentType, createdAt: serverTimestamp()};
      await assertFails(setDoc(target, {...value, byteSize: maximum * 1024 * 1024 + 1}));
      await assertSucceeds(setDoc(target, {...value, byteSize: maximum * 1024 * 1024}));
      await deleteDoc(target);
    }
  });

  it("binds attachment metadata to its message and sender", async () => {
    const alice = environment.authenticatedContext("alice").firestore();
    const bob = environment.authenticatedContext("bob").firestore();
    const aliceStorage = environment.authenticatedContext("alice").storage();
    const bobStorage = environment.authenticatedContext("bob").storage();

    const validMetadataPath =
      `conversations/conversation-one/attachments/${messageIds.aliceImage}`;
    const validStoragePath =
      `conversations/conversation-one/attachments/${messageIds.aliceImage}/photo.jpg`;
    const validBytes = new Uint8Array([1, 2, 3, 4]);
    await assertSucceeds(
      setDoc(doc(alice, validMetadataPath), {
        ownerId: "alice",
        messageId: messageIds.aliceImage,
        storagePath: validStoragePath,
        fileName: "photo.jpg",
        contentType: "image/jpeg",
        byteSize: validBytes.byteLength,
        createdAt: serverTimestamp(),
      }),
    );
    await assertSucceeds(
      uploadBytes(
        ref(aliceStorage, validStoragePath),
        validBytes,
        {contentType: "image/jpeg"},
      ),
    );
    await assertSucceeds(
      setDoc(
        doc(
          alice,
          `conversations/conversation-one/messages/${messageIds.aliceImage}`,
        ),
        {
          senderId: "alice",
          clientId: messageIds.aliceImage,
          type: "image",
          text: "photo.jpg",
          createdAt: serverTimestamp(),
        },
      ),
    );
    await assertSucceeds(getDoc(doc(bob, validMetadataPath)));
    await assertSucceeds(
      getDoc(
        doc(
          bob,
          `conversations/conversation-one/messages/${messageIds.aliceImage}`,
        ),
      ),
    );
    await assertSucceeds(
      getBytes(ref(bobStorage, validStoragePath)),
    );

    await assertFails(
      setDoc(
        doc(
          alice,
          `conversations/conversation-one/attachments/${messageIds.different}`,
        ),
        {
          ownerId: "alice",
          messageId: messageIds.one,
          storagePath:
            `conversations/conversation-one/attachments/${messageIds.different}/photo.jpg`,
          fileName: "photo.jpg",
          contentType: "image/jpeg",
          byteSize: 1024,
          createdAt: serverTimestamp(),
        },
      ),
    );

    await environment.withSecurityRulesDisabled(async (context) => {
      await setDoc(
        doc(
          context.firestore(),
          `conversations/conversation-one/messages/${messageIds.bobImage}`,
        ),
        {
          senderId: "bob",
          clientId: messageIds.bobImage,
          type: "image",
          text: "bob.jpg",
          createdAt: Timestamp.now(),
        },
      );
    });
    await assertFails(
      setDoc(
        doc(
          alice,
          `conversations/conversation-one/attachments/${messageIds.bobImage}`,
        ),
        {
          ownerId: "alice",
          messageId: messageIds.bobImage,
          storagePath:
            `conversations/conversation-one/attachments/${messageIds.bobImage}/forged.jpg`,
          fileName: "forged.jpg",
          contentType: "image/jpeg",
          byteSize: 1024,
          createdAt: serverTimestamp(),
        },
      ),
    );
  });

  it("accepts a durable photo group and rejects forged membership", async () => {
    const alice = environment.authenticatedContext("alice").firestore();
    const ids = [messageIds.one, messageIds.two, messageIds.three];

    for (const id of ids) {
      const fileName = `${id}.jpg`;
      await assertSucceeds(
        setDoc(
          doc(
            alice,
            `conversations/conversation-one/attachments/${id}`,
          ),
          {
            ownerId: "alice",
            messageId: id,
            storagePath:
              `conversations/conversation-one/attachments/${id}/${fileName}`,
            fileName,
            contentType: "image/jpeg",
            byteSize: 4,
            createdAt: serverTimestamp(),
          },
        ),
      );
    }

    await assertSucceeds(
      setDoc(
        doc(
          alice,
          `conversations/conversation-one/messages/${messageIds.one}`,
        ),
        {
          senderId: "alice",
          clientId: messageIds.one,
          type: "image",
          text: "one.jpg",
          attachmentGroupId: messageIds.one,
          attachmentGroupIndex: 0,
          attachmentGroupCount: 3,
          createdAt: serverTimestamp(),
        },
      ),
    );
    await assertSucceeds(
      setDoc(
        doc(
          alice,
          `conversations/conversation-one/messages/${messageIds.two}`,
        ),
        {
          senderId: "alice",
          clientId: messageIds.two,
          type: "image",
          text: "two.jpg",
          attachmentGroupId: messageIds.one,
          attachmentGroupIndex: 1,
          attachmentGroupCount: 3,
          createdAt: serverTimestamp(),
        },
      ),
    );

    await assertFails(
      setDoc(
        doc(
          alice,
          `conversations/conversation-one/messages/${messageIds.three}`,
        ),
        {
          senderId: "alice",
          clientId: messageIds.three,
          type: "image",
          text: "three.jpg",
          attachmentGroupId: messageIds.missing,
          attachmentGroupIndex: 2,
          attachmentGroupCount: 3,
          createdAt: serverTimestamp(),
        },
      ),
    );
  });

  it("rejects attachment metadata recreated for an unsent message", async () => {
    const alice = environment.authenticatedContext("alice").firestore();
    const messagePath =
      `conversations/conversation-one/messages/${messageIds.tombstone}`;

    await assertSucceeds(
      setDoc(doc(alice, messagePath), {
        senderId: "alice",
        clientId: messageIds.tombstone,
        type: "text",
        text: "Never mind",
        createdAt: serverTimestamp(),
      }),
    );
    await assertSucceeds(
      updateDoc(doc(alice, messagePath), {
        text: "",
        deletedAt: serverTimestamp(),
      }),
    );
    await assertFails(
      setDoc(
        doc(
          alice,
          `conversations/conversation-one/attachments/${messageIds.tombstone}`,
        ),
        {
          ownerId: "alice",
          messageId: messageIds.tombstone,
          storagePath:
            `conversations/conversation-one/attachments/${messageIds.tombstone}/voice.m4a`,
          fileName: "voice.m4a",
          contentType: "audio/mp4",
          byteSize: 4096,
          audioDurationMs: 4250,
          createdAt: serverTimestamp(),
        },
      ),
    );
  });

  it("rejects attachment messages backed by another user's metadata", async () => {
    const alice = environment.authenticatedContext("alice").firestore();

    await environment.withSecurityRulesDisabled(async (context) => {
      await setDoc(
        doc(
          context.firestore(),
          `conversations/conversation-one/attachments/${messageIds.claimedByBob}`,
        ),
        {
          ownerId: "bob",
          messageId: messageIds.claimedByBob,
          storagePath:
            `conversations/conversation-one/attachments/${messageIds.claimedByBob}/bob.jpg`,
          fileName: "bob.jpg",
          contentType: "image/jpeg",
          byteSize: 1024,
          createdAt: Timestamp.now(),
        },
      );
    });

    await assertFails(
      setDoc(
        doc(
          alice,
          `conversations/conversation-one/messages/${messageIds.claimedByBob}`,
        ),
        {
          senderId: "alice",
          clientId: messageIds.claimedByBob,
          type: "image",
          text: "bob.jpg",
          createdAt: serverTimestamp(),
        },
      ),
    );
  });
});

it("does not permit users to change server-managed pairing state", async () => {
  const alice = environment.authenticatedContext("alice").firestore();

  await assertFails(
    updateDoc(doc(alice, "users/alice"), {
      activeConversationId: "attacker-selected-conversation",
      updatedAt: serverTimestamp(),
    }),
  );
  assert.ok(true);
});

describe("attachment blobs", () => {
  it("requires matching owner metadata and allows the other member to read", async () => {
    const path =
      `conversations/conversation-one/attachments/${messageIds.attachment}/photo.jpg`;
    const bytes = new Uint8Array([1, 2, 3, 4]);
    await environment.withSecurityRulesDisabled(async (context) => {
      await setDoc(
        doc(
          context.firestore(),
          `conversations/conversation-one/attachments/${messageIds.attachment}`,
        ),
        {
          ownerId: "alice",
          messageId: messageIds.attachment,
          storagePath: path,
          fileName: "photo.jpg",
          contentType: "image/jpeg",
          byteSize: bytes.byteLength,
          createdAt: Timestamp.now(),
        },
      );
    });

    const aliceStorage = environment.authenticatedContext("alice").storage();
    const bobStorage = environment.authenticatedContext("bob").storage();
    const malloryStorage =
      environment.authenticatedContext("mallory").storage();

    await assertSucceeds(
      uploadBytes(ref(aliceStorage, path), bytes, {contentType: "image/jpeg"}),
    );
    await assertSucceeds(getBytes(ref(bobStorage, path)));
    await assertFails(getBytes(ref(malloryStorage, path)));
    await assertFails(deleteObject(ref(bobStorage, path)));
    await assertSucceeds(deleteObject(ref(aliceStorage, path)));
  });
});

describe("secure conversation downgrade boundary", () => {
  it("rejects legacy content writes and blob uploads once the server marks a conversation encrypted", async () => {
    const path = `conversations/conversation-one/attachments/${messageIds.attachment}/photo.jpg`;
    await environment.withSecurityRulesDisabled(async (context) => {
      await updateDoc(doc(context.firestore(), "conversations/conversation-one"), {encryption: "mines-e2ee-v1", keyEpoch: 1});
      await setDoc(doc(context.firestore(), "conversations/conversation-one/locationSharing/alice"), {
        userId: "alice", isSharing: true, updatedAt: Timestamp.now(),
      });
      await setDoc(doc(context.firestore(), `conversations/conversation-one/messages/${messageIds.one}`), {
        senderId: "alice", clientId: messageIds.one, type: "text", text: "old", createdAt: Timestamp.now(),
      });
      await setDoc(doc(context.firestore(), `conversations/conversation-one/attachments/${messageIds.attachment}`), {
        ownerId: "alice", messageId: messageIds.attachment, storagePath: path,
        fileName: "photo.jpg", contentType: "image/jpeg", byteSize: 4, createdAt: Timestamp.now(),
      });
    });
    const alice = environment.authenticatedContext("alice");
    await assertFails(setDoc(doc(alice.firestore(), `conversations/conversation-one/messages/${messageIds.two}`), {
      senderId: "alice", clientId: messageIds.two, type: "text", text: "must not upload", createdAt: serverTimestamp(),
    }));
    await assertFails(updateDoc(doc(alice.firestore(), `conversations/conversation-one/messages/${messageIds.one}`), {text: "plaintext edit", editedAt: serverTimestamp()}));
    await assertFails(setDoc(doc(alice.firestore(), `conversations/conversation-one/reactions/${messageIds.one}--alice`), {
      messageId: messageIds.one, userId: "alice", emoji: "👍", updatedAt: serverTimestamp(),
    }));
    await assertFails(setDoc(doc(alice.firestore(), "conversations/conversation-one/locations/alice"), {
      userId: "alice", latitude: 1, longitude: 2, horizontalAccuracy: 3, recordedAt: Timestamp.now(), updatedAt: serverTimestamp(),
    }));
    await assertFails(uploadBytes(ref(alice.storage(), path), new Uint8Array([1, 2, 3, 4]), {contentType: "image/jpeg"}));
    // Metadata remains readable to members; content activation still needs a trusted local capsule.
    await assertSucceeds(getDoc(doc(alice.firestore(), "conversations/conversation-one")));
  });
  it("keeps protocol floors, pending invites and generation reservations server-only", async () => {
    const alice = environment.authenticatedContext("alice").firestore();
    await environment.withSecurityRulesDisabled(async (context) => {
      await updateDoc(doc(context.firestore(), "users/alice"), {e2eeRequired: true});
    });
    await assertFails(updateDoc(doc(alice, "users/alice"), {e2eeRequired: false, updatedAt: serverTimestamp()}));
    for (const path of ["securePairingInvites/invite", "securePairingRateLimits/rate", "secureConversationGenerations/generation"]) {
      await assertFails(getDoc(doc(alice, path)));
      await assertFails(setDoc(doc(alice, path), {state: "complete"}));
    }
  });
});


describe("encrypted content", () => {
  const base = "conversations/conversation-one";
  const cipher = (size = 128) => Bytes.fromUint8Array(new Uint8Array(size).fill(7));
  const record = () => ({encryption: "mines-e2ee-v1", keyEpoch: 1, revision: 1, ciphertext: cipher()});
  const message = (id = messageIds.one) => ({...record(), senderId: "alice", clientId: id,
    type: "encrypted", createdAt: serverTimestamp()});
  beforeEach(async () => {
    await environment.withSecurityRulesDisabled(async (context) => {
      await updateDoc(doc(context.firestore(), base), {encryption: "mines-e2ee-v1", keyEpoch: 1});
    });
  });
  it("accepts bounded ciphertext and rejects plaintext, wrong context metadata and strangers", async () => {
    const alice = environment.authenticatedContext("alice").firestore();
    const target = doc(alice, `${base}/messages/${messageIds.one}`);
    for (const invalid of [
      {...message(), text: "private"}, {...message(), replyToId: messageIds.two},
      {...message(), keyEpoch: 2}, {...message(), revision: 2}, {...message(), ciphertext: "plaintext"},
      {...message(), ciphertext: cipher(69633)}, {...message(), ciphertext: cipher(0)},
      {...message(), senderId: "bob"}, {...message(), clientId: messageIds.two},
      {...message(), type: "image"}, {...message(), delivery: "anything"},
    ]) await assertFails(setDoc(target, invalid));
    await assertFails(setDoc(doc(environment.authenticatedContext("mallory").firestore(), `${base}/messages/${messageIds.one}`), message()));
    await assertSucceeds(setDoc(target, message()));
    await assertSucceeds(getDoc(doc(environment.authenticatedContext("bob").firestore(), `${base}/messages/${messageIds.one}`)));
    await assertFails(getDoc(doc(environment.authenticatedContext("mallory").firestore(), `${base}/messages/${messageIds.one}`)));
  });
  it("requires sender-owned increasing edits and irreversible ciphertext-clearing unsend", async () => {
    const alice = environment.authenticatedContext("alice").firestore();
    const target = doc(alice, `${base}/messages/${messageIds.one}`);
    await assertSucceeds(setDoc(target, message()));
    await assertFails(updateDoc(target, {ciphertext: cipher(129), editedAt: serverTimestamp()}));
    await assertFails(updateDoc(target, {ciphertext: cipher(129), revision: 3, editedAt: serverTimestamp()}));
    await assertFails(updateDoc(doc(environment.authenticatedContext("bob").firestore(), target.path), {ciphertext: cipher(129), revision: 2, editedAt: serverTimestamp()}));
    await assertSucceeds(updateDoc(target, {ciphertext: cipher(129), revision: 2, editedAt: serverTimestamp()}));
    await assertFails(updateDoc(target, {revision: 3, deletedAt: serverTimestamp()}));
    await assertSucceeds(updateDoc(target, {ciphertext: cipher(0), revision: 3, deletedAt: serverTimestamp()}));
    await assertFails(updateDoc(target, {ciphertext: cipher(), revision: 4, editedAt: serverTimestamp()}));
    await assertFails(deleteDoc(target));
    await environment.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), target.path), {...message(), createdAt: Timestamp.now(), revision: Number.MAX_SAFE_INTEGER});
    });
    await assertFails(updateDoc(target, {ciphertext: cipher(0), revision: Number.MAX_SAFE_INTEGER + 1, deletedAt: serverTimestamp()}));
  });
  const sidecar = (size = 128) => ({...record(), senderId: "alice", ciphertext: cipher(size)});
  const createWithPreview = (id = messageIds.one, value: object = sidecar(), sender = "alice") => {
    const firestore = environment.authenticatedContext(sender).firestore();
    const batch = writeBatch(firestore);
    batch.set(doc(firestore, `${base}/messages/${id}`), message(id));
    batch.set(doc(firestore, `${base}/notificationPreviews/${id}`), value);
    return batch.commit();
  };
  it("accepts atomic bounded preview sidecars and preserves the old encrypted message schema", async () => {
    const alice = environment.authenticatedContext("alice").firestore();
    await assertFails(setDoc(doc(alice, `${base}/messages/${messageIds.one}`),
      {...message(), notificationPreview: cipher()}));
    await assertSucceeds(createWithPreview(messageIds.one, sidecar(1)));
    await assertSucceeds(createWithPreview(messageIds.two, sidecar(2048)));
    await assertSucceeds(setDoc(doc(alice, `${base}/messages/${messageIds.three}`), message(messageIds.three)));
    const stored = (await getDoc(doc(alice, `${base}/messages/${messageIds.one}`))).data();
    assert.equal(stored?.notificationPreview, undefined);
    assert.deepEqual(Object.keys(stored ?? {}).sort(), Object.keys(message()).sort());
    await assertSucceeds(getDoc(doc(environment.authenticatedContext("bob").firestore(),
      `${base}/notificationPreviews/${messageIds.one}`)));
    await assertFails(getDoc(doc(environment.authenticatedContext("mallory").firestore(),
      `${base}/notificationPreviews/${messageIds.one}`)));
    await assertFails(createWithPreview(messageIds.target, sidecar(), "bob"));
    await assertFails(createWithPreview(messageIds.target, sidecar(), "mallory"));
  });
  it("rejects orphan, late, mismatched and malformed notification preview sidecars", async () => {
    const alice = environment.authenticatedContext("alice").firestore();
    const target = doc(alice, `${base}/notificationPreviews/${messageIds.one}`);
    await assertFails(setDoc(target, sidecar()));
    for (const value of [
      ...[null, "private", [], {}, cipher(0), cipher(2049)].map((ciphertext) => ({...sidecar(), ciphertext})),
      {...sidecar(), senderId: "bob"}, {...sidecar(), keyEpoch: 2}, {...sidecar(), revision: 2},
      {...sidecar(), encryption: "future"}, {...sidecar(), text: "private"},
      {ciphertext: cipher()},
    ]) await assertFails(createWithPreview(messageIds.one, value));
    await assertFails(createWithPreview("NONCANONICAL", sidecar()));
    await assertSucceeds(setDoc(doc(alice, `${base}/messages/${messageIds.one}`), message()));
    await assertFails(setDoc(target, sidecar()));
  });
  it("keeps notification preview sidecars immutable while permitting ordinary message edits", async () => {
    const alice = environment.authenticatedContext("alice").firestore();
    await assertSucceeds(createWithPreview());
    const target = doc(alice, `${base}/notificationPreviews/${messageIds.one}`);
    await assertFails(updateDoc(target, {ciphertext: cipher(129)}));
    await assertFails(updateDoc(target, {revision: 2, ciphertext: cipher(129)}));
    await assertFails(setDoc(target, sidecar()));
    await assertSucceeds(updateDoc(doc(alice, `${base}/messages/${messageIds.one}`),
      {revision: 2, ciphertext: cipher(129), editedAt: serverTimestamp()}));
    assert.deepEqual((await getDoc(target)).data()?.ciphertext, cipher());
  });
  it("deletes notification previews only atomically with a sender-owned ciphertext-clearing unsend", async () => {
    const alice = environment.authenticatedContext("alice").firestore();
    await assertSucceeds(createWithPreview());
    const target = doc(alice, `${base}/notificationPreviews/${messageIds.one}`);
    const messageTarget = doc(alice, `${base}/messages/${messageIds.one}`);
    await assertFails(deleteDoc(target));
    await assertFails(deleteDoc(doc(environment.authenticatedContext("bob").firestore(), target.path)));
    const wrong = writeBatch(alice);
    wrong.delete(target);
    wrong.update(messageTarget, {revision: 2, ciphertext: cipher(129), editedAt: serverTimestamp()});
    await assertFails(wrong.commit());
    const correct = writeBatch(alice);
    correct.delete(target);
    correct.update(messageTarget, {revision: 2, ciphertext: cipher(0), deletedAt: serverTimestamp()});
    await assertSucceeds(correct.commit());
    assert.equal((await getDoc(target)).exists(), false);
    await assertFails(setDoc(target, sidecar()));
  });
  it("accepts old-client unsend without deleting its independent notification preview", async () => {
    const alice = environment.authenticatedContext("alice").firestore();
    await assertSucceeds(createWithPreview());
    await assertSucceeds(updateDoc(doc(alice, `${base}/messages/${messageIds.one}`),
      {revision: 2, ciphertext: cipher(0), deletedAt: serverTimestamp()}));
    const preview = doc(alice, `${base}/notificationPreviews/${messageIds.one}`);
    assert.deepEqual((await getDoc(preview)).data()?.ciphertext, cipher());
    // A subsequent request is not the atomic unsend and cannot erase sidecars.
    await assertFails(deleteDoc(preview));
  });
  it("retains encrypted reaction revisions and binds owner and target", async () => {
    const alice = environment.authenticatedContext("alice").firestore();
    await setDoc(doc(alice, `${base}/messages/${messageIds.one}`), message());
    const target = doc(alice, `${base}/reactions/${messageIds.one}--alice`);
    const value = {...record(), messageId: messageIds.one, userId: "alice", updatedAt: serverTimestamp()};
    await assertFails(setDoc(target, {...value, emoji: "private"}));
    await assertSucceeds(setDoc(target, value));
    await assertFails(updateDoc(target, {ciphertext: cipher(140), updatedAt: serverTimestamp()}));
    await assertSucceeds(updateDoc(target, {ciphertext: cipher(140), revision: 2, updatedAt: serverTimestamp()}));
    await assertFails(updateDoc(target, {messageId: messageIds.two, revision: 3, updatedAt: serverTimestamp()}));
    await assertFails(deleteDoc(target));
  });
  it("requires location consent and deletes the encrypted point atomically on opt-out", async () => {
    const alice = environment.authenticatedContext("alice").firestore();
    const point = doc(alice, `${base}/locations/alice`);
    const intent = doc(alice, `${base}/locationSharing/alice`);
    const source = {sourceDeviceId: "synthetic-phone-0001", sourceGeneration: 1};
    const value = {...record(), ...source, userId: "alice", updatedAt: serverTimestamp()};
    const consent = {userId: "alice", isSharing: true, ...source,
      sourceMutationId: "00000000-0000-4000-8000-000000000001", updatedAt: serverTimestamp()};
    await assertFails(setDoc(point, value));
    await setDoc(intent, consent);
    await assertFails(setDoc(point, {...value, latitude: 1}));
    await assertSucceeds(setDoc(point, value));
    await assertFails(setDoc(intent, {...consent, isSharing: false, sourceGeneration: 2, sourceMutationId: "00000000-0000-4000-8000-000000000002"}));
    await assertFails(updateDoc(point, {ciphertext: cipher(150), updatedAt: serverTimestamp()}));
    await assertSucceeds(updateDoc(point, {ciphertext: cipher(150), revision: 2, updatedAt: serverTimestamp()}));
    const batch = writeBatch(alice);
    batch.set(intent, {...consent, isSharing: false, sourceGeneration: 2, sourceMutationId: "00000000-0000-4000-8000-000000000002"});
    batch.delete(point);
    await assertSucceeds(batch.commit());
    await assertFails(setDoc(point, value));
  });
  it("accepts the 200 MiB encrypted envelope boundary and rejects one byte more", async () => {
    const alice = environment.authenticatedContext("alice").firestore();
    const target = doc(alice, `${base}/encryptedBlobs/${messageIds.attachment}`);
    const value = {ownerId: "alice", messageId: messageIds.one, keyEpoch: 1, revision: 1,
      digest: "a".repeat(64), createdAt: serverTimestamp()};
    await assertFails(setDoc(target, {...value, byteSize: 200 * 1024 * 1024 + 4097}));
    await assertSucceeds(setDoc(target, {...value, byteSize: 200 * 1024 * 1024 + 4096}));
  });

  // Apple's StorageMetadata serializes an unset customMetadata as JSON null;
  // JS omits it by default. Exercise both wire shapes plus an explicit empty map.
  for (const customMetadata of [undefined, null, {}]) {
    for (const defaults of [{}, {contentDisposition: "inline; filename*=utf-8''blob", contentEncoding: "identity"}]) {
      it(`accepts opaque immutable blobs with ${customMetadata === undefined ? "omitted" : JSON.stringify(customMetadata)} metadata, ${Object.keys(defaults).length ? "production headers" : "omitted headers"}, and rejects leaks`, async () => {
        const alice = environment.authenticatedContext("alice");
        const id = messageIds.attachment;
        const metadata = doc(alice.firestore(), `${base}/encryptedBlobs/${id}`);
        const value = {ownerId: "alice", messageId: messageIds.one, keyEpoch: 1, revision: 1,
          byteSize: 128, digest: "a".repeat(64), createdAt: serverTimestamp()};
        await assertFails(setDoc(metadata, {...value, fileName: "private.jpg"}));
        await assertFails(setDoc(metadata, {...value, byteSize: 200 * 1024 * 1024 + 4097}));
        await assertSucceeds(setDoc(metadata, value));
        await assertFails(updateDoc(metadata, {digest: "b".repeat(64)}));
        const blob = ref(alice.storage(), `${base}/encryptedBlobs/${id}/blob`);
        const bytes = new Uint8Array(128).fill(7);
        await assertFails(uploadBytes(blob, bytes, {contentType: "image/jpeg"}));
        await assertFails(uploadBytes(blob, bytes, {contentType: "application/octet-stream", customMetadata: {fileName: "private.jpg"}}));
        await assertFails(uploadBytes(blob, new Uint8Array(127), {contentType: "application/octet-stream"}));
        await assertFails(uploadBytes(ref(environment.authenticatedContext("bob").storage(), blob.fullPath), bytes, {contentType: "application/octet-stream"}));
        for (const extra of [
          {contentDisposition: 'attachment; filename="private.jpg"'},
          {contentEncoding: "private"},
        ]) await assertFails(uploadBytes(blob, bytes, {contentType: "application/octet-stream", ...extra}))
          .catch((error) => { throw new Error(`Header rejection failed: ${Object.keys(extra)[0]}`, {cause: error}); });
        await assertSucceeds(uploadBytes(blob, bytes, {
          contentType: "application/octet-stream",
          // Preserve the native JSON null shape despite the narrower JS SDK type.
          customMetadata: customMetadata as Record<string, string> | undefined,
          ...defaults,
        }));
        await assertFails(uploadBytes(blob, bytes, {contentType: "application/octet-stream"}));
        await assertSucceeds(getBytes(ref(environment.authenticatedContext("bob").storage(), blob.fullPath)));
        await assertFails(getBytes(ref(environment.authenticatedContext("mallory").storage(), blob.fullPath)));
        await assertSucceeds(deleteObject(blob));
        await assertSucceeds(deleteDoc(metadata));
      });
    }
  }
});
