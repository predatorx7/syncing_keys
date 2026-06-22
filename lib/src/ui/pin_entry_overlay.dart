import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

import '../config/pin_policy.dart';
import '../config/pin_theme.dart';
import '../config/syncing_keys_strings.dart';
import '../models/exceptions.dart';

/// =============================================================================
/// PinEntryOverlay — modal numeric-pad sheet that returns the PIN string.
/// -----------------------------------------------------------------------------
/// Lives entirely on the Flutter side. The PIN never leaves the widget tree —
/// the calling code uses it to derive an AES-GCM wrapping key (PBKDF2) and
/// hands only the encrypted *envelope* down to native.
///
/// Highlights:
///   • Modern Material-3 styled bottom sheet (also works as a [Dialog]).
///   • Animated PIN-progress dots, haptics on each tap, shake on wrong PIN.
///   • Optional biometric pre-gate — if the device has a registered Face ID /
///     fingerprint, the user can unlock the cached PIN with biometrics
///     instead of typing it. (The cached PIN is in-memory only; the SDK never
///     persists the PIN itself.)
///   • Fully themable via [PinTheme].
/// =============================================================================

/// Reason the PIN UI is being shown — purely cosmetic (drives the subtitle
/// copy: "encrypt your private keys" vs. "unlock your private keys").
enum PinPurpose { encrypt, decrypt }

class PinEntryOverlay {
  PinEntryOverlay._();

  /// Shows the bottom-sheet and resolves to the entered PIN string.
  ///
  /// Throws [PinEntryCancelledException] if the user dismisses without
  /// completing entry. Callers should let that exception propagate — the
  /// CRUD engine catches it and treats it as a user-initiated cancel.
  /// [hasStoredPin] / [readStoredPin] wire the optional biometric unlock. When
  /// both are supplied (decrypt path only) the sheet offers a Face ID /
  /// fingerprint button: it checks [hasStoredPin] to decide whether to show
  /// the button, and — only after a successful biometric gesture — calls
  /// [readStoredPin] and closes the sheet with that PIN. Leave them null to
  /// disable biometrics entirely (e.g. the encrypt path, or tests).
  static Future<String> show({
    required BuildContext context,
    required PinTheme theme,
    required PinPurpose purpose,
    PinPolicy? policy,
    SyncingKeysStrings strings = const SyncingKeysStrings(),
    String? errorMessage,
    Future<bool> Function()? hasStoredPin,
    Future<String?> Function()? readStoredPin,
    bool autoPromptBiometric = true,
  }) async {
    final result = await showModalBottomSheet<String>(
      context: context,
      isDismissible: true,
      enableDrag: false,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _PinSheet(
        theme: theme,
        purpose: purpose,
        // Policy only applies to the encrypt path — decrypt prompts must
        // accept *whatever* the user originally chose, even a weak PIN.
        policy: purpose == PinPurpose.encrypt ? policy : null,
        strings: strings,
        initialError: errorMessage,
        hasStoredPin: hasStoredPin,
        readStoredPin: readStoredPin,
        autoPromptBiometric: autoPromptBiometric,
      ),
    );
    if (result == null) throw const PinEntryCancelledException();
    return result;
  }
}

class _PinSheet extends StatefulWidget {
  const _PinSheet({
    required this.theme,
    required this.purpose,
    required this.strings,
    this.policy,
    this.initialError,
    this.hasStoredPin,
    this.readStoredPin,
    this.autoPromptBiometric = true,
  });

  final PinTheme theme;
  final PinPurpose purpose;
  final SyncingKeysStrings strings;
  final PinPolicy? policy;
  final String? initialError;

  /// Existence check for a biometric-unlockable PIN (no plaintext). Null when
  /// biometric unlock is disabled for this prompt.
  final Future<bool> Function()? hasStoredPin;

  /// Reads the stored PIN in plaintext. Invoked only after a successful
  /// biometric gesture. Null when biometric unlock is disabled.
  final Future<String?> Function()? readStoredPin;

  /// Whether to fire the biometric prompt automatically when the sheet opens.
  /// The caller sets this false on a *retry* prompt (after a wrong PIN) so a
  /// stale stored PIN can't auto-loop — the button stays available for a
  /// manual tap, but typing is the default.
  final bool autoPromptBiometric;

  @override
  State<_PinSheet> createState() => _PinSheetState();
}

class _PinSheetState extends State<_PinSheet> with TickerProviderStateMixin {
  /// Currently entered digits — kept as a [String] of length 0..pinLength.
  /// We store as a plain string in component state; the moment [_submit] is
  /// called we hand it to the caller and the State is disposed.
  String _pin = '';

  String? _error;

  /// Shake animation controller, played on a wrong-PIN error message.
  late final AnimationController _shake;
  late final Animation<double> _shakeAnim;

  /// Biometric helper. We try once on first build; if it fails (no biometrics
  /// enrolled, user dismissed, etc.) we silently fall back to PIN entry.
  final LocalAuthentication _localAuth = LocalAuthentication();
  bool _biometricChecked = false;

  /// Whether to show the biometric button — set once we've confirmed the
  /// device has enrolled biometrics *and* there's a stored PIN to unlock.
  bool _biometricAvailable = false;

  @override
  void initState() {
    super.initState();
    _error = widget.initialError;
    _shake = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _shakeAnim = Tween<double>(begin: 0, end: 1).animate(_shake);
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeOfferBiometric());
  }

  @override
  void dispose() {
    _shake.dispose();
    super.dispose();
  }

  /// On first display, ask the OS if biometrics are available and (in the
  /// decrypt flow) prompt for them. In the encrypt flow we always require a
  /// fresh PIN — there's nothing to unlock yet.
  Future<void> _maybeOfferBiometric() async {
    if (_biometricChecked) return;
    _biometricChecked = true;
    if (widget.purpose != PinPurpose.decrypt) return;
    // No store callbacks → biometric unlock disabled for this prompt.
    final hasStored = widget.hasStoredPin;
    if (hasStored == null || widget.readStoredPin == null) return;

    try {
      final canCheck = await _localAuth.canCheckBiometrics;
      final available = await _localAuth.getAvailableBiometrics();
      if (!canCheck || available.isEmpty) return;
      // Only surface biometrics if there's actually a PIN persisted to unlock.
      if (!await hasStored()) return;
      if (!mounted) return;
      setState(() => _biometricAvailable = true);
      // Auto-prompt on open — this is an "unlock" screen, so we lead with the
      // gesture and let the user fall back to typing by cancelling. Skipped on
      // retry prompts so a stale stored PIN can't silently re-loop.
      if (widget.autoPromptBiometric) await _tryBiometric();
    } catch (_) {
      /* swallow — biometrics are best-effort. */
    }
  }

  Future<void> _tryBiometric() async {
    final read = widget.readStoredPin;
    if (read == null) return;
    try {
      final ok = await _localAuth.authenticate(
        localizedReason: widget.strings.biometricPromptReason,
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
        ),
      );
      if (!ok) return;
      // Gesture succeeded — surface the persisted PIN and close the sheet with
      // it, exactly as if the user had typed it. `null` means the store was
      // cleared between the availability check and now (e.g. a concurrent
      // changePin) — fall through to manual entry rather than popping garbage.
      final pin = await read();
      if (pin == null || pin.isEmpty) return;
      if (!mounted) return;
      Navigator.of(context).pop(pin);
    } catch (_) {
      /* ignore — fall through to PIN typing. */
    }
  }

  void _onDigit(String d) {
    if (_pin.length >= widget.theme.pinLength) return;
    HapticFeedback.selectionClick();
    setState(() {
      _pin = _pin + d;
      _error = null;
    });
    if (_pin.length == widget.theme.pinLength) {
      // Tiny delay so the final dot animates in before we close.
      Future.delayed(const Duration(milliseconds: 80), _submit);
    }
  }

  void _onBackspace() {
    if (_pin.isEmpty) return;
    HapticFeedback.lightImpact();
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  void _submit() {
    final policy = widget.policy;
    if (policy != null) {
      final reason = policy.reasonForRejection(_pin, strings: widget.strings);
      if (reason != null) {
        // Don't pop — surface the error inline and let the user retype.
        setState(() {
          _error = reason;
          _pin = '';
        });
        _shake.forward(from: 0);
        return;
      }
    }
    Navigator.of(context).pop(_pin);
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    final bg = t.backgroundColor ?? cs.surface;
    final headerStyle = t.headerTextStyle ??
        tt.titleLarge?.copyWith(fontWeight: FontWeight.w700);
    final subStyle =
        t.subheaderTextStyle ?? tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant);
    final dotFilled = t.dotFilledColor ?? cs.primary;
    final dotEmpty = t.dotEmptyColor ?? cs.outlineVariant;
    final errColor = t.errorColor ?? cs.error;
    final btnColor = t.keypadButtonColor ?? cs.surfaceContainerHighest;
    final btnShape = t.keypadButtonShape ?? const CircleBorder();
    final radius = t.borderRadius ??
        const BorderRadius.vertical(top: Radius.circular(28));

    final subtitle = widget.purpose == PinPurpose.encrypt
        ? t.subtitle
        : widget.strings.decryptSubtitle;

    return AnimatedBuilder(
      animation: _shakeAnim,
      builder: (_, child) => Transform.translate(
        offset: Offset(
          // Damped sine-shake: 4 oscillations over the controller's lifetime.
          (_shakeAnim.value == 0)
              ? 0
              : 8 *
                  (1 - _shakeAnim.value) *
                  // ignore: prefer_const_constructors
                  (_shakeOscillation(_shakeAnim.value)),
          0,
        ),
        child: child,
      ),
      child: SafeArea(
        top: false,
        child: Container(
          decoration: BoxDecoration(color: bg, borderRadius: radius),
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _grabber(cs),
              const SizedBox(height: 20),
              Text(t.title, style: headerStyle),
              const SizedBox(height: 8),
              Text(
                _error ?? subtitle,
                style: subStyle?.copyWith(color: _error != null ? errColor : null),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 28),
              _pinDots(t.pinLength, dotFilled, dotEmpty, errColor),
              const SizedBox(height: 28),
              _keypad(
                btnColor,
                btnShape,
                t.digitTextStyle ?? tt.headlineSmall!,
                t.biometricIcon ?? _defaultBiometricIcon(context),
                cs,
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  double _shakeOscillation(double t) {
    // Sin(8πt) — 4 full oscillations across [0,1]. We dampen via the
    // amplitude factor `(1 - _shakeAnim.value)` in the build() caller, so
    // here we just need a correct sine. The earlier hand-rolled Taylor
    // expansion diverged for x ≳ 10, which yanked the sheet completely
    // off-screen and broke hit-testing during tests.
    return math.sin(t * 4 * math.pi * 2);
  }

  Widget _grabber(ColorScheme cs) => Container(
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: cs.onSurfaceVariant.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(2),
        ),
      );

  Widget _pinDots(int length, Color filled, Color empty, Color errColor) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(length, (i) {
        final on = i < _pin.length;
        final base = _error != null ? errColor : (on ? filled : empty);
        return AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          width: 14,
          height: 14,
          margin: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(color: base, shape: BoxShape.circle),
        );
      }),
    );
  }

  Widget _keypad(
    Color btnColor,
    ShapeBorder shape,
    TextStyle digitStyle,
    IconData bioIcon,
    ColorScheme cs,
  ) {
    Widget digit(String d) => _KeypadButton(
          color: btnColor,
          shape: shape,
          onTap: () => _onDigit(d),
          semanticLabel: '${widget.strings.digitLabelPrefix}$d',
          child: Text(d, style: digitStyle),
        );

    Widget icon(
      IconData i,
      VoidCallback? onTap, {
      required String label,
    }) =>
        _KeypadButton(
          color: Colors.transparent,
          shape: shape,
          onTap: onTap,
          semanticLabel: label,
          child: Icon(i, color: cs.onSurface),
        );

    final rows = <List<Widget>>[
      [digit('1'), digit('2'), digit('3')],
      [digit('4'), digit('5'), digit('6')],
      [digit('7'), digit('8'), digit('9')],
      [
        // Only show the biometric button once we've confirmed it can do
        // something; otherwise keep the slot empty so '0' stays centred.
        if (_biometricAvailable)
          icon(bioIcon, _tryBiometric,
              label: widget.strings.biometricButtonLabel)
        else
          const SizedBox(width: 72, height: 72),
        digit('0'),
        icon(Icons.backspace_outlined, _onBackspace,
            label: widget.strings.deleteDigitLabel),
      ],
    ];

    return Column(
      children: rows
          .map((r) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: r,
                ),
              ))
          .toList(),
    );
  }

  /// Picks a sensible biometric icon when the developer hasn't overridden
  /// [PinTheme.biometricIcon]: Face-ID glyph on iOS/macOS, fingerprint
  /// elsewhere. We use `Theme.of(context).platform` rather than
  /// `Platform.isIOS` so this still does the right thing under tests and
  /// when the developer overrides the target platform manually.
  IconData _defaultBiometricIcon(BuildContext context) {
    final p = Theme.of(context).platform;
    if (p == TargetPlatform.iOS || p == TargetPlatform.macOS) {
      return Icons.face;
    }
    return Icons.fingerprint;
  }
}

class _KeypadButton extends StatelessWidget {
  const _KeypadButton({
    required this.color,
    required this.shape,
    required this.onTap,
    required this.child,
    required this.semanticLabel,
  });

  final Color color;
  final ShapeBorder shape;
  final VoidCallback? onTap;
  final Widget child;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) => Semantics(
        label: semanticLabel,
        button: true,
        enabled: onTap != null,
        excludeSemantics: true,
        child: _rawButton(),
      );

  Widget _rawButton() => SizedBox(
        width: 72,
        height: 72,
        child: Material(
          color: color,
          shape: shape,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Center(child: child),
          ),
        ),
      );
}
