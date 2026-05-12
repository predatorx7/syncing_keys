/// Result of [SyncingKeys.changePin]. The two lists never overlap.
///
/// A pure-success rotation returns `failed.isEmpty`. A partial failure
/// (rare — e.g. Keychain row went read-only mid-rotation) leaves the
/// listed ids on the old PIN; you can retry with the same args and only
/// those ids will be retouched.
class ChangePinResult {
  const ChangePinResult({required this.rotated, required this.failed});

  /// Ids whose envelope is now sealed under the new PIN.
  final List<String> rotated;

  /// Ids the SDK could not rotate; consult [ChangePinFailure.error] for the
  /// underlying cause. An empty list means total success.
  final List<ChangePinFailure> failed;

  @override
  String toString() =>
      'ChangePinResult(rotated=${rotated.length}, failed=${failed.length})';
}

class ChangePinFailure {
  const ChangePinFailure({required this.id, required this.error});
  final String id;
  final Object error;

  @override
  String toString() => 'ChangePinFailure(id=$id, error=$error)';
}
