import Foundation

/// A rebuildable projection used to load notebook surfaces without scanning every payload.
/// The projection lives only in the encrypted local database. It is never synchronized or
/// included in a portable export.
public struct WorkspaceSummaryRecord: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var entityType: EntityType
    public var parentId: UUID?
    public var topicId: UUID?
    public var lifecycleState: String
    public var pinnedAt: Date?
    public var dueAt: Date?
    public var activityAt: Date

    public init(
        id: UUID,
        entityType: EntityType,
        parentId: UUID?,
        topicId: UUID?,
        lifecycleState: String,
        pinnedAt: Date?,
        dueAt: Date?,
        activityAt: Date
    ) {
        self.id = id
        self.entityType = entityType
        self.parentId = parentId
        self.topicId = topicId
        self.lifecycleState = lifecycleState
        self.pinnedAt = pinnedAt
        self.dueAt = dueAt
        self.activityAt = activityAt
    }
}

enum WorkspaceSummaryIndexer {
    static func record(
        id: UUID,
        entityType: EntityType,
        parentId: UUID?,
        content: Data,
        modifiedAt: Date
    ) -> WorkspaceSummaryRecord? {
        do {
            switch entityType {
            case .note:
                let value = try CanonicalJSON.decode(NotePayload.self, from: content)
                return make(
                    id, entityType, parentId, value.topicId,
                    value.archivedAt == nil ? "ACTIVE" : "ARCHIVED",
                    value.pinnedAt, nil, value.updatedAt
                )
            case .source:
                let value = try CanonicalJSON.decode(SourcePayload.self, from: content)
                return make(
                    id, entityType, parentId, value.primaryTopicId,
                    value.archivedAt == nil ? value.importState.rawValue : "ARCHIVED",
                    nil, nil, value.updatedAt
                )
            case .topic:
                let value = try CanonicalJSON.decode(TopicPayload.self, from: content)
                return make(
                    id, entityType, parentId, id,
                    value.archived ? "ARCHIVED" : "ACTIVE",
                    nil, value.endDate, value.updatedAt
                )
            case .list:
                let value = try CanonicalJSON.decode(ListPayload.self, from: content)
                return make(
                    id, entityType, parentId, nil,
                    value.archivedAt == nil ? "ACTIVE" : "ARCHIVED",
                    nil, nil, value.updatedAt
                )
            case .studySession:
                let value = try CanonicalJSON.decode(StudySessionPayload.self, from: content)
                return make(
                    id, entityType, parentId, value.topicId,
                    value.state.rawValue, nil, value.plannedAt, value.updatedAt
                )
            case .studyGoal:
                let value = try CanonicalJSON.decode(StudyGoalPayload.self, from: content)
                return make(
                    id, entityType, parentId, value.topicId,
                    value.state.rawValue, nil, value.targetDate, value.updatedAt
                )
            case .unresolvedQuestion:
                let value = try CanonicalJSON.decode(UnresolvedQuestionPayload.self, from: content)
                return make(
                    id, entityType, parentId, value.topicId,
                    value.resolvedAt == nil ? "OPEN" : "RESOLVED",
                    nil, nil, value.updatedAt
                )
            case .flashcard:
                let value = try CanonicalJSON.decode(FlashcardPayload.self, from: content)
                let state = value.archivedAt != nil
                    ? "ARCHIVED"
                    : (value.suspendedAt == nil ? "ACTIVE" : "SUSPENDED")
                // A card without reviews is due from the moment it is created. The latest
                // review's due date is resolved by the local projection query.
                return make(id, entityType, parentId, value.topicId, state, nil, value.createdAt, value.updatedAt)
            case .flashcardReview:
                let value = try CanonicalJSON.decode(FlashcardReviewPayload.self, from: content)
                return make(
                    id, entityType, value.cardId, nil, "REVIEWED",
                    nil, value.resultingState.dueAt, value.reviewedAt
                )
            case .practiceTest:
                let value = try CanonicalJSON.decode(PracticeTestPayload.self, from: content)
                return make(id, entityType, parentId, value.topicId, value.state.rawValue, nil, nil, value.updatedAt)
            case .testAttempt:
                let value = try CanonicalJSON.decode(TestAttemptPayload.self, from: content)
                return make(id, entityType, parentId, value.topicId, value.state.rawValue, nil, nil, value.updatedAt)
            case .studyRecommendation:
                let value = try CanonicalJSON.decode(StudyRecommendationPayload.self, from: content)
                return make(
                    id, entityType, parentId, value.topicId, "ACTIVE",
                    nil, value.expiresAt, value.updatedAt
                )
            case .trashEntry:
                let value = try CanonicalJSON.decode(TrashEntryPayload.self, from: content)
                return make(
                    id, entityType, value.targetId, nil, value.targetType.rawValue,
                    nil, nil, value.updatedAt
                )
            default:
                return nil
            }
        } catch {
            // This projection is disposable. A malformed or unsupported payload is omitted rather
            // than weakening the authoritative write path.
            return nil
        }
    }

    private static func make(
        _ id: UUID,
        _ entityType: EntityType,
        _ parentId: UUID?,
        _ topicId: UUID?,
        _ lifecycleState: String,
        _ pinnedAt: Date?,
        _ dueAt: Date?,
        _ activityAt: Date
    ) -> WorkspaceSummaryRecord {
        WorkspaceSummaryRecord(
            id: id,
            entityType: entityType,
            parentId: parentId,
            topicId: topicId,
            lifecycleState: lifecycleState,
            pinnedAt: pinnedAt,
            dueAt: dueAt,
            activityAt: activityAt
        )
    }
}
