import Foundation

public enum EntityType: String, Codable, CaseIterable, Sendable {
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
    case active = "ACTIVE"
    case ended = "ENDED"
}

public protocol EntityPayload: Codable, Sendable {
    static var entityType: EntityType { get }
    var createdAt: Date { get }
    var updatedAt: Date { get }
}

public struct CollectionPayload: EntityPayload, Equatable {
    public static let entityType = EntityType.collection
    public var schemaVersion = "collection/v1"
    public var name: String
    public var parentCollectionId: UUID?
    public var createdAt: Date
    public var updatedAt: Date

    public init(name: String, parentCollectionId: UUID? = nil, now: Date = .now) {
        self.name = name
        self.parentCollectionId = parentCollectionId
        createdAt = now
        updatedAt = now
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
    public var schemaVersion = "note-block/v4"
    public var noteId: UUID
    public var blockType: NoteBlockKind
    public var orderKey: String
    public var plainText: String
    public var richTextRtf: Data?
    public var drawingData: Data?
    public var assetId: UUID?
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
