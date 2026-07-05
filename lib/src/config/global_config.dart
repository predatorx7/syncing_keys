import 'cloud_backend.dart';
import 'pin_policy.dart';
import 'pin_theme.dart';
import 'syncing_keys_strings.dart';

/// One-time setup payload passed to [SyncingKeys.initialize].
///
/// Everything is opt-in: an app that just wants on-device storage can leave
/// `syncEnabled` false and the cloud-side identifier empty.
class GlobalConfig {
  const GlobalConfig({
    this.iosKeychainGroup,
    this.syncEnabled = false,
    this.cloudBackend,
    this.pinTheme = const PinTheme(),
    this.pinPolicy = const PinPolicy(),
    this.strings = const SyncingKeysStrings(),
    this.pbkdf2Iterations = 120000,
    this.pinCacheDuration = const Duration(days: 3),
    this.biometricUnlockEnabled = true,
  })  : assert(pbkdf2Iterations >= 50000,
            'PBKDF2 iterations should be at least 50k for production use.');

  /// iOS Keychain *Access Group* identifier. Required if you want the same
  /// key to be readable by a sibling app (your watch companion, an iOS
  /// extension, etc.) or to survive certain Keychain restore paths.
  ///
  /// Format: `"$(AppIdentifierPrefix)com.yourcompany.shared"`.
  final String? iosKeychainGroup;

  /// Master switch for automatic cloud syncing. When `false`, the SDK behaves
  /// as a pure local store — `saveKey` skips iCloud / Drive, and `getKey`
  /// never reaches out to the network.
  ///
  /// On Android, the Drive OAuth client is resolved at runtime from
  /// `google-services.json` by matching the running APK's package name +
  /// signing-cert SHA-1 — no client ID needs to be passed in code. Register
  /// one Android OAuth client per signing cert (debug, upload, Play App
  /// Signing) in Google Cloud Console and re-download `google-services.json`.
  final bool syncEnabled;

  /// Which cloud backend to use when [syncEnabled] is true.
  ///
  /// When `null` the native side picks its platform default (iCloud Keychain on
  /// iOS, Google Drive on Android) — this preserves the pre-[CloudBackend]
  /// behaviour. Pass a concrete value to pin the choice, or drive it from a
  /// user preference. It can also be changed at runtime via
  /// [SyncingKeys.setBackend] / [SyncingKeys.switchBackend] without an app
  /// restart. A value of [CloudBackend.local] is equivalent to
  /// `syncEnabled == false`.
  final CloudBackend? cloudBackend;

  /// Visual theme for the PIN entry overlay.
  final PinTheme pinTheme;

  /// Strength rules applied to a PIN before [seal]ing. Subclass [PinPolicy]
  /// to tighten the defaults (e.g. add an entropy floor or a denylist).
  final PinPolicy pinPolicy;

  /// All user-visible strings the SDK ships — default to English. Build a
  /// custom [SyncingKeysStrings] from your app's `AppLocalizations` to
  /// localize.
  final SyncingKeysStrings strings;

  /// Iterations for the PBKDF2 PIN-wrap function. Default is 120 000 which
  /// hits the OWASP 2023 minimum for SHA-256. Tune up for high-value targets.
  final int pbkdf2Iterations;

  /// How long a successfully-entered PIN is held in memory before the SDK
  /// re-prompts. Cleared earlier if the app is paused. Pass [Duration.zero]
  /// to disable the cache and prompt for every CRUD call.
  final Duration pinCacheDuration;

  /// When true (default), a successfully-entered PIN is also persisted in the
  /// platform Keychain / Keystore so the user can unlock with Face ID /
  /// fingerprint instead of re-typing it. The persisted PIN is read only after
  /// a successful biometric gesture and survives process restarts. Set to
  /// `false` to opt out entirely — no PIN is ever written to disk and the
  /// biometric button never appears. See [BiometricPinStore] for the security
  /// trade-offs.
  final bool biometricUnlockEnabled;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GlobalConfig &&
          other.iosKeychainGroup == iosKeychainGroup &&
          other.syncEnabled == syncEnabled &&
          other.cloudBackend == cloudBackend &&
          other.pinTheme == pinTheme &&
          other.pinPolicy == pinPolicy &&
          other.strings == strings &&
          other.pbkdf2Iterations == pbkdf2Iterations &&
          other.pinCacheDuration == pinCacheDuration &&
          other.biometricUnlockEnabled == biometricUnlockEnabled;

  @override
  int get hashCode => Object.hash(
        iosKeychainGroup,
        syncEnabled,
        cloudBackend,
        pinTheme,
        pinPolicy,
        strings,
        pbkdf2Iterations,
        pinCacheDuration,
        biometricUnlockEnabled,
      );
}
