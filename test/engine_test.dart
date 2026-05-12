// Drives the CrudEngine end-to-end against an in-memory fake platform.
// We seed the engine's PIN cache so no PIN sheet has to be rendered — that
// lets these tests run under plain `flutter test` rather than
// `integration_test`.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:syncing_keys/syncing_keys.dart';
import 'package:syncing_keys/syncing_keys_platform_interface.dart';
import 'package:syncing_keys/src/crypto/envelope.dart';
import 'package:syncing_keys/src/engine/crud_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // A throwaway BuildContext — the engine asks for it via contextProvider
  // but our seeded-PIN-cache flow never actually renders any UI.
  late BuildContext fakeContext;

  setUp(() {
    fakeContext = _NullContext();
  });

  // Helper — build an engine wired to a fresh fake platform and pre-seed
  // its PIN cache with [pin] so no overlay has to render.
  ({CrudEngine engine, _FakePlatform fake}) buildEngine({
    bool sync = false,
    String pin = '246813',
  }) {
    final fake = _FakePlatform();
    SyncingKeysPlatform.instance = fake;

    final engine = CrudEngine(
      config: GlobalConfig(
        syncEnabled: sync,
        // Use a low PBKDF2 cost so tests don't churn — the crypto behaviour
        // is identical at any cost factor ≥ 1.
        pbkdf2Iterations: 50000,
      ),
      contextProvider: () => fakeContext,
    );
    // Inject the seed PIN into the engine's private cache so generate /
    // get / changePin don't try to summon the bottom sheet.
    _seedPin(engine, pin);
    addTearDown(engine.dispose);
    return (engine: engine, fake: fake);
  }

  group('listKeys', () {
    test('returns one entry per locally-stored envelope', () async {
      final r = buildEngine();
      await r.engine.generateAndStoreEthereum('eth-1');
      await r.engine.generateAndStoreStarknet('stark-1');

      final keys = await r.engine.listKeys();
      expect(keys.map((k) => k.id), unorderedEquals(['eth-1', 'stark-1']));
      expect(keys.firstWhere((k) => k.id == 'eth-1').type, KeyType.ethereum);
      expect(keys.firstWhere((k) => k.id == 'stark-1').type, KeyType.starknet);
      // ts is captured at seal time, so it must be non-null and "recent".
      for (final k in keys) {
        expect(k.createdAtMs, isNotNull);
        expect(k.createdAtMs!,
            greaterThan(DateTime.now().millisecondsSinceEpoch - 60_000));
      }
    });

    test('skips ids whose blob is corrupted', () async {
      final r = buildEngine();
      await r.engine.generateAndStoreEthereum('good');
      r.fake.local['corrupt'] = 'not-a-real-envelope';

      final keys = await r.engine.listKeys();
      expect(keys.map((k) => k.id), ['good']);
    });
  });

  group('changePin', () {
    test('rotates every local id and the new PIN decrypts each', () async {
      final r = buildEngine(pin: '246813');
      await r.engine.generateAndStoreEthereum('a');
      await r.engine.generateAndStoreStarknet('b');

      final result = await r.engine.changePin(oldPin: '246813', newPin: '975312');
      expect(result.failed, isEmpty);
      expect(result.rotated, unorderedEquals(['a', 'b']));

      // Inspect the new ciphertexts directly — opens with new PIN, fails
      // with old PIN (GCM tag mismatch → WrongPinException).
      for (final id in const ['a', 'b']) {
        final env = Envelope.fromBlob(r.fake.local[id]!);
        env.open('975312'); // succeeds
        expect(() => env.open('246813'), throwsA(isA<WrongPinException>()));
      }
    });

    test('also rotates cloud-only ids when sync is enabled', () async {
      final r = buildEngine(sync: true, pin: '246813');

      // Generate one locally + sync to cloud.
      await r.engine.generateAndStoreEthereum('local');

      // Seed a cloud-only blob — same PIN, fresh envelope.
      final cloudOnly = Envelope.seal(
        privateKey: r.fake.local['local'] != null
            ? Envelope.fromBlob(r.fake.local['local']!).open('246813')
            : (throw 'fixture missing'),
        pin: '246813',
        type: KeyType.ethereum,
        iterations: 50000,
      );
      r.fake.cloud['cloud-only'] = cloudOnly.toBlob();

      final result =
          await r.engine.changePin(oldPin: '246813', newPin: '975312');
      expect(result.rotated, contains('cloud-only'));

      // After rotation the cloud copy decrypts with the new PIN.
      final after = Envelope.fromBlob(r.fake.cloud['cloud-only']!);
      after.open('975312');
    });

    test('rejects a newPin that violates the policy', () async {
      final r = buildEngine();
      await r.engine.generateAndStoreEthereum('a');
      await expectLater(
        () => r.engine.changePin(oldPin: '246813', newPin: '111111'),
        throwsArgumentError,
      );
    });

    test('throws on wrong oldPin without modifying any envelope', () async {
      final r = buildEngine(pin: '246813');
      await r.engine.generateAndStoreEthereum('a');
      final before = r.fake.local['a'];

      await expectLater(
        () => r.engine.changePin(oldPin: 'wrong!', newPin: '975312'),
        throwsA(isA<WrongPinException>()),
      );
      expect(r.fake.local['a'], equals(before));
    });
  });
}

/// We tunnel into CrudEngine's private PinCache through its public
/// `dispose()` companion. The engine exposes nothing else, so we cheat: the
/// PinCache constructor is package-public and the engine stores its
/// reference — we replicate the call inside a top-level helper.
void _seedPin(CrudEngine engine, String pin) {
  // The engine has a private `_pinCache` field. We can't access it from
  // here, so the test relies on the same TTL behaviour the engine uses —
  // generate / get pass through the same cache, and after the first
  // PinEntryOverlay.show the cache is populated. To avoid the sheet,
  // we instead inject the PIN via the engine's exposed cache-warmup
  // path: a single `generateAndStoreEthereum` would normally need to
  // render the sheet too… so instead, we render a synthetic envelope
  // with the seed PIN and then use generateAndStore via a wrapper.
  //
  // In practice we sidestep this by setting up the engine such that
  // its first interaction is `generateAndStoreEthereum`, which calls
  // `_seal` → `_pinCache.get() ?? PinEntryOverlay.show(...)`. Without a
  // pre-populated cache the test would hang on `showModalBottomSheet`.
  //
  // To avoid the hang, the engine's PinCache exposes `set(pin)` —
  // we reach in through a thin shared singleton API: see
  // `PinCacheTestAccess` below.
  PinCacheTestAccess.seed(engine, pin);
}

/// Reaches into the engine's PinCache to pre-populate a session PIN for
/// tests. This is the same as calling `set(pin)` from inside the engine.
class PinCacheTestAccess {
  PinCacheTestAccess._();
  static void seed(CrudEngine engine, String pin) {
    // The CrudEngine constructor builds a PinCache with the configured TTL.
    // We make a parallel PinCache and copy the PIN into the engine's
    // private one by leveraging the fact that PinCache.set() is public.
    // The engine exposes its cache via `pinCacheForTest` (added below in
    // src/engine/crud_engine.dart for this test-only surface).
    engine.pinCacheForTest.set(pin);
  }
}

class _NullContext extends ChangeNotifier implements BuildContext {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakePlatform extends SyncingKeysPlatform with MockPlatformInterfaceMixin {
  final Map<String, String> local = {};
  final Map<String, String> cloud = {};

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
      local[id] = cloud[id]!;
      return BlobLookup(blob: cloud[id]!, fromCloud: true);
    }
    return null;
  }

  @override
  Future<void> deleteBlob({required String id, required bool deleteFromCloud}) async {
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
  Future<String?> getPlatformVersion() async => 'engine-fake';
}
