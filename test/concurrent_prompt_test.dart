// Regression test for the "claim reward → multiple PIN prompts" bug.
//
// When several CRUD calls race (e.g. a claim that triggers a couple of
// signing calls at once), each used to hit the empty PIN cache and pop its
// own PinEntryOverlay — stacking sheets and overlapping biometric prompts.
// The CrudEngine now serialises prompt presentation through a single gate:
// the first racing call prompts, the rest queue and reuse the entered PIN.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:syncing_keys/syncing_keys.dart';
import 'package:syncing_keys/syncing_keys_platform_interface.dart';
import 'package:syncing_keys/src/crypto/envelope.dart';
import 'package:syncing_keys/src/engine/crud_engine.dart';

void main() {
  testWidgets(
      'concurrent getKey shows a single PIN sheet and reuses the entered PIN',
      (tester) async {
    const pin = '2486';

    final fake = _FakePlatform();
    SyncingKeysPlatform.instance = fake;

    // Seal one envelope under `pin` so getKey('main') has something to open.
    final priv = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
    final env = Envelope.seal(
      privateKey: priv,
      pin: pin,
      type: KeyType.ethereum,
      iterations: 50000,
    );
    fake.local['main'] = env.toBlob();

    final navKey = GlobalKey<NavigatorState>();
    final engine = CrudEngine(
      // biometricUnlockEnabled: false keeps local_auth out of this widget test
      // (no platform channel) — the gate behaviour is identical either way.
      config: const GlobalConfig(
        syncEnabled: false,
        biometricUnlockEnabled: false,
        pbkdf2Iterations: 50000,
        pinTheme: PinTheme(pinLength: 4),
      ),
      contextProvider: () => navKey.currentContext!,
    );
    addTearDown(engine.dispose);

    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      home: const Scaffold(body: SizedBox.expand()),
    ));

    // Fire two concurrent reads — the real-world "tap claim" race.
    final f1 = engine.getKey('main');
    final f2 = engine.getKey('main');

    // Let the readBlob futures resolve and the first sheet animate in.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    // Exactly ONE sheet on screen — the gate queued the second read instead
    // of stacking another overlay.
    expect(find.bySemanticsLabel('Digit 5'), findsOneWidget);

    // Enter the PIN once.
    for (final d in pin.split('')) {
      await tester.tap(find.bySemanticsLabel('Digit $d'));
      await tester.pump(const Duration(milliseconds: 60));
    }
    await tester.pumpAndSettle();

    // No second sheet was ever shown — the queued read reused the cached PIN.
    expect(find.bySemanticsLabel('Digit 5'), findsNothing);

    final k1 = await f1;
    final k2 = await f2;
    expect(k1.publicAddress, isNotEmpty);
    expect(k2.publicAddress, k1.publicAddress);
    k1.dispose();
    k2.dispose();
  });
}

class _FakePlatform extends SyncingKeysPlatform with MockPlatformInterfaceMixin {
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
    if (local[id] != null) {
      return BlobLookup(blob: local[id]!, fromCloud: false);
    }
    if (allowCloudFallback && cloud[id] != null) {
      local[id] = cloud[id]!;
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
  Future<String?> getPlatformVersion() async => 'concurrent-fake';
}
