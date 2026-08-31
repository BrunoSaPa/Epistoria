@testable import Epistoria
import EpistoriaCore
import XCTest

@MainActor
final class AccountStorageLocatorTests: XCTestCase {
    func testNewAccountDoesNotReuseLegacyEncryptedDatabase() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let legacyDatabaseURL = root.appendingPathComponent("epistoria.sqlite")
        let legacyKey = Data(repeating: 7, count: 32)
        _ = try SQLCipherDatabase(url: legacyDatabaseURL, key: legacyKey)
        let legacyBytes = try Data(contentsOf: legacyDatabaseURL)
        let newKey = Data(repeating: 8, count: 32)
        XCTAssertThrowsError(try SQLCipherDatabase(url: legacyDatabaseURL, key: newKey)) { error in
            XCTAssertEqual(error as? LocalDatabaseError, .keyRejected)
        }

        let accountId = UUID()
        let location = AccountStorageLocator(applicationSupportURL: root).location(
            for: accountId,
            purpose: .accountScoped
        )

        XCTAssertNotEqual(location.databaseURL, legacyDatabaseURL)
        XCTAssertEqual(location.directoryURL.lastPathComponent, accountId.uuidString.lowercased())
        XCTAssertNoThrow(try SQLCipherDatabase(url: location.databaseURL, key: newKey))
        XCTAssertEqual(try Data(contentsOf: legacyDatabaseURL), legacyBytes)
    }

    func testExistingNotebookCanOpenLegacyStorage() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyDatabaseURL = root.appendingPathComponent("epistoria.sqlite")
        _ = FileManager.default.createFile(atPath: legacyDatabaseURL.path, contents: Data())
        let locator = AccountStorageLocator(applicationSupportURL: root)

        let location = locator.location(for: UUID(), purpose: .existingWithLegacyFallback)

        XCTAssertTrue(locator.hasLegacyDatabase)
        XCTAssertEqual(location.databaseURL, legacyDatabaseURL)
        XCTAssertEqual(
            location.assetsDirectoryURL.path,
            root.appendingPathComponent("Assets").path
        )
    }

    func testAccountScopedStorageTakesPriorityForExistingNotebook() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let accountId = UUID()
        let accountDirectory = root
            .appendingPathComponent("Accounts", isDirectory: true)
            .appendingPathComponent(accountId.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: accountDirectory, withIntermediateDirectories: true)
        _ = FileManager.default.createFile(
            atPath: root.appendingPathComponent("epistoria.sqlite").path,
            contents: Data([1])
        )
        _ = FileManager.default.createFile(
            atPath: accountDirectory.appendingPathComponent("epistoria.sqlite").path,
            contents: Data([2])
        )

        let location = AccountStorageLocator(applicationSupportURL: root).location(
            for: accountId,
            purpose: .existingWithLegacyFallback
        )

        XCTAssertEqual(location.directoryURL, accountDirectory)
    }

    func testExplicitLegacyScopeDoesNotSwitchToAnAccountDirectory() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let accountId = UUID()
        let accountDirectory = accountDirectory(root: root, accountId: accountId)
        try FileManager.default.createDirectory(at: accountDirectory, withIntermediateDirectories: true)
        let legacy = root.appendingPathComponent("epistoria.sqlite")
        _ = FileManager.default.createFile(atPath: legacy.path, contents: Data([1]))
        _ = FileManager.default.createFile(
            atPath: accountDirectory.appendingPathComponent("epistoria.sqlite").path,
            contents: Data([2])
        )

        let location = AccountStorageLocator(applicationSupportURL: root).location(
            for: accountId,
            purpose: .legacyShared
        )

        XCTAssertEqual(location.databaseURL, legacy)
        XCTAssertEqual(try Data(contentsOf: location.databaseURL), Data([1]))
    }

    func testOlderConfigurationDecodesWithoutAStorageMarker() throws {
        let accountId = UUID()
        let deviceId = UUID()
        let source = """
        {
          "accountId": "\(accountId.uuidString)",
          "deviceId": "\(deviceId.uuidString)",
          "serverConnected": false
        }
        """

        let configuration = try JSONDecoder().decode(
            AccountConfiguration.self,
            from: Data(source.utf8)
        )

        XCTAssertEqual(configuration.accountId, accountId)
        XCTAssertEqual(configuration.deviceId, deviceId)
        XCTAssertNil(configuration.storageScope)
    }

    func testInvalidConfigurationFailsClosedWithoutChangingStoredBytes() {
        let suiteName = "AccountStorageLocatorTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let invalid = Data("not-json".utf8)
        defaults.set(invalid, forKey: "epistoria.account-configuration.v1")
        let store = AccountConfigurationStore(defaults: defaults)

        XCTAssertTrue(store.containsStoredConfiguration)
        XCTAssertNil(store.load())
        XCTAssertThrowsError(try store.validateForMutation()) { error in
            XCTAssertEqual(
                error as? AccountConfigurationStore.StoreError,
                .invalidStoredConfiguration
            )
        }
        XCTAssertEqual(defaults.data(forKey: "epistoria.account-configuration.v1"), invalid)
    }

    func testConfiguredNotebookPreventsCreatingASecondNotebook() throws {
        let suiteName = "AccountStorageLocatorTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configuration = makeConfiguration()
        let store = AccountConfigurationStore(defaults: defaults)
        try store.save(configuration)
        let storedBytes = defaults.data(forKey: "epistoria.account-configuration.v1")
        let model = AppModel(configurationStore: store)

        XCTAssertThrowsError(try model.prepareNewAccount()) { error in
            XCTAssertTrue(error.localizedDescription.contains("already has"))
        }
        XCTAssertEqual(store.load(), configuration)
        XCTAssertEqual(defaults.data(forKey: "epistoria.account-configuration.v1"), storedBytes)
    }

    func testUnconfiguredLegacyStorageAlsoPreventsCreatingASecondNotebook() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = FileManager.default.createFile(
            atPath: root.appendingPathComponent("epistoria.sqlite").path,
            contents: Data([1])
        )
        let suiteName = "AccountStorageLocatorTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(
            configurationStore: AccountConfigurationStore(defaults: defaults),
            applicationSupportURL: root
        )

        XCTAssertThrowsError(try model.prepareNewAccount()) { error in
            XCTAssertTrue(error.localizedDescription.contains("already has"))
        }
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent("epistoria.sqlite")),
            Data([1])
        )
    }

    #if DEBUG
    func testDevelopmentResetRemovesOnlyTheConfiguredAccountDirectory() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let targetId = UUID()
        let siblingId = UUID()
        let target = accountDirectory(root: root, accountId: targetId)
        let sibling = accountDirectory(root: root, accountId: siblingId)
        try FileManager.default.createDirectory(
            at: target.appendingPathComponent("Assets", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        _ = FileManager.default.createFile(
            atPath: target.appendingPathComponent("epistoria.sqlite").path,
            contents: Data([1])
        )
        _ = FileManager.default.createFile(
            atPath: sibling.appendingPathComponent("epistoria.sqlite").path,
            contents: Data([2])
        )
        let legacy = root.appendingPathComponent("epistoria.sqlite")
        _ = FileManager.default.createFile(atPath: legacy.path, contents: Data([3]))

        try DevelopmentNotebookStorageResetter(
            applicationSupportURL: root
        ).removeConfiguredStorage(accountId: targetId, purpose: .accountScoped)

        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
        XCTAssertEqual(try Data(contentsOf: legacy), Data([3]))
    }

    func testDevelopmentResetRetryNeverFallsBackFromMissingAccountScopeToLegacy() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("epistoria.sqlite")
        _ = FileManager.default.createFile(atPath: legacy.path, contents: Data([3]))

        try DevelopmentNotebookStorageResetter(
            applicationSupportURL: root
        ).removeConfiguredStorage(accountId: UUID(), purpose: .accountScoped)

        XCTAssertEqual(try Data(contentsOf: legacy), Data([3]))
    }

    func testDevelopmentLegacyResetPreservesUnrelatedFilesAndAccountDirectories() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("epistoria.sqlite")
        for suffix in ["", "-wal", "-shm", "-journal"] {
            _ = FileManager.default.createFile(
                atPath: database.path + suffix,
                contents: Data([1])
            )
        }
        let assets = root.appendingPathComponent("Assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let sibling = accountDirectory(root: root, accountId: UUID())
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let keep = root.appendingPathComponent("keep.txt")
        _ = FileManager.default.createFile(atPath: keep.path, contents: Data([9]))

        try DevelopmentNotebookStorageResetter(
            applicationSupportURL: root
        ).removeLegacyStorage()

        for suffix in ["", "-wal", "-shm", "-journal"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: database.path + suffix))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: assets.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
        XCTAssertEqual(try Data(contentsOf: keep), Data([9]))
    }

    func testDevelopmentConfigurationClearRemovesOnlyEpistoriaSetupValue() throws {
        let suiteName = "AccountStorageLocatorTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AccountConfigurationStore(defaults: defaults)
        try store.save(makeConfiguration())
        defaults.set("keep", forKey: "unrelated")

        store.clearForDevelopment()

        XCTAssertFalse(store.containsStoredConfiguration)
        XCTAssertEqual(defaults.string(forKey: "unrelated"), "keep")
    }

    func testDevelopmentResetAcceptsCurrentReadableArchiveAndClearsConfiguration() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "AccountStorageLocatorTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configuration = makeConfiguration()
        let configurationStore = AccountConfigurationStore(defaults: defaults)
        try configurationStore.save(configuration)
        let target = accountDirectory(root: root, accountId: configuration.accountId)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        _ = FileManager.default.createFile(
            atPath: target.appendingPathComponent("epistoria.sqlite").path,
            contents: Data([1])
        )
        let suffix = UUID().uuidString.lowercased()
        let model = AppModel(
            configurationStore: configurationStore,
            accountKeyStore: KeychainStore(service: "com.epistoria.tests.reset-key.\(suffix)"),
            tokenStore: DeviceTokenStore(service: "com.epistoria.tests.reset-token.\(suffix)"),
            applicationSupportURL: root
        )

        try await model.deleteLocalDevelopmentNotebook(
            verifiedArchive: PortableArchiveInspection(
                formatVersion: "epistoria-export/8",
                sha256: String(repeating: "a", count: 64),
                byteCount: 1
            )
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertFalse(configurationStore.containsStoredConfiguration)
        guard case .onboarding = model.phase else {
            return XCTFail("Reset did not return to onboarding")
        }
        XCTAssertEqual(
            configurationStore.developmentResetReceipt?.archiveFormat,
            "epistoria-export/8"
        )
    }
    #endif

    func testDatabaseErrorsHaveUserReadableDescriptions() {
        XCTAssertEqual(
            LocalDatabaseError.keyRejected.localizedDescription,
            "The available key could not unlock this notebook. It may belong to another account or be damaged. No local data was changed."
        )
        XCTAssertFalse(LocalDatabaseError.queryFailed("internal").localizedDescription.contains("error 1"))
    }

    func testLegacyConfigurationDecodesAsGenerationOne() throws {
        let accountId = UUID()
        let deviceId = UUID()
        let data = try JSONSerialization.data(withJSONObject: [
            "accountId": accountId.uuidString,
            "deviceId": deviceId.uuidString,
            "serverConnected": false,
            "storageScope": "accountScoped",
        ])

        let decoded = try JSONDecoder().decode(AccountConfiguration.self, from: data)
        XCTAssertEqual(decoded.accountId, accountId)
        XCTAssertEqual(decoded.notebookGenerationId, accountId)
        XCTAssertEqual(decoded.schemaGeneration, 1)
    }

    #if DEBUG
    func testDevelopmentResetReceiptPreservesOnlyArchiveProofAndNextGeneration() throws {
        let suiteName = "AccountStorageLocatorTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AccountConfigurationStore(defaults: defaults)
        let receipt = DevelopmentResetReceipt(
            archiveFormat: "epistoria-export/7",
            archiveSHA256: String(repeating: "a", count: 64),
            priorAccountId: UUID(),
            nextNotebookGenerationId: UUID(),
            resetAt: .now
        )

        store.recordDevelopmentReset(receipt)

        XCTAssertEqual(store.developmentResetReceipt, receipt)
        XCTAssertEqual(store.pendingNotebookGenerationId, receipt.nextNotebookGenerationId)
    }
    #endif

    private func makeConfiguration() -> AccountConfiguration {
        AccountConfiguration(
            accountId: UUID(),
            deviceId: UUID(),
            apiURL: nil,
            serverConnected: false,
            storageScope: .accountScoped
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AccountStorageLocatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func accountDirectory(root: URL, accountId: UUID) -> URL {
        root.appendingPathComponent("Accounts", isDirectory: true)
            .appendingPathComponent(accountId.uuidString.lowercased(), isDirectory: true)
    }
}
