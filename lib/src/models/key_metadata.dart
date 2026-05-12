import 'key_type.dart';

/// Lightweight summary of a stored key — id, type, and creation timestamp —
/// returned by [SyncingKeys.listKeys] without decrypting anything.
///
/// `createdAtMs` is `null` for legacy envelopes (v0.1.0/0.1.1) that predate
/// the timestamp field. Use that as a signal to re-`saveKey` if you want to
/// upgrade legacy envelopes to the timestamped format.
class KeyMetadata {
  const KeyMetadata({
    required this.id,
    required this.type,
    required this.createdAtMs,
  });

  /// Caller-chosen identifier.
  final String id;

  /// Curve family the key belongs to.
  final KeyType type;

  /// Epoch-millisecond timestamp captured when the envelope was sealed,
  /// or `null` if the envelope predates the `ts` field.
  final int? createdAtMs;

  @override
  String toString() =>
      'KeyMetadata(id=$id, type=${type.id}, '
      'createdAtMs=${createdAtMs ?? "legacy"})';
}
