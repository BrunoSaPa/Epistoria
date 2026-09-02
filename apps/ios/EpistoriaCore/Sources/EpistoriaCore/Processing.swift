import Foundation

public enum ProcessingJobState: String, Codable, CaseIterable, Sendable {
    case queued = "QUEUED"
    case running = "RUNNING"
    case paused = "PAUSED"
    case waitingForCapability = "WAITING_FOR_CAPABILITY"
    case waitingForNetwork = "WAITING_FOR_NETWORK"
    case completed = "COMPLETED"
    case failed = "FAILED"
    case cancelled = "CANCELLED"

    public var isTerminal: Bool {
        self == .completed || self == .failed || self == .cancelled
    }
}

public enum ProcessingRoute: String, Codable, CaseIterable, Sendable {
    case onDevice = "ON_DEVICE"
    case directProvider = "DIRECT_PROVIDER"
    case computeNode = "COMPUTE_NODE"
}

public enum ProcessingRoutePreferenceMode: String, Codable, CaseIterable, Sendable {
    case ipadFirst = "IPAD_FIRST"
    case preferComputeNodeForHeavyWork = "PREFER_COMPUTE_NODE_FOR_HEAVY_WORK"
}

/// Device-local routing policy. It never contains provider credentials or notebook content.
public struct ProcessingRoutePreference: Codable, Equatable, Sendable {
    public var mode: ProcessingRoutePreferenceMode
    public var computeNodeCapabilities: Set<ProcessingCapability>

    public init(
        mode: ProcessingRoutePreferenceMode = .ipadFirst,
        computeNodeCapabilities: Set<ProcessingCapability> = [
            .transcription, .officeConversion, .formulaRecognition, .localProvider,
        ]
    ) {
        self.mode = mode
        self.computeNodeCapabilities = computeNodeCapabilities
    }

    public func orderedRoutes(for required: Set<ProcessingCapability>) -> [ProcessingRoute] {
        guard mode == .preferComputeNodeForHeavyWork,
              !required.isDisjoint(with: computeNodeCapabilities)
        else { return [.onDevice, .directProvider, .computeNode] }
        return [.computeNode, .onDevice, .directProvider]
    }
}

public enum ProcessingCapability: String, Codable, CaseIterable, Sendable {
    case textRecognition = "recognition.text"
    case formulaRecognition = "recognition.formula"
    case sourceExtraction = "source.extraction"
    case transcription = "transcription"
    case hostedProvider = "provider.hosted"
    case localProvider = "provider.local"
    case officeConversion = "document-conversion.office"
}

public struct ProcessingApproval: Codable, Equatable, Sendable {
    public var providerProfileId: UUID?
    public var sourceIds: [UUID]
    public var maximumCostMinorUnits: Int?
    public var currencyCode: String?
    public var approvedAt: Date
    public var expiresAt: Date?

    public init(
        providerProfileId: UUID? = nil,
        sourceIds: [UUID] = [],
        maximumCostMinorUnits: Int? = nil,
        currencyCode: String? = nil,
        approvedAt: Date = .now,
        expiresAt: Date? = nil
    ) {
        self.providerProfileId = providerProfileId
        self.sourceIds = Array(Set(sourceIds)).sorted { $0.uuidString < $1.uuidString }
        self.maximumCostMinorUnits = maximumCostMinorUnits.map { max($0, 0) }
        self.currencyCode = currencyCode.map { String($0.uppercased().prefix(8)) }
        self.approvedAt = approvedAt
        self.expiresAt = expiresAt
    }

    public func isValid(at date: Date = .now) -> Bool {
        expiresAt.map { date < $0 } ?? true
    }
}

/// Durable, local-only work state. Inputs and results remain in their authoritative encrypted
/// entities; this record contains only bounded routing metadata and opaque fingerprints.
public struct ProcessingJob: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: String
    public var state: ProcessingJobState
    public var inputEntityId: UUID?
    public var inputRevision: Int?
    public var inputFingerprint: String
    public var requiredCapabilities: [ProcessingCapability]
    public var selectedRoute: ProcessingRoute?
    public var computeNodeId: UUID?
    public var approval: ProcessingApproval?
    public var attemptCount: Int
    public var progress: Double?
    public var errorCode: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        kind: String,
        state: ProcessingJobState = .queued,
        inputEntityId: UUID? = nil,
        inputRevision: Int? = nil,
        inputFingerprint: String,
        requiredCapabilities: [ProcessingCapability],
        selectedRoute: ProcessingRoute? = nil,
        computeNodeId: UUID? = nil,
        approval: ProcessingApproval? = nil,
        attemptCount: Int = 0,
        progress: Double? = nil,
        errorCode: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.kind = String(kind.prefix(128))
        self.state = state
        self.inputEntityId = inputEntityId
        self.inputRevision = inputRevision.map { max($0, 0) }
        self.inputFingerprint = String(inputFingerprint.prefix(256))
        self.requiredCapabilities = Array(Set(requiredCapabilities)).sorted { $0.rawValue < $1.rawValue }
        self.selectedRoute = selectedRoute
        self.computeNodeId = computeNodeId
        self.approval = approval
        self.attemptCount = max(attemptCount, 0)
        self.progress = progress.map { min(max($0.isFinite ? $0 : 0, 0), 1) }
        self.errorCode = errorCode.map { String($0.prefix(128)) }
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ProcessingRouteAvailability: Equatable, Sendable {
    public var route: ProcessingRoute
    public var capabilities: Set<ProcessingCapability>
    public var isAvailable: Bool

    public init(
        route: ProcessingRoute,
        capabilities: Set<ProcessingCapability>,
        isAvailable: Bool = true
    ) {
        self.route = route
        self.capabilities = capabilities
        self.isAvailable = isAvailable
    }
}

public protocol ProcessingRouting: Sendable {
    func route(
        requiredCapabilities: Set<ProcessingCapability>,
        approval: ProcessingApproval?,
        availability: [ProcessingRouteAvailability]
    ) -> ProcessingRoute?
}

public struct ProcessingRouter: ProcessingRouting, Sendable {
    public init() {}

    public func route(
        requiredCapabilities: Set<ProcessingCapability>,
        approval: ProcessingApproval?,
        availability: [ProcessingRouteAvailability]
    ) -> ProcessingRoute? {
        route(
            requiredCapabilities: requiredCapabilities,
            approval: approval,
            availability: availability,
            preference: ProcessingRoutePreference()
        )
    }

    public func route(
        requiredCapabilities: Set<ProcessingCapability>,
        approval: ProcessingApproval?,
        availability: [ProcessingRouteAvailability],
        preference: ProcessingRoutePreference
    ) -> ProcessingRoute? {
        let byRoute = Dictionary(uniqueKeysWithValues: availability.map { ($0.route, $0) })
        for candidate in preference.orderedRoutes(for: requiredCapabilities) {
            guard let value = byRoute[candidate], value.isAvailable,
                  requiredCapabilities.isSubset(of: value.capabilities)
            else { continue }
            if candidate == .directProvider,
               !(approval?.isValid() ?? false) {
                continue
            }
            return candidate
        }
        return nil
    }
}

public protocol RecognitionEngine: Sendable {
    var capabilities: Set<ProcessingCapability> { get }
    func recognize(_ request: LocalOCRRequest) async throws -> LocalOCRResponse
}

public protocol FormulaRecognitionEngine: RecognitionEngine {}

public protocol TranscriptionEngine: Sendable {
    func transcribe(audio: Data, languages: [String]) async throws -> Data
}

public protocol SourceExtractionEngine: Sendable {
    func extract(source: Data, mimeType: String) async throws -> Data
}

public struct ProviderImageInput: Codable, Equatable, Sendable {
    public var mimeType: String
    public var data: Data

    public init(mimeType: String, data: Data) {
        self.mimeType = mimeType
        self.data = data
    }
}

public struct ProviderTextRequest: Codable, Equatable, Sendable {
    public var prompt: String
    public var systemInstructions: String?
    public var maximumOutputTokens: Int
    public var images: [ProviderImageInput]

    public init(
        prompt: String,
        systemInstructions: String? = nil,
        maximumOutputTokens: Int = 2_048,
        images: [ProviderImageInput] = []
    ) {
        self.prompt = prompt
        self.systemInstructions = systemInstructions
        self.maximumOutputTokens = min(max(maximumOutputTokens, 1), 32_768)
        self.images = Array(images.prefix(12))
    }
}

public struct ProviderTextResponse: Codable, Equatable, Sendable {
    public var text: String
    public var providerRequestId: String?
    public var inputTokens: Int?
    public var outputTokens: Int?

    public init(
        text: String,
        providerRequestId: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil
    ) {
        self.text = text
        self.providerRequestId = providerRequestId.map { String($0.prefix(256)) }
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public protocol ProviderClient: Sendable {
    func performText(
        _ request: ProviderTextRequest,
        route: AIProviderRouteSnapshot,
        apiKey: String?
    ) async throws -> ProviderTextResponse

    func testConnection(
        route: AIProviderRouteSnapshot,
        apiKey: String?
    ) async throws -> ProviderConnectionResult
}

public struct ProviderConnectionResult: Equatable, Sendable {
    public var elapsedMilliseconds: Int
    public var verifiedModel: String

    public init(elapsedMilliseconds: Int, verifiedModel: String) {
        self.elapsedMilliseconds = max(elapsedMilliseconds, 0)
        self.verifiedModel = String(verifiedModel.prefix(200))
    }
}

public extension ProviderClient {
    func testConnection(
        route: AIProviderRouteSnapshot,
        apiKey: String?
    ) async throws -> ProviderConnectionResult {
        let startedAt = Date()
        let prompt = route.structuredOutput
            ? #"Return exactly this JSON object and nothing else: {"status":"ok"}"#
            : "Reply with OK and nothing else."
        _ = try await performText(
            ProviderTextRequest(prompt: prompt, maximumOutputTokens: 24),
            route: route,
            apiKey: apiKey
        )
        return ProviderConnectionResult(
            elapsedMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1_000),
            verifiedModel: route.textModel
        )
    }
}

public struct ProviderTranscriptionRequest: Equatable, Sendable {
    public var audio: Data
    public var filename: String
    public var mimeType: String
    public var language: String?

    public init(audio: Data, filename: String, mimeType: String, language: String? = nil) {
        self.audio = audio
        self.filename = String(filename.prefix(255))
        self.mimeType = String(mimeType.prefix(128))
        self.language = language.map { String($0.prefix(32)) }
    }
}

public struct ProviderTranscriptionResponse: Codable, Equatable, Sendable {
    public var text: String
    public var language: String?
    public var durationSeconds: Double
    public var segments: [TranscriptSegment]
    public var providerRequestId: String?

    public init(
        text: String,
        language: String?,
        durationSeconds: Double,
        segments: [TranscriptSegment],
        providerRequestId: String? = nil
    ) {
        self.text = text
        self.language = language
        self.durationSeconds = durationSeconds
        self.segments = segments
        self.providerRequestId = providerRequestId
    }
}

public protocol ProviderTranscriptionClient: Sendable {
    func performTranscription(
        _ request: ProviderTranscriptionRequest,
        route: AIProviderRouteSnapshot,
        apiKey: String?
    ) async throws -> ProviderTranscriptionResponse
}

public struct ComputeNodeDescriptor: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var displayName: String
    public var capabilities: [String]
    public var lastSeenAt: Date?
    public var isPaused: Bool

    public init(
        id: UUID,
        displayName: String,
        capabilities: [String],
        lastSeenAt: Date? = nil,
        isPaused: Bool = false
    ) {
        self.id = id
        self.displayName = String(displayName.prefix(120))
        self.capabilities = Array(Set(capabilities.map { String($0.prefix(128)) })).sorted()
        self.lastSeenAt = lastSeenAt
        self.isPaused = isPaused
    }
}

public protocol ComputeNodeClient: Sendable {
    func availableNodes() async throws -> [ComputeNodeDescriptor]
    func submit(jobId: UUID, encryptedEnvelope: Data, to nodeId: UUID) async throws
    func revoke(nodeId: UUID) async throws
}
