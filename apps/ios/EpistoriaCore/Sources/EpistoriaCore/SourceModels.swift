import Foundation

public enum SourceImportState: String, Codable, Sendable {
    case pending = "PENDING"
    case ready = "READY"
    case failed = "FAILED"
}

public enum SourceExtractionState: String, Codable, Sendable {
    case notRequested = "NOT_REQUESTED"
    case queued = "QUEUED"
    case processing = "PROCESSING"
    case ready = "READY"
    case failed = "FAILED"
}

public enum SourceLocatorKind: String, Codable, CaseIterable, Sendable {
    case pdf = "PDF"
    case epub = "EPUB"
    case web = "WEB"
    case media = "MEDIA"
    case document = "DOCUMENT"
    case image = "IMAGE"
    case plainText = "PLAIN_TEXT"
    case slide = "SLIDE"
    case sheet = "SHEET"
}

public enum SourceModelError: Error, Equatable, LocalizedError {
    case invalidLocator
    case emptyEvidence
    case sourceVersionMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidLocator: "The Source location is incomplete or outside its valid range."
        case .emptyEvidence: "Evidence must contain an excerpt or annotation."
        case .sourceVersionMismatch: "The selected Source Version does not belong to this Source."
        }
    }
}

/// One stable locator shape keeps citations portable across the app, worker, and readable export.
/// Only fields required by `kind` are populated.
public struct SourceLocator: Codable, Equatable, Sendable {
    public var schemaVersion = "source-locator/v1"
    public var kind: SourceLocatorKind
    public var page: Int?
    public var rectangles: [AnnotationRectangle]
    public var chapter: String?
    public var cfi: String?
    public var heading: String?
    public var selector: String?
    public var startOffset: Int?
    public var endOffset: Int?
    public var startSeconds: Double?
    public var endSeconds: Double?
    public var slide: Int?
    public var sheet: String?
    public var cellRange: String?

    public init(
        kind: SourceLocatorKind,
        page: Int? = nil,
        rectangles: [AnnotationRectangle] = [],
        startOffset: Int? = nil,
        endOffset: Int? = nil,
        startSeconds: Double? = nil,
        endSeconds: Double? = nil
    ) {
        self.kind = kind
        self.page = page
        self.rectangles = rectangles
        chapter = nil
        cfi = nil
        heading = nil
        selector = nil
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        slide = nil
        sheet = nil
        cellRange = nil
    }

    public func validate() throws {
        guard rectangles.allSatisfy({ rectangle in
            rectangle.x >= 0 && rectangle.y >= 0 && rectangle.width > 0 && rectangle.height > 0
        }) else { throw SourceModelError.invalidLocator }
        switch kind {
        case .pdf:
            guard let page, page >= 1 else { throw SourceModelError.invalidLocator }
        case .media:
            guard let startSeconds, startSeconds >= 0,
                  endSeconds.map({ $0 >= startSeconds }) ?? true
            else { throw SourceModelError.invalidLocator }
        case .plainText:
            guard let startOffset, startOffset >= 0,
                  let endOffset, endOffset >= startOffset
            else { throw SourceModelError.invalidLocator }
        case .epub, .web, .document, .image, .slide, .sheet:
            break
        }
    }
}

/// One imported or captured item in the Library.
public struct SourcePayload: EntityPayload, Equatable {
    public static let entityType = EntityType.source
    public var schemaVersion = "source/v1"
    public var sourceType: SourceKind
    public var title: String
    public var authors: [String]
    public var canonicalURL: URL?
    public var identifiers: [String]
    public var originalAssetId: UUID?
    public var currentVersionId: UUID?
    public var primaryTopicId: UUID?
    public var relatedTopicIds: [UUID]
    public var listIds: [UUID]
    public var importState: SourceImportState
    public var locallyAvailable: Bool
    public var archivedAt: Date?
    public var importedAt: Date
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        sourceType: SourceKind,
        title: String,
        authors: [String] = [],
        originalAssetId: UUID? = nil,
        primaryTopicId: UUID? = nil,
        now: Date = .now
    ) {
        self.sourceType = sourceType
        self.title = title
        self.authors = authors
        canonicalURL = nil
        identifiers = []
        self.originalAssetId = originalAssetId
        currentVersionId = nil
        self.primaryTopicId = primaryTopicId
        relatedTopicIds = []
        listIds = []
        importState = .ready
        locallyAvailable = originalAssetId != nil
        archivedAt = nil
        importedAt = now
        createdAt = now
        updatedAt = now
    }

}

public struct SourceVersionPayload: EntityPayload, Equatable {
    public static let entityType = EntityType.sourceVersion
    public var schemaVersion = "source-version/v1"
    public var sourceId: UUID
    public var versionNumber: Int
    public var originalAssetId: UUID?
    public var capturedURL: URL?
    public var contentFingerprint: String?
    public var extractionState: SourceExtractionState
    public var extractorVersion: String?
    public var extractedTextAssetId: UUID?
    public var thumbnailAssetId: UUID?
    public var refreshedFromVersionId: UUID?
    public var createdAt: Date
    public var updatedAt: Date

    public init(sourceId: UUID, versionNumber: Int, originalAssetId: UUID? = nil, now: Date = .now) {
        self.sourceId = sourceId
        self.versionNumber = max(versionNumber, 1)
        self.originalAssetId = originalAssetId
        capturedURL = nil
        contentFingerprint = nil
        extractionState = .notRequested
        extractorVersion = nil
        extractedTextAssetId = nil
        thumbnailAssetId = nil
        refreshedFromVersionId = nil
        createdAt = now
        updatedAt = now
    }
}

public enum EvidenceKind: String, Codable, Sendable {
    case excerpt = "EXCERPT"
    case annotation = "ANNOTATION"
    case imageRegion = "IMAGE_REGION"
    case mediaClip = "MEDIA_CLIP"
}

public struct EvidencePayload: EntityPayload, Equatable {
    public static let entityType = EntityType.evidence
    public var schemaVersion = "evidence/v1"
    public var sourceId: UUID
    public var sourceVersionId: UUID
    public var kind: EvidenceKind
    public var locator: SourceLocator
    public var excerpt: String
    public var note: String?
    /// The immutable provider artifact used to create transcript Evidence, when applicable.
    public var transcriptionArtifactId: UUID?
    /// Provider segment indexes included in this Evidence. Empty for non-transcript Evidence.
    public var transcriptSegmentIndexes: [Int]?
    /// Owner correction records applied when the excerpt was frozen.
    public var transcriptCorrectionIds: [UUID]?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        sourceId: UUID,
        sourceVersionId: UUID,
        kind: EvidenceKind,
        locator: SourceLocator,
        excerpt: String,
        now: Date = .now
    ) {
        self.sourceId = sourceId
        self.sourceVersionId = sourceVersionId
        self.kind = kind
        self.locator = locator
        self.excerpt = excerpt
        note = nil
        transcriptionArtifactId = nil
        transcriptSegmentIndexes = []
        transcriptCorrectionIds = []
        createdAt = now
        updatedAt = now
    }

    public var resolvedTranscriptSegmentIndexes: [Int] { transcriptSegmentIndexes ?? [] }
    public var resolvedTranscriptCorrectionIds: [UUID] { transcriptCorrectionIds ?? [] }
}

public enum EvidenceBacklinkKind: String, Codable, Sendable {
    case note = "NOTE"
    case concept = "CONCEPT"
    case flashcard = "FLASHCARD"
    case testQuestion = "TEST_QUESTION"
}

/// A local projection rebuilt from durable records. It is not synchronized as a separate entity.
public struct EvidenceBacklink: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var kind: EvidenceBacklinkKind
    public var ownerId: UUID
    public var title: String

    public init(id: UUID, kind: EvidenceBacklinkKind, ownerId: UUID, title: String) {
        self.id = id
        self.kind = kind
        self.ownerId = ownerId
        self.title = title
    }
}

public enum ConceptLifecycleState: String, Codable, Sendable {
    case active = "ACTIVE"
    case archived = "ARCHIVED"
}

public struct ConceptPayload: EntityPayload, Equatable {
    public static let entityType = EntityType.concept
    public var schemaVersion = "concept/v1"
    public var name: String
    public var conceptDescription: String
    public var aliases: [String]
    public var topicIds: [UUID]
    public var state: ConceptLifecycleState
    public var createdAt: Date
    public var updatedAt: Date

    public init(name: String, conceptDescription: String = "", topicIds: [UUID], now: Date = .now) {
        self.name = name
        self.conceptDescription = conceptDescription
        aliases = []
        self.topicIds = topicIds
        state = .active
        createdAt = now
        updatedAt = now
    }
}

public enum ConceptEvidenceKind: String, Codable, Sendable {
    case supporting = "SUPPORTING"
    case contradicting = "CONTRADICTING"
    case example = "EXAMPLE"
    case prerequisite = "PREREQUISITE"
    case application = "APPLICATION"
}

public struct ConceptEvidenceRelationPayload: EntityPayload, Equatable {
    public static let entityType = EntityType.conceptEvidence
    public var schemaVersion = "concept-evidence/v1"
    public var conceptId: UUID
    public var evidenceId: UUID
    public var relation: ConceptEvidenceKind
    public var createdAt: Date
    public var updatedAt: Date

    public init(conceptId: UUID, evidenceId: UUID, relation: ConceptEvidenceKind, now: Date = .now) {
        self.conceptId = conceptId
        self.evidenceId = evidenceId
        self.relation = relation
        createdAt = now
        updatedAt = now
    }
}

public enum ConceptLinkKind: String, Codable, CaseIterable, Sendable {
    case prerequisite = "PREREQUISITE"
    case partOf = "PART_OF"
    case related = "RELATED"
    case contrasts = "CONTRASTS"
    case applies = "APPLIES"

    public var displayName: String {
        switch self {
        case .prerequisite: "Prerequisite for"
        case .partOf: "Part of"
        case .related: "Related to"
        case .contrasts: "Contrasts with"
        case .applies: "Applies to"
        }
    }
}

public enum RecordProvenance: String, Codable, Sendable {
    case user = "USER"
    case generatedAI = "GENERATED_AI"
    case reviewedAI = "REVIEWED_AI"
}

public struct ConceptLinkPayload: EntityPayload, Equatable {
    public static let entityType = EntityType.conceptLink
    public var schemaVersion = "concept-link/v1"
    public var sourceConceptId: UUID
    public var targetConceptId: UUID
    public var relation: ConceptLinkKind
    public var provenance: RecordProvenance
    public var rationale: String?
    public var evidenceIds: [UUID]
    public var generatorArtifactId: UUID?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        sourceConceptId: UUID,
        targetConceptId: UUID,
        relation: ConceptLinkKind,
        provenance: RecordProvenance = .user,
        rationale: String? = nil,
        evidenceIds: [UUID] = [],
        generatorArtifactId: UUID? = nil,
        now: Date = .now
    ) {
        self.sourceConceptId = sourceConceptId
        self.targetConceptId = targetConceptId
        self.relation = relation
        self.provenance = provenance
        self.rationale = rationale
        self.evidenceIds = evidenceIds
        self.generatorArtifactId = generatorArtifactId
        createdAt = now
        updatedAt = now
    }
}
