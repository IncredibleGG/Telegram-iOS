import Foundation
import Security

// The Keychain half of LuminaGram's local storage - see LuminaSettings.swift for the
// SharedData half. Anything that must never sit in LuminaSettings (translation-provider
// API keys, the chat-lock code) goes through here instead, exactly as the roadmap
// (IOS-PORT-PLAN.md, App Privacy section) specifies: "User's own AI/DeepL/Google keys,
// stored in Keychain (kSecAttrAccessibleWhenUnlockedThisDeviceOnly), never in SharedData,
// never transmitted to LuminaGram."
//
// kSecAttrAccessibleWhenUnlockedThisDeviceOnly: unreadable while the device is locked,
// and excluded from iCloud Keychain sync and from encrypted device-to-device backup
// restores - the value only ever exists on the device it was set on. That matches Telegram
// itself, which never syncs these values either: they are entered by the user, once, per
// device.
//
// Modeled on the existing Keychain usage in this codebase (WebUI/Sources/WebAppSecureStorage.swift,
// LocalAuth/Sources/LocalAuth.swift) - same kSecClassGenericPassword item shape, same
// synchronous SecItemCopyMatching/SecItemAdd/SecItemUpdate/SecItemDelete calls. Unlike
// WebAppSecureStorage this has no AccountContext/engine dependency: it is a flat
// string-keyed store, safe to call from anywhere, including before an account exists.
public enum LuminaKeychain {
    private static let service = "app.luminagram.secrets"

    private static func query(for key: String) -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }

    // Passing nil or an empty string deletes the entry instead of storing an empty secret.
    @discardableResult
    public static func set(_ value: String?, forKey key: String) -> Bool {
        guard let value, !value.isEmpty else {
            return self.delete(key)
        }
        guard let data = value.data(using: .utf8) else {
            return false
        }

        let query = self.query(for: key)
        let exists = SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
        if exists {
            let updateAttributes: [String: Any] = [
                kSecValueData as String: data
            ]
            return SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary) == errSecSuccess
        } else {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }
    }

    public static func get(_ key: String) -> String? {
        var query = self.query(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func delete(_ key: String) -> Bool {
        let status = SecItemDelete(self.query(for: key) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

// Naming the keys Wave 1+ features are expected to store here. LuminaKeychain itself takes
// any String key - this enum only keeps call sites that need the same key from drifting.
public enum LuminaKeychainKey {
    // One key per provider id, so switching the active engine in LuminaSettings.translateEngine
    // never has to move or overwrite another provider's stored key.
    public static func translateProviderAPIKey(providerId: String) -> String {
        return "translateKey_\(providerId)"
    }

    // LocalAuthentication (Face ID/passcode) is the primary chat-lock gate; this is only
    // the fallback PIN, so it belongs in the Keychain, not LuminaSettings.lockedChats.
    public static let chatLockCode = "chatLockCode"
}
