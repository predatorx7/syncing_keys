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
    this.pinTheme = const PinTheme(),
    this.pinPolicy = const PinPolicy(),
    this.strings = const SyncingKeysStrings(),
    this.pbkdf2Iterations = 120000,
    this.pinCacheDuration = const Duration(minutes: 10),
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

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GlobalConfig &&
          other.iosKeychainGroup == iosKeychainGroup &&
          other.syncEnabled == syncEnabled &&
          other.pinTheme == pinTheme &&
          other.pinPolicy == pinPolicy &&
          other.strings == strings &&
          other.pbkdf2Iterations == pbkdf2Iterations &&
          other.pinCacheDuration == pinCacheDuration;

  @override
  int get hashCode => Object.hash(
        iosKeychainGroup,
        syncEnabled,
        pinTheme,
        pinPolicy,
        strings,
        pbkdf2Iterations,
        pinCacheDuration,
      );
}
