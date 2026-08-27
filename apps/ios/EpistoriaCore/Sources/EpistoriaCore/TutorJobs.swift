import Foundation

public enum TutorTurnAction: String, Codable, CaseIterable, Sendable {
    case begin = "BEGIN"
    case answer = "ANSWER"
    case hint = "HINT"
    case explainDirectly = "EXPLAIN_DIRECTLY"
    case tryAnotherExample = "TRY_ANOTHER_EXAMPLE"
    case whyNext = "WHY_NEXT"
    case end = "END"
}

public struct TutorSourceExcerpt: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID { excerptId }
    public var excerptId: UUID
    public var sourceId: UUID
    public var sourceVersionId: UUID
    public var evidenceId: UUID?
    public var title: String
    public var locator: SourceLocator
    public var excerpt: String

    public init(
        excerptId: UUID = UUID(),
        sourceId: UUID,
        sourceVersionId: UUID,
        evidenceId: UUID? = nil,
        title: String,
        locator: SourceLocator,
        excerpt: String
    ) {
        self.excerptId = excerptId
        self.sourceId = sourceId
        self.sourceVersionId = sourceVersionId
        self.evidenceId = evidenceId
        self.title = title
        self.locator = locator
        self.excerpt = excerpt
    }
}

public struct TutorTranscriptExcerpt: Codable, Equatable, Sendable {
    public var turnId: UUID
    public var sequence: Int
    public var role: TutorTurnRole
    public var kind: TutorTurnKind
    public var text: String
    public var confidence: Int?
}

public struct TutorLearningHistoryExcerpt: Codable, Equatable, Sendable {
    public var objective: String
    public var assessmentKind: LearningAssessmentKind
    public var outcome: LearningSignalOutcome
    public var confidence: Int?
    public var observedAt: Date
}

public struct TutorSessionAuthorization: Codable, Equatable, Sendable {
    public var schemaVersion = "tutor-session-authorization/v1"
    public var tutorSessionId: UUID
    public var topicId: UUID
    public var sourceVersionIds: [UUID]
    public var includeConnectedKnowledge: Bool
    public var maximumTurns: Int
    public var approvedTurnCount: Int
    public var spendingLimitMinorUnits: Int
    public var estimatedSpentMinorUnits: Int
    public var currencyCode: String
    public var expiresAt: Date
    public var approvedAt: Date
}

public struct TutorTurnRequest: Codable, Equatable, Sendable {
    public var schemaVersion = "tutor-turn-request/v1"
    public var accountId: UUID
    public var jobId: UUID
    public var tutorSessionId: UUID
    public var topicId: UUID
    public var sequence: Int
    public var action: TutorTurnAction
    public var objective: String
    public var guidanceStyle: TutorGuidanceStyle
    public var learnerMessage: String?
    public var learnerConfidence: Int?
    public var recommendedTurnKind: TutorTurnKind
    public var recommendationReason: String
    public var conversationSummary: String?
    public var recentTranscript: [TutorTranscriptExcerpt]
    public var learningHistory: [TutorLearningHistoryExcerpt]
    public var sources: [TutorSourceExcerpt]
    public var authorization: TutorSessionAuthorization
    public var disclosureAcknowledged: Bool
    public var providerRoute: AIProviderRouteSnapshot?
}

public struct TutorSignalDraft: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var objective: String
    public var assessmentKind: LearningAssessmentKind
    public var outcome: LearningSignalOutcome
    public var confidence: Int?
    public var rationale: String
    public var citedExcerptIds: [UUID]

    public init(
        id: UUID = UUID(),
        objective: String,
        assessmentKind: LearningAssessmentKind,
        outcome: LearningSignalOutcome,
        confidence: Int? = nil,
        rationale: String,
        citedExcerptIds: [UUID] = []
    ) {
        self.id = id
        self.objective = objective
        self.assessmentKind = assessmentKind
        self.outcome = outcome
        self.confidence = confidence
        self.rationale = rationale
        self.citedExcerptIds = citedExcerptIds
    }
}

public struct TutorTurnResponse: Codable, Equatable, Sendable {
    public var schemaVersion = "tutor-turn-response/v1"
    public var message: String
    public var kind: TutorTurnKind
    public var citedExcerptIds: [UUID]
    public var proposedSignals: [TutorSignalDraft]
    public var followUpActions: [TutorTurnAction]
    public var unresolvedQuestions: [String]
    public var suggestedTopics: [String]
    public var sessionSummary: String?
    public var sourceGap: Bool
}

public struct TutorTurnArtifact: EntityPayload, Equatable {
    public static let entityType = EntityType.aiArtifact
    public var schemaVersion = "ai-artifact/tutor-turn/v1"
    public var jobId: UUID
    public var tutorSessionId: UUID
    public var topicId: UUID
    public var sequence: Int
    public var generatedAt: Date
    public var sources: [TutorSourceExcerpt]
    public var sourceExcerptIds: [UUID]
    public var sourceIds: [UUID]
    public var sourceVersionIds: [UUID]
    public var trace: ProviderTrace
    public var providerRoute: AIProviderRouteSnapshot? = nil
    public var response: TutorTurnResponse

    public var createdAt: Date { generatedAt }
    public var updatedAt: Date { generatedAt }

    public init(
        jobId: UUID,
        tutorSessionId: UUID,
        topicId: UUID,
        sequence: Int,
        generatedAt: Date,
        sources: [TutorSourceExcerpt],
        sourceExcerptIds: [UUID],
        sourceIds: [UUID],
        sourceVersionIds: [UUID],
        trace: ProviderTrace,
        providerRoute: AIProviderRouteSnapshot? = nil,
        response: TutorTurnResponse
    ) {
        self.jobId = jobId
        self.tutorSessionId = tutorSessionId
        self.topicId = topicId
        self.sequence = sequence
        self.generatedAt = generatedAt
        self.sources = sources
        self.sourceExcerptIds = sourceExcerptIds
        self.sourceIds = sourceIds
        self.sourceVersionIds = sourceVersionIds
        self.trace = trace
        self.providerRoute = providerRoute
        self.response = response
    }
}

public struct PreparedTutorTurnRequest: Equatable, Sendable {
    public var request: TutorTurnRequest
    public var sourceCount: Int
    public var approximateTokens: Int
    public var projectedCostLimitMinorUnits: Int
}

public enum TutorContractError: Error, Equatable, LocalizedError {
    case sessionUnavailable
    case sessionNotActive
    case approvalExpired
    case turnLimitReached
    case spendingLimitReached
    case objectiveRequired
    case messageRequired
    case noGroundingMaterial
    case artifactMismatch
    case citationOutsideScope
    case signalOutsideScope

    public var errorDescription: String? {
        switch self {
        case .sessionUnavailable: "The Tutor session is no longer available."
        case .sessionNotActive: "Resume the Tutor session before continuing."
        case .approvalExpired: "Review and approve a new Tutor session budget before continuing."
        case .turnLimitReached: "This Tutor session reached its approved turn limit."
        case .spendingLimitReached: "This Tutor session reached its approved spending limit."
        case .objectiveRequired: "Add a learning objective before starting the Tutor."
        case .messageRequired: "Write an answer or choose a Tutor action."
        case .noGroundingMaterial: "Add readable Sources or Evidence to this Topic before asking the Tutor."
        case .artifactMismatch: "The Tutor response does not match this session."
        case .citationOutsideScope: "The Tutor response cited material outside the approved Source scope."
        case .signalOutsideScope: "The Tutor response proposed a learning result outside the current objective."
        }
    }
}
