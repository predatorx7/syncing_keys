## 0.1.0 — 2026-05-12

Initial release of the SyncingKeys SDK. Pre-release polish has been
consolidated into this single entry.

### Public surface

- `SyncingKeys.initialize(GlobalConfig, {navigatorKey, contextProvider})` —
  one-shot setup; idempotent on equal `GlobalConfig`.
- `SyncingKeys.generateEthereumKey({id})` — BIP-44 secp256k1 key on path
  `m/44'/60'/0'/0/0`, keccak-256 derived address.
- `SyncingKeys.generateStarknetKey({id})` — STARK-curve key
  (Pedersen/Poseidon-compatible) with felt-encoded public address.
- `SyncingKeys.saveKey(id, privateKey, type)` — store an externally
  produced 32-byte key; enforces curve-appropriate length.
- `SyncingKeys.getKey(id)` — local fast path, cloud-fallback slow path
  with a visible loading indicator; PIN prompt; returns a `StoredKey`.
- `SyncingKeys.deleteKey(id)` — wipes local + (if sync) cloud copy,
  clears the PIN cache.
- `SyncingKeys.listKeys()` — returns `List<KeyMetadata>` (id, type,
  optional createdAtMs) without decrypting or touching the cloud.
- `SyncingKeys.changePin({oldPin, newPin})` — re-encrypts every stored
  envelope under the new PIN; returns a `ChangePinResult`.
- `SyncingKeys.isCloudAvailable()`, `signInToCloud()`,
  `signOutOfCloud()` — cloud-state helpers.

### `GlobalConfig` fields

- `iosKeychainGroup` — Keychain Sharing access group (without team prefix).
- `androidDriveClientId` — OAuth 2.0 Client ID configured in Google Cloud
  Console (bound to package + signing-cert SHA-1).
- `syncEnabled` — master switch for iCloud / Drive sync.
- `pinTheme` — Material-3 themable PIN sheet (`PinTheme`).
- `pinPolicy` — strength rules (`PinPolicy`) — rejects all-same-digit
  and ascending/descending sequences by default.
- `pinCacheDuration` — in-memory PIN cache TTL; default 10 min;
  `Duration.zero` disables; cleared on `AppLifecycleState.paused`,
  `deleteKey`, 3-strikes wrong PIN, and `signOutOfCloud`.
- `pbkdf2Iterations` — PBKDF2-HMAC-SHA256 cost factor; default 120 000.

### Cryptography

- PBKDF2-HMAC-SHA256 → AES-256-GCM envelope, JSON-encoded with `v=1`.
- Optional `ts` (epoch ms) creation timestamp; background reconciliation
  on `getKey` prefers the newer copy when local and cloud diverge.
- Field-by-field envelope validation; missing/wrong-typed fields throw
  `EnvelopeFormatException` instead of a runtime `TypeError`.
- 16-byte salt + 12-byte IV per envelope (never reused); auth tag
  appended to ciphertext (standard combined AEAD form).
- Per-call CSPRNG seeded once from `Random.secure()` (`SyncingRandom`).

### iOS

- Keychain CRUD with `kSecAttrService = "app.xyz.everydayapp.syncing_keys"`,
  `kSecAttrAccessGroup` (from `GlobalConfig.iosKeychainGroup`), and
  `kSecAttrSynchronizable = true` for iCloud Keychain when sync is on.
- `kSecAttrAccessibleAfterFirstUnlock(ThisDeviceOnly)` chosen by sync flag.
- `kSecUseDataProtectionKeychain = true` on every query so macOS / Catalyst
  builds use the modern data-protection Keychain.
- `isCloudAvailable` probes `FileManager.ubiquityIdentityToken` (a
  necessary, not sufficient, signal — see INTEGRATION §6).
- `signIn`/`signOut` are no-ops on iOS (Apple ID sign-in is OS-owned).
- `Resources/PrivacyInfo.xcprivacy` shipped as a `resource_bundle`;
  audited — no required-reason API usage.

### Android

- Local store: `EncryptedSharedPreferences` (StrongBox-backed master key
  via `androidx.security:security-crypto`).
- Cloud store: Drive REST v3 against the hidden `appDataFolder`, via
  raw OkHttp (no Drive SDK pull-in). Multipart upload body assembled from
  raw `ByteArray` parts so larger envelopes survive UTF-8 round-trips.
- Authorization uses the modern `Identity.getAuthorizationClient(...)`
  + `AuthorizationRequest` API (the deprecated `GoogleSignIn` flow has
  been removed). Resolution `PendingIntent`s route through the existing
  `RC_SIGN_IN` activity-result handler.
- `UserRecoverableAuthException` → `ReauthRequiredException`; the
  captured `IntentSender` is used directly by the next
  `signInToCloud()` call. `isCloudAvailable` flips false while pending.
- Background coroutine scope is cancelled in `onDetachedFromEngine` and
  rebuilt on re-attach (no FlutterEngine leak).
- Id-redacted log lines (`<id:hhhh>`) so wallet-flavoured ids don't leak.
- `consumer-rules.pro` ships with the AAR — keeps GMS auth + Tink
  symbols alive under R8 in release builds.

### UI

- Themable `PinEntryOverlay` bottom sheet with a Material-3 numeric pad,
  animated PIN-progress dots, haptic feedback, wrong-PIN shake.
- Biometric pre-gate via `local_auth`; iOS / macOS default to
  `Icons.face`, all other targets to `Icons.fingerprint`.
- Every keypad button carries `Semantics(label, button)` so screen
  readers announce digits / actions correctly.
- `LoadingOverlay` shown during slow-path cloud fetches in `getKey`.

### Input validation

- `KeyId.validate` restricts ids to `[A-Za-z0-9_.-]{1,64}` — applied at
  every CRUD entry point so Drive `q=name=…` queries and Keychain
  `kSecAttrAccount` values stay safe.
- `saveKey` length-checks the private key (32 bytes for both curves).
- `PinPolicy` rejects empty, all-same-digit, and sequential PINs by
  default; subclass to enforce stricter rules.

### Memory hygiene

- `StoredKey.dispose()` overwrites the private-key bytes; `withKey(...)`
  helper auto-disposes on completion.
- `changePin` zero-fills its scratch plaintexts on every loop iteration.

### Project hygiene

- `dart analyze` is clean; `analysis_options.yaml` enables
  `strict-casts/inference/raw-types` plus 12 additional lints.
- 21 Dart unit + integration tests cover envelope round-trip, wrong-PIN,
  malformed envelopes, ETH/STARK key generation, PIN cache lifecycle,
  and platform method-channel arg-marshalling.
- `.github/workflows/ci.yml` runs format / analyze / test on macOS-latest.
- Apache-2.0 LICENSE shipped.
- `INTEGRATION.md` covers Google Cloud Console (with debug/release/Play
  SHA-1 build-flavor guidance), Xcode capabilities, Info.plist
  additions, a threat model, and a foundational device-trust callout.
- `example/README.md` walks newcomers through the two constants they
  must swap before running the example app.
