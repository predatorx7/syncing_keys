import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'src/models/exceptions.dart';
import 'syncing_keys_platform_interface.dart';

/// MethodChannel-backed implementation of [SyncingKeysPlatform].
///
/// Channel name is namespaced under the package id so multiple plugins can
/// coexist without colliding.
///
/// Every native `result.error(code, …)` is translated to a typed
/// [SyncingKeysException] subclass so callers can `catch` over a single
/// sealed hierarchy instead of inspecting [PlatformException.code] strings.
class MethodChannelSyncingKeys extends SyncingKeysPlatform {
  @visibleForTesting
  final methodChannel =
      const MethodChannel('app.xyz.everydayapp.syncing_keys/syncing_keys');

  /// Funnel every channel invocation through a single typed wrapper.
  Future<T?> _invoke<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await methodChannel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      throw _translate(e);
    }
  }

  Future<Map<String, dynamic>?> _invokeMap(
      String method, Map<String, Object?> args) async {
    try {
      return await methodChannel.invokeMapMethod<String, dynamic>(method, args);
    } on PlatformException catch (e) {
      throw _translate(e);
    }
  }

  Future<List<T>?> _invokeList<T>(String method) async {
    try {
      return await methodChannel.invokeListMethod<T>(method);
    } on PlatformException catch (e) {
      throw _translate(e);
    }
  }

  SyncingKeysException _translate(PlatformException e) {
    switch (e.code) {
      case 'PLAY_SERVICES_UNAVAILABLE':
        // The native side stuffs the integer ConnectionResult code into
        // `details` as a string; parse it back so the typed exception
        // carries a useful enum-like value.
        final code = int.tryParse((e.details ?? '').toString()) ?? -1;
        return PlayServicesUnavailableException(code, e.message);
      default:
        return PlatformChannelException(e.code, e.message);
    }
  }

  @override
  Future<void> configure({
    String? iosKeychainGroup,
    required bool syncEnabled,
  }) async {
    await _invoke<void>('configure', <String, Object?>{
      'iosKeychainGroup': iosKeychainGroup,
      'syncEnabled': syncEnabled,
    });
  }

  @override
  Future<void> storeBlob({
    required String id,
    required String blob,
    required bool syncToCloud,
  }) async {
    await _invoke<void>('storeBlob', <String, Object?>{
      'id': id,
      'blob': blob,
      'syncToCloud': syncToCloud,
    });
  }

  @override
  Future<BlobLookup?> readBlob({
    required String id,
    required bool allowCloudFallback,
  }) async {
    final result = await _invokeMap('readBlob', <String, Object?>{
      'id': id,
      'allowCloudFallback': allowCloudFallback,
    });
    if (result == null || result['blob'] == null) return null;
    return BlobLookup(
      blob: result['blob'] as String,
      fromCloud: (result['fromCloud'] as bool?) ?? false,
    );
  }

  @override
  Future<void> deleteBlob({
    required String id,
    required bool deleteFromCloud,
  }) async {
    await _invoke<void>('deleteBlob', <String, Object?>{
      'id': id,
      'deleteFromCloud': deleteFromCloud,
    });
  }

  @override
  Future<List<String>> listLocalIds() async {
    final result = await _invokeList<String>('listLocalIds');
    return result ?? const <String>[];
  }

  @override
  Future<List<String>> listCloudIds() async {
    final result = await _invokeList<String>('listCloudIds');
    return result ?? const <String>[];
  }

  @override
  Future<bool> isCloudAvailable() async {
    final v = await _invoke<bool>('isCloudAvailable');
    return v ?? false;
  }

  @override
  Future<bool> signInToCloud() async {
    final v = await _invoke<bool>('signIn');
    return v ?? false;
  }

  @override
  Future<void> signOutOfCloud() async {
    await _invoke<void>('signOut');
  }

  @override
  Future<String?> getPlatformVersion() => _invoke<String>('getPlatformVersion');
}
