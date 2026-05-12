import 'dart:typed_data';

import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/ecc_fp.dart' as fp;

import '../crypto/secure_random.dart' show SyncingRandom;

/// =============================================================================
/// Starknet (STARK-friendly elliptic curve) key generator.
/// -----------------------------------------------------------------------------
/// Starknet uses a **different** curve from Ethereum's secp256k1 — the STARK
/// curve is defined over the prime field of order
/// `p = 2^251 + 17·2^192 + 1` (same prime as Cairo's field), with a
/// short-Weierstrass equation `y^2 = x^3 + α·x + β`. The order `n` of the
/// generator point is also a 252-bit prime.
///
/// Curve parameters from the StarkWare specification
/// (https://docs.starkware.co/starkex/crypto/stark-curve.html):
///
///   p  = 0x0800000000000011000000000000000000000000000000000000000000000001
///   α  = 1
///   β  = 0x06f21413efbe40de150e596d72f7a8c5609ad26c15c915c1f4cdfcb99cee9e89
///   n  = 0x0800000000000010ffffffffffffffffb781126dcae7b2321e66a241adc64d2f
///   Gx = 0x01ef15c18599971b7beced415a40f0c7deacfd9b0d1819e03d723d8bc943cfca
///   Gy = 0x005668060aa49730b7be4801df46ec62de53ecd11abe43a32873000c36e8dc1f
///
/// A private key is a uniformly random integer in `[1, n-1]`. The public key
/// is the affine x-coordinate of `G * privKey` (the Starknet protocol uses
/// only the x-coordinate as the address-input).
/// =============================================================================
class StarknetKeyGenerator {
  StarknetKeyGenerator._();

  static StarknetKey generate() {
    final params = _starkCurve();

    // Sample a uniformly random 252-bit scalar in `[1, n-1]`. The simple
    // rejection-loop is overwhelmingly likely to succeed in one iteration
    // (the gap between 2^252 and `n` is negligible for our purposes).
    BigInt priv;
    do {
      final rand = SyncingRandom.instance.nextBytes(32);
      // Clear the top 5 bits to keep priv < 2^251 — well under `n`.
      rand[0] &= 0x07;
      priv = _bytesToBigInt(rand);
    } while (priv == BigInt.zero || priv >= params.n);

    // Public point P = G * priv.
    final q = (params.G * priv)!;
    final pubX = q.x!.toBigInteger()!;

    return StarknetKey(
      privateKey: _bigIntTo32Bytes(priv),
      publicAddress: '0x${pubX.toRadixString(16).padLeft(64, '0')}',
    );
  }

  /// Re-derive the public address for an existing private key (used after a
  /// cloud restore + decrypt to populate the returned [StoredKey]).
  static String publicAddressFor(Uint8List privKey) {
    final params = _starkCurve();
    final d = _bytesToBigInt(privKey);
    final q = (params.G * d)!;
    final pubX = q.x!.toBigInteger()!;
    return '0x${pubX.toRadixString(16).padLeft(64, '0')}';
  }

  // ──────────────────────────────────────────────────────────────────────
  // STARK curve domain parameters wired into pointycastle's generic ECC.
  // ──────────────────────────────────────────────────────────────────────

  static ECDomainParameters _starkCurve() {
    final p = BigInt.parse(
        '0800000000000011000000000000000000000000000000000000000000000001',
        radix: 16);
    final a = BigInt.one;
    final b = BigInt.parse(
        '06f21413efbe40de150e596d72f7a8c5609ad26c15c915c1f4cdfcb99cee9e89',
        radix: 16);
    final n = BigInt.parse(
        '0800000000000010ffffffffffffffffb781126dcae7b2321e66a241adc64d2f',
        radix: 16);
    final gx = BigInt.parse(
        '01ef15c18599971b7beced415a40f0c7deacfd9b0d1819e03d723d8bc943cfca',
        radix: 16);
    final gy = BigInt.parse(
        '005668060aa49730b7be4801df46ec62de53ecd11abe43a32873000c36e8dc1f',
        radix: 16);
    final h = BigInt.one;

    final curve = fp.ECCurve(p, a, b);
    final g = curve.createPoint(gx, gy);

    return _StarkDomain(curve: curve, g: g, n: n, h: h);
  }

  static BigInt _bytesToBigInt(Uint8List bytes) {
    var result = BigInt.zero;
    for (final b in bytes) {
      result = (result << 8) | BigInt.from(b);
    }
    return result;
  }

  static Uint8List _bigIntTo32Bytes(BigInt v) {
    var hex = v.toRadixString(16);
    if (hex.length.isOdd) hex = '0$hex';
    hex = hex.padLeft(64, '0');
    return Uint8List.fromList(List.generate(
        32, (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16)));
  }
}

/// pointycastle has no built-in STARK curve, so we implement the
/// [ECDomainParameters] interface ourselves.
class _StarkDomain implements ECDomainParameters {
  _StarkDomain({
    required this.curve,
    required this.g,
    required this.n,
    required this.h,
  });

  @override
  final ECCurve curve;

  /// Generator point. Exposed through the [G] getter which the interface
  /// requires (note the uppercase — pointycastle keeps the cryptography
  /// convention).
  final ECPoint g;

  @override
  final BigInt n;

  /// Cofactor — not part of `ECDomainParameters` in pointycastle 3.x but
  /// kept for completeness (always 1 on the STARK curve).
  final BigInt h;

  @override
  ECPoint get G => g;

  @override
  String get domainName => 'starknet-stark-curve';

  @override
  List<int>? get seed => null;
}

class StarknetKey {
  const StarknetKey({required this.privateKey, required this.publicAddress});
  final Uint8List privateKey;
  final String publicAddress;
}
