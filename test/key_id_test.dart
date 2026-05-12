import 'package:flutter_test/flutter_test.dart';
import 'package:syncing_keys/src/models/ids.dart';

void main() {
  group('KeyId.validate', () {
    test('accepts the documented charset', () {
      KeyId.validate('main');
      KeyId.validate('wallet-2024_v1.bak');
      KeyId.validate('A1');
      KeyId.validate('1' * 64); // boundary length
    });

    test('rejects empty / over-long', () {
      expect(() => KeyId.validate(''), throwsArgumentError);
      expect(() => KeyId.validate('a' * 65), throwsArgumentError);
    });

    test("rejects characters Drive's query syntax can't handle", () {
      expect(() => KeyId.validate("a'b"), throwsArgumentError);
      expect(() => KeyId.validate('a/b'), throwsArgumentError);
      expect(() => KeyId.validate('a\\b'), throwsArgumentError);
      expect(() => KeyId.validate('a b'), throwsArgumentError);
      expect(() => KeyId.validate('a\nb'), throwsArgumentError);
    });
  });
}
