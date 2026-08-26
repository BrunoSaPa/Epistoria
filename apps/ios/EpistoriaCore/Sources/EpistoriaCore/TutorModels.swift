import Foundation

public enum TutorSessionState: String, Codable, CaseIterable, Sendable {
    case active = "ACTIVE"
    case paused = "PAUSED"
    case ended = "ENDED"
    case abandoned = "ABANDONED"
}

public enum TutorGuidanceStyle: String, Codable, CaseIterable, Sendable {
    case adaptive = "ADAPTIVE"
    case socratic = "SOCRATIC"
    case direct = "DIRECT"
}

public struct TutorSessionBudget: Codable, Equatable, Sendable {
    public var maximumTurns: Int
    public var spendingLimitMinorUnits: Int
    public var currencyCode: String
    public var expiresAt: Date
    public var approvedAt: Date

    public init(
        maximumTurns: Int = 12,
        spendingLimitMinorUnits: Int = 100,
        currencyCode: String = "USD",
        expiresAt: Date = .now.addingTimeInterval(4 * 60 * 60),
        approvedAt: Date = .now
    ) {
        self.maximumTurns = min(max(maximumTurns, 1), 100)
        self.spendingLimitMinorUnits = min(max(spendingLimitMinorUnits, 0), 100_000)
        self.currencyCode = currencyCode
        self.expiresAt = expiresAt
        self.approvedAt = approvedAt
    }
}

public struct TutorSessionPayload: EntityPayload, Equatable {
    public static let entityType = EntityType.tutorSession
    public var schemaVersion = "tutor-session/v1"
    public var topicId: UUID
    public var studySessionId: UUID?
    public var goalId: UUID?
    public var objective: String?
    public var timeTargetMinutes: Int?
    public var sourceVersionIds: [UUID]
    public var includeConnectedKnowledge: Bool
    public var guidanceStyle: TutorGuidanceStyle
    public var state: TutorSessionState
    public var providerRoute: AIProviderRouteSnapshot?
    public var budget: TutorSessionBudget
    public var approvedTurnCount: Int
    public var estimatedSpentMinorUnits: Int
    public var startedAt: Date
    public var pausedAt: Date?
    public var endedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        topicId: UUID,
        studySessionId: UUID? = nil,
        goalId: UUID? = nil,
        objective: String? = nil,
        timeTargetMinutes: Int? = nil,
        sourceVersionIds: [UUID] = [],
        includeConnectedKnowledge: Bool = false,
        guidanceStyle: TutorGuidanceStyle = .adaptive,
        providerRoute: AIProviderRouteSnapshot? = nil,
        budget: TutorSessionBudget = TutorSessionBudget(),
        now: Date = .now
    ) {
        self.topicId = topicId
        self.studySessionId = studySessionId
        self.goalId = goalId
        self.objective = objective?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.timeTargetMinutes = timeTargetMinutes.map { min(max($0, 5), 480) }
        self.sourceVersionIds = sourceVersionIds.uniqued()
        self.includeConnectedKnowledge = includeConnectedKnowledge
        self.guidanceStyle = guidanceStyle
        state = .active
        self.providerRoute = providerRoute
        self.budget = budget
        approvedTurnCount = 0
        estimatedSpentMinorUnits = 0
        startedAt = now
        pausedAt = nil
        endedAt = nil
        createdAt = now
        updatedAt = now
    }

    public func canQueueTurn(at date: Date) -> Bool {
        state == .active
            && date < budget.expiresAt
            && approvedTurnCount < budget.maximumTurns
            && estimatedSpentMinorUnits < budget.spendingLimitMinorUnits
    }
}

public enum TutorTurnRole: String, Codable, Sendable {
    case learner = "LEARNER"
    case tutor = "TUTOR"
    case system = "SYSTEM"
}

public enum TutorTurnKind: String, Codable, CaseIterable, Sendable {
    case diagnostic = "DIAGNOSTIC"
    case hint = "HINT"
    case explanation = "EXPLANATION"
    case workedExample = "WORKED_EXAMPLE"
    case retrieval = "RETRIEVAL"
    case application = "APPLICATION"
    case errorAnalysis = "ERROR_ANALYSIS"
    case reflection = "REFLECTION"
    case sourceGap = "SOURCE_GAP"
}

public struct TutorCitation: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var excerptId: UUID
    public var sourceId: UUID
    public var sourceVersionId: UUID
    public var locator: SourceLocator
    public var evidenceId: UUID?
    public var excerpt: String

    public init(
        id: UUID = UUID(),
        excerptId: UUID,
        sourceId: UUID,
        sourceVersionId: UUID,
        locator: SourceLocator,
        evidenceId: UUID? = nil,
        excerpt: String
    ) {
        self.id = id
        self.excerptId = excerptId
        self.sourceId = sourceId
        self.sourceVersionId = sourceVersionId
        self.locator = locator
        self.evidenceId = evidenceId
        self.excerpt = excerpt
    }
}

public struct TutorTurnPayload: EntityPayload, Equatable {
    public static let entityType = EntityType.tutorTurn
    public var schemaVersion = "tutor-turn/v1"
    public var tutorSessionId: UUID
    public var sequence: Int
    public var role: TutorTurnRole
    public var kind: TutorTurnKind
    public var text: String
    public var confidence: Int?
    public var citations: [TutorCitation]
    public var providerTrace: ProviderTrace?
    public var jobId: UUID?
    public var pending: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        tutorSessionId: UUID,
        sequence: Int,
        role: TutorTurnRole,
        kind: TutorTurnKind,
        text: String,
        confidence: Int? = nil,
        citations: [TutorCitation] = [],
        providerTrace: ProviderTrace? = nil,
        jobId: UUID? = nil,
        pending: Bool = false,
        now: Date = .now
    ) {
        self.tutorSessionId = tutorSessionId
        self.sequence = max(sequence, 0)
        self.role = role
        self.kind = kind
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.confidence = confidence.map { min(max($0, 1), 5) }
        self.citations = citations
        self.providerTrace = providerTrace
        self.jobId = jobId
        self.pending = pending
        createdAt = now
        updatedAt = now
    }
}

public enum LearningAssessmentKind: String, Codable, CaseIterable, Sendable {
    case diagnostic = "DIAGNOSTIC"
    case retrieval = "RETRIEVAL"
    case application = "APPLICATION"
    case selfExplanation = "SELF_EXPLANATION"
    case correction = "CORRECTION"
}

public enum LearningSignalOutcome: String, Codable, CaseIterable, Sendable {
    case correct = "CORRECT"
    case partial = "PARTIAL"
    case incorrect = "INCORRECT"
    case skipped = "SKIPPED"
}

public enum LearningSignalReviewState: String, Codable, Sendable {
    case proposed = "PROPOSED"
    case accepted = "ACCEPTED"
    case rejected = "REJECTED"
}

public struct LearningSignalPayload: EntityPayload, Equatable {
    public static let entityType = EntityType.learningSignal
    public var schemaVersion = "learning-signal/v1"
    public var tutorSessionId: UUID
    public var topicId: UUID
    public var objective: String
    public var assessmentKind: LearningAssessmentKind
    public var outcome: LearningSignalOutcome
    public var confidence: Int?
    public var turnIds: [UUID]
    public var evidenceIds: [UUID]
    public var rationale: String?
    public var provenance: RecordProvenance
    public var reviewState: LearningSignalReviewState
    public var reviewedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        tutorSessionId: UUID,
        topicId: UUID,
        objective: String,
        assessmentKind: LearningAssessmentKind,
        outcome: LearningSignalOutcome,
        confidence: Int? = nil,
        turnIds: [UUID] = [],
        evidenceIds: [UUID] = [],
        rationale: String? = nil,
        provenance: RecordProvenance = .generatedAI,
        reviewState: LearningSignalReviewState = .proposed,
        now: Date = .now
    ) {
        self.tutorSessionId = tutorSessionId
        self.topicId = topicId
        self.objective = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        self.assessmentKind = assessmentKind
        self.outcome = outcome
        self.confidence = confidence.map { min(max($0, 1), 5) }
        self.turnIds = turnIds.uniqued()
        self.evidenceIds = evidenceIds.uniqued()
        self.rationale = rationale?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.provenance = provenance
        self.reviewState = reviewState
        reviewedAt = reviewState == .accepted ? now : nil
        createdAt = now
        updatedAt = now
    }
}

public enum MasteryLevel: String, Codable, CaseIterable, Sendable {
    case notAssessed = "NOT_ASSESSED"
    case needsWork = "NEEDS_WORK"
    case developing = "DEVELOPING"
    case secure = "SECURE"
}

public struct MasteryProjection: Equatable, Sendable {
    public var objective: String
    public var level: MasteryLevel
    public var score: Double
    public var acceptedSignalCount: Int
    public var explanation: String
    public var nextTurnKind: TutorTurnKind
}

public enum TutorAdaptationEngine {
    public static func project(
        objective: String,
        signals: [IdentifiedPayload<LearningSignalPayload>],
        now: Date = .now
    ) -> MasteryProjection {
        let matching = signals.filter {
            $0.payload.reviewState == .accepted
                && $0.payload.objective.localizedCaseInsensitiveCompare(objective) == .orderedSame
        }
        guard !matching.isEmpty else {
            return MasteryProjection(
                objective: objective,
                level: .notAssessed,
                score: 0,
                acceptedSignalCount: 0,
                explanation: "No accepted evidence of learning is available yet. Start with a short diagnostic.",
                nextTurnKind: .diagnostic
            )
        }
        var weight = 0.0
        var total = 0.0
        for signal in matching {
            let ageDays = max(0, now.timeIntervalSince(signal.payload.createdAt) / 86_400)
            let recency = max(0.35, 1 - ageDays / 120)
            let assessmentWeight: Double = switch signal.payload.assessmentKind {
            case .diagnostic: 0.8
            case .retrieval: 1
            case .application: 1.25
            case .selfExplanation: 1
            case .correction: 0.7
            }
            let value: Double = switch signal.payload.outcome {
            case .correct: 1
            case .partial: 0.55
            case .incorrect: 0
            case .skipped: 0.1
            }
            let confidenceCalibration: Double
            if signal.payload.outcome == .incorrect, (signal.payload.confidence ?? 0) >= 4 {
                confidenceCalibration = 1.2
            } else {
                confidenceCalibration = 1
            }
            let itemWeight = assessmentWeight * recency * confidenceCalibration
            total += value * itemWeight
            weight += itemWeight
        }
        let score = weight > 0 ? min(max(total / weight, 0), 1) : 0
        let level: MasteryLevel
        let next: TutorTurnKind
        let explanation: String
        switch score {
        case 0.78...:
            level = .secure
            next = .application
            explanation = "Accepted results show consistent understanding. Use a transfer or mixed application problem next."
        case 0.42 ..< 0.78:
            level = .developing
            next = .retrieval
            explanation = "Understanding is developing. Retrieve the method and explain why it applies before adding difficulty."
        default:
            level = .needsWork
            next = .workedExample
            explanation = "Recent accepted results show a gap. Review a cited worked example and then solve a similar problem."
        }
        return MasteryProjection(
            objective: objective,
            level: level,
            score: score,
            acceptedSignalCount: matching.count,
            explanation: explanation,
            nextTurnKind: next
        )
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
