/// =============================================================================
/// SyncingKeysStrings — all user-visible text the SDK shows, in one place.
/// -----------------------------------------------------------------------------
/// `PinTheme.title` / `PinTheme.subtitle` already cover the *encrypt-side*
/// PIN sheet copy because that's where the developer typically wants the
/// strongest brand fit. This class covers the rest:
///
///   • the *decrypt-side* PIN subtitle,
///   • the wrong-PIN retry banner,
///   • biometric prompt + button label,
///   • the "Fetching from cloud…" loading dialog,
///   • the three default [PinPolicy] rejection reasons,
///   • the keypad semantics labels (used by screen readers).
///
/// All defaults are in English. To localise, build a [SyncingKeysStrings]
/// instance from your app's `AppLocalizations` and pass it via
/// `GlobalConfig.strings`. Because the class is `const`-constructible and
/// has value-equality, swapping locale at runtime triggers a clean re-init
/// through [SyncingKeys.initialize]'s idempotency check.
/// =============================================================================
class SyncingKeysStrings {
  const SyncingKeysStrings({
    this.decryptSubtitle = 'Enter your PIN to unlock this key.',
    this.wrongPinRetry = 'Wrong PIN — try again.',
    this.fetchingFromCloud = 'Fetching from cloud…',
    this.biometricPromptReason = 'Unlock your encrypted keys',
    this.biometricButtonLabel = 'Unlock with biometrics',
    this.deleteDigitLabel = 'Delete digit',
    this.digitLabelPrefix = 'Digit ',
    this.pinPolicyEmpty = 'PIN cannot be empty',
    this.pinPolicyRepeating = 'PIN cannot be a single repeating digit',
    this.pinPolicySequential = 'PIN cannot be a sequence',
  });

  /// Subtitle shown beneath the PIN dots when the sheet is decrypting an
  /// existing envelope. The encrypt-side subtitle lives on `PinTheme`.
  final String decryptSubtitle;

  /// Inline banner shown when the entered PIN didn't decrypt — used by the
  /// CRUD engine's retry loop.
  final String wrongPinRetry;

  /// Body text of the [LoadingOverlay] shown during slow-path cloud reads.
  final String fetchingFromCloud;

  /// Localized reason passed to `LocalAuthentication.authenticate` —
  /// surfaced inside the OS biometric prompt sheet.
  final String biometricPromptReason;

  /// Semantics label for the biometric-shortcut button on the keypad.
  final String biometricButtonLabel;

  /// Semantics label for the backspace button on the keypad.
  final String deleteDigitLabel;

  /// Prefix for digit-button semantics labels. The full label is
  /// `"$digitLabelPrefix$d"` (e.g. `"Digit 5"`).
  final String digitLabelPrefix;

  /// Default `PinPolicy` rejection message for empty PINs.
  final String pinPolicyEmpty;

  /// Default `PinPolicy` rejection message for all-same-digit PINs.
  final String pinPolicyRepeating;

  /// Default `PinPolicy` rejection message for ascending/descending PINs.
  final String pinPolicySequential;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SyncingKeysStrings &&
          other.decryptSubtitle == decryptSubtitle &&
          other.wrongPinRetry == wrongPinRetry &&
          other.fetchingFromCloud == fetchingFromCloud &&
          other.biometricPromptReason == biometricPromptReason &&
          other.biometricButtonLabel == biometricButtonLabel &&
          other.deleteDigitLabel == deleteDigitLabel &&
          other.digitLabelPrefix == digitLabelPrefix &&
          other.pinPolicyEmpty == pinPolicyEmpty &&
          other.pinPolicyRepeating == pinPolicyRepeating &&
          other.pinPolicySequential == pinPolicySequential;

  @override
  int get hashCode => Object.hash(
        decryptSubtitle,
        wrongPinRetry,
        fetchingFromCloud,
        biometricPromptReason,
        biometricButtonLabel,
        deleteDigitLabel,
        digitLabelPrefix,
        pinPolicyEmpty,
        pinPolicyRepeating,
        pinPolicySequential,
      );
}
