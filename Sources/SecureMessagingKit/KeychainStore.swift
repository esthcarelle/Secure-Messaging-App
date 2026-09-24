import Foundation
import Security

public enum KeychainError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case encoding
}

public final class KeychainStore: @unchecked Sendable {
    private let service: String
    private let lock = NSLock()

    public init(service: String = "com.securemessaging.keystore") {
        self.service = service
    }

    public func set(_ data: Data, account: String) throws {
        try lock.sync {
            let query = baseQuery(account: account)
            SecItemDelete(query as CFDictionary)
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let status = SecItemAdd(insert as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        }
    }

    public func data(account: String) throws -> Data? {
        try lock.sync {
            var query = baseQuery(account: account)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
            return item as? Data
        }
    }

    public func delete(account: String) throws {
        try lock.sync {
            let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError.unexpectedStatus(status)
            }
        }
    }

    public func setString(_ value: String, account: String) throws {
        guard let data = value.data(using: .utf8) else { throw KeychainError.encoding }
        try set(data, account: account)
    }

    public func string(account: String) throws -> String? {
        guard let data = try data(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Creates a 256-bit database key on first launch and keeps it in the Keychain.
    public func databaseKey(account: String = "db.encryption.key") throws -> Data {
        if let existing = try data(account: account) {
            guard existing.count == 32 else { throw KeychainError.encoding }
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        let key = Data(bytes)
        try set(key, account: account)
        return key
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

private extension NSLock {
    func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
