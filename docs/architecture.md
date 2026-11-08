# Architecture

## Client composition

`MinesApp.swift` (iPhone) and `MinesMacApp.swift` (Mac) compose the native app
models. The source filenames are retained implementation names; generated apps
and schemes are Peapod and PeapodMac. SwiftUI renders platform-specific
conversation surfaces, while shared models/services own common contracts.

Firebase authentication establishes the account. Profile assignment selects
its one active conversation. `EncryptedAppServices` coordinates secure pairing,
iCloud-synchronized key readiness, encrypted message transport, attachment
resolution, and account/conversation lifecycle. Late results must remain bound
to the account and conversation that requested them.

## Pairing and keys

A private invitation authorizes a second account to join. The creator and
recipient exchange authenticated protocol records through callable Functions
and Firestore. A trusted conversation capsule binds participants, conversation,
key epoch, commitments, and key material. Each participant stores their capsule
in their own synchronizable Keychain namespace; Apple, not Firebase, supplies
that participant's cross-device Keychain synchronization.

`packages/MinesE2EE` contains the protocol encodings, CryptoKit operations,
Keychain storage, readiness/session rules, and durable SQLite outbox. Its
`Tests` directory contains focused synthetic protocol/storage checks, including
deterministic vectors. These are not real keys or accounts. The library module
and protocol IDs remain `MinesE2EE` / `mines-e2ee-v1` so exporting and renaming
the app do not rewrite authenticated bytes.

## Messaging and attachments

The app submits encrypted content to a durable outbox. Firebase transports
relay ciphertext and metadata to Firestore and encrypted blobs to Storage.
Recipients resolve current account membership and keys before decrypting.
Photo display renditions and original media are distinct encrypted resources;
original saving preserves original bytes. A bounded persistent photo cache
holds ciphertext, while decoded/decrypted display state is session-scoped.

The backend handles invitation state, message notifications, shared read
position and absolute unread badges, unsent attachment cleanup, and orphan
attachment cleanup. Firestore and Storage rules enforce participant membership
and per-record constraints. Admin SDK Functions are a separate trusted server
boundary and must enforce their own invariants.

## Cross-process delivery

Share extensions use an App Group for staged input and a durable encrypted
handoff, and the containing app drains the outbox. Share checks authentication,
current profile assignment, conversation membership, protocol mode, and the
native key capsule before accepting content. Its REST project ID comes from
that extension's Firebase options.

The iPhone notification service extension decrypts bounded preview sidecars
locally. Missing keys or a deadline retain a generic notification. Mac sends
compatible encrypted preview data but displays generic notification content.
The notification extension has E2EE access but no shared-auth entitlement.

## Location

Location sharing is opt-in and owned by one explicitly selected iPhone per
participant. The encrypted latest point replaces the previous point; it is
not a server-side movement history. Mac reads phone-shared points and age
labels rather than sampling or publishing the Mac's position.

## Scope and verification

The public snapshot excludes private feedback processing, autonomous coding
workers, release operations, debug galleries, synthetic app launch modes, and
UI-test hosts. Focused crypto/package and backend unit/rules/integration tests
remain. A passing package or emulator suite does not establish physical-device
APNs, iCloud sync, microphone, or full media acceptance.

Legacy plaintext services and wire shapes remain where the implementation
still uses them for compatibility. Their presence must not be described as
end-to-end encrypted. See [SECURITY.md](../SECURITY.md).
