import EpistoriaCore
import Foundation
import Network
import Security

enum AIProviderProfileState: String, Codable {
    case local = "LOCAL"
    case queued = "QUEUED"
    case ready = "READY"
    case failed = "FAILED"
    case deleting = "DELETING"
}

struct AIProviderProfile: Codable, Equatable, Identifiable {
    var id: UUID
    var configurationRevisionId: UUID?
    var displayName: String
    var adapter: AIProviderAdapter
    var baseURL: URL
    var textModel: String
    var transcriptionModel: String?
    var capabilities: [AIProviderCapability]
    var structuredOutput: Bool
    var inputUSDPerMillion: Double?
    var outputUSDPerMillion: Double?
    var transcriptionUSDPerMinute: Double?
    var isActive: Bool
    var state: AIProviderProfileState
    var pendingOperation: AIProviderConfigurationOperation?
    var lastJobId: UUID?
    var lastErrorCode: String?
    var updatedAt: Date

    var destinationHost: String { baseURL.host() ?? baseURL.absoluteString }

    var routeSnapshot: AIProviderRouteSnapshot {
        AIProviderRouteSnapshot(
            profileId: id,
            configurationRevisionId: configurationRevisionId ?? id,
            displayName: displayName,
            adapter: adapter,
            baseURL: baseURL.absoluteString,
            textModel: textModel,
            transcriptionModel: transcriptionModel,
            capabilities: capabilities,
            structuredOutput: structuredOutput
        )
    }
}

@MainActor
final class AIProviderProfileStore {
    enum StoreError: Error, LocalizedError {
        case invalidProfiles

        var errorDescription: String? {
            "Epistoria found AI provider settings it could not read. API keys were not changed."
        }
    }

    private let defaults: UserDefaults
    private let keyPrefix = "epistoria.ai-provider-profiles.v1."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(accountId: UUID) throws -> [AIProviderProfile] {
        let key = keyPrefix + accountId.uuidString.lowercased()
        guard let data = defaults.data(forKey: key) else { return [] }
        guard let profiles = try? JSONDecoder().decode([AIProviderProfile].self, from: data),
              Set(profiles.map(\.id)).count == profiles.count
        else { throw StoreError.invalidProfiles }
        return profiles.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func save(_ profiles: [AIProviderProfile], accountId: UUID) throws {
        guard Set(profiles.map(\.id)).count == profiles.count else { throw StoreError.invalidProfiles }
        let key = keyPrefix + accountId.uuidString.lowercased()
        defaults.set(try JSONEncoder().encode(profiles), forKey: key)
    }

    func delete(accountId: UUID) {
        defaults.removeObject(forKey: keyPrefix + accountId.uuidString.lowercased())
    }
}

final class AIProviderSecretStore: @unchecked Sendable {
    enum SecretError: Error, LocalizedError {
        case invalidSecret
        case status(OSStatus)

        var errorDescription: String? {
            switch self {
            case .invalidSecret: "The API key is empty or too large."
            case .status: "The iPad Keychain could not update the API key."
            }
        }
    }

    private let service: String

    init(service: String = "com.epistoria.ai-provider-key") {
        self.service = service
    }

    func save(_ secret: String, accountId: UUID, profileId: UUID) throws {
        guard let data = secret.data(using: .utf8), !data.isEmpty, data.count <= 8_192 else {
            throw SecretError.invalidSecret
        }
        let query = baseQuery(accountId: accountId, profileId: profileId)
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecretError.status(status) }
    }

    func secret(accountId: UUID, profileId: UUID) throws -> String? {
        var query = baseQuery(accountId: accountId, profileId: profileId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              data.count <= 8_192,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else {
            if status == errSecSuccess { throw SecretError.invalidSecret }
            throw SecretError.status(status)
        }
        return value
    }

    func contains(accountId: UUID, profileId: UUID) -> Bool {
        (try? secret(accountId: accountId, profileId: profileId)) != nil
    }

    func delete(accountId: UUID, profileId: UUID) throws {
        let status = SecItemDelete(baseQuery(accountId: accountId, profileId: profileId) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretError.status(status)
        }
    }

    private func baseQuery(accountId: UUID, profileId: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String:
                "\(accountId.uuidString.lowercased()):\(profileId.uuidString.lowercased())",
            kSecAttrSynchronizable as String: false,
        ]
    }
}

enum AIProviderURLPolicy {
    static func normalized(_ value: String, adapter: AIProviderAdapter) -> URL? {
        if adapter == .openAIResponses {
            return URL(string: "https://api.openai.com/v1")
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else { return nil }
        if scheme == "http", !isLocal(host: host) { return nil }
        components.scheme = scheme
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + (components.path.isEmpty ? "v1" : components.path)
        return components.url
    }

    private static func isLocal(host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") { return true }
        if let address = IPv4Address(host) {
            let bytes = [UInt8](address.rawValue)
            guard bytes.count == 4 else { return false }
            return bytes[0] == 127
                || bytes[0] == 10
                || (bytes[0] == 192 && bytes[1] == 168)
                || (bytes[0] == 172 && (16 ... 31).contains(bytes[1]))
                || (bytes[0] == 169 && bytes[1] == 254)
        }
        if let address = IPv6Address(host) {
            let bytes = [UInt8](address.rawValue)
            guard bytes.count == 16 else { return false }
            let loopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
            let uniqueLocal = bytes[0] & 0xfe == 0xfc
            let linkLocal = bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80
            return loopback || uniqueLocal || linkLocal
        }
        return false
    }
}
