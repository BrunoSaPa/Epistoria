import EpistoriaCore
import CryptoKit
import Foundation
import Network
import Observation
import PDFKit
import UIKit

private enum AppModelOperationError: Error, LocalizedError {
    case accountSetupRollbackFailed
    case existingLocalNotebook
    case configuredNotebookUnavailable
    case notebookKeyUnavailable
    case serverIdentityMismatch
    case serverConnectionRollbackFailed
    case unlockedSessionUnavailable
    case aiProviderUnavailable
    case aiProviderSecretRequired
    case aiProviderURLInvalid
    case aiProviderRouteChanged
    case automationCostUnavailable
    case automationBudgetExceeded

    var errorDescription: String? {
        switch self {
        case .accountSetupRollbackFailed:
            "Epistoria could not safely roll back account setup. Restart the app before trying again."
        case .existingLocalNotebook:
            "This iPad already has an Epistoria notebook. Open or recover it before creating another. Existing data was not changed."
        case .configuredNotebookUnavailable:
            "Epistoria could not find a configured notebook to open. Existing data was not changed."
        case .notebookKeyUnavailable:
            "The notebook key is not available on this iPad. Restore it with its account ID and 24 recovery words. Existing data was not changed."
        case .serverIdentityMismatch:
            "The server returned credentials for a different account or device. No credentials were saved."
        case .serverConnectionRollbackFailed:
            "Epistoria could not safely restore the previous server credentials. Reconnect with the bootstrap secret."
        case .unlockedSessionUnavailable:
            "The unlocked notebook changed while this operation was running. Please try again."
        case .aiProviderUnavailable:
            "Unlock the notebook before changing an AI provider."
        case .aiProviderSecretRequired:
            "This provider requires an API key. The existing key was not changed."
        case .aiProviderURLInvalid:
            "Use HTTPS for a remote provider. Plain HTTP is allowed only for a local or private-network address."
        case .aiProviderRouteChanged:
            "The active provider changed after this request was reviewed. Review the request again before sending it."
        case .automationCostUnavailable:
            "Automatic provider work requires configured input and output rates so Epistoria can enforce the spending limit."
        case .automationBudgetExceeded:
            "This automatic request could exceed the approved spending limit. Increase the limit or run the request manually."
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

struct DirectProviderDisclosure: Equatable {
    var provider: String
    var model: String
    var destination: String
    var maximumEstimatedCostUsd: Double?
    var route: AIProviderRouteSnapshot
}

struct DirectSourcePreparation: Equatable {
    var sourceId: UUID
    var sourceVersionId: UUID
    var title: String
    var pageCount: Int
    var references: [SourceCitationReference]
    var images: [ProviderImageInput]
    var approximateTokens: Int
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
    var learningLaunchContext: LearningLaunchContext?
    var lastSyncReport: SyncReport?
    var lastSuccessfulSyncAt: Date?
    var syncError: String?
    var isSyncing = false
    var pendingRecordCount = 0
    var pendingFileCount = 0
    var unresolvedConflictCount = 0
    var sharedCaptureImportMessage: String?
    var sharedCaptureFailureMessage: String?
    private(set) var pendingSharedCaptureCount = 0
    private(set) var failedSharedCaptureCount = 0
    private(set) var sharedCaptureImportRevision = 0
    private(set) var isCreatingPortableExport = false
    private(set) var isImportingPortableExport = false
    private(set) var isCreatingNotePDF = false
    var configuration: AccountConfiguration?
    let pendingSaves = PendingSaveRegistry()
    let localProcessingSettings: LocalProcessingSettings
    let formulaModelManager: OnDeviceFormulaModelManager
    let formulaRecognitionEngine: CoreMLFormulaRecognitionEngine
    let workspacePreferences: WorkspacePreferences

    private(set) var database: SQLCipherDatabase?
    private(set) var store: EpistoriaStore?
    private(set) var assetManager: AssetManager?
    private(set) var api: EpistoriaAPIClient?
    private(set) var syncEngine: SyncEngine?
    private(set) var aiJobs: AIJobCoordinator?

    private var accountKey: Data?
    private let configurationStore: AccountConfigurationStore
    private let accountKeyStore: KeychainStore
    private let tokenStore: DeviceTokenStore
    private let aiProviderProfileStore: AIProviderProfileStore
    private let aiProviderSecretStore: AIProviderSecretStore
    private let directProviderClient: any ProviderClient
    private let directTranscriptionClient: any ProviderTranscriptionClient
    private let crypto: EntityCrypto
    private let sharedCaptureImporter: SharedCaptureImporter?
    private let applicationSupportOverride: URL?
    private var isOpening = false
    private var automaticSyncTask: Task<Void, Never>?
    private var automaticSyncToken: UUID?
    private var periodicSyncTask: Task<Void, Never>?
    private var proactiveAutomationTask: Task<Void, Never>?
    private var semanticIndexTask: Task<Void, Never>?
    private var syncAttemptTask: Task<SyncReport, Error>?
    private var exportTask: Task<EpistoriaExportResult, Error>?
    private var portableImportService: EpistoriaPortableImportService?
    private var pendingPortableImportPlan: EpistoriaImportPlan?
    private var notePDFExportTask: Task<NotePDFExportResult, Error>?
    private var sharedCaptureImportTask: Task<SharedCaptureImportReport, Never>?
    private var syncRequestedWhileRunning = false
    private var pathMonitor: NWPathMonitor?
    private var isLocking = false
    private var restartRequested = false
    private var sessionGeneration: UInt64 = 0
    private var isReconfiguringSync = false
    private var pendingSaveWarning: String?

    init(
        configurationStore: AccountConfigurationStore = AccountConfigurationStore(),
        accountKeyStore: KeychainStore = KeychainStore(),
        tokenStore: DeviceTokenStore = DeviceTokenStore(),
        aiProviderProfileStore: AIProviderProfileStore = AIProviderProfileStore(),
        aiProviderSecretStore: AIProviderSecretStore = AIProviderSecretStore(),
        directProviderClient: any ProviderClient = DirectProviderClient(),
        directTranscriptionClient: any ProviderTranscriptionClient = DirectProviderClient(),
        localProcessingSettings: LocalProcessingSettings = LocalProcessingSettings(),
        formulaModelManager: OnDeviceFormulaModelManager = OnDeviceFormulaModelManager(),
        workspacePreferences: WorkspacePreferences = WorkspacePreferences(),
        sharedCaptureImporter: SharedCaptureImporter? = .live(),
        crypto: EntityCrypto = EntityCrypto(),
        applicationSupportURL: URL? = nil
    ) {
        self.configurationStore = configurationStore
        self.accountKeyStore = accountKeyStore
        self.tokenStore = tokenStore
        self.aiProviderProfileStore = aiProviderProfileStore
        self.aiProviderSecretStore = aiProviderSecretStore
        self.directProviderClient = directProviderClient
        self.directTranscriptionClient = directTranscriptionClient
        self.localProcessingSettings = localProcessingSettings
        self.formulaModelManager = formulaModelManager
        self.workspacePreferences = workspacePreferences
        self.sharedCaptureImporter = sharedCaptureImporter
        formulaRecognitionEngine = CoreMLFormulaRecognitionEngine(modelManager: formulaModelManager)
        self.crypto = crypto
        applicationSupportOverride = applicationSupportURL
    }

    var hasConfiguredNotebook: Bool {
        configurationStore.load() != nil
    }

    var hasUnconfiguredLegacyNotebook: Bool {
        guard !configurationStore.containsStoredConfiguration,
              let support = try? applicationSupportURL()
        else { return false }
        return AccountStorageLocator(applicationSupportURL: support).hasLegacyDatabase
    }

    #if DEBUG
    var hasLocalDevelopmentNotebookData: Bool {
        if configurationStore.containsStoredConfiguration { return true }
        guard let support = try? applicationSupportURL() else { return false }
        return DevelopmentNotebookStorageResetter(
            applicationSupportURL: support
        ).hasLegacyStorage
    }
    #endif

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
            let purpose = storagePurpose(for: configuration)
            try await open(
                configuration: configuration,
                key: key,
                generation: generation,
                storagePurpose: purpose
            )
            try persistResolvedStorageScopeIfNeeded(
                configuration,
                purpose: purpose
            )
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
        proactiveAutomationTask?.cancel()
        proactiveAutomationTask = nil
        semanticIndexTask?.cancel()
        semanticIndexTask = nil
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

        if let service = portableImportService, let plan = pendingPortableImportPlan {
            try? await service.cancel(plan)
        }
        portableImportService = nil
        pendingPortableImportPlan = nil
        isImportingPortableExport = false

        let activeNotePDFExport = notePDFExportTask
        activeNotePDFExport?.cancel()
        if let activeNotePDFExport {
            _ = await activeNotePDFExport.result
        }
        notePDFExportTask = nil
        isCreatingNotePDF = false
        let captureImport = sharedCaptureImportTask
        captureImport?.cancel()
        if let captureImport { _ = await captureImport.value }
        sharedCaptureImportTask = nil
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
        try? NotePDFExportService.removeAllTemporaryPDFs()
        try? ProtectedVideoFileStore.removeAllTemporaryFiles()
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
        try configurationStore.validateForMutation()
        guard !configurationStore.containsStoredConfiguration,
              !hasUnconfiguredLegacyNotebook
        else {
            throw AppModelOperationError.existingLocalNotebook
        }
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
        try configurationStore.validateForMutation()
        guard !configurationStore.containsStoredConfiguration,
              !hasUnconfiguredLegacyNotebook
        else {
            throw AppModelOperationError.existingLocalNotebook
        }
        isOpening = true
        let generation = sessionGeneration
        let configuration = AccountConfiguration(
            accountId: material.accountId,
            deviceId: material.deviceId,
            apiURL: nil,
            serverConnected: false,
            storageScope: .accountScoped
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
                generation: generation,
                storagePurpose: .accountScoped
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
        try configurationStore.validateForMutation()
        let existing = try configurationStore.loadValidated()
        guard existing == nil || existing?.accountId == accountId else {
            throw AppModelOperationError.existingLocalNotebook
        }
        isOpening = true
        let generation = sessionGeneration
        let support = try applicationSupportURL()
        let recoveredLocation = AccountStorageLocator(applicationSupportURL: support).location(
            for: accountId,
            purpose: .existingWithLegacyFallback
        )
        var configuration = existing ?? AccountConfiguration(
            accountId: accountId,
            deviceId: UUID(),
            apiURL: nil,
            serverConnected: false,
            storageScope: recoveredLocation.directoryURL.standardizedFileURL
                == support.standardizedFileURL ? .legacyShared : .accountScoped
        )
        let purpose = storagePurpose(for: configuration)
        do {
            try await open(
                configuration: configuration,
                key: key,
                generation: generation,
                storagePurpose: purpose
            )
            configuration = try resolvedStorageConfiguration(
                configuration,
                purpose: purpose
            )
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

    func openConfiguredNotebook() async throws {
        guard !isOpening, !isLocking else {
            throw AppModelOperationError.unlockedSessionUnavailable
        }
        try configurationStore.validateForMutation()
        guard let target = try configurationStore.loadValidated() else {
            throw AppModelOperationError.configuredNotebookUnavailable
        }
        guard let key = try accountKeyStore.accountKey(
            accountId: target.accountId,
            prompt: "Open Epistoria"
        ) else { throw AppModelOperationError.notebookKeyUnavailable }

        isOpening = true
        let generation = sessionGeneration
        let purpose = storagePurpose(for: target)
        do {
            try await open(
                configuration: target,
                key: key,
                generation: generation,
                storagePurpose: purpose
            )
            try persistResolvedStorageScopeIfNeeded(target, purpose: purpose)
        } catch {
            let originalError = error
            await tearDown(nextPhase: .onboarding, honorDeferredRestart: false)
            isOpening = false
            throw originalError
        }
        await beginReadyWork()
        isOpening = false
        await honorDeferredRestartIfNeeded()
    }

    func aiProviderProfiles() throws -> [AIProviderProfile] {
        guard let accountId = configuration?.accountId else { return [] }
        return try aiProviderProfileStore.load(accountId: accountId)
    }

    var activeAIProviderDescription: String {
        let profiles = (try? aiProviderProfiles()) ?? []
        guard let profile = profiles.first(where: { $0.isActive && $0.state == .ready }) else {
            if !profiles.isEmpty {
                return "the provider after its connection is ready on this iPad"
            }
            return "the provider active on this iPad"
        }
        return "\(profile.displayName) at \(profile.destinationHost) using \(profile.textModel)"
    }

    private func activeProviderRouteState(
        accountId: UUID
    ) -> (snapshot: AIProviderRouteSnapshot?, required: Bool) {
        guard let profiles = try? aiProviderProfileStore.load(accountId: accountId) else {
            return (nil, true)
        }
        let active = profiles.first { $0.isActive && $0.state == .ready }
        return (active?.routeSnapshot, !profiles.isEmpty)
    }

    private func refreshAIJobProviderRoute(accountId: UUID) async {
        let route = activeProviderRouteState(accountId: accountId)
        await aiJobs?.setProviderRouteSnapshot(route.snapshot, required: route.required)
    }

    func saveAIProviderProfile(
        _ proposed: AIProviderProfile,
        replacementSecret: String?
    ) async throws {
        guard let accountId = configuration?.accountId else {
            throw AppModelOperationError.aiProviderUnavailable
        }
        guard AIProviderURLPolicy.normalized(
            proposed.baseURL.absoluteString,
            adapter: proposed.adapter
        ) == proposed.baseURL else {
            throw AppModelOperationError.aiProviderURLInvalid
        }
        var profiles = try aiProviderProfileStore.load(accountId: accountId)
        let existing = profiles.first(where: { $0.id == proposed.id })
        if let replacementSecret, !replacementSecret.isEmpty {
            try aiProviderSecretStore.save(
                replacementSecret,
                accountId: accountId,
                profileId: proposed.id
            )
        } else if let existing, existing.adapter != proposed.adapter {
            try aiProviderSecretStore.delete(accountId: accountId, profileId: proposed.id)
        }
        let secret = try aiProviderSecretStore.secret(
            accountId: accountId,
            profileId: proposed.id
        )
        if proposed.adapter == .openAIResponses, secret == nil {
            throw AppModelOperationError.aiProviderSecretRequired
        }

        var saved = proposed
        if !saved.isActive,
           !profiles.contains(where: { $0.id != saved.id && $0.isActive }) {
            saved.isActive = true
        }
        if saved.isActive {
            for index in profiles.indices { profiles[index].isActive = profiles[index].id == saved.id }
        }
        saved.state = .ready
        saved.pendingOperation = nil
        saved.configurationRevisionId = UUID()
        saved.lastJobId = nil
        saved.lastErrorCode = nil
        saved.updatedAt = Date()
        upsert(saved, in: &profiles)
        try aiProviderProfileStore.save(profiles, accountId: accountId)
        await refreshAIJobProviderRoute(accountId: accountId)
    }

    func activateAIProviderProfile(id: UUID) async throws {
        guard let accountId = configuration?.accountId else {
            throw AppModelOperationError.aiProviderUnavailable
        }
        var profiles = try aiProviderProfileStore.load(accountId: accountId)
        guard profiles.contains(where: { $0.id == id }) else { return }
        for index in profiles.indices {
            profiles[index].isActive = profiles[index].id == id
            profiles[index].state = .ready
            profiles[index].pendingOperation = nil
            profiles[index].lastJobId = nil
            profiles[index].lastErrorCode = nil
            profiles[index].updatedAt = Date()
        }
        try aiProviderProfileStore.save(profiles, accountId: accountId)
        await refreshAIJobProviderRoute(accountId: accountId)
    }

    func removeAIProviderProfile(id: UUID) async throws {
        guard let accountId = configuration?.accountId else {
            throw AppModelOperationError.aiProviderUnavailable
        }
        var profiles = try aiProviderProfileStore.load(accountId: accountId)
        guard profiles.contains(where: { $0.id == id }) else { return }
        try aiProviderSecretStore.delete(accountId: accountId, profileId: id)
        profiles.removeAll { $0.id == id }
        if !profiles.contains(where: \.isActive), !profiles.isEmpty { profiles[0].isActive = true }
        try aiProviderProfileStore.save(profiles, accountId: accountId)
        await refreshAIJobProviderRoute(accountId: accountId)
    }

    func refreshAIProviderProfiles() async throws {
        guard let accountId = configuration?.accountId else { return }
        var profiles = try aiProviderProfileStore.load(accountId: accountId)
        var changed = false
        for index in profiles.indices where profiles[index].state == .local || profiles[index].state == .queued {
            profiles[index].state = .ready
            profiles[index].pendingOperation = nil
            profiles[index].lastJobId = nil
            profiles[index].lastErrorCode = nil
            profiles[index].updatedAt = Date()
            changed = true
        }
        if changed { try aiProviderProfileStore.save(profiles, accountId: accountId) }
        await refreshAIJobProviderRoute(accountId: accountId)
    }

    /// Executes an explicitly approved provider turn directly from this iPad. The durable local
    /// job contains no prompt or response text; callers store validated output in its typed,
    /// encrypted artifact only after this method succeeds.
    func performDirectProviderText(
        _ request: ProviderTextRequest,
        approval: ProcessingApproval
    ) async throws -> (ProviderTextResponse, AIProviderRouteSnapshot, UUID) {
        guard let accountId = configuration?.accountId, let database else {
            throw AppModelOperationError.aiProviderUnavailable
        }
        let profiles = try aiProviderProfileStore.load(accountId: accountId)
        guard let profile = profiles.first(where: {
            $0.id == approval.providerProfileId && $0.isActive && $0.state == .ready
        }), approval.isValid() else {
            throw AppModelOperationError.aiProviderUnavailable
        }
        let secret = try aiProviderSecretStore.secret(accountId: accountId, profileId: profile.id)
        let fingerprint = SHA256.hash(data: Data(request.prompt.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let router = ProcessingRouter()
        let route = router.route(
            requiredCapabilities: [.hostedProvider],
            approval: approval,
            availability: [
                ProcessingRouteAvailability(
                    route: .directProvider,
                    capabilities: [.hostedProvider, .localProvider],
                    isAvailable: true
                ),
            ]
        )
        guard route == .directProvider else { throw AppModelOperationError.aiProviderUnavailable }
        var job = ProcessingJob(
            kind: "DIRECT_PROVIDER_TEXT",
            inputFingerprint: fingerprint,
            requiredCapabilities: [.hostedProvider],
            selectedRoute: .directProvider,
            approval: approval
        )
        _ = try await database.saveProcessingJob(job)
        job = try await database.transitionProcessingJob(
            id: job.id,
            to: .running,
            route: .directProvider
        )
        do {
            let response = try await directProviderClient.performText(
                request,
                route: profile.routeSnapshot,
                apiKey: secret
            )
            _ = try await database.transitionProcessingJob(
                id: job.id,
                to: .completed,
                progress: 1
            )
            return (response, profile.routeSnapshot, job.id)
        } catch DirectProviderError.transport {
            _ = try? await database.transitionProcessingJob(
                id: job.id,
                to: .waitingForNetwork,
                errorCode: "PROVIDER_UNREACHABLE"
            )
            throw DirectProviderError.transport
        } catch is CancellationError {
            _ = try? await database.transitionProcessingJob(id: job.id, to: .cancelled)
            throw CancellationError()
        } catch {
            _ = try? await database.transitionProcessingJob(
                id: job.id,
                to: .failed,
                errorCode: "PROVIDER_REQUEST_FAILED"
            )
            throw error
        }
    }

    func directTopicStudioDisclosure(
        approximateInputTokens: Int,
        jobType: LearningAIJobType
    ) throws -> DirectProviderDisclosure {
        try directProviderDisclosure(
            approximateInputTokens: approximateInputTokens,
            maximumOutputTokens: DirectLearningGeneration.maximumOutputTokens(for: jobType)
        )
    }

    func directProviderDisclosure(
        approximateInputTokens: Int,
        maximumOutputTokens: Int,
        requiresVision: Bool = false,
        requiresTranscription: Bool = false
    ) throws -> DirectProviderDisclosure {
        guard let accountId = configuration?.accountId else {
            throw AppModelOperationError.aiProviderUnavailable
        }
        let profile = try activeDirectProviderProfile(accountId: accountId)
        if requiresVision, !profile.capabilities.contains(.vision) {
            throw DirectWorkflowError.visionUnavailable
        }
        if requiresTranscription,
           (!profile.capabilities.contains(.transcription)
               || profile.transcriptionModel?.isEmpty != false) {
            throw AppModelOperationError.aiProviderUnavailable
        }
        let maximumEstimatedCostUsd: Double?
        if let inputRate = profile.inputUSDPerMillion,
           let outputRate = profile.outputUSDPerMillion {
            maximumEstimatedCostUsd =
                (Double(max(approximateInputTokens, 0)) / 1_000_000 * max(inputRate, 0))
                + (Double(maximumOutputTokens) / 1_000_000 * max(outputRate, 0))
        } else {
            maximumEstimatedCostUsd = nil
        }
        return DirectProviderDisclosure(
            provider: profile.displayName,
            model: profile.textModel,
            destination: profile.destinationHost,
            maximumEstimatedCostUsd: maximumEstimatedCostUsd,
            route: profile.routeSnapshot
        )
    }

    @discardableResult
    private func generateDirectArtifact<Result>(
        jobId: UUID,
        kind: String,
        inputEntityId: UUID,
        sourceIds: [UUID],
        approximateInputTokens: Int,
        approvedRoute: AIProviderRouteSnapshot,
        providerRequest: ProviderTextRequest,
        validate: (String) throws -> Result,
        persist: (Result, ProviderTrace, AIProviderRouteSnapshot) async throws -> UUID
    ) async throws -> UUID {
        guard let accountId = configuration?.accountId, let database else {
            throw AppModelOperationError.aiProviderUnavailable
        }
        let profile = try activeDirectProviderProfile(accountId: accountId)
        guard profile.routeSnapshot == approvedRoute else {
            throw AppModelOperationError.aiProviderRouteChanged
        }
        let disclosure = try directProviderDisclosure(
            approximateInputTokens: approximateInputTokens,
            maximumOutputTokens: providerRequest.maximumOutputTokens,
            requiresVision: !providerRequest.images.isEmpty
        )
        let approval = ProcessingApproval(
            providerProfileId: profile.id,
            sourceIds: sourceIds,
            maximumCostMinorUnits: disclosure.maximumEstimatedCostUsd.map {
                Int(ceil(max($0, 0) * 100))
            },
            currencyCode: disclosure.maximumEstimatedCostUsd == nil ? nil : "USD",
            expiresAt: Date().addingTimeInterval(30 * 60)
        )
        var fingerprintData = Data(providerRequest.prompt.utf8)
        for image in providerRequest.images {
            fingerprintData.append(contentsOf: SHA256.hash(data: image.data))
        }
        let fingerprint = SHA256.hash(data: fingerprintData)
            .map { String(format: "%02x", $0) }.joined()
        let job = ProcessingJob(
            id: jobId,
            kind: kind,
            inputEntityId: inputEntityId,
            inputFingerprint: fingerprint,
            requiredCapabilities: [.hostedProvider],
            selectedRoute: .directProvider,
            approval: approval
        )
        _ = try await database.saveProcessingJob(job)
        _ = try await database.transitionProcessingJob(
            id: job.id,
            to: .running,
            route: .directProvider
        )
        do {
            let secret = try aiProviderSecretStore.secret(
                accountId: accountId,
                profileId: profile.id
            )
            let providerResponse = try await directProviderClient.performText(
                providerRequest,
                route: approvedRoute,
                apiKey: secret
            )
            let result = try validate(providerResponse.text)
            let trace = providerTrace(
                profile: profile,
                response: providerResponse,
                promptVersion: DirectWorkflowGeneration.promptVersion
            )
            let artifactId = try await persist(result, trace, approvedRoute)
            _ = try await database.transitionProcessingJob(id: job.id, to: .completed, progress: 1)
            return artifactId
        } catch DirectProviderError.transport {
            _ = try? await database.transitionProcessingJob(
                id: job.id,
                to: .waitingForNetwork,
                errorCode: "PROVIDER_UNREACHABLE"
            )
            throw DirectProviderError.transport
        } catch is CancellationError {
            _ = try? await database.transitionProcessingJob(id: job.id, to: .cancelled)
            throw CancellationError()
        } catch let error as DirectWorkflowError {
            _ = try? await database.transitionProcessingJob(
                id: job.id,
                to: .failed,
                errorCode: "PROVIDER_SCHEMA_INVALID"
            )
            throw error
        } catch {
            _ = try? await database.transitionProcessingJob(
                id: job.id,
                to: .failed,
                errorCode: "PROVIDER_REQUEST_FAILED"
            )
            throw error
        }
    }

    private func providerTrace(
        profile: AIProviderProfile,
        response: ProviderTextResponse,
        promptVersion: String
    ) -> ProviderTrace {
        let cost: Double?
        if let inputTokens = response.inputTokens,
           let outputTokens = response.outputTokens,
           let inputRate = profile.inputUSDPerMillion,
           let outputRate = profile.outputUSDPerMillion {
            cost = Double(inputTokens) / 1_000_000 * max(inputRate, 0)
                + Double(outputTokens) / 1_000_000 * max(outputRate, 0)
        } else {
            cost = nil
        }
        return ProviderTrace(
            provider: profile.displayName,
            model: profile.textModel,
            promptVersion: promptVersion,
            inputTokens: response.inputTokens,
            outputTokens: response.outputTokens,
            estimatedCostUsd: cost,
            providerRequestId: response.providerRequestId
        )
    }

    func generateSessionDigestDirect(
        _ prepared: PreparedDigestRequest,
        approvedRoute: AIProviderRouteSnapshot
    ) async throws -> UUID {
        guard let store else { throw AppModelOperationError.unlockedSessionUnavailable }
        var request = prepared.request
        request.disclosureAcknowledged = true
        request.providerRoute = approvedRoute
        let providerRequest = try DirectWorkflowGeneration.sessionDigestRequest(request)
        return try await generateDirectArtifact(
            jobId: request.jobId,
            kind: "SESSION_DIGEST",
            inputEntityId: request.sessionId,
            sourceIds: request.sources.map(\.sourceId),
            approximateInputTokens: prepared.preview.approximateTokens,
            approvedRoute: approvedRoute,
            providerRequest: providerRequest,
            validate: { try DirectWorkflowGeneration.validateSessionDigest($0, request: request) },
            persist: { digest, trace, route in
                let artifact = SessionDigestArtifact(
                    schemaVersion: "ai-artifact/session-digest/v1",
                    jobId: request.jobId,
                    sessionId: request.sessionId,
                    generatedAt: .now,
                    sourceIds: digest.keyPoints.flatMap(\.sourceIds)
                        + digest.possibleMisconceptions.flatMap(\.sourceIds),
                    trace: trace,
                    providerRoute: route,
                    digest: digest,
                    reviewState: nil,
                    reviewedAt: nil,
                    editedDigest: nil
                )
                let id = DirectWorkflowGeneration.artifactId(jobId: request.jobId, kind: "session")
                _ = try await store.save(
                    id: id,
                    payload: artifact,
                    parentId: request.sessionId,
                    relationIds: [request.sessionId] + artifact.sourceIds
                )
                return id
            }
        )
    }

    func generateNoteQueryDirect(
        _ prepared: PreparedNoteQueryRequest,
        approvedRoute: AIProviderRouteSnapshot
    ) async throws -> UUID {
        guard let store else { throw AppModelOperationError.unlockedSessionUnavailable }
        var request = prepared.request
        request.disclosureAcknowledged = true
        request.providerRoute = approvedRoute
        let providerRequest = try DirectWorkflowGeneration.noteQueryRequest(request, route: approvedRoute)
        return try await generateDirectArtifact(
            jobId: request.jobId,
            kind: "NOTE_QUERY",
            inputEntityId: request.noteId,
            sourceIds: (request.selectionSources + request.contextSources).map(\.sourceId),
            approximateInputTokens: prepared.approximateTokens,
            approvedRoute: approvedRoute,
            providerRequest: providerRequest,
            validate: { try DirectWorkflowGeneration.validateNoteQuery($0, request: request) },
            persist: { response, trace, route in
                let artifact = NoteQueryArtifact(
                    schemaVersion: "ai-artifact/note-query/v1",
                    jobId: request.jobId,
                    noteId: request.noteId,
                    question: request.question,
                    generatedAt: .now,
                    sourceIds: response.citedSourceIds,
                    trace: trace,
                    providerRoute: route,
                    response: response,
                    reviewState: nil,
                    reviewedAt: nil,
                    editedResponse: nil
                )
                let id = DirectWorkflowGeneration.artifactId(jobId: request.jobId, kind: "note-query")
                _ = try await store.save(
                    id: id,
                    payload: artifact,
                    parentId: request.noteId,
                    relationIds: [request.noteId] + artifact.sourceIds
                )
                return id
            }
        )
    }

    func generateMathAssistanceDirect(
        _ prepared: PreparedMathAssistanceRequest,
        approvedRoute: AIProviderRouteSnapshot
    ) async throws -> UUID {
        guard let store else { throw AppModelOperationError.unlockedSessionUnavailable }
        var request = prepared.request
        request.disclosureAcknowledged = true
        request.providerRoute = approvedRoute
        let providerRequest = try DirectWorkflowGeneration.mathRequest(request, route: approvedRoute)
        return try await generateDirectArtifact(
            jobId: request.jobId,
            kind: "MATH_ASSISTANCE",
            inputEntityId: request.noteId,
            sourceIds: (request.selectionSources + request.contextSources).map(\.sourceId),
            approximateInputTokens: prepared.approximateTokens,
            approvedRoute: approvedRoute,
            providerRequest: providerRequest,
            validate: { try DirectWorkflowGeneration.validateMath($0, request: request) },
            persist: { response, trace, route in
                let artifact = MathAssistanceArtifact(
                    jobId: request.jobId,
                    noteId: request.noteId,
                    mode: request.mode,
                    learnerInstructions: request.learnerInstructions,
                    generatedAt: .now,
                    sourceIds: response.citedSourceIds,
                    trace: trace,
                    response: response,
                    providerRoute: route
                )
                let id = DirectWorkflowGeneration.artifactId(jobId: request.jobId, kind: "math")
                _ = try await store.save(
                    id: id,
                    payload: artifact,
                    parentId: request.noteId,
                    relationIds: [request.noteId] + artifact.sourceIds
                )
                return id
            }
        )
    }

    func generateFreeResponseFeedbackDirect(
        _ prepared: PreparedFreeResponseFeedbackRequest,
        approvedRoute: AIProviderRouteSnapshot
    ) async throws -> UUID {
        guard let store else { throw AppModelOperationError.unlockedSessionUnavailable }
        var request = prepared.request
        request.disclosureAcknowledged = true
        request.providerRoute = approvedRoute
        let providerRequest = try DirectWorkflowGeneration.feedbackRequest(request)
        return try await generateDirectArtifact(
            jobId: request.jobId,
            kind: "FREE_RESPONSE_FEEDBACK",
            inputEntityId: request.responseId,
            sourceIds: request.evidence.map(\.sourceId),
            approximateInputTokens: prepared.approximateTokens,
            approvedRoute: approvedRoute,
            providerRequest: providerRequest,
            validate: { try DirectWorkflowGeneration.validateFeedback($0, request: request) },
            persist: { response, trace, route in
                let artifact = FreeResponseFeedbackArtifact(
                    jobId: request.jobId,
                    attemptId: request.attemptId,
                    responseId: request.responseId,
                    questionId: request.questionId,
                    topicId: request.topicId,
                    generatedAt: .now,
                    sourceIds: response.citedSourceIds,
                    trace: trace,
                    response: response,
                    providerRoute: route
                )
                let id = DirectWorkflowGeneration.artifactId(jobId: request.jobId, kind: "feedback")
                _ = try await store.save(
                    id: id,
                    payload: artifact,
                    parentId: request.attemptId,
                    relationIds: [request.attemptId, request.responseId, request.topicId]
                        + artifact.sourceIds
                )
                return id
            }
        )
    }

    /// Extracts a PDF locally. The original encrypted Asset remains authoritative; chunks and the
    /// manifest are derived encrypted records that can be regenerated.
    @discardableResult
    func extractPDFOnDevice(sourceId: UUID) async throws -> UUID {
        guard let database, let store, let assetManager else {
            throw AppModelOperationError.unlockedSessionUnavailable
        }
        let resource = try await store.payload(ResourcePayload.self, id: sourceId).payload
        let source = try await store.payload(SourcePayload.self, id: sourceId).payload
        guard resource.resourceType == .pdf,
              let versionId = source.currentVersionId,
              let version = try? await store.payload(SourceVersionPayload.self, id: versionId).payload,
              let assetId = version.originalAssetId
        else { throw AIJobCoordinatorError.resourceHasNoPDF }
        let data = try await assetManager.decryptedData(assetId: assetId)
        guard let document = PDFDocument(data: data), document.pageCount > 0 else {
            throw AIJobCoordinatorError.resourceHasNoPDF
        }
        let jobId = UUID()
        let fingerprint = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }.joined()
        let job = ProcessingJob(
            id: jobId,
            kind: "PDF_EXTRACTION",
            inputEntityId: versionId,
            inputFingerprint: fingerprint,
            requiredCapabilities: [.sourceExtraction],
            selectedRoute: .onDevice
        )
        _ = try await database.saveProcessingJob(job)
        _ = try await database.transitionProcessingJob(id: jobId, to: .running, route: .onDevice)
        do {
            var pages: [ExtractedPDFPage] = []
            for index in 0 ..< document.pageCount {
                try Task.checkCancellation()
                let raw = document.page(at: index)?.string ?? ""
                let text = String(raw.prefix(100_000))
                let count = text.count
                pages.append(
                    ExtractedPDFPage(
                        pageNumber: index + 1,
                        text: text,
                        characterCount: count,
                        needsOcr: text.trimmingCharacters(in: .whitespacesAndNewlines).count < 24
                    )
                )
            }
            var chunkIds: [UUID] = []
            for (index, start) in stride(from: 0, to: pages.count, by: 10).enumerated() {
                let id = DirectWorkflowGeneration.artifactId(
                    jobId: jobId,
                    kind: "pdf-chunk-\(index)"
                )
                let chunk = PDFExtractionChunk(
                    schemaVersion: "pdf-extraction-chunk/v1",
                    jobId: jobId,
                    resourceId: sourceId,
                    chunkIndex: index,
                    pages: Array(pages[start ..< min(start + 10, pages.count)])
                )
                _ = try await database.saveLocal(
                    id: id,
                    entityType: .aiArtifact,
                    parentId: sourceId,
                    relationIds: [sourceId, versionId],
                    content: CanonicalJSON.encode(chunk)
                )
                chunkIds.append(id)
            }
            let manifest = PDFExtractionManifest(
                schemaVersion: "ai-artifact/pdf-extraction/v2",
                jobId: jobId,
                resourceId: sourceId,
                generatedAt: .now,
                pageCount: pages.count,
                characterCount: pages.reduce(0) { $0 + $1.characterCount },
                pagesNeedingOcr: pages.filter(\.needsOcr).map(\.pageNumber),
                chunkEntityIds: chunkIds
            )
            let manifestId = DirectWorkflowGeneration.artifactId(jobId: jobId, kind: "pdf")
            _ = try await store.save(
                id: manifestId,
                payload: manifest,
                parentId: sourceId,
                relationIds: [sourceId, versionId] + chunkIds
            )
            _ = try await database.transitionProcessingJob(id: jobId, to: .completed, progress: 1)
            return manifestId
        } catch is CancellationError {
            _ = try? await database.transitionProcessingJob(id: jobId, to: .cancelled)
            throw CancellationError()
        } catch {
            _ = try? await database.transitionProcessingJob(
                id: jobId,
                to: .failed,
                errorCode: "PDF_EXTRACTION_FAILED"
            )
            throw error
        }
    }

    func prepareDirectSource(
        sourceId: UUID,
        includeImages: Bool
    ) async throws -> DirectSourcePreparation {
        guard let store, let assetManager else {
            throw AppModelOperationError.unlockedSessionUnavailable
        }
        let source = try await store.payload(SourcePayload.self, id: sourceId).payload
        guard source.sourceType == .pdf,
              let versionId = source.currentVersionId,
              let version = try? await store.payload(SourceVersionPayload.self, id: versionId).payload,
              let assetId = version.originalAssetId
        else { throw AIJobCoordinatorError.sourceAnalysisRequiresPDF }
        let data = try await assetManager.decryptedData(assetId: assetId)
        guard let document = PDFDocument(data: data), document.pageCount > 0 else {
            throw AIJobCoordinatorError.sourceAnalysisRequiresPDF
        }
        var references: [SourceCitationReference] = []
        var images: [ProviderImageInput] = []
        var characterCount = 0
        for pageIndex in 0 ..< document.pageCount where references.count < 80 {
            try Task.checkCancellation()
            guard let page = document.page(at: pageIndex) else { continue }
            let pageText = page.string ?? ""
            let text = pageText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, characterCount < 320_000 {
                for (part, start) in stride(from: 0, to: text.count, by: 8_000).enumerated() {
                    guard references.count < 80, characterCount < 320_000 else { break }
                    let lower = text.index(text.startIndex, offsetBy: start)
                    let upper = text.index(lower, offsetBy: min(8_000, text.count - start))
                    let excerpt = String(text[lower ..< upper])
                    let referenceId = DirectWorkflowGeneration.artifactId(
                        jobId: versionId,
                        kind: "page-\(pageIndex + 1)-text-\(part)"
                    )
                    references.append(
                        SourceCitationReference(
                            sourceId: referenceId,
                            kind: .text,
                            pageNumber: pageIndex + 1,
                            rectangles: Self.pdfSelectionRectangles(
                                page: page,
                                pageText: pageText,
                                excerpt: excerpt
                            ),
                            excerpt: excerpt
                        )
                    )
                    characterCount += excerpt.count
                }
            }
            if includeImages, images.count < 8 {
                let thumbnail = page.thumbnail(of: CGSize(width: 1_200, height: 1_600), for: .mediaBox)
                if let image = thumbnail.jpegData(compressionQuality: 0.72), image.count <= 2_000_000 {
                    let referenceId = DirectWorkflowGeneration.artifactId(
                        jobId: versionId,
                        kind: "page-\(pageIndex + 1)-image"
                    )
                    references.append(
                        SourceCitationReference(
                            sourceId: referenceId,
                            kind: .image,
                            pageNumber: pageIndex + 1,
                            rectangles: [AnnotationRectangle(x: 0, y: 0, width: 1, height: 1)],
                            excerpt: "Rendered page \(pageIndex + 1)"
                        )
                    )
                    images.append(ProviderImageInput(mimeType: "image/jpeg", data: image))
                }
            }
        }
        guard !references.isEmpty else { throw AIJobCoordinatorError.noReadableSources }
        return DirectSourcePreparation(
            sourceId: sourceId,
            sourceVersionId: versionId,
            title: source.title,
            pageCount: document.pageCount,
            references: references,
            images: images,
            approximateTokens: max(1, characterCount / 4 + images.count * 700)
        )
    }

    private static func pdfSelectionRectangles(
        page: PDFPage,
        pageText: String,
        excerpt: String
    ) -> [AnnotationRectangle] {
        guard let range = pageText.range(of: excerpt) else {
            return [AnnotationRectangle(x: 0, y: 0, width: 1, height: 1)]
        }
        let nsRange = NSRange(range, in: pageText)
        guard let selection = page.selection(for: nsRange) else {
            return [AnnotationRectangle(x: 0, y: 0, width: 1, height: 1)]
        }
        let pageBounds = page.bounds(for: .mediaBox)
        let bounds = selection.bounds(for: page)
        guard pageBounds.width > 0, pageBounds.height > 0,
              !bounds.isNull, !bounds.isEmpty
        else { return [AnnotationRectangle(x: 0, y: 0, width: 1, height: 1)] }
        return [AnnotationRectangle(
            x: min(max((bounds.minX - pageBounds.minX) / pageBounds.width, 0), 1),
            y: min(max((pageBounds.maxY - bounds.maxY) / pageBounds.height, 0), 1),
            width: min(max(bounds.width / pageBounds.width, 0.000_001), 1),
            height: min(max(bounds.height / pageBounds.height, 0.000_001), 1)
        )]
    }

    func generateSourceAnalysisDirect(
        preparation: DirectSourcePreparation,
        outputLanguage: String,
        approvedRoute: AIProviderRouteSnapshot
    ) async throws -> UUID {
        guard let store else { throw AppModelOperationError.unlockedSessionUnavailable }
        let jobId = UUID()
        let providerRequest = try DirectWorkflowGeneration.sourceGuideRequest(
            title: preparation.title,
            outputLanguage: outputLanguage,
            references: preparation.references,
            images: preparation.images
        )
        return try await generateDirectArtifact(
            jobId: jobId,
            kind: "SOURCE_ANALYSIS",
            inputEntityId: preparation.sourceVersionId,
            sourceIds: [preparation.sourceId, preparation.sourceVersionId],
            approximateInputTokens: preparation.approximateTokens,
            approvedRoute: approvedRoute,
            providerRequest: providerRequest,
            validate: {
                try DirectWorkflowGeneration.validateSourceGuide(
                    $0,
                    references: preparation.references
                )
            },
            persist: { guide, trace, route in
                let artifact = SourceAnalysisArtifact(
                    schemaVersion: "ai-artifact/source-analysis/v1",
                    jobId: jobId,
                    sourceId: preparation.sourceId,
                    sourceVersionId: preparation.sourceVersionId,
                    generatedAt: .now,
                    pageCount: preparation.pageCount,
                    analyzedPageCount: Set(preparation.references.map(\.pageNumber)).count,
                    references: preparation.references,
                    trace: trace,
                    providerRoute: route,
                    guide: guide
                )
                let id = DirectWorkflowGeneration.artifactId(jobId: jobId, kind: "source-analysis")
                _ = try await store.save(
                    id: id,
                    payload: artifact,
                    parentId: preparation.sourceId,
                    relationIds: [preparation.sourceId, preparation.sourceVersionId]
                )
                return id
            }
        )
    }

    func generateSourceQueryDirect(
        preparation: DirectSourcePreparation,
        question: String,
        outputLanguage: String,
        approvedRoute: AIProviderRouteSnapshot
    ) async throws -> UUID {
        guard let store else { throw AppModelOperationError.unlockedSessionUnavailable }
        let jobId = UUID()
        let providerRequest = try DirectWorkflowGeneration.sourceQueryRequest(
            title: preparation.title,
            question: question,
            outputLanguage: outputLanguage,
            references: preparation.references,
            images: preparation.images
        )
        return try await generateDirectArtifact(
            jobId: jobId,
            kind: "SOURCE_QUERY",
            inputEntityId: preparation.sourceVersionId,
            sourceIds: [preparation.sourceId, preparation.sourceVersionId],
            approximateInputTokens: preparation.approximateTokens,
            approvedRoute: approvedRoute,
            providerRequest: providerRequest,
            validate: {
                try DirectWorkflowGeneration.validateSourceQuery(
                    $0,
                    references: preparation.references
                )
            },
            persist: { response, trace, route in
                let artifact = SourceQueryArtifact(
                    schemaVersion: "ai-artifact/source-query/v1",
                    jobId: jobId,
                    sourceId: preparation.sourceId,
                    sourceVersionId: preparation.sourceVersionId,
                    question: question,
                    generatedAt: .now,
                    references: preparation.references,
                    trace: trace,
                    providerRoute: route,
                    response: response
                )
                let id = DirectWorkflowGeneration.artifactId(jobId: jobId, kind: "source-query")
                _ = try await store.save(
                    id: id,
                    payload: artifact,
                    parentId: preparation.sourceId,
                    relationIds: [preparation.sourceId, preparation.sourceVersionId]
                )
                return id
            }
        )
    }

    func directTranscriptionDisclosure() throws -> DirectProviderDisclosure {
        guard let accountId = configuration?.accountId else {
            throw AppModelOperationError.aiProviderUnavailable
        }
        let profile = try activeDirectProviderProfile(accountId: accountId)
        guard profile.capabilities.contains(.transcription),
              let model = profile.transcriptionModel, !model.isEmpty
        else { throw AppModelOperationError.aiProviderUnavailable }
        return DirectProviderDisclosure(
            provider: profile.displayName,
            model: model,
            destination: profile.destinationHost,
            maximumEstimatedCostUsd: nil,
            route: profile.routeSnapshot
        )
    }

    @discardableResult
    func transcribeSourceDirect(
        sourceId: UUID,
        language: String?,
        approvedRoute: AIProviderRouteSnapshot
    ) async throws -> UUID {
        guard let accountId = configuration?.accountId,
              let database, let store, let assetManager
        else { throw AppModelOperationError.unlockedSessionUnavailable }
        let profile = try activeDirectProviderProfile(accountId: accountId)
        guard profile.routeSnapshot == approvedRoute,
              profile.capabilities.contains(.transcription),
              let transcriptionModel = profile.transcriptionModel,
              !transcriptionModel.isEmpty
        else { throw AppModelOperationError.aiProviderRouteChanged }
        let source = try await store.payload(SourcePayload.self, id: sourceId).payload
        guard [.audio, .video].contains(source.sourceType),
              let versionId = source.currentVersionId,
              let version = try? await store.payload(SourceVersionPayload.self, id: versionId).payload,
              let assetId = version.originalAssetId
        else { throw AIJobCoordinatorError.sourceHasNoTranscribableMedia }
        let asset = try await store.payload(AssetPayload.self, id: assetId).payload
        guard asset.plaintextByteSize <= 25 * 1_024 * 1_024 else {
            throw AIJobCoordinatorError.transcriptionMediaTooLarge
        }
        let media = try await assetManager.decryptedData(assetId: assetId)
        let jobId = UUID()
        let approval = ProcessingApproval(
            providerProfileId: profile.id,
            sourceIds: [sourceId, versionId],
            expiresAt: Date().addingTimeInterval(30 * 60)
        )
        let fingerprint = SHA256.hash(data: media)
            .map { String(format: "%02x", $0) }.joined()
        let job = ProcessingJob(
            id: jobId,
            kind: "TRANSCRIPTION",
            inputEntityId: versionId,
            inputFingerprint: fingerprint,
            requiredCapabilities: [.transcription, .hostedProvider],
            selectedRoute: .directProvider,
            approval: approval
        )
        _ = try await database.saveProcessingJob(job)
        _ = try await database.transitionProcessingJob(id: jobId, to: .running, route: .directProvider)
        do {
            let secret = try aiProviderSecretStore.secret(accountId: accountId, profileId: profile.id)
            let response = try await directTranscriptionClient.performTranscription(
                ProviderTranscriptionRequest(
                    audio: media,
                    filename: asset.originalFilename,
                    mimeType: asset.mimeType,
                    language: language
                ),
                route: approvedRoute,
                apiKey: secret
            )
            guard response.segments.count <= 20_000,
                  response.segments.reduce(0, { $0 + $1.text.count }) <= 5_000_000
            else { throw DirectProviderError.invalidResponse }
            var groups: [[TranscriptSegment]] = []
            var current: [TranscriptSegment] = []
            var currentCharacters = 0
            for segment in response.segments {
                if current.count == 500 || currentCharacters + segment.text.count > 200_000 {
                    groups.append(current)
                    current = []
                    currentCharacters = 0
                }
                current.append(segment)
                currentCharacters += segment.text.count
            }
            if !current.isEmpty { groups.append(current) }
            guard groups.count <= 64 else { throw DirectProviderError.invalidResponse }
            var chunkIds: [UUID] = []
            for (index, segments) in groups.enumerated() {
                let id = DirectWorkflowGeneration.artifactId(
                    jobId: jobId,
                    kind: "transcript-chunk-\(index)"
                )
                let chunk = MediaTranscriptionChunk(
                    jobId: jobId,
                    sourceId: sourceId,
                    sourceVersionId: versionId,
                    chunkIndex: index,
                    segments: segments
                )
                _ = try await database.saveLocal(
                    id: id,
                    entityType: .aiArtifact,
                    parentId: sourceId,
                    relationIds: [sourceId, versionId],
                    content: CanonicalJSON.encode(chunk)
                )
                chunkIds.append(id)
            }
            let estimatedCost = profile.transcriptionUSDPerMinute.map {
                max($0, 0) * response.durationSeconds / 60
            }
            let trace = ProviderTrace(
                provider: profile.displayName,
                model: transcriptionModel,
                promptVersion: "media-transcription/v1",
                estimatedCostUsd: estimatedCost,
                providerRequestId: response.providerRequestId
            )
            let manifest = MediaTranscriptionManifest(
                jobId: jobId,
                sourceId: sourceId,
                sourceVersionId: versionId,
                generatedAt: .now,
                language: response.language ?? language,
                durationSeconds: response.durationSeconds,
                characterCount: response.segments.reduce(0) { $0 + $1.text.count },
                segmentCount: response.segments.count,
                trace: trace,
                chunkEntityIds: chunkIds,
                providerRoute: approvedRoute
            )
            let manifestId = DirectWorkflowGeneration.artifactId(jobId: jobId, kind: "transcription")
            _ = try await store.save(
                id: manifestId,
                payload: manifest,
                parentId: sourceId,
                relationIds: [sourceId, versionId] + chunkIds
            )
            _ = try await database.transitionProcessingJob(id: jobId, to: .completed, progress: 1)
            return manifestId
        } catch DirectProviderError.transport {
            _ = try? await database.transitionProcessingJob(
                id: jobId,
                to: .waitingForNetwork,
                errorCode: "PROVIDER_UNREACHABLE"
            )
            throw DirectProviderError.transport
        } catch is CancellationError {
            _ = try? await database.transitionProcessingJob(id: jobId, to: .cancelled)
            throw CancellationError()
        } catch {
            _ = try? await database.transitionProcessingJob(
                id: jobId,
                to: .failed,
                errorCode: "TRANSCRIPTION_FAILED"
            )
            throw error
        }
    }

    @discardableResult
    func generateTutorTurnDirect(
        _ prepared: PreparedTutorTurnRequest
    ) async throws -> UUID {
        guard let coordinator = aiJobs, let store else {
            throw AppModelOperationError.unlockedSessionUnavailable
        }
        let request = try await coordinator.stageTutorTurn(prepared)
        guard let route = request.providerRoute else {
            throw AppModelOperationError.aiProviderUnavailable
        }
        let providerRequest = try DirectWorkflowGeneration.tutorRequest(request)
        let artifactId = try await generateDirectArtifact(
            jobId: request.jobId,
            kind: "TUTOR_TURN",
            inputEntityId: request.tutorSessionId,
            sourceIds: request.sources.map(\.sourceId),
            approximateInputTokens: prepared.approximateTokens,
            approvedRoute: route,
            providerRequest: providerRequest,
            validate: { try DirectWorkflowGeneration.validateTutor($0, request: request) },
            persist: { response, trace, providerRoute in
                let artifact = TutorTurnArtifact(
                    jobId: request.jobId,
                    tutorSessionId: request.tutorSessionId,
                    topicId: request.topicId,
                    sequence: request.sequence,
                    generatedAt: .now,
                    sources: request.sources,
                    sourceExcerptIds: response.citedExcerptIds,
                    sourceIds: Array(Set(request.sources.map(\.sourceId))),
                    sourceVersionIds: Array(Set(request.sources.map(\.sourceVersionId))),
                    trace: trace,
                    providerRoute: providerRoute,
                    response: response
                )
                let id = DirectWorkflowGeneration.artifactId(jobId: request.jobId, kind: "tutor")
                _ = try await store.save(
                    id: id,
                    payload: artifact,
                    parentId: request.tutorSessionId,
                    relationIds: [request.tutorSessionId, request.topicId]
                        + artifact.sourceIds + artifact.sourceVersionIds
                )
                return id
            }
        )
        _ = try await coordinator.importTutorTurnArtifact(artifactId: artifactId)
        noteLocalMutation()
        return artifactId
    }

    func runDueAutomationsDirect(at date: Date = .now) async throws -> [AutomationQueueOutcome] {
        guard let aiJobs else { throw AppModelOperationError.unlockedSessionUnavailable }
        return try await aiJobs.runDueAutomations(at: date) { [weak self] prepared in
            guard let self, let route = prepared.request.providerRoute else {
                throw AppModelOperationError.aiProviderUnavailable
            }
            guard let authorization = prepared.request.automationAuthorization else {
                throw AppModelOperationError.aiProviderUnavailable
            }
            let disclosure = try await self.directTopicStudioDisclosure(
                approximateInputTokens: prepared.approximateTokens,
                jobType: prepared.request.jobType
            )
            guard let maximumCost = disclosure.maximumEstimatedCostUsd else {
                throw AppModelOperationError.automationCostUnavailable
            }
            let maximumMinorUnits = Int(ceil(max(maximumCost, 0) * 100))
            guard (authorization.estimatedSpentMinorUnits ?? 0) + maximumMinorUnits
                    <= authorization.spendingLimitMinorUnits
            else { throw AppModelOperationError.automationBudgetExceeded }
            _ = try await self.generateTopicStudioDirect(prepared, approvedRoute: route)
            return maximumMinorUnits
        }
    }

    /// Runs a reviewed Topic Studio request directly from the iPad. Provider text is decoded and
    /// citation-checked before the encrypted artifact is saved. A schema failure leaves no draft.
    @discardableResult
    func generateTopicStudioDirect(
        _ prepared: PreparedLearningGenerationRequest,
        approvedRoute: AIProviderRouteSnapshot
    ) async throws -> UUID {
        guard let accountId = configuration?.accountId, let database, let store else {
            throw AppModelOperationError.aiProviderUnavailable
        }
        let profile = try activeDirectProviderProfile(accountId: accountId)
        guard profile.routeSnapshot == approvedRoute else {
            throw AppModelOperationError.aiProviderRouteChanged
        }
        var request = prepared.request
        request.disclosureAcknowledged = true
        request.providerRoute = approvedRoute
        let providerRequest = try DirectLearningGeneration.providerRequest(for: request)
        let disclosedCost = try directTopicStudioDisclosure(
            approximateInputTokens: prepared.approximateTokens,
            jobType: request.jobType
        ).maximumEstimatedCostUsd
        let approval = ProcessingApproval(
            providerProfileId: profile.id,
            sourceIds: request.sources.map(\.sourceId),
            maximumCostMinorUnits: disclosedCost.map { Int(ceil(max($0, 0) * 100)) },
            currencyCode: disclosedCost == nil ? nil : "USD",
            expiresAt: Date().addingTimeInterval(30 * 60)
        )
        let fingerprint = SHA256.hash(data: Data(providerRequest.prompt.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let processingJob = ProcessingJob(
            id: request.jobId,
            kind: request.jobType.rawValue,
            inputEntityId: request.topicId,
            inputFingerprint: fingerprint,
            requiredCapabilities: [.hostedProvider],
            selectedRoute: .directProvider,
            approval: approval
        )
        _ = try await database.saveProcessingJob(processingJob)
        _ = try await database.transitionProcessingJob(
            id: processingJob.id,
            to: .running,
            route: .directProvider
        )
        do {
            let secret = try aiProviderSecretStore.secret(
                accountId: accountId,
                profileId: profile.id
            )
            let providerResponse = try await directProviderClient.performText(
                providerRequest,
                route: profile.routeSnapshot,
                apiKey: secret
            )
            let response = try DirectLearningGeneration.validatedResponse(
                from: providerResponse.text,
                request: request
            )
            let estimatedCost: Double?
            if let inputTokens = providerResponse.inputTokens,
               let outputTokens = providerResponse.outputTokens,
               let inputRate = profile.inputUSDPerMillion,
               let outputRate = profile.outputUSDPerMillion {
                estimatedCost =
                    (Double(inputTokens) / 1_000_000 * max(inputRate, 0))
                    + (Double(outputTokens) / 1_000_000 * max(outputRate, 0))
            } else {
                estimatedCost = nil
            }
            let trace = ProviderTrace(
                provider: profile.displayName,
                model: profile.textModel,
                promptVersion: DirectLearningGeneration.promptVersion,
                inputTokens: providerResponse.inputTokens,
                outputTokens: providerResponse.outputTokens,
                estimatedCostUsd: estimatedCost,
                providerRequestId: providerResponse.providerRequestId
            )
            let artifact = try DirectLearningGeneration.artifact(
                request: request,
                response: response,
                trace: trace
            )
            let artifactId = DirectLearningGeneration.artifactId(for: request.jobId)
            _ = try await store.save(
                id: artifactId,
                payload: artifact,
                parentId: request.topicId,
                relationIds: [request.topicId] + artifact.sourceIds
            )
            _ = try await database.transitionProcessingJob(
                id: processingJob.id,
                to: .completed,
                progress: 1
            )
            return artifactId
        } catch DirectProviderError.transport {
            _ = try? await database.transitionProcessingJob(
                id: processingJob.id,
                to: .waitingForNetwork,
                errorCode: "PROVIDER_UNREACHABLE"
            )
            throw DirectProviderError.transport
        } catch is CancellationError {
            _ = try? await database.transitionProcessingJob(
                id: processingJob.id,
                to: .cancelled
            )
            throw CancellationError()
        } catch let error as DirectLearningGenerationError {
            _ = try? await database.transitionProcessingJob(
                id: processingJob.id,
                to: .failed,
                errorCode: "PROVIDER_SCHEMA_INVALID"
            )
            throw error
        } catch {
            _ = try? await database.transitionProcessingJob(
                id: processingJob.id,
                to: .failed,
                errorCode: "PROVIDER_REQUEST_FAILED"
            )
            throw error
        }
    }

    func recognizeFormulaOnDevice(_ request: LocalOCRRequest) async throws -> LocalOCRResponse {
        guard let database else { throw AppModelOperationError.unlockedSessionUnavailable }
        let fingerprint = SHA256.hash(data: Data(request.imageContent.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let job = ProcessingJob(
            id: request.jobId,
            kind: "FORMULA_RECOGNITION",
            inputEntityId: request.targetId,
            inputRevision: request.inputRevision,
            inputFingerprint: fingerprint,
            requiredCapabilities: [.formulaRecognition],
            selectedRoute: .onDevice
        )
        _ = try await database.saveProcessingJob(job)
        _ = try await database.transitionProcessingJob(
            id: job.id,
            to: .running,
            route: .onDevice
        )
        do {
            let response = try await formulaRecognitionEngine.recognize(request)
            _ = try await database.transitionProcessingJob(
                id: job.id,
                to: .completed,
                progress: 1
            )
            return response
        } catch OnDeviceFormulaModelError.manifestUnavailable,
                OnDeviceFormulaModelError.modelUnavailable {
            _ = try? await database.transitionProcessingJob(
                id: job.id,
                to: .waitingForCapability,
                errorCode: "ON_DEVICE_FORMULA_MODEL_UNAVAILABLE"
            )
            throw OnDeviceFormulaModelError.modelUnavailable
        } catch is CancellationError {
            _ = try? await database.transitionProcessingJob(id: job.id, to: .cancelled)
            throw CancellationError()
        } catch {
            _ = try? await database.transitionProcessingJob(
                id: job.id,
                to: .failed,
                errorCode: "FORMULA_RECOGNITION_FAILED"
            )
            throw error
        }
    }

    private func upsert(_ profile: AIProviderProfile, in profiles: inout [AIProviderProfile]) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
    }

    private func activeDirectProviderProfile(accountId: UUID) throws -> AIProviderProfile {
        guard let profile = try aiProviderProfileStore.load(accountId: accountId).first(where: {
            $0.isActive && $0.state == .ready && $0.capabilities.contains(.text)
        }) else { throw AppModelOperationError.aiProviderUnavailable }
        return profile
    }

    #if DEBUG
    /// Creates a raw encrypted development backup. The SQLCipher database and encrypted assets
    /// remain encrypted; the recovery words and account ID are required to use the copy.
    func createEncryptedDevelopmentBackup() async throws -> URL {
        guard !isOpening,
              !isLocking,
              !isCreatingPortableExport,
              !isImportingPortableExport,
              !isCreatingNotePDF
        else { throw AppModelOperationError.unlockedSessionUnavailable }
        if case .ready = phase { try await pendingSaves.flushAll() }
        try? await database?.checkpoint()

        let support = try applicationSupportURL()
        let storedConfiguration: AccountConfiguration?
        if let configuration {
            storedConfiguration = configuration
        } else {
            storedConfiguration = try configurationStore.loadValidated()
        }
        let storage: AccountStorageLocation
        let accountLabel: String
        if let storedConfiguration {
            storage = AccountStorageLocator(applicationSupportURL: support).location(
                for: storedConfiguration.accountId,
                purpose: storagePurpose(for: storedConfiguration)
            )
            accountLabel = storedConfiguration.accountId.uuidString.lowercased()
        } else {
            storage = AccountStorageLocation(directoryURL: support)
            accountLabel = "unconfigured-legacy"
        }
        guard FileManager.default.fileExists(atPath: storage.databaseURL.path) else {
            throw AppModelOperationError.unlockedSessionUnavailable
        }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Epistoria-\(accountLabel)-\(UUID().uuidString).epistoria-encrypted-backup",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            try FileManager.default.copyItem(
                at: storage.databaseURL,
                to: destination.appendingPathComponent("epistoria.sqlite")
            )
            for suffix in ["-wal", "-shm"] {
                let source = URL(fileURLWithPath: storage.databaseURL.path + suffix)
                if FileManager.default.fileExists(atPath: source.path) {
                    try FileManager.default.copyItem(
                        at: source,
                        to: destination.appendingPathComponent("epistoria.sqlite\(suffix)")
                    )
                }
            }
            if FileManager.default.fileExists(atPath: storage.assetsDirectoryURL.path) {
                try FileManager.default.copyItem(
                    at: storage.assetsDirectoryURL,
                    to: destination.appendingPathComponent("Assets", isDirectory: true)
                )
            }
            let manifest: [String: String] = [
                "schemaVersion": "epistoria-encrypted-development-backup/v1",
                "accountId": accountLabel,
                "createdAt": RFC3339Milliseconds.string(from: .now),
                "encryption": "SQLCipher database and Epistoria encrypted assets",
            ]
            let manifestData = try JSONSerialization.data(
                withJSONObject: manifest,
                options: [.sortedKeys, .prettyPrinted]
            )
            try manifestData.write(
                to: destination.appendingPathComponent("manifest.json"),
                options: [.atomic, .completeFileProtection]
            )
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Permanently removes the local development copy after a separate typed confirmation in the
    /// interface. This method is not compiled into release builds and never contacts the server.
    func deleteLocalDevelopmentNotebook() async throws {
        guard !isOpening,
              !isLocking,
              !isCreatingPortableExport,
              !isImportingPortableExport,
              !isCreatingNotePDF
        else { throw AppModelOperationError.unlockedSessionUnavailable }
        var storedConfiguration = try configurationStore.loadValidated()
        if let unresolved = storedConfiguration, unresolved.storageScope == nil {
            let resolved = try resolvedStorageConfiguration(
                unresolved,
                purpose: .existingWithLegacyFallback
            )
            try configurationStore.save(resolved)
            storedConfiguration = resolved
        }
        let support = try applicationSupportURL()
        let resetter = DevelopmentNotebookStorageResetter(applicationSupportURL: support)

        await tearDown(nextPhase: .onboarding, honorDeferredRestart: false)
        if let storedConfiguration {
            try resetter.removeConfiguredStorage(
                accountId: storedConfiguration.accountId,
                purpose: storagePurpose(for: storedConfiguration)
            )
            try tokenStore.delete(deviceId: storedConfiguration.deviceId)
            try accountKeyStore.deleteAccountKey(accountId: storedConfiguration.accountId)
        } else {
            try resetter.removeLegacyStorage()
        }
        configurationStore.clearForDevelopment()
        configuration = nil
        phase = .onboarding
    }
    #endif

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
        let providerRoute = activeProviderRouteState(accountId: configuration.accountId)
        let nextAIJobs = AIJobCoordinator(
            accountId: configuration.accountId,
            accountKey: accountKey,
            store: store,
            api: client,
            providerRouteSnapshot: providerRoute.snapshot,
            requiresProviderRouteSnapshot: providerRoute.required
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

    func preparePortableImport(from url: URL) async throws -> EpistoriaImportPlan {
        guard !isCreatingPortableExport,
              !isImportingPortableExport,
              !isCreatingNotePDF,
              !isReconfiguringSync,
              !isLocking,
              case .ready = phase,
              let configuration,
              let accountKey,
              let database,
              let store,
              let assetManager
        else { throw AppModelOperationError.unlockedSessionUnavailable }
        isImportingPortableExport = true
        let generation = sessionGeneration
        automaticSyncTask?.cancel()
        automaticSyncTask = nil
        automaticSyncToken = nil
        syncRequestedWhileRunning = false
        if let syncAttemptTask { _ = await syncAttemptTask.result }
        guard generation == sessionGeneration, !isLocking, case .ready = phase else {
            isImportingPortableExport = false
            throw CancellationError()
        }
        do {
            try await pendingSaves.flushAll()
            let support = try applicationSupportURL()
            let storage = AccountStorageLocator(applicationSupportURL: support).location(
                for: configuration.accountId,
                purpose: storagePurpose(for: configuration)
            )
            let service = EpistoriaPortableImportService(
                accountId: configuration.accountId,
                accountKey: accountKey,
                database: database,
                store: store,
                assetManager: assetManager,
                assetsDirectory: storage.assetsDirectoryURL
            )
            portableImportService = service
            let plan = try await service.prepare(from: url)
            guard generation == sessionGeneration, !isLocking, case .ready = phase else {
                try? await service.cancel(plan)
                throw CancellationError()
            }
            pendingPortableImportPlan = plan
            return plan
        } catch {
            portableImportService = nil
            pendingPortableImportPlan = nil
            isImportingPortableExport = false
            resumeSyncSchedulingIfNeeded()
            throw error
        }
    }

    func commitPortableImport(_ plan: EpistoriaImportPlan) async throws -> EpistoriaImportResult {
        guard isImportingPortableExport,
              let service = portableImportService,
              case .ready = phase,
              !isLocking
        else { throw AppModelOperationError.unlockedSessionUnavailable }
        defer {
            portableImportService = nil
            pendingPortableImportPlan = nil
            isImportingPortableExport = false
            resumeSyncSchedulingIfNeeded()
        }
        let result = try await service.commit(plan)
        try? await store?.rebuildRecognitionSearchProjections()
        await refreshDataHealth()
        noteLocalMutation()
        return result
    }

    func cancelPortableImport(_ plan: EpistoriaImportPlan) async {
        if let service = portableImportService { try? await service.cancel(plan) }
        portableImportService = nil
        pendingPortableImportPlan = nil
        isImportingPortableExport = false
        resumeSyncSchedulingIfNeeded()
    }

    func createPortableExport(includingDerivedAI: Bool) async throws -> EpistoriaExportResult {
        guard !isCreatingPortableExport,
              !isImportingPortableExport,
              !isCreatingNotePDF,
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

    func createNotePDF(
        noteId: UUID,
        options: NotePDFExportOptions = .allPages
    ) async throws -> NotePDFExportResult {
        guard !isCreatingPortableExport,
              !isImportingPortableExport,
              !isCreatingNotePDF,
              !isReconfiguringSync,
              !isLocking,
              case .ready = phase,
              let store,
              let assetManager
        else { throw AppModelOperationError.unlockedSessionUnavailable }
        isCreatingNotePDF = true
        let generation = sessionGeneration
        defer {
            if generation == sessionGeneration {
                notePDFExportTask = nil
                isCreatingNotePDF = false
                resumeSyncSchedulingIfNeeded()
            }
        }
        automaticSyncTask?.cancel()
        automaticSyncTask = nil
        automaticSyncToken = nil
        syncRequestedWhileRunning = false
        if let syncAttemptTask { _ = await syncAttemptTask.result }
        guard generation == sessionGeneration, !isLocking, case .ready = phase else {
            isCreatingNotePDF = false
            throw CancellationError()
        }
        try await pendingSaves.flushAll()

        let service = NotePDFExportService(store: store, assetManager: assetManager)
        let task = Task { try await service.export(noteId: noteId, options: options) }
        notePDFExportTask = task
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
        scheduleProactiveAutomation(delay: .seconds(10))
        scheduleSemanticIndexing(delay: .seconds(2))
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
        guard !isCreatingPortableExport,
              !isImportingPortableExport,
              !isCreatingNotePDF,
              !isReconfiguringSync
        else { return }
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
                try? await store?.rebuildRecognitionSearchProjections()
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
        guard syncEngine != nil,
              !isCreatingPortableExport,
              !isImportingPortableExport,
              !isCreatingNotePDF,
              !isReconfiguringSync
        else { return }
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
        try? ProtectedVideoFileStore.removeAllTemporaryFiles()
        let generation = sessionGeneration
        do {
            try await pendingSaves.flushAll()
            pendingSaveWarning = nil
        } catch {
            pendingSaveWarning = "A recent edit is still waiting for a safe local write. Free storage if needed; Epistoria will keep retrying."
        }
        await drainSharedCaptureInbox()
        await refreshDataHealth()
        guard generation == sessionGeneration, !isLocking, case .ready = phase else { return }
        if let pendingSaveWarning { syncError = pendingSaveWarning }
        resumeSyncSchedulingIfNeeded()
        scheduleProactiveAutomation()
        scheduleSemanticIndexing(delay: .zero)
    }

    func drainSharedCaptureInbox() async {
        guard let sharedCaptureImporter, let store, let assetManager,
              sharedCaptureImportTask == nil,
              !isLocking, case .ready = phase
        else { return }
        let generation = sessionGeneration
        let task = Task {
            await sharedCaptureImporter.drain(store: store, assetManager: assetManager)
        }
        sharedCaptureImportTask = task
        let report = await task.value
        sharedCaptureImportTask = nil
        guard generation == sessionGeneration, !isLocking, case .ready = phase else { return }
        pendingSharedCaptureCount = report.remainingPendingCount
        failedSharedCaptureCount = report.failedCount
        if report.importedCount > 0 {
            let noun = report.importedCount == 1 ? "item" : "items"
            sharedCaptureImportMessage = "Imported \(report.importedCount) shared \(noun) into Source Inbox."
            sharedCaptureImportRevision &+= 1
            noteLocalMutation()
        }
        if report.failedCount > 0 {
            let detail = report.firstFailureDescription.map { " \($0)" } ?? ""
            sharedCaptureFailureMessage = "\(report.failedCount) encrypted capture\(report.failedCount == 1 ? "" : "s") could not be imported.\(detail)"
        } else {
            sharedCaptureFailureMessage = nil
        }
    }

    func retryFailedSharedCaptures() async {
        guard let sharedCaptureImporter else { return }
        do {
            try sharedCaptureImporter.retryFailed()
            sharedCaptureFailureMessage = nil
            await drainSharedCaptureInbox()
        } catch {
            sharedCaptureFailureMessage = error.localizedDescription
        }
    }

    func discardFailedSharedCaptures() {
        guard let sharedCaptureImporter else { return }
        do {
            try sharedCaptureImporter.discardFailed()
            let counts = sharedCaptureImporter.counts()
            pendingSharedCaptureCount = counts.pending
            failedSharedCaptureCount = counts.failed
            sharedCaptureFailureMessage = nil
        } catch {
            sharedCaptureFailureMessage = error.localizedDescription
        }
    }

    private func scheduleSemanticIndexing(delay: Duration) {
        semanticIndexTask?.cancel()
        guard let database, !isLocking, case .ready = phase else { return }
        semanticIndexTask = Task(priority: .utility) {
            do { try await Task.sleep(for: delay) }
            catch { return }
            while !Task.isCancelled {
                let indexed: Int
                do {
                    indexed = try await database.rebuildSemanticSearchIndex(batchLimit: 48)
                } catch {
                    // This index is local and disposable. Exact search remains available.
                    return
                }
                guard indexed == 48 else { return }
                do { try await Task.sleep(for: .milliseconds(50)) }
                catch { return }
            }
        }
    }

    private func startPeriodicSync() {
        periodicSyncTask?.cancel()
        periodicSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(300)) }
                catch { return }
                guard !Task.isCancelled, let self else { return }
                await self.synchronize(reportMissingServer: false)
                await self.runProactiveAutomation(reportErrors: false)
            }
        }
    }

    private func scheduleProactiveAutomation(delay: Duration = .seconds(5)) {
        guard aiJobs != nil, !isLocking, case .ready = phase else { return }
        proactiveAutomationTask?.cancel()
        let generation = sessionGeneration
        proactiveAutomationTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) }
            catch { return }
            guard !Task.isCancelled, let self, generation == self.sessionGeneration else { return }
            await self.runProactiveAutomation(reportErrors: false)
        }
    }

    private func runProactiveAutomation(reportErrors: Bool) async {
        guard !isLocking, case .ready = phase, aiJobs != nil else { return }
        do {
            let outcomes = try await runDueAutomationsDirect()
            if outcomes.contains(where: {
                if case .queued = $0 { return true }
                return false
            }) {
                noteLocalMutation()
            }
        } catch where reportErrors {
            syncError = "Automatic processing paused safely. \(error.localizedDescription)"
        } catch {
            // Automatic processing is optional. A failure must not interrupt local notebook use.
        }
    }

    private func quiesceSyncForReconfiguration() async {
        automaticSyncTask?.cancel()
        automaticSyncTask = nil
        automaticSyncToken = nil
        periodicSyncTask?.cancel()
        periodicSyncTask = nil
        proactiveAutomationTask?.cancel()
        proactiveAutomationTask = nil
        semanticIndexTask?.cancel()
        semanticIndexTask = nil
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
              !isImportingPortableExport,
              !isCreatingNotePDF,
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

    func removeComputeNode(id: UUID) async throws {
        try await revokeTrustedDevice(id: id)
        _ = try await database?.rerouteJobs(fromComputeNode: id)
    }

    private func open(
        configuration: AccountConfiguration,
        key: Data,
        generation: UInt64,
        storagePurpose: AccountStoragePurpose
    ) async throws {
        let support = try applicationSupportURL()
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let storage = AccountStorageLocator(applicationSupportURL: support).location(
            for: configuration.accountId,
            purpose: storagePurpose
        )
        let database = try SQLCipherDatabase(
            url: storage.databaseURL,
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
            directory: storage.assetsDirectoryURL
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
                    let providerRoute = activeProviderRouteState(accountId: configuration.accountId)
                    openedAIJobs = AIJobCoordinator(
                        accountId: configuration.accountId,
                        accountKey: key,
                        store: store,
                        api: api,
                        providerRouteSnapshot: providerRoute.snapshot,
                        requiresProviderRouteSnapshot: providerRoute.required
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

    private func applicationSupportURL() throws -> URL {
        if let applicationSupportOverride { return applicationSupportOverride }
        return try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Epistoria", isDirectory: true)
    }

    private func storagePurpose(
        for configuration: AccountConfiguration
    ) -> AccountStoragePurpose {
        switch configuration.storageScope {
        case .accountScoped:
            .accountScoped
        case .legacyShared:
            .legacyShared
        case nil:
            .existingWithLegacyFallback
        }
    }

    private func resolvedStorageConfiguration(
        _ configuration: AccountConfiguration,
        purpose: AccountStoragePurpose
    ) throws -> AccountConfiguration {
        guard configuration.storageScope == nil else { return configuration }
        let support = try applicationSupportURL()
        let location = AccountStorageLocator(applicationSupportURL: support).location(
            for: configuration.accountId,
            purpose: purpose
        )
        var resolved = configuration
        resolved.storageScope = location.directoryURL.standardizedFileURL
            == support.standardizedFileURL ? .legacyShared : .accountScoped
        return resolved
    }

    private func persistResolvedStorageScopeIfNeeded(
        _ configuration: AccountConfiguration,
        purpose: AccountStoragePurpose
    ) throws {
        let resolved = try resolvedStorageConfiguration(configuration, purpose: purpose)
        guard resolved != configuration else { return }
        try configurationStore.save(resolved)
        self.configuration = resolved
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
