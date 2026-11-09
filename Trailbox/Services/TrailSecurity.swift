import Foundation
import Security

/// Keychain is device-bound; medical details never enter the normal trip-plan event.
enum TrailSecurity {
    static func save(_ value: String, key: String) -> Bool {
        let account = "trailbox." + key
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "Trailbox",
                                    kSecAttrAccount as String: account]
        let data = Data(value.utf8)
        let update = [kSecValueData as String: data]
        if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecSuccess { return true }
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func read(_ key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "Trailbox",
                                    kSecAttrAccount as String: "trailbox." + key,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
