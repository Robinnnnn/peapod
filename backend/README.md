# Peapod backend

Firebase Functions, Firestore rules and indexes, and Storage rules for one paired conversation. The backend manages invite claiming, pairing rate limits, push delivery, unread badges, retention, and orphaned attachment cleanup.

## Local setup

Use Node.js 22 and Java 21 or newer for the Firebase emulators. From `backend/functions`:

```sh
npm ci
npm test
npm run serve
```

The dependency versions and compatibility overrides are pinned in `functions/package.json` and its lockfile. The Firebase app overrides retain Node.js 22 support, the gRPC override avoids known transport advisories while preserving its v1 API, and the rimraf override updates an inherited cleanup dependency for Node.js 22.

The pinned Firebase CLI runs against the synthetic `demo-peapod` project. No production credentials are needed. Emulator ports are configured in the root `firebase.json`; use separate ports if another local session owns them.

## Checks

From `backend/functions`:

```sh
npm run test:rules
npm run test:message-pins
npm run test:secure-pairing
npm run test:pairing
npm run test:badge
```

`test:rules` includes Firestore and Storage membership, message and attachment permissions, plus encrypted location ownership. Additional suites cover pin authorization, secure invite races, callable pairing, and badge lifecycle behavior. Tests create only synthetic users, IDs, messages, and byte arrays in local emulators. They clear their demo project data; run them on emulators owned by your session.

## Firebase project setup

Create your own Firebase project and configure its Apple clients as described in the main README. Enable the required Authentication providers, Firestore, Cloud Storage, and Cloud Messaging. Cloud Functions use Node.js 22 in `us-west1`; scheduled cleanup requires billing and the associated Google Cloud APIs. Review the rules, indexes, retention policy, and Functions before deploying them to your project. Do not point emulator tests at a live project.

Clients cannot create conversations or change membership directly. Pairing callables own these transitions. Firestore and Storage require active conversation membership; encrypted uploads additionally bind opaque objects to owner-authored metadata. Encryption markers such as `mines-e2ee-v1` are retained protocol identifiers used by the clients. Legacy unencrypted conversation support remains in the rules and backend; it does not provide the same privacy guarantees as encrypted conversations. Push previews follow the message encryption contract. Retired conversation-removal callables remain exported to reject older clients safely, and their retained deletion trigger performs no deletion.

Deployments, Apple notification configuration, and production data migration are outside the local test commands. Never commit service-account keys, Firebase CLI tokens, Functions environment files, or user data.

## Dependency audit

The 2026-11-08 lockfile audit reports no production advisories, 11 moderate development advisories from four upstream issues, and no high-severity advisories. The pinned Firebase CLI still inherits moderate advisories in [OpenTelemetry Core](https://github.com/advisories/GHSA-8988-4f7v-96qf), [glob](https://github.com/advisories/GHSA-3g3m-2fjr-6pw4), [minimatch](https://github.com/advisories/GHSA-g3hv-75wg-m249), and [uuid](https://github.com/advisories/GHSA-w5hq-g745-h8pq). Its current dependency ranges do not accept the fixed major versions. Those CLI dependencies are development-only; deployment, archive, and provider paths have not been verified with forced major overrides. Recheck `npm audit` before using the CLI against a real project.
