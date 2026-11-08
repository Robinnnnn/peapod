# Security

Peapod is experimental messenger software. The encryption implementation has
not received an independent security audit. This repository supplies source,
not a hosted service or a guarantee of production security.

## Encrypted conversations

Configured native clients require secure pairing for new sessions. Invitations
are bearer authorization: send the complete invitation only to the intended
person through a trusted channel. Display names do not verify identity.
The two participants share conversation key material; this is not a protocol
that proves authorship against the other participant holding that key.

Message content, attachments, encrypted location, and notification-preview
sidecars are encrypted before upload. Apple CryptoKit provides the primitives.
Each person's trusted conversation capsule synchronizes through that person's
iCloud Keychain. Missing keys block encrypted operations; they must not select
a plaintext fallback or reset the conversation automatically.
The iPhone and Mac notification service extensions use the active App Group
route and E2EE Keychain group to attempt local preview decryption. They have no
shared-auth Keychain entitlement and retain generic alert text when the route,
key, or authenticated record cannot be verified.

Backend and push operators still see account identifiers, membership, routing,
message timing, record sizes, device/push tokens, and delivery metadata.
Profile display names are plaintext, including the notification title sent
through FCM/APNs. Typing, read and pin state, location-sharing status and source
device IDs, and sign-in email are also visible to the relevant backend operators.
Third-party link previews make network requests and are not an anonymity tool.
Endpoint compromise, screenshots, clipboard contents, exported media, and the
other participant's behavior are outside content encryption's protection.

## Legacy paths

Legacy plaintext messages and location paths remain in source and Firebase
rules for compatibility. Those records are readable by backend operators.
An encrypted client does not retroactively encrypt existing plaintext history.
The private AI feedback pipeline and its client screen are not included.

## Deployment responsibilities

- Supply your own Apple signing identity and Firebase project. Keep service
  account keys, APNs keys, and local signing configuration outside Git.
- Deploy matching rules and Functions together; verify membership isolation
  with emulators before use. Do not relax rules to make an upload work.
- App Check enforcement is currently off. iPhone configures App Attest;
  simulators use the debug provider. Native Mac needs a custom attestation
  solution before enforcement can be enabled across both clients.
- Review account abuse, quotas, rate limits, billing alerts, retention, and
  administrative access for your deployment. A Firebase client config is not
  a server credential; authorization must come from rules and authenticated
  server policy.
- Account sign-out preserves the paired connection and history. There is no
  user-facing whole-conversation deletion flow in this snapshot. Establish
  an appropriate operator data-management policy before running a service.

## Reporting vulnerabilities

Use this repository's GitHub **Security → Report a vulnerability** feature.
Do not put keys, real conversation contents, personal coordinates, or usable
invitation links in public issues. Include the affected source revision and
synthetic reproduction steps when possible.
