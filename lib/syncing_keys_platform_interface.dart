import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'syncing_keys_method_channel.dart';

/// Platform-interface contract that the iOS and Android implementations
/// fulfil. All methods deal in **opaque encrypted envelopes** (base64
/// strings); the native sides never see plaintext key material.
abstract class SyncingKeysPlatform extends PlatformInterface {
  SyncingKeysPlatform() : super(token: _token);

  static final Object _token = Object();

  static SyncingKeysPlatform _instance = MethodChannelSyncingKeys();

  static SyncingKeysPlatform get instance => _instance;

  static set instance(SyncingKeysPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// Push the global configuration to the native side once. The Dart layer
  /// guarantees this is called before any CRUD.
  Future<void> configure({
    String? iosKeychainGroup,
    String? androidDriveClientId,
    required bool syncEnabled,
  });

  /// Store an opaque encrypted [blob] under [id]. If sync is enabled the
  /// native side is expected to also push the blob to iCloud (iOS) / Drive
  /// `appDataFolder` (Android).
  Future<void> storeBlob({
    required String id,
    required String blob,
    required bool syncToCloud,
  });

  /// Returns the stored blob for [id], or `null` if not found anywhere.
  ///
  /// Implementations should try the local store first (fast path) and fall
  /// back to cloud retrieval when local is empty.
  Future<BlobLookup?> readBlob({
    required String id,
    required bool allowCloudFallback,
  });

  /// Removes [id] from both local storage and the cloud (best-effort).
  Future<void> deleteBlob({
    required String id,
    required bool deleteFromCloud,
  });

  /// Returns the list of locally-stored ids. The platform-side iteration
  /// does **not** touch the cloud — call [readBlob] with cloud fallback for
  /// each id you don't recognise if you want a union.
  Future<List<String>> listLocalIds();

  /// Returns the list of ids that exist in the cloud (iCloud Keychain on
  /// iOS, Drive `appDataFolder` on Android) but might not be present
  /// locally. Implementations may return ids that *also* exist locally —
  /// the Dart side de-dups against [listLocalIds]. Returns an empty list
  /// when sync is disabled or no cloud account is signed in.
  Future<List<String>> listCloudIds();

  /// Whether the platform claims to have a usable cloud backend for the
  /// current configuration. Used by the Dart side to short-circuit cloud
  /// branches when, e.g., the user has not signed into Google.
  Future<bool> isCloudAvailable();

  /// Asks the platform to surface its cloud sign-in flow.
  ///
  /// - **Android:** launches the Google account picker; returns `true` if the
  ///   user grants the `drive.appdata` scope, `false` on user cancel.
  /// - **iOS:** no-op — iCloud sign-in is owned by the OS, the developer
  ///   should not be able to surface it from inside the app. Always `true`.
  Future<bool> signInToCloud();

  /// Forgets the cached cloud account on the platform side. Does **not**
  /// delete any cloud blobs — call [deleteBlob] for that.
  Future<void> signOutOfCloud();

  /// Optional helper — returns the platform's debug version string.
  Future<String?> getPlatformVersion();
}

/// Value type for the platform's blob lookup response.
class BlobLookup {
  const BlobLookup({required this.blob, required this.fromCloud});
  final String blob;
  final bool fromCloud;
}
