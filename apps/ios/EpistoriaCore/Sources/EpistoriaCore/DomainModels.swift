import CryptoKit
import Foundation

public enum EntityType: String, Codable, CaseIterable, Sendable {
    case area = "AREA"
    case topicArea = "TOPIC_AREA"
    case list = "LIST"
    case listItem = "LIST_ITEM"
    case topic = "TOPIC"
    case studySession = "STUDY_SESSION"
    case note = "NOTE"
    case notePage = "NOTE_PAGE"
    case noteBlock = "NOTE_BLOCK"
    case trashEntry = "TRASH_ENTRY"
    case source = "SOURCE"
    case asset = "ASSET"
    case annotation = "ANNOTATION"
    case sessionNote = "SESSION_NOTE"
    case sessionSource = "SESSION_SOURCE"
    case aiArtifact = "AI_ARTIFACT"
    case recognitionArtifact = "RECOGNITION_ARTIFACT"
    case recognitionDecision = "RECOGNITION_DECISION"
    case transcriptCorrection = "TRANSCRIPT_CORRECTION"
    case sourceVersion = "SOURCE_VERSION"
    case evidence = "EVIDENCE"
    case concept = "CONCEPT"
    case conceptEvidence = "CONCEPT_EVIDENCE"
    case conceptLink = "CONCEPT_LINK"
    case knowledgeMap = "KNOWLEDGE_MAP"
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
    case dailyReviewResponse = "DAILY_REVIEW_RESPONSE"
    case studyRecommendation = "STUDY_RECOMMENDATION"
    case recommendationResponse = "RECOMMENDATION_RESPONSE"
    case automationGrant = "AUTOMATION_GRANT"
    case tutorSession = "TUTOR_SESSION"
    case tutorTurn = "TUTOR_TURN"
    case learningSignal = "LEARNING_SIGNAL"
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

public enum NoteCanvasImageMask: String, Codable, CaseIterable, Sendable {
    case none = "NONE"
    case roundedRectangle = "ROUNDED_RECTANGLE"
    case ellipse = "ELLIPSE"
}

/// A crop rectangle in normalized coordinates after the image's quarter-turn rotation is applied.
/// Keeping it independent from the canvas frame makes the edit stable across resize and zoom.
public struct NoteCanvasImageCrop: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double = 0, y: Double = 0, width: Double = 1, height: Double = 1) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self = sanitized
    }

    public static let full = NoteCanvasImageCrop()

    public var sanitized: NoteCanvasImageCrop {
        var value = self
        value.x = min(max(value.x.isFinite ? value.x : 0, 0), 0.98)
        value.y = min(max(value.y.isFinite ? value.y : 0, 0), 0.98)
        value.width = min(max(value.width.isFinite ? value.width : 1, 0.02), 1 - value.x)
        value.height = min(max(value.height.isFinite ? value.height : 1, 0.02), 1 - value.y)
        return value
    }

    public var isFullFrame: Bool {
        let value = sanitized
        return abs(value.x) < 0.000_001
            && abs(value.y) < 0.000_001
            && abs(value.width - 1) < 0.000_001
            && abs(value.height - 1) < 0.000_001
    }
}

/// Non-destructive presentation metadata for a canvas image. `assetId` on the block identifies
/// the current displayed asset. `originalAssetId` retains the first immutable asset after a
/// replacement so the owner can restore it without relying on undo history.
public struct NoteCanvasImageConfiguration: Codable, Equatable, Sendable {
    public var crop: NoteCanvasImageCrop
    public var mask: NoteCanvasImageMask
    public var roundedCornerFraction: Double
    public var rotationQuarterTurns: Int
    public var originalAssetId: UUID?

    public init(
        crop: NoteCanvasImageCrop = .full,
        mask: NoteCanvasImageMask = .none,
        roundedCornerFraction: Double = 0.12,
        rotationQuarterTurns: Int = 0,
        originalAssetId: UUID? = nil
    ) {
        self.crop = crop.sanitized
        self.mask = mask
        self.roundedCornerFraction = min(max(
            roundedCornerFraction.isFinite ? roundedCornerFraction : 0.12,
            0.02
        ), 0.5)
        self.rotationQuarterTurns = ((rotationQuarterTurns % 4) + 4) % 4
        self.originalAssetId = originalAssetId
    }

    public var sanitized: NoteCanvasImageConfiguration {
        NoteCanvasImageConfiguration(
            crop: crop,
            mask: mask,
            roundedCornerFraction: roundedCornerFraction,
            rotationQuarterTurns: rotationQuarterTurns,
            originalAssetId: originalAssetId
        )
    }
}

/// The spatial presentation of one note. Measurements use document points (72 per inch),
/// independent of device scale and zoom. Infinite canvases share the same origin as fixed
/// paper and allow negative coordinates in every direction.
public struct NoteCanvasConfiguration: Codable, Equatable, Sendable {
    public var schemaVersion = "note-canvas/v4"
    public var pageFormat: NotePageFormat
    public var orientation: NotePageOrientation
    public var paperStyle: NotePaperStyle
    public var paperColor: NotePaperColor
    /// Pattern spacing in document points. The renderer clamps decoded values before use.
    public var paperSpacing: Double
    public init(
        pageFormat: NotePageFormat = .a4,
        orientation: NotePageOrientation = .portrait,
        paperStyle: NotePaperStyle = .plain,
        paperColor: NotePaperColor = .white,
        paperSpacing: Double? = nil
    ) {
        self.pageFormat = pageFormat
        self.orientation = orientation
        self.paperStyle = paperStyle
        self.paperColor = paperColor
        self.paperSpacing = min(
            max(paperSpacing ?? (paperStyle == .dotted ? 24 : 28), 12),
            72
        )
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

public enum SourceKind: String, Codable, CaseIterable, Sendable {
    case book = "BOOK"
    case pdf = "PDF"
    case paper = "PAPER"
    case video = "VIDEO"
    case website = "WEBSITE"
    case lecture = "LECTURE"
    case image = "IMAGE"
    case document = "DOCUMENT"
    case topicMaterial = "TOPIC_MATERIAL"
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

public struct ListPayload: EntityPayload, Equatable {
    public static let entityType = EntityType.list
    public var schemaVersion = "list/v1"
    public var name: String
    public var archivedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(name: String, now: Date = .now) {
        self.name = name
        archivedAt = nil
        createdAt = now
        updatedAt = now
    }
}

public struct StudySessionPayload: EntityPayload, Equatable {
    public static let entityType = EntityType.studySession
    public var schemaVersion = "study-session/v2"
    public var title: String
    public var topicId: UUID?
    public var primaryListId: UUID?
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
        topicId: UUID? = nil,
        goals: [String] = [],
        now: Date = .now
    ) {
        self.title = title
        self.topicId = topicId
        primaryListId = nil
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
    public var schemaVersion = "note/v5"
    public var title: String
    public var topicId: UUID?
    public var studySessionId: UUID?
    public var archivedAt: Date?
    /// A local-first ordering hint used by Notebook and Today. The value is encrypted and syncs
    /// with the note so another owner device can present the same pinned set.
    public var pinnedAt: Date?
    /// `nil` only for records created before the spatial editor. Those records render with the
    /// documented A4/plain compatibility default and are upgraded on the first canvas change.
    public var canvas: NoteCanvasConfiguration?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        title: String,
        topicId: UUID? = nil,
        studySessionId: UUID? = nil,
        canvas: NoteCanvasConfiguration = NoteCanvasConfiguration(),
        now: Date = .now
    ) {
        self.title = title
        self.topicId = topicId
        self.studySessionId = studySessionId
        archivedAt = nil
        pinnedAt = nil
        self.canvas = canvas
        createdAt = now
        updatedAt = now
    }
}

public struct NoteBlockPayload: EntityPayload, Equatable {
    public static let entityType = EntityType.noteBlock
    public var schemaVersion = "note-block/v8"
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
    /// Non-destructive crop, mask, rotation, and original-reference metadata for image blocks.
    public var imageConfiguration: NoteCanvasImageConfiguration?
    /// Stable page identity for fixed-page notes. Infinite-canvas blocks leave this nil.
    public var pageId: UUID?
    public var tombstone: Bool
    public var createdAt: Date
    public var updatedAt: Date

    /// Stable identity for OCR input bytes. Local database revisions represent synchronized
    /// server state and do not advance for every pending local edit.
    public var ocrInputRevision: Int {
        let input: Data
        if let drawingData, !drawingData.isEmpty {
            input = drawingData
        } else if blockType == .image, let assetId {
            // Presentation-only edits do not invalidate recognition. Replacing the immutable
            // source asset does, even before an image-specific OCR workflow is enabled.
            input = Data(assetId.uuidString.lowercased().utf8)
        } else {
            return 0
        }
        let prefix = SHA256.hash(data: input).prefix(MemoryLayout<UInt64>.size)
        let value = prefix.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return Int(value & UInt64(Int.max))
    }

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
        imageConfiguration = nil
        pageId = nil
        tombstone = false
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
    public var sourceId: UUID
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
        sourceId: UUID,
        annotationType: AnnotationKind,
        pageNumber: Int? = nil,
        comment: String = "",
        now: Date = .now
    ) {
        self.sourceId = sourceId
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
        case listItem = "list-item/v1"
        case sessionNote = "session-note/v1"
        case sessionSource = "session-source/v1"
    }

    public static let entityType = EntityType.listItem
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
        case .listItem: .listItem
        case .sessionNote: .sessionNote
        case .sessionSource: .sessionSource
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
