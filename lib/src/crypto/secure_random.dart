import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/random/fortuna_random.dart';
import 'package:pointycastle/api.dart' show KeyParameter;

/// A process-wide CSPRNG used everywhere the SDK needs non-predictable bytes
/// (PBKDF2 salts, AES-GCM IVs, ECDSA private keys).
///
/// pointycastle's `SecureRandom` is a re-seeded Fortuna construction. We
/// seed it once from `dart:math`'s `Random.secure()` (OS-provided CSPRNG on
/// every Flutter target — `/dev/urandom`, `arc4random`, `BCryptGenRandom`).
///
/// Renamed to [SyncingRandom] to avoid clashing with pointycastle's
/// `SecureRandom` interface, which we transitively expose via `crypto/envelope.dart`.
class SyncingRandom {
  SyncingRandom._();

  static final SyncingRandom instance = SyncingRandom._();

  late final FortunaRandom _rng = _seed();

  FortunaRandom _seed() {
    final r = FortunaRandom();
    final sysRng = Random.secure();
    final seed = Uint8List(32);
    for (var i = 0; i < seed.length; i++) {
      seed[i] = sysRng.nextInt(256);
    }
    r.seed(KeyParameter(seed));
    return r;
  }

  /// Returns `length` uniformly-random bytes.
  Uint8List nextBytes(int length) => _rng.nextBytes(length);
}
