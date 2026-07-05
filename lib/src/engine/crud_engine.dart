import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../syncing_keys_platform_interface.dart';
import '../config/cloud_backend.dart';
import '../config/global_config.dart';
import '../crypto/envelope.dart';
import '../keygen/ethereum_key_generator.dart';
import '../keygen/starknet_key_generator.dart';
import '../models/exceptions.dart';
import '../models/ids.dart';
import '../models/key_conflict.dart';
import '../models/key_metadata.dart';
import '../models/key_type.dart';
import '../models/stored_key.dart';
import '../ui/loading_overlay.dart';
import '../ui/pin_entry_overlay.dart';
import 'biometric_pin_store.dart';
import 'change_pin_result.dart';
import 'pin_cache.dart';

/// =============================================================================
/// CrudEngine — the orchestration layer behind the SyncingKeys facade.
/// -----------------------------------------------------------------------------
/// Sequence for `saveKey`:
///   1. (If no cached PIN) show the PIN entry overlay — receive PIN string.
///   2. Build an [Envelope] using `Envelope.seal(...)`.
///   3. Push the envelope's base64 blob to the platform via `storeBlob`.
///      The platform writes locally **and** (if syncEnabled) uploads to
///      iCloud / Drive in the same call — the developer never asks for it.
///   4. Cache the PIN for [GlobalConfig.pinCacheDuration] so the next CRUD
///      call doesn't re-prompt.
///
/// Sequence for `getKey`:
///   1. Ask the platform for the blob (cloud fallback allowed when syncEnabled).
///   2. If only the cloud had it, the platform side will have already re-saved
///      it locally so subsequent reads are fast.
///   3. Try cached PIN first; on miss/wrong-PIN, show the PIN UI.
///   4. Re-hydrate the public address from the curve and hand back a
///      [StoredKey] for the developer.
///   5. After returning, kick off a non-blocking reconciliation that pulls
///      the cloud copy and replaces the local one if the cloud envelope's
///      `ts` is newer.
///
/// `deleteKey` is straightforward — wipes both ends and clears the cache.
/// =============================================================================
class CrudEngine {
  CrudEngine({
    required this.config,
    required this.contextProvider,
    BiometricPinStore? biometricStore,
  })  : _pinCache = PinCache(ttl: config.pinCacheDuration),
        _biometricStore = config.biometricUnlockEnabled
            ? (biometricStore ?? BiometricPinStore())
            : null;

  final GlobalConfig config;

  // ── Runtime-mutable sync state ─────────────────────────────────────────
  // `syncEnabled` / `cloudBackend` start from [config] but can be changed at
  // runtime via [setRuntimeConfig] without rebuilding the engine, so the user
  // can turn backup on/off or switch backends from settings. Reads go through
  // [_syncEnabled] / [_activeBackend] everywhere below.
  bool? _syncEnabledOverride;
  bool _backendOverridden = false;
  CloudBackend? _backendOverride;

  bool get _syncEnabled => _syncEnabledOverride ?? config.syncEnabled;
  CloudBackend? get _activeBackend =>
      _backendOverridden ? _backendOverride : config.cloudBackend;

  /// Apply a new sync configuration at runtime. Pushes to the native side
  /// first (so a failure there doesn't leave Dart and native disagreeing),
  /// then records the override locally.
  Future<void> setRuntimeConfig({
    required bool syncEnabled,
    CloudBackend? backend,
  }) async {
    await _platform.setRuntimeConfig(syncEnabled: syncEnabled, backend: backend);
    _syncEnabledOverride = syncEnabled;
    _backendOverride = backend;
    _backendOverridden = true;
  }

  /// The host app needs to give us a [BuildContext] to draw PIN UIs into.
  /// We accept a *provider* rather than a context directly because contexts
  /// are short-lived and the SDK lives across many `setState` calls.
  final BuildContext Function() contextProvider;

  final PinCache _pinCache;

  /// Persistent, biometric-gated PIN store. Null when
  /// [GlobalConfig.biometricUnlockEnabled] is false — in that case no PIN is
  /// ever written to disk and the biometric button never appears.
  final BiometricPinStore? _biometricStore;

  /// Test-only accessor for the session PIN cache. Used in unit tests to
  /// pre-seed a PIN so CRUD calls don't try to render the bottom sheet.
  @visibleForTesting
  PinCache get pinCacheForTest => _pinCache;

  /// Serialises every interactive PIN / biometric prompt so two overlays can
  /// never be on screen at once. Concurrent CRUD calls (e.g. several `getKey`
  /// / `signHash` that fire together when the user taps "claim reward") queue
  /// on this gate instead of each spawning their own sheet — which previously
  /// stacked multiple PIN sheets and overlapping `local_auth` biometric
  /// prompts. The tail of the chain represents the in-flight prompt, if any.
  Future<void> _promptGate = Future<void>.value();

  /// Runs [action] with exclusive access to the PIN prompt: it only starts
  /// once any in-flight prompt has settled, and the gate is released when
  /// [action] itself settles (success *or* error) so a failure can't wedge
  /// the chain. Callers should re-check [_pinCache] inside [action] — by the
  /// time they acquire the gate a prior prompt may already have cached a PIN,
  /// in which case they reuse it rather than prompting again.
  Future<T> _withPromptGate<T>(Future<T> Function() action) {
    final result = _promptGate.then((_) => action());
    // Chain the next waiter off this result, swallowing errors so one
    // cancelled / failed prompt doesn't poison every queued caller.
    _promptGate = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  /// Persists a known-good PIN for biometric unlock. Best-effort: a Keychain /
  /// Keystore write failure must never break the CRUD operation that produced
  /// the PIN, so we swallow errors here.
  Future<void> _rememberPin(String pin) async {
    final store = _biometricStore;
    if (store == null) return;
    try {
      await store.save(pin);
    } catch (_) {
      /* best-effort — biometric convenience only. */
    }
  }

  /// Drops the persisted PIN. Called wherever the in-memory cache is cleared
  /// for a PIN-invalidation reason (wrong-PIN strikes, `changePin`,
  /// `deleteKey`). Also best-effort.
  Future<void> _forgetPin() async {
    final store = _biometricStore;
    if (store == null) return;
    try {
      await store.clear();
    } catch (_) {
      /* best-effort. */
    }
  }

  /// Wipes the persisted biometric PIN on request (e.g. a "disable fingerprint
  /// unlock" toggle). No-op when biometric unlock is disabled.
  Future<void> clearBiometricPin() => _forgetPin();

  /// Convenience for retrieving the platform implementation.
  SyncingKeysPlatform get _platform => SyncingKeysPlatform.instance;

  /// Cleanly tear down — drops the lifecycle observer and clears the PIN
  /// cache. Re-builders (e.g. `SyncingKeys.initialize` after a config change)
  /// must call this before discarding the engine.
  void dispose() => _pinCache.dispose();

  // ─────────────────────────────────────────────────────────────────────
  // CREATE
  // ─────────────────────────────────────────────────────────────────────

  /// Generate a new ETH key, seal it, and persist.
  Future<StoredKey> generateAndStoreEthereum(String id) async {
    KeyId.validate(id);
    final eth = EthereumKeyGenerator.generate();
    await _seal(id: id, privateKey: eth.privateKey, type: KeyType.ethereum);
    return StoredKey(
      id: id,
      type: KeyType.ethereum,
      privateKey: eth.privateKey,
      publicAddress: eth.address,
    );
  }

  /// Generate a new Starknet key, seal it, and persist.
  Future<StoredKey> generateAndStoreStarknet(String id) async {
    KeyId.validate(id);
    final sk = StarknetKeyGenerator.generate();
    await _seal(id: id, privateKey: sk.privateKey, type: KeyType.starknet);
    return StoredKey(
      id: id,
      type: KeyType.starknet,
      privateKey: sk.privateKey,
      publicAddress: sk.publicAddress,
    );
  }

  /// Store an externally-produced private key under [id].
  ///
  /// Both curve families we support use a 32-byte scalar; anything else is
  /// almost certainly a developer mistake (wrong-format buffer, accidentally
  /// passing a public key, etc.).
  Future<void> saveKey({
    required String id,
    required Uint8List privateKey,
    required KeyType type,
  }) {
    KeyId.validate(id);
    _validatePrivateKey(privateKey, type);
    return _seal(id: id, privateKey: privateKey, type: type);
  }

  static void _validatePrivateKey(Uint8List bytes, KeyType type) {
    const expected = 32;
    if (bytes.length != expected) {
      throw ArgumentError.value(
        bytes,
        'privateKey',
        '${type.name} requires a $expected-byte private key, got ${bytes.length} bytes',
      );
    }
    // For Starknet, additionally reject scalars outside the valid range
    // `[1, n-1]` — an all-zero buffer or a value >= the curve order would seal
    // into an envelope that can never produce a valid signature. secp256k1's
    // range check is deferred to the signer, but the stark path is the one the
    // import feature uses, so we guard it here.
    if (type == KeyType.starknet && !StarknetKeyGenerator.isValidScalar(bytes)) {
      throw ArgumentError.value(
        bytes,
        'privateKey',
        'not a valid STARK private scalar (must be in [1, n-1])',
      );
    }
  }

  Future<void> _seal({
    required String id,
    required Uint8List privateKey,
    required KeyType type,
  }) async {
    // Fast path: a cached PIN needs no UI and no gate.
    final pin = _pinCache.get() ??
        await _withPromptGate<String>(() async {
          // Re-check inside the gate — a concurrent prompt may have just
          // cached a PIN while we were queued.
          final cached = _pinCache.get();
          if (cached != null) return cached;
          return PinEntryOverlay.show(
            context: contextProvider(),
            theme: config.pinTheme,
            policy: config.pinPolicy,
            strings: config.strings,
            purpose: PinPurpose.encrypt,
          );
        });

    final env = Envelope.seal(
      privateKey: privateKey,
      pin: pin,
      type: type,
      iterations: config.pbkdf2Iterations,
    );

    await _platform.storeBlob(
      id: id,
      blob: env.toBlob(),
      syncToCloud: _syncEnabled,
    );
    _pinCache.set(pin); // record after the platform write succeeded.
    // Persist for biometric unlock so the *next* getKey can be a fingerprint.
    await _rememberPin(pin);
  }

  // ─────────────────────────────────────────────────────────────────────
  // READ
  // ─────────────────────────────────────────────────────────────────────

  Future<StoredKey> getKey(String id) async {
    KeyId.validate(id);
    // Fast path — local lookup with no UI cost.
    BlobLookup? lookup = await _platform.readBlob(
      id: id,
      allowCloudFallback: false,
    );

    // Slow path — cloud round-trip with a visible loading state. We only
    // engage this if sync is enabled and the local store missed.
    if (lookup == null && _syncEnabled) {
      final dismiss = LoadingOverlay.show(
        contextProvider(),
        message: config.strings.fetchingFromCloud,
      );
      try {
        lookup = await _platform.readBlob(
          id: id,
          allowCloudFallback: true,
        );
      } finally {
        dismiss();
      }
    }

    if (lookup == null) throw KeyNotFoundException(id);

    final env = Envelope.fromBlob(lookup.blob);
    final plain = await _openWithPinPrompt(env);

    final address = switch (env.type) {
      KeyType.ethereum => EthereumKeyGenerator.addressFor(plain),
      KeyType.starknet => StarknetKeyGenerator.publicAddressFor(plain),
    };

    // Background reconciliation — fire-and-forget. If sync is enabled and
    // the cloud has a newer envelope for this id, the platform copies the
    // newer blob over the local one so the *next* read sees fresh state.
    // This does not affect the current call's return value (we already
    // decrypted what we had); doing it lazily avoids a round-trip on every
    // read while still converging within one cycle.
    if (_syncEnabled && !lookup.fromCloud) {
      unawaited(_reconcileLater(id: id, localEnv: env));
    }

    return StoredKey(
      id: id,
      type: env.type,
      privateKey: plain,
      publicAddress: address,
    );
  }

  /// Tries the cached PIN first; falls back to the overlay on cache miss or
  /// authentication failure. Up to 3 wrong-PIN attempts before we give up.
  Future<Uint8List> _openWithPinPrompt(Envelope env) async {
    // 1) Cache attempt — no UI, no gate.
    final cached = _pinCache.get();
    if (cached != null) {
      try {
        final plain = env.open(cached);
        return plain;
      } on WrongPinException {
        // Envelope is from a different PIN era — drop the cache and prompt.
        _pinCache.clear();
      }
    }

    // 2) Interactive prompt with retry — serialised through the prompt gate so
    // concurrent reads (e.g. a claim that triggers several signing calls at
    // once) don't each pop their own sheet + biometric prompt. Whoever wins
    // the gate prompts; everyone queued behind them re-checks the cache below
    // and reuses the freshly-entered PIN instead of prompting again.
    return _withPromptGate<Uint8List>(() async {
      final c = _pinCache.get();
      if (c != null) {
        try {
          return env.open(c);
        } on WrongPinException {
          _pinCache.clear();
        }
      }

      String? errorMessage;
      var attempts = 0;
      while (true) {
        final pin = await PinEntryOverlay.show(
          context: contextProvider(),
          theme: config.pinTheme,
          strings: config.strings,
          purpose: PinPurpose.decrypt,
          errorMessage: errorMessage,
          hasStoredPin: _biometricStore?.has,
          readStoredPin: _biometricStore?.read,
          // Auto-fire biometrics only on the first prompt; after a wrong PIN
          // (errorMessage set) fall back to manual entry so a stale stored PIN
          // can't loop.
          autoPromptBiometric: errorMessage == null,
        );
        try {
          final plain = env.open(pin);
          _pinCache.set(pin);
          await _rememberPin(pin);
          return plain;
        } on WrongPinException {
          attempts += 1;
          if (attempts >= 3) {
            _pinCache.clear();
            // The persisted PIN no longer opens this envelope (likely rotated
            // on another device) — drop it so we stop offering a dead
            // fingerprint.
            await _forgetPin();
            rethrow;
          }
          errorMessage = config.strings.wrongPinRetry;
        }
      }
    });
  }

  /// Background pass — asks the platform for the cloud copy and, if its
  /// envelope timestamp is strictly newer than our local one, asks the
  /// platform to overwrite local. Failures are swallowed; logging is the
  /// developer's responsibility if they want to see them.
  Future<void> _reconcileLater({
    required String id,
    required Envelope localEnv,
  }) async {
    try {
      final cloud = await _platform.readBlob(id: id, allowCloudFallback: true);
      if (cloud == null || !cloud.fromCloud) return;
      final cloudEnv = Envelope.fromBlob(cloud.blob);
      if (cloudEnv.createdAtMs > localEnv.createdAtMs) {
        // The platform's `readBlob` with cloud fallback already re-saves the
        // cloud copy locally as a side-effect, so we don't need a separate
        // `storeBlob` here. Subsequent reads will see the newer envelope.
      }
    } catch (_) {
      /* best-effort; surface via logs the platform writes. */
    }
  }

  // ─────────────────────────────────────────────────────────────────────
  // BACKEND SWITCH + CONFLICT
  // ─────────────────────────────────────────────────────────────────────

  static String _addressFor(KeyType type, Uint8List plain) => switch (type) {
        KeyType.ethereum => EthereumKeyGenerator.addressFor(plain),
        KeyType.starknet => StarknetKeyGenerator.publicAddressFor(plain),
      };

  static void _zero(Uint8List bytes) {
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = 0;
    }
  }

  /// Move the cloud backup for [id] to [to], keeping the local device copy
  /// intact (it is what signs). If [to] is a cloud backend the current local
  /// envelope is uploaded there; every *other* cloud backend is then cleared so
  /// exactly one cloud copy exists. If [to] is [CloudBackend.local] all cloud
  /// copies are removed. Finishes by flipping the runtime config so subsequent
  /// writes target the new backend.
  Future<void> switchBackend(String id, CloudBackend to) async {
    KeyId.validate(id);

    if (to.isCloud) {
      final local =
          await _platform.readBlobFromBackend(id: id, backend: CloudBackend.local);
      if (local != null) {
        await _platform.writeBlobToBackend(id: id, blob: local.blob, backend: to);
      }
    }

    // Ensure only `to` retains a cloud copy. Best-effort — a backend that isn't
    // available on this platform simply has nothing to delete.
    for (final b in CloudBackend.values) {
      if (b == to || !b.isCloud) continue;
      try {
        await _platform.deleteBlobFromBackend(id: id, backend: b);
      } catch (_) {
        /* best-effort cleanup */
      }
    }

    await setRuntimeConfig(syncEnabled: to.isCloud, backend: to);
  }

  /// Compare the local key for [id] against its copy on the active cloud
  /// backend. See [KeyConflict] for what counts as a conflict.
  ///
  /// When [promptIfNeeded] is true (default) this may pop the PIN sheet to
  /// decrypt and compare public addresses. When false it uses only a cached
  /// (session-warm) PIN and, if none is cached, returns
  /// [KeyConflict.undetermined] instead of prompting — use this for passive
  /// background checks that must not surprise the user with a PIN sheet.
  Future<KeyConflict> checkConflict(String id,
      {bool promptIfNeeded = true}) async {
    KeyId.validate(id);

    // Figure out which cloud backend to compare against. Prefer the explicitly
    // configured one; otherwise (config left at platform-default) scan the
    // known cloud backends for one that actually holds a copy.
    final backend = _activeBackend;
    final List<CloudBackend> candidates;
    if (backend != null && backend.isCloud) {
      candidates = [backend];
    } else if (_syncEnabled) {
      candidates = CloudBackend.values.where((b) => b.isCloud).toList();
    } else {
      return const KeyConflict.none(CloudBackend.local);
    }

    final local =
        await _platform.readBlobFromBackend(id: id, backend: CloudBackend.local);
    if (local == null) {
      return KeyConflict.none(candidates.first);
    }

    CloudBackend? cloudBackend;
    BlobLookup? cloud;
    for (final b in candidates) {
      try {
        final lookup = await _platform.readBlobFromBackend(id: id, backend: b);
        if (lookup != null) {
          cloudBackend = b;
          cloud = lookup;
          break;
        }
      } on CloudReauthRequiredException {
        // Can't reach this backend without interactive sign-in — a passive
        // conflict check should not force it. Skip.
        continue;
      }
    }
    if (cloud == null || cloudBackend == null) {
      return KeyConflict.none(candidates.first);
    }

    // Byte-identical envelopes can't conflict.
    if (local.blob == cloud.blob) return KeyConflict.none(cloudBackend);

    final localEnv = Envelope.fromBlob(local.blob);
    final cloudEnv = Envelope.fromBlob(cloud.blob);

    // Decrypt local to learn its public address (and warm the PIN cache).
    // Passive mode: use only a cached PIN, never prompt.
    final Uint8List localPlain;
    if (promptIfNeeded) {
      localPlain = await _openWithPinPrompt(localEnv);
    } else {
      final cachedPin = _pinCache.get();
      if (cachedPin == null) return KeyConflict.undetermined(cloudBackend);
      try {
        localPlain = localEnv.open(cachedPin);
      } on WrongPinException {
        // Cached PIN doesn't even open local — bail passively.
        return KeyConflict.undetermined(cloudBackend);
      }
    }
    final localPub = _addressFor(localEnv.type, localPlain);
    _zero(localPlain);

    // Try the cloud copy under the same PIN. If it opens to the same address
    // it's just a benign re-seal (e.g. a PIN rotation) — not a conflict.
    final pin = _pinCache.get();
    String? cloudPub;
    var cloudUndecryptable = false;
    if (pin != null) {
      try {
        final cloudPlain = cloudEnv.open(pin);
        cloudPub = _addressFor(cloudEnv.type, cloudPlain);
        _zero(cloudPlain);
      } on WrongPinException {
        cloudUndecryptable = true;
      }
    } else {
      cloudUndecryptable = true;
    }

    final hasConflict = cloudUndecryptable || cloudPub != localPub;
    return KeyConflict(
      hasConflict: hasConflict,
      backend: cloudBackend,
      localPublicAddress: localPub,
      cloudPublicAddress: cloudPub,
      localCreatedAtMs: localEnv.createdAtMs,
      cloudCreatedAtMs: cloudEnv.createdAtMs,
      cloudUndecryptable: cloudUndecryptable,
    );
  }

  /// Resolve a conflict on [backend] by overwriting the loser. `keepLocal`
  /// pushes the device copy up to the cloud; `keepCloud` pulls the cloud copy
  /// down over local (and drops the cached PIN, since the cloud copy may be a
  /// different PIN era).
  Future<void> resolveConflict(
    String id,
    ConflictResolution keep,
    CloudBackend backend,
  ) async {
    KeyId.validate(id);
    if (keep == ConflictResolution.keepLocal) {
      final local = await _platform.readBlobFromBackend(
          id: id, backend: CloudBackend.local);
      if (local == null) throw KeyNotFoundException(id);
      await _platform.writeBlobToBackend(id: id, blob: local.blob, backend: backend);
    } else {
      final cloud = await _platform.readBlobFromBackend(id: id, backend: backend);
      if (cloud == null) throw KeyNotFoundException(id);
      await _platform.writeBlobToBackend(
          id: id, blob: cloud.blob, backend: CloudBackend.local);
      _pinCache.clear();
      await _forgetPin();
    }
  }

  // ─────────────────────────────────────────────────────────────────────
  // DELETE
  // ─────────────────────────────────────────────────────────────────────

  /// Re-encrypts every locally-stored envelope under [newPin], starting from
  /// the current ciphertexts encrypted under [oldPin].
  ///
  /// Behaviour:
  ///   * `oldPin` must be the current PIN — verified by attempting to decrypt
  ///     the first envelope. On mismatch we throw [WrongPinException] before
  ///     touching anything else.
  ///   * `newPin` is run through [PinPolicy] — same rules as a fresh PIN.
  ///   * Each id is re-sealed individually. A failure mid-list leaves the
  ///     processed ids on `newPin` and the rest on `oldPin`. We surface
  ///     this with the returned `ChangePinResult`.
  ///   * The PIN cache is wiped at the end so the next CRUD call requires
  ///     a fresh `newPin` entry — defence-in-depth for the case where a
  ///     stale `oldPin` lingered in the cache.
  Future<ChangePinResult> changePin({
    required String oldPin,
    required String newPin,
  }) async {
    final policyError =
        config.pinPolicy.reasonForRejection(newPin, strings: config.strings);
    if (policyError != null) {
      throw ArgumentError.value(newPin, 'newPin', policyError);
    }

    // Union local + cloud ids. A key that exists *only* in the cloud
    // (e.g. uploaded from another device and never `getKey`'d here) must
    // also be rotated, otherwise the next `getKey` on this device pulls
    // the cloud copy and fails to decrypt under the new PIN. Cloud
    // enumeration is best-effort — if Drive / iCloud is unreachable we
    // proceed with whatever local has and surface the missing ones via
    // the result's `failed` list on the next attempt.
    final localIds = await _platform.listLocalIds();
    final List<String> cloudIds = _syncEnabled
        ? await _platform.listCloudIds().catchError(
            (Object _) => const <String>[],
          )
        : const <String>[];
    final ids = <String>{...localIds, ...cloudIds}.toList(growable: false);

    if (ids.isEmpty) {
      _pinCache.clear();
      return const ChangePinResult(rotated: [], failed: []);
    }

    // Verify oldPin by attempting to decrypt the first envelope. We try the
    // first id and fall through to the cloud lookup if it's cloud-only.
    final probe = await _platform.readBlob(
      id: ids.first,
      allowCloudFallback: _syncEnabled,
    );
    if (probe == null) {
      // Race — id list said it existed but the row vanished. Treat as no-op.
      _pinCache.clear();
      return const ChangePinResult(rotated: [], failed: []);
    }
    Envelope.fromBlob(probe.blob).open(oldPin);

    final rotated = <String>[];
    final failed = <ChangePinFailure>[];

    for (final id in ids) {
      try {
        final lookup = await _platform.readBlob(
          id: id,
          allowCloudFallback: _syncEnabled,
        );
        if (lookup == null) continue;
        final env = Envelope.fromBlob(lookup.blob);
        final plain = env.open(oldPin);
        try {
          final resealed = Envelope.seal(
            privateKey: plain,
            pin: newPin,
            type: env.type,
            iterations: config.pbkdf2Iterations,
          );
          await _platform.storeBlob(
            id: id,
            blob: resealed.toBlob(),
            syncToCloud: _syncEnabled,
          );
          rotated.add(id);
        } finally {
          // Zero the plaintext immediately — we don't need to keep it past
          // this loop iteration.
          for (var i = 0; i < plain.length; i++) {
            plain[i] = 0;
          }
        }
      } catch (e) {
        failed.add(ChangePinFailure(id: id, error: e));
      }
    }

    _pinCache.clear();
    // The persisted PIN is now stale (envelopes re-sealed under newPin). Drop
    // it; the next successful decrypt under newPin re-persists it.
    await _forgetPin();
    return ChangePinResult(rotated: rotated, failed: failed);
  }

  /// Enumerates the locally-stored keys. No PIN prompt, no cloud round-trip,
  /// no decryption — we only peek at the envelope metadata (`type`, `ts`).
  ///
  /// Envelopes whose JSON can't be parsed are silently skipped (and logged
  /// via the platform's own logger). This avoids one corrupted blob taking
  /// down the entire listing.
  Future<List<KeyMetadata>> listKeys() async {
    final ids = await _platform.listLocalIds();
    final out = <KeyMetadata>[];
    for (final id in ids) {
      final lookup = await _platform.readBlob(id: id, allowCloudFallback: false);
      if (lookup == null) continue;
      try {
        final env = Envelope.fromBlob(lookup.blob);
        out.add(KeyMetadata(
          id: id,
          type: env.type,
          createdAtMs: env.createdAtMs == 0 ? null : env.createdAtMs,
        ));
      } catch (_) {
        // Skip — corrupted or unrecognised envelope.
      }
    }
    return out;
  }

  // ─────────────────────────────────────────────────────────────────────
  // DELETE
  // ─────────────────────────────────────────────────────────────────────

  Future<void> deleteKey(String id) async {
    KeyId.validate(id);
    await _platform.deleteBlob(
      id: id,
      deleteFromCloud: _syncEnabled,
    );
    // Best-practice: a deleteKey often signals a security-relevant action
    // (rotating the wallet, signing out of an account). Drop the cached PIN
    // so the next CRUD requires a fresh prompt.
    _pinCache.clear();
    await _forgetPin();
  }
}
