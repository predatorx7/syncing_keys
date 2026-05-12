/// The kinds of blockchain keys the SyncingKeys SDK understands.
///
/// The [KeyType] is persisted alongside the encrypted envelope so the SDK can
/// reconstruct the correct public-address representation when a key is later
/// re-hydrated from cloud storage on a fresh device.
enum KeyType {
  /// secp256k1 BIP-44 key used by Ethereum, EVM L2s, and most EVM-compatible
  /// chains. Public address is the keccak256-hashed last-20-bytes form.
  ethereum,

  /// STARK-curve key used by Starknet. The curve order and generator differ
  /// from secp256k1 — see [keygen/starknet_key_generator.dart].
  starknet;

  /// Stable string id stored in the envelope. Never change once shipped —
  /// existing envelopes already use these.
  String get id => switch (this) {
        KeyType.ethereum => 'eth',
        KeyType.starknet => 'stark',
      };

  static KeyType fromId(String id) => switch (id) {
        'eth' => KeyType.ethereum,
        'stark' => KeyType.starknet,
        _ => throw ArgumentError('Unknown KeyType id: $id'),
      };
}
