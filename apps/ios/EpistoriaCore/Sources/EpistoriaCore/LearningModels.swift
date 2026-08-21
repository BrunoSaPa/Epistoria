import Foundation

public enum LearningRecordState: String, Codable, Sendable {
    case active = "ACTIVE"
    case completed = "COMPLETED"
    case archived = "ARCHIVED"
}

public struct StudyGoalPayload: EntityPayload, Equatable {
    public static let entityType = EntityType.studyGoal
    public var schemaVersion = "study-goal/v1"
    public var topicId: UUID
    public var title: String
    public var details: String?
    public var targetDate: Date?
    public var priority: Int
    public var state: LearningRecordState
    public var createdAt: Date
    public var updatedAt: Date

    public init(topicId: UUID, title: String, targetDate: Date? = nil, priority: Int = 0, now: Date = .now) {
        self.topicId = topicId
        self.title = title
        details = nil
        self.targetDate = targetDate
        self.priority = min(max(priority, 0), 3)
        state = .active
        createdAt = now
        updatedAt = now
    }
}

public struct UnresolvedQuestionPayload: EntityPayload, Equatable {
    public static let entityType = EntityType.unresolvedQuestion
    public var schemaVersion = "unresolved-question/v1"
    public var topicId: UUID
    public var question: String
    public var sourceEvidenceIds: [UUID]
    public var resolvedAnswer: String?
    public var resolvedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(topicId: UUID, question: String, sourceEvidenceIds: [UUID] = [], now: Date = .now) {
        self.topicId = topicId
        self.question = question
        self.sourceEvidenceIds = sourceEvidenceIds
        resolvedAnswer = nil
        resolvedAt = nil
        createdAt = now
        updatedAt = now
    }
}

public enum SessionActivityKind: String, Codable, Sendable {
    case noteOpened = "NOTE_OPENED"
    case noteCreated = "NOTE_CREATED"
    case sourceOpened = "SOURCE_OPENED"
    case sourceAdded = "SOURCE_ADDED"
}

public struct SessionActivityPayload: EntityPayload, Equatable {
    public static let entityType = EntityType.sessionActivity
    public var schemaVersion = "session-activity/v1"
    public var sessionId: UUID
    public var itemId: UUID
    public var kind: SessionActivityKind
    public var occurredAt: Date
    public var removedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(sessionId: UUID, itemId: UUID, kind: SessionActivityKind, now: Date = .now) {
        self.sessionId = sessionId
        self.itemId = itemId
        self.kind = kind
        occurredAt = now
        removedAt = nil
        createdAt = now
        updatedAt = now
    }
}

public enum FlashcardKind: String, Codable, CaseIterable, Sendable {
    case basic = "BASIC"
    case reverse = "REVERSE"
    case bidirectional = "BIDIRECTIONAL"
    case cloze = "CLOZE"
    case typedAnswer = "TYPED_ANSWER"
    case imageOcclusion = "IMAGE_OCCLUSION"
    case ordering = "ORDERING"
    case explanation = "EXPLANATION"
}

public struct FlashcardDeckPayload: EntityPayload, Equatable {
    public static let entityType = EntityType.flashcardDeck
    public var schemaVersion = "flashcard-deck/v1"
    public var topicId: UUID
    public var name: String
    public var archivedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(topicId: UUID, name: String, now: Date = .now) {
        self.topicId = topicId
        self.name = name
        archivedAt = nil
        createdAt = now
        updatedAt = now
    }
}

public struct FlashcardPayload: EntityPayload, Equatable {
    public static let entityType = EntityType.flashcard
    public var schemaVersion = "flashcard/v1"
    public var topicId: UUID
    public var deckId: UUID?
    public var currentRevisionId: UUID
    public var kind: FlashcardKind
    public var suspendedAt: Date?
    public var archivedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        topicId: UUID,
        deckId: UUID? = nil,
        currentRevisionId: UUID,
        kind: FlashcardKind,
        now: Date = .now
    ) {
        self.topicId = topicId
        self.deckId = deckId
        self.currentRevisionId = currentRevisionId
        self.kind = kind
        suspendedAt = nil
        archivedAt = nil
        createdAt = now
        updatedAt = now
    }
}

public struct FlashcardRevisionPayload: EntityPayload, Equatable {
    public static let entityType = EntityType.flashcardRevision
    public var schemaVersion = "flashcard-revision/v1"
    public var cardId: UUID
    public var revisionNumber: Int
    public var prompt: String
    public var answer: String
    public var orderedItems: [String]
    public var evidenceIds: [UUID]
    public var provenance: RecordProvenance
    public var generatorArtifactId: UUID?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        cardId: UUID,
        revisionNumber: Int,
        prompt: String,
        answer: String,
        evidenceIds: [UUID] = [],
        provenance: RecordProvenance = .user,
        now: Date = .now
    ) {
        self.cardId = cardId
        self.revisionNumber = max(revisionNumber, 1)
        self.prompt = prompt
        self.answer = answer
        orderedItems = []
        self.evidenceIds = evidenceIds
        self.provenance = provenance
        generatorArtifactId = nil
        createdAt = now
        updatedAt = now
    }
}

public struct FlashcardScheduleState: Codable, Equatable, Sendable {
    public var algorithmVersion: String
    public var dueAt: Date
    public var intervalDays: Int
    public var ease: Double
    public var lapseCount: Int

    public init(
        algorithmVersion: String = "epistoria-sm/v1",
        dueAt: Date = .now,
        intervalDays: Int = 0,
        ease: Double = 2.5,
        lapseCount: Int = 0
    ) {
        self.algorithmVersion = algorithmVersion
        self.dueAt = dueAt
        self.intervalDays = max(intervalDays, 0)
        self.ease = min(max(ease, 1.3), 3.0)
        self.lapseCount = max(lapseCount, 0)
    }
}

public enum FlashcardRating: Int, Codable, CaseIterable, Sendable {
    case again = 0
    case hard = 1
    case good = 2
    case easy = 3
}

public struct FlashcardReviewPayload: EntityPayload, Equatable {
    public static let entityType = EntityType.flashcardReview
    public var schemaVersion = "flashcard-review/v1"
    public var cardId: UUID
    public var cardRevisionId: UUID
    public var rating: FlashcardRating
    public var previousState: FlashcardScheduleState
    public var resultingState: FlashcardScheduleState
    public var responseMilliseconds: Int?
    public var reviewedAt: Date
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        cardId: UUID,
        cardRevisionId: UUID,
        rating: FlashcardRating,
        previousState: FlashcardScheduleState,
        resultingState: FlashcardScheduleState,
        responseMilliseconds: Int? = nil,
        now: Date = .now
    ) {
        self.cardId = cardId
        self.cardRevisionId = cardRevisionId
        self.rating = rating
        self.previousState = previousState
        self.resultingState = resultingState
        self.responseMilliseconds = responseMilliseconds
        reviewedAt = now
        createdAt = now
        updatedAt = now
    }
}

public enum TestCoverageDimension: String, Codable, CaseIterable, Sendable {
    case prerequisite = "PREREQUISITE"
    case conceptual = "CONCEPTUAL"
    case methodSelection = "METHOD_SELECTION"
    case procedural = "PROCEDURAL"
    case verification = "VERIFICATION"
    case errorAnalysis = "ERROR_ANALYSIS"
    case integrated = "INTEGRATED"
}

public enum TestQuestionKind: String, Codable, CaseIterable, Sendable {
    case multipleChoice = "MULTIPLE_CHOICE"
    case multipleSelection = "MULTIPLE_SELECTION"
    case shortAnswer = "SHORT_ANSWER"
    case numerical = "NUMERICAL"
    case ordering = "ORDERING"
    case labeling = "LABELING"
    case explanation = "EXPLANATION"
    case errorAnalysis = "ERROR_ANALYSIS"
    case multiStepApplication = "MULTI_STEP_APPLICATION"
}

public struct ManualTestQuestion: Equatable, Sendable {
    public var objectiveIds: [UUID]
    public var kind: TestQuestionKind
    public var prompt: String
    public var correctAnswer: String
    public var rubric: String
    public var evidenceIds: [UUID]

    public init(
        objectiveIds: [UUID],
        kind: TestQuestionKind = .shortAnswer,
        prompt: String,
        correctAnswer: String,
        rubric: String = "Answer accurately and explain the reasoning.",
        evidenceIds: [UUID] = []
    ) {
        self.objectiveIds = objectiveIds
        self.kind = kind
        self.prompt = prompt
        self.correctAnswer = correctAnswer
        self.rubric = rubric
        self.evidenceIds = evidenceIds
    }
}

public struct TopicScopeSnapshotPayload: EntityPayload, Equatable {
    public static let entityType = EntityType.topicScopeSnapshot
    public var schemaVersion = "topic-scope-snapshot/v1"
    public var topicId: UUID
    public var includeConnectedKnowledge: Bool
    public var sourceVersionIds: [UUID]
    public var noteIds: [UUID]
    public var conceptIds: [UUID]
    public var evidenceIds: [UUID]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        topicId: UUID,
        includeConnectedKnowledge: Bool = false,
        sourceVersionIds: [UUID],
        noteIds: [UUID] = [],
        conceptIds: [UUID] = [],
        evidenceIds: [UUID] = [],
        now: Date = .now
    ) {
        self.topicId = topicId
        self.includeConnectedKnowledge = includeConnectedKnowledge
        self.sourceVersionIds = sourceVersionIds
        self.noteIds = noteIds
        self.conceptIds = conceptIds
        self.evidenceIds = evidenceIds
        createdAt = now
        updatedAt = now
    }
}

public struct TestObjective: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var dimensions: [TestCoverageDimension]
    public var weight: Double
    public var prerequisiteObjectiveIds: [UUID]

    public init(
        id: UUID = UUID(),
        title: String,
        dimensions: [TestCoverageDimension],
        weight: Double = 1,
        prerequisiteObjectiveIds: [UUID] = []
    ) {
        self.id = id
        self.title = title
        self.dimensions = dimensions
        self.weight = max(weight, 0)
        self.prerequisiteObjectiveIds = prerequisiteObjectiveIds
    }
}

public enum TestMode: String, Codable, Sendable {
    case comprehensive = "COMPREHENSIVE"
    case quickCheck = "QUICK_CHECK"
    case custom = "CUSTOM"
}

public struct TestBlueprintPayload: EntityPayload, Equatable {
    public static let entityType = EntityType.testBlueprint
    public var schemaVersion = "test-blueprint/v1"
    public var topicId: UUID
    public var scopeSnapshotId: UUID
    public var mode: TestMode
    public var objectives: [TestObjective]
    public var requestedQuestionCount: Int
    public var uncoveredObjectives: [UUID]
    public var provenance: RecordProvenance
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        topicId: UUID,
        scopeSnapshotId: UUID,
        mode: TestMode = .comprehensive,
        objectives: [TestObjective],
        requestedQuestionCount: Int,
        provenance: RecordProvenance = .user,
        now: Date = .now
    ) {
        self.topicId = topicId
        self.scopeSnapshotId = scopeSnapshotId
        self.mode = mode
        self.objectives = objectives
        self.requestedQuestionCount = max(requestedQuestionCount, 1)
        uncoveredObjectives = []
        self.provenance = provenance
        createdAt = now
        updatedAt = now
    }
}

public enum PracticeTestState: String, Codable, Sendable {
    case draft = "DRAFT"
    case ready = "READY"
    case archived = "ARCHIVED"
}

public struct PracticeTestPayload: EntityPayload, Equatable {
    public static let entityType = EntityType.practiceTest
    public var schemaVersion = "practice-test/v1"
    public var topicId: UUID
    public var title: String
    public var blueprintId: UUID
    public var scopeSnapshotId: UUID
    public var questionIds: [UUID]
    public var state: PracticeTestState
    public var provenance: RecordProvenance
    public var generatorArtifactId: UUID?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        topicId: UUID,
        title: String,
        blueprintId: UUID,
        scopeSnapshotId: UUID,
        provenance: RecordProvenance = .user,
        now: Date = .now
    ) {
        self.topicId = topicId
        self.title = title
        self.blueprintId = blueprintId
        self.scopeSnapshotId = scopeSnapshotId
        questionIds = []
        state = .draft
        self.provenance = provenance
        generatorArtifactId = nil
        createdAt = now
        updatedAt = now
    }
}

public struct TestQuestionPayload: EntityPayload, Equatable {
    public static let entityType = EntityType.testQuestion
    public var schemaVersion = "test-question/v1"
    public var testId: UUID
    public var objectiveIds: [UUID]
    public var kind: TestQuestionKind
    public var prompt: String
    public var choices: [String]
    public var correctAnswer: String
    public var rubric: String
    public var evidenceIds: [UUID]
    public var order: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        testId: UUID,
        objectiveIds: [UUID],
        kind: TestQuestionKind,
        prompt: String,
        correctAnswer: String,
        rubric: String,
        evidenceIds: [UUID] = [],
        order: Int,
        now: Date = .now
    ) {
        self.testId = testId
        self.objectiveIds = objectiveIds
        self.kind = kind
        self.prompt = prompt
        choices = []
        self.correctAnswer = correctAnswer
        self.rubric = rubric
        self.evidenceIds = evidenceIds
        self.order = max(order, 0)
        createdAt = now
        updatedAt = now
    }
}

public enum TestAttemptState: String, Codable, Sendable {
    case inProgress = "IN_PROGRESS"
    case submitted = "SUBMITTED"
    case scored = "SCORED"
    case abandoned = "ABANDONED"
}

public struct FrozenQuestionSnapshot: Codable, Equatable, Sendable {
    public var questionId: UUID
    public var kind: TestQuestionKind
    public var prompt: String
    public var choices: [String]
    public var rubric: String
    public var correctAnswer: String
    public var objectiveIds: [UUID]
    public var evidenceIds: [UUID]
}

public struct TestAttemptPayload: EntityPayload, Equatable {
    public static let entityType = EntityType.testAttempt
    public var schemaVersion = "test-attempt/v1"
    public var testId: UUID
    public var topicId: UUID
    public var scopeSnapshotId: UUID
    public var frozenQuestions: [FrozenQuestionSnapshot]
    public var state: TestAttemptState
    public var startedAt: Date
    public var submittedAt: Date?
    public var score: Double?
    public var scoreOverride: Double?
    public var scoreOverrideReason: String?
    public var retakeOfAttemptId: UUID?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        testId: UUID,
        topicId: UUID,
        scopeSnapshotId: UUID,
        frozenQuestions: [FrozenQuestionSnapshot],
        retakeOfAttemptId: UUID? = nil,
        now: Date = .now
    ) {
        self.testId = testId
        self.topicId = topicId
        self.scopeSnapshotId = scopeSnapshotId
        self.frozenQuestions = frozenQuestions
        state = .inProgress
        startedAt = now
        submittedAt = nil
        score = nil
        scoreOverride = nil
        scoreOverrideReason = nil
        self.retakeOfAttemptId = retakeOfAttemptId
        createdAt = now
        updatedAt = now
    }
}

public struct TestResponsePayload: EntityPayload, Equatable {
    public static let entityType = EntityType.testResponse
    public var schemaVersion = "test-response/v1"
    public var attemptId: UUID
    public var questionId: UUID
    public var response: String
    public var confidence: Int?
    public var elapsedMilliseconds: Int
    public var isSkipped: Bool
    public var isCorrect: Bool?
    public var feedback: String?
    public var score: Double?
    public var createdAt: Date
    public var updatedAt: Date

    public init(attemptId: UUID, questionId: UUID, now: Date = .now) {
        self.attemptId = attemptId
        self.questionId = questionId
        response = ""
        confidence = nil
        elapsedMilliseconds = 0
        isSkipped = false
        isCorrect = nil
        feedback = nil
        score = nil
        createdAt = now
        updatedAt = now
    }
}

public enum RecommendationKind: String, Codable, Sendable {
    case dueCards = "DUE_CARDS"
    case testErrors = "TEST_ERRORS"
    case unresolvedQuestion = "UNRESOLVED_QUESTION"
    case incompleteCoverage = "INCOMPLETE_COVERAGE"
    case pausedSession = "PAUSED_SESSION"
    case unfinishedTest = "UNFINISHED_TEST"
    case neglectedTopic = "NEGLECTED_TOPIC"
    case goalDeadline = "GOAL_DEADLINE"
}

public struct StudyRecommendationPayload: EntityPayload, Equatable {
    public static let entityType = EntityType.studyRecommendation
    public var schemaVersion = "study-recommendation/v1"
    public var topicId: UUID
    public var kind: RecommendationKind
    public var title: String
    public var explanation: String
    public var score: Double
    public var targetEntityIds: [UUID]
    public var generatedLocally: Bool
    public var expiresAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        topicId: UUID,
        kind: RecommendationKind,
        title: String,
        explanation: String,
        score: Double,
        targetEntityIds: [UUID] = [],
        generatedLocally: Bool = true,
        now: Date = .now
    ) {
        self.topicId = topicId
        self.kind = kind
        self.title = title
        self.explanation = explanation
        self.score = score
        self.targetEntityIds = targetEntityIds
        self.generatedLocally = generatedLocally
        expiresAt = nil
        createdAt = now
        updatedAt = now
    }
}

public enum RecommendationAction: String, Codable, Sendable {
    case accepted = "ACCEPTED"
    case pinned = "PINNED"
    case snoozed = "SNOOZED"
    case dismissed = "DISMISSED"
    case irrelevant = "IRRELEVANT"
}

public struct RecommendationResponsePayload: EntityPayload, Equatable {
    public static let entityType = EntityType.recommendationResponse
    public var schemaVersion = "recommendation-response/v1"
    public var recommendationId: UUID
    public var action: RecommendationAction
    public var snoozedUntil: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(recommendationId: UUID, action: RecommendationAction, snoozedUntil: Date? = nil, now: Date = .now) {
        self.recommendationId = recommendationId
        self.action = action
        self.snoozedUntil = snoozedUntil
        createdAt = now
        updatedAt = now
    }
}

public enum AutomationJobKind: String, Codable, CaseIterable, Sendable {
    case sourceExtraction = "SOURCE_EXTRACTION"
    case transcription = "TRANSCRIPTION"
    case topicSynthesis = "TOPIC_SYNTHESIS"
    case flashcardDrafts = "FLASHCARD_DRAFTS"
    case testDraft = "TEST_DRAFT"
    case feedback = "FEEDBACK"
    case conceptSuggestions = "CONCEPT_SUGGESTIONS"
    case sourceDiscovery = "SOURCE_DISCOVERY"
    case sessionReview = "SESSION_REVIEW"
    case weeklyReview = "WEEKLY_REVIEW"
}

public struct AutomationGrantPayload: EntityPayload, Equatable {
    public static let entityType = EntityType.automationGrant
    public var schemaVersion = "automation-grant/v1"
    public var topicIds: [UUID]
    public var jobTypes: [AutomationJobKind]
    public var minimumIntervalHours: Int
    public var expiresAt: Date
    public var spendingLimitMinorUnits: Int
    public var currencyCode: String
    public var revokedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        topicIds: [UUID],
        jobTypes: [AutomationJobKind],
        minimumIntervalHours: Int,
        expiresAt: Date,
        spendingLimitMinorUnits: Int,
        currencyCode: String = "USD",
        now: Date = .now
    ) {
        self.topicIds = topicIds
        self.jobTypes = jobTypes
        self.minimumIntervalHours = max(minimumIntervalHours, 1)
        self.expiresAt = expiresAt
        self.spendingLimitMinorUnits = max(spendingLimitMinorUnits, 0)
        self.currencyCode = currencyCode
        revokedAt = nil
        createdAt = now
        updatedAt = now
    }
}

/// Deterministic, local scheduler. Reviews are append-only; the resulting state is stored on
/// each review so history can be reconstructed even after the algorithm changes.
public enum FlashcardScheduler {
    public static func next(
        after previous: FlashcardScheduleState,
        rating: FlashcardRating,
        reviewedAt: Date
    ) -> FlashcardScheduleState {
        let interval: Int
        let ease: Double
        let lapses: Int
        switch rating {
        case .again:
            interval = 0
            ease = max(1.3, previous.ease - 0.2)
            lapses = previous.lapseCount + 1
        case .hard:
            interval = max(1, Int((Double(max(previous.intervalDays, 1)) * 1.2).rounded()))
            ease = max(1.3, previous.ease - 0.15)
            lapses = previous.lapseCount
        case .good:
            interval = previous.intervalDays == 0
                ? 1
                : max(previous.intervalDays + 1, Int((Double(previous.intervalDays) * previous.ease).rounded()))
            ease = previous.ease
            lapses = previous.lapseCount
        case .easy:
            interval = previous.intervalDays == 0
                ? 4
                : max(previous.intervalDays + 2, Int((Double(previous.intervalDays) * previous.ease * 1.3).rounded()))
            ease = min(3.0, previous.ease + 0.15)
            lapses = previous.lapseCount
        }
        let dueAt = Calendar(identifier: .gregorian).date(
            byAdding: rating == .again ? .minute : .day,
            value: rating == .again ? 10 : interval,
            to: reviewedAt
        ) ?? reviewedAt
        return FlashcardScheduleState(
            algorithmVersion: "epistoria-sm/v1",
            dueAt: dueAt,
            intervalDays: interval,
            ease: ease,
            lapseCount: lapses
        )
    }
}
