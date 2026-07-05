/// SyncingKeys SDK — set-and-forget secure key management for Starknet/Ethereum.
///
/// Public surface:
///   - [SyncingKeys]            – top-level facade.
///   - [GlobalConfig]       – one-shot setup payload.
///   - [PinTheme]           – customise the PIN entry sheet.
///   - [KeyType]            – ethereum | starknet.
///   - [StoredKey]          – decrypted key returned by `getKey`.
///   - Exceptions           – sealed hierarchy under [SyncingKeysException].
library;

export 'src/syncing_keys_facade.dart';
export 'src/config/global_config.dart';
export 'src/config/cloud_backend.dart';
export 'src/config/pin_theme.dart';
export 'src/models/key_type.dart';
export 'src/models/stored_key.dart';
export 'src/models/key_metadata.dart';
export 'src/models/key_conflict.dart';
export 'src/models/exceptions.dart';
export 'src/config/pin_policy.dart';
export 'src/config/syncing_keys_strings.dart';
export 'src/engine/change_pin_result.dart';
