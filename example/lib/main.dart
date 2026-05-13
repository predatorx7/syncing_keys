import 'package:flutter/material.dart';
import 'package:syncing_keys/syncing_keys.dart';

/// Minimal example app showing the SyncingKeys SDK in action.
///
/// Replace [_iosKeychainGroup] with your own value from Xcode (see
/// INTEGRATION.md). Android Drive sync needs no code-side ID — drop your
/// `google-services.json` into `android/app/` and register one Android
/// OAuth client per signing-cert SHA-1 in Google Cloud Console.
const String _iosKeychainGroup = 'group.com.example.shared';

final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SyncingKeys.initialize(
    const GlobalConfig(
      iosKeychainGroup: _iosKeychainGroup,
      syncEnabled: true,
    ),
    navigatorKey: navigatorKey,
  );
  runApp(const _ExampleApp());
}

class _ExampleApp extends StatelessWidget {
  const _ExampleApp();
  @override
  Widget build(BuildContext context) => MaterialApp(
        navigatorKey: navigatorKey,
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
        home: const _Home(),
      );
}

class _Home extends StatefulWidget {
  const _Home();
  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  StoredKey? _lastKey;
  String? _error;
  bool _busy = false;

  Future<void> _withBusy(Future<void> Function() body) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await body();
    } on SyncingKeysException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('SyncingKeys example')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FilledButton(
                onPressed: _busy
                    ? null
                    : () => _withBusy(() async {
                          final k = await SyncingKeys.generateStarknetKey(id: 'main');
                          setState(() => _lastKey = k);
                        }),
                child: const Text('Generate Starknet key (id: main)'),
              ),
              const SizedBox(height: 12),
              FilledButton.tonal(
                onPressed: _busy
                    ? null
                    : () => _withBusy(() async {
                          final k = await SyncingKeys.generateEthereumKey(id: 'eth');
                          setState(() => _lastKey = k);
                        }),
                child: const Text('Generate Ethereum key (id: eth)'),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _withBusy(() async {
                          final k = await SyncingKeys.getKey('main');
                          setState(() => _lastKey = k);
                        }),
                child: const Text('Read "main" (will pull from cloud if needed)'),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _withBusy(() => SyncingKeys.deleteKey('main')),
                child: const Text('Delete "main"'),
              ),
              const SizedBox(height: 24),
              if (_busy) const LinearProgressIndicator(),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text('⚠ $_error',
                      style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
              if (_lastKey != null)
                Card(
                  margin: const EdgeInsets.only(top: 24),
                  child: ListTile(
                    title: Text(_lastKey!.id),
                    subtitle: Text(
                      '${_lastKey!.type.id}\n${_lastKey!.publicAddress}',
                    ),
                    isThreeLine: true,
                  ),
                ),
            ],
          ),
        ),
      );
}
