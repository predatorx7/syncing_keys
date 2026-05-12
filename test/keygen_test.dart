import 'package:flutter_test/flutter_test.dart';
import 'package:syncing_keys/src/keygen/ethereum_key_generator.dart';
import 'package:syncing_keys/src/keygen/starknet_key_generator.dart';

void main() {
  group('EthereumKeyGenerator', () {
    test('produces a 32-byte private key and a well-formed 0x address', () {
      final k = EthereumKeyGenerator.generate();
      expect(k.privateKey.length, 32);
      expect(k.address, startsWith('0x'));
      expect(k.address.length, 42); // '0x' + 40 hex chars
      expect(RegExp(r'^0x[0-9a-f]{40}$').hasMatch(k.address), isTrue,
          reason: 'Address should be lowercase hex.');
    });

    test('addressFor is deterministic for a given private key', () {
      final k = EthereumKeyGenerator.generate();
      final addr2 = EthereumKeyGenerator.addressFor(k.privateKey);
      expect(addr2, equals(k.address));
    });

    test('two fresh generations are not equal', () {
      final a = EthereumKeyGenerator.generate();
      final b = EthereumKeyGenerator.generate();
      expect(a.privateKey, isNot(equals(b.privateKey)));
      expect(a.address, isNot(equals(b.address)));
    });
  });

  group('StarknetKeyGenerator', () {
    test('produces a 32-byte private key and a felt-range public address', () {
      final k = StarknetKeyGenerator.generate();
      expect(k.privateKey.length, 32);
      expect(k.publicAddress, startsWith('0x'));
      // STARK felt is a 252-bit number → max 64 hex chars after the 0x.
      expect(k.publicAddress.length, 66);
      expect(
          RegExp(r'^0x[0-9a-f]{64}$').hasMatch(k.publicAddress), isTrue,
          reason: 'STARK public address should be 64 lowercase hex chars.');

      // 252-bit ceiling: the leading hex nibble must fit in 2^(252-248) = 2^4 - 1 = 0x7
      // i.e. ≤ 7. Our generator clears the top 5 bits of the private key, but
      // the **public** x-coordinate can still occupy the full 252-bit field.
      // So we just sanity-check it's parseable as a BigInt < 2^252.
      final felt = BigInt.parse(k.publicAddress.substring(2), radix: 16);
      final ceiling = BigInt.parse('1${'0' * 63}', radix: 16);
      expect(felt < ceiling, isTrue,
          reason: 'Public felt must fit in 252 bits.');
    });

    test('publicAddressFor is deterministic', () {
      final k = StarknetKeyGenerator.generate();
      final addr2 = StarknetKeyGenerator.publicAddressFor(k.privateKey);
      expect(addr2, equals(k.publicAddress));
    });
  });
}
