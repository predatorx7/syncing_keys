/// Which cloud backend an envelope is (or should be) backed up to.
///
/// Historically the SDK hardwired the backend by platform (iCloud Keychain on
/// iOS, Google Drive on Android) and only exposed an on/off [GlobalConfig.syncEnabled]
/// switch. [CloudBackend] makes the choice explicit and runtime-selectable so the
/// host app can offer the user a real preference and switch between backends.
///
/// Not every backend is available on every platform:
///   - [local]         — always available (device-only storage, no cloud copy).
///   - [appleKeychain] — iOS only (synchronizable Keychain items via iCloud).
///   - [googleDrive]   — Android today; iOS once the Drive backend ships.
///
/// The wire form sent across the method channel is [name] (`"local"`,
/// `"appleKeychain"`, `"googleDrive"`).
enum CloudBackend {
  /// Device-only. No cloud copy is written; `syncEnabled` is effectively off.
  local,

  /// Apple iCloud Keychain (synchronizable items). iOS only.
  appleKeychain,

  /// Google Drive `appDataFolder`. Android (and iOS after the Drive backend
  /// lands).
  googleDrive;

  /// Whether this backend represents a real cloud copy (anything but [local]).
  bool get isCloud => this != CloudBackend.local;

  /// Parse a wire-form [name] back to a [CloudBackend]. Returns `null` for
  /// unknown values so callers can fall back to a platform default rather than
  /// throw on a forward-incompatible string.
  static CloudBackend? fromName(String? name) {
    for (final b in CloudBackend.values) {
      if (b.name == name) return b;
    }
    return null;
  }
}
