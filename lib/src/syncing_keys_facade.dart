import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../syncing_keys_platform_interface.dart';
import 'config/global_config.dart';
import 'engine/change_pin_result.dart';
import 'engine/crud_engine.dart';
import 'models/exceptions.dart';
import 'models/key_metadata.dart';
import 'models/key_type.dart';
import 'models/stored_key.dart';

/// =============================================================================
/// SyncingKeys — the single public entry-point of the SDK.
/// -----------------------------------------------------------------------------
/// "Set it and forget it":
///
/// ```dart
/// await SyncingKeys.initialize(GlobalConfig(
///   iosKeychainGroup: 'group.com.acme.wallet',
///   syncEnabled: true,
/// ));
///
/// final stark = await SyncingKeys.generateStarknetKey(id: 'main');
/// // stark.publicAddress is ready to use.
///
/// final fetched = await SyncingKeys.getKey('main');
/// ```
///
/// All sync state is handled inside the SDK. The developer never calls a
/// "backup" or "restore" function.
/// =============================================================================
class SyncingKeys {
  SyncingKeys._();

  static GlobalConfig? _config;
  static CrudEngine? _engine;

  /// Returns the active configuration after [initialize].
  static GlobalConfig get config {
    final c = _config;
    if (c == null) throw const SyncingKeysNotInitializedException();
    return c;
  }

  /// One-time setup. Call from `main()` after `WidgetsFlutterBinding.ensureInitialized()`.
  ///
  /// **Idempotent**: calling [initialize] a second time with a [GlobalConfig]
  /// equal to the existing one is a no-op (common during hot reload). If the
  /// config differs, the SDK rebuilds its engine and re-pushes the new
  /// values to the native side.
  ///
  /// [navigatorKey] (or [contextProvider]) supplies the [BuildContext] used
  /// to host the PIN entry sheet. Pass either one — the SDK prefers
  /// [contextProvider] if both are supplied.
  static Future<void> initialize(
    GlobalConfig config, {
    GlobalKey<NavigatorState>? navigatorKey,
    BuildContext Function()? contextProvider,
  }) async {
    assert(navigatorKey != null || contextProvider != null,
        'Provide either navigatorKey or contextProvider so the PIN UI can be rendered.');

    if (_config == config && _engine != null) {
      // Same payload, already initialised. Skip the platform round-trip so
      // hot reload doesn't blow away the in-memory PIN cache or in-flight
      // platform state.
      return;
    }

    // Tear down the previous engine (drops lifecycle observer + PIN cache)
    // before swapping in the new one.
    _engine?.dispose();

    _config = config;

    await SyncingKeysPlatform.instance.configure(
      iosKeychainGroup: config.iosKeychainGroup,
      syncEnabled: config.syncEnabled,
    );

    final BuildContext Function() resolver = contextProvider ??
        () {
          final ctx = navigatorKey!.currentContext;
          if (ctx == null) {
            throw StateError(
                'SyncingKeys: navigatorKey has no currentContext yet. '
                'Call SyncingKeys APIs after the first frame is rendered.');
          }
          return ctx;
        };

    _engine = CrudEngine(config: config, contextProvider: resolver);
  }

  static CrudEngine get _e {
    final e = _engine;
    if (e == null) throw const SyncingKeysNotInitializedException();
    return e;
  }

  // ─────────────────────────────────────────────────────────────────────
  // High-level generators (the most common path)
  // ─────────────────────────────────────────────────────────────────────

  /// Generates a fresh BIP-44 Ethereum keypair, prompts for a PIN, stores
  /// the encrypted envelope locally (+ iCloud/Drive if `syncEnabled`), and
  /// returns the public-address part to the caller.
  static Future<StoredKey> generateEthereumKey({required String id}) =>
      _e.generateAndStoreEthereum(id);

  /// Generates a fresh Starknet keypair using the STARK curve and persists
  /// it under [id]. Returns the public address (felt-encoded 0x… string).
  static Future<StoredKey> generateStarknetKey({required String id}) =>
      _e.generateAndStoreStarknet(id);

  // ─────────────────────────────────────────────────────────────────────
  // Generic CRUD (advanced; usually you'll only need the generators above)
  // ─────────────────────────────────────────────────────────────────────

  /// Persist a private key produced elsewhere.
  static Future<void> saveKey({
    required String id,
    required Uint8List privateKey,
    required KeyType type,
  }) =>
      _e.saveKey(id: id, privateKey: privateKey, type: type);

  /// Look up a key by id. If sync is enabled and the local store has a miss,
  /// the cloud is consulted (with a visible loading indicator) before the
  /// PIN entry sheet appears.
  static Future<StoredKey> getKey(String id) => _e.getKey(id);

  /// Lists every locally-stored key as a [KeyMetadata]. No PIN prompt, no
  /// cloud round-trip. Useful for "show me all my wallets" UIs.
  static Future<List<KeyMetadata>> listKeys() => _e.listKeys();

  /// Rotates the user's PIN. Re-encrypts **every** stored envelope under
  /// [newPin] — both locally-stored ids and cloud-only ids (those that
  /// exist in iCloud / Drive but haven't been read on this device yet).
  /// Each new ciphertext is also re-uploaded if sync is enabled. The PIN
  /// cache is cleared on completion.
  ///
  /// Throws [WrongPinException] if [oldPin] doesn't decrypt the first
  /// envelope, and [ArgumentError] if [newPin] violates the configured
  /// [PinPolicy].
  ///
  /// Returns a [ChangePinResult] summarising which ids rotated and which
  /// (if any) failed.
  ///
  /// **Partial-failure semantics.** Rotation runs id-by-id. A mid-list
  /// failure (a transient Drive upload, a Keychain that briefly turned
  /// read-only) leaves the listed ids on the old PIN and the rotated ids
  /// on the new PIN. Retrying the same `changePin(oldPin, newPin)` call
  /// is safe — only the still-old ids are touched the second time.
  /// **Ignoring `failed` will put you in a split-brain state.**
  static Future<ChangePinResult> changePin({
    required String oldPin,
    required String newPin,
  }) =>
      _e.changePin(oldPin: oldPin, newPin: newPin);

  /// Wipes the key from local storage and (if sync is enabled) from the
  /// cloud as well. Idempotent — deleting a non-existent id is a no-op.
  static Future<void> deleteKey(String id) => _e.deleteKey(id);

  /// Whether the platform can currently talk to its cloud backend. Useful
  /// for "you're offline" UI hints. Returns `false` when sync is disabled.
  static Future<bool> isCloudAvailable() =>
      SyncingKeysPlatform.instance.isCloudAvailable();

  /// Surfaces the platform's cloud sign-in flow.
  ///
  /// - **Android:** shows the Google account picker so the user can grant the
  ///   `drive.appdata` scope. Resolves to `true` on grant, `false` on cancel.
  ///   Safe to call multiple times — fast-paths to `true` if an account is
  ///   already cached.
  /// - **iOS:** iCloud sign-in is OS-owned; this is a no-op that always
  ///   resolves to `true`. Direct users to **Settings → [Their name] →
  ///   iCloud → Keychain** if they need to enable it.
  ///
  /// Call this **after** [initialize] and only when [GlobalConfig.syncEnabled]
  /// is true.
  static Future<bool> signInToCloud() =>
      SyncingKeysPlatform.instance.signInToCloud();

  /// Drops the platform's cached cloud account credentials. Does not delete
  /// any uploaded blobs. After this, the next CRUD call that needs cloud
  /// access will require a fresh [signInToCloud].
  static Future<void> signOutOfCloud() =>
      SyncingKeysPlatform.instance.signOutOfCloud();
}
