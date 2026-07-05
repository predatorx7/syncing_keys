// Exercises the Phase-0 additions to CrudEngine: runtime sync config,
// cross-backend switching, conflict detection, and import validation. Runs
// against an in-memory per-backend fake platform with a seeded PIN so no PIN
// sheet renders under plain `flutter test`.

import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:syncing_keys/syncing_keys.dart';
import 'package:syncing_keys/syncing_keys_platform_interface.dart';
import 'package:syncing_keys/src/crypto/envelope.dart';
import 'package:syncing_keys/src/engine/crud_engine.dart';
import 'package:syncing_keys/src/keygen/starknet_key_generator.dart';

const _pin = '246813';
const _iter = 50000;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BuildContext ctx;
  setUp(() => ctx = _NullContext());

  ({CrudEngine engine, _BackendFake fake}) buildEngine({
    bool sync = true,
    CloudBackend? backend = CloudBackend.googleDrive,
  }) {
    final fake = _BackendFake()
      ..syncEnabled = sync
      ..backend = backend;
    SyncingKeysPlatform.instance = fake;
    final engine = CrudEngine(
      config: GlobalConfig(
        syncEnabled: sync,
        cloudBackend: backend,
        pbkdf2Iterations: _iter,
        biometricUnlockEnabled: false,
      ),
      contextProvider: () => ctx,
    );
    engine.pinCacheForTest.set(_pin);
    addTearDown(engine.dispose);
    return (engine: engine, fake: fake);
  }

  // Deterministic valid STARK envelope for the given small scalar.
  ({String blob, String pubkey}) sealScalar(int scalar, {String pin = _pin}) {
    final priv = _scalarBytes(scalar);
    final env = Envelope.seal(
      privateKey: priv,
      pin: pin,
      type: KeyType.starknet,
      iterations: _iter,
    );
    return (blob: env.toBlob(), pubkey: StarknetKeyGenerator.publicAddressFor(priv));
  }

  group('setRuntimeConfig', () {
    test('runtime enable/disable is honoured by storeBlob sync', () async {
      final r = buildEngine(sync: false, backend: CloudBackend.local);
      await r.engine.generateAndStoreStarknet('main');
      expect(r.fake.stores['googleDrive'], isEmpty,
          reason: 'sync off → no cloud copy');

      await r.engine.setRuntimeConfig(
          syncEnabled: true, backend: CloudBackend.googleDrive);
      expect(r.fake.syncEnabled, isTrue);
      expect(r.fake.backend, CloudBackend.googleDrive);
    });
  });

  group('switchBackend', () {
    test('moves the cloud copy to the target and clears others', () async {
      final r = buildEngine();
      // Seed local + a cloud copy on appleKeychain (as if that was the old one).
      final seeded = sealScalar(5);
      r.fake.stores['local']!['main'] = seeded.blob;
      r.fake.stores['appleKeychain']!['main'] = seeded.blob;

      await r.engine.switchBackend('main', CloudBackend.googleDrive);

      expect(r.fake.stores['googleDrive']!['main'], seeded.blob,
          reason: 'target now holds the copy');
      expect(r.fake.stores['appleKeychain'], isEmpty,
          reason: 'old cloud backend cleared');
      expect(r.fake.stores['local']!['main'], seeded.blob,
          reason: 'local copy always retained');
      expect(r.fake.syncEnabled, isTrue);
      expect(r.fake.backend, CloudBackend.googleDrive);
    });

    test('switching to local removes all cloud copies', () async {
      final r = buildEngine();
      final seeded = sealScalar(9);
      r.fake.stores['local']!['main'] = seeded.blob;
      r.fake.stores['googleDrive']!['main'] = seeded.blob;

      await r.engine.switchBackend('main', CloudBackend.local);

      expect(r.fake.stores['googleDrive'], isEmpty);
      expect(r.fake.stores['local']!['main'], seeded.blob);
      expect(r.fake.syncEnabled, isFalse);
    });
  });

  group('checkConflict', () {
    test('no conflict when cloud is absent', () async {
      final r = buildEngine();
      r.fake.stores['local']!['main'] = sealScalar(5).blob;
      final c = await r.engine.checkConflict('main');
      expect(c.hasConflict, isFalse);
    });

    test('no conflict when cloud holds the same key (benign re-seal)', () async {
      final r = buildEngine();
      r.fake.stores['local']!['main'] = sealScalar(5).blob;
      // Different envelope bytes (fresh salt/iv) but same key + PIN.
      r.fake.stores['googleDrive']!['main'] = sealScalar(5).blob;

      final c = await r.engine.checkConflict('main');
      expect(c.hasConflict, isFalse);
      expect(c.localPublicAddress, c.cloudPublicAddress);
    });

    test('conflict when cloud holds a different key', () async {
      final r = buildEngine();
      final local = sealScalar(5);
      final cloud = sealScalar(7);
      r.fake.stores['local']!['main'] = local.blob;
      r.fake.stores['googleDrive']!['main'] = cloud.blob;

      final c = await r.engine.checkConflict('main');
      expect(c.hasConflict, isTrue);
      expect(c.localPublicAddress, local.pubkey);
      expect(c.cloudPublicAddress, cloud.pubkey);
      expect(c.backend, CloudBackend.googleDrive);
    });

    test('passive check returns undetermined when no PIN is cached', () async {
      final r = buildEngine();
      r.engine.pinCacheForTest.clear();
      r.fake.stores['local']!['main'] = sealScalar(5).blob;
      r.fake.stores['googleDrive']!['main'] = sealScalar(7).blob;

      final c = await r.engine.checkConflict('main', promptIfNeeded: false);
      expect(c.undetermined, isTrue);
      expect(c.hasConflict, isFalse);
    });

    test('conflict (undecryptable) when cloud sealed under a different PIN',
        () async {
      final r = buildEngine();
      r.fake.stores['local']!['main'] = sealScalar(5).blob;
      r.fake.stores['googleDrive']!['main'] =
          sealScalar(5, pin: '999999').blob; // same key, wrong PIN era

      final c = await r.engine.checkConflict('main');
      expect(c.hasConflict, isTrue);
      expect(c.cloudUndecryptable, isTrue);
      expect(c.cloudPublicAddress, isNull);
    });
  });

  group('resolveConflict', () {
    test('keepLocal overwrites the cloud copy', () async {
      final r = buildEngine();
      final local = sealScalar(5);
      r.fake.stores['local']!['main'] = local.blob;
      r.fake.stores['googleDrive']!['main'] = sealScalar(7).blob;

      await r.engine.resolveConflict(
          'main', ConflictResolution.keepLocal, CloudBackend.googleDrive);
      expect(r.fake.stores['googleDrive']!['main'], local.blob);
    });

    test('keepCloud overwrites the local copy', () async {
      final r = buildEngine();
      final cloud = sealScalar(7);
      r.fake.stores['local']!['main'] = sealScalar(5).blob;
      r.fake.stores['googleDrive']!['main'] = cloud.blob;

      await r.engine.resolveConflict(
          'main', ConflictResolution.keepCloud, CloudBackend.googleDrive);
      expect(r.fake.stores['local']!['main'], cloud.blob);
    });
  });

  group('import validation', () {
    test('rejects an all-zero (out-of-range) stark scalar', () async {
      final r = buildEngine();
      await expectLater(
        () => r.engine.saveKey(
          id: 'main',
          privateKey: Uint8List(32),
          type: KeyType.starknet,
        ),
        throwsArgumentError,
      );
    });

    test('rejects a scalar >= the curve order', () async {
      final r = buildEngine();
      final tooBig = _bigIntBytes(StarknetKeyGenerator.curveOrder);
      await expectLater(
        () => r.engine.saveKey(
          id: 'main',
          privateKey: tooBig,
          type: KeyType.starknet,
        ),
        throwsArgumentError,
      );
    });

    test('accepts a valid stark scalar and seals it', () async {
      final r = buildEngine();
      await r.engine.saveKey(
        id: 'main',
        privateKey: _scalarBytes(12345),
        type: KeyType.starknet,
      );
      expect(r.fake.stores['local']!['main'], isNotNull);
    });
  });
}

Uint8List _scalarBytes(int v) => _bigIntBytes(BigInt.from(v));

Uint8List _bigIntBytes(BigInt v) {
  var hex = v.toRadixString(16);
  if (hex.length.isOdd) hex = '0$hex';
  hex = hex.padLeft(64, '0');
  return Uint8List.fromList(List.generate(
      32, (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16)));
}

class _NullContext extends ChangeNotifier implements BuildContext {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Fake platform with an independent store per backend, so migration and
/// conflict logic can be observed directly.
class _BackendFake extends SyncingKeysPlatform with MockPlatformInterfaceMixin {
  final Map<String, Map<String, String>> stores = {
    'local': {},
    'appleKeychain': {},
    'googleDrive': {},
  };
  bool syncEnabled = false;
  CloudBackend? backend;

  Map<String, String> _store(CloudBackend b) => stores[b.name]!;
  CloudBackend? get _activeCloud =>
      (backend != null && backend!.isCloud) ? backend : null;

  @override
  Future<void> configure({
    String? iosKeychainGroup,
    required bool syncEnabled,
  }) async {}

  @override
  Future<void> setRuntimeConfig({
    required bool syncEnabled,
    CloudBackend? backend,
  }) async {
    this.syncEnabled = syncEnabled;
    this.backend = backend;
  }

  @override
  Future<BlobLookup?> readBlobFromBackend({
    required String id,
    required CloudBackend backend,
  }) async {
    final v = _store(backend)[id];
    return v == null ? null : BlobLookup(blob: v, fromCloud: backend.isCloud);
  }

  @override
  Future<void> writeBlobToBackend({
    required String id,
    required String blob,
    required CloudBackend backend,
  }) async {
    _store(backend)[id] = blob;
  }

  @override
  Future<void> deleteBlobFromBackend({
    required String id,
    required CloudBackend backend,
  }) async {
    _store(backend).remove(id);
  }

  @override
  Future<void> storeBlob({
    required String id,
    required String blob,
    required bool syncToCloud,
    bool awaitCloud = false,
  }) async {
    stores['local']![id] = blob;
    final cloud = _activeCloud;
    if (syncToCloud && cloud != null) _store(cloud)[id] = blob;
  }

  @override
  Future<BlobLookup?> readBlob({
    required String id,
    required bool allowCloudFallback,
  }) async {
    final local = stores['local']![id];
    if (local != null) return BlobLookup(blob: local, fromCloud: false);
    final cloud = _activeCloud;
    if (allowCloudFallback && cloud != null && _store(cloud)[id] != null) {
      stores['local']![id] = _store(cloud)[id]!;
      return BlobLookup(blob: _store(cloud)[id]!, fromCloud: true);
    }
    return null;
  }

  @override
  Future<void> deleteBlob({
    required String id,
    required bool deleteFromCloud,
  }) async {
    stores['local']!.remove(id);
    if (deleteFromCloud) {
      for (final b in CloudBackend.values.where((b) => b.isCloud)) {
        _store(b).remove(id);
      }
    }
  }

  @override
  Future<bool> isCloudAvailable() async => true;

  @override
  Future<bool> signInToCloud() async => true;

  @override
  Future<void> signOutOfCloud() async {}

  @override
  Future<List<String>> listLocalIds() async => stores['local']!.keys.toList();

  @override
  Future<List<String>> listCloudIds() async =>
      _activeCloud == null ? const [] : _store(_activeCloud!).keys.toList();

  @override
  Future<String?> getPlatformVersion() async => 'backend-fake';
}
