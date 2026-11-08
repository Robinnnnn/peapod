# Peapod

A native iPhone and Mac messenger for **one connection and one conversation**.

Peapod opens to the person you paired with. There is no inbox, group chat,
contact list, discovery feed, or social graph. It works for friends, family,
partners, or any other pair who want a dedicated line.

This is a standalone source snapshot. Development continues separately;
updates here may be occasional. There is no hosted service, public beta,
or automatic connection to the author's infrastructure.

## What it does

- Sign in with Apple and secure invitation-based pairing.
- Encrypted messages, photos, videos, files, and voice notes.
- Replies, edits, unsend, reactions, pins, search, typing, and read receipts.
- Native Share extensions, durable sending queues, and notification actions.
- On-device iPhone notification-preview decryption, with generic fallback.
- Optional location sharing from one designated iPhone per person; Mac views
  the phone's shared location and never publishes its own.
- Shared artwork and conversation behavior, with native Mac windowing,
  keyboard interaction, selection, and media controls.

Both people need accounts in **your** Firebase deployment. Keys synchronize
between each person's Apple devices through their own iCloud Keychain.
Read [the security model](SECURITY.md) before relying on the implementation.
The encryption has not received an independent security audit.

### From one person to the other

In an already-paired **encrypted conversation**, the apps encrypt and decrypt
locally. Your Firebase deployment stores and relays ciphertext.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/diagrams/message-flow-dark.svg">
  <img src="docs/diagrams/message-flow-light.svg" alt="Person A and Person B each sync keys through their own iCloud Keychain. Messages are encrypted locally and relayed through your Firebase deployment. Cloud Functions sends iPhone alerts through FCM and APNs; Person B decrypts locally.">
</picture>

Secure pairing establishes the conversation key; each person's **own iCloud
Keychain** synchronizes their key capsule across their Apple devices. Firebase
Auth and access rules restrict message and attachment access to the paired accounts.

For alerting messages, Cloud Functions sends a push through **FCM → APNs** to
the recipient's iPhone. Notification previews are decrypted on the iPhone when
keys are available; otherwise the alert body stays generic. Backend operators can
still see routing and delivery metadata.

## Requirements

For the apps: macOS, Xcode 26 or newer with Swift 6, and
[XcodeGen](https://github.com/yonaskolb/XcodeGen). Deployment targets are
**iOS 18** and **macOS 15**. Full device functionality needs your own Apple
Developer account, registered capabilities, and Firebase project.

For the backend: **Node 22**, **Java 21 or newer**, and npm. The backend installs
its Firebase CLI locally. Emulator tests do not need a production project;
initial package and emulator downloads require network access.

## Build the apps

1. Clone this repository and install XcodeGen (`brew install xcodegen`).
2. Follow [configuration and deployment](docs/setup.md) to choose your Apple
   identifiers and supply your own Firebase client configuration.
3. Generate and open the project:

   ```sh
   xcodegen generate
   open Peapod.xcodeproj
   ```

4. Select **Peapod** for iPhone or **PeapodMac** for Mac. Configure signing with
   your own account, then build and run.

You can compile without a signing account or Firebase configuration:

```sh
xcodebuild -project Peapod.xcodeproj -scheme Peapod \
  -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Peapod.xcodeproj -scheme PeapodMac \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

These commands establish compilation only. Without Firebase configuration the
normal app shows a configuration error; this export does not bundle a demo
account, a live project, or a synthetic conversation. Apple authentication,
shared Keychain access, notifications, and iCloud key synchronization require
properly signed apps and configured services.

## Run focused checks

The retained checks cover cryptographic records and pairing, durable outbox
behavior, backend policies, and database/storage authorization. Debug galleries,
click-through suites, private feedback automation, live-account fixtures, and
release machinery are deliberately excluded.

```sh
swift test --package-path packages/MinesE2EE
cd backend/functions
npm ci
npm test
npm run test:rules
```

Additional local emulator integration commands are listed in
[backend/README.md](backend/README.md). No test should need the author's
credentials or contact a production deployment. Do not point test commands at
real accounts. There is no automated UI-test gate. The current dependency audit and remaining
CLI-only advisories are documented in [backend/README.md](backend/README.md#dependency-audit).

## Repository layout

| Path | Purpose |
| --- | --- |
| `apps/ios/App` | iPhone app composition, model, timeline, composer, media, location, and notifications |
| `apps/ios/ShareExtension` | iPhone Share extension |
| `apps/ios/NotificationServiceExtension` | On-device encrypted notification-preview handling |
| `apps/macos/App` | Mac app composition, native presentation, platform services, and media |
| `apps/macos/ShareExtension` | Mac Share extension metadata |
| `shared/Sources` | Shared models, Firebase transports, authentication, pairing, encryption routing, appearance, and caching |
| `shared/ShareExtension` | Shared cross-process Share queue and delivery implementation |
| `shared/Resources` | App artwork and privacy manifest |
| `packages/MinesE2EE` | Local Swift package for cryptographic records, pairing, Keychain capsules, SQLite outbox, and package tests |
| `backend/functions` | Firebase Functions for pairing, notification delivery, unread badges, and attachment cleanup |
| `backend/*.rules` | Firestore and Storage authorization rules |
| `Configurations` | Public identity defaults and local override example |
| `project.yml` | XcodeGen target, dependency, entitlement, and build configuration |

The Swift module name `MinesE2EE` and `mines-e2ee-v1` protocol identifiers are
retained for wire compatibility. They are not remote services. See
[architecture](docs/architecture.md) for the main data flows and boundaries.

## Hosting and distribution

You operate the Firebase project and pay its costs. Deploying backend code,
enabling Apple capabilities, configuring APNs, and distributing signed builds
are separate from cloning source. No deployment runs during setup or CI.

## Contributing and license

Bug fixes and focused improvements are welcome. Keep the one-connection
product boundary; see [CONTRIBUTING.md](CONTRIBUTING.md).

Code and contributed app artwork are available under the [MIT license](LICENSE).
You may copy, modify, redistribute, and sell your own version while preserving
the license notice. Dependencies retain their own licenses; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
