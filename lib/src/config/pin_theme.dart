import 'package:flutter/material.dart';

/// Visual theme for the [PinEntryOverlay].
///
/// Pass an instance into [GlobalConfig] to override any of the defaults.
/// Anything left `null` falls back to a sensible Material-3 derived default
/// at render time (we resolve against [Theme.of(context)] in the widget).
class PinTheme {
  const PinTheme({
    this.backgroundColor,
    this.headerTextStyle,
    this.subheaderTextStyle,
    this.digitTextStyle,
    this.dotFilledColor,
    this.dotEmptyColor,
    this.keypadButtonColor,
    this.keypadButtonShape,
    this.borderRadius,
    this.errorColor,
    this.biometricIcon,
    this.title = 'Enter your PIN',
    this.subtitle = 'Used to encrypt your private keys on this device.',
    this.pinLength = 6,
  });

  /// Background colour of the overlay sheet.
  final Color? backgroundColor;

  /// Text style for the [title].
  final TextStyle? headerTextStyle;

  /// Text style for the [subtitle].
  final TextStyle? subheaderTextStyle;

  /// Text style for digits on the numeric keypad.
  final TextStyle? digitTextStyle;

  /// Colour of a filled PIN-progress dot.
  final Color? dotFilledColor;

  /// Colour of an empty PIN-progress dot.
  final Color? dotEmptyColor;

  /// Background colour of each keypad button.
  final Color? keypadButtonColor;

  /// Shape of each keypad button (circle by default).
  final ShapeBorder? keypadButtonShape;

  /// Corner radius of the bottom-sheet container.
  final BorderRadius? borderRadius;

  /// Used when the user enters an incorrect PIN (animated shake + colour).
  final Color? errorColor;

  /// Custom icon for the biometric pre-gate button. Defaults to
  /// [Icons.fingerprint].
  final IconData? biometricIcon;

  /// Header text shown above the PIN dots.
  final String title;

  /// Sub-text shown below the title.
  final String subtitle;

  /// Number of digits expected (4 or 6 are the common choices).
  final int pinLength;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PinTheme &&
          other.backgroundColor == backgroundColor &&
          other.headerTextStyle == headerTextStyle &&
          other.subheaderTextStyle == subheaderTextStyle &&
          other.digitTextStyle == digitTextStyle &&
          other.dotFilledColor == dotFilledColor &&
          other.dotEmptyColor == dotEmptyColor &&
          other.keypadButtonColor == keypadButtonColor &&
          other.keypadButtonShape == keypadButtonShape &&
          other.borderRadius == borderRadius &&
          other.errorColor == errorColor &&
          other.biometricIcon == biometricIcon &&
          other.title == title &&
          other.subtitle == subtitle &&
          other.pinLength == pinLength;

  @override
  int get hashCode => Object.hashAll([
        backgroundColor,
        headerTextStyle,
        subheaderTextStyle,
        digitTextStyle,
        dotFilledColor,
        dotEmptyColor,
        keypadButtonColor,
        keypadButtonShape,
        borderRadius,
        errorColor,
        biometricIcon,
        title,
        subtitle,
        pinLength,
      ]);

  /// Copy with — useful for runtime tweaks (e.g. switching to an error state).
  PinTheme copyWith({
    Color? backgroundColor,
    TextStyle? headerTextStyle,
    TextStyle? subheaderTextStyle,
    TextStyle? digitTextStyle,
    Color? dotFilledColor,
    Color? dotEmptyColor,
    Color? keypadButtonColor,
    ShapeBorder? keypadButtonShape,
    BorderRadius? borderRadius,
    Color? errorColor,
    IconData? biometricIcon,
    String? title,
    String? subtitle,
    int? pinLength,
  }) =>
      PinTheme(
        backgroundColor: backgroundColor ?? this.backgroundColor,
        headerTextStyle: headerTextStyle ?? this.headerTextStyle,
        subheaderTextStyle: subheaderTextStyle ?? this.subheaderTextStyle,
        digitTextStyle: digitTextStyle ?? this.digitTextStyle,
        dotFilledColor: dotFilledColor ?? this.dotFilledColor,
        dotEmptyColor: dotEmptyColor ?? this.dotEmptyColor,
        keypadButtonColor: keypadButtonColor ?? this.keypadButtonColor,
        keypadButtonShape: keypadButtonShape ?? this.keypadButtonShape,
        borderRadius: borderRadius ?? this.borderRadius,
        errorColor: errorColor ?? this.errorColor,
        biometricIcon: biometricIcon ?? this.biometricIcon,
        title: title ?? this.title,
        subtitle: subtitle ?? this.subtitle,
        pinLength: pinLength ?? this.pinLength,
      );
}
