// Regression test for the "backup badge says 'not backed up' after restart" bug.
//
// isKeySynced used to gate on isCloudAvailable(), which on Android reflects an
// in-memory "authorized this session" flag that resets on every cold start.
// It now queries listCloudIds() directly (a silent re-auth on Android), so the
// status is correct across restarts even when isCloudAvailable() is still false.

import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:syncing_keys/syncing_keys.dart';
import 'package:syncing_keys/syncing_keys_platform_interface.dart';

void main() {
  test('isKeySynced is true when the blob is in cloud even if '
      'isCloudAvailable() is false (cold start)', () async {
    SyncingKeysPlatform.instance =
        _FakePlatform(cloudAvailable: false, cloudIds: const ['main']);
    expect(await SyncingKeys.isKeySynced('main'), isTrue);
  });

  test('isKeySynced is false when the blob is not in cloud', () async {
    SyncingKeysPlatform.instance =
        _FakePlatform(cloudAvailable: false, cloudIds: const []);
    expect(await SyncingKeys.isKeySynced('main'), isFalse);
  });

  test('isKeySynced returns false (not throws) when cloud needs re-auth',
      () async {
    SyncingKeysPlatform.instance = _FakePlatform(
      cloudAvailable: false,
      cloudIds: const [],
      throwReauthOnList: true,
    );
    expect(await SyncingKeys.isKeySynced('main'), isFalse);
  });
}

class _FakePlatform extends SyncingKeysPlatform with MockPlatformInterfaceMixin {
  _FakePlatform({
    required this.cloudAvailable,
    required this.cloudIds,
    this.throwReauthOnList = false,
  });

  final bool cloudAvailable;
  final List<String> cloudIds;
  final bool throwReauthOnList;

  @override
  Future<void> configure({
    String? iosKeychainGroup,
    required bool syncEnabled,
  }) async {}

  @override
  Future<bool> isCloudAvailable() async => cloudAvailable;

  @override
  Future<List<String>> listCloudIds() async {
    if (throwReauthOnList) throw const CloudReauthRequiredException();
    return cloudIds;
  }

  // Unused by isKeySynced — minimal stubs.
  @override
  Future<void> storeBlob({
    required String id,
    required String blob,
    required bool syncToCloud,
    bool awaitCloud = false,
  }) async {}

  @override
  Future<BlobLookup?> readBlob({
    required String id,
    required bool allowCloudFallback,
  }) async =>
      null;

  @override
  Future<void> deleteBlob({
    required String id,
    required bool deleteFromCloud,
  }) async {}

  @override
  Future<bool> signInToCloud() async => true;

  @override
  Future<void> signOutOfCloud() async {}

  @override
  Future<List<String>> listLocalIds() async => const [];

  @override
  Future<String?> getPlatformVersion() async => 'is-key-synced-fake';
}
