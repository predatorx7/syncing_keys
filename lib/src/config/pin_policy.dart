import 'syncing_keys_strings.dart';

/// =============================================================================
/// PinPolicy — minimum-strength rules for PIN entry.
/// -----------------------------------------------------------------------------
/// Passed in via [GlobalConfig] so the host app can tune it (or replace it
/// entirely with a custom subclass).
///
/// Default policy:
///   • Length matches [PinTheme.pinLength].
///   • Reject all-same-digit PINs (`000000`, `111111`, …).
///   • Reject ascending/descending sequential PINs (`123456`, `654321`).
///
/// These three rules block the vast majority of "obviously bad" choices
/// (~10 PINs in a 6-digit space) without forcing UI churn. Subclass and
/// override [reasonForRejection] for stricter policies — e.g. a top-N
/// breached-PINs check, an entropy floor, or a denylist seeded from the
/// user's birthday.
///
/// Rejection reasons are sourced from [SyncingKeysStrings] so a localized
/// app shows native-language errors. Subclasses that add new reasons
/// should accept the [SyncingKeysStrings] in their own constructor.
/// =============================================================================
class PinPolicy {
  const PinPolicy();

  /// Returns `null` if [pin] is acceptable, or a human-readable reason
  /// string to display to the user otherwise. The reason is shown inline
  /// in the PIN entry sheet's error slot — keep it short.
  ///
  /// The default implementation uses [SyncingKeysStrings] defaults if
  /// [strings] is null, which lets unit tests and CLI tools call the
  /// policy without wiring up a whole [GlobalConfig].
  String? reasonForRejection(String pin, {SyncingKeysStrings? strings}) {
    final s = strings ?? const SyncingKeysStrings();
    if (pin.isEmpty) return s.pinPolicyEmpty;
    if (_allSameDigit(pin)) return s.pinPolicyRepeating;
    if (_isSequential(pin)) return s.pinPolicySequential;
    return null;
  }

  static bool _allSameDigit(String pin) {
    final first = pin.codeUnitAt(0);
    for (var i = 1; i < pin.length; i++) {
      if (pin.codeUnitAt(i) != first) return false;
    }
    return true;
  }

  static bool _isSequential(String pin) {
    if (pin.length < 2) return false;
    final step = pin.codeUnitAt(1) - pin.codeUnitAt(0);
    if (step != 1 && step != -1) return false;
    for (var i = 2; i < pin.length; i++) {
      if (pin.codeUnitAt(i) - pin.codeUnitAt(i - 1) != step) return false;
    }
    return true;
  }
}
