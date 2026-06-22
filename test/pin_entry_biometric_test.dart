// Widget tests for the PIN sheet's biometric unlock path.
//
// Verifies the bug that was reported ("after verifying with biometrics it
// doesn't close"):
//   • on a successful biometric gesture the sheet *pops* with the stored PIN,
//   • when no PIN is stored the biometric button is not even shown,
//   • a failed/cancelled gesture leaves the sheet open for manual typing.
//
// local_auth is faked at the platform-interface layer (no method channels) so
// the test is robust across plugin versions.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth_platform_interface/local_auth_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:syncing_keys/syncing_keys.dart';
import 'package:syncing_keys/src/ui/pin_entry_overlay.dart';

class _FakeLocalAuth extends LocalAuthPlatform with MockPlatformInterfaceMixin {
  _FakeLocalAuth({required this.authResult});

  /// What `authenticate` resolves to — true = gesture succeeded.
  final bool authResult;
  int authCalls = 0;

  @override
  Future<bool> deviceSupportsBiometrics() async => true;

  @override
  Future<List<BiometricType>> getEnrolledBiometrics() async =>
      const [BiometricType.fingerprint];

  @override
  Future<bool> isDeviceSupported() async => true;

  @override
  Future<bool> authenticate({
    required String localizedReason,
    required Iterable<AuthMessages> authMessages,
    AuthenticationOptions options = const AuthenticationOptions(),
  }) async {
    authCalls++;
    return authResult;
  }
}

Future<String?> Function() _showHelper(
  GlobalKey<NavigatorState> navKey, {
  required Future<bool> Function()? hasStoredPin,
  required Future<String?> Function()? readStoredPin,
  void Function(Object)? onError,
}) {
  return () async {
    try {
      return await PinEntryOverlay.show(
        context: navKey.currentContext!,
        theme: const PinTheme(pinLength: 4),
        purpose: PinPurpose.decrypt,
        hasStoredPin: hasStoredPin,
        readStoredPin: readStoredPin,
      );
    } catch (e) {
      onError?.call(e);
      return null;
    }
  };
}

void main() {
  testWidgets('biometric success closes the sheet with the stored PIN',
      (tester) async {
    final original = LocalAuthPlatform.instance;
    final fake = _FakeLocalAuth(authResult: true);
    LocalAuthPlatform.instance = fake;
    addTearDown(() => LocalAuthPlatform.instance = original);

    final navKey = GlobalKey<NavigatorState>();
    String? returned;

    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      home: const Scaffold(body: SizedBox.expand()),
    ));

    final show = _showHelper(
      navKey,
      hasStoredPin: () async => true,
      readStoredPin: () async => '2486',
    );
    unawaited(show().then((v) => returned = v));

    await tester.pumpAndSettle();

    expect(fake.authCalls, 1, reason: 'biometric should auto-prompt on open');
    expect(returned, '2486', reason: 'sheet must pop with the stored PIN');
    // Sheet is gone.
    expect(find.bySemanticsLabel('Digit 2'), findsNothing);
  });

  testWidgets('no biometric button when nothing is stored', (tester) async {
    final original = LocalAuthPlatform.instance;
    final fake = _FakeLocalAuth(authResult: true);
    LocalAuthPlatform.instance = fake;
    addTearDown(() => LocalAuthPlatform.instance = original);

    final navKey = GlobalKey<NavigatorState>();

    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      home: const Scaffold(body: SizedBox.expand()),
    ));

    unawaited(_showHelper(
      navKey,
      hasStoredPin: () async => false, // nothing persisted
      readStoredPin: () async => null,
    )());
    await tester.pumpAndSettle();

    expect(fake.authCalls, 0, reason: 'no auto-prompt without a stored PIN');
    expect(find.bySemanticsLabel('Unlock with biometrics'), findsNothing);
    // Manual entry still works.
    expect(find.bySemanticsLabel('Digit 2'), findsOneWidget);
  });

  testWidgets('failed gesture leaves the sheet open for manual entry',
      (tester) async {
    final original = LocalAuthPlatform.instance;
    final fake = _FakeLocalAuth(authResult: false); // user cancelled
    LocalAuthPlatform.instance = fake;
    addTearDown(() => LocalAuthPlatform.instance = original);

    final navKey = GlobalKey<NavigatorState>();
    String? returned;

    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      home: const Scaffold(body: SizedBox.expand()),
    ));

    unawaited(_showHelper(
      navKey,
      hasStoredPin: () async => true,
      readStoredPin: () async => '2486',
    )().then((v) => returned = v));
    await tester.pumpAndSettle();

    expect(fake.authCalls, 1);
    expect(returned, isNull, reason: 'a cancelled gesture must not pop');

    // Type the PIN by hand — the sheet is still there.
    for (final d in ['2', '4', '8', '6']) {
      await tester.tap(find.bySemanticsLabel('Digit $d'));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
    expect(returned, '2486');
  });
}
