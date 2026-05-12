# =============================================================================
# SyncingKeys SDK — consumer ProGuard rules
# -----------------------------------------------------------------------------
# These rules are merged into the host app's R8 configuration at release-build
# time. They keep the symbols the SDK reaches into reflectively (GMS auth,
# AndroidX security-crypto, OkHttp3 internals) so a `minifyEnabled true` build
# does not strip them and cause silent runtime failures.
# =============================================================================

# Google Sign-In / OAuth — referenced by GoogleDriveBackup via reflection inside GMS.
-keep class com.google.android.gms.auth.** { *; }
-keep class com.google.android.gms.common.api.** { *; }
-dontwarn com.google.android.gms.**

# AndroidX security-crypto uses Tink under the hood; Tink loads its primitives
# by class name. Stripping any of these breaks EncryptedSharedPreferences.
-keep class com.google.crypto.tink.** { *; }
-dontwarn com.google.crypto.tink.**

# OkHttp + Okio — already ship with their own R8 rules, but pinning them
# here protects against future host-side configs that strip too aggressively.
-dontwarn okhttp3.**
-dontwarn okio.**
-dontwarn javax.annotation.**

# Kotlin coroutines — the InternalCoroutinesApi reflection lookups.
-dontwarn kotlinx.coroutines.**

# The SDK itself — kept verbatim because Flutter resolves the plugin class by
# its fully-qualified name from a generated registrar.
-keep class app.xyz.everydayapp.syncing_keys.** { *; }
