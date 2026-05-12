import 'package:flutter_test/flutter_test.dart';
import 'package:syncing_keys/syncing_keys.dart';

void main() {
  const policy = PinPolicy();

  test('accepts reasonable PINs', () {
    expect(policy.reasonForRejection('246813'), isNull);
    expect(policy.reasonForRejection('314159'), isNull);
    expect(policy.reasonForRejection('hunter2'), isNull);
  });

  test('rejects empty', () {
    expect(policy.reasonForRejection(''), contains('empty'));
  });

  test('rejects all-same-digit', () {
    expect(policy.reasonForRejection('000000'), contains('repeating'));
    expect(policy.reasonForRejection('1111'), contains('repeating'));
  });

  test('rejects ascending and descending sequences', () {
    expect(policy.reasonForRejection('123456'), contains('sequence'));
    expect(policy.reasonForRejection('654321'), contains('sequence'));
    expect(policy.reasonForRejection('345'), contains('sequence'));
  });

  test('a custom policy can extend the defaults', () {
    const policy = _DenylistPolicy({'2486', 'abcd'});
    expect(policy.reasonForRejection('2486'), isNotNull);
    expect(policy.reasonForRejection('5921'), isNull); // not on denylist, not sequential, not repeating
  });
}

class _DenylistPolicy extends PinPolicy {
  const _DenylistPolicy(this.denylist);
  final Set<String> denylist;

  @override
  String? reasonForRejection(String pin, {SyncingKeysStrings? strings}) {
    if (denylist.contains(pin)) return 'PIN is on the denylist';
    return super.reasonForRejection(pin, strings: strings);
  }
}
