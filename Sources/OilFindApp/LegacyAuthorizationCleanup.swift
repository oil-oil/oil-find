import Foundation
import LocalAuthentication
import Security

enum LegacyAuthorizationCleanup {
    static let completedKey = "legacyAuthorizationCleanupCompleted"
    static let keychainService = "com.oiloil.find.trial"
    private static let exactDefaultsKeys = ["trialStartedAt", "trialLastSeenAt", "licenseAPI", "deviceFallbackID"]

    static var licenseFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Oil Find/license.json")
    }

    static func run(
        licenseFile: URL = licenseFileURL,
        defaults: UserDefaults = .standard,
        deleteKeychainItem: () -> Void = deleteLegacyTrialKeychainItem
    ) {
        guard !defaults.bool(forKey: completedKey) else { return }
        try? FileManager.default.removeItem(at: licenseFile)

        let keys = Set(defaults.dictionaryRepresentation().keys)
        let authorizationKeys = keys.filter { key in
            let normalized = key.lowercased()
            return exactDefaultsKeys.contains(key)
                || normalized.hasPrefix("trial")
                || normalized.hasPrefix("license")
        }
        authorizationKeys.forEach(defaults.removeObject(forKey:))

        deleteKeychainItem()
        defaults.set(true, forKey: completedKey)
    }

    private static func deleteLegacyTrialKeychainItem() {
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecUseAuthenticationContext as String: authenticationContext
        ]
        _ = SecItemDelete(query as CFDictionary)
    }
}
