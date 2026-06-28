// Regression test for the "reinstall → can't restore key" bug.
//
// On a fresh install the local store is empty, so getKey falls back to the
// cloud. If the cloud needs sign-in (Android Drive not authorized yet), the
// native side now reports CLOUD_REAUTH_REQUIRED instead of swallowing it to
// null. getKey must propagate that as CloudReauthRequiredException so the host
// app can prompt sign-in + retry — NOT mask it as KeyNotFoundException.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:syncing_keys/syncing_keys.dart';
import 'package:syncing_keys/syncing_keys_platform_interface.dart';
import 'package:syncing_keys/src/engine/crud_engine.dart';

void main() {
  CrudEngine buildEngine(_FakePlatform fake, GlobalKey<NavigatorState> navKey) {
    SyncingKeysPlatform.instance = fake;
    final engine = CrudEngine(
      config: const GlobalConfig(
        syncEnabled: true,
        biometricUnlockEnabled: false,
        pbkdf2Iterations: 50000,
      ),
      contextProvider: () => navKey.currentContext!,
    );
    addTearDown(engine.dispose);
    return engine;
  }

  Future<void> pumpHost(WidgetTester tester, GlobalKey<NavigatorState> navKey) {
    return tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      home: const Scaffold(body: SizedBox.expand()),
    ));
  }

  testWidgets(
      'getKey propagates CloudReauthRequiredException from the cloud fallback',
      (tester) async {
    final navKey = GlobalKey<NavigatorState>();
    final engine = buildEngine(_FakePlatform(cloudNeedsReauth: true), navKey);
    await pumpHost(tester, navKey);

    // Attach the matcher synchronously (before pumping) so the future's error
    // is handled the instant it rejects during pump.
    final expectation = expectLater(
      engine.getKey('main'),
      throwsA(isA<CloudReauthRequiredException>()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await expectation;
    await tester.pumpAndSettle();
  });

  testWidgets('getKey still throws KeyNotFoundException when truly absent',
      (tester) async {
    final navKey = GlobalKey<NavigatorState>();
    final engine = buildEngine(_FakePlatform(cloudNeedsReauth: false), navKey);
    await pumpHost(tester, navKey);

    final expectation =
        expectLater(engine.getKey('main'), throwsA(isA<KeyNotFoundException>()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await expectation;
    await tester.pumpAndSettle();
  });
}

class _FakePlatform extends SyncingKeysPlatform with MockPlatformInterfaceMixin {
  _FakePlatform({required this.cloudNeedsReauth});

  /// When true, the cloud-fallback read throws CloudReauthRequiredException
  /// (simulating Drive not authorized). When false, it returns null (no blob).
  final bool cloudNeedsReauth;

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
    bool awaitCloud = false,
  }) async {}

  @override
  Future<BlobLookup?> readBlob({
    required String id,
    required bool allowCloudFallback,
  }) async {
    if (!allowCloudFallback) return null; // local miss (fresh install)
    if (cloudNeedsReauth) throw const CloudReauthRequiredException();
    return null; // genuinely absent in cloud
  }

  @override
  Future<void> deleteBlob({
    required String id,
    required bool deleteFromCloud,
  }) async {}

  @override
  Future<bool> isCloudAvailable() async => true;

  @override
  Future<bool> signInToCloud() async => true;

  @override
  Future<void> signOutOfCloud() async {}

  @override
  Future<List<String>> listLocalIds() async => const [];

  @override
  Future<List<String>> listCloudIds() async => const [];

  @override
  Future<String?> getPlatformVersion() async => 'reauth-fake';
}
