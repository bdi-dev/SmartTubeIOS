import Foundation
@testable import SmartTubeIOSCore

// Test double for the Keychain seam. The unsigned simulator test host has no keychain
// entitlement (SecItem* returns errSecMissingEntitlement), so token persistence tests
// inject this instead of the system Keychain.
final class InMemoryKeychainStore: KeychainStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]

    func get(service: String, key: String) -> String? {
        lock.withLock { items[Self.id(service, key)] }
    }

    func set(service: String, key: String, value: String?) {
        lock.withLock {
            if let value {
                items[Self.id(service, key)] = value
            } else {
                items[Self.id(service, key)] = nil
            }
        }
    }

    func delete(service: String, key: String) {
        lock.withLock { items[Self.id(service, key)] = nil }
    }

    private static func id(_ service: String, _ key: String) -> String { "\(service)|\(key)" }
}
