package app.xyz.everydayapp.syncing_keys.keystore

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/**
 * Local store for the opaque SyncingKeys envelope strings.
 *
 * Built on top of androidx.security's [EncryptedSharedPreferences], which uses
 * a master key in the Android Keystore (StrongBox-backed where available) to
 * wrap a per-file AES-GCM data key. The envelope itself is already
 * PIN-encrypted by the Dart layer; this is defence-in-depth so a rooted
 * inspection of /data/data still cannot read the envelope blob without the
 * device unlock credentials being present.
 */
class LocalSecureStore(context: Context) {

    private val masterKey: MasterKey = MasterKey.Builder(context)
        .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
        .build()

    private val prefs: SharedPreferences = EncryptedSharedPreferences.create(
        context,
        FILE_NAME,
        masterKey,
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
    )

    fun put(id: String, blob: String) {
        prefs.edit().putString(id, blob).apply()
    }

    fun get(id: String): String? = prefs.getString(id, null)

    fun delete(id: String) {
        prefs.edit().remove(id).apply()
    }

    /**
     * Returns every id ever stored under this SDK's preferences file.
     * Order is not guaranteed (SharedPreferences' Map view is unordered).
     */
    fun listIds(): List<String> = prefs.all.keys.toList()

    companion object {
        private const val FILE_NAME = "syncing_keys_envelopes_v1"
    }
}
