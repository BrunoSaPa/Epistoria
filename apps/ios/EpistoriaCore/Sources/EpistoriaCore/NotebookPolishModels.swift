import Foundation

/// A stable page in a fixed-paper note. Page identity does not change when the owner reorders it.
public struct NotePagePayload: EntityPayload, Equatable {
    public static let entityType = EntityType.notePage
    public var schemaVersion = "note-page/v1"
    public var noteId: UUID
    public var orderKey: String
    public var configuration: NoteCanvasConfiguration
    public var trashedAt: Date?
    /// Changes when the page content changes. Thumbnails remain derived local state.
    public var thumbnailRevision: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        noteId: UUID,
        orderKey: String,
        configuration: NoteCanvasConfiguration,
        now: Date = .now
    ) {
        self.noteId = noteId
        self.orderKey = orderKey
        var pageConfiguration = configuration
        pageConfiguration.pageCount = 1
        self.configuration = pageConfiguration
        trashedAt = nil
        thumbnailRevision = 0
        createdAt = now
        updatedAt = now
    }
}

/// An encrypted, synchronized pointer that hides an authoritative record without erasing it.
/// Permanent removal remains a separate, explicit operation.
public struct TrashEntryPayload: EntityPayload, Equatable {
    public static let entityType = EntityType.trashEntry
    public var schemaVersion = "trash-entry/v1"
    public var targetId: UUID
    public var targetType: EntityType
    public var deletionGroupId: UUID
    public var previousParentId: UUID?
    public var previousOrderKey: String?
    public var displayName: String
    public var estimatedByteCount: Int64
    public var dependencyIds: [UUID]
    public var deletedAt: Date
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        targetId: UUID,
        targetType: EntityType,
        deletionGroupId: UUID = UUID(),
        previousParentId: UUID? = nil,
        previousOrderKey: String? = nil,
        displayName: String,
        estimatedByteCount: Int64 = 0,
        dependencyIds: [UUID] = [],
        now: Date = .now
    ) {
        self.targetId = targetId
        self.targetType = targetType
        self.deletionGroupId = deletionGroupId
        self.previousParentId = previousParentId
        self.previousOrderKey = previousOrderKey
        self.displayName = String(displayName.prefix(240))
        self.estimatedByteCount = max(estimatedByteCount, 0)
        self.dependencyIds = Array(Set(dependencyIds)).sorted { $0.uuidString < $1.uuidString }
        deletedAt = now
        createdAt = now
        updatedAt = now
    }
}

public enum LearningDestination: String, Codable, CaseIterable, Sendable {
    case overview = "OVERVIEW"
    case sessions = "SESSIONS"
    case review = "REVIEW"
    case tutor = "TUTOR"
    case knowledge = "KNOWLEDGE"
    case history = "HISTORY"
}

/// In-memory navigation context. Content remains referenced by encrypted record identity rather
/// than being copied into navigation state or logs.
public struct LearningLaunchContext: Codable, Equatable, Sendable {
    public var topicId: UUID?
    public var noteId: UUID?
    public var sourceVersionId: UUID?
    public var evidenceIds: [UUID]
    public var selectedObjectIds: [UUID]
    public var objective: String?
    public var destination: LearningDestination
    public var includeConnectedKnowledge: Bool

    public init(
        topicId: UUID? = nil,
        noteId: UUID? = nil,
        sourceVersionId: UUID? = nil,
        evidenceIds: [UUID] = [],
        selectedObjectIds: [UUID] = [],
        objective: String? = nil,
        destination: LearningDestination = .overview,
        includeConnectedKnowledge: Bool = false
    ) {
        self.topicId = topicId
        self.noteId = noteId
        self.sourceVersionId = sourceVersionId
        self.evidenceIds = Array(Set(evidenceIds)).sorted { $0.uuidString < $1.uuidString }
        self.selectedObjectIds = Array(Set(selectedObjectIds)).sorted { $0.uuidString < $1.uuidString }
        let cleanObjective = objective?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.objective = cleanObjective?.isEmpty == true ? nil : cleanObjective.map { String($0.prefix(1_000)) }
        self.destination = destination
        self.includeConnectedKnowledge = includeConnectedKnowledge
    }
}
