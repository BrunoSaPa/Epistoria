import CryptoKit
import Foundation

public enum DigestSourceKind: String, Codable, Sendable {
    case noteBlock = "NOTE_BLOCK"
    case annotation = "ANNOTATION"
    case pdfPage = "PDF_PAGE"
}

public enum LearningAIJobType: String, Codable, CaseIterable, Sendable {
    case sourceExtraction = "SOURCE_EXTRACTION"
    case transcription = "TRANSCRIPTION"
    case topicSynthesis = "TOPIC_SYNTHESIS"
    case flashcardDrafts = "FLASHCARD_DRAFTS"
    case testBlueprint = "TEST_BLUEPRINT"
    case testGeneration = "TEST_GENERATION"
    case freeResponseFeedback = "FREE_RESPONSE_FEEDBACK"
    case conceptSuggestions = "CONCEPT_SUGGESTIONS"
    case sourceDiscovery = "SOURCE_DISCOVERY"
    case sessionReview = "SESSION_REVIEW"
    case weeklyReview = "WEEKLY_REVIEW"
}

public extension AutomationJobKind {
    var learningJobType: LearningAIJobType? {
        switch self {
        case .topicSynthesis: .topicSynthesis
        case .flashcardDrafts: .flashcardDrafts
        case .conceptSuggestions: .conceptSuggestions
        case .sourceDiscovery: .sourceDiscovery
        case .weeklyReview: .weeklyReview
        default: nil
        }
    }
}

public struct TestGenerationPlan: Codable, Equatable, Sendable {
    public var schemaVersion = "test-generation-plan/v1"
    public var mode: TestMode
    public var questionCount: Int
    public var timeLimitMinutes: Int?
    public var coverageDimensions: [TestCoverageDimension]
    public var objectiveTitles: [String]

    public init(
        mode: TestMode,
        questionCount: Int,
        timeLimitMinutes: Int? = nil,
        coverageDimensions: [TestCoverageDimension],
        objectiveTitles: [String]
    ) {
        self.mode = mode
        self.questionCount = min(max(questionCount, 1), 100)
        self.timeLimitMinutes = timeLimitMinutes.map { min(max($0, 1), 600) }
        self.coverageDimensions = coverageDimensions.reduce(into: []) { result, dimension in
            if !result.contains(dimension) { result.append(dimension) }
        }
        self.objectiveTitles = objectiveTitles.reduce(into: []) { result, rawTitle in
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty,
                  !result.contains(where: { $0.localizedCaseInsensitiveCompare(title) == .orderedSame })
            else { return }
            result.append(title)
        }
    }
}

public struct DetectedTestObjective: Equatable, Sendable, Identifiable {
    public var title: String
    public var supportingRecordCount: Int
    public var origin: String
    public var id: String { title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }

    public init(title: String, supportingRecordCount: Int, origin: String) {
        self.title = title
        self.supportingRecordCount = max(supportingRecordCount, 1)
        self.origin = origin
    }
}

public struct LearningGenerationRequest: Codable, Equatable, Sendable {
    public var schemaVersion = "learning-generation-request/v4"
    public var accountId: UUID
    public var jobId: UUID
    public var jobType: LearningAIJobType
    public var topicId: UUID
    public var includeConnectedKnowledge: Bool
    public var userInstructions: String?
    public var sources: [DigestSourceExcerpt]
    public var knownConcepts: [KnownConceptReference]?
    public var objectiveTitles: [String]
    public var testPlan: TestGenerationPlan? = nil
    public var automationAuthorization: AutomationAuthorization? = nil
    public var disclosureAcknowledged: Bool
    public var providerRoute: AIProviderRouteSnapshot? = nil
}

public struct KnownConceptReference: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var aliases: [String]

    public init(id: UUID, name: String, aliases: [String] = []) {
        self.id = id
        self.name = name
        self.aliases = aliases
    }
}

public struct AutomationAuthorization: Codable, Equatable, Sendable {
    public var schemaVersion = "automation-authorization/v1"
    public var grantId: UUID
    public var topicIds: [UUID]
    public var jobTypes: [LearningAIJobType]
    public var minimumIntervalHours: Int
    public var expiresAt: Date
    public var spendingLimitMinorUnits: Int
    public var currencyCode: String
    public var authorizedAt: Date
    public var scopeKey: String
    public var inputFingerprint: String

    public init(
        grantId: UUID,
        topicIds: [UUID],
        jobTypes: [LearningAIJobType],
        minimumIntervalHours: Int,
        expiresAt: Date,
        spendingLimitMinorUnits: Int,
        currencyCode: String,
        authorizedAt: Date,
        scopeKey: String,
        inputFingerprint: String
    ) {
        self.grantId = grantId
        self.topicIds = topicIds
        self.jobTypes = jobTypes
        self.minimumIntervalHours = max(minimumIntervalHours, 1)
        self.expiresAt = expiresAt
        self.spendingLimitMinorUnits = max(spendingLimitMinorUnits, 0)
        self.currencyCode = currencyCode
        self.authorizedAt = authorizedAt
        self.scopeKey = scopeKey
        self.inputFingerprint = inputFingerprint
    }
}

public enum AutomationQueueOutcome: Equatable, Sendable {
    case queued(jobId: UUID, grantId: UUID, topicId: UUID, jobType: LearningAIJobType)
    case unchanged(grantId: UUID, topicId: UUID, jobType: LearningAIJobType)
    case notDue(grantId: UUID, topicId: UUID, jobType: LearningAIJobType)
    case unavailable(grantId: UUID, topicId: UUID, jobType: LearningAIJobType, reason: String)
}

public struct LearningDraftItem: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var kind: String
    public var title: String
    public var body: String
    public var answer: String?
    public var choices: [String]
    public var objectiveTitles: [String]
    public var citedSourceIds: [UUID]

    public init(
        id: UUID = UUID(),
        kind: String,
        title: String,
        body: String,
        answer: String? = nil,
        choices: [String] = [],
        objectiveTitles: [String] = [],
        citedSourceIds: [UUID]
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.answer = answer
        self.choices = choices
        self.objectiveTitles = objectiveTitles
        self.citedSourceIds = citedSourceIds
    }
}

public struct LearningGenerationResponse: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var summary: String
    public var items: [LearningDraftItem]
    public var conceptLinks: [ConceptLinkDraft]?
    public var coverageGaps: [String]

    public init(
        schemaVersion: String = "learning-generation-response/v2",
        summary: String,
        items: [LearningDraftItem],
        conceptLinks: [ConceptLinkDraft] = [],
        coverageGaps: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.summary = summary
        self.items = items
        self.conceptLinks = conceptLinks
        self.coverageGaps = coverageGaps
    }

    public var resolvedConceptLinks: [ConceptLinkDraft] { conceptLinks ?? [] }
}

public struct ConceptLinkDraft: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var sourceConceptId: UUID?
    public var sourceConceptName: String
    public var targetConceptId: UUID?
    public var targetConceptName: String
    public var relation: ConceptLinkKind
    public var rationale: String
    public var citedSourceIds: [UUID]

    public init(
        id: UUID = UUID(),
        sourceConceptId: UUID? = nil,
        sourceConceptName: String,
        targetConceptId: UUID? = nil,
        targetConceptName: String,
        relation: ConceptLinkKind,
        rationale: String,
        citedSourceIds: [UUID]
    ) {
        self.id = id
        self.sourceConceptId = sourceConceptId
        self.sourceConceptName = sourceConceptName
        self.targetConceptId = targetConceptId
        self.targetConceptName = targetConceptName
        self.relation = relation
        self.rationale = rationale
        self.citedSourceIds = citedSourceIds
    }
}

public struct LearningGenerationArtifact: EntityPayload, Equatable {
    public static let entityType = EntityType.aiArtifact
    public var schemaVersion: String
    public var jobId: UUID
    public var jobType: LearningAIJobType
    public var topicId: UUID
    public var includeConnectedKnowledge: Bool
    public var generatedAt: Date
    public var sourceIds: [UUID]
    public var trace: ProviderTrace
    public var response: LearningGenerationResponse
    public var reviewState: AIArtifactReviewState?
    public var reviewedAt: Date?
    public var editedResponse: LearningGenerationResponse?
    public var testPlan: TestGenerationPlan?
    public var knownConceptIds: [UUID]?

    public var createdAt: Date { generatedAt }
    public var updatedAt: Date { reviewedAt ?? generatedAt }

    public init(
        schemaVersion: String = "ai-artifact/learning-generation/v2",
        jobId: UUID,
        jobType: LearningAIJobType,
        topicId: UUID,
        includeConnectedKnowledge: Bool,
        generatedAt: Date,
        sourceIds: [UUID],
        trace: ProviderTrace,
        response: LearningGenerationResponse,
        testPlan: TestGenerationPlan? = nil,
        knownConceptIds: [UUID] = []
    ) {
        self.schemaVersion = schemaVersion
        self.jobId = jobId
        self.jobType = jobType
        self.topicId = topicId
        self.includeConnectedKnowledge = includeConnectedKnowledge
        self.generatedAt = generatedAt
        self.sourceIds = sourceIds
        self.trace = trace
        self.response = response
        reviewState = nil
        reviewedAt = nil
        editedResponse = nil
        self.testPlan = testPlan
        self.knownConceptIds = knownConceptIds
    }
}

public struct PreparedLearningGenerationRequest: Equatable, Sendable {
    public var request: LearningGenerationRequest
    public var sourceCount: Int
    public var approximateTokens: Int
}

public enum FeedbackEvidenceKind: String, Codable, Sendable {
    case questionSnapshot = "QUESTION_SNAPSHOT"
    case noteBlock = "NOTE_BLOCK"
    case evidence = "EVIDENCE"
}

public struct FeedbackEvidenceExcerpt: Codable, Equatable, Sendable {
    public var sourceId: UUID
    public var sourceKind: FeedbackEvidenceKind
    public var title: String
    public var locator: String
    public var excerpt: String

    public init(
        sourceId: UUID,
        sourceKind: FeedbackEvidenceKind,
        title: String,
        locator: String,
        excerpt: String
    ) {
        self.sourceId = sourceId
        self.sourceKind = sourceKind
        self.title = title
        self.locator = locator
        self.excerpt = excerpt
    }
}

public struct FreeResponseFeedbackRequest: Codable, Equatable, Sendable {
    public var schemaVersion = "free-response-feedback-request/v1"
    public var accountId: UUID
    public var jobId: UUID
    public var attemptId: UUID
    public var responseId: UUID
    public var questionId: UUID
    public var topicId: UUID
    public var questionKind: TestQuestionKind
    public var prompt: String
    public var rubric: String
    public var referenceAnswer: String
    public var userResponse: String
    public var confidence: Int?
    public var evidence: [FeedbackEvidenceExcerpt]
    public var disclosureAcknowledged: Bool
    public var providerRoute: AIProviderRouteSnapshot? = nil
}

public struct FreeResponseFeedbackResponse: Codable, Equatable, Sendable {
    public var schemaVersion = "free-response-feedback-response/v1"
    public var feedback: String
    public var strengths: [String]
    public var improvements: [String]
    public var proposedScore: Double
    public var uncertainty: String
    public var citedSourceIds: [UUID]

    public init(
        feedback: String,
        strengths: [String] = [],
        improvements: [String] = [],
        proposedScore: Double,
        uncertainty: String,
        citedSourceIds: [UUID]
    ) {
        self.feedback = feedback
        self.strengths = strengths
        self.improvements = improvements
        self.proposedScore = min(max(proposedScore, 0), 1)
        self.uncertainty = uncertainty
        self.citedSourceIds = citedSourceIds
    }
}

public struct FreeResponseFeedbackArtifact: EntityPayload, Equatable {
    public static let entityType = EntityType.aiArtifact
    public var schemaVersion = "ai-artifact/free-response-feedback/v1"
    public var jobId: UUID
    public var attemptId: UUID
    public var responseId: UUID
    public var questionId: UUID
    public var topicId: UUID
    public var generatedAt: Date
    public var sourceIds: [UUID]
    public var trace: ProviderTrace
    public var response: FreeResponseFeedbackResponse
    public var reviewState: AIArtifactReviewState?
    public var reviewedAt: Date?
    public var editedResponse: FreeResponseFeedbackResponse?

    public var createdAt: Date { generatedAt }
    public var updatedAt: Date { reviewedAt ?? generatedAt }

    public init(
        jobId: UUID,
        attemptId: UUID,
        responseId: UUID,
        questionId: UUID,
        topicId: UUID,
        generatedAt: Date,
        sourceIds: [UUID],
        trace: ProviderTrace,
        response: FreeResponseFeedbackResponse
    ) {
        self.jobId = jobId
        self.attemptId = attemptId
        self.responseId = responseId
        self.questionId = questionId
        self.topicId = topicId
        self.generatedAt = generatedAt
        self.sourceIds = sourceIds
        self.trace = trace
        self.response = response
        reviewState = nil
        reviewedAt = nil
        editedResponse = nil
    }
}

public struct PreparedFreeResponseFeedbackRequest: Equatable, Sendable {
    public var request: FreeResponseFeedbackRequest
    public var evidenceCount: Int
    public var approximateTokens: Int
}

// MARK: - Note Query types

public enum NoteQuerySourceKind: String, Codable, Sendable {
    case noteBlock = "NOTE_BLOCK"
    case lassoSelection = "LASSO_SELECTION"
}

public struct NoteQuerySourceExcerpt: Codable, Equatable, Sendable {
    public var sourceId: UUID
    public var sourceKind: NoteQuerySourceKind
    public var title: String
    public var locator: String
    /// Plain text content. Present for text blocks and transcribed drawing blocks.
    public var excerpt: String?
    /// Base64-encoded PNG of a drawing block region. Nil for text-only sources.
    public var imageContent: String?

    public init(
        sourceId: UUID,
        sourceKind: NoteQuerySourceKind,
        title: String,
        locator: String,
        excerpt: String? = nil,
        imageContent: String? = nil
    ) {
        self.sourceId = sourceId
        self.sourceKind = sourceKind
        self.title = title
        self.locator = locator
        self.excerpt = excerpt
        self.imageContent = imageContent
    }
}

public struct NoteQueryRequest: Codable, Equatable, Sendable {
    public var schemaVersion = "note-query-request/v1"
    public var accountId: UUID
    public var jobId: UUID
    public var noteId: UUID
    public var noteTitle: String?
    public var question: String
    /// Blocks that the user lasso-selected — at most 10.
    public var selectionSources: [NoteQuerySourceExcerpt]
    /// All other blocks from the same note for context — at most 200.
    public var contextSources: [NoteQuerySourceExcerpt]
    public var disclosureAcknowledged: Bool
    public var providerRoute: AIProviderRouteSnapshot? = nil
}

public struct NoteQueryResponse: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var answer: String
    public var citedSourceIds: [UUID]
    public var followUpQuestions: [String]

    public init(
        schemaVersion: String,
        answer: String,
        citedSourceIds: [UUID],
        followUpQuestions: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.answer = answer
        self.citedSourceIds = citedSourceIds
        self.followUpQuestions = followUpQuestions
    }
}

public struct NoteQueryArtifact: EntityPayload, Equatable {
    public static let entityType = EntityType.aiArtifact
    public var schemaVersion: String
    public var jobId: UUID
    /// The note this artifact is linked to (used as the entity's parentId).
    public var noteId: UUID
    public var question: String
    public var generatedAt: Date
    public var sourceIds: [UUID]
    public var trace: ProviderTrace
    public var response: NoteQueryResponse

    // Review state — set by the owner on the iPad, never by the worker.
    public var reviewState: AIArtifactReviewState?
    public var reviewedAt: Date?
    public var editedResponse: NoteQueryResponse?

    public var createdAt: Date { generatedAt }
    public var updatedAt: Date { reviewedAt ?? generatedAt }
}

public struct PreparedNoteQueryRequest: Equatable, Sendable {
    public var request: NoteQueryRequest
    public var selectionCount: Int
    public var contextCount: Int
    public var hasImages: Bool
    public var approximateTokens: Int
}

public struct DigestSourceExcerpt: Codable, Equatable, Sendable {
    public var sourceId: UUID
    public var sourceKind: DigestSourceKind
    public var title: String
    public var locator: String
    public var excerpt: String
}

public struct SessionDigestRequest: Codable, Equatable, Sendable {
    public var schemaVersion = "session-digest-request/v1"
    public var accountId: UUID
    public var jobId: UUID
    public var sessionId: UUID
    public var courseId: UUID?
    public var sessionTitle: String
    public var startedAt: Date
    public var endedAt: Date
    public var sources: [DigestSourceExcerpt]
    public var userInstructions: String?
    public var disclosureAcknowledged: Bool
    public var providerRoute: AIProviderRouteSnapshot? = nil
}

public struct CitedStatement: Codable, Equatable, Sendable, Identifiable {
    public var id: String { text + sourceIds.map(\.uuidString).joined() }
    public var text: String
    public var sourceIds: [UUID]
}

public struct SessionDigest: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var title: String
    public var summary: String
    public var keyPoints: [CitedStatement]
    public var possibleMisconceptions: [CitedStatement]
    public var followUpQuestions: [String]
}

public struct ProviderTrace: Codable, Equatable, Sendable {
    public var provider: String
    public var model: String
    public var promptVersion: String
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var estimatedCostUsd: Double?
    public var providerRequestId: String?

    public init(
        provider: String,
        model: String,
        promptVersion: String,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        estimatedCostUsd: Double? = nil,
        providerRequestId: String? = nil
    ) {
        self.provider = provider
        self.model = model
        self.promptVersion = promptVersion
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.estimatedCostUsd = estimatedCostUsd
        self.providerRequestId = providerRequestId
    }
}

public enum AIArtifactReviewState: String, Codable, Sendable {
    case accepted = "ACCEPTED"
    case edited = "EDITED"
    case rejected = "REJECTED"
}

public struct SessionDigestArtifact: EntityPayload, Equatable {
    public static let entityType = EntityType.aiArtifact
    public var schemaVersion: String
    public var jobId: UUID
    public var sessionId: UUID
    public var generatedAt: Date
    public var sourceIds: [UUID]
    public var trace: ProviderTrace
    public var digest: SessionDigest

    // The trusted worker does not set review fields. They are added by the person using
    // the iPad and sync as part of the encrypted artifact.
    public var reviewState: AIArtifactReviewState?
    public var reviewedAt: Date?
    public var editedDigest: SessionDigest?

    public var createdAt: Date { generatedAt }
    public var updatedAt: Date { reviewedAt ?? generatedAt }
}

public struct DigestDisclosurePreview: Equatable, Sendable {
    public var sourceCount: Int
    public var characterCount: Int
    public var approximateTokens: Int
    public var sourceTitles: [String]
}

public struct PreparedDigestRequest: Equatable, Sendable {
    public var request: SessionDigestRequest
    public var preview: DigestDisclosurePreview
}

public struct PDFExtractionRequest: Codable, Equatable, Sendable {
    public var schemaVersion = "pdf-extraction-request/v1"
    public var accountId: UUID
    public var jobId: UUID
    public var resourceId: UUID
    public var assetId: UUID
    public var assetKey: String
    public var expectedDedupeTag: String
    public var title: String
}

public struct ExtractedPDFPage: Codable, Equatable, Sendable {
    public var pageNumber: Int
    public var text: String
    public var characterCount: Int
    public var needsOcr: Bool
}

public struct PDFExtractionChunk: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var jobId: UUID
    public var resourceId: UUID
    public var chunkIndex: Int
    public var pages: [ExtractedPDFPage]
}

public struct PDFExtractionManifest: EntityPayload, Equatable {
    public static let entityType = EntityType.aiArtifact
    public var schemaVersion: String
    public var jobId: UUID
    public var resourceId: UUID
    public var generatedAt: Date
    public var pageCount: Int
    public var characterCount: Int
    public var pagesNeedingOcr: [Int]
    public var chunkEntityIds: [UUID]

    public var createdAt: Date { generatedAt }
    public var updatedAt: Date { generatedAt }
}

public enum SourceAnalysisMaterialKind: String, Codable, Sendable {
    case text = "TEXT"
    case image = "IMAGE"
}

public struct SourceCitationReference: Codable, Equatable, Sendable, Identifiable {
    public var sourceId: UUID
    public var kind: SourceAnalysisMaterialKind
    public var pageNumber: Int
    public var rectangles: [AnnotationRectangle]
    public var excerpt: String
    public var id: UUID { sourceId }

    public var locator: SourceLocator {
        SourceLocator(kind: .pdf, page: pageNumber, rectangles: rectangles)
    }
}

public struct SourceAnalysisRequest: Codable, Equatable, Sendable {
    public var schemaVersion = "source-analysis-request/v1"
    public var accountId: UUID
    public var jobId: UUID
    public var sourceId: UUID
    public var sourceVersionId: UUID
    public var title: String
    public var outputLanguage: String
    public var assetId: UUID
    public var assetKey: String
    public var expectedDedupeTag: String
    public var includeImages: Bool
    public var disclosureAcknowledged: Bool
    public var providerRoute: AIProviderRouteSnapshot? = nil
}

public struct SourceQueryRequest: Codable, Equatable, Sendable {
    public var schemaVersion = "source-query-request/v1"
    public var accountId: UUID
    public var jobId: UUID
    public var sourceId: UUID
    public var sourceVersionId: UUID
    public var title: String
    public var outputLanguage: String
    public var assetId: UUID
    public var assetKey: String
    public var expectedDedupeTag: String
    public var includeImages: Bool
    public var disclosureAcknowledged: Bool
    public var question: String
    public var providerRoute: AIProviderRouteSnapshot? = nil
}

public struct SourceGuideStatement: Codable, Equatable, Sendable, Identifiable {
    public var text: String
    public var sourceIds: [UUID]
    public var id: String { text + sourceIds.map(\.uuidString).joined() }
}

public struct SourceGuideTopic: Codable, Equatable, Sendable, Identifiable {
    public var title: String
    public var explanation: String
    public var sourceIds: [UUID]
    public var id: String { title + sourceIds.map(\.uuidString).joined() }
}

public struct SuggestedSourceQuestion: Codable, Equatable, Sendable, Identifiable {
    public var question: String
    public var sourceIds: [UUID]
    public var id: String { question + sourceIds.map(\.uuidString).joined() }
}

public struct SourceGuideResponse: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var sourceLanguage: String
    public var outputLanguage: String
    public var summary: [SourceGuideStatement]
    public var translatedSummary: [SourceGuideStatement]
    public var keyTopics: [SourceGuideTopic]
    public var suggestedQuestions: [SuggestedSourceQuestion]
    public var imageInsights: [SourceGuideStatement]
    public var coverageGaps: [String]
}

public struct SourceQueryResponse: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var answer: [SourceGuideStatement]
    public var insufficientEvidence: Bool
    public var followUpQuestions: [String]
}

public struct SourceAnalysisArtifact: EntityPayload, Equatable {
    public static let entityType = EntityType.aiArtifact
    public var schemaVersion: String
    public var jobId: UUID
    public var sourceId: UUID
    public var sourceVersionId: UUID
    public var generatedAt: Date
    public var pageCount: Int
    public var analyzedPageCount: Int
    public var references: [SourceCitationReference]
    public var trace: ProviderTrace
    public var guide: SourceGuideResponse
    public var createdAt: Date { generatedAt }
    public var updatedAt: Date { generatedAt }
}

public struct SourceQueryArtifact: EntityPayload, Equatable {
    public static let entityType = EntityType.aiArtifact
    public var schemaVersion: String
    public var jobId: UUID
    public var sourceId: UUID
    public var sourceVersionId: UUID
    public var question: String
    public var generatedAt: Date
    public var references: [SourceCitationReference]
    public var trace: ProviderTrace
    public var response: SourceQueryResponse
    public var createdAt: Date { generatedAt }
    public var updatedAt: Date { generatedAt }
}

public struct MediaTranscriptionRequest: Codable, Equatable, Sendable {
    public var schemaVersion = "media-transcription-request/v1"
    public var accountId: UUID
    public var jobId: UUID
    public var sourceId: UUID
    public var sourceVersionId: UUID
    public var sourceType: ResourceKind
    public var assetId: UUID
    public var assetKey: String
    public var expectedDedupeTag: String
    public var expectedPlaintextBytes: Int64
    public var filename: String
    public var mimeType: String
    public var language: String?
    public var disclosureAcknowledged: Bool
    public var providerRoute: AIProviderRouteSnapshot? = nil
}

public struct TranscriptSegment: Codable, Equatable, Sendable, Identifiable {
    public var index: Int
    public var startSeconds: Double
    public var endSeconds: Double
    public var text: String
    public var id: Int { index }

    public init(index: Int, startSeconds: Double, endSeconds: Double, text: String) {
        self.index = index
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
    }
}

public enum TranscriptCorrectionState: String, Codable, Sendable {
    case active = "ACTIVE"
    case superseded = "SUPERSEDED"
    case retracted = "RETRACTED"
}

/// An owner-authored correction. The generated transcript chunk remains immutable.
public struct TranscriptCorrectionPayload: EntityPayload, Equatable {
    public static let entityType = EntityType.transcriptCorrection
    public var schemaVersion = "transcript-correction/v1"
    public var sourceId: UUID
    public var sourceVersionId: UUID
    public var transcriptionArtifactId: UUID
    public var segmentIndex: Int
    public var startSeconds: Double
    public var endSeconds: Double
    public var originalText: String
    public var correctedText: String
    public var reason: String?
    public var state: TranscriptCorrectionState
    public var supersedesCorrectionId: UUID?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        sourceId: UUID,
        sourceVersionId: UUID,
        transcriptionArtifactId: UUID,
        segment: TranscriptSegment,
        correctedText: String,
        reason: String? = nil,
        supersedesCorrectionId: UUID? = nil,
        now: Date = .now
    ) {
        self.sourceId = sourceId
        self.sourceVersionId = sourceVersionId
        self.transcriptionArtifactId = transcriptionArtifactId
        segmentIndex = segment.index
        startSeconds = segment.startSeconds
        endSeconds = segment.endSeconds
        originalText = segment.text
        self.correctedText = correctedText
        self.reason = reason
        state = .active
        self.supersedesCorrectionId = supersedesCorrectionId
        createdAt = now
        updatedAt = now
    }
}

/// Local projection combining one immutable provider segment with an optional active correction.
public struct ReviewedTranscriptSegment: Identifiable, Equatable, Sendable {
    public var original: TranscriptSegment
    public var text: String
    public var correctionId: UUID?
    public var id: Int { original.index }

    public init(original: TranscriptSegment, text: String, correctionId: UUID?) {
        self.original = original
        self.text = text
        self.correctionId = correctionId
    }
}

public struct MediaTranscriptionChunk: Codable, Equatable, Sendable {
    public var schemaVersion = "media-transcription-chunk/v1"
    public var jobId: UUID
    public var sourceId: UUID
    public var sourceVersionId: UUID
    public var chunkIndex: Int
    public var segments: [TranscriptSegment]

    public init(
        jobId: UUID,
        sourceId: UUID,
        sourceVersionId: UUID,
        chunkIndex: Int,
        segments: [TranscriptSegment]
    ) {
        self.jobId = jobId
        self.sourceId = sourceId
        self.sourceVersionId = sourceVersionId
        self.chunkIndex = chunkIndex
        self.segments = segments
    }
}

public struct MediaTranscriptionManifest: EntityPayload, Equatable {
    public static let entityType = EntityType.aiArtifact
    public var schemaVersion = "ai-artifact/media-transcription/v1"
    public var jobId: UUID
    public var sourceId: UUID
    public var sourceVersionId: UUID
    public var generatedAt: Date
    public var language: String?
    public var durationSeconds: Double
    public var characterCount: Int
    public var segmentCount: Int
    public var trace: ProviderTrace
    public var chunkEntityIds: [UUID]
    public var reviewState: AIArtifactReviewState?
    public var reviewedAt: Date?
    public var createdAt: Date { generatedAt }
    public var updatedAt: Date { reviewedAt ?? generatedAt }

    public init(
        jobId: UUID,
        sourceId: UUID,
        sourceVersionId: UUID,
        generatedAt: Date,
        language: String?,
        durationSeconds: Double,
        characterCount: Int,
        segmentCount: Int,
        trace: ProviderTrace,
        chunkEntityIds: [UUID],
        reviewState: AIArtifactReviewState? = nil,
        reviewedAt: Date? = nil
    ) {
        self.jobId = jobId
        self.sourceId = sourceId
        self.sourceVersionId = sourceVersionId
        self.generatedAt = generatedAt
        self.language = language
        self.durationSeconds = durationSeconds
        self.characterCount = characterCount
        self.segmentCount = segmentCount
        self.trace = trace
        self.chunkEntityIds = chunkEntityIds
        self.reviewState = reviewState
        self.reviewedAt = reviewedAt
    }
}

public enum AIJobCoordinatorError: Error, Equatable {
    case sessionNotEnded
    case noReadableSources
    case disclosureNotAcknowledged
    case resourceHasNoPDF
    case sourceAnalysisRequiresPDF
    case sourceQuestionEmpty
    case sourceHasNoTranscribableMedia
    case transcriptionFormatUnsupported
    case transcriptionMediaTooLarge
    case topicRequired
    case invalidTestPlan
    case feedbackRequiresSubmittedResponse
    case attemptNotSubmitted
    case responseEmpty
    case questionNotFound
    case providerRouteUnavailable
}

extension AIJobCoordinatorError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .sessionNotEnded: "End the session before requesting its review."
        case .noReadableSources: "This scope does not contain readable note text or Evidence yet."
        case .disclosureNotAcknowledged: "Review and approve the disclosure before queueing this request."
        case .resourceHasNoPDF: "This Source does not contain a PDF that the trusted Mac can extract."
        case .sourceAnalysisRequiresPDF:
            "Exact Source analysis currently requires a locally available PDF Source Version."
        case .sourceQuestionEmpty: "Enter a question about this Source."
        case .sourceHasNoTranscribableMedia:
            "This Source does not contain a current local audio or video version."
        case .transcriptionFormatUnsupported:
            "This transcription stage supports MP3, M4A, WAV, and MP4 files."
        case .transcriptionMediaTooLarge:
            "This recording exceeds the current 25 MB transcription limit. Import a smaller copy before trying again."
        case .topicRequired: "Choose a Topic before creating a learning request."
        case .invalidTestPlan: "A test plan needs at least one objective and one coverage dimension."
        case .feedbackRequiresSubmittedResponse:
            "Free-response feedback must be requested from a submitted test response."
        case .attemptNotSubmitted: "Submit the test before requesting feedback."
        case .responseEmpty: "Write an answer before requesting feedback."
        case .questionNotFound: "The frozen question is no longer available in this attempt."
        case .providerRouteUnavailable:
            "Wait for the selected AI provider configuration to finish before approving a request."
        }
    }
}

public actor AIJobCoordinator {
    let accountId: UUID
    let accountKey: Data
    private let database: SQLCipherDatabase
    private let store: EpistoriaStore
    let api: EpistoriaAPIClient
    private let crypto = EntityCrypto()
    private var providerRouteSnapshot: AIProviderRouteSnapshot?
    private var requiresProviderRouteSnapshot: Bool

    public init(
        accountId: UUID,
        accountKey: Data,
        store: EpistoriaStore,
        api: EpistoriaAPIClient,
        providerRouteSnapshot: AIProviderRouteSnapshot? = nil,
        requiresProviderRouteSnapshot: Bool = false
    ) {
        self.accountId = accountId
        self.accountKey = accountKey
        self.store = store
        database = store.database
        self.api = api
        self.providerRouteSnapshot = providerRouteSnapshot
        self.requiresProviderRouteSnapshot = requiresProviderRouteSnapshot
    }

    public func setProviderRouteSnapshot(
        _ snapshot: AIProviderRouteSnapshot?,
        required: Bool
    ) {
        providerRouteSnapshot = snapshot
        requiresProviderRouteSnapshot = required
    }

    private func reviewedProviderRoute() throws -> AIProviderRouteSnapshot? {
        if requiresProviderRouteSnapshot, providerRouteSnapshot == nil {
            throw AIJobCoordinatorError.providerRouteUnavailable
        }
        return providerRouteSnapshot
    }

    public func prepareSessionDigest(
        sessionId: UUID,
        userInstructions: String? = nil
    ) async throws -> PreparedDigestRequest {
        let session = try await store.payload(StudySessionPayload.self, id: sessionId).payload
        guard session.state == .ended, let endedAt = session.endedAt else {
            throw AIJobCoordinatorError.sessionNotEnded
        }
        var sources: [DigestSourceExcerpt] = []
        let linkedNoteIds = try await store.noteIdsLinkedToSession(sessionId)
        let notes = try await store.list(NotePayload.self)
            .filter { linkedNoteIds.contains($0.id) }
        for note in notes {
            let blocks = try await store.list(NoteBlockPayload.self, parentId: note.id)
                .sorted { $0.payload.orderKey < $1.payload.orderKey }
            for block in blocks {
                let text = [block.payload.plainText, block.payload.transcription]
                    .compactMap(\ .self)
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                sources.append(
                    DigestSourceExcerpt(
                        sourceId: block.id,
                        sourceKind: .noteBlock,
                        title: note.payload.title,
                        locator: "block \(block.payload.orderKey)",
                        excerpt: String(text.prefix(12_000))
                    )
                )
            }
        }
        let annotations = try await store.list(AnnotationPayload.self)
            .filter { $0.payload.studySessionId == sessionId }
        for annotation in annotations {
            let text = [annotation.payload.selectedText, annotation.payload.comment]
                .compactMap(\ .self)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            sources.append(
                DigestSourceExcerpt(
                    sourceId: annotation.id,
                    sourceKind: .annotation,
                    title: annotation.payload.annotationType.rawValue.capitalized,
                    locator: annotation.payload.pageNumber.map { "page \($0)" } ?? "annotation",
                    excerpt: String(text.prefix(12_000))
                )
            )
        }
        guard !sources.isEmpty else { throw AIJobCoordinatorError.noReadableSources }
        sources = Array(sources.prefix(200))
        let jobId = UUID()
        let request = SessionDigestRequest(
            accountId: accountId,
            jobId: jobId,
            sessionId: sessionId,
            courseId: session.courseId,
            sessionTitle: session.title,
            startedAt: session.startedAt,
            endedAt: endedAt,
            sources: sources,
            userInstructions: userInstructions,
            disclosureAcknowledged: false
        )
        let characters = sources.reduce(0) { $0 + $1.excerpt.count }
        return PreparedDigestRequest(
            request: request,
            preview: DigestDisclosurePreview(
                sourceCount: sources.count,
                characterCount: characters,
                approximateTokens: max(1, characters / 4),
                sourceTitles: Array(Set(sources.map(\.title))).sorted()
            )
        )
    }

    public func submitSessionDigest(_ prepared: PreparedDigestRequest) async throws -> AIJobSummary {
        var request = prepared.request
        guard !request.sources.isEmpty else { throw AIJobCoordinatorError.noReadableSources }
        request.disclosureAcknowledged = true
        request.providerRoute = try reviewedProviderRoute()
        let plaintext = try CanonicalJSON.encode(request)
        let envelope = try crypto.encryptJob(
            plaintext,
            accountKey: accountKey,
            accountId: accountId,
            jobType: "SESSION_DIGEST",
            jobId: request.jobId
        )
        return try await api.createAIJob(
            id: request.jobId,
            type: "SESSION_DIGEST",
            envelope: envelope
        )
    }

    public func latestDigest(sessionId: UUID) async throws -> IdentifiedPayload<SessionDigestArtifact>? {
        let entities = try await database.entities(type: .aiArtifact, parentId: sessionId)
        for entity in entities {
            if let artifact = try? CanonicalJSON.decode(
                SessionDigestArtifact.self,
                from: entity.content
            ) {
                return IdentifiedPayload(
                    id: entity.id,
                    payload: artifact,
                    revision: entity.revision,
                    syncState: entity.syncState
                )
            }
        }
        return nil
    }

    public func submitPDFExtraction(resourceId: UUID) async throws -> AIJobSummary {
        let resource = try await store.payload(ResourcePayload.self, id: resourceId).payload
        guard resource.resourceType == .pdf, let assetId = resource.originalAssetId else {
            throw AIJobCoordinatorError.resourceHasNoPDF
        }
        let asset = try await store.payload(AssetPayload.self, id: assetId).payload
        let jobId = UUID()
        let request = PDFExtractionRequest(
            accountId: accountId,
            jobId: jobId,
            resourceId: resourceId,
            assetId: assetId,
            assetKey: asset.assetKey,
            expectedDedupeTag: asset.dedupeTag,
            title: resource.title
        )
        let envelope = try crypto.encryptJob(
            CanonicalJSON.encode(request),
            accountKey: accountKey,
            accountId: accountId,
            jobType: "PDF_EXTRACTION",
            jobId: jobId
        )
        return try await api.createAIJob(id: jobId, type: "PDF_EXTRACTION", envelope: envelope)
    }

    public func latestPDFExtraction(
        resourceId: UUID
    ) async throws -> IdentifiedPayload<PDFExtractionManifest>? {
        let entities = try await database.entities(type: .aiArtifact, parentId: resourceId)
        for entity in entities {
            if let artifact = try? CanonicalJSON.decode(PDFExtractionManifest.self, from: entity.content),
               artifact.resourceId == resourceId
            {
                return IdentifiedPayload(
                    id: entity.id,
                    payload: artifact,
                    revision: entity.revision,
                    syncState: entity.syncState
                )
            }
        }
        return nil
    }

    public func submitSourceAnalysis(
        sourceId: UUID,
        outputLanguage: String,
        includeImages: Bool = true,
        disclosureAcknowledged: Bool
    ) async throws -> AIJobSummary {
        guard disclosureAcknowledged else {
            throw AIJobCoordinatorError.disclosureNotAcknowledged
        }
        let context = try await sourcePDFContext(sourceId: sourceId)
        let jobId = UUID()
        let request = SourceAnalysisRequest(
            accountId: accountId,
            jobId: jobId,
            sourceId: sourceId,
            sourceVersionId: context.versionId,
            title: context.title,
            outputLanguage: normalizedOutputLanguage(outputLanguage),
            assetId: context.assetId,
            assetKey: context.asset.assetKey,
            expectedDedupeTag: context.asset.dedupeTag,
            includeImages: includeImages,
            disclosureAcknowledged: true,
            providerRoute: try reviewedProviderRoute()
        )
        let envelope = try crypto.encryptJob(
            CanonicalJSON.encode(request),
            accountKey: accountKey,
            accountId: accountId,
            jobType: "SOURCE_ANALYSIS",
            jobId: jobId
        )
        return try await api.createAIJob(
            id: jobId, type: "SOURCE_ANALYSIS", envelope: envelope
        )
    }

    public func submitSourceQuery(
        sourceId: UUID,
        question: String,
        outputLanguage: String,
        includeImages: Bool = true,
        disclosureAcknowledged: Bool
    ) async throws -> AIJobSummary {
        guard disclosureAcknowledged else {
            throw AIJobCoordinatorError.disclosureNotAcknowledged
        }
        let cleanQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuestion.isEmpty else { throw AIJobCoordinatorError.sourceQuestionEmpty }
        let context = try await sourcePDFContext(sourceId: sourceId)
        let jobId = UUID()
        let request = SourceQueryRequest(
            accountId: accountId,
            jobId: jobId,
            sourceId: sourceId,
            sourceVersionId: context.versionId,
            title: context.title,
            outputLanguage: normalizedOutputLanguage(outputLanguage),
            assetId: context.assetId,
            assetKey: context.asset.assetKey,
            expectedDedupeTag: context.asset.dedupeTag,
            includeImages: includeImages,
            disclosureAcknowledged: true,
            question: String(cleanQuestion.prefix(2_000)),
            providerRoute: try reviewedProviderRoute()
        )
        let envelope = try crypto.encryptJob(
            CanonicalJSON.encode(request),
            accountKey: accountKey,
            accountId: accountId,
            jobType: "SOURCE_QUERY",
            jobId: jobId
        )
        return try await api.createAIJob(id: jobId, type: "SOURCE_QUERY", envelope: envelope)
    }

    public func latestSourceAnalysis(
        sourceId: UUID,
        sourceVersionId: UUID? = nil
    ) async throws -> IdentifiedPayload<SourceAnalysisArtifact>? {
        let candidates = try await database.entities(type: .aiArtifact, parentId: sourceId)
            .compactMap { entity -> IdentifiedPayload<SourceAnalysisArtifact>? in
                guard let artifact = try? CanonicalJSON.decode(
                    SourceAnalysisArtifact.self, from: entity.content
                ), artifact.sourceId == sourceId,
                   sourceVersionId.map({ artifact.sourceVersionId == $0 }) ?? true
                else { return nil }
                return IdentifiedPayload(
                    id: entity.id,
                    payload: artifact,
                    revision: entity.revision,
                    syncState: entity.syncState
                )
            }
        return candidates.max { $0.payload.generatedAt < $1.payload.generatedAt }
    }

    public func sourceQueryArtifacts(
        sourceId: UUID,
        sourceVersionId: UUID? = nil
    ) async throws -> [IdentifiedPayload<SourceQueryArtifact>] {
        try await database.entities(type: .aiArtifact, parentId: sourceId)
            .compactMap { entity -> IdentifiedPayload<SourceQueryArtifact>? in
                guard let artifact = try? CanonicalJSON.decode(
                    SourceQueryArtifact.self, from: entity.content
                ), artifact.sourceId == sourceId,
                   sourceVersionId.map({ artifact.sourceVersionId == $0 }) ?? true
                else { return nil }
                return IdentifiedPayload(
                    id: entity.id,
                    payload: artifact,
                    revision: entity.revision,
                    syncState: entity.syncState
                )
            }
            .sorted { $0.payload.generatedAt > $1.payload.generatedAt }
    }

    private func sourcePDFContext(sourceId: UUID) async throws -> (
        title: String, versionId: UUID, assetId: UUID, asset: AssetPayload
    ) {
        let source = try await store.payload(SourcePayload.self, id: sourceId).payload
        guard source.sourceType == .pdf,
              let versionId = source.currentVersionId,
              let version = try? await store.payload(SourceVersionPayload.self, id: versionId).payload,
              version.sourceId == sourceId,
              let assetId = version.originalAssetId,
              let asset = try? await store.payload(AssetPayload.self, id: assetId).payload
        else { throw AIJobCoordinatorError.sourceAnalysisRequiresPDF }
        return (source.title, versionId, assetId, asset)
    }

    private func normalizedOutputLanguage(_ value: String) -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty { return String(clean.prefix(64)) }
        return Locale.current.localizedString(forLanguageCode: Locale.current.language.languageCode?.identifier ?? "en")
            ?? "English"
    }

    public func submitMediaTranscription(
        sourceId: UUID,
        language: String? = nil,
        disclosureAcknowledged: Bool
    ) async throws -> AIJobSummary {
        guard disclosureAcknowledged else {
            throw AIJobCoordinatorError.disclosureNotAcknowledged
        }
        let source = try await store.payload(SourcePayload.self, id: sourceId).payload
        guard [.audio, .video].contains(source.sourceType),
              let sourceVersionId = source.currentVersionId,
              let assetId = source.originalAssetId
        else { throw AIJobCoordinatorError.sourceHasNoTranscribableMedia }
        let version = try await store.payload(SourceVersionPayload.self, id: sourceVersionId).payload
        guard version.sourceId == sourceId, version.originalAssetId == assetId else {
            throw AIJobCoordinatorError.sourceHasNoTranscribableMedia
        }
        let asset = try await store.payload(AssetPayload.self, id: assetId).payload
        guard asset.plaintextByteSize <= 25 * 1_024 * 1_024 else {
            throw AIJobCoordinatorError.transcriptionMediaTooLarge
        }
        let ext = URL(fileURLWithPath: asset.originalFilename).pathExtension.lowercased()
        let supportedExtensions = source.sourceType == .audio
            ? ["mp3", "m4a", "wav"]
            : ["mp4"]
        guard supportedExtensions.contains(ext) else {
            throw AIJobCoordinatorError.transcriptionFormatUnsupported
        }
        let cleanLanguage = language?.trimmingCharacters(in: .whitespacesAndNewlines)
        let jobId = UUID()
        let request = MediaTranscriptionRequest(
            accountId: accountId,
            jobId: jobId,
            sourceId: sourceId,
            sourceVersionId: sourceVersionId,
            sourceType: source.sourceType,
            assetId: assetId,
            assetKey: asset.assetKey,
            expectedDedupeTag: asset.dedupeTag,
            expectedPlaintextBytes: asset.plaintextByteSize,
            filename: asset.originalFilename,
            mimeType: asset.mimeType,
            language: cleanLanguage?.isEmpty == false ? cleanLanguage : nil,
            disclosureAcknowledged: true,
            providerRoute: try reviewedProviderRoute()
        )
        let envelope = try crypto.encryptJob(
            CanonicalJSON.encode(request),
            accountKey: accountKey,
            accountId: accountId,
            jobType: "TRANSCRIPTION",
            jobId: jobId
        )
        return try await api.createAIJob(id: jobId, type: "TRANSCRIPTION", envelope: envelope)
    }

    public func latestMediaTranscription(
        sourceId: UUID,
        sourceVersionId: UUID? = nil
    ) async throws -> IdentifiedPayload<MediaTranscriptionManifest>? {
        let candidates = try await database.entities(type: .aiArtifact, parentId: sourceId)
            .compactMap { entity -> IdentifiedPayload<MediaTranscriptionManifest>? in
                guard let artifact = try? CanonicalJSON.decode(
                    MediaTranscriptionManifest.self,
                    from: entity.content
                ), artifact.sourceId == sourceId,
                   sourceVersionId.map({ artifact.sourceVersionId == $0 }) ?? true
                else { return nil }
                return IdentifiedPayload(
                    id: entity.id,
                    payload: artifact,
                    revision: entity.revision,
                    syncState: entity.syncState
                )
            }
        return candidates.max { $0.payload.generatedAt < $1.payload.generatedAt }
    }

    public func mediaTranscriptionSegments(
        manifest: MediaTranscriptionManifest
    ) async throws -> [TranscriptSegment] {
        var chunks: [MediaTranscriptionChunk] = []
        for id in manifest.chunkEntityIds {
            guard let entity = try await database.entity(id: id),
                  let chunk = try? CanonicalJSON.decode(MediaTranscriptionChunk.self, from: entity.content),
                  chunk.jobId == manifest.jobId,
                  chunk.sourceId == manifest.sourceId,
                  chunk.sourceVersionId == manifest.sourceVersionId
            else { throw StoreError.entityNotFound }
            chunks.append(chunk)
        }
        return chunks.sorted { $0.chunkIndex < $1.chunkIndex }.flatMap(\.segments)
    }

    // MARK: - Note Query

    public func prepareNoteQuery(
        noteId: UUID,
        selectedBlockIds: [UUID],
        selectionImagesByBlockId: [UUID: Data],
        question: String
    ) async throws -> PreparedNoteQueryRequest {
        guard !selectedBlockIds.isEmpty else {
            throw AIJobCoordinatorError.noReadableSources
        }
        let note = try await store.payload(NotePayload.self, id: noteId).payload
        let allBlocks = try await store.list(NoteBlockPayload.self, parentId: noteId)
            .sorted { $0.payload.orderKey < $1.payload.orderKey }

        let selectedSet = Set(selectedBlockIds)
        var selectionSources: [NoteQuerySourceExcerpt] = []
        var contextSources: [NoteQuerySourceExcerpt] = []

        for block in allBlocks {
            let isSelected = selectedSet.contains(block.id)
            if isSelected {
                if let imageData = selectionImagesByBlockId[block.id] {
                    // Selected Pencil or canvas-image visual — send as a bounded PNG.
                    selectionSources.append(
                        NoteQuerySourceExcerpt(
                            sourceId: block.id,
                            sourceKind: .lassoSelection,
                            title: note.title,
                            locator: "selected visual \(block.payload.orderKey)",
                            imageContent: imageData.base64EncodedString()
                        )
                    )
                } else {
                    // Text item (or handwriting with transcription).
                    let text = [block.payload.plainText, block.payload.transcription]
                        .compactMap(\.self)
                        .joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    selectionSources.append(
                        NoteQuerySourceExcerpt(
                            sourceId: block.id,
                            sourceKind: .noteBlock,
                            title: note.title,
                            locator: "canvas item \(block.payload.orderKey)",
                            excerpt: String(text.prefix(12_000))
                        )
                    )
                }
            } else {
                // Context-only: text and transcriptions, no images.
                let text = [block.payload.plainText, block.payload.transcription]
                    .compactMap(\.self)
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                contextSources.append(
                    NoteQuerySourceExcerpt(
                        sourceId: block.id,
                        sourceKind: .noteBlock,
                        title: note.title,
                        locator: "context item \(block.payload.orderKey)",
                        excerpt: String(text.prefix(12_000))
                    )
                )
            }
        }

        guard !selectionSources.isEmpty else {
            throw AIJobCoordinatorError.noReadableSources
        }
        selectionSources = Array(selectionSources.prefix(10))
        contextSources = Array(contextSources.prefix(200))

        let jobId = UUID()
        let request = NoteQueryRequest(
            accountId: accountId,
            jobId: jobId,
            noteId: noteId,
            noteTitle: note.title,
            question: question,
            selectionSources: selectionSources,
            contextSources: contextSources,
            disclosureAcknowledged: false
        )
        let hasImages = selectionSources.contains { $0.imageContent != nil }
        let characters = (selectionSources + contextSources)
            .compactMap(\.excerpt)
            .reduce(0) { $0 + $1.count }
        let imageTokenEstimate = selectionSources.filter { $0.imageContent != nil }.count * 500
        return PreparedNoteQueryRequest(
            request: request,
            selectionCount: selectionSources.count,
            contextCount: contextSources.count,
            hasImages: hasImages,
            approximateTokens: max(1, characters / 4 + imageTokenEstimate)
        )
    }

    public func submitNoteQuery(_ prepared: PreparedNoteQueryRequest) async throws -> AIJobSummary {
        var request = prepared.request
        guard !request.selectionSources.isEmpty else {
            throw AIJobCoordinatorError.noReadableSources
        }
        request.disclosureAcknowledged = true
        request.providerRoute = try reviewedProviderRoute()
        let plaintext = try CanonicalJSON.encode(request)
        let envelope = try crypto.encryptJob(
            plaintext,
            accountKey: accountKey,
            accountId: accountId,
            jobType: "NOTE_QUERY",
            jobId: request.jobId
        )
        return try await api.createAIJob(
            id: request.jobId,
            type: "NOTE_QUERY",
            envelope: envelope
        )
    }

    public func latestNoteQueryArtifacts(
        noteId: UUID
    ) async throws -> [IdentifiedPayload<NoteQueryArtifact>] {
        let entities = try await database.entities(type: .aiArtifact, parentId: noteId)
        return entities.compactMap { entity in
            guard let artifact = try? CanonicalJSON.decode(NoteQueryArtifact.self, from: entity.content),
                  artifact.noteId == noteId
            else { return nil }
            return IdentifiedPayload(
                id: entity.id,
                payload: artifact,
                revision: entity.revision,
                syncState: entity.syncState
            )
        }
        .sorted { $0.payload.generatedAt > $1.payload.generatedAt }
    }

    public func detectTestObjectives(
        topicId: UUID,
        includeConnectedKnowledge: Bool = false
    ) async throws -> [DetectedTestObjective] {
        _ = try await store.topic(id: topicId)
        let scopedTopicIds = try await topicScopeIds(
            topicId: topicId,
            includeConnectedKnowledge: includeConnectedKnowledge
        )
        let concepts = try await store.list(ConceptPayload.self).filter {
            $0.payload.state == .active && !$0.payload.topicIds.filter(scopedTopicIds.contains).isEmpty
        }
        let sources = try await store.list(SourcePayload.self).filter {
            $0.payload.archivedAt == nil
                && ($0.payload.primaryTopicId.map(scopedTopicIds.contains) == true
                    || !$0.payload.relatedTopicIds.filter(scopedTopicIds.contains).isEmpty)
        }
        let notes = try await store.list(NotePayload.self).filter {
            $0.payload.archivedAt == nil && ($0.payload.courseId.map(scopedTopicIds.contains) ?? false)
        }
        let questions = try await store.list(UnresolvedQuestionPayload.self).filter {
            $0.payload.resolvedAt == nil && scopedTopicIds.contains($0.payload.topicId)
        }

        struct Candidate {
            var title: String
            var count: Int
            var origin: String
        }
        var candidates: [String: Candidate] = [:]
        func add(_ rawTitle: String, origin: String) {
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.localizedCaseInsensitiveCompare("Untitled") != .orderedSame else { return }
            let key = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            if var existing = candidates[key] {
                existing.count += 1
                candidates[key] = existing
            } else {
                candidates[key] = Candidate(title: title, count: 1, origin: origin)
            }
        }
        concepts.forEach { add($0.payload.name, origin: "Concept") }
        sources.forEach { add($0.payload.title, origin: "Source") }
        notes.forEach { add($0.payload.title, origin: "Note") }
        questions.forEach { add($0.payload.question, origin: "Open question") }

        return candidates.values
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            .prefix(50)
            .map { DetectedTestObjective(
                title: $0.title,
                supportingRecordCount: $0.count,
                origin: $0.origin
            ) }
    }

    public func prepareFreeResponseFeedback(
        attemptId: UUID,
        responseId: UUID
    ) async throws -> PreparedFreeResponseFeedbackRequest {
        let attempt = try await store.payload(TestAttemptPayload.self, id: attemptId)
        guard [.submitted, .scored].contains(attempt.payload.state) else {
            throw AIJobCoordinatorError.attemptNotSubmitted
        }
        let savedResponse = try await store.payload(TestResponsePayload.self, id: responseId)
        guard savedResponse.payload.attemptId == attemptId else {
            throw AIJobCoordinatorError.questionNotFound
        }
        let userResponse = savedResponse.payload.response
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userResponse.isEmpty, !savedResponse.payload.isSkipped else {
            throw AIJobCoordinatorError.responseEmpty
        }
        guard let question = attempt.payload.frozenQuestions.first(where: {
            $0.questionId == savedResponse.payload.questionId
        }) else { throw AIJobCoordinatorError.questionNotFound }

        let snapshotText = """
        Question: \(question.prompt)
        Grading guide: \(question.rubric)
        Reference answer: \(question.correctAnswer)
        """
        var evidence = [FeedbackEvidenceExcerpt(
            sourceId: question.questionId,
            sourceKind: .questionSnapshot,
            title: "Frozen question and grading guide",
            locator: "attempt \(attemptId.uuidString), question \(question.questionId.uuidString)",
            excerpt: String(snapshotText.prefix(12_000))
        )]
        var seenIds: Set<UUID> = [question.questionId]
        for evidenceId in question.evidenceIds where !seenIds.contains(evidenceId) {
            guard let entity = try await database.entity(id: evidenceId) else { continue }
            let excerpt: FeedbackEvidenceExcerpt?
            switch entity.entityType {
            case .noteBlock:
                guard let block = try? CanonicalJSON.decode(NoteBlockPayload.self, from: entity.content) else {
                    continue
                }
                let text = [block.plainText, block.transcription]
                    .compactMap(\ .self)
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                excerpt = text.isEmpty ? nil : FeedbackEvidenceExcerpt(
                    sourceId: evidenceId,
                    sourceKind: .noteBlock,
                    title: "Note evidence",
                    locator: "note block \(evidenceId.uuidString)",
                    excerpt: String(text.prefix(12_000))
                )
            case .evidence:
                guard let item = try? CanonicalJSON.decode(EvidencePayload.self, from: entity.content) else {
                    continue
                }
                let text = [item.excerpt, item.note]
                    .compactMap(\ .self)
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                excerpt = text.isEmpty ? nil : FeedbackEvidenceExcerpt(
                    sourceId: evidenceId,
                    sourceKind: .evidence,
                    title: "Saved Evidence",
                    locator: item.locator.kind.rawValue,
                    excerpt: String(text.prefix(12_000))
                )
            default:
                excerpt = nil
            }
            if let excerpt {
                evidence.append(excerpt)
                seenIds.insert(evidenceId)
            }
            if evidence.count == 50 { break }
        }

        let jobId = UUID()
        let request = FreeResponseFeedbackRequest(
            accountId: accountId,
            jobId: jobId,
            attemptId: attemptId,
            responseId: responseId,
            questionId: question.questionId,
            topicId: attempt.payload.topicId,
            questionKind: question.kind,
            prompt: question.prompt,
            rubric: question.rubric,
            referenceAnswer: question.correctAnswer,
            userResponse: userResponse,
            confidence: savedResponse.payload.confidence,
            evidence: evidence,
            disclosureAcknowledged: false
        )
        let characterCount = evidence.reduce(0) { $0 + $1.excerpt.count }
            + request.prompt.count + request.rubric.count
            + request.referenceAnswer.count + request.userResponse.count
        return PreparedFreeResponseFeedbackRequest(
            request: request,
            evidenceCount: evidence.count,
            approximateTokens: max(1, characterCount / 4)
        )
    }

    public func submitFreeResponseFeedback(
        _ prepared: PreparedFreeResponseFeedbackRequest
    ) async throws -> AIJobSummary {
        var request = prepared.request
        guard !request.evidence.isEmpty else { throw AIJobCoordinatorError.noReadableSources }
        request.disclosureAcknowledged = true
        request.providerRoute = try reviewedProviderRoute()
        let type = LearningAIJobType.freeResponseFeedback.rawValue
        let envelope = try crypto.encryptJob(
            CanonicalJSON.encode(request),
            accountKey: accountKey,
            accountId: accountId,
            jobType: type,
            jobId: request.jobId
        )
        return try await api.createAIJob(id: request.jobId, type: type, envelope: envelope)
    }

    public func latestFreeResponseFeedback(
        attemptId: UUID,
        responseId: UUID
    ) async throws -> IdentifiedPayload<FreeResponseFeedbackArtifact>? {
        let entities = try await database.entities(type: .aiArtifact, parentId: attemptId)
        return entities.compactMap { entity in
            guard let artifact = try? CanonicalJSON.decode(
                FreeResponseFeedbackArtifact.self,
                from: entity.content
            ), artifact.responseId == responseId else { return nil }
            return IdentifiedPayload(
                id: entity.id,
                payload: artifact,
                revision: entity.revision,
                syncState: entity.syncState
            )
        }
        .max { $0.payload.generatedAt < $1.payload.generatedAt }
    }

    public func prepareTopicGeneration(
        topicId: UUID,
        jobType: LearningAIJobType,
        objectiveTitles: [String] = [],
        testPlan: TestGenerationPlan? = nil,
        userInstructions: String? = nil,
        includeConnectedKnowledge: Bool = false
    ) async throws -> PreparedLearningGenerationRequest {
        guard jobType != .freeResponseFeedback else {
            throw AIJobCoordinatorError.feedbackRequiresSubmittedResponse
        }
        _ = try await store.topic(id: topicId)
        if let testPlan {
            guard [.testBlueprint, .testGeneration].contains(jobType),
                  !testPlan.objectiveTitles.isEmpty,
                  !testPlan.coverageDimensions.isEmpty,
                  testPlan.objectiveTitles == objectiveTitles
            else { throw AIJobCoordinatorError.invalidTestPlan }
        }
        let scopedTopicIds = try await topicScopeIds(
            topicId: topicId,
            includeConnectedKnowledge: includeConnectedKnowledge
        )
        var excerpts: [DigestSourceExcerpt] = []
        let notes = try await store.list(NotePayload.self).filter { note in
            note.payload.courseId.map(scopedTopicIds.contains) ?? false
        }
        for note in notes {
            let blocks = try await store.list(NoteBlockPayload.self, parentId: note.id)
                .sorted { $0.payload.orderKey < $1.payload.orderKey }
            for block in blocks {
                let text = [block.payload.plainText, block.payload.transcription]
                    .compactMap(\ .self).joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                excerpts.append(DigestSourceExcerpt(
                    sourceId: block.id,
                    sourceKind: .noteBlock,
                    title: note.payload.title,
                    locator: "note block \(block.payload.orderKey)",
                    excerpt: String(text.prefix(12_000))
                ))
            }
        }
        let evidence = try await store.list(EvidencePayload.self)
        let topicSources = try await store.list(SourcePayload.self).filter {
            $0.payload.primaryTopicId.map(scopedTopicIds.contains) == true
                || !$0.payload.relatedTopicIds.filter(scopedTopicIds.contains).isEmpty
        }
        let sourceIds = Set(topicSources.map(\.id))
        for item in evidence where sourceIds.contains(item.payload.sourceId) {
            excerpts.append(DigestSourceExcerpt(
                sourceId: item.id,
                sourceKind: .annotation,
                title: "Evidence",
                locator: item.payload.locator.kind.rawValue,
                excerpt: String(item.payload.excerpt.prefix(12_000))
            ))
        }
        guard !excerpts.isEmpty else { throw AIJobCoordinatorError.noReadableSources }
        excerpts = Array(excerpts.prefix(200))
        let knownConcepts = try await store.list(ConceptPayload.self)
            .filter { concept in
                concept.payload.state == .active
                    && !concept.payload.topicIds.filter(scopedTopicIds.contains).isEmpty
            }
            .sorted { $0.payload.name.localizedCaseInsensitiveCompare($1.payload.name) == .orderedAscending }
            .prefix(200)
            .map {
                KnownConceptReference(
                    id: $0.id,
                    name: $0.payload.name,
                    aliases: $0.payload.aliases
                )
            }
        let jobId = UUID()
        let request = LearningGenerationRequest(
            accountId: accountId,
            jobId: jobId,
            jobType: jobType,
            topicId: topicId,
            includeConnectedKnowledge: includeConnectedKnowledge,
            userInstructions: userInstructions,
            sources: excerpts,
            knownConcepts: jobType == .conceptSuggestions ? knownConcepts : [],
            objectiveTitles: objectiveTitles,
            testPlan: testPlan,
            disclosureAcknowledged: false
        )
        let characters = excerpts.reduce(0) { $0 + $1.excerpt.count }
        return PreparedLearningGenerationRequest(
            request: request,
            sourceCount: excerpts.count,
            approximateTokens: max(1, characters / 4)
        )
    }

    private func topicScopeIds(
        topicId: UUID,
        includeConnectedKnowledge: Bool
    ) async throws -> Set<UUID> {
        var scopedTopicIds: Set<UUID> = [topicId]
        guard includeConnectedKnowledge else { return scopedTopicIds }
        let topicRelations = try await store.list(TopicAreaRelationPayload.self)
        let areas = Set(topicRelations.lazy
            .filter { $0.payload.topicId == topicId }
            .map(\.payload.areaId))
        if !areas.isEmpty {
            scopedTopicIds.formUnion(topicRelations.lazy
                .filter { areas.contains($0.payload.areaId) }
                .map(\.payload.topicId))
        }
        return scopedTopicIds
    }

    public func submitTopicGeneration(
        _ prepared: PreparedLearningGenerationRequest
    ) async throws -> AIJobSummary {
        var request = prepared.request
        guard !request.sources.isEmpty else { throw AIJobCoordinatorError.noReadableSources }
        request.disclosureAcknowledged = true
        request.providerRoute = try reviewedProviderRoute()
        let type = request.jobType.rawValue
        let envelope = try crypto.encryptJob(
            CanonicalJSON.encode(request),
            accountKey: accountKey,
            accountId: accountId,
            jobType: type,
            jobId: request.jobId
        )
        return try await api.createAIJob(id: request.jobId, type: type, envelope: envelope)
    }

    public func runDueAutomations(at date: Date = .now) async throws -> [AutomationQueueOutcome] {
        let grants = try await store.list(AutomationGrantPayload.self)
            .sorted { $0.payload.createdAt < $1.payload.createdAt }
        let artifacts = try await database.entities(type: .aiArtifact).compactMap { entity in
            try? CanonicalJSON.decode(LearningGenerationArtifact.self, from: entity.content)
        }
        var outcomes: [AutomationQueueOutcome] = []

        for identified in grants where identified.payload.revokedAt == nil {
            var grant = identified.payload
            let queuedIds = Set(grant.queuedJobIds ?? [])
            let estimatedSpent = artifacts.reduce(0) { total, artifact in
                guard queuedIds.contains(artifact.jobId),
                      let dollars = artifact.trace.estimatedCostUsd
                else { return total }
                return total + max(Int((dollars * 100).rounded()), 0)
            }
            grant.estimatedSpentMinorUnits = estimatedSpent
            grant.lastQueuedAtByScope = grant.lastQueuedAtByScope ?? [:]
            grant.lastInputFingerprintByScope = grant.lastInputFingerprintByScope ?? [:]
            grant.queuedJobIds = grant.queuedJobIds ?? []
            guard grant.isActive(at: date) else { continue }

            for topicId in grant.topicIds {
                for configuredType in grant.jobTypes {
                    guard let jobType = configuredType.learningJobType else { continue }
                    let scopeKey = "\(topicId.uuidString.lowercased()):\(jobType.rawValue)"
                    if let last = grant.lastQueuedAtByScope?[scopeKey],
                       date.timeIntervalSince(last) < Double(grant.minimumIntervalHours * 3_600) {
                        outcomes.append(.notDue(
                            grantId: identified.id,
                            topicId: topicId,
                            jobType: jobType
                        ))
                        continue
                    }
                    do {
                        var prepared = try await prepareTopicGeneration(
                            topicId: topicId,
                            jobType: jobType
                        )
                        let fingerprint = try automationFingerprint(for: prepared.request)
                        if grant.lastInputFingerprintByScope?[scopeKey] == fingerprint {
                            outcomes.append(.unchanged(
                                grantId: identified.id,
                                topicId: topicId,
                                jobType: jobType
                            ))
                            continue
                        }
                        let jobId = Self.automaticJobId(
                            grantId: identified.id,
                            scopeKey: scopeKey,
                            fingerprint: fingerprint
                        )
                        prepared.request.jobId = jobId
                        prepared.request.schemaVersion = "learning-generation-request/v4"
                        prepared.request.automationAuthorization = AutomationAuthorization(
                            grantId: identified.id,
                            topicIds: grant.topicIds,
                            jobTypes: grant.jobTypes.compactMap(\.learningJobType),
                            minimumIntervalHours: grant.minimumIntervalHours,
                            expiresAt: grant.expiresAt,
                            spendingLimitMinorUnits: grant.spendingLimitMinorUnits,
                            currencyCode: grant.currencyCode,
                            authorizedAt: date,
                            scopeKey: scopeKey,
                            inputFingerprint: fingerprint
                        )
                        _ = try await submitTopicGeneration(prepared)
                        try await store.recordAutomationQueue(
                            grantId: identified.id,
                            scopeKey: scopeKey,
                            fingerprint: fingerprint,
                            jobId: jobId,
                            estimatedSpentMinorUnits: estimatedSpent,
                            at: date
                        )
                        grant.lastQueuedAtByScope?[scopeKey] = date
                        grant.lastInputFingerprintByScope?[scopeKey] = fingerprint
                        if grant.queuedJobIds?.contains(jobId) == false {
                            grant.queuedJobIds?.append(jobId)
                        }
                        outcomes.append(.queued(
                            jobId: jobId,
                            grantId: identified.id,
                            topicId: topicId,
                            jobType: jobType
                        ))
                    } catch {
                        outcomes.append(.unavailable(
                            grantId: identified.id,
                            topicId: topicId,
                            jobType: jobType,
                            reason: error.localizedDescription
                        ))
                    }
                }
            }
        }
        return outcomes
    }

    public func setAutomationGrantPaused(id: UUID, paused: Bool) async throws {
        let jobIds = try await store.setAutomationGrantPaused(id: id, paused: paused)
        if paused { await cancelNonterminalJobs(jobIds) }
    }

    public func revokeAutomationGrant(id: UUID) async throws {
        let jobIds = try await store.revokeAutomationGrant(id: id)
        await cancelNonterminalJobs(jobIds)
    }

    private func cancelNonterminalJobs(_ ids: [UUID]) async {
        for id in ids {
            guard let summary = try? await api.aiJob(id: id),
                  summary.status == "PENDING" || summary.status == "LEASED"
            else { continue }
            _ = try? await api.cancelAIJob(id: id)
        }
    }

    private func automationFingerprint(for request: LearningGenerationRequest) throws -> String {
        struct Input: Codable {
            var schemaVersion = "automation-input/v1"
            var topicId: UUID
            var jobType: LearningAIJobType
            var includeConnectedKnowledge: Bool
            var userInstructions: String?
            var sources: [DigestSourceExcerpt]
            var objectiveTitles: [String]
            var testPlan: TestGenerationPlan?
        }
        let input = Input(
            topicId: request.topicId,
            jobType: request.jobType,
            includeConnectedKnowledge: request.includeConnectedKnowledge,
            userInstructions: request.userInstructions,
            sources: request.sources,
            objectiveTitles: request.objectiveTitles,
            testPlan: request.testPlan
        )
        return SHA256.hash(data: try CanonicalJSON.encode(input))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public nonisolated static func automaticJobId(
        grantId: UUID,
        scopeKey: String,
        fingerprint: String
    ) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(
            "\(grantId.uuidString.lowercased()):\(scopeKey):\(fingerprint)".utf8
        )).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    public func latestTopicGeneration(
        topicId: UUID,
        jobType: LearningAIJobType? = nil
    ) async throws -> IdentifiedPayload<LearningGenerationArtifact>? {
        let entities = try await database.entities(type: .aiArtifact, parentId: topicId)
        for entity in entities {
            guard let artifact = try? CanonicalJSON.decode(
                LearningGenerationArtifact.self,
                from: entity.content
            ) else { continue }
            if jobType == nil || artifact.jobType == jobType {
                return IdentifiedPayload(
                    id: entity.id,
                    payload: artifact,
                    revision: entity.revision,
                    syncState: entity.syncState
                )
            }
        }
        return nil
    }

    // MARK: - Adaptive Tutor

    public func createTutorSession(
        topicId: UUID,
        studySessionId: UUID? = nil,
        goalId: UUID? = nil,
        objective: String? = nil,
        timeTargetMinutes: Int? = nil,
        sourceVersionIds: [UUID] = [],
        includeConnectedKnowledge: Bool = false,
        guidanceStyle: TutorGuidanceStyle = .adaptive,
        budget: TutorSessionBudget = TutorSessionBudget()
    ) async throws -> UUID {
        try await store.createTutorSession(
            topicId: topicId,
            studySessionId: studySessionId,
            goalId: goalId,
            objective: objective,
            timeTargetMinutes: timeTargetMinutes,
            sourceVersionIds: sourceVersionIds,
            includeConnectedKnowledge: includeConnectedKnowledge,
            guidanceStyle: guidanceStyle,
            providerRoute: try reviewedProviderRoute(),
            budget: budget
        )
    }

    public func prepareTutorTurn(
        sessionId: UUID,
        action: TutorTurnAction,
        learnerMessage: String? = nil,
        learnerConfidence: Int? = nil,
        preferredEvidenceIds: [UUID] = []
    ) async throws -> PreparedTutorTurnRequest {
        let identified = try await store.payload(TutorSessionPayload.self, id: sessionId)
        let session = identified.payload
        guard session.state == .active else { throw TutorContractError.sessionNotActive }
        guard Date() < session.budget.expiresAt else { throw TutorContractError.approvalExpired }
        guard session.approvedTurnCount < session.budget.maximumTurns else {
            throw TutorContractError.turnLimitReached
        }
        guard session.estimatedSpentMinorUnits < session.budget.spendingLimitMinorUnits else {
            throw TutorContractError.spendingLimitReached
        }
        let topic = try await store.topic(id: session.topicId)
        let objective = session.objective?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? topic.payload.name
        let cleanMessage = learnerMessage?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if action == .answer, cleanMessage == nil { throw TutorContractError.messageRequired }

        let turns = try await store.tutorTurns(sessionId: sessionId)
        let signals = try await store.learningSignals()
        let projection = TutorAdaptationEngine.project(
            objective: objective,
            signals: signals.filter { $0.payload.topicId == session.topicId }
        )
        let sources = try await tutorSources(
            for: session,
            query: cleanMessage ?? objective,
            preferredEvidenceIds: preferredEvidenceIds
        )
        guard !sources.isEmpty else { throw TutorContractError.noGroundingMaterial }

        let recentTranscript = turns.suffix(12).map {
            TutorTranscriptExcerpt(
                turnId: $0.id,
                sequence: $0.payload.sequence,
                role: $0.payload.role,
                kind: $0.payload.kind,
                text: String($0.payload.text.prefix(4_000)),
                confidence: $0.payload.confidence
            )
        }
        let history = signals
            .filter { $0.payload.topicId == session.topicId && $0.payload.reviewState == .accepted }
            .prefix(50)
            .map {
                TutorLearningHistoryExcerpt(
                    objective: $0.payload.objective,
                    assessmentKind: $0.payload.assessmentKind,
                    outcome: $0.payload.outcome,
                    confidence: $0.payload.confidence,
                    observedAt: $0.payload.createdAt
                )
            }
        let sequence = (turns.map(\.payload.sequence).max() ?? -1) + 1
        let jobId = UUID()
        let request = TutorTurnRequest(
            accountId: accountId,
            jobId: jobId,
            tutorSessionId: sessionId,
            topicId: session.topicId,
            sequence: sequence,
            action: action,
            objective: objective,
            guidanceStyle: session.guidanceStyle,
            learnerMessage: cleanMessage,
            learnerConfidence: learnerConfidence.map { min(max($0, 1), 5) },
            recommendedTurnKind: recommendedTutorKind(action: action, projection: projection),
            recommendationReason: projection.explanation,
            conversationSummary: turns.count > 12
                ? "Earlier turns are retained in the encrypted session. Continue from the recent transcript and accepted learning history."
                : nil,
            recentTranscript: recentTranscript,
            learningHistory: Array(history),
            sources: sources,
            authorization: TutorSessionAuthorization(
                tutorSessionId: sessionId,
                topicId: session.topicId,
                sourceVersionIds: session.sourceVersionIds.isEmpty
                    ? Array(Set(sources.map(\.sourceVersionId)))
                    : session.sourceVersionIds,
                includeConnectedKnowledge: session.includeConnectedKnowledge,
                maximumTurns: session.budget.maximumTurns,
                approvedTurnCount: session.approvedTurnCount,
                spendingLimitMinorUnits: session.budget.spendingLimitMinorUnits,
                estimatedSpentMinorUnits: session.estimatedSpentMinorUnits,
                currencyCode: session.budget.currencyCode,
                expiresAt: session.budget.expiresAt,
                approvedAt: session.budget.approvedAt
            ),
            disclosureAcknowledged: false,
            providerRoute: session.providerRoute
        )
        let characters = sources.reduce(0) { $0 + $1.excerpt.count }
            + recentTranscript.reduce(0) { $0 + $1.text.count }
            + (cleanMessage?.count ?? 0)
        return PreparedTutorTurnRequest(
            request: request,
            sourceCount: sources.count,
            approximateTokens: max(1, characters / 4),
            projectedCostLimitMinorUnits: max(
                0,
                session.budget.spendingLimitMinorUnits - session.estimatedSpentMinorUnits
            )
        )
    }

    public func submitTutorTurn(
        _ prepared: PreparedTutorTurnRequest,
        now: Date = .now
    ) async throws -> AIJobSummary {
        var request = prepared.request
        var session = try await store.payload(TutorSessionPayload.self, id: request.tutorSessionId)
        guard session.payload.topicId == request.topicId else { throw TutorContractError.sessionUnavailable }
        guard session.payload.canQueueTurn(at: now) else {
            if session.payload.state != .active { throw TutorContractError.sessionNotActive }
            if now >= session.payload.budget.expiresAt { throw TutorContractError.approvalExpired }
            if session.payload.approvedTurnCount >= session.payload.budget.maximumTurns {
                throw TutorContractError.turnLimitReached
            }
            throw TutorContractError.spendingLimitReached
        }
        request.disclosureAcknowledged = true
        request.providerRoute = session.payload.providerRoute

        let learnerTurnId = UUID()
        let learnerText = request.learnerMessage ?? request.action.displayLabel
        let learnerTurn = TutorTurnPayload(
            tutorSessionId: request.tutorSessionId,
            sequence: request.sequence,
            role: .learner,
            kind: request.recommendedTurnKind,
            text: learnerText,
            confidence: request.learnerConfidence,
            jobId: request.jobId,
            pending: true,
            now: now
        )
        session.payload.approvedTurnCount += 1
        session.payload.updatedAt = now
        try await database.saveLocalBatch([
            try tutorWrite(
                id: learnerTurnId,
                payload: learnerTurn,
                parentId: request.tutorSessionId,
                relationIds: [request.tutorSessionId, request.topicId, request.jobId]
            ),
            try tutorWrite(
                id: session.id,
                payload: session.payload,
                parentId: session.payload.topicId,
                relationIds: [session.payload.topicId, session.payload.studySessionId, session.payload.goalId]
                    .compactMap { $0 } + session.payload.sourceVersionIds
            ),
        ])

        let envelope = try crypto.encryptJob(
            CanonicalJSON.encode(request),
            accountKey: accountKey,
            accountId: accountId,
            jobType: "TUTOR_TURN",
            jobId: request.jobId
        )
        return try await api.createAIJob(id: request.jobId, type: "TUTOR_TURN", envelope: envelope)
    }

    public func tutorJob(id: UUID) async throws -> AIJobSummary {
        try await api.aiJob(id: id)
    }

    public func cancelTutorJob(id: UUID) async throws -> AIJobSummary {
        try await api.cancelAIJob(id: id)
    }

    public func latestTutorTurnArtifact(
        sessionId: UUID,
        jobId: UUID? = nil
    ) async throws -> IdentifiedPayload<TutorTurnArtifact>? {
        let entities = try await database.entities(type: .aiArtifact, parentId: sessionId)
        for entity in entities {
            guard let artifact = try? CanonicalJSON.decode(TutorTurnArtifact.self, from: entity.content),
                  artifact.tutorSessionId == sessionId,
                  jobId == nil || artifact.jobId == jobId
            else { continue }
            return IdentifiedPayload(
                id: entity.id,
                payload: artifact,
                revision: entity.revision,
                syncState: entity.syncState
            )
        }
        return nil
    }

    @discardableResult
    public func importTutorTurnArtifact(
        artifactId: UUID,
        now: Date = .now
    ) async throws -> UUID {
        let artifact = try await store.payload(TutorTurnArtifact.self, id: artifactId)
        var session = try await store.payload(TutorSessionPayload.self, id: artifact.payload.tutorSessionId)
        guard artifact.payload.topicId == session.payload.topicId else {
            throw TutorContractError.artifactMismatch
        }
        let allowed = Dictionary(uniqueKeysWithValues: artifact.payload.sources.map { ($0.excerptId, $0) })
        guard artifact.payload.response.citedExcerptIds.allSatisfy({ allowed[$0] != nil }) else {
            throw TutorContractError.citationOutsideScope
        }
        let existingTurns = try await store.tutorTurns(sessionId: session.id)
        if let existing = existingTurns.first(where: { $0.payload.jobId == artifact.payload.jobId && $0.payload.role == .tutor }) {
            return existing.id
        }
        let citations = try artifact.payload.response.citedExcerptIds.compactMap { excerptId -> TutorCitation? in
            guard let source = allowed[excerptId] else { return nil }
            try source.locator.validate()
            return TutorCitation(
                excerptId: excerptId,
                sourceId: source.sourceId,
                sourceVersionId: source.sourceVersionId,
                locator: source.locator,
                evidenceId: source.evidenceId,
                excerpt: source.excerpt
            )
        }
        let tutorTurnId = UUID()
        let tutorTurn = TutorTurnPayload(
            tutorSessionId: session.id,
            sequence: artifact.payload.sequence + 1,
            role: .tutor,
            kind: artifact.payload.response.kind,
            text: artifact.payload.response.message,
            citations: citations,
            providerTrace: artifact.payload.trace,
            jobId: artifact.payload.jobId,
            pending: false,
            now: now
        )
        let topic = try await store.topic(id: session.payload.topicId)
        let objective = session.payload.objective?.nilIfEmpty ?? topic.payload.name
        guard artifact.payload.response.proposedSignals.allSatisfy({
            $0.objective.localizedCaseInsensitiveCompare(objective) == .orderedSame
        }) else { throw TutorContractError.signalOutsideScope }

        var writes = [try tutorWrite(
            id: tutorTurnId,
            payload: tutorTurn,
            parentId: session.id,
            relationIds: [session.id, session.payload.topicId, artifact.id, artifact.payload.jobId]
                + citations.flatMap { [$0.sourceId, $0.sourceVersionId, $0.evidenceId].compactMap { $0 } }
        )]
        for draft in artifact.payload.response.proposedSignals {
            let cited = draft.citedExcerptIds.compactMap { allowed[$0] }
            let signal = LearningSignalPayload(
                tutorSessionId: session.id,
                topicId: session.payload.topicId,
                objective: draft.objective,
                assessmentKind: draft.assessmentKind,
                outcome: draft.outcome,
                confidence: draft.confidence,
                turnIds: [tutorTurnId],
                evidenceIds: cited.compactMap(\.evidenceId),
                rationale: draft.rationale,
                provenance: .generatedAI,
                reviewState: .proposed,
                now: now
            )
            writes.append(try tutorWrite(
                id: draft.id,
                payload: signal,
                parentId: session.id,
                relationIds: [session.id, session.payload.topicId, tutorTurnId]
                    + cited.compactMap(\.evidenceId)
            ))
        }
        if let pending = existingTurns.first(where: {
            $0.payload.jobId == artifact.payload.jobId && $0.payload.role == .learner
        }) {
            var resolved = pending.payload
            resolved.pending = false
            resolved.updatedAt = now
            writes.append(try tutorWrite(
                id: pending.id,
                payload: resolved,
                parentId: session.id,
                relationIds: [session.id, session.payload.topicId, artifact.payload.jobId]
            ))
        }
        if artifact.payload.response.sessionSummary != nil {
            session.payload.state = .ended
            session.payload.endedAt = now
        }
        let cost = Int(((artifact.payload.trace.estimatedCostUsd ?? 0) * 100).rounded(.up))
        session.payload.estimatedSpentMinorUnits = min(
            session.payload.budget.spendingLimitMinorUnits,
            session.payload.estimatedSpentMinorUnits + max(cost, 0)
        )
        session.payload.updatedAt = now
        writes.append(try tutorWrite(
            id: session.id,
            payload: session.payload,
            parentId: session.payload.topicId,
            relationIds: [session.payload.topicId, session.payload.studySessionId, session.payload.goalId]
                .compactMap { $0 } + session.payload.sourceVersionIds
        ))
        try await database.saveLocalBatch(writes)
        return tutorTurnId
    }

    private func tutorSources(
        for session: TutorSessionPayload,
        query: String,
        preferredEvidenceIds: [UUID]
    ) async throws -> [TutorSourceExcerpt] {
        let scopedTopicIds = try await topicScopeIds(
            topicId: session.topicId,
            includeConnectedKnowledge: session.includeConnectedKnowledge
        )
        let allSources = try await store.list(SourcePayload.self)
        let scopedSources = allSources.filter {
            $0.payload.archivedAt == nil
                && ($0.payload.primaryTopicId.map(scopedTopicIds.contains) == true
                    || !$0.payload.relatedTopicIds.filter(scopedTopicIds.contains).isEmpty)
        }
        let sourceById = Dictionary(uniqueKeysWithValues: scopedSources.map { ($0.id, $0) })
        let selectedVersions = Set(session.sourceVersionIds)
        let allowedSourceIds = Set(scopedSources.compactMap { source -> UUID? in
            guard selectedVersions.isEmpty
                    || source.payload.currentVersionId.map(selectedVersions.contains) == true
            else { return nil }
            return source.id
        })

        var excerpts: [TutorSourceExcerpt] = []
        var seen: Set<UUID> = []
        let hits = (try? await database.search(
            query,
            entityTypes: [.evidence, .aiArtifact],
            limit: 24
        )) ?? []
        let prioritizedIds = preferredEvidenceIds + hits.map(\.id)
        let allEvidence = try await store.list(EvidencePayload.self)
        let evidence = allEvidence.sorted { left, right in
            let leftIndex = prioritizedIds.firstIndex(of: left.id) ?? Int.max
            let rightIndex = prioritizedIds.firstIndex(of: right.id) ?? Int.max
            return leftIndex == rightIndex
                ? left.payload.updatedAt > right.payload.updatedAt
                : leftIndex < rightIndex
        }
        for item in evidence {
            guard allowedSourceIds.contains(item.payload.sourceId),
                  selectedVersions.isEmpty || selectedVersions.contains(item.payload.sourceVersionId),
                  !item.payload.excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seen.insert(item.id).inserted
            else { continue }
            try item.payload.locator.validate()
            excerpts.append(TutorSourceExcerpt(
                excerptId: item.id,
                sourceId: item.payload.sourceId,
                sourceVersionId: item.payload.sourceVersionId,
                evidenceId: item.id,
                title: sourceById[item.payload.sourceId]?.payload.title ?? "Source",
                locator: item.payload.locator,
                excerpt: String(item.payload.excerpt.prefix(4_000))
            ))
            if excerpts.count == 16 { break }
        }

        if excerpts.count < 16 {
            for source in scopedSources where allowedSourceIds.contains(source.id) {
                guard let versionId = source.payload.currentVersionId,
                      selectedVersions.isEmpty || selectedVersions.contains(versionId)
                else { continue }
                let artifacts = try await database.entities(type: .aiArtifact, parentId: source.id)
                guard let guide = artifacts.compactMap({ entity in
                    try? CanonicalJSON.decode(SourceAnalysisArtifact.self, from: entity.content)
                }).first(where: { $0.sourceVersionId == versionId }) else { continue }
                for reference in guide.references where seen.insert(reference.sourceId).inserted {
                    excerpts.append(TutorSourceExcerpt(
                        excerptId: reference.sourceId,
                        sourceId: source.id,
                        sourceVersionId: versionId,
                        title: source.payload.title,
                        locator: reference.locator,
                        excerpt: String(reference.excerpt.prefix(4_000))
                    ))
                    if excerpts.count == 16 { break }
                }
                if excerpts.count == 16 { break }
            }
        }
        return excerpts
    }

    private func recommendedTutorKind(
        action: TutorTurnAction,
        projection: MasteryProjection
    ) -> TutorTurnKind {
        switch action {
        case .begin: projection.nextTurnKind
        case .answer: projection.nextTurnKind
        case .hint: .hint
        case .explainDirectly: .explanation
        case .tryAnotherExample: projection.level == .needsWork ? .workedExample : .application
        case .whyNext: .reflection
        case .end: .reflection
        }
    }

    private func tutorWrite<Payload: EntityPayload>(
        id: UUID,
        payload: Payload,
        parentId: UUID?,
        relationIds: [UUID]
    ) throws -> LocalEntityWrite {
        let content = try CanonicalJSON.encode(payload)
        return LocalEntityWrite(
            id: id,
            entityType: Payload.entityType,
            parentId: parentId,
            relationIds: Array(Set(relationIds)),
            content: content,
            search: EntitySearchIndexer.document(for: Payload.entityType, content: content),
            modifiedAt: payload.updatedAt
        )
    }
}

public extension TutorTurnAction {
    var displayLabel: String {
        switch self {
        case .begin: "Start the learning guide"
        case .answer: "Answer"
        case .hint: "Give me a hint"
        case .explainDirectly: "Explain directly"
        case .tryAnotherExample: "Try another example"
        case .whyNext: "Why this next?"
        case .end: "End and review"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
