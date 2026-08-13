import EpistoriaCore
import Foundation
import Network
import Observation

private enum AppModelOperationError: Error, LocalizedError {
    case accountSetupRollbackFailed
    case serverIdentityMismatch
    case serverConnectionRollbackFailed
    case unlockedSessionUnavailable

    var errorDescription: String? {
        switch self {
        case .accountSetupRollbackFailed:
            "Epistoria could not safely roll back account setup. Restart the app before trying again."
        case .serverIdentityMismatch:
            "The server returned credentials for a different account or device. No credentials were saved."
        case .serverConnectionRollbackFailed:
            "Epistoria could not safely restore the previous server credentials. Reconnect with the bootstrap secret."
        case .unlockedSessionUnavailable:
            "The unlocked notebook changed while this operation was running. Please try again."
        }
    }
}

struct NewAccountMaterial: Identifiable {
    let id = UUID()
    let accountId: UUID
    let deviceId: UUID
    let accountKey: Data
    let recoveryWords: String
}

struct MacPairingMaterial: Identifiable {
    let id = UUID()
    let accountId: UUID
    let deviceId: UUID
    let deviceToken: String
}

@MainActor
@Observable
final class AppModel {
    enum Phase {
        case loading
        case onboarding
        case ready
        case failed(String)
    }

    var phase: Phase = .loading
    var selectedSection: AppSection? = .today
    var lastSyncReport: SyncReport?
    var lastSuccessfulSyncAt: Date?
    var syncError: String?
    var isSyncing = false
    var pendingRecordCount = 0
    var pendingFileCount = 0
    var unresolvedConflictCount = 0
    private(set) var isCreatingPortableExport = false
    var configuration: AccountConfiguration?
    let pendingSaves = PendingSaveRegistry()

    private(set) var database: SQLCipherDatabase?
    private(set) var store: EpistoriaStore?
    private(set) var assetManager: AssetManager?
    private(set) var api: EpistoriaAPIClient?
    private(set) var syncEngine: SyncEngine?
    private(set) var aiJobs: AIJobCoordinator?

    private var accountKey: Data?
    private let configurationStore = AccountConfigurationStore()
    private let accountKeyStore = KeychainStore()
    private let tokenStore = DeviceTokenStore()
    private let crypto = EntityCrypto()
    private var isOpening = false
    private var automaticSyncTask: Task<Void, Never>?
    private var automaticSyncToken: UUID?
    private var periodicSyncTask: Task<Void, Never>?
    private var syncAttemptTask: Task<SyncReport, Error>?
    private var exportTask: Task<EpistoriaExportResult, Error>?
    private var syncRequestedWhileRunning = false
    private var pathMonitor: NWPathMonitor?
    private var isLocking = false
    private var restartRequested = false
    private var sessionGeneration: UInt64 = 0
    private var isReconfiguringSync = false
    private var pendingSaveWarning: String?

    func start() async {
        if isOpening || isLocking {
            restartRequested = true
            return
        }
        guard case .loading = phase else { return }
        isOpening = true
        let generation = sessionGeneration
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-reset-onboarding") {
            // UI tests force the presentation state only. No Keychain, configuration, or
            // encrypted database content is deleted.
            phase = .onboarding
            isOpening = false
            restartRequested = false
            return
        }
        #endif
        guard let configuration = configurationStore.load() else {
            phase = .onboarding
            isOpening = false
            restartRequested = false
            return
        }
        do {
            guard let key = try accountKeyStore.accountKey(accountId: configuration.accountId) else {
                phase = .failed("The account key is missing. Restore it with your 24 recovery words.")
                isOpening = false
                restartRequested = false
                return
            }
            try await open(configuration: configuration, key: key, generation: generation)
            await beginReadyWork()
        } catch {
            if generation == sessionGeneration, !isLocking, !(error is CancellationError) {
                phase = .failed("Epistoria could not unlock its encrypted data: \(error.localizedDescription)")
            }
        }
        isOpening = false
        await honorDeferredRestartIfNeeded()
    }

    func lock() async {
        await tearDown(nextPhase: .loading, honorDeferredRestart: true)
    }

    private func tearDown(nextPhase: Phase, honorDeferredRestart: Bool) async {
        guard !isLocking else { return }
        isLocking = true
        sessionGeneration &+= 1
        phase = .loading
        automaticSyncTask?.cancel()
        automaticSyncTask = nil
        automaticSyncToken = nil
        periodicSyncTask?.cancel()
        periodicSyncTask = nil
        pathMonitor?.pathUpdateHandler = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        syncRequestedWhileRunning = false

        let attempt = syncAttemptTask
        attempt?.cancel()
        if let attempt {
            _ = await attempt.result
        }
        syncAttemptTask = nil
        isSyncing = false

        let activeExport = exportTask
        activeExport?.cancel()
        if let activeExport {
            _ = await activeExport.result
        }
        exportTask = nil
        isCreatingPortableExport = false
        isReconfiguringSync = false

        // Give disappearing editors a main-actor turn to stage their last snapshot, then
        // drain again after the checkpoint in case a save was staged while it was running.
        await Task.yield()
        do {
            try await pendingSaves.flushAll()
        } catch {
            pendingSaveWarning = "A recent edit is still waiting for a safe local write. Epistoria will retry after unlock."
        }
        try? await database?.checkpoint()
        do {
            try await pendingSaves.flushAll()
        } catch {
            pendingSaveWarning = "A recent edit is still waiting for a safe local write. Epistoria will retry after unlock."
        }

        aiJobs = nil
        syncEngine = nil
        api = nil
        assetManager = nil
        store = nil
        database = nil
        accountKey = nil
        lastSyncReport = nil
        syncError = nil
        pendingRecordCount = 0
        pendingFileCount = 0
        unresolvedConflictCount = 0
        try? EpistoriaExportService.removeAllTemporaryExports()
        configuration = configurationStore.load()
        phase = nextPhase
        isLocking = false

        if honorDeferredRestart {
            await honorDeferredRestartIfNeeded()
        } else {
            restartRequested = false
        }
    }

    func prepareNewAccount() throws -> NewAccountMaterial {
        let key = try crypto.randomKey()
        return NewAccountMaterial(
            accountId: UUID(),
            deviceId: UUID(),
            accountKey: key,
            recoveryWords: try RecoveryKit.words(for: key)
        )
    }

    func confirmNewAccount(_ material: NewAccountMaterial) async throws {
        guard !isOpening, !isLocking else { throw AppModelOperationError.unlockedSessionUnavailable }
        isOpening = true
        let generation = sessionGeneration
        let configuration = AccountConfiguration(
            accountId: material.accountId,
            deviceId: material.deviceId,
            apiURL: nil,
            serverConnected: false
        )
        do {
            try accountKeyStore.saveAccountKey(
                material.accountKey,
                accountId: material.accountId,
                requiresUserPresence: true
            )
            try await open(
                configuration: configuration,
                key: material.accountKey,
                generation: generation
            )
            try configurationStore.save(configuration)
        } catch {
            let originalError = error
            await tearDown(nextPhase: .onboarding, honorDeferredRestart: false)
            do {
                try accountKeyStore.deleteAccountKey(accountId: material.accountId)
            } catch {
                isOpening = false
                throw AppModelOperationError.accountSetupRollbackFailed
            }
            isOpening = false
            throw originalError
        }
        await beginReadyWork()
        isOpening = false
        await honorDeferredRestartIfNeeded()
    }

    func restoreLocalAccount(accountId: UUID, words: String) async throws {
        let key = try RecoveryKit.accountKey(from: words)
        guard !isOpening, !isLocking else { throw AppModelOperationError.unlockedSessionUnavailable }
        isOpening = true
        let generation = sessionGeneration
        let configuration = AccountConfiguration(
            accountId: accountId,
            deviceId: UUID(),
            apiURL: nil,
            serverConnected: false
        )
        do {
            try await open(configuration: configuration, key: key, generation: generation)
            try accountKeyStore.saveAccountKey(key, accountId: accountId, requiresUserPresence: true)
            try configurationStore.save(configuration)
        } catch {
            let originalError = error
            await tearDown(nextPhase: .onboarding, honorDeferredRestart: false)
            // Recovery may be repairing an existing account. Never delete a Keychain item
            // here: a failed database open happens before this attempt writes any key, and
            // removing it could destroy the previously valid local unlock path.
            isOpening = false
            throw originalError
        }
        await beginReadyWork()
        isOpening = false
        await honorDeferredRestartIfNeeded()
    }

    /// Returns to the recovery-safe onboarding surface without deleting the encrypted store.
    func beginRecovery() {
        phase = .loading
        Task { [weak self] in
            await self?.tearDown(nextPhase: .onboarding, honorDeferredRestart: false)
        }
    }

    func connectServer(apiURL: URL, bootstrapSecret: String) async throws {
        guard var configuration,
              let accountKey,
              let database,
              let store,
              let assetManager,
              !isLocking,
              case .ready = phase
        else { throw AppModelOperationError.unlockedSessionUnavailable }
        let generation = sessionGeneration
        let previousToken = try tokenStore.token(deviceId: configuration.deviceId)
        let client = EpistoriaAPIClient(baseURL: apiURL)
        let credentials = try await client.bootstrap(
            ownerId: configuration.accountId,
            deviceId: configuration.deviceId,
            bootstrapSecret: bootstrapSecret
        )
        guard generation == sessionGeneration, !isLocking, case .ready = phase else {
            throw CancellationError()
        }
        guard credentials.ownerId == configuration.accountId,
              credentials.deviceId == configuration.deviceId
        else { throw AppModelOperationError.serverIdentityMismatch }

        isReconfiguringSync = true
        defer {
            isReconfiguringSync = false
            resumeSyncSchedulingIfNeeded()
        }
        await quiesceSyncForReconfiguration()
        guard generation == sessionGeneration, !isLocking, case .ready = phase else {
            throw CancellationError()
        }

        let nextSyncEngine = SyncEngine(
            accountId: configuration.accountId,
            accountKey: accountKey,
            database: database,
            api: client
        )
        let nextAIJobs = AIJobCoordinator(
            accountId: configuration.accountId,
            accountKey: accountKey,
            store: store,
            api: client
        )
        configuration.deviceId = credentials.deviceId
        configuration.apiURL = apiURL
        configuration.serverConnected = true
        do {
            try tokenStore.save(credentials.token, deviceId: credentials.deviceId)
            try configurationStore.save(configuration)
        } catch {
            let originalError = error
            do {
                if let previousToken {
                    try tokenStore.save(previousToken, deviceId: credentials.deviceId)
                } else {
                    try tokenStore.delete(deviceId: credentials.deviceId)
                }
            } catch {
                throw AppModelOperationError.serverConnectionRollbackFailed
            }
            throw originalError
        }

        self.configuration = configuration
        await assetManager.setAPIClient(client)
        api = client
        syncEngine = nextSyncEngine
        aiJobs = nextAIJobs
        syncError = nil
        await refreshDataHealth()
    }

    func synchronize() async {
        await synchronize(reportMissingServer: true)
    }

    func createPortableExport(includingDerivedAI: Bool) async throws -> EpistoriaExportResult {
        guard !isCreatingPortableExport,
              !isReconfiguringSync,
              !isLocking,
              case .ready = phase,
              let configuration,
              let store,
              let database,
              let assetManager
        else { throw AppModelOperationError.unlockedSessionUnavailable }
        isCreatingPortableExport = true
        let generation = sessionGeneration
        defer {
            if generation == sessionGeneration {
                exportTask = nil
                isCreatingPortableExport = false
                resumeSyncSchedulingIfNeeded()
            }
        }
        automaticSyncTask?.cancel()
        automaticSyncTask = nil
        automaticSyncToken = nil
        syncRequestedWhileRunning = false
        if let syncAttemptTask {
            _ = await syncAttemptTask.result
        }
        guard generation == sessionGeneration, !isLocking, case .ready = phase else {
            isCreatingPortableExport = false
            throw CancellationError()
        }
        try await pendingSaves.flushAll()

        let service = EpistoriaExportService(
            accountId: configuration.accountId,
            store: store,
            database: database,
            assetManager: assetManager
        )
        let task = Task {
            try await service.exportDecrypted(includingDerivedAI: includingDerivedAI)
        }
        exportTask = task
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Records a completed local transaction and schedules network work independently.
    /// Local saving never waits for synchronization.
    func noteLocalMutation() {
        guard !isLocking, case .ready = phase else { return }
        Task { await refreshDataHealth() }
        scheduleAutomaticSync()
    }

    func refreshDataHealth() async {
        guard let database else {
            pendingRecordCount = 0
            pendingFileCount = 0
            unresolvedConflictCount = 0
            return
        }
        let generation = sessionGeneration
        do {
            let snapshot = try await database.dataHealth()
            guard generation == sessionGeneration, !isLocking, case .ready = phase else { return }
            pendingRecordCount = snapshot.pendingMutations
            pendingFileCount = snapshot.pendingAssets
            unresolvedConflictCount = snapshot.unresolvedConflicts
        } catch {
            // Health reporting must never interrupt editing. Manual sync exposes actual
            // database and transport failures through the normal sync error.
        }
    }

    var syncStatusText: String {
        if isSyncing { return "Syncing securely…" }
        if let syncError { return syncError }
        let pending = pendingRecordCount + pendingFileCount
        if pending > 0 {
            return "Saved on this iPad · \(pending) waiting to sync"
        }
        guard configuration?.serverConnected == true else {
            return "Saved on this iPad · sync is optional"
        }
        if let lastSuccessfulSyncAt {
            return "Synced \(lastSuccessfulSyncAt.formatted(.relative(presentation: .named)))"
        }
        return "Saved on this iPad · ready to sync"
    }

    var syncStatusSymbol: String {
        if isSyncing { return "arrow.triangle.2.circlepath" }
        if syncError != nil { return "exclamationmark.triangle.fill" }
        if pendingRecordCount + pendingFileCount > 0 { return "checkmark.circle" }
        if configuration?.serverConnected == true { return "checkmark.icloud" }
        return "checkmark.shield"
    }

    private func synchronize(reportMissingServer: Bool) async {
        guard !isCreatingPortableExport, !isReconfiguringSync else { return }
        guard !isLocking, case .ready = phase, let syncEngine else {
            if reportMissingServer {
                syncError = "Connect a private sync server in Data Health first."
            }
            return
        }
        if isSyncing {
            syncRequestedWhileRunning = true
            return
        }
        isSyncing = true
        let generation = sessionGeneration
        repeat {
            syncRequestedWhileRunning = false
            let attempt = Task { try await syncEngine.synchronize() }
            syncAttemptTask = attempt
            do {
                let report = try await withTaskCancellationHandler {
                    try await attempt.value
                } onCancel: {
                    attempt.cancel()
                }
                syncAttemptTask = nil
                guard generation == sessionGeneration, !isLocking, case .ready = phase else {
                    break
                }
                lastSyncReport = report
                lastSuccessfulSyncAt = .now
                syncError = nil
            } catch is CancellationError {
                syncAttemptTask = nil
                break
            } catch {
                syncAttemptTask = nil
                guard generation == sessionGeneration,
                      !isLocking,
                      !Task.isCancelled,
                      case .ready = phase
                else { break }
                syncError = "Sync paused; your local work is safe. \(error.localizedDescription)"
            }
        } while syncRequestedWhileRunning
            && !Task.isCancelled
            && generation == sessionGeneration
            && !isLocking

        guard generation == sessionGeneration, !isLocking, case .ready = phase else { return }
        isSyncing = false
        await refreshDataHealth()
    }

    private func scheduleAutomaticSync(delay: Duration = .seconds(1.5)) {
        guard syncEngine != nil, !isCreatingPortableExport, !isReconfiguringSync else { return }
        automaticSyncTask?.cancel()
        let token = UUID()
        automaticSyncToken = token
        automaticSyncTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) }
            catch { return }
            guard !Task.isCancelled, let self else { return }
            await self.runAutomaticSync(token: token)
        }
    }

    private func runAutomaticSync(token: UUID) async {
        guard automaticSyncToken == token, !Task.isCancelled else { return }
        automaticSyncTask = nil
        automaticSyncToken = nil
        await synchronize(reportMissingServer: false)
    }

    private func beginReadyWork() async {
        let generation = sessionGeneration
        do {
            try await pendingSaves.flushAll()
            pendingSaveWarning = nil
        } catch {
            pendingSaveWarning = "A recent edit is still waiting for a safe local write. Free storage if needed; Epistoria will keep retrying."
        }
        await refreshDataHealth()
        guard generation == sessionGeneration, !isLocking, case .ready = phase else { return }
        if let pendingSaveWarning { syncError = pendingSaveWarning }
        resumeSyncSchedulingIfNeeded()
    }

    private func startPeriodicSync() {
        periodicSyncTask?.cancel()
        periodicSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(300)) }
                catch { return }
                guard !Task.isCancelled, let self else { return }
                await self.synchronize(reportMissingServer: false)
            }
        }
    }

    private func quiesceSyncForReconfiguration() async {
        automaticSyncTask?.cancel()
        automaticSyncTask = nil
        automaticSyncToken = nil
        periodicSyncTask?.cancel()
        periodicSyncTask = nil
        pathMonitor?.pathUpdateHandler = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        syncRequestedWhileRunning = false
        let attempt = syncAttemptTask
        attempt?.cancel()
        if let attempt { _ = await attempt.result }
        syncAttemptTask = nil
        isSyncing = false
    }

    private func resumeSyncSchedulingIfNeeded() {
        guard !isLocking,
              !isCreatingPortableExport,
              !isReconfiguringSync,
              case .ready = phase
        else { return }
        scheduleAutomaticSync(delay: .zero)
        startPathMonitorIfNeeded()
        startPeriodicSync()
    }

    func recoveryWords() throws -> String {
        guard let configuration,
              let verifiedKey = try accountKeyStore.accountKey(
                  accountId: configuration.accountId,
                  prompt: "Reveal your Epistoria recovery kit"
              )
        else { throw RecoveryKitError.invalidKey }
        return try RecoveryKit.words(for: verifiedKey)
    }

    func enrollMac() async throws -> MacPairingMaterial {
        guard let api, let configuration else { throw APIClientError.unauthorized }
        let generation = sessionGeneration
        let macId = UUID()
        let credentials = try await api.enrollDevice(id: macId, kind: "MAC")
        guard generation == sessionGeneration,
              !isLocking,
              credentials.ownerId == configuration.accountId,
              credentials.deviceId == macId
        else { throw CancellationError() }
        return MacPairingMaterial(
            accountId: configuration.accountId,
            deviceId: credentials.deviceId,
            deviceToken: credentials.token
        )
    }

    func trustedDevices() async throws -> [DeviceSummary] {
        guard let api else { throw APIClientError.unauthorized }
        let generation = sessionGeneration
        let devices = try await api.listDevices()
        guard generation == sessionGeneration, !isLocking else { throw CancellationError() }
        return devices
    }

    func revokeTrustedDevice(id: UUID) async throws {
        guard let api, id != configuration?.deviceId else {
            throw APIClientError.unauthorized
        }
        let generation = sessionGeneration
        try await api.revokeDevice(id: id)
        guard generation == sessionGeneration, !isLocking else { throw CancellationError() }
    }

    private func open(
        configuration: AccountConfiguration,
        key: Data,
        generation: UInt64
    ) async throws {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Epistoria", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let database = try SQLCipherDatabase(
            url: support.appendingPathComponent("epistoria.sqlite"),
            key: try crypto.localDatabaseKey(
                accountKey: key,
                accountId: configuration.accountId
            )
        )
        let store = EpistoriaStore(database: database)
        let assetManager = AssetManager(
            accountId: configuration.accountId,
            accountKey: key,
            store: store,
            directory: support.appendingPathComponent("Assets", isDirectory: true)
        )
        var openedAPI: EpistoriaAPIClient?
        var openedSyncEngine: SyncEngine?
        var openedAIJobs: AIJobCoordinator?
        var connectionWarning: String?
        if configuration.serverConnected, let apiURL = configuration.apiURL {
            do {
                if let token = try tokenStore.token(deviceId: configuration.deviceId) {
                    let credentials = DeviceCredentials(
                        ownerId: configuration.accountId,
                        deviceId: configuration.deviceId,
                        token: token
                    )
                    let api = EpistoriaAPIClient(baseURL: apiURL, credentials: credentials)
                    await assetManager.setAPIClient(api)
                    openedAPI = api
                    openedSyncEngine = SyncEngine(
                        accountId: configuration.accountId,
                        accountKey: key,
                        database: database,
                        api: api
                    )
                    openedAIJobs = AIJobCoordinator(
                        accountId: configuration.accountId,
                        accountKey: key,
                        store: store,
                        api: api
                    )
                } else {
                    connectionWarning = "Private sync needs to be reconnected; local work remains available."
                }
            } catch {
                connectionWarning = "Private sync credentials could not be read; local work remains available."
            }
        }

        guard generation == sessionGeneration, !isLocking else { throw CancellationError() }
        self.configuration = configuration
        accountKey = key
        self.database = database
        self.store = store
        self.assetManager = assetManager
        api = openedAPI
        syncEngine = openedSyncEngine
        aiJobs = openedAIJobs
        syncError = connectionWarning
        phase = .ready
    }

    private func startPathMonitorIfNeeded() {
        guard pathMonitor == nil,
              configuration?.serverConnected == true,
              syncEngine != nil,
              !isLocking,
              case .ready = phase
        else { return }
        let generation = sessionGeneration
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self, weak monitor] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in
                guard let self, let monitor,
                      self.sessionGeneration == generation,
                      !self.isLocking,
                      self.pathMonitor === monitor,
                      case .ready = self.phase
                else { return }
                self.scheduleAutomaticSync(delay: .zero)
            }
        }
        pathMonitor = monitor
        monitor.start(queue: DispatchQueue(label: "com.epistoria.network-monitor"))
    }

    private func honorDeferredRestartIfNeeded() async {
        guard restartRequested else { return }
        guard !isOpening, !isLocking else { return }
        restartRequested = false
        guard case .loading = phase else { return }
        await start()
    }
}
