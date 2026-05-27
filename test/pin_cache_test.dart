import 'package:flutter_test/flutter_test.dart';
import 'package:syncing_keys/src/engine/pin_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PinCache', () {
    test('set/get round-trips within TTL', () {
      final c = PinCache(ttl: const Duration(seconds: 10));
      addTearDown(c.dispose);
      c.set('123456');
      expect(c.get(), '123456');
    });

    test('ttl <= 0 disables the cache entirely', () {
      final c = PinCache(ttl: Duration.zero);
      addTearDown(c.dispose);
      c.set('123456');
      expect(c.get(), isNull);
    });

    test('clear() wipes immediately', () {
      final c = PinCache(ttl: const Duration(minutes: 10));
      addTearDown(c.dispose);
      c.set('p');
      c.clear();
      expect(c.get(), isNull);
    });
  });
}
