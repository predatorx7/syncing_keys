import 'package:flutter/widgets.dart';

/// =============================================================================
/// _PinCache — keeps a successfully-entered PIN in memory for a short TTL so
/// the user doesn't have to re-type it for every CRUD call.
/// -----------------------------------------------------------------------------
/// Stored as the raw PIN string (not the derived AES key) because each
/// envelope has a fresh random salt — caching the derived key would only
/// help within a single envelope's lifetime, which the user almost never sees.
///
/// Trade-off: holding the PIN as plaintext in process memory for the cache
/// window slightly enlarges the attack surface. We mitigate by:
///   • bounding the TTL (configurable; default 10 minutes),
///   • clearing immediately on [AppLifecycleState.paused] so a recents-screen
///     screenshot won't leak it,
///   • never persisting the cache (process-restart wipes it).
///
/// Pass [Duration.zero] to disable.
/// =============================================================================
class PinCache with WidgetsBindingObserver {
  PinCache({required this.ttl}) {
    if (ttl > Duration.zero) {
      WidgetsBinding.instance.addObserver(this);
    }
  }

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

  /// Wipes the cache immediately. Called on PIN-failure, on lifecycle pause,
  /// and on [SyncingKeys.signOutOfCloud] for a clean session reset.
  void clear() {
    _pin = null;
    _expiry = null;
  }

  /// Disposes the lifecycle observer. The engine should call this when
  /// rebuilding (e.g. after [SyncingKeys.initialize] is invoked with a new
  /// config).
  void dispose() {
    if (ttl > Duration.zero) {
      WidgetsBinding.instance.removeObserver(this);
    }
    clear();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Only clear on *true* backgrounding (`paused`, `hidden`, `detached`).
    // `inactive` fires for transient interruptions like Face ID prompts,
    // notification-center pulls, and incoming-call sheets — clearing on
    // those would force a re-PIN every time, which is hostile UX.
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        clear();
      case AppLifecycleState.resumed:
      case AppLifecycleState.inactive:
        // No-op — keep the cache.
        break;
    }
  }
}
