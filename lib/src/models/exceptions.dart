/// Base class for every error the SyncingKeys SDK throws. Developers can catch
/// this single type to recover gracefully across all failure modes.
sealed class SyncingKeysException implements Exception {
  const SyncingKeysException(this.message);
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// Thrown when [SyncingKeys.initialize] has not been called before a CRUD op.
class SyncingKeysNotInitializedException extends SyncingKeysException {
  const SyncingKeysNotInitializedException()
      : super('SyncingKeys.initialize() must be called before any CRUD call.');
}

/// Thrown when the user cancels the PIN entry dialog or fails too many times.
class PinEntryCancelledException extends SyncingKeysException {
  const PinEntryCancelledException([super.message = 'PIN entry cancelled.']);
}

/// Thrown when AES-GCM authentication fails — typically a wrong PIN, but
/// can also indicate envelope tampering.
class WrongPinException extends SyncingKeysException {
  const WrongPinException()
      : super('Incorrect PIN — envelope decryption failed authentication tag check.');
}

/// Thrown when a requested key is not present locally and not in the cloud
/// (or sync is disabled). Distinct from [WrongPinException] — the blob is
/// genuinely absent rather than undecryptable.
class KeyNotFoundException extends SyncingKeysException {
  KeyNotFoundException(this.keyId) : super('No key found for id "$keyId".');
  final String keyId;
}

/// Thrown for network/cloud failures that the SDK could not silently recover
/// from. The CRUD engine never throws this when [GlobalConfig.syncEnabled] is
/// `false`.
class CloudSyncException extends SyncingKeysException {
  const CloudSyncException(super.message);
}

/// Thrown when the cloud OAuth token has expired or the user has revoked the
/// scope. The host app should respond by calling
/// [SyncingKeys.signInToCloud] which will fast-path through the platform's
/// recovery intent if one was captured.
class CloudReauthRequiredException extends SyncingKeysException {
  const CloudReauthRequiredException()
      : super('Cloud sign-in required — call SyncingKeys.signInToCloud().');
}

/// Thrown when Google Play services are missing or out of date on the
/// device. Android-only — `code` is the integer from
/// `GoogleApiAvailability.isGooglePlayServicesAvailable` (e.g. 1 =
/// `SERVICE_MISSING`, 2 = `SERVICE_VERSION_UPDATE_REQUIRED`,
/// 18 = `SERVICE_UPDATING`).
class PlayServicesUnavailableException extends SyncingKeysException {
  const PlayServicesUnavailableException(this.code, [String? msg])
      : super(msg ?? 'Google Play services are unavailable (code=$code).');

  /// The raw `ConnectionResult` code, useful for surfacing the right
  /// recovery flow to the user (install / update / wait / etc.).
  final int code;
}

/// Generic typed wrapper for any other [PlatformException] thrown by the
/// native side of the SDK. Callers who don't need to discriminate can
/// catch [SyncingKeysException] and get every error in one branch.
class PlatformChannelException extends SyncingKeysException {
  const PlatformChannelException(this.code, this.platformMessage)
      : super('Platform channel error ($code): $platformMessage');

  /// The original `PlatformException.code` ("BAD_ARGS", "LOCAL_WRITE", …).
  final String code;

  /// The original `PlatformException.message`.
  final String? platformMessage;
}

/// Thrown when the envelope JSON cannot be parsed — usually means a different
/// SDK version wrote it. Bump the envelope `v` field carefully.
class EnvelopeFormatException extends SyncingKeysException {
  const EnvelopeFormatException(super.message);
}
