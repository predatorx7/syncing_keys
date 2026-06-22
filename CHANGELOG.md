## 0.2.0 — 2026-06-22

Biometric (Face ID / fingerprint) unlock now actually works, and the PIN
entry sheet correctly closes after a successful gesture.

> **⚠ Behavioural change — read before upgrading.** The source API is fully
> backwards-compatible (every addition is an optional parameter, a new method,
> or a new defaulted config field — no existing call site needs to change).
> **However, the default behaviour changed:** a successfully-entered PIN is now
> persisted to the platform Keychain / Keystore so it can be surfaced by a
> biometric gesture. Previously the PIN was held in memory only and never
> written to disk. This is the reason for the minor (breaking) version bump.
> If your threat model requires the PIN to never touch disk, opt out with
> `GlobalConfig(biometricUnlockEnabled: false)`.

### Fixed

- **Biometric unlock no longer leaves the sheet open.** A successful biometric
  gesture previously authenticated and then did nothing — no `Navigator.pop`,
  so the PIN sheet stayed up. It now surfaces the stored PIN and closes,
  exactly as if the user had typed it.

### Added

- **`GlobalConfig.biometricUnlockEnabled`** (default `true`) — master switch
  for the persist-and-biometric-unlock flow. Set `false` to never write the
  PIN to disk and hide the biometric button entirely.
- **`SyncingKeys.clearBiometricPin()`** — forgets the persisted PIN (e.g. to
  back a "disable fingerprint unlock" toggle or a sign-out) without changing
  the PIN or deleting any key. No-op when biometric unlock is disabled.
- **`BiometricPinStore`** — Keychain / Keystore-backed (`flutter_secure_storage`)
  at-rest store for the biometric-gated PIN. The `local_auth` gesture is the
  user-presence gate; reads happen only after it succeeds. This is **not**
  hardware biometric-binding — see INTEGRATION §5.4 for the trade-offs.
- New `flutter_secure_storage` dependency.

### Behaviour

- The decrypt sheet auto-prompts for biometrics on open, and only shows the
  button when a PIN is actually stored to unlock.
- The persisted PIN is dropped on the same invalidation events as the in-memory
  cache: 3-strikes wrong PIN, `changePin`, and `deleteKey`. It is **not**
  auto-prompted on a retry prompt, so a stale stored PIN can't silently loop.
- There is still **no "reset / forgot PIN" API by design** — the PIN derives
  the encryption key, so a forgotten PIN is unrecoverable. `changePin` (needs
  the old PIN) and `deleteKey` remain the only paths; `clearBiometricPin` only
  forgets the biometric convenience copy.

### Tests

- New widget tests (`pin_entry_biometric_test.dart`) cover the close-on-success
  regression, button-hidden-when-empty, and cancel-falls-back-to-typing — with
  `local_auth` faked at the platform-interface layer.
- New engine tests cover PIN persistence on seal, and forgetting on
  `changePin` / `deleteKey` / `clearBiometricPin` / opt-out.

---

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
- `syncEnabled` — master switch for iCloud / Drive sync. On Android the
  Drive OAuth client is resolved at runtime from `google-services.json` by
  package name + signing-cert SHA-1 — no client ID is required in code.
- `pinTheme` — Material-3 themable PIN sheet (`PinTheme`).
- `pinPolicy` — strength rules (`PinPolicy`) — rejects all-same-digit
  and ascending/descending sequences by default.
- `pinCacheDuration` — in-memory PIN cache TTL; default 3 days;
  `Duration.zero` disables; cleared on `deleteKey`, 3-strikes wrong PIN,
  PIN change, and `signOutOfCloud`. Survives app backgrounding —
  process restart is the only implicit drop.
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
