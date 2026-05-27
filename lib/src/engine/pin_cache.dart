/// =============================================================================
/// _PinCache — keeps a successfully-entered PIN in memory for a configurable
/// TTL so the user doesn't have to re-type it for every CRUD call.
/// -----------------------------------------------------------------------------
/// Stored as the raw PIN string (not the derived AES key) because each
/// envelope has a fresh random salt — caching the derived key would only
/// help within a single envelope's lifetime, which the user almost never sees.
///
/// Trade-off: holding the PIN as plaintext in process memory for the cache
/// window slightly enlarges the attack surface. We mitigate by:
///   • bounding the TTL (configurable; default 3 days),
///   • never persisting the cache (process-restart wipes it),
///   • clearing on PIN change, `deleteKey`, 3-strikes wrong PIN, and
///     `SyncingKeys.signOutOfCloud`.
///
/// The cache deliberately survives app backgrounding (`AppLifecycleState.paused`,
/// `hidden`, `detached`) so the user isn't re-prompted every time they switch
/// apps or lock the screen — only a process restart (or an explicit clear)
/// drops it.
///
/// Pass [Duration.zero] to disable.
/// =============================================================================
class PinCache {
  PinCache({required this.ttl});

  /// Effective cache lifetime. `Duration.zero` disables the cache entirely.
  final Duration ttl;

  String? _pin;
  DateTime? _expiry;

  /// Returns the cached PIN if it's still valid, else null.
  String? get() {
    if (ttl <= Duration.zero) return null;
    final exp = _expiry;
    if (exp == null || DateTime.now().isAfter(exp)) {
      clear();
      return null;
    }
    return _pin;
  }

  /// Records [pin] as the active session PIN and resets the TTL clock.
  void set(String pin) {
    if (ttl <= Duration.zero) return;
    _pin = pin;
    _expiry = DateTime.now().add(ttl);
  }

  /// Wipes the cache immediately. Called on PIN-failure, PIN change,
  /// `deleteKey`, and `SyncingKeys.signOutOfCloud` for a clean session reset.
  void clear() {
    _pin = null;
    _expiry = null;
  }

  /// Disposes the cache. The engine should call this when rebuilding
  /// (e.g. after [SyncingKeys.initialize] is invoked with a new config).
  void dispose() {
    clear();
  }
}
