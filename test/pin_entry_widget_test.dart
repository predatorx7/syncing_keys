// Widget test for the PIN entry sheet's PinPolicy integration.
//
// Verifies that:
//   • a policy-violating PIN is rejected without popping the sheet,
//   • the rejection reason is surfaced inline,
//   • a subsequent valid PIN does pop and resolves to the entered digits.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncing_keys/syncing_keys.dart';
import 'package:syncing_keys/src/ui/pin_entry_overlay.dart';

void main() {
  testWidgets('rejecting PIN keeps sheet open and shows reason', (tester) async {
    String? returnedPin;
    Object? returnedError;
    final navKey = GlobalKey<NavigatorState>();

    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      home: Scaffold(
        body: Builder(builder: (ctx) {
          return ElevatedButton(
            onPressed: () async {
              try {
                returnedPin = await PinEntryOverlay.show(
                  context: ctx,
                  theme: const PinTheme(pinLength: 4),
                  purpose: PinPurpose.encrypt,
                  policy: const PinPolicy(),
                );
              } catch (e) {
                returnedError = e;
              }
            },
            child: const Text('open'),
          );
        }),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Type "1111" — should be rejected as all-same-digit. We probe by
    // Semantics labels because the keypad uses them for screen-reader
    // accessibility (and tests).
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.bySemanticsLabel('Digit 1'));
      await tester.pump(const Duration(milliseconds: 100));
    }
    // _submit runs ~80ms after the last digit; let it complete.
    await tester.pump(const Duration(milliseconds: 250));

    // The rejection reason should be on screen and the sheet still up.
    expect(find.textContaining('repeating'), findsOneWidget);
    expect(returnedPin, isNull, reason: 'sheet must not have popped');
    expect(returnedError, isNull);

    // Now type a valid PIN — 2486.
    await tester.tap(find.bySemanticsLabel('Digit 2'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.bySemanticsLabel('Digit 4'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.bySemanticsLabel('Digit 8'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.bySemanticsLabel('Digit 6'));
    await tester.pumpAndSettle();

    expect(returnedPin, '2486');
  });
}
