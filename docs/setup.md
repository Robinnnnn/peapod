# Configuration and deployment

Peapod does not ship a Firebase project, signing keys, or a hosted account.
Use a new project and Apple identifiers you control. Do not reuse somebody
else's app group or Keychain namespace.

## Apple identities

Copy `Configurations/Local.xcconfig.example` to
`Configurations/Local.xcconfig` and uncomment/set your values:

```xcconfig
DEVELOPMENT_TEAM = YOURTEAMID
PEAPOD_BUNDLE_ID = com.yourorganization.peapod
```

`Configurations/Peapod.xcconfig` supplies the derived app group and Keychain
suffixes. The local override is gitignored. Regenerate with `xcodegen generate`
after changing configuration. The public `org.example.peapod` namespace is an
example, not an identifier registered for you.

Register these bundle identifiers with your Apple team:

| Target | Identifier |
| --- | --- |
| Peapod / PeapodMac | your base bundle ID (the same on both platforms) |
| PeapodShare | base + `.share` |
| PeapodMacShare | base + `.mac-share` |
| PeapodNotificationService | base + `.notification-service` |
| PeapodMacNotificationService | base + `.mac-notification-service` |

Enable the matching capabilities in your developer account and provisioning:
Sign in with Apple, Push Notifications, the shared App Group, and the relevant
communication/time-sensitive notification and App Attest capabilities declared
in `project.yml`. The Mac apps use sandboxing and their declared file/network/
audio entitlements. Both people need iCloud Keychain enabled for key sync.

The main apps and Share extensions share the auth Keychain group. All six
targets share the E2EE group. Neither notification extension receives the auth
Keychain entitlement. Assign the Mac notification extension to the same App
Group as the Mac app before creating its distribution provisioning profile.
Keep those boundaries intact.
Xcode expands `AppIdentifierPrefix` from provisioning into both entitlements
and Info.plist configuration; Swift validates those expanded identities.
Do not substitute an assumed team ID for an App ID prefix or add a fallback
Keychain group when an entitlement is missing.

Both apps register `peapod`, and invitations and Share handoffs use `peapod://`.
A custom scheme is not exclusive to an app: send invitations only through a
trusted channel and confirm joins. The routing prefix is separate from the
unchanged encryption suites and domain-separation strings.

## Firebase

1. Create a Firebase project you control. Deploying Functions and using the
   associated cloud services may require a billing-enabled project.
2. Register the shared main Apple bundle ID. Download its
   `GoogleService-Info.plist` into `apps/ios/App/Resources/`. XcodeGen includes
   it when present in the iPhone, Mac, and Share targets. Never commit it here.
3. Enable Authentication with Sign in with Apple. Configure the provider for
   your own Apple developer account and app identifiers.
4. Set up Firestore and Cloud Storage. Functions and clients use `us-west1`;
   if changing that region, change the corresponding callable transport and
   backend declarations together.
5. Configure Cloud Messaging with your own APNs authentication key. Keep that
   key outside Git. Verify both app registration and notification capabilities.
6. From the repo root, choose your project explicitly:

   ```sh
   cd backend/functions
   npm ci
   npx firebase login
   npx firebase use --add --config ../../firebase.json
   ```

7. After reviewing rules and passing local tests, deploy deliberately with an
   explicit project argument from `backend/functions`:

   ```sh
   npx firebase deploy --config ../../firebase.json --project YOUR_PROJECT_ID \
     --only firestore,storage,functions
   ```

The Storage rules consult Firestore membership. Accept/review Firebase's
cross-service permission setup so the Storage service account can evaluate
Firestore-backed rules. Do not bypass membership checks if an upload fails.
Do not commit the local project alias file or credentials produced by setup.

Read [backend/README.md](../backend/README.md) for local emulator commands and
[SECURITY.md](../SECURITY.md) for App Check limitations. Backend deployment is
not a substitute for signed-device acceptance of Apple sign-in, invitation
handoff, iCloud Keychain sync, Share extensions, APNs, or media behavior.

## Distribution

Build and archive using your own signing/provisioning and App Store Connect
records. This repository includes no upload automation, TestFlight group,
export-compliance assertion, or release credential restoration. Determine those
requirements for your own app and distribution. Never install an unrelated
fork over an existing user's app identity just to test it.
