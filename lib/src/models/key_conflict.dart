import '../config/cloud_backend.dart';

/// Which copy to keep when resolving a [KeyConflict].
enum ConflictResolution {
  /// Overwrite the cloud copy with this device's local key.
  keepLocal,

  /// Overwrite the local copy with the cloud key.
  keepCloud,
}

/// The result of comparing the local envelope against the active cloud backend
/// for a given key id.
///
/// A *conflict* means both a local copy and a cloud copy exist but they are
/// **not the same key** — either they decrypt (under the current PIN) to
/// different public addresses, or the cloud copy was sealed under a different
/// PIN and cannot be opened here at all. A benign difference (the same key
/// re-sealed, e.g. after a PIN change) is **not** reported as a conflict.
///
/// When [hasConflict] is false the other fields describe whatever was found
/// (they may be null if one side was absent), and no user action is needed.
class KeyConflict {
  const KeyConflict({
    required this.hasConflict,
    required this.backend,
    this.localPublicAddress,
    this.cloudPublicAddress,
    this.localCreatedAtMs,
    this.cloudCreatedAtMs,
    this.cloudUndecryptable = false,
    this.undetermined = false,
  });

  /// No local/cloud pair to compare, or they are the same key.
  const KeyConflict.none(CloudBackend backend)
      : this(hasConflict: false, backend: backend);

  /// Could not be determined without a PIN prompt (passive check with no cached
  /// PIN). The UI should offer an explicit "verify" action.
  const KeyConflict.undetermined(CloudBackend backend)
      : this(hasConflict: false, backend: backend, undetermined: true);

  /// True when local and cloud hold genuinely different keys.
  final bool hasConflict;

  /// The cloud backend that was compared against local.
  final CloudBackend backend;

  /// Public address of the local key (null if there was no local copy).
  final String? localPublicAddress;

  /// Public address of the cloud key. Null when there was no cloud copy or the
  /// cloud envelope could not be decrypted under the current PIN (see
  /// [cloudUndecryptable]).
  final String? cloudPublicAddress;

  /// Seal timestamp (epoch ms) of the local envelope, `0`/null if unknown.
  final int? localCreatedAtMs;

  /// Seal timestamp (epoch ms) of the cloud envelope, `0`/null if unknown.
  final int? cloudCreatedAtMs;

  /// True when a cloud copy exists but could not be opened with the PIN that
  /// unlocked the local copy — i.e. it belongs to a different PIN era. This is
  /// always a conflict, but we cannot show its public address.
  final bool cloudUndecryptable;

  /// True when the check couldn't run without prompting for the PIN and the
  /// caller asked for a no-prompt (passive) check. Not a conflict — the UI
  /// should surface a "verify backup" affordance that runs the full check.
  final bool undetermined;

  @override
  String toString() => 'KeyConflict(hasConflict=$hasConflict, backend=${backend.name}, '
      'local=$localPublicAddress, cloud=$cloudPublicAddress, '
      'cloudUndecryptable=$cloudUndecryptable, undetermined=$undetermined)';
}
