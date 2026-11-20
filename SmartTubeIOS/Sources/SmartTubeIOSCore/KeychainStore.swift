import Foundation
import Security

// MARK: - KeychainStore
//
// Seam over generic-password Keychain storage. TokenManager talks to this protocol so
// tests can inject an in-memory fake: the unsigned simulator test host has no keychain
// entitlement, so SecItem* calls return errSecMissingEntitlement (-34018) there.

public protocol KeychainStore: Sendable {
    func get(service: String, key: String) -> String?
    func set(service: String, key: String, value: String?)
    func delete(service: String, key: String)
}

/// Production implementation backed by the Security framework.
public struct SystemKeychainStore: KeychainStore {
    public init() {}

    public func get(service: String, key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func set(service: String, key: String, value: String?) {
        delete(service: service, key: key)
        guard let value, let data = value.data(using: .utf8) else { return }
        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    public func delete(service: String, key: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
