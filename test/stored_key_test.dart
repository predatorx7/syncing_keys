import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncing_keys/syncing_keys.dart';

void main() {
  group('StoredKey memory hygiene', () {
    StoredKey newKey() => StoredKey(
          id: 'main',
          type: KeyType.ethereum,
          privateKey: Uint8List.fromList(List.generate(32, (i) => i + 1)),
          publicAddress: '0x${'aa' * 20}',
        );

    test('dispose() zeroes the privateKey buffer', () {
      final k = newKey();
      expect(k.privateKey.any((b) => b != 0), isTrue, reason: 'sanity');
      k.dispose();
      expect(k.privateKey.every((b) => b == 0), isTrue);
    });

    test('dispose() is idempotent', () {
      final k = newKey()..dispose();
      k.dispose(); // should not throw
      expect(k.privateKey.every((b) => b == 0), isTrue);
    });

    test('withKey() runs body and zeroes on success', () async {
      final k = newKey();
      final sum = await k.withKey<int>((kk) async =>
          kk.privateKey.fold<int>(0, (a, b) => a + b));
      expect(sum, equals((32 * 33) ~/ 2));
      expect(k.privateKey.every((b) => b == 0), isTrue);
    });

    test('withKey() zeroes even when body throws', () async {
      final k = newKey();
      await expectLater(
        () => k.withKey<void>((_) async => throw StateError('boom')),
        throwsStateError,
      );
      expect(k.privateKey.every((b) => b == 0), isTrue);
    });
  });
}
