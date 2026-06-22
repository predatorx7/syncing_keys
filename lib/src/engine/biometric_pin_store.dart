import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// =============================================================================
/// BiometricPinStore — persists the PIN at rest so a successful biometric
/// gesture can surface it on the next launch.
/// -----------------------------------------------------------------------------
/// The PIN is stored in the platform Keychain (iOS) / Keystore-backed
/// `EncryptedSharedPreferences` (Android). On its own this only protects the
/// PIN *at rest*; the **user-presence gate** is the `local_auth` call the PIN
/// overlay runs immediately before [read]. We deliberately read the PIN only
/// after that gesture succeeds, so the flow is:
///
///   biometric prompt (local_auth) ──ok──▶ BiometricPinStore.read() ──▶ unlock
///
/// Trade-off (consistent with the SDK's existing posture — see INTEGRATION.md):
/// on a rooted / jailbroken device an attacker with the Keychain/Keystore could
/// read the stored PIN without the gesture. That's the same out-of-scope threat
/// the rest of the SDK accepts; the in-memory [PinCache] already holds the PIN
/// in plaintext for its TTL. We do *not* claim hardware biometric-binding here.
///
/// The store survives process restarts on purpose — that is what lets the user
/// unlock with a fingerprint on a cold launch without re-typing. It is wiped on
/// the same PIN-invalidation events as the cache (3-strikes, `changePin`,
/// `deleteKey`) and via [SyncingKeys.clearBiometricPin].
/// =============================================================================
class BiometricPinStore {
  BiometricPinStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
            );

  final FlutterSecureStorage _storage;

  /// Single fixed slot — the PIN is global to the SDK, not per-key.
  static const String _key = 'syncing_keys.biometric_pin';

  /// Persists [pin] so a future biometric gesture can surface it.
  Future<void> save(String pin) => _storage.write(key: _key, value: pin);

  /// Returns the stored PIN in plaintext. Call **only after** a successful
  /// biometric gesture. Returns null if nothing is stored.
  Future<String?> read() => _storage.read(key: _key);

  /// Whether a PIN is currently stored — used to decide whether to surface the
  /// biometric button at all (no point offering it with nothing to unlock).
  /// Does not return the plaintext.
  Future<bool> has() => _storage.containsKey(key: _key);

  /// Wipes the stored PIN immediately.
  Future<void> clear() => _storage.delete(key: _key);
}
