# Initial snapshot verification

Verified locally on November 8, 2026, with Xcode 27 and Node 22:

- XcodeGen project generation without a Firebase plist.
- iPhone Simulator Debug compilation, including Share and notification extensions,
  with signing disabled; no simulator launch or account access.
- Mac Debug compilation, including the Mac Share extension, with signing disabled.
- Swift crypto-package suite: 150 tests, 2 intentionally skipped, zero failures.
- Backend: 50 unit tests and 77 local emulator rule/integration tests.
- Expanded identity/plist checks for all five app/extension targets, including
  rejection of malformed and mismatched Keychain namespaces.
- Tracked-source private-marker checks and Gitleaks tree/history scans. The
  scanner configuration narrowly allows the two reviewed deterministic vector
  keys and a typed property declaration; it does not blanket-ignore test files.
- Ancillary image metadata removed from icon PNGs while preserving their
  compressed pixel data. No credentials, personal message screenshots, private
  Git history, or sample-media fixtures are included.

These results establish source compilation and focused non-live behavior.
They do not establish signed physical-device operation, iCloud Keychain sync,
Sign in with Apple, APNs delivery, microphones, or full media interoperability
in a new deployment. Those depend on your Apple/Firebase configuration.
No hosted backend was deployed and no release was uploaded.

Reproduce checks using the commands in README.md and backend/README.md.

## Public cleanup verification

The follow-up cleanup on November 8, 2026 passed:

- iPhone Simulator and Mac Debug builds, including their extensions.
- Inspection of both compiled app asset catalogs: `SnowfallFlakeA` and
  `SnowfallFlakeB` are bundled. The existing iPhone animation and native Mac
  motion behavior are unchanged.
- Built Info.plists register `peapod`; invite generation/parsing, both app
  handlers, the join field, and Share handoff use that same scheme.
- An executable check of the actual invite parser accepts the canonical
  Peapod URL and bare fragment, and rejects nine malformed/old-scheme inputs.
- The 150-test crypto package suite (two skips, zero failures); cryptographic
  protocol source and domain-separation bytes were unchanged.
- The generic public-source checker passed 16 isolated fixture cases. Its
  policy contains no private installation identifiers.
- The two additional CI commands passed locally: nine secure-pairing emulator
  tests and eight message-pin authorization tests. Workflow lint passed.

CI now also scans the complete checked-out Git history using the pinned,
Gitleaks CLI, built from version-pinned, module-checksummed Go source. Checks remain focused on source, packages,
services, and resources; no automated UI suite or live account was used.
