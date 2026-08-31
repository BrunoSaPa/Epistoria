import Foundation

enum AccountStorageScope: String, Codable, Equatable {
    case accountScoped
    case legacyShared
}

struct AccountConfiguration: Codable, Equatable {
    static let currentSchemaGeneration = 2

    var accountId: UUID
    var deviceId: UUID
    var apiURL: URL?
    var serverConnected: Bool
    var storageScope: AccountStorageScope?
    var notebookGenerationId: UUID
    var schemaGeneration: Int

    init(
        accountId: UUID,
        deviceId: UUID,
        apiURL: URL?,
        serverConnected: Bool,
        storageScope: AccountStorageScope? = nil,
        notebookGenerationId: UUID? = nil,
        schemaGeneration: Int = AccountConfiguration.currentSchemaGeneration
    ) {
        self.accountId = accountId
        self.deviceId = deviceId
        self.apiURL = apiURL
        self.serverConnected = serverConnected
        self.storageScope = storageScope
        self.notebookGenerationId = notebookGenerationId ?? accountId
        self.schemaGeneration = schemaGeneration
    }

    private enum CodingKeys: String, CodingKey {
        case accountId
        case deviceId
        case apiURL
        case serverConnected
        case storageScope
        case notebookGenerationId
        case schemaGeneration
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        accountId = try values.decode(UUID.self, forKey: .accountId)
        deviceId = try values.decode(UUID.self, forKey: .deviceId)
        apiURL = try values.decodeIfPresent(URL.self, forKey: .apiURL)
        serverConnected = try values.decode(Bool.self, forKey: .serverConnected)
        storageScope = try values.decodeIfPresent(AccountStorageScope.self, forKey: .storageScope)
        notebookGenerationId = try values.decodeIfPresent(
            UUID.self,
            forKey: .notebookGenerationId
        ) ?? accountId
        schemaGeneration = try values.decodeIfPresent(Int.self, forKey: .schemaGeneration) ?? 1
    }
}

#if DEBUG
struct DevelopmentResetReceipt: Codable, Equatable {
    var archiveFormat: String
    var archiveSHA256: String
    var priorAccountId: UUID?
    var nextNotebookGenerationId: UUID
    var resetAt: Date
}
#endif

enum AccountStoragePurpose {
    case accountScoped
    case legacyShared
    case existingWithLegacyFallback
}

struct AccountStorageLocation: Equatable {
    let directoryURL: URL

    var databaseURL: URL {
        directoryURL.appendingPathComponent("epistoria.sqlite")
    }

    var assetsDirectoryURL: URL {
        directoryURL.appendingPathComponent("Assets", isDirectory: true)
    }
}

struct AccountStorageLocator {
    let applicationSupportURL: URL
    var fileManager: FileManager = .default

    func location(
        for accountId: UUID,
        purpose: AccountStoragePurpose
    ) -> AccountStorageLocation {
        let accountDirectory = applicationSupportURL
            .appendingPathComponent("Accounts", isDirectory: true)
            .appendingPathComponent(accountId.uuidString.lowercased(), isDirectory: true)
        let accountLocation = AccountStorageLocation(directoryURL: accountDirectory)

        // An account-scoped notebook must never open the former shared path. An explicit legacy
        // scope keeps an older notebook there. Unmarked configurations from earlier builds keep
        // the account-scoped-first fallback so this fix does not require a risky file migration.
        if purpose == .accountScoped {
            return accountLocation
        }

        let legacyLocation = AccountStorageLocation(directoryURL: applicationSupportURL)
        if purpose == .legacyShared,
           fileManager.fileExists(atPath: legacyLocation.databaseURL.path)
        {
            return legacyLocation
        }
        if fileManager.fileExists(atPath: accountLocation.databaseURL.path) {
            return accountLocation
        }
        if fileManager.fileExists(atPath: legacyLocation.databaseURL.path) {
            return legacyLocation
        }
        return accountLocation
    }

    var hasLegacyDatabase: Bool {
        fileManager.fileExists(
            atPath: AccountStorageLocation(directoryURL: applicationSupportURL).databaseURL.path
        )
    }
}

@MainActor
final class AccountConfigurationStore {
    enum StoreError: Error, LocalizedError, Equatable {
        case invalidStoredConfiguration

        var errorDescription: String? {
            "Epistoria found notebook settings it could not read. Existing notebook data was not changed. Reinstalling or clearing app data can make recovery harder."
        }
    }

    private let key = "epistoria.account-configuration.v1"
    #if DEBUG
    private let resetReceiptKey = "epistoria.development-reset-receipt.v1"
    #endif
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AccountConfiguration? {
        try? loadValidated()
    }

    func loadValidated() throws -> AccountConfiguration? {
        guard defaults.object(forKey: key) != nil else { return nil }
        guard let data = defaults.data(forKey: key),
              let configuration = try? JSONDecoder().decode(AccountConfiguration.self, from: data)
        else { throw StoreError.invalidStoredConfiguration }
        return configuration
    }

    var containsStoredConfiguration: Bool {
        defaults.object(forKey: key) != nil
    }

    func validateForMutation() throws {
        _ = try loadValidated()
    }

    func save(_ configuration: AccountConfiguration) throws {
        defaults.set(try JSONEncoder().encode(configuration), forKey: key)
    }

    #if DEBUG
    func clearForDevelopment() {
        defaults.removeObject(forKey: key)
    }

    func recordDevelopmentReset(_ receipt: DevelopmentResetReceipt) {
        guard let data = try? JSONEncoder().encode(receipt) else { return }
        defaults.set(data, forKey: resetReceiptKey)
    }

    var developmentResetReceipt: DevelopmentResetReceipt? {
        guard let data = defaults.data(forKey: resetReceiptKey) else { return nil }
        return try? JSONDecoder().decode(DevelopmentResetReceipt.self, from: data)
    }

    var pendingNotebookGenerationId: UUID? {
        developmentResetReceipt?.nextNotebookGenerationId
    }
    #endif
}

#if DEBUG
struct DevelopmentNotebookStorageResetter {
    let applicationSupportURL: URL
    var fileManager: FileManager = .default

    func removeConfiguredStorage(
        accountId: UUID,
        purpose: AccountStoragePurpose
    ) throws {
        let location = AccountStorageLocator(
            applicationSupportURL: applicationSupportURL,
            fileManager: fileManager
        ).location(for: accountId, purpose: purpose)
        if location.directoryURL.standardizedFileURL
            == applicationSupportURL.standardizedFileURL
        {
            try removeLegacyStorage()
            return
        }

        let expectedDirectory = applicationSupportURL
            .appendingPathComponent("Accounts", isDirectory: true)
            .appendingPathComponent(accountId.uuidString.lowercased(), isDirectory: true)
        guard location.directoryURL.standardizedFileURL == expectedDirectory.standardizedFileURL
        else { throw CocoaError(.fileWriteInvalidFileName) }
        if fileManager.fileExists(atPath: expectedDirectory.path) {
            try fileManager.removeItem(at: expectedDirectory)
        }
    }

    func removeLegacyStorage() throws {
        let location = AccountStorageLocation(directoryURL: applicationSupportURL)
        let exactTargets = [
            location.databaseURL,
            URL(fileURLWithPath: location.databaseURL.path + "-wal"),
            URL(fileURLWithPath: location.databaseURL.path + "-shm"),
            URL(fileURLWithPath: location.databaseURL.path + "-journal"),
            location.assetsDirectoryURL,
        ]
        for target in exactTargets where fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
    }

    var hasLegacyStorage: Bool {
        AccountStorageLocator(
            applicationSupportURL: applicationSupportURL,
            fileManager: fileManager
        ).hasLegacyDatabase
    }
}
#endif
