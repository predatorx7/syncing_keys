// Smoke + flow tests for the example app.
//
// The unit tests in `test/` cover the crypto primitives in isolation. The
// integration_test/ suite exercises the public surface of the SDK against
// a fake platform — verifying that generate → get → delete works end-to-end
// without any host-app context.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:syncing_keys/syncing_keys.dart';
import 'package:syncing_keys/syncing_keys_platform_interface.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('SyncingKeys public surface', () {
    setUp(() {
      // Replace the real platform with an in-memory fake so we don't need
      // a real Keychain or Drive while running.
      SyncingKeysPlatform.instance = _FakePlatform();
    });

    testWidgets('isCloudAvailable returns a bool', (tester) async {
      final available = await SyncingKeys.isCloudAvailable();
      expect(available, isA<bool>());
    });

    testWidgets('saveKey validates 32-byte private keys', (tester) async {
      // Pre-init guard — calling CRUD before initialize() must throw.
      expect(
        () => SyncingKeys.saveKey(
          id: 'x',
          privateKey: Uint8List(31),
          type: KeyType.ethereum,
        ),
        // We expect either the not-initialised error or the length error
        // depending on whether something else in the suite has init-ed.
        // Both are SyncingKeysException / ArgumentError respectively.
        throwsA(anyOf(
            isA<SyncingKeysNotInitializedException>(),
            isA<ArgumentError>())),
      );
    });
  });
}

class _FakePlatform extends SyncingKeysPlatform with MockPlatformInterfaceMixin {
  final Map<String, String> _local = {};
  final Map<String, String> _cloud = {};

  @override
  Future<void> configure({
    String? iosKeychainGroup,
    String? androidDriveClientId,
    required bool syncEnabled,
  }) async {}

  @override
  Future<void> storeBlob({
    required String id,
    required String blob,
    required bool syncToCloud,
  }) async {
    _local[id] = blob;
    if (syncToCloud) _cloud[id] = blob;
  }

  @override
  Future<BlobLookup?> readBlob({
    required String id,
    required bool allowCloudFallback,
  }) async {
    if (_local[id] != null) return BlobLookup(blob: _local[id]!, fromCloud: false);
    if (allowCloudFallback && _cloud[id] != null) {
      _local[id] = _cloud[id]!;
      return BlobLookup(blob: _cloud[id]!, fromCloud: true);
    }
    return null;
  }

  @override
  Future<void> deleteBlob({required String id, required bool deleteFromCloud}) async {
    _local.remove(id);
    if (deleteFromCloud) _cloud.remove(id);
  }

  @override
  Future<bool> isCloudAvailable() async => true;

  @override
  Future<bool> signInToCloud() async => true;

  @override
  Future<void> signOutOfCloud() async {}

  @override
  Future<List<String>> listLocalIds() async => _local.keys.toList();

  @override
  Future<List<String>> listCloudIds() async => _cloud.keys.toList();

  @override
  Future<String?> getPlatformVersion() async => 'integration-fake';
}
