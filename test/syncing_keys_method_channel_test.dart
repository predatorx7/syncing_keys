import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncing_keys/syncing_keys_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final platform = MethodChannelSyncingKeys();
  const channel = MethodChannel('app.xyz.everydayapp.syncing_keys/syncing_keys');

  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'getPlatformVersion' => 'mock-os',
        'isCloudAvailable' => true,
        'readBlob' => {'blob': 'opaque', 'fromCloud': false},
        _ => null,
      };
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('getPlatformVersion forwards through the channel', () async {
    expect(await platform.getPlatformVersion(), 'mock-os');
    expect(calls.single.method, 'getPlatformVersion');
  });

  test('storeBlob ships the right arg map', () async {
    await platform.storeBlob(id: 'k', blob: 'b64-blob', syncToCloud: true);
    final args = calls.single.arguments as Map;
    expect(args['id'], 'k');
    expect(args['blob'], 'b64-blob');
    expect(args['syncToCloud'], true);
  });

  test('readBlob materialises into a BlobLookup', () async {
    final lookup = await platform.readBlob(id: 'k', allowCloudFallback: true);
    expect(lookup?.blob, 'opaque');
    expect(lookup?.fromCloud, false);
  });
}
