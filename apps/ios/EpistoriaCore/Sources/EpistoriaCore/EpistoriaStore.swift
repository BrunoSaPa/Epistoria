import Foundation

public struct IdentifiedPayload<Payload: EntityPayload>: Sendable {
    public var id: UUID
    public var payload: Payload
    public var revision: Int
    public var syncState: LocalSyncState

    public init(id: UUID, payload: Payload, revision: Int, syncState: LocalSyncState) {
        self.id = id
        self.payload = payload
        self.revision = revision
        self.syncState = syncState
    }
}

public enum StoreError: Error, Equatable {
    case entityNotFound
    case entityTypeMismatch
    case activeSessionExists
    case sessionTopicRequired
    case artifactAlreadyAccepted
    case invalidDraftReview
    case invalidFeedbackReview
    case invalidAutomationGrant
    case invalidConceptLink
    case invalidTranscriptCorrection
    case transcriptReviewRequired
    case transcriptCorrectionConflict
    case relationshipNotFound
}

public struct AcceptedLearningRecords: Equatable, Sendable {
    public var flashcards: Int
    public var tests: Int
    public var concepts: Int
    public var conceptLinks: Int

    public init(flashcards: Int = 0, tests: Int = 0, concepts: Int = 0, conceptLinks: Int = 0) {
        self.flashcards = flashcards
        self.tests = tests
        self.concepts = concepts
        self.conceptLinks = conceptLinks
    }
}

extension StoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .entityNotFound:
            "The requested record is no longer available."
        case .entityTypeMismatch:
            "The record has an unexpected type."
        case .activeSessionExists:
            "Pause or end the active study session before starting another one."
        case .sessionTopicRequired:
            "Choose a Topic for this study session."
        case .artifactAlreadyAccepted:
            "This draft was already accepted and cannot be changed."
        case .invalidDraftReview:
            "The reviewed draft contains an invalid or unknown item. Reload the original draft and try again."
        case .invalidFeedbackReview:
            "The reviewed feedback is incomplete or cites material outside this request."
        case .invalidAutomationGrant:
            "The automation permission is invalid, inactive, expired, over budget, or outside its Topic and task scope."
        case .invalidConceptLink:
            "Choose two different Concepts and valid supporting Evidence for this connection."
        case .invalidTranscriptCorrection:
            "The transcript correction is empty, unchanged, or does not match this transcript."
        case .transcriptReviewRequired:
            "Review this transcript before creating Evidence from it."
        case .transcriptCorrectionConflict:
            "This segment has conflicting corrections. Resolve the conflict before using it as Evidence."
        case .relationshipNotFound:
            "This item is no longer linked here. Reload the view and try again."
        }
    }
}

public enum EntitySearchIndexer {
    public static func document(for entityType: EntityType, content: Data) -> SearchDocument? {
        do {
            switch entityType {
            case .area:
                let value = try CanonicalJSON.decode(AreaPayload.self, from: content)
                return SearchDocument(title: value.name, body: value.areaDescription ?? "")
            case .collection:
                let value = try CanonicalJSON.decode(CollectionPayload.self, from: content)
                return SearchDocument(title: value.name, body: "")
            case .institution:
                let value = try CanonicalJSON.decode(InstitutionPayload.self, from: content)
                return SearchDocument(title: value.name, body: "")
            case .academicTerm:
                let value = try CanonicalJSON.decode(AcademicTermPayload.self, from: content)
                return SearchDocument(title: value.name, body: "")
            case .course:
                let value = try CanonicalJSON.decode(TopicPayload.self, from: content)
                return SearchDocument(
                    title: value.name,
                    body: [value.officialClassName, value.code, value.professor, value.topicDescription]
                        .compactMap(\ .self).joined(separator: "\n")
                )
            case .studySession:
                let value = try CanonicalJSON.decode(StudySessionPayload.self, from: content)
                return SearchDocument(title: value.title, body: value.goals.joined(separator: "\n"))
            case .note:
                let value = try CanonicalJSON.decode(NotePayload.self, from: content)
                return SearchDocument(title: value.title, body: "")
            case .noteBlock:
                let value = try CanonicalJSON.decode(NoteBlockPayload.self, from: content)
                return SearchDocument(
                    title: "",
                    body: [value.plainText, value.transcription].compactMap(\ .self)
                        .joined(separator: "\n")
                )
            case .resource:
                let value = try CanonicalJSON.decode(SourcePayload.self, from: content)
                return SearchDocument(title: value.title, body: value.authors.joined(separator: "\n"))
            case .evidence:
                let value = try CanonicalJSON.decode(EvidencePayload.self, from: content)
                return SearchDocument(title: "Evidence", body: [value.excerpt, value.note].compactMap(\ .self).joined(separator: "\n"))
            case .concept:
                let value = try CanonicalJSON.decode(ConceptPayload.self, from: content)
                return SearchDocument(title: value.name, body: ([value.conceptDescription] + value.aliases).joined(separator: "\n"))
            case .studyGoal:
                let value = try CanonicalJSON.decode(StudyGoalPayload.self, from: content)
                return SearchDocument(title: value.title, body: value.details ?? "")
            case .unresolvedQuestion:
                let value = try CanonicalJSON.decode(UnresolvedQuestionPayload.self, from: content)
                return SearchDocument(title: "Unresolved question", body: value.question)
            case .flashcardRevision:
                let value = try CanonicalJSON.decode(FlashcardRevisionPayload.self, from: content)
                return SearchDocument(title: value.prompt, body: value.answer)
            case .practiceTest:
                let value = try CanonicalJSON.decode(PracticeTestPayload.self, from: content)
                return SearchDocument(title: value.title, body: "")
            case .testQuestion:
                let value = try CanonicalJSON.decode(TestQuestionPayload.self, from: content)
                return SearchDocument(title: "Test question", body: value.prompt)
            case .studyRecommendation:
                let value = try CanonicalJSON.decode(StudyRecommendationPayload.self, from: content)
                return SearchDocument(title: value.title, body: value.explanation)
            case .tutorSession:
                let value = try CanonicalJSON.decode(TutorSessionPayload.self, from: content)
                return SearchDocument(title: "Tutor session", body: value.objective ?? "")
            case .tutorTurn:
                let value = try CanonicalJSON.decode(TutorTurnPayload.self, from: content)
                return SearchDocument(title: value.role == .learner ? "Learner" : "Tutor", body: value.text)
            case .learningSignal:
                let value = try CanonicalJSON.decode(LearningSignalPayload.self, from: content)
                return SearchDocument(title: value.objective, body: value.rationale ?? value.outcome.rawValue)
            case .asset:
                let value = try CanonicalJSON.decode(AssetPayload.self, from: content)
                return SearchDocument(title: value.originalFilename, body: value.mimeType)
            case .annotation:
                let value = try CanonicalJSON.decode(AnnotationPayload.self, from: content)
                return SearchDocument(
                    title: value.annotationType.rawValue.capitalized,
                    body: [value.selectedText, value.comment].compactMap(\ .self)
                        .joined(separator: "\n")
                )
            case .transcriptCorrection:
                let value = try CanonicalJSON.decode(TranscriptCorrectionPayload.self, from: content)
                return SearchDocument(
                    title: "Transcript correction",
                    body: [value.correctedText, value.reason].compactMap(\ .self).joined(separator: "\n")
                )
            case .aiArtifact:
                return nil
            case .recognitionArtifact, .recognitionDecision:
                return nil
            case .topicArea, .collectionItem, .sessionNote, .sessionResource, .sourceVersion,
                 .conceptEvidence, .conceptLink, .knowledgeMap, .sessionActivity, .flashcardDeck, .flashcard,
                 .flashcardReview, .topicScopeSnapshot, .testBlueprint, .testAttempt,
                 .testResponse, .recommendationResponse, .automationGrant:
                return nil
            }
        } catch {
            return nil
        }
    }

}

public actor EpistoriaStore {
    public let database: SQLCipherDatabase

    public init(database: SQLCipherDatabase) {
        self.database = database
    }

    public func topics() async throws -> [IdentifiedPayload<TopicPayload>] {
        try await list(TopicPayload.self)
    }

    public func topic(id: UUID) async throws -> IdentifiedPayload<TopicPayload> {
        try await payload(TopicPayload.self, id: id)
    }

    /// Writes the upgraded Topic representation only after preserving the legacy encrypted
    /// payload locally for recovery. The server transport type remains `COURSE`.
    @discardableResult
    public func saveTopic(id: UUID = UUID(), payload: TopicPayload) async throws -> UUID {
        var migration: LocalMigrationBatch?
        if let existing = try await database.entity(id: id),
           existing.entityType == .course,
           let object = try? JSONSerialization.jsonObject(with: existing.content) as? [String: Any],
           object["schemaVersion"] as? String == "course/v1" {
            migration = LocalMigrationBatch(
                name: "course-to-topic/v1",
                backupEntityId: id,
                backupContent: existing.content
            )
        }
        var upgraded = payload
        upgraded.schemaVersion = "topic/v1"
        let write = try localWrite(
            id: id,
            payload: upgraded,
            parentId: upgraded.primaryAreaId,
            relationIds: [
                upgraded.primaryAreaId,
                upgraded.institutionId,
                upgraded.academicTermId,
            ].compactMap(\ .self)
        )
        try await database.saveLocalBatch([write], migration: migration)
        return id
    }

    @discardableResult
    public func createArea(name: String, description: String? = nil) async throws -> UUID {
        try await save(payload: AreaPayload(name: name, areaDescription: description))
    }

    @discardableResult
    public func createTopic(name: String, primaryAreaId: UUID? = nil) async throws -> UUID {
        if let primaryAreaId { _ = try await payload(AreaPayload.self, id: primaryAreaId) }
        let topicId = UUID()
        let topic = TopicPayload(name: name, primaryAreaId: primaryAreaId)
        var writes = try [localWrite(
            id: topicId,
            payload: topic,
            parentId: primaryAreaId,
            relationIds: [primaryAreaId].compactMap(\ .self)
        )]
        if let primaryAreaId {
            writes.append(try localWrite(
                id: UUID(),
                payload: TopicAreaRelationPayload(topicId: topicId, areaId: primaryAreaId, role: .primary),
                parentId: primaryAreaId,
                relationIds: [topicId, primaryAreaId]
            ))
        }
        try await database.saveLocalBatch(writes)
        return topicId
    }

    @discardableResult
    public func relateTopic(
        _ topicId: UUID,
        to areaId: UUID,
        role: TopicAreaRole
    ) async throws -> UUID {
        _ = try await topic(id: topicId)
        _ = try await payload(AreaPayload.self, id: areaId)
        let existing = try await list(TopicAreaRelationPayload.self).first {
            $0.payload.topicId == topicId && $0.payload.areaId == areaId
        }
        if var existing {
            if existing.payload.role != role {
                existing.payload.role = role
                existing.payload.updatedAt = .now
                _ = try await save(
                    id: existing.id,
                    payload: existing.payload,
                    parentId: areaId,
                    relationIds: [topicId, areaId]
                )
            }
            return existing.id
        }
        return try await save(
            payload: TopicAreaRelationPayload(topicId: topicId, areaId: areaId, role: role),
            parentId: areaId,
            relationIds: [topicId, areaId]
        )
    }

    public func relatedAreaIds(topicId: UUID) async throws -> [UUID] {
        try await list(TopicAreaRelationPayload.self)
            .filter { $0.payload.topicId == topicId && $0.payload.role == .related }
            .map(\.payload.areaId)
    }

    /// Lists are the presentation name for the existing Collection record. IDs and links do not
    /// change, so synced notebooks require no destructive migration.
    public func lists() async throws -> [IdentifiedPayload<CollectionPayload>] {
        try await list(CollectionPayload.self)
    }

    @discardableResult
    public func createList(name: String, parentListId: UUID? = nil) async throws -> UUID {
        try await save(
            payload: CollectionPayload(name: name, parentCollectionId: parentListId),
            parentId: parentListId,
            relationIds: [parentListId].compactMap(\ .self)
        )
    }

    public func updateList(
        id: UUID,
        name: String,
        parentListId: UUID?,
        archived: Bool,
        at date: Date = .now
    ) async throws {
        if let parentListId {
            guard parentListId != id else {
                throw LocalDatabaseError.queryFailed("a List cannot contain itself")
            }
            _ = try await payload(CollectionPayload.self, id: parentListId)
        }
        var list = try await payload(CollectionPayload.self, id: id)
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            throw LocalDatabaseError.queryFailed("a List needs a name")
        }
        let migration: LocalMigrationBatch? = list.payload.schemaVersion == "collection/v1"
            ? try await database.entity(id: id).map {
                LocalMigrationBatch(
                    name: "collection-to-list/v2",
                    backupEntityId: id,
                    backupContent: $0.content
                )
            }
            : nil
        list.payload.schemaVersion = "collection/v2"
        list.payload.name = cleanName
        list.payload.parentCollectionId = parentListId
        list.payload.archivedAt = archived ? (list.payload.archivedAt ?? date) : nil
        list.payload.updatedAt = date
        try await database.saveLocalBatch(
            try [localWrite(
                id: id,
                payload: list.payload,
                parentId: parentListId,
                relationIds: [parentListId].compactMap(\ .self)
            )],
            migration: migration
        )
    }

    @discardableResult
    public func createFlashcardDeck(topicId: UUID, name: String, at date: Date = .now) async throws -> UUID {
        _ = try await topic(id: topicId)
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            throw LocalDatabaseError.queryFailed("a deck needs a name")
        }
        return try await save(
            payload: FlashcardDeckPayload(topicId: topicId, name: cleanName, now: date),
            parentId: topicId,
            relationIds: [topicId]
        )
    }

    public func updateFlashcardDeck(
        id: UUID,
        name: String,
        archived: Bool,
        at date: Date = .now
    ) async throws {
        var deck = try await payload(FlashcardDeckPayload.self, id: id)
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            throw LocalDatabaseError.queryFailed("a deck needs a name")
        }
        deck.payload.name = cleanName
        deck.payload.archivedAt = archived ? (deck.payload.archivedAt ?? date) : nil
        deck.payload.updatedAt = date
        _ = try await save(
            id: id,
            payload: deck.payload,
            parentId: deck.payload.topicId,
            relationIds: [deck.payload.topicId]
        )
    }

    public func updateStudyGoal(
        id: UUID,
        title: String,
        details: String?,
        targetDate: Date?,
        priority: Int,
        state: LearningRecordState,
        at date: Date = .now
    ) async throws {
        var goal = try await payload(StudyGoalPayload.self, id: id)
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else {
            throw LocalDatabaseError.queryFailed("a goal needs a title")
        }
        goal.payload.title = cleanTitle
        goal.payload.details = details?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        goal.payload.targetDate = targetDate
        goal.payload.priority = min(max(priority, 0), 3)
        goal.payload.state = state
        goal.payload.updatedAt = date
        _ = try await save(
            id: id,
            payload: goal.payload,
            parentId: goal.payload.topicId,
            relationIds: [goal.payload.topicId]
        )
    }

    public func updateUnresolvedQuestion(
        id: UUID,
        question: String,
        resolvedAnswer: String?,
        resolved: Bool,
        at date: Date = .now
    ) async throws {
        var item = try await payload(UnresolvedQuestionPayload.self, id: id)
        let cleanQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuestion.isEmpty else {
            throw LocalDatabaseError.queryFailed("a question cannot be empty")
        }
        item.payload.question = cleanQuestion
        item.payload.resolvedAnswer = resolved
            ? resolvedAnswer?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            : nil
        item.payload.resolvedAt = resolved ? (item.payload.resolvedAt ?? date) : nil
        item.payload.updatedAt = date
        _ = try await save(
            id: id,
            payload: item.payload,
            parentId: item.payload.topicId,
            relationIds: [item.payload.topicId] + item.payload.sourceEvidenceIds
        )
    }

    @discardableResult
    public func save<Payload: EntityPayload>(
        id: UUID = UUID(),
        payload: Payload,
        parentId: UUID? = nil,
        relationIds: [UUID] = [],
        entityTypeOverride: EntityType? = nil
    ) async throws -> UUID {
        let content = try CanonicalJSON.encode(payload)
        let entityType = entityTypeOverride ?? Payload.entityType
        _ = try await database.saveLocal(
            id: id,
            entityType: entityType,
            parentId: parentId,
            relationIds: relationIds,
            content: content,
            search: EntitySearchIndexer.document(for: entityType, content: content),
            modifiedAt: payload.updatedAt
        )
        return id
    }

    public func payload<Payload: EntityPayload>(
        _ type: Payload.Type,
        id: UUID
    ) async throws -> IdentifiedPayload<Payload> {
        guard let entity = try await database.entity(id: id) else {
            throw StoreError.entityNotFound
        }
        guard entity.entityType == Payload.entityType || Payload.self == RelationPayload.self else {
            throw StoreError.entityTypeMismatch
        }
        return IdentifiedPayload(
            id: id,
            payload: try CanonicalJSON.decode(type, from: entity.content),
            revision: entity.revision,
            syncState: entity.syncState
        )
    }

    public func list<Payload: EntityPayload>(
        _ type: Payload.Type,
        parentId: UUID? = nil,
        entityTypeOverride: EntityType? = nil
    ) async throws -> [IdentifiedPayload<Payload>] {
        let entities = try await database.entities(
            type: entityTypeOverride ?? Payload.entityType,
            parentId: parentId
        )
        return try entities.map { entity in
            IdentifiedPayload(
                id: entity.id,
                payload: try CanonicalJSON.decode(type, from: entity.content),
                revision: entity.revision,
                syncState: entity.syncState
            )
        }
    }

    @discardableResult
    public func createNote(
        title: String,
        courseId: UUID? = nil,
        sessionId: UUID? = nil,
        canvas: NoteCanvasConfiguration = NoteCanvasConfiguration()
    ) async throws -> UUID {
        let noteId = UUID()
        let note = NotePayload(
            title: title,
            courseId: courseId,
            studySessionId: sessionId,
            canvas: canvas
        )
        var writes = try [localWrite(
            id: noteId,
            payload: note,
            parentId: courseId ?? sessionId,
            relationIds: [courseId, sessionId].compactMap(\ .self)
        )]
        if let sessionId {
            let relation = RelationPayload(kind: .sessionNote, leftId: sessionId, rightId: noteId)
            writes.append(try localWrite(
                id: UUID(),
                payload: relation,
                parentId: sessionId,
                relationIds: [sessionId, noteId]
            ).overridingEntityType(.sessionNote))
            writes.append(try localWrite(
                id: UUID(),
                payload: SessionActivityPayload(sessionId: sessionId, itemId: noteId, kind: .noteCreated),
                parentId: sessionId,
                relationIds: [sessionId, noteId]
            ))
        }
        try await database.saveLocalBatch(writes)
        return noteId
    }

    /// Adds an existing note to a topic collection without moving or duplicating the note.
    /// The relationship is idempotent so repeated taps cannot create duplicate membership.
    @discardableResult
    public func linkNote(_ noteId: UUID, toCollection collectionId: UUID) async throws -> UUID {
        _ = try await payload(NotePayload.self, id: noteId)
        _ = try await payload(CollectionPayload.self, id: collectionId)
        let existing = try await list(
            RelationPayload.self,
            parentId: collectionId,
            entityTypeOverride: .collectionItem
        ).first {
            $0.payload.schemaVersion == .collectionItem
                && $0.payload.leftId == collectionId
                && $0.payload.rightId == noteId
        }
        if let existing { return existing.id }
        let relation = RelationPayload(
            kind: .collectionItem,
            leftId: collectionId,
            rightId: noteId
        )
        return try await save(
            payload: relation,
            parentId: collectionId,
            relationIds: [collectionId, noteId],
            entityTypeOverride: .collectionItem
        )
    }

    /// Removes List membership without changing or deleting the note. Every matching relation is
    /// tombstoned in one local transaction so older duplicate links cannot keep the note visible.
    public func unlinkNote(
        _ noteId: UUID,
        fromCollection collectionId: UUID,
        at date: Date = .now
    ) async throws {
        _ = try await payload(NotePayload.self, id: noteId)
        _ = try await payload(CollectionPayload.self, id: collectionId)
        let matches = try await list(
            RelationPayload.self,
            parentId: collectionId,
            entityTypeOverride: .collectionItem
        ).filter {
            $0.payload.schemaVersion == .collectionItem
                && $0.payload.leftId == collectionId
                && $0.payload.rightId == noteId
        }
        guard !matches.isEmpty else { throw StoreError.relationshipNotFound }
        try await database.saveLocalBatch(
            [],
            deleting: matches.map(\.id),
            deletedAt: date
        )
    }

    /// Adds an existing note to a focused study session. Session membership is a relationship,
    /// so one source note can be reviewed in multiple sessions without being copied.
    @discardableResult
    public func linkNote(_ noteId: UUID, toSession sessionId: UUID) async throws -> UUID {
        _ = try await payload(NotePayload.self, id: noteId)
        _ = try await payload(StudySessionPayload.self, id: sessionId)
        let existing = try await list(
            RelationPayload.self,
            parentId: sessionId,
            entityTypeOverride: .sessionNote
        ).first {
            $0.payload.schemaVersion == .sessionNote
                && $0.payload.leftId == sessionId
                && $0.payload.rightId == noteId
        }
        if let existing {
            _ = try await recordSessionActivity(sessionId: sessionId, itemId: noteId, kind: .noteOpened)
            return existing.id
        }
        let relation = RelationPayload(kind: .sessionNote, leftId: sessionId, rightId: noteId)
        let relationId = UUID()
        let writes = try [
            localWrite(
                id: relationId,
                payload: relation,
                parentId: sessionId,
                relationIds: [sessionId, noteId]
            ).overridingEntityType(.sessionNote),
            localWrite(
                id: UUID(),
                payload: SessionActivityPayload(sessionId: sessionId, itemId: noteId, kind: .noteOpened),
                parentId: sessionId,
                relationIds: [sessionId, noteId]
            ),
        ]
        try await database.saveLocalBatch(writes)
        return relationId
    }

    /// Removes Session membership without deleting the note or its activity history. Legacy
    /// note-owned membership is cleared in the same local transaction as relation tombstones.
    public func unlinkNote(
        _ noteId: UUID,
        fromSession sessionId: UUID,
        at date: Date = .now
    ) async throws {
        _ = try await payload(StudySessionPayload.self, id: sessionId)
        var note = try await payload(NotePayload.self, id: noteId)
        let matches = try await list(
            RelationPayload.self,
            parentId: sessionId,
            entityTypeOverride: .sessionNote
        ).filter {
            $0.payload.schemaVersion == .sessionNote
                && $0.payload.leftId == sessionId
                && $0.payload.rightId == noteId
        }
        let hasLegacyMembership = note.payload.studySessionId == sessionId
        guard !matches.isEmpty || hasLegacyMembership else { throw StoreError.relationshipNotFound }

        var writes: [LocalEntityWrite] = []
        if hasLegacyMembership {
            note.payload.studySessionId = nil
            note.payload.updatedAt = date
            writes.append(try localWrite(
                id: noteId,
                payload: note.payload,
                parentId: note.payload.courseId,
                relationIds: [note.payload.courseId].compactMap(\ .self)
            ))
        }
        try await database.saveLocalBatch(
            writes,
            deleting: matches.map(\.id),
            deletedAt: date
        )
    }

    /// Returns relation-backed session membership and keeps legacy note-owned membership readable.
    public func noteIdsLinkedToSession(_ sessionId: UUID) async throws -> Set<UUID> {
        let relations = try await list(
            RelationPayload.self,
            parentId: sessionId,
            entityTypeOverride: .sessionNote
        )
        var result = Set(
            relations.lazy
                .filter {
                    $0.payload.schemaVersion == .sessionNote
                        && $0.payload.leftId == sessionId
                }
                .map(\.payload.rightId)
        )
        let legacyNotes = try await list(NotePayload.self)
            .filter { $0.payload.studySessionId == sessionId }
        result.formUnion(legacyNotes.map(\.id))
        return result
    }

    @discardableResult
    public func appendTextBlock(noteId: UUID, text: String = "") async throws -> UUID {
        let count = try await database.entities(type: .noteBlock, parentId: noteId).count
        let block = NoteBlockPayload(
            noteId: noteId,
            blockType: .text,
            orderKey: String(format: "%012d", count * 1_000),
            plainText: text
        )
        return try await save(
            payload: block,
            parentId: noteId,
            relationIds: [noteId]
        )
    }

    @discardableResult
    public func appendCanvasText(
        noteId: UUID,
        text: String = "",
        placement: NoteCanvasPlacement,
        pageIndex: Int = 0
    ) async throws -> UUID {
        let count = try await database.entities(type: .noteBlock, parentId: noteId).count
        var block = NoteBlockPayload(
            noteId: noteId,
            blockType: .text,
            orderKey: String(format: "%012d", count * 1_000),
            plainText: text
        )
        block.canvasPlacement = placement
        block.canvasPageIndex = max(pageIndex, 0)
        return try await save(payload: block, parentId: noteId, relationIds: [noteId])
    }

    /// Places a reusable Evidence card on a note. The Evidence remains the source of truth and
    /// retains its exact Source Version and locator.
    @discardableResult
    public func appendCanvasEvidence(
        noteId: UUID,
        evidenceId: UUID,
        placement: NoteCanvasPlacement,
        pageIndex: Int = 0
    ) async throws -> UUID {
        _ = try await payload(NotePayload.self, id: noteId)
        let evidence = try await payload(EvidencePayload.self, id: evidenceId)
        let source = try await payload(SourcePayload.self, id: evidence.payload.sourceId)
        let version = try await payload(SourceVersionPayload.self, id: evidence.payload.sourceVersionId)
        guard version.payload.sourceId == source.id else { throw SourceModelError.sourceVersionMismatch }
        let count = try await database.entities(type: .noteBlock, parentId: noteId).count
        var block = NoteBlockPayload(
            noteId: noteId,
            blockType: .callout,
            orderKey: String(format: "%012d", count * 1_000),
            plainText: ""
        )
        block.evidenceId = evidenceId
        block.canvasPlacement = placement
        block.canvasPageIndex = max(pageIndex, 0)
        return try await save(
            payload: block,
            parentId: noteId,
            relationIds: [noteId, evidenceId, source.id, version.id]
        )
    }

    @discardableResult
    public func appendCanvasImage(
        noteId: UUID,
        assetId: UUID,
        filename: String,
        placement: NoteCanvasPlacement,
        pageIndex: Int = 0
    ) async throws -> UUID {
        let count = try await database.entities(type: .noteBlock, parentId: noteId).count
        var block = NoteBlockPayload(
            noteId: noteId,
            blockType: .image,
            orderKey: String(format: "%012d", count * 1_000),
            plainText: filename
        )
        block.assetId = assetId
        block.canvasPlacement = placement
        block.canvasPageIndex = max(pageIndex, 0)
        return try await save(
            payload: block,
            parentId: noteId,
            relationIds: [noteId, assetId]
        )
    }

    @discardableResult
    public func appendCanvasShape(
        noteId: UUID,
        shape: NoteCanvasShape,
        placement: NoteCanvasPlacement,
        pageIndex: Int = 0
    ) async throws -> UUID {
        let count = try await database.entities(type: .noteBlock, parentId: noteId).count
        var block = NoteBlockPayload(
            noteId: noteId,
            blockType: .shape,
            orderKey: String(format: "%012d", count * 1_000),
            plainText: "\(shape.kind.rawValue.lowercased()) shape"
        )
        block.canvasShape = shape
        block.canvasPlacement = placement
        block.canvasPageIndex = max(pageIndex, 0)
        return try await save(payload: block, parentId: noteId, relationIds: [noteId])
    }

    @discardableResult
    public func appendCanvasEquation(
        noteId: UUID,
        symbol: String,
        placement: NoteCanvasPlacement,
        pageIndex: Int = 0
    ) async throws -> UUID {
        let count = try await database.entities(type: .noteBlock, parentId: noteId).count
        var block = NoteBlockPayload(
            noteId: noteId,
            blockType: .equation,
            orderKey: String(format: "%012d", count * 1_000),
            plainText: symbol
        )
        block.canvasPlacement = placement
        block.canvasPageIndex = max(pageIndex, 0)
        return try await save(payload: block, parentId: noteId, relationIds: [noteId])
    }

    @discardableResult
    public func appendCanvasInkLayer(noteId: UUID, pageIndex: Int = 0) async throws -> UUID {
        let count = try await database.entities(type: .noteBlock, parentId: noteId).count
        var block = NoteBlockPayload(
            noteId: noteId,
            blockType: .handwriting,
            orderKey: String(format: "%012d", count * 1_000)
        )
        block.canvasRole = .inkLayer
        block.canvasPageIndex = max(pageIndex, 0)
        return try await save(payload: block, parentId: noteId, relationIds: [noteId])
    }

    @discardableResult
    public func appendHandwritingBlock(noteId: UUID) async throws -> UUID {
        let count = try await database.entities(type: .noteBlock, parentId: noteId).count
        let block = NoteBlockPayload(
            noteId: noteId,
            blockType: .handwriting,
            orderKey: String(format: "%012d", count * 1_000)
        )
        return try await save(
            payload: block,
            parentId: noteId,
            relationIds: [noteId]
        )
    }

    @discardableResult
    public func startSession(
        title: String,
        courseId: UUID? = nil,
        goals: [String] = [],
        state: StudySessionState = .active,
        requireTopic: Bool = false,
        objective: String? = nil,
        startingNotes: String? = nil
    ) async throws -> UUID {
        if requireTopic, courseId == nil {
            throw StoreError.sessionTopicRequired
        }
        if state == .active {
            let existing = try await list(StudySessionPayload.self)
            if existing.contains(where: { $0.payload.state == .active }) {
                throw StoreError.activeSessionExists
            }
        }
        var payload = StudySessionPayload(title: title, courseId: courseId, goals: goals)
        payload.state = state
        payload.objective = objective ?? goals.first
        payload.startingNotes = startingNotes
        if state == .planned {
            payload.plannedAt = payload.createdAt
        }
        return try await save(
            payload: payload,
            parentId: courseId,
            relationIds: [courseId].compactMap(\ .self)
        )
    }

    public func endSession(id: UUID, at date: Date = .now) async throws {
        var identified = try await payload(StudySessionPayload.self, id: id)
        identified.payload.state = .ended
        identified.payload.endedAt = date
        identified.payload.updatedAt = date
        _ = try await save(
            id: id,
            payload: identified.payload,
            parentId: identified.payload.courseId,
            relationIds: [identified.payload.courseId].compactMap(\ .self)
        )
    }

    public func setSessionState(id: UUID, state: StudySessionState, at date: Date = .now) async throws {
        if state == .active {
            let existing = try await list(StudySessionPayload.self)
            if existing.contains(where: { $0.id != id && $0.payload.state == .active }) {
                throw StoreError.activeSessionExists
            }
        }
        var identified = try await payload(StudySessionPayload.self, id: id)
        identified.payload.state = state
        identified.payload.updatedAt = date
        switch state {
        case .planned:
            identified.payload.plannedAt = date
        case .active:
            identified.payload.pausedAt = nil
        case .paused:
            identified.payload.pausedAt = date
        case .ended:
            identified.payload.endedAt = date
        case .abandoned:
            identified.payload.abandonedAt = date
        }
        _ = try await save(
            id: id,
            payload: identified.payload,
            parentId: identified.payload.courseId,
            relationIds: [identified.payload.courseId].compactMap(\ .self)
        )
    }

    @discardableResult
    public func recordSessionActivity(
        sessionId: UUID,
        itemId: UUID,
        kind: SessionActivityKind
    ) async throws -> UUID {
        _ = try await payload(StudySessionPayload.self, id: sessionId)
        return try await save(
            payload: SessionActivityPayload(sessionId: sessionId, itemId: itemId, kind: kind),
            parentId: sessionId,
            relationIds: [sessionId, itemId]
        )
    }

    public func removeSessionActivity(id: UUID, at date: Date = .now) async throws {
        var activity = try await payload(SessionActivityPayload.self, id: id)
        activity.payload.removedAt = date
        activity.payload.updatedAt = date
        _ = try await save(
            id: id,
            payload: activity.payload,
            parentId: activity.payload.sessionId,
            relationIds: [activity.payload.sessionId, activity.payload.itemId]
        )
    }

    @discardableResult
    public func respondToRecommendation(
        _ recommendation: LocalStudyRecommendation,
        action: RecommendationAction,
        snoozedUntil: Date? = nil,
        at date: Date = .now
    ) async throws -> UUID {
        let existing = try await list(StudyRecommendationPayload.self).first { value in
            value.payload.topicId == recommendation.topicId
                && value.payload.kind == recommendation.kind
                && (recommendation.targetId.map(value.payload.targetEntityIds.contains)
                    ?? value.payload.targetEntityIds.isEmpty)
        }
        let recommendationId = existing?.id ?? UUID()
        let responseId = UUID()
        let response = RecommendationResponsePayload(
            recommendationId: recommendationId,
            action: action,
            snoozedUntil: snoozedUntil,
            recommendationTitle: recommendation.title,
            recommendationKind: recommendation.kind,
            topicId: recommendation.topicId,
            targetEntityIds: [recommendation.targetId].compactMap(\ .self),
            now: date
        )
        var writes: [LocalEntityWrite] = []
        if existing == nil {
            let payload = StudyRecommendationPayload(
                topicId: recommendation.topicId,
                kind: recommendation.kind,
                title: recommendation.title,
                explanation: recommendation.explanation,
                score: recommendation.score,
                targetEntityIds: [recommendation.targetId].compactMap(\ .self),
                now: date
            )
            writes.append(try localWrite(
                id: recommendationId,
                payload: payload,
                parentId: recommendation.topicId,
                relationIds: [recommendation.topicId, recommendation.targetId].compactMap(\ .self)
            ))
        }
        writes.append(try localWrite(
            id: responseId,
            payload: response,
            parentId: recommendationId,
            relationIds: [recommendationId, recommendation.topicId]
        ))
        try await database.saveLocalBatch(writes)
        return responseId
    }

    public func acceptLearningArtifact(
        id artifactId: UUID,
        at date: Date = .now
    ) async throws -> AcceptedLearningRecords {
        let stored = try await database.entity(id: artifactId)
        guard let stored,
              var artifact = try? CanonicalJSON.decode(LearningGenerationArtifact.self, from: stored.content)
        else { throw StoreError.entityTypeMismatch }
        if artifact.reviewState == .accepted { return AcceptedLearningRecords() }
        let response = try validatedLearningResponse(for: artifact)
        artifact.reviewState = .accepted
        artifact.reviewedAt = date
        var writes: [LocalEntityWrite] = []
        var result = AcceptedLearningRecords()

        switch artifact.jobType {
        case .flashcardDrafts:
            for item in response.items {
                let answer = item.answer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !answer.isEmpty else { continue }
                let cardId = UUID()
                let revisionId = UUID()
                var revision = FlashcardRevisionPayload(
                    cardId: cardId,
                    revisionNumber: 1,
                    prompt: item.title,
                    answer: answer,
                    evidenceIds: item.citedSourceIds,
                    provenance: .reviewedAI,
                    now: date
                )
                revision.generatorArtifactId = artifactId
                let card = FlashcardPayload(
                    topicId: artifact.topicId,
                    currentRevisionId: revisionId,
                    kind: .basic,
                    now: date
                )
                writes.append(try localWrite(
                    id: revisionId,
                    payload: revision,
                    parentId: cardId,
                    relationIds: [cardId, artifact.topicId, artifactId] + item.citedSourceIds
                ))
                writes.append(try localWrite(
                    id: cardId,
                    payload: card,
                    parentId: artifact.topicId,
                    relationIds: [artifact.topicId, revisionId, artifactId]
                ))
                result.flashcards += 1
            }

        case .testGeneration:
            let usableItems = response.items.filter {
                $0.answer?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            }
            if !usableItems.isEmpty {
                let objectiveTitles = (
                    (artifact.testPlan?.objectiveTitles ?? []) + usableItems.flatMap(\.objectiveTitles)
                ).reduce(into: [String]()) { result, rawTitle in
                    let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty,
                          !result.contains(where: { $0.localizedCaseInsensitiveCompare(title) == .orderedSame })
                    else { return }
                    result.append(title)
                }
                let titles = objectiveTitles.isEmpty ? ["Topic coverage"] : objectiveTitles
                let objectives = titles.map {
                    TestObjective(
                        title: $0,
                        dimensions: artifact.testPlan?.coverageDimensions.isEmpty == false
                            ? artifact.testPlan?.coverageDimensions ?? TestCoverageDimension.allCases
                            : TestCoverageDimension.allCases
                    )
                }
                let objectiveByTitle = Dictionary(uniqueKeysWithValues: zip(
                    titles.map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) },
                    objectives.map(\.id)
                ))
                let sources = try await list(SourcePayload.self).filter {
                    $0.payload.primaryTopicId == artifact.topicId || $0.payload.relatedTopicIds.contains(artifact.topicId)
                }
                let notes = try await list(NotePayload.self).filter { $0.payload.courseId == artifact.topicId }
                let concepts = try await list(ConceptPayload.self).filter { $0.payload.topicIds.contains(artifact.topicId) }
                let scopeId = UUID()
                let blueprintId = UUID()
                let testId = UUID()
                let questionIds = usableItems.map { _ in UUID() }
                let scope = TopicScopeSnapshotPayload(
                    topicId: artifact.topicId,
                    includeConnectedKnowledge: artifact.includeConnectedKnowledge,
                    sourceVersionIds: sources.compactMap(\.payload.currentVersionId),
                    noteIds: notes.map(\.id),
                    conceptIds: concepts.map(\.id),
                    evidenceIds: Array(Set(usableItems.flatMap(\.citedSourceIds))),
                    now: date
                )
                var blueprint = TestBlueprintPayload(
                    topicId: artifact.topicId,
                    scopeSnapshotId: scopeId,
                    mode: artifact.testPlan?.mode ?? .comprehensive,
                    objectives: objectives,
                    requestedQuestionCount: artifact.testPlan?.questionCount ?? usableItems.count,
                    timeLimitMinutes: artifact.testPlan?.timeLimitMinutes,
                    provenance: .reviewedAI,
                    now: date
                )
                let coveredTitles = Set(usableItems.flatMap(\.objectiveTitles).map {
                    $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                })
                blueprint.uncoveredObjectives = objectives.compactMap {
                    let key = $0.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    return coveredTitles.contains(key) || objectiveTitles.isEmpty ? nil : $0.id
                }
                var coverageNotes = response.coverageGaps
                if let requested = artifact.testPlan?.questionCount, usableItems.count < requested {
                    coverageNotes.append("Generated \(usableItems.count) of \(requested) requested questions.")
                }
                blueprint.coverageNotes = Array(Set(coverageNotes)).sorted()
                var test = PracticeTestPayload(
                    topicId: artifact.topicId,
                    title: response.summary,
                    blueprintId: blueprintId,
                    scopeSnapshotId: scopeId,
                    provenance: .reviewedAI,
                    now: date
                )
                test.generatorArtifactId = artifactId
                test.questionIds = questionIds
                test.state = .ready
                writes.append(try localWrite(id: scopeId, payload: scope, parentId: artifact.topicId, relationIds: [artifact.topicId, artifactId] + scope.sourceVersionIds))
                writes.append(try localWrite(id: blueprintId, payload: blueprint, parentId: artifact.topicId, relationIds: [artifact.topicId, artifactId, scopeId]))
                writes.append(try localWrite(id: testId, payload: test, parentId: artifact.topicId, relationIds: [artifact.topicId, artifactId, scopeId, blueprintId] + questionIds))
                for (index, item) in usableItems.enumerated() {
                    let mappedObjectives = item.objectiveTitles.compactMap {
                        objectiveByTitle[$0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)]
                    }
                    let question = TestQuestionPayload(
                        testId: testId,
                        objectiveIds: mappedObjectives.isEmpty ? objectives.map(\.id) : mappedObjectives,
                        kind: TestQuestionKind(rawValue: item.kind.uppercased()) ?? .explanation,
                        prompt: item.title,
                        correctAnswer: item.answer ?? "",
                        rubric: item.body,
                        evidenceIds: item.citedSourceIds,
                        order: index,
                        now: date
                    )
                    writes.append(try localWrite(
                        id: questionIds[index],
                        payload: question,
                        parentId: testId,
                        relationIds: [testId, artifact.topicId, artifactId] + question.objectiveIds + question.evidenceIds
                    ))
                }
                result.tests = 1
            }

        case .conceptSuggestions:
            let knownIds = Set(artifact.knownConceptIds ?? [])
            let existingConcepts = try await list(ConceptPayload.self).filter {
                $0.payload.state == .active
                    && (knownIds.contains($0.id) || $0.payload.topicIds.contains(artifact.topicId))
            }
            var conceptsById = Dictionary(uniqueKeysWithValues: existingConcepts.map { ($0.id, $0.payload) })
            var idsByName: [String: Set<UUID>] = [:]
            func conceptKey(_ value: String) -> String {
                value.trimmingCharacters(in: .whitespacesAndNewlines)
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            }
            func indexConcept(id: UUID, payload: ConceptPayload) {
                for name in [payload.name] + payload.aliases {
                    let key = conceptKey(name)
                    guard !key.isEmpty else { continue }
                    idsByName[key, default: []].insert(id)
                }
            }
            existingConcepts.forEach { indexConcept(id: $0.id, payload: $0.payload) }

            for item in response.items {
                let key = conceptKey(item.title)
                if idsByName[key]?.count == 1 { continue }
                guard idsByName[key] == nil else { throw StoreError.invalidDraftReview }
                let conceptId = UUID()
                let concept = ConceptPayload(
                    name: item.title,
                    conceptDescription: item.body,
                    topicIds: [artifact.topicId],
                    now: date
                )
                conceptsById[conceptId] = concept
                indexConcept(id: conceptId, payload: concept)
                writes.append(try localWrite(
                    id: conceptId,
                    payload: concept,
                    parentId: artifact.topicId,
                    relationIds: [artifact.topicId, artifactId] + item.citedSourceIds
                ))
                result.concepts += 1
            }

            func resolvedConceptId(id: UUID?, name: String) throws -> UUID {
                if let id {
                    guard conceptsById[id] != nil, knownIds.contains(id) else {
                        throw StoreError.invalidDraftReview
                    }
                    return id
                }
                let matches = idsByName[conceptKey(name)] ?? []
                guard matches.count == 1, let match = matches.first else {
                    throw StoreError.invalidDraftReview
                }
                return match
            }

            let evidenceIdSet = Set(try await list(EvidencePayload.self).map(\.id))
            let existingLinkKeys = Set(try await list(ConceptLinkPayload.self).map {
                "\($0.payload.sourceConceptId.uuidString)|\($0.payload.targetConceptId.uuidString)|\($0.payload.relation.rawValue)"
            })
            var acceptedLinkKeys = existingLinkKeys
            for draft in response.resolvedConceptLinks {
                let sourceId = try resolvedConceptId(
                    id: draft.sourceConceptId,
                    name: draft.sourceConceptName
                )
                let targetId = try resolvedConceptId(
                    id: draft.targetConceptId,
                    name: draft.targetConceptName
                )
                guard sourceId != targetId else { throw StoreError.invalidDraftReview }
                let key = "\(sourceId.uuidString)|\(targetId.uuidString)|\(draft.relation.rawValue)"
                guard !acceptedLinkKeys.contains(key) else { continue }
                acceptedLinkKeys.insert(key)
                let evidenceIds = Array(Set(draft.citedSourceIds.filter(evidenceIdSet.contains)))
                let link = ConceptLinkPayload(
                    sourceConceptId: sourceId,
                    targetConceptId: targetId,
                    relation: draft.relation,
                    provenance: .reviewedAI,
                    rationale: draft.rationale,
                    evidenceIds: evidenceIds,
                    generatorArtifactId: artifactId,
                    now: date
                )
                writes.append(try localWrite(
                    id: UUID(),
                    payload: link,
                    parentId: sourceId,
                    relationIds: [sourceId, targetId, artifactId] + evidenceIds
                ))
                result.conceptLinks += 1
            }

        default:
            break
        }

        writes.append(try localWrite(
            id: artifactId,
            payload: artifact,
            parentId: artifact.topicId,
            relationIds: [artifact.topicId] + artifact.sourceIds
        ))
        try await database.saveLocalBatch(writes)
        return result
    }

    /// Persists a reviewed working copy inside the encrypted artifact. The provider response
    /// remains immutable in `response`; omission from `editedResponse.items` means excluded.
    /// Stable item IDs allow excluded items to be restored from the original after relaunch.
    public func saveLearningArtifactDraftReview(
        id artifactId: UUID,
        summary: String,
        selectedItems: [LearningDraftItem],
        selectedConceptLinks: [ConceptLinkDraft]? = nil,
        at date: Date = .now
    ) async throws {
        var artifact = try await payload(LearningGenerationArtifact.self, id: artifactId)
        guard artifact.payload.reviewState != .accepted else {
            throw StoreError.artifactAlreadyAccepted
        }
        var candidate = artifact.payload.response
        candidate.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.items = selectedItems
        if let selectedConceptLinks { candidate.conceptLinks = selectedConceptLinks }
        artifact.payload.editedResponse = candidate
        artifact.payload.reviewState = .edited
        artifact.payload.reviewedAt = date
        _ = try validatedLearningResponse(for: artifact.payload)
        _ = try await save(
            id: artifactId,
            payload: artifact.payload,
            parentId: artifact.payload.topicId,
            relationIds: [artifact.payload.topicId] + artifact.payload.sourceIds
        )
    }

    public func saveFreeResponseFeedbackDraftReview(
        id artifactId: UUID,
        response: FreeResponseFeedbackResponse,
        at date: Date = .now
    ) async throws {
        var artifact = try await payload(FreeResponseFeedbackArtifact.self, id: artifactId)
        guard artifact.payload.reviewState != .accepted else {
            throw StoreError.artifactAlreadyAccepted
        }
        var candidate = response
        candidate.feedback = candidate.feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.uncertainty = candidate.uncertainty.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.strengths = candidate.strengths.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        candidate.improvements = candidate.improvements.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        try validateFreeResponseFeedback(candidate, artifact: artifact.payload)
        artifact.payload.editedResponse = candidate
        artifact.payload.reviewState = .edited
        artifact.payload.reviewedAt = date
        _ = try await save(
            id: artifactId,
            payload: artifact.payload,
            parentId: artifact.payload.attemptId,
            relationIds: [
                artifact.payload.attemptId,
                artifact.payload.responseId,
                artifact.payload.questionId,
                artifact.payload.topicId,
            ] + artifact.payload.sourceIds
        )
    }

    public func reviewFreeResponseFeedbackArtifact(
        id artifactId: UUID,
        state: AIArtifactReviewState,
        at date: Date = .now
    ) async throws {
        var artifact = try await payload(FreeResponseFeedbackArtifact.self, id: artifactId)
        if artifact.payload.reviewState == .accepted {
            if state == .accepted { return }
            throw StoreError.artifactAlreadyAccepted
        }
        guard state != .edited else { throw StoreError.invalidFeedbackReview }
        var writes: [LocalEntityWrite] = []
        if state == .accepted {
            let reviewed = artifact.payload.editedResponse ?? artifact.payload.response
            try validateFreeResponseFeedback(reviewed, artifact: artifact.payload)
            var testResponse = try await payload(TestResponsePayload.self, id: artifact.payload.responseId)
            guard testResponse.payload.attemptId == artifact.payload.attemptId,
                  testResponse.payload.questionId == artifact.payload.questionId
            else { throw StoreError.invalidFeedbackReview }
            testResponse.payload.feedback = reviewed.feedback
            testResponse.payload.score = reviewed.proposedScore
            testResponse.payload.feedbackStrengths = reviewed.strengths
            testResponse.payload.feedbackImprovements = reviewed.improvements
            testResponse.payload.feedbackUncertainty = reviewed.uncertainty
            testResponse.payload.feedbackCitedSourceIds = reviewed.citedSourceIds
            testResponse.payload.feedbackArtifactId = artifactId
            testResponse.payload.feedbackAcceptedAt = date
            testResponse.payload.schemaVersion = "test-response/v2"
            testResponse.payload.updatedAt = date
            writes.append(try localWrite(
                id: testResponse.id,
                payload: testResponse.payload,
                parentId: artifact.payload.attemptId,
                relationIds: [
                    artifact.payload.attemptId,
                    artifact.payload.questionId,
                    artifactId,
                ] + reviewed.citedSourceIds
            ))
        }
        artifact.payload.reviewState = state
        artifact.payload.reviewedAt = date
        writes.append(try localWrite(
            id: artifactId,
            payload: artifact.payload,
            parentId: artifact.payload.attemptId,
            relationIds: [
                artifact.payload.attemptId,
                artifact.payload.responseId,
                artifact.payload.questionId,
                artifact.payload.topicId,
            ] + artifact.payload.sourceIds
        ))
        try await database.saveLocalBatch(writes)
    }

    public func setTestResponseScoreOverride(
        id responseId: UUID,
        score: Double?,
        reason: String?,
        at date: Date = .now
    ) async throws {
        var response = try await payload(TestResponsePayload.self, id: responseId)
        let cleanReason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        if score != nil, cleanReason?.isEmpty != false {
            throw LocalDatabaseError.queryFailed("a score override needs a reason")
        }
        response.payload.scoreOverride = score.map { min(max($0, 0), 1) }
        response.payload.scoreOverrideReason = score == nil ? nil : cleanReason
        response.payload.schemaVersion = "test-response/v2"
        response.payload.updatedAt = date
        _ = try await save(
            id: responseId,
            payload: response.payload,
            parentId: response.payload.attemptId,
            relationIds: [
                response.payload.attemptId,
                response.payload.questionId,
                response.payload.feedbackArtifactId,
            ].compactMap(\ .self) + (response.payload.feedbackCitedSourceIds ?? [])
        )
    }

    @discardableResult
    public func createAutomationGrant(
        topicIds: [UUID],
        jobTypes: [AutomationJobKind],
        minimumIntervalHours: Int,
        expiresAt: Date,
        spendingLimitMinorUnits: Int,
        currencyCode: String = "USD",
        at date: Date = .now
    ) async throws -> UUID {
        let topics = Array(Set(topicIds))
        let jobs = Array(Set(jobTypes))
        guard !topics.isEmpty, !jobs.isEmpty, expiresAt > date,
              spendingLimitMinorUnits > 0, currencyCode == "USD",
              jobs.allSatisfy({ $0.learningJobType != nil })
        else { throw StoreError.invalidAutomationGrant }
        for topicId in topics { _ = try await topic(id: topicId) }
        return try await save(
            payload: AutomationGrantPayload(
                topicIds: topics,
                jobTypes: jobs,
                minimumIntervalHours: minimumIntervalHours,
                expiresAt: expiresAt,
                spendingLimitMinorUnits: spendingLimitMinorUnits,
                currencyCode: currencyCode,
                now: date
            ),
            relationIds: topics
        )
    }

    public func updateAutomationGrant(
        id: UUID,
        topicIds: [UUID],
        jobTypes: [AutomationJobKind],
        minimumIntervalHours: Int,
        expiresAt: Date,
        spendingLimitMinorUnits: Int,
        at date: Date = .now
    ) async throws {
        var grant = try await payload(AutomationGrantPayload.self, id: id)
        let topics = Array(Set(topicIds))
        let jobs = Array(Set(jobTypes))
        guard grant.payload.revokedAt == nil, !topics.isEmpty, !jobs.isEmpty,
              expiresAt > date, spendingLimitMinorUnits > 0,
              jobs.allSatisfy({ $0.learningJobType != nil })
        else { throw StoreError.invalidAutomationGrant }
        for topicId in topics { _ = try await topic(id: topicId) }
        grant.payload.schemaVersion = "automation-grant/v2"
        grant.payload.topicIds = topics
        grant.payload.jobTypes = jobs
        grant.payload.minimumIntervalHours = max(minimumIntervalHours, 1)
        grant.payload.expiresAt = expiresAt
        grant.payload.spendingLimitMinorUnits = spendingLimitMinorUnits
        grant.payload.currencyCode = "USD"
        grant.payload.updatedAt = date
        _ = try await save(id: id, payload: grant.payload, relationIds: topics)
    }

    public func setAutomationGrantPaused(
        id: UUID,
        paused: Bool,
        at date: Date = .now
    ) async throws -> [UUID] {
        var grant = try await payload(AutomationGrantPayload.self, id: id)
        guard grant.payload.revokedAt == nil else { throw StoreError.invalidAutomationGrant }
        grant.payload.schemaVersion = "automation-grant/v2"
        grant.payload.pausedAt = paused ? (grant.payload.pausedAt ?? date) : nil
        grant.payload.updatedAt = date
        _ = try await save(id: id, payload: grant.payload, relationIds: grant.payload.topicIds)
        return grant.payload.queuedJobIds ?? []
    }

    public func revokeAutomationGrant(id: UUID, at date: Date = .now) async throws -> [UUID] {
        var grant = try await payload(AutomationGrantPayload.self, id: id)
        grant.payload.schemaVersion = "automation-grant/v2"
        grant.payload.revokedAt = grant.payload.revokedAt ?? date
        grant.payload.pausedAt = grant.payload.pausedAt ?? date
        grant.payload.updatedAt = date
        _ = try await save(id: id, payload: grant.payload, relationIds: grant.payload.topicIds)
        return grant.payload.queuedJobIds ?? []
    }

    public func recordAutomationQueue(
        grantId: UUID,
        scopeKey: String,
        fingerprint: String,
        jobId: UUID,
        estimatedSpentMinorUnits: Int,
        at date: Date = .now
    ) async throws {
        var grant = try await payload(AutomationGrantPayload.self, id: grantId)
        guard grant.payload.isActive(at: date), fingerprint.count == 64,
              !scopeKey.isEmpty, estimatedSpentMinorUnits < grant.payload.spendingLimitMinorUnits
        else { throw StoreError.invalidAutomationGrant }
        grant.payload.schemaVersion = "automation-grant/v2"
        var queuedAt = grant.payload.lastQueuedAtByScope ?? [:]
        var fingerprints = grant.payload.lastInputFingerprintByScope ?? [:]
        var jobs = grant.payload.queuedJobIds ?? []
        queuedAt[scopeKey] = date
        fingerprints[scopeKey] = fingerprint
        if !jobs.contains(jobId) { jobs.append(jobId) }
        grant.payload.lastQueuedAtByScope = queuedAt
        grant.payload.lastInputFingerprintByScope = fingerprints
        grant.payload.queuedJobIds = Array(jobs.suffix(100))
        grant.payload.estimatedSpentMinorUnits = max(estimatedSpentMinorUnits, 0)
        grant.payload.updatedAt = date
        _ = try await save(id: grantId, payload: grant.payload, relationIds: grant.payload.topicIds)
    }

    private func validateFreeResponseFeedback(
        _ response: FreeResponseFeedbackResponse,
        artifact: FreeResponseFeedbackArtifact
    ) throws {
        let allowed = Set(artifact.sourceIds)
        guard !response.feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !response.uncertainty.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              response.proposedScore >= 0,
              response.proposedScore <= 1,
              !response.citedSourceIds.isEmpty,
              Set(response.citedSourceIds).isSubset(of: allowed)
        else { throw StoreError.invalidFeedbackReview }
    }

    private func validatedLearningResponse(
        for artifact: LearningGenerationArtifact
    ) throws -> LearningGenerationResponse {
        let response = artifact.editedResponse ?? artifact.response
        let originalIds = Set(artifact.response.items.map(\.id))
        let selectedIds = response.items.map(\.id)
        let originalLinkIds = Set(artifact.response.resolvedConceptLinks.map(\.id))
        let selectedLinkIds = response.resolvedConceptLinks.map(\.id)
        let allowedSourceIds = Set(artifact.sourceIds)
        let allowedConceptIds = Set(artifact.knownConceptIds ?? [])
        guard Set(selectedIds).count == selectedIds.count,
              selectedIds.allSatisfy(originalIds.contains),
              Set(selectedLinkIds).count == selectedLinkIds.count,
              selectedLinkIds.allSatisfy(originalLinkIds.contains),
              artifact.jobType == .conceptSuggestions || response.resolvedConceptLinks.isEmpty,
              response.items.allSatisfy({ item in
                  let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
                  guard !title.isEmpty, Set(item.citedSourceIds).isSubset(of: allowedSourceIds) else {
                      return false
                  }
                  switch artifact.jobType {
                  case .flashcardDrafts, .testGeneration:
                      return item.answer?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                  case .conceptSuggestions:
                      return true
                  default:
                      return true
                  }
              }),
              response.resolvedConceptLinks.allSatisfy({ link in
                  let sourceName = link.sourceConceptName.trimmingCharacters(in: .whitespacesAndNewlines)
                  let targetName = link.targetConceptName.trimmingCharacters(in: .whitespacesAndNewlines)
                  let rationale = link.rationale.trimmingCharacters(in: .whitespacesAndNewlines)
                  let cited = Set(link.citedSourceIds)
                  let idsAreAllowed = [link.sourceConceptId, link.targetConceptId]
                      .compactMap(\ .self).allSatisfy(allowedConceptIds.contains)
                  return !sourceName.isEmpty
                      && !targetName.isEmpty
                      && !rationale.isEmpty
                      && !cited.isEmpty
                      && cited.isSubset(of: allowedSourceIds)
                      && idsAreAllowed
                      && link.sourceConceptId != link.targetConceptId
                      && (link.sourceConceptId != nil
                          || link.targetConceptId != nil
                          || sourceName.localizedCaseInsensitiveCompare(targetName) != .orderedSame)
              })
        else { throw StoreError.invalidDraftReview }
        return response
    }

    @discardableResult
    public func createFlashcard(
        topicId: UUID,
        deckId: UUID? = nil,
        kind: FlashcardKind = .basic,
        prompt: String,
        answer: String,
        evidenceIds: [UUID] = []
    ) async throws -> UUID {
        _ = try await topic(id: topicId)
        let cardId = UUID()
        let revisionId = UUID()
        let now = Date.now
        let revision = FlashcardRevisionPayload(
            cardId: cardId,
            revisionNumber: 1,
            prompt: prompt,
            answer: answer,
            evidenceIds: evidenceIds,
            now: now
        )
        let card = FlashcardPayload(
            topicId: topicId,
            deckId: deckId,
            currentRevisionId: revisionId,
            kind: kind,
            now: now
        )
        let writes = try [
            localWrite(
                id: revisionId,
                payload: revision,
                parentId: cardId,
                relationIds: [cardId, topicId] + evidenceIds
            ),
            localWrite(
                id: cardId,
                payload: card,
                parentId: deckId ?? topicId,
                relationIds: [topicId, deckId, revisionId].compactMap(\ .self)
            ),
        ]
        try await database.saveLocalBatch(writes)
        return cardId
    }

    /// Editing a card always appends a revision. Existing reviews continue to reference the
    /// exact revision that was shown when the review occurred.
    @discardableResult
    public func reviseFlashcard(
        id cardId: UUID,
        kind: FlashcardKind,
        prompt: String,
        answer: String,
        deckId: UUID?,
        evidenceIds: [UUID],
        at date: Date = .now
    ) async throws -> UUID {
        var card = try await payload(FlashcardPayload.self, id: cardId)
        if let deckId {
            let deck = try await payload(FlashcardDeckPayload.self, id: deckId)
            guard deck.payload.topicId == card.payload.topicId else {
                throw LocalDatabaseError.queryFailed("the deck belongs to a different Topic")
            }
        }
        let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPrompt.isEmpty, !cleanAnswer.isEmpty else {
            throw LocalDatabaseError.queryFailed("a card needs a prompt and answer")
        }
        let revisionNumber = (try await list(FlashcardRevisionPayload.self, parentId: cardId))
            .map(\.payload.revisionNumber).max() ?? 0
        let revisionId = UUID()
        let revision = FlashcardRevisionPayload(
            cardId: cardId,
            revisionNumber: revisionNumber + 1,
            prompt: cleanPrompt,
            answer: cleanAnswer,
            evidenceIds: Array(Set(evidenceIds)),
            now: date
        )
        card.payload.kind = kind
        card.payload.deckId = deckId
        card.payload.currentRevisionId = revisionId
        card.payload.updatedAt = date
        try await database.saveLocalBatch(try [
            localWrite(
                id: revisionId,
                payload: revision,
                parentId: cardId,
                relationIds: [cardId, card.payload.topicId] + revision.evidenceIds
            ),
            localWrite(
                id: cardId,
                payload: card.payload,
                parentId: deckId ?? card.payload.topicId,
                relationIds: [card.payload.topicId, deckId, revisionId].compactMap(\ .self)
            ),
        ])
        return revisionId
    }

    public func setFlashcardLifecycle(
        id: UUID,
        suspended: Bool? = nil,
        archived: Bool? = nil,
        at date: Date = .now
    ) async throws {
        var card = try await payload(FlashcardPayload.self, id: id)
        if let suspended {
            card.payload.suspendedAt = suspended ? (card.payload.suspendedAt ?? date) : nil
        }
        if let archived {
            card.payload.archivedAt = archived ? (card.payload.archivedAt ?? date) : nil
        }
        card.payload.updatedAt = date
        _ = try await save(
            id: id,
            payload: card.payload,
            parentId: card.payload.deckId ?? card.payload.topicId,
            relationIds: [card.payload.topicId, card.payload.deckId, card.payload.currentRevisionId]
                .compactMap(\ .self)
        )
    }

    @discardableResult
    public func reviewFlashcard(
        cardId: UUID,
        rating: FlashcardRating,
        previousState: FlashcardScheduleState,
        responseMilliseconds: Int? = nil,
        at date: Date = .now
    ) async throws -> UUID {
        let card = try await payload(FlashcardPayload.self, id: cardId)
        let result = FlashcardScheduler.next(after: previousState, rating: rating, reviewedAt: date)
        return try await save(
            payload: FlashcardReviewPayload(
                cardId: cardId,
                cardRevisionId: card.payload.currentRevisionId,
                rating: rating,
                previousState: previousState,
                resultingState: result,
                responseMilliseconds: responseMilliseconds,
                now: date
            ),
            parentId: cardId,
            relationIds: [cardId, card.payload.currentRevisionId]
        )
    }

    @discardableResult
    public func beginTestAttempt(
        testId: UUID,
        retakeOfAttemptId: UUID? = nil,
        missedObjectivesOnly: Bool = false,
        at date: Date = .now
    ) async throws -> UUID {
        let test = try await payload(PracticeTestPayload.self, id: testId)
        var questions = try await list(TestQuestionPayload.self, parentId: testId)
            .sorted { $0.payload.order < $1.payload.order }
        if let retakeOfAttemptId {
            let prior = try await payload(TestAttemptPayload.self, id: retakeOfAttemptId)
            guard prior.payload.testId == testId else { throw StoreError.entityTypeMismatch }
            if missedObjectivesOnly {
                let responses = try await list(TestResponsePayload.self, parentId: retakeOfAttemptId)
                let missedQuestionIds = Set(responses.compactMap { response in
                    response.payload.isCorrect == false || response.payload.isSkipped
                        ? response.payload.questionId
                        : nil
                })
                let missedObjectives = Set(prior.payload.frozenQuestions
                    .filter { missedQuestionIds.contains($0.questionId) }
                    .flatMap(\.objectiveIds))
                questions = questions.filter { !missedObjectives.isDisjoint(with: $0.payload.objectiveIds) }
                if questions.isEmpty {
                    throw LocalDatabaseError.queryFailed("the earlier attempt has no missed objectives to retake")
                }
            }
        }
        let frozen = questions.map {
            FrozenQuestionSnapshot(
                questionId: $0.id,
                kind: $0.payload.kind,
                prompt: $0.payload.prompt,
                choices: $0.payload.choices,
                rubric: $0.payload.rubric,
                correctAnswer: $0.payload.correctAnswer,
                objectiveIds: $0.payload.objectiveIds,
                evidenceIds: $0.payload.evidenceIds
            )
        }
        return try await save(
            payload: TestAttemptPayload(
                testId: testId,
                topicId: test.payload.topicId,
                scopeSnapshotId: test.payload.scopeSnapshotId,
                frozenQuestions: frozen,
                retakeOfAttemptId: retakeOfAttemptId,
                now: date
            ),
            parentId: testId,
            relationIds: [testId, test.payload.topicId, test.payload.scopeSnapshotId, retakeOfAttemptId].compactMap(\ .self)
        )
    }

    @discardableResult
    public func createPracticeTest(
        topicId: UUID,
        title: String,
        mode: TestMode = .comprehensive,
        objectives: [TestObjective],
        questions: [ManualTestQuestion],
        includeConnectedKnowledge: Bool = false,
        timeLimitMinutes: Int? = nil,
        at date: Date = .now
    ) async throws -> UUID {
        _ = try await topic(id: topicId)
        guard !objectives.isEmpty, !questions.isEmpty else {
            throw LocalDatabaseError.queryFailed("a practice test needs objectives and questions")
        }
        let sources = try await list(SourcePayload.self).filter {
            $0.payload.primaryTopicId == topicId || $0.payload.relatedTopicIds.contains(topicId)
        }
        let notes = try await list(NotePayload.self).filter { $0.payload.courseId == topicId }
        let concepts = try await list(ConceptPayload.self).filter { $0.payload.topicIds.contains(topicId) }
        let evidence = try await list(EvidencePayload.self).filter { value in
            sources.contains { $0.id == value.payload.sourceId }
        }
        let scopeId = UUID()
        let blueprintId = UUID()
        let testId = UUID()
        let questionIds = questions.map { _ in UUID() }
        let scope = TopicScopeSnapshotPayload(
            topicId: topicId,
            includeConnectedKnowledge: includeConnectedKnowledge,
            sourceVersionIds: sources.compactMap(\.payload.currentVersionId),
            noteIds: notes.map(\.id),
            conceptIds: concepts.map(\.id),
            evidenceIds: evidence.map(\.id),
            now: date
        )
        var blueprint = TestBlueprintPayload(
            topicId: topicId,
            scopeSnapshotId: scopeId,
            mode: mode,
            objectives: objectives,
            requestedQuestionCount: questions.count,
            timeLimitMinutes: timeLimitMinutes,
            now: date
        )
        let covered = Set(questions.flatMap(\.objectiveIds))
        blueprint.uncoveredObjectives = objectives.map(\.id).filter { !covered.contains($0) }
        if !blueprint.uncoveredObjectives.isEmpty {
            blueprint.coverageNotes = [
                "\(blueprint.uncoveredObjectives.count) objective\(blueprint.uncoveredObjectives.count == 1 ? "" : "s") have no question."
            ]
        }
        var test = PracticeTestPayload(
            topicId: topicId,
            title: title,
            blueprintId: blueprintId,
            scopeSnapshotId: scopeId,
            now: date
        )
        test.questionIds = questionIds
        test.state = .ready
        var writes = try [
            localWrite(id: scopeId, payload: scope, parentId: topicId, relationIds: [topicId] + scope.sourceVersionIds),
            localWrite(id: blueprintId, payload: blueprint, parentId: topicId, relationIds: [topicId, scopeId]),
            localWrite(id: testId, payload: test, parentId: topicId, relationIds: [topicId, scopeId, blueprintId] + questionIds),
        ]
        for (index, input) in questions.enumerated() {
            let question = TestQuestionPayload(
                testId: testId,
                objectiveIds: input.objectiveIds,
                kind: input.kind,
                prompt: input.prompt,
                correctAnswer: input.correctAnswer,
                rubric: input.rubric,
                evidenceIds: input.evidenceIds,
                order: index,
                now: date
            )
            writes.append(try localWrite(
                id: questionIds[index],
                payload: question,
                parentId: testId,
                relationIds: [testId, topicId] + input.objectiveIds + input.evidenceIds
            ))
        }
        try await database.saveLocalBatch(writes)
        return testId
    }

    public func updatePracticeTest(
        id: UUID,
        title: String,
        state: PracticeTestState,
        at date: Date = .now
    ) async throws {
        var test = try await payload(PracticeTestPayload.self, id: id)
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else {
            throw LocalDatabaseError.queryFailed("a test needs a title")
        }
        test.payload.title = cleanTitle
        test.payload.state = state
        test.payload.updatedAt = date
        _ = try await save(
            id: id,
            payload: test.payload,
            parentId: test.payload.topicId,
            relationIds: [
                test.payload.topicId,
                test.payload.blueprintId,
                test.payload.scopeSnapshotId,
            ] + test.payload.questionIds
        )
    }

    @discardableResult
    public func createSource(
        type: ResourceKind,
        title: String,
        originalAssetId: UUID? = nil,
        canonicalURL: URL? = nil,
        capturedURL: URL? = nil,
        identifiers: [String] = [],
        primaryTopicId: UUID? = nil,
        sessionId: UUID? = nil,
        at date: Date = .now
    ) async throws -> UUID {
        if let primaryTopicId { _ = try await topic(id: primaryTopicId) }
        if let originalAssetId { _ = try await payload(AssetPayload.self, id: originalAssetId) }
        let sourceId = UUID()
        let versionId = UUID()
        var source = SourcePayload(
            sourceType: type,
            title: title,
            originalAssetId: originalAssetId,
            primaryTopicId: primaryTopicId,
            now: date
        )
        source.canonicalURL = canonicalURL
        source.identifiers = Array(Set(identifiers.filter { !$0.isEmpty })).sorted()
        source.currentVersionId = versionId
        var version = SourceVersionPayload(
            sourceId: sourceId,
            versionNumber: 1,
            originalAssetId: originalAssetId,
            now: date
        )
        version.capturedURL = capturedURL
        var writes = try [
            localWrite(
                id: sourceId,
                payload: source,
                parentId: primaryTopicId,
                relationIds: [primaryTopicId, originalAssetId, versionId].compactMap(\ .self)
            ),
            localWrite(
                id: versionId,
                payload: version,
                parentId: sourceId,
                relationIds: [sourceId, originalAssetId].compactMap(\ .self)
            ),
        ]
        if let sessionId {
            let relationId = UUID()
            let relation = RelationPayload(kind: .sessionResource, leftId: sessionId, rightId: sourceId, now: date)
            writes.append(try localWrite(
                id: relationId,
                payload: relation,
                parentId: sessionId,
                relationIds: [sessionId, sourceId]
            ).overridingEntityType(.sessionResource))
            writes.append(try localWrite(
                id: UUID(),
                payload: SessionActivityPayload(sessionId: sessionId, itemId: sourceId, kind: .sourceAdded, now: date),
                parentId: sessionId,
                relationIds: [sessionId, sourceId]
            ))
        }
        try await database.saveLocalBatch(writes)
        return sourceId
    }

    @discardableResult
    public func refreshSource(
        id sourceId: UUID,
        originalAssetId: UUID?,
        capturedURL: URL? = nil,
        at date: Date = .now
    ) async throws -> UUID {
        var source = try await payload(SourcePayload.self, id: sourceId)
        if let originalAssetId { _ = try await payload(AssetPayload.self, id: originalAssetId) }
        let versions = try await list(SourceVersionPayload.self, parentId: sourceId)
        let versionId = UUID()
        var version = SourceVersionPayload(
            sourceId: sourceId,
            versionNumber: (versions.map(\.payload.versionNumber).max() ?? 0) + 1,
            originalAssetId: originalAssetId,
            now: date
        )
        version.capturedURL = capturedURL
        version.refreshedFromVersionId = source.payload.currentVersionId
        source.payload.currentVersionId = versionId
        source.payload.originalAssetId = originalAssetId
        source.payload.locallyAvailable = originalAssetId != nil
        source.payload.updatedAt = date
        try await database.saveLocalBatch(try [
            localWrite(
                id: versionId,
                payload: version,
                parentId: sourceId,
                relationIds: [sourceId, originalAssetId, version.refreshedFromVersionId].compactMap(\ .self)
            ),
            localWrite(
                id: sourceId,
                payload: source.payload,
                parentId: source.payload.primaryTopicId,
                relationIds: [source.payload.primaryTopicId, originalAssetId, versionId].compactMap(\ .self)
            ),
        ])
        return versionId
    }

    public func updateSource(
        id: UUID,
        title: String,
        primaryTopicId: UUID?,
        relatedTopicIds: [UUID],
        listIds: [UUID],
        archived: Bool,
        at date: Date = .now
    ) async throws {
        let topicIds = Array(Set(relatedTopicIds).subtracting([primaryTopicId].compactMap(\ .self)))
        if let primaryTopicId { _ = try await topic(id: primaryTopicId) }
        for topicId in topicIds { _ = try await topic(id: topicId) }
        for listId in Set(listIds) { _ = try await payload(CollectionPayload.self, id: listId) }
        var source = try await payload(SourcePayload.self, id: id)
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else {
            throw LocalDatabaseError.queryFailed("a Source needs a title")
        }
        source.payload.title = cleanTitle
        source.payload.primaryTopicId = primaryTopicId
        source.payload.relatedTopicIds = topicIds
        source.payload.listIds = Array(Set(listIds))
        source.payload.archivedAt = archived ? (source.payload.archivedAt ?? date) : nil
        source.payload.updatedAt = date
        _ = try await save(
            id: id,
            payload: source.payload,
            parentId: primaryTopicId,
            relationIds: [
                primaryTopicId,
                source.payload.originalAssetId,
                source.payload.currentVersionId,
            ].compactMap(\ .self) + topicIds + source.payload.listIds
        )
    }

    @discardableResult
    public func createEvidence(
        sourceId: UUID,
        sourceVersionId: UUID,
        kind: EvidenceKind,
        locator: SourceLocator,
        excerpt: String,
        note: String? = nil
    ) async throws -> UUID {
        _ = try await payload(SourcePayload.self, id: sourceId)
        let version = try await payload(SourceVersionPayload.self, id: sourceVersionId)
        guard version.payload.sourceId == sourceId else { throw SourceModelError.sourceVersionMismatch }
        try locator.validate()
        let cleanExcerpt = excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanExcerpt.isEmpty || cleanNote?.isEmpty == false else { throw SourceModelError.emptyEvidence }
        var evidence = EvidencePayload(
            sourceId: sourceId,
            sourceVersionId: sourceVersionId,
            kind: kind,
            locator: locator,
            excerpt: cleanExcerpt
        )
        evidence.note = cleanNote?.isEmpty == true ? nil : cleanNote
        return try await save(
            payload: evidence,
            parentId: sourceId,
            relationIds: [sourceId, sourceVersionId]
        )
    }

    public func createAnnotationEvidence(
        annotation: AnnotationPayload,
        sourceVersionId: UUID
    ) async throws -> (annotationId: UUID, evidenceId: UUID) {
        let source = try await payload(SourcePayload.self, id: annotation.resourceId)
        let version = try await payload(SourceVersionPayload.self, id: sourceVersionId)
        guard version.payload.sourceId == source.id else { throw SourceModelError.sourceVersionMismatch }
        let locator = SourceLocator(
            kind: source.payload.sourceType == .image ? .image : .pdf,
            page: source.payload.sourceType == .image ? nil : annotation.pageNumber,
            rectangles: annotation.rectangles
        )
        try locator.validate()
        let excerpt = [annotation.selectedText, annotation.comment]
            .compactMap(\ .self)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !excerpt.isEmpty else { throw SourceModelError.emptyEvidence }
        let annotationId = UUID()
        let evidenceId = UUID()
        let evidence = EvidencePayload(
            sourceId: source.id,
            sourceVersionId: sourceVersionId,
            kind: annotation.rectangles.isEmpty ? .annotation : .excerpt,
            locator: locator,
            excerpt: excerpt
        )
        try await database.saveLocalBatch(try [
            localWrite(
                id: annotationId,
                payload: annotation,
                parentId: source.id,
                relationIds: [source.id, annotation.studySessionId, annotation.noteId].compactMap(\ .self)
            ),
            localWrite(
                id: evidenceId,
                payload: evidence,
                parentId: source.id,
                relationIds: [source.id, sourceVersionId, annotationId]
            ),
        ])
        return (annotationId, evidenceId)
    }

    /// Returns every owner correction for one immutable transcript, including superseded and
    /// retracted history. Generated transcript chunks are never rewritten.
    public func transcriptCorrections(
        transcriptionArtifactId: UUID
    ) async throws -> [IdentifiedPayload<TranscriptCorrectionPayload>] {
        let manifest = try await payload(MediaTranscriptionManifest.self, id: transcriptionArtifactId)
        return try await list(TranscriptCorrectionPayload.self, parentId: manifest.payload.sourceId)
            .filter { $0.payload.transcriptionArtifactId == transcriptionArtifactId }
            .sorted {
                if $0.payload.segmentIndex == $1.payload.segmentIndex {
                    return $0.payload.createdAt < $1.payload.createdAt
                }
                return $0.payload.segmentIndex < $1.payload.segmentIndex
            }
    }

    /// Creates a new correction revision and supersedes the prior active correction in the same
    /// local transaction. Concurrent active corrections fail closed when read.
    @discardableResult
    public func createTranscriptCorrection(
        transcriptionArtifactId: UUID,
        segmentIndex: Int,
        correctedText: String,
        reason: String? = nil,
        at date: Date = .now
    ) async throws -> UUID {
        var manifest = try await payload(MediaTranscriptionManifest.self, id: transcriptionArtifactId)
        let segments = try await transcriptProviderSegments(manifest: manifest.payload)
        guard let segment = segments.first(where: { $0.index == segmentIndex }) else {
            throw StoreError.invalidTranscriptCorrection
        }
        let cleanText = correctedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanReason = reason?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard !cleanText.isEmpty else { throw StoreError.invalidTranscriptCorrection }

        var allCorrections = try await transcriptCorrections(
            transcriptionArtifactId: transcriptionArtifactId
        )
        let active = allCorrections.filter {
            $0.payload.segmentIndex == segmentIndex && $0.payload.state == .active
        }
        guard active.count <= 1 else { throw StoreError.transcriptCorrectionConflict }
        let currentText = active.first?.payload.correctedText ?? segment.text
        guard cleanText != currentText else { throw StoreError.invalidTranscriptCorrection }

        let correctionId = UUID()
        let previousId = active.first?.id
        let correction = TranscriptCorrectionPayload(
            sourceId: manifest.payload.sourceId,
            sourceVersionId: manifest.payload.sourceVersionId,
            transcriptionArtifactId: transcriptionArtifactId,
            segment: segment,
            correctedText: cleanText,
            reason: cleanReason,
            supersedesCorrectionId: previousId,
            now: date
        )

        var writes: [LocalEntityWrite] = []
        for index in allCorrections.indices where allCorrections[index].payload.segmentIndex == segmentIndex
            && allCorrections[index].payload.state == .active {
            allCorrections[index].payload.state = .superseded
            allCorrections[index].payload.updatedAt = date
            writes.append(try localWrite(
                id: allCorrections[index].id,
                payload: allCorrections[index].payload,
                parentId: manifest.payload.sourceId,
                relationIds: transcriptCorrectionRelationIds(allCorrections[index].payload)
            ))
        }

        manifest.payload.reviewState = .edited
        manifest.payload.reviewedAt = date
        writes.append(try localWrite(
            id: transcriptionArtifactId,
            payload: manifest.payload,
            parentId: manifest.payload.sourceId,
            relationIds: [
                manifest.payload.sourceId,
                manifest.payload.sourceVersionId,
            ] + manifest.payload.chunkEntityIds
        ))
        writes.append(try localWrite(
            id: correctionId,
            payload: correction,
            parentId: correction.sourceId,
            relationIds: transcriptCorrectionRelationIds(correction)
        ))
        _ = try await database.saveLocalBatch(writes)
        return correctionId
    }

    /// Retraction preserves the correction text and history while removing it from the effective
    /// transcript. It never restores an older superseded correction implicitly.
    public func retractTranscriptCorrection(
        id: UUID,
        at date: Date = .now
    ) async throws {
        var correction = try await payload(TranscriptCorrectionPayload.self, id: id)
        guard correction.payload.state == .active else {
            throw StoreError.invalidTranscriptCorrection
        }
        correction.payload.state = .retracted
        correction.payload.updatedAt = date
        _ = try await save(
            id: id,
            payload: correction.payload,
            parentId: correction.payload.sourceId,
            relationIds: transcriptCorrectionRelationIds(correction.payload)
        )
    }

    /// Resolves independently-created active corrections without deleting either record. Passing
    /// `nil` restores generated text by retracting every active candidate.
    public func resolveTranscriptCorrectionConflict(
        transcriptionArtifactId: UUID,
        segmentIndex: Int,
        keeping correctionId: UUID?,
        at date: Date = .now
    ) async throws {
        let manifest = try await payload(MediaTranscriptionManifest.self, id: transcriptionArtifactId)
        var corrections = try await transcriptCorrections(
            transcriptionArtifactId: transcriptionArtifactId
        )
        let activeIndexes = corrections.indices.filter {
            corrections[$0].payload.segmentIndex == segmentIndex
                && corrections[$0].payload.state == .active
        }
        guard activeIndexes.count > 1 else { throw StoreError.invalidTranscriptCorrection }
        if let correctionId,
           !activeIndexes.contains(where: { corrections[$0].id == correctionId }) {
            throw StoreError.invalidTranscriptCorrection
        }

        let writes = try activeIndexes.map { index in
            corrections[index].payload.state = corrections[index].id == correctionId
                ? .active
                : (correctionId == nil ? .retracted : .superseded)
            corrections[index].payload.updatedAt = date
            return try localWrite(
                id: corrections[index].id,
                payload: corrections[index].payload,
                parentId: manifest.payload.sourceId,
                relationIds: transcriptCorrectionRelationIds(corrections[index].payload)
            )
        }
        _ = try await database.saveLocalBatch(writes)
    }

    public func reviewedTranscriptSegments(
        transcriptionArtifactId: UUID
    ) async throws -> [ReviewedTranscriptSegment] {
        let manifest = try await payload(MediaTranscriptionManifest.self, id: transcriptionArtifactId)
        let segments = try await transcriptProviderSegments(manifest: manifest.payload)
        let corrections = try await transcriptCorrections(
            transcriptionArtifactId: transcriptionArtifactId
        ).filter { $0.payload.state == .active }
        let grouped = Dictionary(grouping: corrections, by: \ .payload.segmentIndex)
        guard grouped.values.allSatisfy({ $0.count == 1 }) else {
            throw StoreError.transcriptCorrectionConflict
        }
        return segments.map { segment in
            let correction = grouped[segment.index]?.first
            return ReviewedTranscriptSegment(
                original: segment,
                text: correction?.payload.correctedText ?? segment.text,
                correctionId: correction?.id
            )
        }
    }

    /// Freezes a contiguous transcript range as Evidence. The excerpt records the reviewed text,
    /// while the locator, provider artifact, segment indexes, and correction IDs retain provenance.
    @discardableResult
    public func createTranscriptEvidence(
        transcriptionArtifactId: UUID,
        segmentIndexes: [Int],
        note: String? = nil,
        at date: Date = .now
    ) async throws -> UUID {
        let manifest = try await payload(MediaTranscriptionManifest.self, id: transcriptionArtifactId)
        guard manifest.payload.reviewState == .accepted || manifest.payload.reviewState == .edited else {
            throw StoreError.transcriptReviewRequired
        }
        let reviewed = try await reviewedTranscriptSegments(
            transcriptionArtifactId: transcriptionArtifactId
        )
        let requested = Set(segmentIndexes)
        guard !requested.isEmpty else { throw SourceModelError.emptyEvidence }
        let positions = reviewed.indices.filter { requested.contains(reviewed[$0].original.index) }
        guard positions.count == requested.count,
              let firstPosition = positions.first,
              let lastPosition = positions.last,
              positions.count == lastPosition - firstPosition + 1
        else { throw SourceModelError.invalidLocator }

        let selected = Array(reviewed[firstPosition...lastPosition])
        let excerpt = selected.map(\ .text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !excerpt.isEmpty else { throw SourceModelError.emptyEvidence }
        let locator = SourceLocator(
            kind: .media,
            startSeconds: selected.first?.original.startSeconds,
            endSeconds: selected.last?.original.endSeconds
        )
        try locator.validate()
        _ = try await payload(SourcePayload.self, id: manifest.payload.sourceId)
        let version = try await payload(
            SourceVersionPayload.self,
            id: manifest.payload.sourceVersionId
        )
        guard version.payload.sourceId == manifest.payload.sourceId else {
            throw SourceModelError.sourceVersionMismatch
        }

        var evidence = EvidencePayload(
            sourceId: manifest.payload.sourceId,
            sourceVersionId: manifest.payload.sourceVersionId,
            kind: .mediaClip,
            locator: locator,
            excerpt: excerpt,
            now: date
        )
        evidence.note = note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        evidence.transcriptionArtifactId = transcriptionArtifactId
        evidence.transcriptSegmentIndexes = selected.map(\ .original.index)
        evidence.transcriptCorrectionIds = selected.compactMap(\ .correctionId)
        return try await save(
            payload: evidence,
            parentId: manifest.payload.sourceId,
            relationIds: [
                manifest.payload.sourceId,
                manifest.payload.sourceVersionId,
                transcriptionArtifactId,
            ] + evidence.resolvedTranscriptCorrectionIds
        )
    }

    private func transcriptProviderSegments(
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
        return chunks.sorted { $0.chunkIndex < $1.chunkIndex }.flatMap(\ .segments)
    }

    private func transcriptCorrectionRelationIds(
        _ correction: TranscriptCorrectionPayload
    ) -> [UUID] {
        [
            correction.sourceId,
            correction.sourceVersionId,
            correction.transcriptionArtifactId,
            correction.supersedesCorrectionId,
        ].compactMap(\ .self)
    }

    @discardableResult
    public func createConcept(
        name: String,
        description: String = "",
        topicIds: [UUID]
    ) async throws -> UUID {
        for topicId in Set(topicIds) { _ = try await topic(id: topicId) }
        return try await save(
            payload: ConceptPayload(name: name, conceptDescription: description, topicIds: Array(Set(topicIds))),
            parentId: topicIds.first,
            relationIds: topicIds
        )
    }

    public func updateConcept(
        id: UUID,
        name: String,
        description: String,
        aliases: [String],
        topicIds: [UUID],
        state: ConceptLifecycleState,
        at date: Date = .now
    ) async throws {
        let uniqueTopicIds = Array(Set(topicIds))
        guard !uniqueTopicIds.isEmpty else {
            throw LocalDatabaseError.queryFailed("a Concept needs at least one Topic")
        }
        for topicId in uniqueTopicIds { _ = try await topic(id: topicId) }
        var concept = try await payload(ConceptPayload.self, id: id)
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            throw LocalDatabaseError.queryFailed("a Concept needs a name")
        }
        concept.payload.name = cleanName
        concept.payload.conceptDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        concept.payload.aliases = Array(Set(aliases.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })).sorted()
        concept.payload.topicIds = uniqueTopicIds
        concept.payload.state = state
        concept.payload.updatedAt = date
        _ = try await save(
            id: id,
            payload: concept.payload,
            parentId: uniqueTopicIds.first,
            relationIds: uniqueTopicIds
        )
    }

    public func knowledgeMap(
        topicId: UUID
    ) async throws -> IdentifiedPayload<KnowledgeMapPayload>? {
        _ = try await topic(id: topicId)
        return try await list(KnowledgeMapPayload.self, parentId: topicId)
            .filter { $0.payload.topicId == topicId }
            .sorted { $0.payload.updatedAt > $1.payload.updatedAt }
            .first
    }

    /// Saves only one node's visual position. Concepts, Evidence, and relationships remain
    /// independent records and are never rewritten by a map gesture.
    public func saveKnowledgeMapPlacement(
        topicId: UUID,
        nodeId: UUID,
        kind: KnowledgeMapNodeKind,
        x: Double,
        y: Double,
        at date: Date = .now
    ) async throws {
        _ = try await topic(id: topicId)
        switch kind {
        case .concept:
            let concept = try await payload(ConceptPayload.self, id: nodeId)
            guard concept.payload.topicIds.contains(topicId) else { throw StoreError.relationshipNotFound }
        case .evidence:
            _ = try await payload(EvidencePayload.self, id: nodeId)
            let conceptIds = Set(try await list(ConceptPayload.self)
                .filter { $0.payload.topicIds.contains(topicId) }
                .map(\.id))
            let isConnected = try await list(ConceptEvidenceRelationPayload.self).contains {
                $0.payload.evidenceId == nodeId && conceptIds.contains($0.payload.conceptId)
            }
            guard isConnected else { throw StoreError.relationshipNotFound }
        }
        let boundedX = min(max(x.isFinite ? x : KnowledgeMapProjectionBuilder.worldWidth / 2, 90),
                           KnowledgeMapProjectionBuilder.worldWidth - 90)
        let boundedY = min(max(y.isFinite ? y : KnowledgeMapProjectionBuilder.worldHeight / 2, 70),
                           KnowledgeMapProjectionBuilder.worldHeight - 70)
        if var map = try await knowledgeMap(topicId: topicId) {
            map.payload.placements.removeAll { $0.nodeId == nodeId }
            map.payload.placements.append(KnowledgeMapNodePlacement(
                nodeId: nodeId,
                kind: kind,
                x: boundedX,
                y: boundedY
            ))
            map.payload.placements.sort { $0.nodeId.uuidString < $1.nodeId.uuidString }
            map.payload.updatedAt = date
            _ = try await save(
                id: map.id,
                payload: map.payload,
                parentId: topicId,
                relationIds: [topicId] + map.payload.placements.map(\.nodeId)
            )
        } else {
            let payload = KnowledgeMapPayload(
                topicId: topicId,
                placements: [KnowledgeMapNodePlacement(
                    nodeId: nodeId,
                    kind: kind,
                    x: boundedX,
                    y: boundedY
                )],
                now: date
            )
            _ = try await save(
                payload: payload,
                parentId: topicId,
                relationIds: [topicId, nodeId]
            )
        }
    }

    public func resetKnowledgeMapLayout(topicId: UUID, at date: Date = .now) async throws {
        guard var map = try await knowledgeMap(topicId: topicId) else { return }
        map.payload.placements = []
        map.payload.updatedAt = date
        _ = try await save(
            id: map.id,
            payload: map.payload,
            parentId: topicId,
            relationIds: [topicId]
        )
    }

    @discardableResult
    public func linkConcept(
        _ conceptId: UUID,
        toEvidence evidenceId: UUID,
        relation: ConceptEvidenceKind
    ) async throws -> UUID {
        _ = try await payload(ConceptPayload.self, id: conceptId)
        _ = try await payload(EvidencePayload.self, id: evidenceId)
        if let existing = try await list(ConceptEvidenceRelationPayload.self).first(where: {
            $0.payload.conceptId == conceptId
                && $0.payload.evidenceId == evidenceId
                && $0.payload.relation == relation
        }) {
            return existing.id
        }
        return try await save(
            payload: ConceptEvidenceRelationPayload(
                conceptId: conceptId,
                evidenceId: evidenceId,
                relation: relation
            ),
            parentId: conceptId,
            relationIds: [conceptId, evidenceId]
        )
    }

    public func updateConceptEvidenceRelation(
        id: UUID,
        relation: ConceptEvidenceKind,
        at date: Date = .now
    ) async throws {
        var value = try await payload(ConceptEvidenceRelationPayload.self, id: id)
        let duplicate = try await list(ConceptEvidenceRelationPayload.self).contains {
            $0.id != id
                && $0.payload.conceptId == value.payload.conceptId
                && $0.payload.evidenceId == value.payload.evidenceId
                && $0.payload.relation == relation
        }
        guard !duplicate else { throw StoreError.invalidConceptLink }
        value.payload.relation = relation
        value.payload.updatedAt = date
        _ = try await save(
            id: id,
            payload: value.payload,
            parentId: value.payload.conceptId,
            relationIds: [value.payload.conceptId, value.payload.evidenceId]
        )
    }

    public func removeConceptEvidenceRelation(id: UUID, at date: Date = .now) async throws {
        _ = try await payload(ConceptEvidenceRelationPayload.self, id: id)
        try await database.deleteLocal(id: id, modifiedAt: date)
    }

    /// Creates one durable typed edge between two Concepts. Identical edges are idempotent so a
    /// repeated review or retry cannot duplicate the owner's knowledge graph.
    @discardableResult
    public func createConceptLink(
        sourceConceptId: UUID,
        targetConceptId: UUID,
        relation: ConceptLinkKind,
        rationale: String? = nil,
        evidenceIds: [UUID] = [],
        provenance: RecordProvenance = .user,
        generatorArtifactId: UUID? = nil,
        at date: Date = .now
    ) async throws -> UUID {
        guard sourceConceptId != targetConceptId else { throw StoreError.invalidConceptLink }
        _ = try await payload(ConceptPayload.self, id: sourceConceptId)
        _ = try await payload(ConceptPayload.self, id: targetConceptId)
        let uniqueEvidenceIds = Array(Set(evidenceIds))
        for evidenceId in uniqueEvidenceIds {
            _ = try await payload(EvidencePayload.self, id: evidenceId)
        }
        if let generatorArtifactId {
            _ = try await payload(LearningGenerationArtifact.self, id: generatorArtifactId)
        }
        if let existing = try await list(ConceptLinkPayload.self).first(where: {
            $0.payload.sourceConceptId == sourceConceptId
                && $0.payload.targetConceptId == targetConceptId
                && $0.payload.relation == relation
        }) {
            return existing.id
        }
        let cleanRationale = rationale?.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = ConceptLinkPayload(
            sourceConceptId: sourceConceptId,
            targetConceptId: targetConceptId,
            relation: relation,
            provenance: provenance,
            rationale: cleanRationale?.isEmpty == true ? nil : cleanRationale,
            evidenceIds: uniqueEvidenceIds,
            generatorArtifactId: generatorArtifactId,
            now: date
        )
        return try await save(
            payload: payload,
            parentId: sourceConceptId,
            relationIds: [sourceConceptId, targetConceptId, generatorArtifactId].compactMap(\ .self)
                + uniqueEvidenceIds
        )
    }

    public func updateConceptLink(
        id: UUID,
        relation: ConceptLinkKind,
        rationale: String?,
        evidenceIds: [UUID],
        at date: Date = .now
    ) async throws {
        var link = try await payload(ConceptLinkPayload.self, id: id)
        let uniqueEvidenceIds = Array(Set(evidenceIds))
        for evidenceId in uniqueEvidenceIds {
            _ = try await payload(EvidencePayload.self, id: evidenceId)
        }
        let duplicate = try await list(ConceptLinkPayload.self).contains {
            $0.id != id
                && $0.payload.sourceConceptId == link.payload.sourceConceptId
                && $0.payload.targetConceptId == link.payload.targetConceptId
                && $0.payload.relation == relation
        }
        guard !duplicate else { throw StoreError.invalidConceptLink }
        let cleanRationale = rationale?.trimmingCharacters(in: .whitespacesAndNewlines)
        link.payload.relation = relation
        link.payload.rationale = cleanRationale?.isEmpty == true ? nil : cleanRationale
        link.payload.evidenceIds = uniqueEvidenceIds
        link.payload.updatedAt = date
        _ = try await save(
            id: id,
            payload: link.payload,
            parentId: link.payload.sourceConceptId,
            relationIds: [
                link.payload.sourceConceptId,
                link.payload.targetConceptId,
                link.payload.generatorArtifactId,
            ].compactMap(\ .self) + uniqueEvidenceIds
        )
    }

    public func conceptLinks(conceptId: UUID) async throws -> [IdentifiedPayload<ConceptLinkPayload>] {
        _ = try await payload(ConceptPayload.self, id: conceptId)
        return try await list(ConceptLinkPayload.self).filter {
            $0.payload.sourceConceptId == conceptId || $0.payload.targetConceptId == conceptId
        }.sorted { $0.payload.updatedAt > $1.payload.updatedAt }
    }

    public func removeConceptLink(id: UUID, at date: Date = .now) async throws {
        _ = try await payload(ConceptLinkPayload.self, id: id)
        try await database.deleteLocal(id: id, modifiedAt: date)
    }

    /// Rebuilds every durable use of one Evidence record. The projection avoids a second mutable
    /// backlink index and remains correct after conflict preservation or recovery.
    public func evidenceBacklinks(evidenceId: UUID) async throws -> [EvidenceBacklink] {
        _ = try await payload(EvidencePayload.self, id: evidenceId)
        let noteBlocks = try await list(NoteBlockPayload.self).filter {
            !$0.payload.tombstone && $0.payload.evidenceId == evidenceId
        }
        let conceptRelations = try await list(ConceptEvidenceRelationPayload.self).filter {
            $0.payload.evidenceId == evidenceId
        }
        let revisions = try await list(FlashcardRevisionPayload.self).filter {
            $0.payload.evidenceIds.contains(evidenceId)
        }
        let questions = try await list(TestQuestionPayload.self).filter {
            $0.payload.evidenceIds.contains(evidenceId)
        }

        var result: [EvidenceBacklink] = []
        for block in noteBlocks {
            let note = try? await payload(NotePayload.self, id: block.payload.noteId)
            result.append(EvidenceBacklink(
                id: block.id,
                kind: .note,
                ownerId: block.payload.noteId,
                title: note?.payload.title ?? "Note"
            ))
        }
        for relation in conceptRelations {
            let concept = try? await payload(ConceptPayload.self, id: relation.payload.conceptId)
            result.append(EvidenceBacklink(
                id: relation.id,
                kind: .concept,
                ownerId: relation.payload.conceptId,
                title: concept?.payload.name ?? "Concept"
            ))
        }
        for revision in revisions {
            result.append(EvidenceBacklink(
                id: revision.id,
                kind: .flashcard,
                ownerId: revision.payload.cardId,
                title: revision.payload.prompt
            ))
        }
        for question in questions {
            result.append(EvidenceBacklink(
                id: question.id,
                kind: .testQuestion,
                ownerId: question.payload.testId,
                title: question.payload.prompt
            ))
        }
        return result.sorted {
            if $0.kind.rawValue == $1.kind.rawValue { return $0.title < $1.title }
            return $0.kind.rawValue < $1.kind.rawValue
        }
    }

    private func localWrite<Payload: EntityPayload>(
        id: UUID,
        payload: Payload,
        parentId: UUID? = nil,
        relationIds: [UUID] = []
    ) throws -> LocalEntityWrite {
        let content = try CanonicalJSON.encode(payload)
        return LocalEntityWrite(
            id: id,
            entityType: Payload.entityType,
            parentId: parentId,
            relationIds: relationIds,
            content: content,
            search: EntitySearchIndexer.document(for: Payload.entityType, content: content),
            modifiedAt: payload.updatedAt
        )
    }
}

private extension LocalEntityWrite {
    func overridingEntityType(_ entityType: EntityType) -> LocalEntityWrite {
        var copy = self
        copy.entityType = entityType
        return copy
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
