import Flutter
import UIKit

/// =============================================================================
/// SyncingKeys SDK — iOS plugin entry point.
/// -----------------------------------------------------------------------------
/// All cryptography happens in Dart. This class only:
///   • parses the FlutterMethodCalls,
///   • stores opaque encrypted *envelopes* in the iOS Keychain,
///   • flips kSecAttrSynchronizable on/off so iCloud Keychain handles the
///     cross-device propagation transparently.
///
/// The Keychain item shape:
///   kSecClass            = kSecClassGenericPassword
///   kSecAttrService      = "app.xyz.everydayapp.syncing_keys"
///   kSecAttrAccount      = <developer-supplied id, e.g. "main-wallet">
///   kSecAttrAccessGroup  = <iosKeychainGroup from GlobalConfig>           (optional)
///   kSecAttrSynchronizable = true if sync && we want this item on iCloud
///   kSecValueData        = <base64 envelope bytes from Dart>
///
/// iCloud Keychain end-to-end-encrypts items it syncs (Apple cannot read the
/// plaintext), and our envelope is itself PIN-encrypted, so the user's keys
/// are protected even if iCloud were ever compromised.
/// =============================================================================
public class SyncingKeysPlugin: NSObject, FlutterPlugin {

    private static let channelName = "app.xyz.everydayapp.syncing_keys/syncing_keys"
    private static let service = "app.xyz.everydayapp.syncing_keys"

    private var keychainGroup: String?
    private var syncEnabled: Bool = false

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: channelName, binaryMessenger: registrar.messenger())
        let instance = SyncingKeysPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {

        case "configure":
            let args = call.arguments as? [String: Any?] ?? [:]
            self.keychainGroup = args["iosKeychainGroup"] as? String
            self.syncEnabled = (args["syncEnabled"] as? Bool) ?? false
            result(nil)

        case "storeBlob":
            guard let args = call.arguments as? [String: Any?],
                  let id   = args["id"]   as? String,
                  let blob = args["blob"] as? String else {
                result(self.argError("storeBlob")); return
            }
            let syncToCloud = (args["syncToCloud"] as? Bool) ?? false
            do {
                try store(id: id, blob: blob, sync: syncToCloud)
                result(nil)
            } catch {
                result(self.flutterError("storeBlob", error)); return
            }

        case "readBlob":
            guard let args = call.arguments as? [String: Any?],
                  let id   = args["id"]    as? String else {
                result(self.argError("readBlob")); return
            }
            let allowCloud = (args["allowCloudFallback"] as? Bool) ?? false
            do {
                if let local = try read(id: id, syncFlag: false) {
                    result(["blob": local, "fromCloud": false]); return
                }
                if allowCloud && self.syncEnabled,
                   let cloud = try read(id: id, syncFlag: true) {
                    // Best-effort: cache the cloud copy back to a non-sync
                    // local row so the next read is offline-fast. The cloud
                    // copy keeps living on its own row.
                    try? store(id: id, blob: cloud, sync: false)
                    result(["blob": cloud, "fromCloud": true]); return
                }
                result(nil)
            } catch {
                result(self.flutterError("readBlob", error))
            }

        case "listLocalIds":
            do {
                result(try self.listIds(syncFlag: false))
            } catch {
                result(self.flutterError("listLocalIds", error))
            }

        case "listCloudIds":
            // iCloud Keychain doesn't have a "remote list" API distinct from
            // the local query — once an item has propagated, it's queryable
            // by SecItemCopyMatching with kSecAttrSynchronizable=true. On a
            // brand-new device the iCloud Keychain bridge populates these
            // rows in the background; we simply query whatever's currently
            // visible. The Dart layer dedups against listLocalIds.
            if !self.syncEnabled {
                result([] as [String]); return
            }
            do {
                result(try self.listIds(syncFlag: true))
            } catch {
                result(self.flutterError("listCloudIds", error))
            }

        case "deleteBlob":
            guard let args = call.arguments as? [String: Any?],
                  let id   = args["id"]    as? String else {
                result(self.argError("deleteBlob")); return
            }
            let deleteFromCloud = (args["deleteFromCloud"] as? Bool) ?? false
            do {
                try delete(id: id, syncFlag: false)
                if deleteFromCloud { try delete(id: id, syncFlag: true) }
                result(nil)
            } catch {
                result(self.flutterError("deleteBlob", error))
            }

        case "isCloudAvailable":
            // We use FileManager.ubiquityIdentityToken as a proxy — it's
            // non-nil iff the device has an iCloud identity. This is *not*
            // the same as "iCloud Keychain is enabled" — Apple offers no
            // public API to check the latter. So this method reports a
            // *necessary* but not strictly *sufficient* condition. If the
            // user has iCloud Drive but disabled iCloud Keychain, syncs
            // will silently no-op and we'd have no way to tell — direct
            // affected users to **Settings → [their name] → iCloud →
            // Passwords & Keychain** to verify.
            let hasICloud = FileManager.default.ubiquityIdentityToken != nil
            result(self.syncEnabled && hasICloud)

        case "signIn":
            // iCloud sign-in is OS-owned — third-party apps cannot launch
            // the Settings sign-in pane directly. We resolve based on the
            // current iCloud identity so the developer can decide whether
            // to instruct the user to enable iCloud Keychain manually.
            result(FileManager.default.ubiquityIdentityToken != nil)

        case "signOut":
            // No-op on iOS — Apple ID sign-out is a system-level action.
            result(nil)

        case "getPlatformVersion":
            result("iOS " + UIDevice.current.systemVersion)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // ────────────────────────────────────────────────────────────────────
    // Keychain primitives
    // ────────────────────────────────────────────────────────────────────

    /// Inserts or replaces a Keychain item.
    ///
    /// We use kSecAttrAccessibleAfterFirstUnlock when sync == true so that
    /// the item is eligible for iCloud Keychain sync; otherwise we use
    /// kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly to pin it locally.
    private func store(id: String, blob: String, sync: Bool) throws {
        guard let data = blob.data(using: .utf8) else {
            throw NSError(domain: "SyncingKeys", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Blob not utf8"])
        }

        var query = baseQuery(id: id, syncFlag: sync)
        // Try to update first; if no row exists, fall through to add.
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: sync
                ? kSecAttrAccessibleAfterFirstUnlock
                : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        var status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            // Combine the query and the attrs for the SecItemAdd call.
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = attrs[kSecAttrAccessible as String]
            status = SecItemAdd(query as CFDictionary, nil)
        }
        try checkStatus(status)
    }

    /// Returns the blob string or nil if absent.
    private func read(id: String, syncFlag: Bool) throws -> String? {
        var query = baseQuery(id: id, syncFlag: syncFlag)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try checkStatus(status)
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Enumerates Keychain rows for the given sync flag and returns each
    /// row's `kSecAttrAccount` value — those are the developer-chosen ids.
    /// Pass `false` for the always-present local copy, `true` for items
    /// that have a corresponding iCloud-sync row.
    private func listIds(syncFlag: Bool) throws -> [String] {
        var query = baseQuery(id: "", syncFlag: syncFlag)
        query.removeValue(forKey: kSecAttrAccount as String)
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = kCFBooleanTrue

        var raw: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &raw)
        if status == errSecItemNotFound { return [] }
        try checkStatus(status)
        guard let items = raw as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    private func delete(id: String, syncFlag: Bool) throws {
        let query = baseQuery(id: id, syncFlag: syncFlag)
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound { return /* idempotent */ }
        try checkStatus(status)
    }

    /// Common attributes shared by all CRUD queries. The kSecAttrSynchronizable
    /// flag is **part of the primary key** for Keychain rows, which is why we
    /// keep a separate copy on each side of the sync flag — they are distinct
    /// items as far as the Security framework is concerned.
    private func baseQuery(id: String, syncFlag: Bool) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  SyncingKeysPlugin.service,
            kSecAttrAccount as String:  id,
            kSecAttrSynchronizable as String: syncFlag
                ? kCFBooleanTrue!
                : kCFBooleanFalse!,
            // Required on macOS (and Catalyst) so we land in the modern
            // data-protection Keychain rather than the legacy file
            // Keychain. iOS has only one Keychain so the flag is a no-op
            // there, but setting it unconditionally keeps cross-platform
            // behaviour identical.
            kSecUseDataProtectionKeychain as String: kCFBooleanTrue!,
        ]
        if let group = keychainGroup, !group.isEmpty {
            q[kSecAttrAccessGroup as String] = group
        }
        return q
    }

    // ────────────────────────────────────────────────────────────────────
    // Error helpers
    // ────────────────────────────────────────────────────────────────────

    private func checkStatus(_ status: OSStatus) throws {
        if status == errSecSuccess { return }
        let msg = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        throw NSError(domain: "SyncingKeys.Keychain", code: Int(status),
                      userInfo: [NSLocalizedDescriptionKey: msg])
    }

    private func argError(_ method: String) -> FlutterError {
        FlutterError(code: "BAD_ARGS",
                     message: "Bad arguments for \(method)",
                     details: nil)
    }

    private func flutterError(_ method: String, _ error: Error) -> FlutterError {
        FlutterError(code: "SYNCINGKEYS_\(method.uppercased())",
                     message: error.localizedDescription,
                     details: "\(error)")
    }
}
