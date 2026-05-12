# SyncingKeys example app

A minimal Flutter app that exercises the SyncingKeys SDK end-to-end. Tap
the buttons on the home screen to:

- generate a Starknet key (id: `main`),
- generate an Ethereum key (id: `eth`),
- read the `main` key back (falls back to the cloud if the local copy is gone),
- delete `main` from local + cloud.

## Configure before you run

The example ships with placeholder identifiers — replace them with your own
before launching against a real device:

1. Open `example/lib/main.dart` and update the two top-level constants:

   ```dart
   const String _iosKeychainGroup = 'group.com.example.shared';
   const String _driveClientId    = 'REPLACE-ME.apps.googleusercontent.com';
   ```

   - **`_iosKeychainGroup`** — match the Keychain Sharing group you added in
     Xcode (Signing & Capabilities). See the SDK's
     [`INTEGRATION.md`](../INTEGRATION.md#3-ios--xcode-capabilities) §3 for
     the exact steps.
   - **`_driveClientId`** — an Android OAuth 2.0 Client ID bound to **this
     example's package name + your debug keystore's SHA-1**. See
     [`INTEGRATION.md`](../INTEGRATION.md#2-android--google-cloud-console--drive-api)
     §2 for the full Google Cloud Console walk-through.

2. iOS only — open `example/ios/Runner.xcworkspace` once and enable
   **Keychain Sharing** + **iCloud → Key-value storage** on the Runner
   target. Re-download the provisioning profile from developer.apple.com
   if you change the App ID.

3. Run it:

   ```bash
   cd example
   flutter run
   ```

## What you should see

- Tapping **Generate Starknet key** opens the PIN entry sheet. After you
  enter a PIN, the app shows the generated 0x-prefixed Starknet address.
- Tapping **Read "main"** on a fresh install (or after deleting local
  storage) shows a "Fetching from cloud…" dialog while the SDK pulls the
  encrypted envelope from iCloud / Drive, then prompts for the PIN.
- Tapping **Delete "main"** wipes both the local row and the cloud copy.

If "Read" reports a `KeyNotFoundException`, the cloud has nothing under
that id — make sure you ran "Generate Starknet key" first and that
`syncEnabled: true` was set in `GlobalConfig`.
