import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import '../models/exceptions.dart';
import '../models/key_type.dart';
import 'secure_random.dart';

/// =============================================================================
/// SyncingKeys envelope format (v1)
/// -----------------------------------------------------------------------------
/// Every private key stored by the SDK is wrapped in this self-describing JSON
/// envelope **before** it ever leaves Dart. Native iOS / Android code only sees
/// the opaque base64 string — they cannot decrypt it without the PIN.
///
/// ```json
/// {
///   "v":     1,
///   "type":  "eth" | "stark",
///   "kdf":   "pbkdf2-sha256",
///   "iter":  120000,
///   "salt":  "<base64, 16 bytes>",
///   "iv":    "<base64, 12 bytes>",
///   "ct":    "<base64>",
///   "ts":    1712345678901            // optional — added in v0.1.2
/// }
/// ```
/// (`ct` is AES-GCM ciphertext with the 16-byte auth tag appended.)
///
/// `ts` is an epoch-millisecond timestamp captured at [seal] time. It is
/// **not** authenticated by the AES-GCM tag — its only use is as a tie-break
/// during cloud-vs-local reconciliation. An attacker rewriting `ts` cannot
/// recover the key, only confuse our merge logic, which is fine.
///
/// AES-GCM is used in its "combined" form: the 16-byte authentication tag is
/// appended to the ciphertext, matching the convention used by every modern
/// AEAD library so the envelope is portable.
///
/// Bumping the version: copy [Envelope] → V2 and keep V1 read-only for
/// migration. Never change v1 semantics — already-stored blobs depend on them.
/// =============================================================================
class Envelope {
  Envelope({
    required this.version,
    required this.type,
    required this.kdf,
    required this.iterations,
    required this.salt,
    required this.iv,
    required this.ciphertext,
    this.createdAtMs = 0,
  });

  final int version;
  final KeyType type;
  final String kdf;
  final int iterations;
  final Uint8List salt;
  final Uint8List iv;
  final Uint8List ciphertext;

  /// Epoch-millisecond timestamp captured when the envelope was sealed.
  /// `0` means the envelope predates the timestamp field (legacy envelopes
  /// from v0.1.0/0.1.1) — they always lose to a timestamped envelope during
  /// reconciliation.
  final int createdAtMs;

  /// Encrypts [privateKey] under [pin] and produces a fresh envelope.
  ///
  /// Generates a new random salt (16 B) and IV (12 B) every call — never
  /// reuse for a different ciphertext (catastrophic for GCM).
  static Envelope seal({
    required Uint8List privateKey,
    required String pin,
    required KeyType type,
    required int iterations,
  }) {
    final salt = SyncingRandom.instance.nextBytes(16);
    final iv = SyncingRandom.instance.nextBytes(12);
    final wrappingKey = _pbkdf2(pin, salt, iterations);
    final ct = _aesGcmEncrypt(key: wrappingKey, iv: iv, plaintext: privateKey);
    return Envelope(
      version: 1,
      type: type,
      kdf: 'pbkdf2-sha256',
      iterations: iterations,
      salt: salt,
      iv: iv,
      ciphertext: ct,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// Decrypts the envelope using [pin].
  ///
  /// Throws [WrongPinException] on GCM tag mismatch — that is *the* signal
  /// that the entered PIN does not match the one used to seal the envelope.
  Uint8List open(String pin) {
    final wrappingKey = _pbkdf2(pin, salt, iterations);
    try {
      return _aesGcmDecrypt(key: wrappingKey, iv: iv, ciphertext: ciphertext);
    } on InvalidCipherTextException {
      throw const WrongPinException();
    }
  }

  /// Serialise to the base64-JSON string we hand to the native layer.
  String toBlob() => base64Encode(utf8.encode(jsonEncode({
        'v': version,
        'type': type.id,
        'kdf': kdf,
        'iter': iterations,
        'salt': base64Encode(salt),
        'iv': base64Encode(iv),
        'ct': base64Encode(ciphertext),
        if (createdAtMs > 0) 'ts': createdAtMs,
      })));

  /// Inverse of [toBlob]. Validates every field's presence and type and
  /// throws [EnvelopeFormatException] on any deviation — this is the only
  /// untrusted-input path in the SDK, so we cannot rely on `as` casts.
  static Envelope fromBlob(String blob) {
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(utf8.decode(base64Decode(blob))) as Map<String, dynamic>;
    } catch (e) {
      throw EnvelopeFormatException('Envelope is not base64-encoded JSON: $e');
    }

    final v = _requireInt(json, 'v');
    if (v != 1) {
      throw EnvelopeFormatException('Unsupported envelope version: $v');
    }

    final typeId = _requireString(json, 'type');
    final KeyType type;
    try {
      type = KeyType.fromId(typeId);
    } catch (_) {
      throw EnvelopeFormatException('Unknown KeyType id in envelope: $typeId');
    }

    final kdf = _requireString(json, 'kdf');
    final iter = _requireInt(json, 'iter');
    if (iter < 1) {
      throw EnvelopeFormatException('Envelope iter must be > 0, got $iter');
    }
    final salt = _requireBase64(json, 'salt');
    final iv = _requireBase64(json, 'iv');
    final ct = _requireBase64(json, 'ct');
    if (salt.isEmpty || iv.length != 12 || ct.length < 16) {
      throw EnvelopeFormatException(
          'Envelope has implausible field sizes (salt=${salt.length}, '
          'iv=${iv.length}, ct=${ct.length}).');
    }

    // `ts` is optional — predates v0.1.2.
    final ts = json['ts'];
    final int createdAtMs;
    if (ts == null) {
      createdAtMs = 0;
    } else if (ts is int) {
      createdAtMs = ts;
    } else {
      throw EnvelopeFormatException('Envelope ts must be int, got ${ts.runtimeType}');
    }

    return Envelope(
      version: v,
      type: type,
      kdf: kdf,
      iterations: iter,
      salt: salt,
      iv: iv,
      ciphertext: ct,
      createdAtMs: createdAtMs,
    );
  }

  static int _requireInt(Map<String, dynamic> json, String key) {
    final v = json[key];
    if (v is int) return v;
    throw EnvelopeFormatException(
        'Envelope field "$key" must be an int, got ${v?.runtimeType}');
  }

  static String _requireString(Map<String, dynamic> json, String key) {
    final v = json[key];
    if (v is String) return v;
    throw EnvelopeFormatException(
        'Envelope field "$key" must be a String, got ${v?.runtimeType}');
  }

  static Uint8List _requireBase64(Map<String, dynamic> json, String key) {
    final s = _requireString(json, key);
    try {
      return base64Decode(s);
    } catch (e) {
      throw EnvelopeFormatException(
          'Envelope field "$key" is not valid base64: $e');
    }
  }

  // ───────────────────────── crypto primitives ─────────────────────────

  /// PBKDF2-HMAC-SHA256 — the OWASP-recommended PIN stretcher.
  ///
  /// We derive a 32-byte key suitable for AES-256-GCM. The cost factor
  /// ([iterations]) is stored in the envelope so we can ratchet it up over
  /// time without breaking older blobs.
  static Uint8List _pbkdf2(String pin, Uint8List salt, int iterations) {
    final pinBytes = Uint8List.fromList(utf8.encode(pin));
    final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(salt, iterations, 32));
    return derivator.process(pinBytes);
  }

  /// AES-256-GCM encrypt. Returns ciphertext **with the 16-byte tag appended**
  /// (the format every other modern AEAD library uses).
  static Uint8List _aesGcmEncrypt({
    required Uint8List key,
    required Uint8List iv,
    required Uint8List plaintext,
  }) {
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        true,
        AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)),
      );
    return cipher.process(plaintext);
  }

  /// AES-256-GCM decrypt with authenticated tag verification.
  static Uint8List _aesGcmDecrypt({
    required Uint8List key,
    required Uint8List iv,
    required Uint8List ciphertext,
  }) {
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        false,
        AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)),
      );
    return cipher.process(ciphertext);
  }
}
