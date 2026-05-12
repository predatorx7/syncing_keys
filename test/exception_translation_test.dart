// Verifies the MethodChannel layer translates PlatformException into the
// typed SyncingKeysException hierarchy that the public API documents.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncing_keys/syncing_keys.dart';
import 'package:syncing_keys/syncing_keys_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final platform = MethodChannelSyncingKeys();
  const channel =
      MethodChannel('app.xyz.everydayapp.syncing_keys/syncing_keys');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'signIn':
          // Mirror the Android plugin's actual payload for an outdated
          // device — ConnectionResult code in `details`.
          throw PlatformException(
            code: 'PLAY_SERVICES_UNAVAILABLE',
            message: 'Play services out of date',
            details: '2',
          );
        case 'storeBlob':
          throw PlatformException(code: 'LOCAL_WRITE', message: 'disk full');
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('PLAY_SERVICES_UNAVAILABLE → PlayServicesUnavailableException', () async {
    try {
      await platform.signInToCloud();
      fail('expected throw');
    } on PlayServicesUnavailableException catch (e) {
      expect(e.code, 2);
      expect(e.message, contains('Play services'));
    }
  });

  test('unrecognised code → PlatformChannelException', () async {
    try {
      await platform.storeBlob(id: 'x', blob: 'y', syncToCloud: false);
      fail('expected throw');
    } on PlatformChannelException catch (e) {
      expect(e.code, 'LOCAL_WRITE');
      expect(e.platformMessage, 'disk full');
    }
  });

  test('Both exceptions are SyncingKeysException', () {
    expect(const PlayServicesUnavailableException(2), isA<SyncingKeysException>());
    expect(const PlatformChannelException('X', 'y'), isA<SyncingKeysException>());
  });
}
