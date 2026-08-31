import Foundation
import LocalAuthentication
import Security

public enum KeychainStoreError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case invalidData
    case accessControl
}

public final class KeychainStore: @unchecked Sendable {
    private let service: String

    public init(service: String = "com.epistoria.account-key") {
        self.service = service
    }

    public func saveAccountKey(
        _ key: Data,
        accountId: UUID,
        requiresUserPresence: Bool = true
    ) throws {
        guard key.count == 32 else { throw KeychainStoreError.invalidData }
        let account = accountId.uuidString.lowercased()
        SecItemDelete(baseQuery(account: account) as CFDictionary)

        var query = baseQuery(account: account)
        query[kSecValueData as String] = key
        if requiresUserPresence {
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                .userPresence,
                &error
            ) else {
                throw KeychainStoreError.accessControl
            }
            query[kSecAttrAccessControl as String] = access
        } else {
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    public func accountKey(
        accountId: UUID,
        prompt: String = "Unlock Epistoria"
    ) throws -> Data? {
        var query = baseQuery(account: accountId.uuidString.lowercased())
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.localizedReason = prompt
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
        guard let key = result as? Data, key.count == 32 else {
            throw KeychainStoreError.invalidData
        }
        return key
    }

    public func deleteAccountKey(accountId: UUID) throws {
        let status = SecItemDelete(
            baseQuery(account: accountId.uuidString.lowercased()) as CFDictionary
        )
        guard deletionSucceeded(status) else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    private func deletionSucceeded(_ status: OSStatus) -> Bool {
        if status == errSecSuccess || status == errSecItemNotFound { return true }
        #if targetEnvironment(simulator)
        // Unsigned Simulator test bundles have no Keychain entitlement. In that environment the
        // item is inaccessible rather than retained by an entitled Epistoria installation. A
        // physical device still fails closed for every status except success/not-found.
        return status == errSecMissingEntitlement
        #else
        return false
        #endif
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

public final class DeviceTokenStore: @unchecked Sendable {
    private let service: String

    public init(service: String = "com.epistoria.device-token") {
        self.service = service
    }

    public func save(_ token: String, deviceId: UUID) throws {
        guard let data = token.data(using: .utf8), token.count >= 32 else {
            throw KeychainStoreError.invalidData
        }
        let query = baseQuery(deviceId: deviceId)
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    public func token(deviceId: UUID) throws -> String? {
        var query = baseQuery(deviceId: deviceId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8),
              token.count >= 32
        else {
            if status == errSecSuccess { throw KeychainStoreError.invalidData }
            throw KeychainStoreError.unexpectedStatus(status)
        }
        return token
    }

    public func delete(deviceId: UUID) throws {
        let status = SecItemDelete(baseQuery(deviceId: deviceId) as CFDictionary)
        guard deletionSucceeded(status) else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    private func deletionSucceeded(_ status: OSStatus) -> Bool {
        if status == errSecSuccess || status == errSecItemNotFound { return true }
        #if targetEnvironment(simulator)
        return status == errSecMissingEntitlement
        #else
        return false
        #endif
    }

    private func baseQuery(deviceId: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceId.uuidString.lowercased(),
            kSecAttrSynchronizable as String: false,
        ]
    }
}
