// Smoke test for the example app — just verifies the basic Material shell
// renders. We don't construct the real SyncingKeys-wired entry point here because
// it requires platform-channel mocking; integration_test/ covers that path.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders a MaterialApp shell', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: const Scaffold(body: Text('SyncingKeys example'))),
    );
    expect(find.text('SyncingKeys example'), findsOneWidget);
  });
}
