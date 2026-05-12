# SyncingKeys SDK — Integration Guide

> One Flutter plugin. Two platforms. Zero "backup" calls.

This document covers everything a developer needs to ship SyncingKeys in a
production Flutter app: Google Cloud Console setup, Xcode capabilities,
manifest/Info.plist entries, and a 10-line usage example.

---

## 1. Add the dependency

```yaml
# pubspec.yaml of your app
dependencies:
  syncing_keys:
    path: ../path/to/syncing_keys   # or git: / hosted reference
```

Run:

```bash
flutter pub get
cd ios && pod install && cd ..
```

---

## 2. Android — Google Cloud Console & Drive API

The Android cloud-sync path uses the Drive **REST API** scoped to the
`drive.appdata` hidden folder. Files there are invisible in the user's Drive
UI and only accessible by the OAuth client that uploaded them.

### 2.1 Create / select a Google Cloud project

1. Open https://console.cloud.google.com/ → **Select a project → New Project**.
2. Give it a name (e.g. *MyWallet*) and a billing account if prompted.

### 2.2 Enable the Drive API

1. APIs & Services → **Library** → search **Google Drive API** → **Enable**.

### 2.3 Configure the OAuth consent screen

1. APIs & Services → **OAuth consent screen**.
2. User type: **External** (or Internal if you're on Workspace).
3. App name, support email, dev contact — required.
4. **Scopes** → Add `…/auth/drive.appdata` (and nothing else — minimal scope!).
5. Add your test users while the app is in *Testing*.

### 2.4 Create the Android OAuth 2.0 Client ID

1. APIs & Services → **Credentials** → **Create Credentials → OAuth client ID**.
2. Application type: **Android**.
3. Package name: your app's id (e.g. `com.acme.wallet`).
4. SHA-1 certificate fingerprint:

   ```bash
   # Debug builds
   ./gradlew signingReport
   # …or directly
   keytool -list -v -keystore ~/.android/debug.keystore \
       -alias androiddebugkey -storepass android -keypass android
   ```

   Add the resulting `SHA1` to the credential. **You must register one Client
   ID per signing certificate** — see the next section.
5. Copy the Client ID — that's the value you pass to
   `GlobalConfig.androidDriveClientId`.

### 2.5 Pick the right Client ID per build flavor

A Client ID is bound to **(package name, SHA-1)**. That means a release build
signed with the Play upload key will fail to authenticate against a Client ID
registered with your debug keystore's SHA-1. Register one Client ID for each
keystore you build with, then select the right one at compile time:

| Build         | Keystore                     | How to get its SHA-1                                 |
| ------------- | ---------------------------- | ---------------------------------------------------- |
| Debug         | `~/.android/debug.keystore`  | `keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android` |
| Internal/QA   | Your team-shared upload key  | `keytool -list -v -keystore upload-keystore.jks -alias upload`                                   |
| Production    | **Play App Signing**         | Play Console → *App integrity* → *App signing* → copy the SHA-1 from the *App signing key certificate* block |

Wire the right ID per flavor with Gradle BuildConfig fields, then read it from
Dart via a small constants file:

```kotlin
// android/app/build.gradle.kts
android {
    buildTypes {
        debug   { buildConfigField("String", "DRIVE_CLIENT_ID", "\"12345-debug.apps.googleusercontent.com\"") }
        release { buildConfigField("String", "DRIVE_CLIENT_ID", "\"67890-prod.apps.googleusercontent.com\"")  }
    }
}
```

…and surface it to Dart at startup (e.g. via a one-method `MethodChannel`).
Alternatively, just use `--dart-define=DRIVE_CLIENT_ID=…` per build:

```bash
flutter build apk --release \
    --dart-define=DRIVE_CLIENT_ID=67890-prod.apps.googleusercontent.com
```

```dart
const _driveClientId = String.fromEnvironment('DRIVE_CLIENT_ID');
```

### 2.6 Trigger the Google account picker on first run

The plugin lazily requests an access token, so the first time the user opts
into cloud sync you have to surface the Google account picker. The SDK
exposes it directly:

```dart
final granted = await SyncingKeys.signInToCloud();
if (!granted) {
  // User cancelled. Show your own "Cloud sync paused" UI.
}
```

`signInToCloud()` is idempotent — it fast-paths to `true` if an account is
already cached. To later forget the account (e.g. on user sign-out):

```dart
await SyncingKeys.signOutOfCloud();
```

You can also let the official `google_sign_in` Flutter plugin handle the
picker with the `drive.appdata` scope; SyncingKeys will pick up the cached
account automatically via `GoogleSignIn.getLastSignedInAccount`.

### 2.7 Android manifest additions

The plugin's own manifest already declares:

* `INTERNET`
* `GET_ACCOUNTS`
* `USE_BIOMETRIC`, `USE_FINGERPRINT`

You do not need to re-declare them in your app's manifest.

---

## 3. iOS — Xcode capabilities

The iOS cloud-sync path uses **iCloud Keychain** via
`kSecAttrSynchronizable = true`. Apple handles the cross-device propagation
end-to-end encrypted; the only ceremony is enabling the right capabilities.

### 3.1 Enable Keychain Sharing

1. Open your app's iOS project in Xcode → select the **Runner** target
   (or your app's target).
2. **Signing & Capabilities** → **+ Capability** → **Keychain Sharing**.
3. Add an access group like `group.com.acme.shared`.

   This becomes the value you pass to `GlobalConfig.iosKeychainGroup`. It
   must start with your Team ID prefix in the final entitlement, but in the
   `GlobalConfig` you just pass the bare group name — the OS prepends the
   prefix automatically when running on device.

### 3.2 Enable iCloud / Keychain sync entitlement

1. Same screen → **+ Capability** → **iCloud**.
2. Check **Key-value storage** (no extra cost; this is what activates the
   iCloud Keychain bridge for `kSecAttrSynchronizable` items).

### 3.3 Apple Developer Portal

Make sure the App ID has both **Keychain Sharing** and **iCloud** enabled in
*Identifiers* on developer.apple.com. Re-download the provisioning profile
after editing.

### 3.4 Info.plist additions

```xml
<!-- Used by local_auth for the optional biometric pre-gate -->
<key>NSFaceIDUsageDescription</key>
<string>Used to unlock your encrypted keys.</string>
```

---

## 4. Usage example (10 lines)

```dart
import 'package:flutter/material.dart';
import 'package:syncing_keys/syncing_keys.dart';

final navKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SyncingKeys.initialize(
    GlobalConfig(
      iosKeychainGroup: 'group.com.acme.shared',
      androidDriveClientId: '12345-abc.apps.googleusercontent.com',
      syncEnabled: true,
    ),
    navigatorKey: navKey,
  );
  runApp(MaterialApp(navigatorKey: navKey, home: const Home()));
}

class Home extends StatelessWidget {
  const Home({super.key});
  @override
  Widget build(BuildContext ctx) => Scaffold(
    body: Center(
      child: ElevatedButton(
        onPressed: () async {
          // PIN sheet pops, key is generated, persisted, and synced.
          final key = await SyncingKeys.generateStarknetKey(id: 'main');
          debugPrint('Starknet address: ${key.publicAddress}');
        },
        child: const Text('Create Starknet wallet'),
      ),
    ),
  );
}
```

That's it. No `backup()`, no `restore()`. On a new device, the developer just
calls `SyncingKeys.getKey('main')` and the SDK fetches the encrypted envelope
from iCloud / Drive, prompts the user for their PIN (with a loading
indicator while the cloud round-trip is in flight), and returns the
decrypted key.

---

## 5. Beyond CRUD — managing keys, rotating PINs, tightening policy

Three additional APIs cover the day-to-day wallet flows you'll need once
the basic store/fetch/delete path is wired up.

### 5.1 `SyncingKeys.listKeys()` — enumerate without decrypting

Returns `List<KeyMetadata>` where each entry is `(id, type, createdAtMs?)`.
No PIN prompt, no cloud round-trip, no decryption — we only peek at the
envelope's outer JSON. Useful for "show me every wallet I have" surfaces.

```dart
final keys = await SyncingKeys.listKeys();
for (final k in keys) {
  print('${k.id} (${k.type.id}) sealed ${k.createdAtMs ?? "<legacy>"}');
}
```

Envelopes whose JSON can't be parsed are silently skipped — one corrupted
blob never takes down the whole listing.

### 5.2 `SyncingKeys.changePin({oldPin, newPin})` — rotate the user's PIN

Re-encrypts **every** locally-stored envelope *and* every cloud-only id
under the new PIN. Returns a `ChangePinResult` carrying:

- `rotated` — the ids that successfully re-sealed,
- `failed` — `ChangePinFailure(id, error)` for each id that didn't.

```dart
final result = await SyncingKeys.changePin(
  oldPin: oldPin,
  newPin: newPin,
);
if (result.failed.isEmpty) {
  // Full success.
} else {
  // Surface the failed ids and let the user retry.
}
```

> **⚠ Partial-failure semantics.** Each id is rotated independently — if a
> mid-list `storeBlob` fails (typically a transient Drive upload error or
> a Keychain that briefly turned read-only after a lock-screen change),
> the SDK keeps going. The `rotated` ids are on the new PIN; the `failed`
> ids are still on the old PIN. Retrying the same `changePin(oldPin, newPin)`
> call is safe — only the still-old ids will be touched the second time.
> If you ignore `failed`, you will end up in a split-brain state.

> **Cloud-only ids.** With `syncEnabled: true`, `changePin` lists Drive /
> iCloud ids too and rotates them via the cloud-fallback read path. If the
> device is offline at rotation time, cloud-only ids will appear in
> `failed` — retry once the network is back.

Other behaviour worth knowing:

- `newPin` is run through the configured `PinPolicy`; a violation throws
  `ArgumentError` before any rewrite.
- The cached session PIN is wiped on completion — the next CRUD call will
  prompt for the new PIN.

### 5.3 `SyncingKeysStrings` — localizing user-visible copy

`PinTheme.title` / `PinTheme.subtitle` already cover the *encrypt-side* PIN
sheet. Every other piece of SDK-rendered text — the *decrypt-side*
subtitle, the wrong-PIN banner, the cloud-loading message, the biometric
prompt and button label, the keypad's screen-reader labels, and the
default `PinPolicy` rejection reasons — comes from
[`SyncingKeysStrings`](./lib/src/config/syncing_keys_strings.dart):

```dart
final french = SyncingKeysStrings(
  decryptSubtitle:    'Entrez votre code pour déverrouiller cette clé.',
  wrongPinRetry:      'Code incorrect — réessayez.',
  fetchingFromCloud:  'Récupération depuis le cloud…',
  biometricPromptReason: 'Déverrouillez vos clés chiffrées',
  biometricButtonLabel:  'Déverrouiller par biométrie',
  pinPolicyEmpty:        'Le code ne peut pas être vide',
  pinPolicyRepeating:    'Le code ne peut pas être un chiffre répété',
  pinPolicySequential:   'Le code ne peut pas être une séquence',
);

await SyncingKeys.initialize(GlobalConfig(strings: french, …));
```

Build the instance from your app's `AppLocalizations` and re-call
`initialize` when the locale changes — the SDK's idempotency check
treats a strings-only delta as a clean rebuild and the next PIN sheet
opens in the new language.

### 5.4 `PinPolicy` — minimum-strength rules

The default `PinPolicy` rejects empty, all-same-digit, and ascending /
descending sequence PINs. To tighten (or replace):

```dart
class StrictPolicy extends PinPolicy {
  const StrictPolicy();
  @override
  String? reasonForRejection(String pin) {
    if (pin.length < 6) return 'PIN must be at least 6 digits';
    if (_breachedTopList.contains(pin)) return 'That PIN is too common';
    return super.reasonForRejection(pin);
  }
}

await SyncingKeys.initialize(GlobalConfig(
  pinPolicy: const StrictPolicy(),
  ...
));
```

Policy runs only on the encrypt-side of the PIN sheet — decrypt prompts
must accept whatever the user originally chose, even a weak PIN, so that
existing envelopes stay openable while you migrate users.

---

## 6. Production checklist

- [ ] Replaced debug SHA-1 with the Play release signing cert SHA-1 in
      Google Cloud Console.
- [ ] OAuth consent screen moved out of **Testing** if you want non-listed
      users to be able to sign in.
- [ ] Tuned `GlobalConfig.pbkdf2Iterations` to your security target
      (default = 120 000 hits the OWASP 2023 minimum for SHA-256).
- [ ] Reviewed `GlobalConfig.pinTheme` — match it to your brand.
- [ ] iOS provisioning profile re-issued after enabling Keychain Sharing
      and iCloud capabilities.
- [ ] Manual smoke test:
      1. Generate a key on device A.
      2. Reinstall the app / use device B with same Apple/Google account.
      3. Call `SyncingKeys.getKey(...)` — expect a loading dialog, then the
         PIN prompt, then the key.
- [ ] User communication — make sure your UI explains that "Forget your PIN"
      means the cloud backup is unrecoverable. SyncingKeys by design has no
      escrow.

---

## 7. Threat model — what SyncingKeys does and does not protect against

> ### ⚠ Foundational assumption: the device must be trustworthy at PIN entry
>
> The SDK's entire security story rests on one assumption: **at the moment the
> user types their PIN, the device they are typing it into is not actively
> compromised.** If that assumption fails — rooted/jailbroken phone, hostile
> keyboard, screen-recording malware, hardware keylogger, MDM-managed device
> in the wrong hands — the PIN is observable, the AES-GCM wrapping key is
> derivable, and the private key falls out the bottom.
>
> No purely-software wallet can defend against a compromised host. If your
> threat model includes this case, you need a hardware signer (a secure
> element, a HSM, or a separate device) — not a Flutter SDK.

### What the SDK *does* protect against

| Threat                                       | Mitigation                                                                                                          |
| -------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| Lost / stolen device                         | Envelope is PIN-encrypted; iOS items use `kSecAttrAccessibleAfterFirstUnlock*`; Android uses StrongBox where avail. |
| Compromised iCloud / Google account          | Envelope is still PIN-wrapped — attacker needs the PIN too.                                                         |
| Forgotten PIN                                | Unrecoverable by design. There is no escrow. Document this clearly to your users.                                   |
| Wrong-PIN brute force                        | PBKDF2 with 120 000 iterations; tune up via `pbkdf2Iterations`.                                                     |
| Envelope tampering                           | AES-GCM authentication tag — `WrongPinException` is thrown on tag failure.                                          |
| Plaintext key over the network               | All cloud-bound bytes are already AES-GCM ciphertext. iCloud/Drive can never see plaintext.                         |

### What it does *not* protect against (out of scope)

| Threat                                       | Why it's out of scope                                                                                               |
| -------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| Rooted / jailbroken device at PIN entry      | The PIN is intercepted before it ever reaches our code — game over for any software wallet.                         |
| Malicious third-party IME (keyboard)         | Same as above. Consider [`flutter_secure_screen`](https://pub.dev/) and a custom keyboard for high-value flows.     |
| Screen recording / accessibility scraping    | Flutter doesn't enable `FLAG_SECURE` on Android by default; turn it on in your `Activity` for sensitive screens.    |
| Side-channel attacks (timing, EM, cold-boot) | Phone-class hardware doesn't give us the primitives to defend here. Use a secure element if this matters.           |
| Coercion / "$5 wrench" attacks               | Outside the threat surface of any wallet SDK.                                                                       |
