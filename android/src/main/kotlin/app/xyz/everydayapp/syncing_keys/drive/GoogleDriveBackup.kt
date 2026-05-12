package app.xyz.everydayapp.syncing_keys.drive

import android.app.Activity
import android.content.Intent
import com.google.android.gms.auth.api.identity.AuthorizationRequest
import com.google.android.gms.auth.api.identity.AuthorizationResult
import com.google.android.gms.auth.api.identity.Identity
import com.google.android.gms.common.api.Scope
import com.google.android.gms.tasks.Task
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * =============================================================================
 * GoogleDriveBackup — Drive REST v3 helper, scoped to `drive.appdata`.
 * -----------------------------------------------------------------------------
 * The Drive `appDataFolder` is a per-app hidden folder. Files there are
 * invisible in the Drive UI and inaccessible to other apps; only the OAuth
 * client that uploaded them can list/read/delete them. That makes it the
 * correct destination for opaque encrypted backups.
 *
 * Why raw OkHttp instead of the Drive Android SDK?
 *   • The Drive SDK pulls in a heavy chain of GMS deps that often clash with
 *     other plugins.
 *   • All we need is three endpoints: create (multipart), list, get/media,
 *     delete. Easy to call directly.
 *
 * File-naming convention: every envelope is uploaded as a file named
 * `syncing-keys-<id>.bin`. We look it up by name via
 * `q=name='syncing-keys-<id>.bin'`.
 *
 * Auth model (migrated off the deprecated `GoogleSignIn` API as of v0.1.0):
 *   • We use Google Identity's [Identity.getAuthorizationClient] to call
 *     `authorize(AuthorizationRequest)`. The Task resolves with an
 *     [AuthorizationResult] that either:
 *       (a) already contains a fresh access token (cached / silent path), or
 *       (b) returns a `PendingIntent` we must launch to surface the user's
 *           consent screen (first-run or revoked-scope path).
 *   • For path (b) we throw [ReauthRequiredException] so the plugin layer
 *     can route the `IntentSender` through `startIntentSenderForResult`,
 *     reusing the same `RC_SIGN_IN` request code as the first-run picker.
 *   • Tokens are short-lived (~1 h); calling `authorize()` again refreshes
 *     them silently when possible.
 *
 * The developer must:
 *   1. Register their OAuth client in Google Cloud Console with the
 *      SHA-1 of their signing certificate.
 *   2. Pass the client ID to SyncingKeys via `GlobalConfig.androidDriveClientId`.
 *      (Used only as a configuration marker — the runtime authorization
 *      flow is matched implicitly by package name + signing certificate.)
 *   3. Enable the Drive API for the project.
 * See INTEGRATION.md for screenshots / steps.
 * =============================================================================
 */
class GoogleDriveBackup(
    private val activity: Activity,
    @Suppress("unused") private val clientId: String,
) {
    private val http = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .build()

    private val authClient by lazy { Identity.getAuthorizationClient(activity) }

    /**
     * Flipped to `true` after a successful silent authorize() or a
     * successful resolution-intent activity result. Drives the cheap
     * [isReady] probe that the plugin reports via `isCloudAvailable`.
     */
    @Volatile private var authorized: Boolean = false

    /** Cheap check used by `SyncingKeys.isCloudAvailable` — non-blocking. */
    fun isReady(): Boolean = authorized

    /**
     * The plugin calls this after `onActivityResult(RC_SIGN_IN)` to confirm
     * the user's consent and cache the resulting access token. Returns
     * `true` on success, `false` if no usable token came back.
     */
    fun markAuthorizedFromIntent(data: Intent?): Boolean {
        val intent = data ?: return false
        return try {
            val result = authClient.getAuthorizationResultFromIntent(intent)
            val ok = result.accessToken != null
            authorized = ok
            ok
        } catch (_: Throwable) {
            false
        }
    }

    /** Forget the cached authorization (host-side signOut). */
    fun clearAuthorization() {
        authorized = false
    }

    /**
     * Performs the authorize() call and returns the result. The caller is
     * responsible for inspecting `hasResolution()` and routing the
     * resolution intent appropriately.
     */
    suspend fun authorize(): AuthorizationResult {
        val request = AuthorizationRequest.builder()
            .setRequestedScopes(listOf(Scope(DRIVE_APPDATA_SCOPE)))
            .build()
        return authClient.authorize(request).awaitTask()
    }

    /**
     * Returns a usable OAuth access token, or throws [ReauthRequiredException]
     * if the user needs to (re-)consent. Called inside each Drive REST call.
     */
    private suspend fun requireToken(): String {
        val result = authorize()
        if (result.hasResolution()) {
            val pi = result.pendingIntent
                ?: throw IllegalStateException(
                    "AuthorizationResult requires resolution but has no PendingIntent.",
                )
            authorized = false
            throw ReauthRequiredException(
                message = "Drive scope authorization required.",
                recoverySender = pi.intentSender,
            )
        }
        val token = result.accessToken
            ?: throw IllegalStateException(
                "AuthorizationResult had neither a resolution nor an accessToken.",
            )
        authorized = true
        return token
    }

    // ────────────────────────── upload (PUT) ──────────────────────────

    /**
     * Uploads [blob] to the `appDataFolder` as `syncing-keys-<id>.bin`.
     *
     * If a file with that name already exists, we PATCH (update its media);
     * otherwise we POST a new multipart upload. Drive's "media" endpoint
     * handles the byte stream; the JSON metadata names the file and pins it
     * to the appDataFolder.
     */
    suspend fun upload(id: String, blob: String) {
        val token = requireToken()
        val fileName = nameFor(id)

        // The envelope blob is technically base64 ASCII, but we treat it as
        // opaque bytes here so larger payloads (a future binary envelope
        // format, say) don't trip on String->ByteArray conversion costs.
        val payload: ByteArray = blob.toByteArray(Charsets.UTF_8)

        val existingId = findFileId(fileName, token)

        if (existingId != null) {
            val req = Request.Builder()
                .url("$UPLOAD_BASE/files/$existingId?uploadType=media")
                .header("Authorization", "Bearer $token")
                .patch(payload.toRequestBody(OCTET, 0, payload.size))
                .build()
            http.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) throw drive("PATCH", resp.code, resp.body?.string())
            }
            return
        }

        // Drive's "multipart/related" upload accepts two parts: a JSON
        // metadata part and a media-bytes part. We hand-roll the boundary
        // framing because OkHttp's MultipartBody uses "multipart/form-data"
        // (Content-Disposition headers) which Drive rejects.
        val boundary = "sk-${System.nanoTime()}-${(Math.random() * 1e9).toLong()}"
        val crlf = "\r\n".toByteArray(Charsets.US_ASCII)
        val metadataJson = JSONObject().apply {
            put("name", fileName)
            put("parents", org.json.JSONArray().put("appDataFolder"))
            put("mimeType", OCTET.toString())
        }.toString().toByteArray(Charsets.UTF_8)

        val bodyBytes = buildList<ByteArray> {
            add("--$boundary".toByteArray()); add(crlf)
            add("Content-Type: application/json; charset=UTF-8".toByteArray()); add(crlf); add(crlf)
            add(metadataJson); add(crlf)
            add("--$boundary".toByteArray()); add(crlf)
            add("Content-Type: $OCTET".toByteArray()); add(crlf); add(crlf)
            add(payload); add(crlf)
            add("--$boundary--".toByteArray())
        }.reduce { acc, bs -> acc + bs }

        val req = Request.Builder()
            .url("$UPLOAD_BASE/files?uploadType=multipart&supportsAllDrives=true")
            .header("Authorization", "Bearer $token")
            .post(bodyBytes.toRequestBody(
                "multipart/related; boundary=$boundary".toMediaType(),
                0,
                bodyBytes.size,
            ))
            .build()
        http.newCall(req).execute().use { resp ->
            if (!resp.isSuccessful) throw drive("CREATE", resp.code, resp.body?.string())
        }
    }

    // ────────────────────────── download (GET) ────────────────────────

    /**
     * Returns the envelope blob for [id], or null if no such file is
     * present in the appDataFolder.
     */
    suspend fun download(id: String): String? {
        val token = requireToken()
        val fileId = findFileId(nameFor(id), token) ?: return null

        val req = Request.Builder()
            .url("$API_BASE/files/$fileId?alt=media")
            .header("Authorization", "Bearer $token")
            .get()
            .build()
        http.newCall(req).execute().use { resp ->
            if (resp.code == 404) return null
            if (!resp.isSuccessful) throw drive("DOWNLOAD", resp.code, resp.body?.string())
            return resp.body?.string()
        }
    }

    // ────────────────────────── delete ────────────────────────────────

    suspend fun delete(id: String) {
        val token = requireToken()
        val fileId = findFileId(nameFor(id), token) ?: return /* idempotent */

        val req = Request.Builder()
            .url("$API_BASE/files/$fileId")
            .header("Authorization", "Bearer $token")
            .delete()
            .build()
        http.newCall(req).execute().use { resp ->
            if (resp.code == 404) return
            if (!resp.isSuccessful) throw drive("DELETE", resp.code, resp.body?.string())
        }
    }

    /**
     * Enumerates every `syncing-keys-*.bin` blob in the appDataFolder and
     * returns the developer-chosen ids (i.e. the part between the prefix
     * and the `.bin` suffix). Returns an empty list when the helper is
     * not authorized — the next call will trigger a fresh authorize().
     */
    suspend fun listIds(): List<String> {
        val token = requireToken()
        val q = "'appDataFolder' in parents and trashed=false and name contains 'syncing-keys-'"
        val url = "$API_BASE/files?spaces=appDataFolder&fields=files(name)" +
            "&pageSize=1000&q=${java.net.URLEncoder.encode(q, "UTF-8")}"
        val req = Request.Builder()
            .url(url)
            .header("Authorization", "Bearer $token")
            .get()
            .build()
        http.newCall(req).execute().use { resp ->
            if (!resp.isSuccessful) throw drive("LIST", resp.code, resp.body?.string())
            val json = JSONObject(resp.body?.string() ?: return emptyList())
            val arr = json.optJSONArray("files") ?: return emptyList()
            val out = mutableListOf<String>()
            for (i in 0 until arr.length()) {
                val name = arr.getJSONObject(i).optString("name")
                if (name.startsWith("syncing-keys-") && name.endsWith(".bin")) {
                    out.add(name.removePrefix("syncing-keys-").removeSuffix(".bin"))
                }
            }
            return out
        }
    }

    // ────────────────────────── helpers ───────────────────────────────

    private fun findFileId(name: String, token: String): String? {
        // Drive search: scope to appDataFolder so we don't leak file IDs.
        val q = "name='${name.replace("'", "\\'")}' and 'appDataFolder' in parents and trashed=false"
        val url = "$API_BASE/files?spaces=appDataFolder&fields=files(id,name)" +
            "&q=${java.net.URLEncoder.encode(q, "UTF-8")}"
        val req = Request.Builder()
            .url(url)
            .header("Authorization", "Bearer $token")
            .get()
            .build()
        http.newCall(req).execute().use { resp ->
            if (!resp.isSuccessful) throw drive("LIST", resp.code, resp.body?.string())
            val json = JSONObject(resp.body?.string() ?: return null)
            val arr = json.optJSONArray("files") ?: return null
            if (arr.length() == 0) return null
            return arr.getJSONObject(0).getString("id")
        }
    }

    private fun nameFor(id: String) = "syncing-keys-${id}.bin"

    private fun drive(op: String, code: Int, body: String?) =
        IllegalStateException("Drive $op failed (HTTP $code): ${body ?: "<empty>"}")

    companion object {
        private const val DRIVE_APPDATA_SCOPE = "https://www.googleapis.com/auth/drive.appdata"
        private const val API_BASE = "https://www.googleapis.com/drive/v3"
        private const val UPLOAD_BASE = "https://www.googleapis.com/upload/drive/v3"
        private val OCTET = "application/octet-stream".toMediaType()
    }
}

/**
 * Tiny GMS Task → coroutine bridge — saves us from pulling in
 * `kotlinx-coroutines-play-services` for a single helper.
 */
private suspend fun <T> Task<T>.awaitTask(): T = suspendCancellableCoroutine { cont ->
    addOnSuccessListener { cont.resume(it) }
    addOnFailureListener { cont.resumeWithException(it) }
}
