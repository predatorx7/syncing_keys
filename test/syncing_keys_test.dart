import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:syncing_keys/syncing_keys_method_channel.dart';
import 'package:syncing_keys/syncing_keys_platform_interface.dart';

/// In-memory fake that lets us exercise the Dart layer end-to-end without
/// touching a real Keychain / Drive. Each blob is keyed by id; `fromCloud`
/// is set whenever the fake had to "round-trip".
class FakeSyncingKeysPlatform extends SyncingKeysPlatform
    with MockPlatformInterfaceMixin {
  final Map<String, String> local = {};
  final Map<String, String> cloud = {};

  @override
  Future<void> configure({
    String? iosKeychainGroup,
    required bool syncEnabled,
  }) async {}

  @override
  Future<void> storeBlob({
    required String id,
    required String blob,
    required bool syncToCloud,
  }) async {
    local[id] = blob;
    if (syncToCloud) cloud[id] = blob;
  }

  @override
  Future<BlobLookup?> readBlob({
    required String id,
    required bool allowCloudFallback,
  }) async {
    if (local[id] != null) return BlobLookup(blob: local[id]!, fromCloud: false);
    if (allowCloudFallback && cloud[id] != null) {
      local[id] = cloud[id]!; // mirror native re-save behaviour
      return BlobLookup(blob: cloud[id]!, fromCloud: true);
    }
    return null;
  }

  @override
  Future<void> deleteBlob({
    required String id,
    required bool deleteFromCloud,
  }) async {
    local.remove(id);
    if (deleteFromCloud) cloud.remove(id);
  }

  @override
  Future<bool> isCloudAvailable() async => true;

  @override
  Future<bool> signInToCloud() async => true;

  @override
  Future<void> signOutOfCloud() async {}

  @override
  Future<List<String>> listLocalIds() async => local.keys.toList();

  @override
  Future<List<String>> listCloudIds() async => cloud.keys.toList();

  @override
  Future<String?> getPlatformVersion() async => 'fake-1.0';
}

void main() {
  test('default platform instance is MethodChannelSyncingKeys', () {
    final initial = SyncingKeysPlatform.instance;
    expect(initial, isA<MethodChannelSyncingKeys>());
  });

  test('FakeSyncingKeysPlatform round-trips blobs', () async {
    final fake = FakeSyncingKeysPlatform();
    SyncingKeysPlatform.instance = fake;

    await fake.storeBlob(id: 'a', blob: 'hello', syncToCloud: true);

    final lookup = await fake.readBlob(id: 'a', allowCloudFallback: false);
    expect(lookup?.blob, 'hello');

    // Wipe local; cloud fallback should restore.
    fake.local.clear();
    final restored = await fake.readBlob(id: 'a', allowCloudFallback: true);
    expect(restored?.blob, 'hello');
    expect(restored?.fromCloud, true);
  });
}
