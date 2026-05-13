package app.xyz.everydayapp.syncing_keys

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.IntentSender
import app.xyz.everydayapp.syncing_keys.drive.GoogleDriveBackup
import app.xyz.everydayapp.syncing_keys.drive.ReauthRequiredException
import app.xyz.everydayapp.syncing_keys.keystore.LocalSecureStore
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * =============================================================================
 * SyncingKeys SDK — Android plugin entry point.
 * -----------------------------------------------------------------------------
 * All cryptography happens in Dart. This class only:
 *   • parses MethodChannel calls,
 *   • stashes the opaque encrypted envelope in EncryptedSharedPreferences
 *     (Android Keystore-backed),
 *   • mirrors the envelope to Google Drive's `appDataFolder` when sync is on,
 *   • surfaces the Google account picker on first-run via the "signIn" call.
 *
 * The Drive copy is uploaded *as-is*: the envelope produced in Dart is already
 * PIN-encrypted (AES-GCM with a PBKDF2-derived key), so even though the file
 * lives in the user's Google Drive, Google can never read the plaintext.
 * =============================================================================
 */
class SyncingKeysPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    ActivityAware,
    PluginRegistry.ActivityResultListener {

    private lateinit var channel: MethodChannel
    private lateinit var appContext: Context

    private var keychainGroup: String? = null
    private var syncEnabled: Boolean = false

    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null

    /**
     * Pending result for the in-flight `signIn` call. Held only between the
     * MethodChannel call returning and `onActivityResult` firing.
     */
    private var pendingSignInResult: MethodChannel.Result? = null

    /**
     * If a background Drive call hit [ReauthRequiredException], we keep the
     * recovery `IntentSender` here so the next `signIn` invocation launches
     * it directly instead of triggering a fresh `authorize()` call. Cleared
     * once consumed or once any successful sign-in happens.
     */
    @Volatile private var pendingReauthSender: IntentSender? = null

    /**
     * Background scope for Drive REST calls. Rebuilt on every attach so a
     * hot-restart can recover after [onDetachedFromEngine] cancels it.
     */
    private var scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val localStore by lazy { LocalSecureStore(appContext) }
    private var drive: GoogleDriveBackup? = null

    // ───────────────────────── plugin lifecycle ─────────────────────────

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        // A previous detach may have cancelled the scope — rebuild so future
        // launch{} calls don't no-op silently.
        if (!scope.isActive) scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        channel = MethodChannel(
            binding.binaryMessenger,
            "app.xyz.everydayapp.syncing_keys/syncing_keys",
        )
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        // Cancel any in-flight Drive coroutines so the SupervisorJob doesn't
        // keep the FlutterEngine pinned in memory after a hot restart / engine
        // teardown. New scope is built on next onAttachedToEngine.
        scope.cancel()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        activity = binding.activity
        binding.addActivityResultListener(this)
        rebuildDrive()
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activityBinding?.removeActivityResultListener(this)
        activity = null
        activityBinding = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activityBinding = binding
        activity = binding.activity
        binding.addActivityResultListener(this)
        rebuildDrive()
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeActivityResultListener(this)
        activity = null
        activityBinding = null
    }

    private fun rebuildDrive() {
        val act = activity
        // Drive's `Identity.getAuthorizationClient` resolves the OAuth client
        // implicitly via the running APK's package + cert SHA-1 against the
        // entries in google-services.json — no client ID needed in code.
        drive = if (act != null) GoogleDriveBackup(act) else null
    }

    /**
     * True iff Google Play services are installed and at a version we can
     * call into. Used by `isCloudAvailable` and gating
     * `signInToCloud`/Drive ops, so a stale device surfaces a typed error
     * instead of a runtime ApiException from deep inside GMS.
     */
    private fun playServicesUsable(): Boolean {
        val ctx = activity ?: appContext
        return GoogleApiAvailability.getInstance()
            .isGooglePlayServicesAvailable(ctx) == ConnectionResult.SUCCESS
    }

    // ───────────────────────── method dispatch ──────────────────────────

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "configure" -> handleConfigure(call, result)
            "storeBlob" -> handleStoreBlob(call, result)
            "readBlob"  -> handleReadBlob(call, result)
            "deleteBlob" -> handleDeleteBlob(call, result)
            "listLocalIds" -> {
                try { result.success(localStore.listIds()) }
                catch (t: Throwable) { result.error("LOCAL_LIST", t.message, t.stackTraceToString()) }
            }
            "listCloudIds" -> handleListCloudIds(result)
            "signIn" -> handleSignIn(result)
            "signOut" -> handleSignOut(result)
            "isCloudAvailable" -> result.success(
                // Four gates: developer opt-in, GMS present & current, Drive
                // helper authorized, no pending recovery intent.
                syncEnabled
                    && playServicesUsable()
                    && drive?.isReady() == true
                    && pendingReauthSender == null,
            )
            "getPlatformVersion" -> result.success("Android ${android.os.Build.VERSION.RELEASE}")
            else -> result.notImplemented()
        }
    }

    /**
     * Lists ids stored in the Drive appDataFolder. Empty when sync is off,
     * Drive is not configured, or the helper isn't authorized yet — the
     * Dart layer treats those uniformly as "nothing on the cloud right now."
     */
    private fun handleListCloudIds(result: MethodChannel.Result) {
        val d = drive
        if (!syncEnabled || d == null) { result.success(emptyList<String>()); return }
        scope.launch {
            val ids = try {
                d.listIds()
            } catch (re: ReauthRequiredException) {
                pendingReauthSender = re.recoverySender
                emptyList()
            } catch (t: Throwable) {
                android.util.Log.w("SyncingKeys", "Drive list ids failed: ${t.message}", t)
                emptyList()
            }
            withContext(Dispatchers.Main) { result.success(ids) }
        }
    }

    private fun handleConfigure(call: MethodCall, result: MethodChannel.Result) {
        keychainGroup  = call.argument<String>("iosKeychainGroup")
        syncEnabled    = call.argument<Boolean>("syncEnabled") ?: false
        rebuildDrive()
        result.success(null)
    }

    /**
     * Surfaces Google's authorization flow so the user grants the
     * `drive.appdata` scope to your app. Resolves the MethodChannel future
     * with `true` on success, `false` on user-cancel, or an error code if
     * the configuration is wrong.
     *
     * If a previous Drive call already captured a re-auth `IntentSender`,
     * we launch that directly; otherwise we call `authorize()` and decide
     * based on the result whether to silently succeed or launch the
     * consent screen.
     */
    private fun handleSignIn(result: MethodChannel.Result) {
        val act = activity
        val d   = drive
        if (act == null) {
            result.error("NO_ACTIVITY", "Plugin is not attached to an Activity.", null); return
        }
        if (d == null) {
            // Activity not attached yet — shouldn't happen for a UI-triggered
            // signIn call, but surface it cleanly if it does.
            result.error("NO_ACTIVITY",
                "Drive helper is not initialised (no Activity attached).",
                null); return
        }
        // Surface a typed error if Play services are missing or stale —
        // otherwise Identity.authorize() throws a generic ApiException
        // from deep inside GMS, which is hard to recover from.
        val gms = GoogleApiAvailability.getInstance()
            .isGooglePlayServicesAvailable(act)
        if (gms != ConnectionResult.SUCCESS) {
            result.error("PLAY_SERVICES_UNAVAILABLE",
                "Google Play services are unavailable or out of date " +
                    "(code=$gms). Ask the user to install/update them.",
                gms.toString())
            return
        }
        if (pendingSignInResult != null) {
            result.error("SIGN_IN_IN_PROGRESS",
                "Another signIn() call is already awaiting an Activity result.",
                null); return
        }

        // Captured recovery sender (revoked grant / expired token) — fire
        // straight away.
        pendingReauthSender?.let { sender ->
            pendingSignInResult = result
            try {
                act.startIntentSenderForResult(sender, RC_SIGN_IN, null, 0, 0, 0)
            } catch (t: Throwable) {
                pendingSignInResult = null
                pendingReauthSender = null
                result.error("SIGN_IN_LAUNCH", t.message, t.stackTraceToString())
            }
            return
        }

        // No captured sender — ask Identity to authorize. On the silent path
        // this short-circuits without surfacing UI; on the consent path it
        // hands us a PendingIntent we then launch.
        pendingSignInResult = result
        scope.launch {
            try {
                val authResult = d.authorize()
                if (authResult.hasResolution()) {
                    val pi = authResult.pendingIntent
                    if (pi == null) {
                        completeSignIn(false)
                    } else {
                        try {
                            act.startIntentSenderForResult(
                                pi.intentSender, RC_SIGN_IN, null, 0, 0, 0,
                            )
                            // pendingSignInResult is resolved in onActivityResult.
                        } catch (t: Throwable) {
                            completeSignInError("SIGN_IN_LAUNCH", t)
                        }
                    }
                } else if (authResult.accessToken != null) {
                    completeSignIn(true)
                } else {
                    completeSignIn(false)
                }
            } catch (t: Throwable) {
                completeSignInError("SIGN_IN_FAILED", t)
            }
        }
    }

    private fun completeSignIn(success: Boolean) {
        val pending = pendingSignInResult ?: return
        pendingSignInResult = null
        pending.success(success)
    }

    private fun completeSignInError(code: String, t: Throwable) {
        val pending = pendingSignInResult ?: return
        pendingSignInResult = null
        pending.error(code, t.message, t.stackTraceToString())
    }

    /**
     * Clears the cached authorization state. The user's app should call
     * this when the user signs out — it doesn't revoke the Google grant
     * (only the user can do that at myaccount.google.com), nor does it
     * delete cloud blobs.
     */
    private fun handleSignOut(result: MethodChannel.Result) {
        drive?.clearAuthorization()
        result.success(null)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != RC_SIGN_IN) return false
        val pending = pendingSignInResult ?: return true
        pendingSignInResult = null
        val wasReauth = pendingReauthSender != null
        pendingReauthSender = null
        try {
            if (resultCode != Activity.RESULT_OK) {
                pending.success(false)
                return true
            }
            // Try to consume the AuthorizationResult so we cache the token.
            // markAuthorizedFromIntent returns false if the intent had no
            // usable result; for revoked-scope recoveries that's still OK
            // because the next Drive call will re-authorize.
            val ok = drive?.markAuthorizedFromIntent(data) ?: false
            pending.success(ok || wasReauth)
        } catch (t: Throwable) {
            pending.error("SIGN_IN_FAILED", t.message, t.stackTraceToString())
        }
        return true
    }

    // ───────────────────────── CRUD handlers ────────────────────────────

    /**
     * saveKey() entry on the platform side.
     * Local write is synchronous (it's just a SharedPreferences put on an
     * encrypted file), but the Drive upload is dispatched to the IO scope so
     * the developer's `await` resolves the moment the local copy is durable.
     */
    private fun handleStoreBlob(call: MethodCall, result: MethodChannel.Result) {
        val id   = call.argument<String>("id")
        val blob = call.argument<String>("blob")
        val sync = call.argument<Boolean>("syncToCloud") ?: false
        if (id == null || blob == null) {
            result.error("BAD_ARGS", "id and blob required", null); return
        }

        // 1) Local — fast and durable.
        try {
            localStore.put(id, blob)
        } catch (t: Throwable) {
            result.error("LOCAL_WRITE", t.message, t.stackTraceToString()); return
        }

        // 2) Drive — fire-and-forget, but errors are surfaced through a log.
        if (sync && drive != null) {
            scope.launch {
                try {
                    drive!!.upload(id, blob)
                } catch (re: ReauthRequiredException) {
                    pendingReauthSender = re.recoverySender
                    android.util.Log.w("SyncingKeys",
                        "Drive upload for ${redactId(id)} needs re-auth: ${re.message}", re)
                } catch (t: Throwable) {
                    android.util.Log.w("SyncingKeys",
                        "Drive upload for ${redactId(id)} failed: ${t.message}", t)
                }
            }
        }
        result.success(null)
    }

    private fun handleReadBlob(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("id")
        val allowCloud = call.argument<Boolean>("allowCloudFallback") ?: false
        if (id == null) {
            result.error("BAD_ARGS", "id required", null); return
        }

        // Fast path — local read.
        val local = localStore.get(id)
        if (local != null) {
            result.success(mapOf("blob" to local, "fromCloud" to false)); return
        }

        // Slow path — cloud lookup. We await this on a background dispatcher
        // so the Dart layer stays responsive and can show its loading dialog.
        if (allowCloud && syncEnabled && drive != null) {
            scope.launch {
                val cloud = try {
                    drive!!.download(id)
                } catch (re: ReauthRequiredException) {
                    pendingReauthSender = re.recoverySender
                    android.util.Log.w("SyncingKeys",
                        "Drive download for ${redactId(id)} needs re-auth: ${re.message}", re)
                    null
                } catch (t: Throwable) {
                    android.util.Log.w("SyncingKeys",
                        "Drive download for ${redactId(id)} failed: ${t.message}", t)
                    null
                }

                withContext(Dispatchers.Main) {
                    if (cloud != null) {
                        // Cache the cloud copy back locally so subsequent
                        // reads are offline-fast.
                        try { localStore.put(id, cloud) } catch (_: Throwable) { /* best-effort */ }
                        result.success(mapOf("blob" to cloud, "fromCloud" to true))
                    } else {
                        result.success(null)
                    }
                }
            }
        } else {
            result.success(null)
        }
    }

    private fun handleDeleteBlob(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("id")
        val deleteFromCloud = call.argument<Boolean>("deleteFromCloud") ?: false
        if (id == null) {
            result.error("BAD_ARGS", "id required", null); return
        }

        try {
            localStore.delete(id)
        } catch (t: Throwable) {
            result.error("LOCAL_DELETE", t.message, t.stackTraceToString()); return
        }

        if (deleteFromCloud && drive != null) {
            scope.launch {
                try {
                    drive!!.delete(id)
                } catch (re: ReauthRequiredException) {
                    pendingReauthSender = re.recoverySender
                    android.util.Log.w("SyncingKeys",
                        "Drive delete for ${redactId(id)} needs re-auth: ${re.message}", re)
                } catch (t: Throwable) {
                    android.util.Log.w("SyncingKeys",
                        "Drive delete for ${redactId(id)} failed: ${t.message}", t)
                }
            }
        }
        result.success(null)
    }

    companion object {
        /** Activity-result request code for the Google Sign-In intent. */
        private const val RC_SIGN_IN = 0xC0FFEE and 0xFFFF

        /**
         * Hash-prefix an id before logging so wallet-flavoured ids
         * (e.g. "wallet-{userId}") don't leak verbatim into logcat. Two
         * decimal digits is enough to keep different ids distinguishable
         * for debugging while making it un-attributable on its own.
         */
        @JvmStatic
        fun redactId(id: String): String {
            val h = (id.hashCode() and 0xFFFF).toString(16).padStart(4, '0')
            return "<id:$h>"
        }
    }
}
