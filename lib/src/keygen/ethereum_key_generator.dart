import 'dart:typed_data';

import 'package:bip32/bip32.dart' as bip32;
import 'package:bip39/bip39.dart' as bip39;
import 'package:pointycastle/digests/keccak.dart';
import 'package:pointycastle/ecc/curves/secp256k1.dart';

/// =============================================================================
/// Ethereum (secp256k1, BIP-44) key generator.
/// -----------------------------------------------------------------------------
/// Produces a fresh BIP-44 wallet keypair on the canonical Ethereum path
/// `m/44'/60'/0'/0/0`. Returns the 32-byte private key plus the 0x-prefixed
/// 20-byte address (keccak256 of the uncompressed public key, last 20 bytes).
///
/// We intentionally use a 128-bit (12 word) mnemonic — strong enough for an
/// ECDSA private key and small enough not to bloat memory. The mnemonic is
/// **not** retained; the SDK only persists the derived 32-byte private key.
/// =============================================================================
class EthereumKeyGenerator {
  EthereumKeyGenerator._();

  /// Result of a single key generation pass.
  static EthereumKey generate() {
    // Step 1 — generate a fresh 128-bit BIP-39 mnemonic.
    final mnemonic = bip39.generateMnemonic(strength: 128);

    // Step 2 — convert to a 512-bit BIP-39 seed (PBKDF2-HMAC-SHA512, 2048 it).
    final seed = bip39.mnemonicToSeed(mnemonic);

    // Step 3 — BIP-32 root, then derive the Ethereum path m/44'/60'/0'/0/0.
    final root = bip32.BIP32.fromSeed(seed);
    final child = root.derivePath("m/44'/60'/0'/0/0");
    final privKey = Uint8List.fromList(child.privateKey!);

    return EthereumKey(privateKey: privKey, address: _addressFromPriv(privKey));
  }

  /// Re-compute the Ethereum address for an existing private key blob (used by
  /// `SyncingKeys.getKey` after decryption to give the caller a [StoredKey] with a
  /// fresh `publicAddress` field).
  static String addressFor(Uint8List privateKey) => _addressFromPriv(privateKey);

  // ──────────────────────────────────────────────────────────────────────

  static String _addressFromPriv(Uint8List priv) {
    final params = ECCurve_secp256k1();
    final d = BigInt.parse(
        priv.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        radix: 16);

    // Public point Q = d·G on secp256k1.
    final q = (params.G * d)!;

    // Ethereum uses the **uncompressed** form minus the 0x04 prefix → 64 bytes
    // (X || Y), then keccak256, then take the last 20 bytes.
    final x = _padTo32(_bigIntToBytes(q.x!.toBigInteger()!));
    final y = _padTo32(_bigIntToBytes(q.y!.toBigInteger()!));
    final pubKey = Uint8List(64)..setAll(0, x)..setAll(32, y);

    final keccak = KeccakDigest(256);
    keccak.update(pubKey, 0, pubKey.length);
    final hash = Uint8List(32);
    keccak.doFinal(hash, 0);

    final addr = hash.sublist(12); // last 20 bytes
    return '0x${addr.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
  }

  static Uint8List _bigIntToBytes(BigInt v) {
    var hex = v.toRadixString(16);
    if (hex.length.isOdd) hex = '0$hex';
    return Uint8List.fromList(
      List.generate(hex.length ~/ 2,
          (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16)),
    );
  }

  static Uint8List _padTo32(Uint8List bytes) {
    if (bytes.length == 32) return bytes;
    final out = Uint8List(32);
    out.setRange(32 - bytes.length, 32, bytes);
    return out;
  }
}

class EthereumKey {
  const EthereumKey({required this.privateKey, required this.address});
  final Uint8List privateKey;
  final String address;
}
