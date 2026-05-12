import 'dart:typed_data';

import 'key_type.dart';

/// A decrypted key ready for the developer to use. `privateKey` is the raw
/// private key material; `publicAddress` is the chain-specific public address.
///
/// The SDK hands these out only after a successful PIN unlock, and never
/// persists them in plaintext. The caller is responsible for ensuring this
/// object's lifetime is short — call [dispose] as soon as you're done so
/// the secret bytes are overwritten in heap memory.
///
/// Use the [withKey] helper for the common ephemeral-scope pattern:
///
/// ```dart
/// final sig = await SyncingKeys.getKey('main').withKey((key) async {
///   return await someSigner.sign(message, key.privateKey);
/// });
/// // `key.privateKey` is zeroised by the time `sig` resolves.
/// ```
class StoredKey {
  StoredKey({
    required this.id,
    required this.type,
    required this.privateKey,
    required this.publicAddress,
  });

  /// Caller-chosen identifier (e.g. `"main-wallet"`).
  final String id;

  /// Curve family the key belongs to.
  final KeyType type;

  /// Raw private key bytes — secp256k1 = 32 bytes, stark = 32 bytes.
  ///
  /// After [dispose] the buffer is zero-filled; reading from it post-dispose
  /// gives an all-zero array, which is the correct failure mode if a
  /// downstream signer somehow keeps a reference past its lifetime.
  final Uint8List privateKey;

  /// Chain-encoded public identifier:
  ///   - ETH: 0x-prefixed 20-byte address (lowercase, no checksum)
  ///   - Starknet: 0x-prefixed felt of the computed public key
  final String publicAddress;

  bool _disposed = false;

  /// Overwrite [privateKey] with zeros and mark this [StoredKey] as spent.
  /// Idempotent.
  ///
  /// Caveat: Dart provides no guarantee that the underlying memory page is
  /// not also held by a copy elsewhere (e.g. inside `pointycastle`'s scratch
  /// buffers). This is a best-effort defence — it removes the secret from
  /// *this* object's view, but a determined attacker with a heap dump can
  /// still find traces. For high-value targets, run the host process under
  /// `mlock`/`MEMORY_LIMIT` constraints.
  void dispose() {
    if (_disposed) return;
    for (var i = 0; i < privateKey.length; i++) {
      privateKey[i] = 0;
    }
    _disposed = true;
  }

  /// Runs [body] with this key, then disposes it — even if [body] throws.
  /// This is the recommended way to consume a [StoredKey] in a wallet flow.
  Future<R> withKey<R>(Future<R> Function(StoredKey key) body) async {
    try {
      return await body(this);
    } finally {
      dispose();
    }
  }

  @override
  String toString() =>
      'StoredKey(id=$id, type=${type.id}, addr=$publicAddress, '
      'disposed=$_disposed)';
}
