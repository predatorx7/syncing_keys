package app.xyz.everydayapp.syncing_keys.drive

import android.content.IntentSender

/**
 * Thrown by [GoogleDriveBackup] when the user must (re-)grant the
 * `drive.appdata` scope. The plugin launches [recoverySender] via
 * `Activity.startIntentSenderForResult(...)` to surface Google's consent
 * screen.
 *
 * We carry an [IntentSender] rather than a plain `Intent` because the
 * modern `Identity.getAuthorizationClient` API hands back a `PendingIntent`
 * whose intent payload is opaque — we can only fire it via its sender.
 */
class ReauthRequiredException(
    message: String,
    val recoverySender: IntentSender,
) : Exception(message)
