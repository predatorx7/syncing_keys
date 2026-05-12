/// =============================================================================
/// Id charset validator.
/// -----------------------------------------------------------------------------
/// Every CRUD call accepts a developer-chosen [String] id. That id ends up
/// in two untrusted-input positions:
///   • a Google Drive `q=name='<id>'` search parameter,
///   • a Keychain `kSecAttrAccount` attribute.
///
/// To keep both safe we restrict ids to a portable, conservative charset:
/// `[A-Za-z0-9_.-]{1,64}`. The lower bound (1) blocks empty ids; the upper
/// bound (64) keeps Drive search URLs comfortably under any practical
/// length limit. Forbidden characters include `'`, `/`, `\`, `\n`, `\t`,
/// `"`, and Unicode control points — any of which can confuse Drive's
/// query escaping or break shell-style logs.
/// =============================================================================
class KeyId {
  KeyId._();

  static final _validIdRegex = RegExp(r'^[A-Za-z0-9_.-]{1,64}$');

  /// Throws [ArgumentError] if [id] isn't in the supported charset.
  static void validate(String id) {
    if (!_validIdRegex.hasMatch(id)) {
      throw ArgumentError.value(
        id,
        'id',
        'SyncingKeys id must match $_validIdRegex — got "$id"',
      );
    }
  }
}
