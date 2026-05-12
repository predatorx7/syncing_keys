# SyncingKeys SDK · `syncing_keys`

> **Set-and-forget secure key management & cross-device syncing for Starknet/Ethereum Flutter apps.**

SyncingKeys gives blockchain developers a single API that handles private key
generation, on-device storage, and **automatic** cross-device sync — without
ever asking the developer to call `backup()` or `restore()`. The CRUD methods
do the right thing based on configuration.

```dart
await SyncingKeys.initialize(GlobalConfig(
  iosKeychainGroup: 'group.com.acme.shared',
  androidDriveClientId: '12345-abc.apps.googleusercontent.com',
  syncEnabled: true,
), navigatorKey: navKey);

final stark = await SyncingKeys.generateStarknetKey(id: 'main');
// stark.publicAddress is ready to use; the private key is already
// PIN-encrypted, stored locally, and replicated to iCloud / Drive.
```

## Core philosophy

| Pillar         | What it means in code                                                                      |
| -------------- | ------------------------------------------------------------------------------------------ |
| **Abstraction**| `saveKey` / `getKey` / `deleteKey` are the **only** CRUD entry-points.                     |
| **Security**   | Private keys never leave the device unencrypted. PBKDF2(PIN) → AES-256-GCM envelope.       |
| **Seamless UI**| A themable `PinEntryOverlay` handles the encrypt/decrypt handshake internally.             |

## What's inside

- **Pure-Dart key generators** — secp256k1 BIP-44 (Ethereum) and the STARK
  curve (Starknet, Pedersen/Poseidon-compatible).
- **PIN-wrapped envelope** — versioned JSON, AES-256-GCM, PBKDF2-HMAC-SHA256.
- **iOS native** — Keychain with `kSecAttrAccessGroup` and
  `kSecAttrSynchronizable = true` for iCloud Keychain sync.
- **Android native** — EncryptedSharedPreferences for local + Drive REST API
  on the `appDataFolder` scope for cloud.
- **Themable PIN UI** — animated bottom sheet with biometric pre-gate.

---

## Configuration cheat-sheet

`GlobalConfig` has two identifiers you'll need to obtain once per app. Set
`syncEnabled: false` if you don't want cloud sync yet — both fields then
become optional and can stay `null`.

### 🍎 `iosKeychainGroup` — the iOS Keychain Sharing access group

**What it is.** A string that scopes Keychain rows to *your* apps. The SDK
attaches it to every Keychain item via `kSecAttrAccessGroup` so that:

- your wallet app + watch companion + iOS extension can all read the same key,
- the item survives certain OS-level restore paths that scope-less items don't.

**Format.** `<TeamID>.<bundle-id-or-shared-group-name>` — but you only pass
the suffix. iOS prepends your Team ID automatically from the entitlement.

```dart
iosKeychainGroup: 'com.acme.wallet'        // single app
iosKeychainGroup: 'group.com.acme.shared'  // shared across your suite
```

**How to obtain it:**

1. Open your iOS project in **Xcode** → app target → **Signing & Capabilities**.
2. **+ Capability → Keychain Sharing** → click **+** and type the identifier
   (e.g. `group.com.acme.shared`). Xcode writes it into your `.entitlements`.
3. Pass the same string to `GlobalConfig.iosKeychainGroup`.
4. *(For cross-app sharing)* On developer.apple.com → **Identifiers** → your
   App ID → enable **Keychain Sharing** and re-download the provisioning profile.

> **Tip:** Leave it `null` to fall back to the calling app's default access
> group. That's fine for single-app installs.

### 🤖 `androidDriveClientId` — the Google OAuth 2.0 Client ID

**What it is.** A string like
`123456789012-abcde1f2g3h4i5j6.apps.googleusercontent.com`. It identifies
your app to Google's OAuth server so the SDK can mint a short-lived access
token for the Drive REST API and store encrypted envelopes in the user's
hidden `appDataFolder`.

The Client ID is bound to two things, which means a stolen ID is useless to
anyone else — they can't sign builds as you:

- your Android **package name** (e.g. `com.acme.wallet`)
- the **SHA-1 fingerprint** of your app's signing certificate

**How to obtain it:**

1. Open https://console.cloud.google.com/ → **Select a project → New Project**.
2. **APIs & Services → Library** → search **Google Drive API** → **Enable**.
3. **APIs & Services → OAuth consent screen** → app name, support email, add
   the `…/auth/drive.appdata` scope (and **only** that), add yourself as a test
   user.
4. **APIs & Services → Credentials → Create Credentials → OAuth client ID**.
5. **Application type:** Android.
6. **Package name:** your app's `applicationId`.
7. **SHA-1:** paste the fingerprint of your signing cert.

   ```bash
   # Debug builds
   keytool -list -v -keystore ~/.android/debug.keystore \
       -alias androiddebugkey -storepass android -keypass android | grep SHA1

   # Or from your app's android/ folder
   ./gradlew signingReport | grep SHA1
   ```

   For Play releases, get the **Play App Signing SHA-1** from the Play
   Console (*App integrity → App signing*) and create a **second** Client ID
   with that SHA-1.

8. Click **Create**, copy the resulting string into
   `GlobalConfig.androidDriveClientId`.

> **Tip:** Create one Client ID per signing key (debug + release) and select
> the right one per build flavor — otherwise your release build will silently
> fail to authenticate.

### Putting it together

```dart
await SyncingKeys.initialize(
  const GlobalConfig(
    iosKeychainGroup: 'group.com.acme.shared',                    // from Xcode
    androidDriveClientId: '12345-abc.apps.googleusercontent.com', // from Cloud Console
    syncEnabled: true,
  ),
  navigatorKey: navKey,
);
```

For step-by-step screenshots and the full production checklist (release
SHA-1, OAuth consent screen submission, Info.plist additions, threat model),
see [`INTEGRATION.md`](./INTEGRATION.md).

---

## Getting started (TL;DR)

1. Add the plugin to your `pubspec.yaml`.
2. Enable **Keychain Sharing** and **iCloud** capabilities in Xcode.
3. Register an Android **OAuth Client ID** in Google Cloud Console and enable
   the Drive API.
4. Call `SyncingKeys.initialize(GlobalConfig(...))` once at app start.
5. Use `SyncingKeys.generateStarknetKey(id: 'main')` (or `generateEthereumKey`,
   or `saveKey/getKey/deleteKey`). That's it.

## Releases

See [`CHANGELOG.md`](./CHANGELOG.md) for per-version notes. The current
version is 0.1.0 (pre-release).

## License

[Apache-2.0](./LICENSE) © 2026 everydayapp.xyz
