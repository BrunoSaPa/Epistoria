import Foundation

public enum EntityType: String, Codable, CaseIterable, Sendable {
    case area = "AREA"
    case topicArea = "TOPIC_AREA"
    case collection = "COLLECTION"
    case collectionItem = "COLLECTION_ITEM"
    case institution = "INSTITUTION"
    case academicTerm = "ACADEMIC_TERM"
    case course = "COURSE"
    case studySession = "STUDY_SESSION"
    case note = "NOTE"
    case noteBlock = "NOTE_BLOCK"
    case resource = "RESOURCE"
    case asset = "ASSET"
    case annotation = "ANNOTATION"
    case sessionNote = "SESSION_NOTE"
    case sessionResource = "SESSION_RESOURCE"
    case aiArtifact = "AI_ARTIFACT"
    case transcriptCorrection = "TRANSCRIPT_CORRECTION"
    case sourceVersion = "SOURCE_VERSION"
    case evidence = "EVIDENCE"
    case concept = "CONCEPT"
    case conceptEvidence = "CONCEPT_EVIDENCE"
    case conceptLink = "CONCEPT_LINK"
    case studyGoal = "STUDY_GOAL"
    case unresolvedQuestion = "UNRESOLVED_QUESTION"
    case sessionActivity = "SESSION_ACTIVITY"
    case flashcardDeck = "FLASHCARD_DECK"
    case flashcard = "FLASHCARD"
    case flashcardRevision = "FLASHCARD_REVISION"
    case flashcardReview = "FLASHCARD_REVIEW"
    case topicScopeSnapshot = "TOPIC_SCOPE_SNAPSHOT"
    case testBlueprint = "TEST_BLUEPRINT"
    case practiceTest = "PRACTICE_TEST"
    case testQuestion = "TEST_QUESTION"
    case testAttempt = "TEST_ATTEMPT"
    case testResponse = "TEST_RESPONSE"
    case studyRecommendation = "STUDY_RECOMMENDATION"
    case recommendationResponse = "RECOMMENDATION_RESPONSE"
    case automationGrant = "AUTOMATION_GRANT"
}

public enum NoteBlockKind: String, Codable, CaseIterable, Sendable {
    case text = "TEXT"
    case handwriting = "HANDWRITING"
    case image = "IMAGE"
    case file = "FILE"
    case pdfReference = "PDF_REFERENCE"
    case videoReference = "VIDEO_REFERENCE"
    case equation = "EQUATION"
    case code = "CODE"
    case callout = "CALLOUT"
    case shape = "SHAPE"
}

public enum NotePageFormat: String, Codable, CaseIterable, Sendable {
    case a4 = "A4"
    case letter = "LETTER"
    case infinite = "INFINITE"
}

public enum NotePageOrientation: String, Codable, CaseIterable, Sendable {
    case portrait = "PORTRAIT"
    case landscape = "LANDSCAPE"
}

public enum NotePaperStyle: String, Codable, CaseIterable, Sendable {
    case plain = "PLAIN"
    case ruled = "RULED"
    case grid = "GRID"
    case dotted = "DOTTED"
    case isometric = "ISOMETRIC"
}

public enum NotePaperColor: String, Codable, CaseIterable, Sendable {
    case white = "WHITE"
    case ivory = "IVORY"
    case fog = "FOG"
    case stone = "STONE"
}

public enum NoteCanvasColor: String, Codable, CaseIterable, Sendable {
    case black = "BLACK"
    case graphite = "GRAPHITE"
    case red = "RED"
    case blue = "BLUE"
    case green = "GREEN"
    case white = "WHITE"
}

public enum NoteCanvasShapeKind: String, Codable, CaseIterable, Sendable {
    case rectangle = "RECTANGLE"
    case roundedRectangle = "ROUNDED_RECTANGLE"
    case ellipse = "ELLIPSE"
    case triangle = "TRIANGLE"
    case diamond = "DIAMOND"
    case line = "LINE"
    case arrow = "ARROW"
}

public struct NoteCanvasShape: Codable, Equatable, Sendable {
    public var kind: NoteCanvasShapeKind
    public var strokeColor: NoteCanvasColor
    public var fillColor: NoteCanvasColor?
    public var lineWidth: Double

    public init(
        kind: NoteCanvasShapeKind,
        strokeColor: NoteCanvasColor = .black,
        fillColor: NoteCanvasColor? = nil,
        lineWidth: Double = 3
    ) {
        self.kind = kind
        self.strokeColor = strokeColor
        self.fillColor = fillColor
        self.lineWidth = min(max(lineWidth, 1), 24)
    }
}

/// The spatial presentation of one note. Measurements use document points (72 per inch),
/// independent of device scale and zoom. Infinite canvases share the same origin as fixed
/// paper and allow negative coordinates in every direction.
public struct NoteCanvasConfiguration: Codable, Equatable, Sendable {
    public var schemaVersion = "note-canvas/v3"
    public var pageFormat: NotePageFormat
    public var orientation: NotePageOrientation
    public var paperStyle: NotePaperStyle
    public var paperColor: NotePaperColor
    /// Pattern spacing in document points. The renderer clamps decoded values before use.
    public var paperSpacing: Double
    /// Fixed-paper notes append compact, numbered pages. Infinite canvases always have one
    /// unbounded surface.
    public var pageCount: Int

    public init(
        pageFormat: NotePageFormat = .a4,
        orientation: NotePageOrientation = .portrait,
        paperStyle: NotePaperStyle = .plain,
        paperColor: NotePaperColor = .white,
        paperSpacing: Double? = nil,
        pageCount: Int = 1
    ) {
        self.pageFormat = pageFormat
        self.orientation = orientation
        self.paperStyle = paperStyle
        self.paperColor = paperColor
        self.paperSpacing = min(
            max(paperSpacing ?? (paperStyle == .dotted ? 24 : 28), 12),
            72
        )
        self.pageCount = pageFormat == .infinite ? 1 : max(pageCount, 1)
    }

    public var effectivePageCount: Int {
        pageFormat == .infinite ? 1 : max(pageCount, 1)
    }

    public var pageWidth: Double? {
        guard pageFormat != .infinite else { return nil }
        let portraitWidth = pageFormat == .a4 ? 595.0 : 612.0
        let portraitHeight = pageFormat == .a4 ? 842.0 : 792.0
        return orientation == .portrait ? portraitWidth : portraitHeight
    }

    public var pageHeight: Double? {
        guard pageFormat != .infinite else { return nil }
        let portraitWidth = pageFormat == .a4 ? 595.0 : 612.0
        let portraitHeight = pageFormat == .a4 ? 842.0 : 792.0
        return orientation == .portrait ? portraitHeight : portraitWidth
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case pageFormat
        case orientation
        case paperStyle
        case paperColor
        case paperSpacing
        case pageCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(String.self, forKey: .schemaVersion)
            ?? "note-canvas/v1"
        pageFormat = try container.decode(NotePageFormat.self, forKey: .pageFormat)
        orientation = try container.decode(NotePageOrientation.self, forKey: .orientation)
        paperStyle = try container.decode(NotePaperStyle.self, forKey: .paperStyle)
        paperColor = try container.decodeIfPresent(NotePaperColor.self, forKey: .paperColor)
            ?? .white
        paperSpacing = min(
            max(
                try container.decodeIfPresent(Double.self, forKey: .paperSpacing)
                    ?? (paperStyle == .dotted ? 24 : 28),
                12
            ),
            72
        )
        let decodedPageCount = max(
            try container.decodeIfPresent(Int.self, forKey: .pageCount) ?? 1,
            1
        )
        pageCount = pageFormat == .infinite ? 1 : decodedPageCount
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(pageFormat, forKey: .pageFormat)
        try container.encode(orientation, forKey: .orientation)
        try container.encode(paperStyle, forKey: .paperStyle)
        try container.encode(paperColor, forKey: .paperColor)
        try container.encode(paperSpacing, forKey: .paperSpacing)
        try container.encode(effectivePageCount, forKey: .pageCount)
    }
}

public struct NoteCanvasPlacement: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var rotationRadians: Double
    public var zIndex: Int

    public init(
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        rotationRadians: Double = 0,
        zIndex: Int = 0
    ) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.rotationRadians = rotationRadians
        self.zIndex = zIndex
    }
}

public enum NoteBlockCanvasRole: String, Codable, Sendable {
    /// A PencilKit drawing whose stroke coordinates live in the note's global document space.
    case inkLayer = "INK_LAYER"
}

public enum ResourceKind: String, Codable, CaseIterable, Sendable {
    case book = "BOOK"
    case pdf = "PDF"
    case paper = "PAPER"
    case video = "VIDEO"
    case website = "WEBSITE"
    case lecture = "LECTURE"
    case image = "IMAGE"
    case document = "DOCUMENT"
    case courseMaterial = "COURSE_MATERIAL"
    case other = "OTHER"
    case pastedText = "PASTED_TEXT"
    case markdown = "MARKDOWN"
    case html = "HTML"
    case epub = "EPUB"
    case docx = "DOCX"
    case odt = "ODT"
    case pptx = "PPTX"
    case odp = "ODP"
    case csv = "CSV"
    case xlsx = "XLSX"
    case audio = "AUDIO"
    case youtube = "YOUTUBE"
    case googleDocument = "GOOGLE_DOCUMENT"
    case googleSlides = "GOOGLE_SLIDES"
    case googleSheet = "GOOGLE_SHEET"
}

public enum AnnotationKind: String, Codable, CaseIterable, Sendable {
    case highlight = "HIGHLIGHT"
    case comment = "COMMENT"
    case question = "QUESTION"
    case idea = "IDEA"
    case important = "IMPORTANT"
    case disagreement = "DISAGREEMENT"
    case summary = "SUMMARY"
    case bookmark = "BOOKMARK"
    case drawing = "DRAWING"
}

public enum StudySessionState: String, Codable, Sendable {
    case planned = "PLANNED"
    case active = "ACTIVE"
    case paused = "PAUSED"
    case ended = "ENDED"
    case abandoned = "ABANDONED"
}

public protocol EntityPayload: Codable, Sendable {
    static var entityType: EntityType { get }
    var createdAt: Date { get }
    var updatedAt: Date { get }
}

public struct CollectionPayload: EntityPayload, Equatable {
    public static let entityType = EntityType.collection
    public var schemaVersion: String
    public var name: String
    public var parentCollectionId: UUID?
    public var archivedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(name: String, parentCollectionId: UUID? = nil, now: Date = .now) {
        schemaVersion = "collection/v2"
        self.name = name
        self.parentCollectionId = parentCollectionId
        archivedAt = nil
        createdAt = now
        updatedAt = now
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, name, parentCollectionId, archivedAt, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decodeIfPresent(String.self, forKey: .schemaVersion)
            ?? "collection/v1"
        guard version == "collection/v1" || version == "collection/v2" else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: values,
                debugDescription: "Unsupported List schema \(version)"
            )
        }
        schemaVersion = version
        name = try values.decode(String.self, forKey: .name)
        parentCollectionId = try values.decodeIfPresent(UUID.self, forKey: .parentCollectionId)
        archivedAt = try values.decodeIfPresent(Date.self, forKey: .archivedAt)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode("collection/v2", forKey: .schemaVersion)
        try values.encode(name, forKey: .name)
        try values.encodeIfPresent(parentCollectionId, forKey: .parentCollectionId)
        try values.encodeIfPresent(archivedAt, forKey: .archivedAt)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(updatedAt, forKey: .updatedAt)
    }
}

public struct InstitutionPayload: EntityPayload, Equatable {
    public static let entityType = EntityType.institution
    public var schemaVersion = "institution/v1"
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(name: String, now: Date = .now) {
        self.name = name
        createdAt = now
        updatedAt = now
    }
}

public struct AcademicTermPayload: EntityPayload, Equatable {
    public static let entityType = EntityType.academicTerm
    public var schemaVersion = "academic-term/v1"
    public var institutionId: UUID
    public var name: String
    public var startDate: Date?
    public var endDate: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        institutionId: UUID,
        name: String,
        startDate: Date? = nil,
        endDate: Date? = nil,
        now: Date = .now
    ) {
        self.institutionId = institutionId
        self.name = name
        self.startDate = startDate
        self.endDate = endDate
        createdAt = now
        updatedAt = now
    }
}

public struct CoursePayload: EntityPayload, Equatable {
    public static let entityType = EntityType.course
    public var schemaVersion = "course/v1"
    public var institutionId: UUID?
    public var academicTermId: UUID?
    public var name: String
    public var code: String?
    public var professor: String?
    public var courseDescription: String?
    public var startDate: Date?
    public var endDate: Date?
    public var archived: Bool
    public var colorHex: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        name: String,
        institutionId: UUID? = nil,
        academicTermId: UUID? = nil,
        code: String? = nil,
        professor: String? = nil,
        now: Date = .now
    ) {
        self.institutionId = institutionId
        self.academicTermId = academicTermId
        self.name = name
        self.code = code
        self.professor = professor
        courseDescription = nil
        startDate = nil
        endDate = nil
        archived = false
        colorHex = nil
        createdAt = now
        updatedAt = now
    }
}

public struct StudySessionPayload: EntityPayload, Equatable {
    public static let entityType = EntityType.studySession
    public var schemaVersion = "study-session/v1"
    public var title: String
    public var courseId: UUID?
    public var primaryCollectionId: UUID?
    public var state: StudySessionState
    public var goals: [String]
    public var objective: String?
    public var startingNotes: String?
    public var plannedAt: Date?
    public var pausedAt: Date?
    public var abandonedAt: Date?
    public var startedAt: Date
    public var endedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        title: String,
        courseId: UUID? = nil,
        goals: [String] = [],
        now: Date = .now
    ) {
        self.title = title
        self.courseId = courseId
        primaryCollectionId = nil
        state = .active
        self.goals = goals
        objective = goals.first
        startingNotes = nil
        plannedAt = nil
        pausedAt = nil
        abandonedAt = nil
        startedAt = now
        endedAt = nil
        createdAt = now
        updatedAt = now
    }
}

public struct NotePayload: EntityPayload, Equatable {
    public static let entityType = EntityType.note
    public var schemaVersion = "note/v3"
    public var title: String
    public var courseId: UUID?
    public var studySessionId: UUID?
    public var archivedAt: Date?
    /// `nil` only for records created before the spatial editor. Those records render with the
    /// documented A4/plain compatibility default and are upgraded on the first canvas change.
    public var canvas: NoteCanvasConfiguration?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        title: String,
        courseId: UUID? = nil,
        studySessionId: UUID? = nil,
        canvas: NoteCanvasConfiguration = NoteCanvasConfiguration(),
        now: Date = .now
    ) {
        self.title = title
        self.courseId = courseId
        self.studySessionId = studySessionId
        archivedAt = nil
        self.canvas = canvas
        createdAt = now
        updatedAt = now
    }
}

public struct NoteBlockPayload: EntityPayload, Equatable {
    public static let entityType = EntityType.noteBlock
    public var schemaVersion = "note-block/v5"
    public var noteId: UUID
    public var blockType: NoteBlockKind
    public var orderKey: String
    public var plainText: String
    public var richTextRtf: Data?
    public var drawingData: Data?
    public var assetId: UUID?
    /// Reuses one immutable Evidence record without copying or weakening its Source Version link.
    public var evidenceId: UUID?
    public var transcription: String?
    /// Spatial geometry is optional so v1 vertical notes decode without a destructive migration.
    public var canvasPlacement: NoteCanvasPlacement?
    public var canvasRole: NoteBlockCanvasRole?
    /// Vector geometry for durable canvas shapes. Missing for older and non-shape records.
    public var canvasShape: NoteCanvasShape?
    /// Page-local records use a zero-based index. A missing value is legacy page zero.
    public var canvasPageIndex: Int?
    public var tombstone: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        noteId: UUID,
        blockType: NoteBlockKind,
        orderKey: String,
        plainText: String = "",
        now: Date = .now
    ) {
        self.noteId = noteId
        self.blockType = blockType
        self.orderKey = orderKey
        self.plainText = plainText
        richTextRtf = nil
        drawingData = nil
        assetId = nil
        evidenceId = nil
        transcription = nil
        canvasPlacement = nil
        canvasRole = nil
        canvasShape = nil
        canvasPageIndex = nil
        tombstone = false
        createdAt = now
        updatedAt = now
    }
}

public struct ResourcePayload: EntityPayload, Equatable {
    public static let entityType = EntityType.resource
    public var schemaVersion = "resource/v1"
    public var resourceType: ResourceKind
    public var title: String
    public var authors: [String]
    public var url: URL?
    public var externalIdentifier: String?
    public var originalAssetId: UUID?
    public var importedAt: Date
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        resourceType: ResourceKind,
        title: String,
        authors: [String] = [],
        originalAssetId: UUID? = nil,
        now: Date = .now
    ) {
        self.resourceType = resourceType
        self.title = title
        self.authors = authors
        url = nil
        externalIdentifier = nil
        self.originalAssetId = originalAssetId
        importedAt = now
        createdAt = now
        updatedAt = now
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, resourceType, sourceType, title, authors, url, canonicalURL
        case externalIdentifier, identifiers, originalAssetId, importedAt, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(String.self, forKey: .schemaVersion) ?? "resource/v1"
        resourceType = try values.decodeIfPresent(ResourceKind.self, forKey: .resourceType)
            ?? values.decode(ResourceKind.self, forKey: .sourceType)
        title = try values.decode(String.self, forKey: .title)
        authors = try values.decodeIfPresent([String].self, forKey: .authors) ?? []
        url = try values.decodeIfPresent(URL.self, forKey: .url)
            ?? values.decodeIfPresent(URL.self, forKey: .canonicalURL)
        externalIdentifier = try values.decodeIfPresent(String.self, forKey: .externalIdentifier)
        if externalIdentifier == nil,
           let identifiers = try values.decodeIfPresent([String].self, forKey: .identifiers) {
            externalIdentifier = identifiers.first
        }
        originalAssetId = try values.decodeIfPresent(UUID.self, forKey: .originalAssetId)
        importedAt = try values.decode(Date.self, forKey: .importedAt)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode("resource/v1", forKey: .schemaVersion)
        try values.encode(resourceType, forKey: .resourceType)
        try values.encode(title, forKey: .title)
        try values.encode(authors, forKey: .authors)
        try values.encodeIfPresent(url, forKey: .url)
        try values.encodeIfPresent(externalIdentifier, forKey: .externalIdentifier)
        try values.encodeIfPresent(originalAssetId, forKey: .originalAssetId)
        try values.encode(importedAt, forKey: .importedAt)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(updatedAt, forKey: .updatedAt)
    }
}

public struct AssetPayload: EntityPayload, Equatable {
    public static let entityType = EntityType.asset
    public var schemaVersion = "asset/v1"
    public var mimeType: String
    public var plaintextByteSize: Int64
    public var encryptedByteSize: Int64
    public var dedupeTag: String
    public var assetKey: String
    public var originalFilename: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        mimeType: String,
        plaintextByteSize: Int64,
        encryptedByteSize: Int64,
        dedupeTag: String,
        assetKey: String,
        originalFilename: String,
        now: Date = .now
    ) {
        self.mimeType = mimeType
        self.plaintextByteSize = plaintextByteSize
        self.encryptedByteSize = encryptedByteSize
        self.dedupeTag = dedupeTag
        self.assetKey = assetKey
        self.originalFilename = originalFilename
        createdAt = now
        updatedAt = now
    }
}

public struct AnnotationRectangle: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct AnnotationPayload: EntityPayload, Equatable {
    public static let entityType = EntityType.annotation
    public var schemaVersion = "annotation/v1"
    public var resourceId: UUID
    public var studySessionId: UUID?
    public var noteId: UUID?
    public var annotationType: AnnotationKind
    public var pageNumber: Int?
    public var selectedText: String?
    public var comment: String
    public var rectangles: [AnnotationRectangle]
    public var drawingData: Data?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        resourceId: UUID,
        annotationType: AnnotationKind,
        pageNumber: Int? = nil,
        comment: String = "",
        now: Date = .now
    ) {
        self.resourceId = resourceId
        studySessionId = nil
        noteId = nil
        self.annotationType = annotationType
        self.pageNumber = pageNumber
        selectedText = nil
        self.comment = comment
        rectangles = []
        drawingData = nil
        createdAt = now
        updatedAt = now
    }
}

public struct RelationPayload: EntityPayload, Equatable {
    public enum Kind: String, Codable, Sendable {
        case collectionItem = "collection-item/v1"
        case sessionNote = "session-note/v1"
        case sessionResource = "session-resource/v1"
    }

    public static let entityType = EntityType.collectionItem
    public var schemaVersion: Kind
    public var leftId: UUID
    public var rightId: UUID
    public var createdAt: Date
    public var updatedAt: Date

    public init(kind: Kind, leftId: UUID, rightId: UUID, now: Date = .now) {
        schemaVersion = kind
        self.leftId = leftId
        self.rightId = rightId
        createdAt = now
        updatedAt = now
    }

    public var resolvedEntityType: EntityType {
        switch schemaVersion {
        case .collectionItem: .collectionItem
        case .sessionNote: .sessionNote
        case .sessionResource: .sessionResource
        }
    }
}

public struct SearchDocument: Equatable, Sendable {
    public var title: String
    public var body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}
