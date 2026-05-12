// Verifies SyncingKeysStrings value-equality and PinPolicy routing.

import 'package:flutter_test/flutter_test.dart';
import 'package:syncing_keys/syncing_keys.dart';

void main() {
  test('default SyncingKeysStrings values are stable identifiers', () {
    const s = SyncingKeysStrings();
    expect(s.digitLabelPrefix, 'Digit ');
    expect(s.biometricButtonLabel, isNotEmpty);
    expect(s.pinPolicyEmpty, contains('empty'));
  });

  test('value equality', () {
    const a = SyncingKeysStrings();
    const b = SyncingKeysStrings();
    expect(a, equals(b));
    expect(a.hashCode, equals(b.hashCode));

    const c = SyncingKeysStrings(wrongPinRetry: 'Réessayez');
    expect(a, isNot(equals(c)));
  });

  test('PinPolicy.reasonForRejection routes through provided strings', () {
    const french = SyncingKeysStrings(
      pinPolicyEmpty: 'Le code ne peut pas être vide',
      pinPolicyRepeating: 'Le code ne peut pas être un chiffre répété',
      pinPolicySequential: 'Le code ne peut pas être une séquence',
    );
    const policy = PinPolicy();
    expect(policy.reasonForRejection('', strings: french),
        equals(french.pinPolicyEmpty));
    expect(policy.reasonForRejection('1111', strings: french),
        equals(french.pinPolicyRepeating));
    expect(policy.reasonForRejection('1234', strings: french),
        equals(french.pinPolicySequential));
  });

  test('GlobalConfig propagates strings through value equality', () {
    const a = GlobalConfig(strings: SyncingKeysStrings());
    const b = GlobalConfig(strings: SyncingKeysStrings());
    expect(a, equals(b));

    const c = GlobalConfig(
      strings: SyncingKeysStrings(wrongPinRetry: 'Réessayez'),
    );
    expect(a, isNot(equals(c)));
  });
}
