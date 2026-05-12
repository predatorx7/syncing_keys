import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncing_keys/syncing_keys.dart';
// Direct import so we can test the seal/open primitives independently of
// the full CRUD pipeline. The envelope is internal but stable across v1.
import 'package:syncing_keys/src/crypto/envelope.dart';

void main() {
  group('Envelope (v1)', () {
    final fakeKey = Uint8List.fromList(List.generate(32, (i) => i + 1));

    test('seal → toBlob → fromBlob → open round-trips the plaintext', () {
      final sealed = Envelope.seal(
        privateKey: fakeKey,
        pin: '123456',
        type: KeyType.ethereum,
        iterations: 1000, // low cost for test speed; crypto behaviour is identical
      );

      final wire = sealed.toBlob();
      final rehydrated = Envelope.fromBlob(wire);
      final plain = rehydrated.open('123456');

      expect(plain, equals(fakeKey));
      expect(rehydrated.type, KeyType.ethereum);
      expect(rehydrated.iterations, 1000);
    });

    test('wrong PIN throws WrongPinException (GCM tag mismatch)', () {
      final sealed = Envelope.seal(
        privateKey: fakeKey,
        pin: 'right-pin',
        type: KeyType.starknet,
        iterations: 1000,
      );

      expect(
        () => sealed.open('wrong-pin'),
        throwsA(isA<WrongPinException>()),
      );
    });

    test('two seals of the same plaintext produce distinct ciphertexts', () {
      // Salt and IV are fresh on every call — GCM with reused IV under the
      // same key is catastrophic, so this is a non-trivial invariant.
      final a = Envelope.seal(
        privateKey: fakeKey,
        pin: 'pw',
        type: KeyType.ethereum,
        iterations: 1000,
      );
      final b = Envelope.seal(
        privateKey: fakeKey,
        pin: 'pw',
        type: KeyType.ethereum,
        iterations: 1000,
      );
      expect(a.salt, isNot(equals(b.salt)));
      expect(a.iv, isNot(equals(b.iv)));
      expect(a.ciphertext, isNot(equals(b.ciphertext)));
    });

    test('fromBlob throws EnvelopeFormatException on malformed input', () {
      expect(
        () => Envelope.fromBlob('not-a-base64-json-thing!!!'),
        throwsA(isA<EnvelopeFormatException>()),
      );
    });

    test('fromBlob throws EnvelopeFormatException on an unsupported version', () {
      // Hand-craft a base64-JSON envelope with v=999.
      const future = 'eyJ2Ijo5OTksInR5cGUiOiJldGgiLCJrZGYiOiJwYmtkZjItc2hhMjU2Iiw'
          'iaXRlciI6MSwic2FsdCI6IiIsIml2IjoiIiwiY3QiOiIifQ==';
      expect(
        () => Envelope.fromBlob(future),
        throwsA(isA<EnvelopeFormatException>()),
      );
    });

    test('sealed envelope carries a non-zero createdAtMs', () {
      final env = Envelope.seal(
        privateKey: fakeKey,
        pin: 'p',
        type: KeyType.ethereum,
        iterations: 1000,
      );
      expect(env.createdAtMs, greaterThan(0));
    });

    test('legacy envelope (no ts field) round-trips with createdAtMs=0', () {
      // Hand-craft a v1 envelope without the `ts` field — represents the
      // shape produced by v0.1.0/v0.1.1.
      const legacy =
          'eyJ2IjoxLCJ0eXBlIjoiZXRoIiwia2RmIjoicGJrZGYyLXNoYTI1NiIsIml0ZXIi'
          'OjEwMDAsInNhbHQiOiJBQUFBQUFBQUFBQUFBQUFBQUFBQUFBPT0iLCJpdiI6IkFB'
          'QUFBQUFBQUFBQUFBQUEiLCJjdCI6IkFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFB'
          'QUFBQUFBQUFBQUFBPT0ifQ==';
      final env = Envelope.fromBlob(legacy);
      expect(env.createdAtMs, 0);
    });
  });
}
