#
# SyncingKeys SDK — secure Starknet/Ethereum key storage with Keychain + iCloud sync.
# Run `pod lib lint syncing_keys.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'syncing_keys'
  s.version          = '0.1.0'
  s.summary          = 'SyncingKeys SDK — secure Starknet/Ethereum key sync for Flutter.'
  s.description      = <<-DESC
A Flutter plugin that provides "set-and-forget" secure key management
for blockchain apps. Stores private keys in the iOS Keychain with optional
iCloud sync via kSecAttrSynchronizable, and a PIN-wrapped envelope so keys
never leave the device unencrypted.
                       DESC
  s.homepage         = 'https://github.com/everydayapp-xyz/syncing_keys'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'everydayapp.xyz' => 'hello@everydayapp.xyz' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'

  # iOS 13+ for modern Keychain APIs and SecKey crypto.
  s.platform = :ios, '13.0'

  # Required system frameworks — Security for Keychain CRUD, LocalAuthentication
  # for the optional biometric pre-gate on the PIN UI.
  s.frameworks = 'Security', 'LocalAuthentication'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # Ship the privacy manifest — required by App Store Connect since
  # May 2024. Our SDK declares zero tracking domains, zero accessed-API
  # types, and zero collected-data types because it only reads/writes
  # opaque encrypted blobs to the Keychain.
  s.resource_bundles = { 'syncing_keys_privacy' => ['Resources/PrivacyInfo.xcprivacy'] }
end
