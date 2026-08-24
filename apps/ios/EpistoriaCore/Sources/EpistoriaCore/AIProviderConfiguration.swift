import Foundation

public enum AIProviderAdapter: String, Codable, CaseIterable, Sendable {
    case openAIResponses = "OPENAI_RESPONSES"
    case openAICompatible = "OPENAI_COMPATIBLE"
}

public enum AIProviderCapability: String, Codable, CaseIterable, Sendable {
    case text = "TEXT"
    case vision = "VISION"
    case transcription = "TRANSCRIPTION"
    case structuredOutput = "STRUCTURED_OUTPUT"
}

public enum AIProviderConfigurationOperation: String, Codable, Sendable {
    case upsert = "UPSERT"
    case activate = "ACTIVATE"
    case delete = "DELETE"
}

/// The non-secret provider route reviewed when an AI job is approved.
///
/// This value is encrypted inside the job payload. The trusted Mac verifies it against the
/// matching Keychain profile before sending any content. API keys are never part of this value.
public struct AIProviderRouteSnapshot: Codable, Equatable, Sendable {
    public var schemaVersion = "provider-route/v1"
    public var profileId: UUID
    public var configurationRevisionId: UUID
    public var displayName: String
    public var adapter: AIProviderAdapter
    public var baseURL: String
    public var textModel: String
    public var transcriptionModel: String?
    public var capabilities: [AIProviderCapability]
    public var structuredOutput: Bool

    public init(
        profileId: UUID,
        configurationRevisionId: UUID,
        displayName: String,
        adapter: AIProviderAdapter,
        baseURL: String,
        textModel: String,
        transcriptionModel: String?,
        capabilities: [AIProviderCapability],
        structuredOutput: Bool
    ) {
        self.profileId = profileId
        self.configurationRevisionId = configurationRevisionId
        self.displayName = displayName
        self.adapter = adapter
        self.baseURL = baseURL
        self.textModel = textModel
        self.transcriptionModel = transcriptionModel
        self.capabilities = Array(Set(capabilities)).sorted { $0.rawValue < $1.rawValue }
        self.structuredOutput = structuredOutput
    }
}

public struct AIProviderConfigurationRequest: Codable, Equatable, Sendable {
    public var schemaVersion = "provider-configuration-request/v1"
    public var accountId: UUID
    public var jobId: UUID
    public var operation: AIProviderConfigurationOperation
    public var profileId: UUID
    public var configurationRevisionId: UUID?
    public var displayName: String?
    public var adapter: AIProviderAdapter?
    public var baseURL: String?
    public var apiKey: String?
    public var textModel: String?
    public var transcriptionModel: String?
    public var capabilities: [AIProviderCapability]
    public var structuredOutput: Bool
    public var inputUSDPerMillion: Double?
    public var outputUSDPerMillion: Double?
    public var transcriptionUSDPerMinute: Double?
    public var makeActive: Bool
    public var disclosureAcknowledged: Bool

    public init(
        accountId: UUID,
        jobId: UUID = UUID(),
        operation: AIProviderConfigurationOperation,
        profileId: UUID,
        configurationRevisionId: UUID? = nil,
        displayName: String? = nil,
        adapter: AIProviderAdapter? = nil,
        baseURL: String? = nil,
        apiKey: String? = nil,
        textModel: String? = nil,
        transcriptionModel: String? = nil,
        capabilities: [AIProviderCapability] = [],
        structuredOutput: Bool = true,
        inputUSDPerMillion: Double? = nil,
        outputUSDPerMillion: Double? = nil,
        transcriptionUSDPerMinute: Double? = nil,
        makeActive: Bool = false,
        disclosureAcknowledged: Bool = true
    ) {
        self.accountId = accountId
        self.jobId = jobId
        self.operation = operation
        self.profileId = profileId
        self.configurationRevisionId = configurationRevisionId
        self.displayName = displayName
        self.adapter = adapter
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.textModel = textModel
        self.transcriptionModel = transcriptionModel
        self.capabilities = Array(Set(capabilities)).sorted { $0.rawValue < $1.rawValue }
        self.structuredOutput = structuredOutput
        self.inputUSDPerMillion = inputUSDPerMillion
        self.outputUSDPerMillion = outputUSDPerMillion
        self.transcriptionUSDPerMinute = transcriptionUSDPerMinute
        self.makeActive = makeActive
        self.disclosureAcknowledged = disclosureAcknowledged
    }
}

public struct AIProviderConfigurationArtifact: EntityPayload, Equatable {
    public static let entityType = EntityType.aiArtifact
    public var schemaVersion = "ai-artifact/provider-configuration/v1"
    public var jobId: UUID
    public var profileId: UUID
    public var configurationRevisionId: UUID?
    public var operation: AIProviderConfigurationOperation
    public var displayName: String?
    public var adapter: AIProviderAdapter?
    public var baseURL: String?
    public var textModel: String?
    public var transcriptionModel: String?
    public var capabilities: [AIProviderCapability]
    public var isActive: Bool
    public var secretStored: Bool
    public var configuredAt: Date

    public var createdAt: Date { configuredAt }
    public var updatedAt: Date { configuredAt }
}

public extension AIJobCoordinator {
    func submitProviderConfiguration(
        _ request: AIProviderConfigurationRequest
    ) async throws -> AIJobSummary {
        guard request.accountId == accountId,
              request.disclosureAcknowledged,
              request.schemaVersion == "provider-configuration-request/v1"
        else { throw AIJobCoordinatorError.disclosureNotAcknowledged }
        let envelope = try EntityCrypto().encryptJob(
            CanonicalJSON.encode(request),
            accountKey: accountKey,
            accountId: accountId,
            jobType: "PROVIDER_CONFIGURATION",
            jobId: request.jobId
        )
        return try await api.createAIJob(
            id: request.jobId,
            type: "PROVIDER_CONFIGURATION",
            envelope: envelope
        )
    }
}
