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
}

public struct AcceptedLearningRecords: Equatable, Sendable {
    public var flashcards: Int
    public var tests: Int
    public var concepts: Int

    public init(flashcards: Int = 0, tests: Int = 0, concepts: Int = 0) {
        self.flashcards = flashcards
        self.tests = tests
        self.concepts = concepts
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
            case .aiArtifact:
                guard let object = try JSONSerialization.jsonObject(with: content) as? [String: Any]
                else { return nil }
                return SearchDocument(title: "AI artifact", body: text(in: object).joined(separator: "\n"))
            case .topicArea, .collectionItem, .sessionNote, .sessionResource, .sourceVersion,
                 .conceptEvidence, .conceptLink, .sessionActivity, .flashcardDeck, .flashcard,
                 .flashcardReview, .topicScopeSnapshot, .testBlueprint, .testAttempt,
                 .testResponse, .recommendationResponse, .automationGrant:
                return nil
            }
        } catch {
            return nil
        }
    }

    private static func text(in value: Any) -> [String] {
        if let string = value as? String {
            if UUID(uuidString: string) != nil || string.contains("/v1") { return [] }
            return [string]
        }
        if let array = value as? [Any] {
            return array.flatMap(text)
        }
        if let dictionary = value as? [String: Any] {
            return dictionary
                .filter { !["schemaVersion", "providerRequestId"].contains($0.key) }
                .flatMap { text(in: $0.value) }
        }
        return []
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
                && value.payload.title == recommendation.title
        }
        let recommendationId = existing?.id ?? UUID()
        let responseId = UUID()
        let response = RecommendationResponsePayload(
            recommendationId: recommendationId,
            action: action,
            snoozedUntil: snoozedUntil,
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
        let response = artifact.editedResponse ?? artifact.response
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
                let objectiveTitles = Array(Set(usableItems.flatMap(\.objectiveTitles))).sorted()
                let titles = objectiveTitles.isEmpty ? ["Topic coverage"] : objectiveTitles
                let objectives = titles.map {
                    TestObjective(title: $0, dimensions: TestCoverageDimension.allCases)
                }
                let objectiveByTitle = Dictionary(uniqueKeysWithValues: zip(titles, objectives.map(\.id)))
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
                    objectives: objectives,
                    requestedQuestionCount: usableItems.count,
                    provenance: .reviewedAI,
                    now: date
                )
                let coveredTitles = Set(usableItems.flatMap(\.objectiveTitles))
                blueprint.uncoveredObjectives = objectives.compactMap {
                    coveredTitles.contains($0.title) || objectiveTitles.isEmpty ? nil : $0.id
                }
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
                    let mappedObjectives = item.objectiveTitles.compactMap { objectiveByTitle[$0] }
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
            for item in response.items {
                let concept = ConceptPayload(
                    name: item.title,
                    conceptDescription: item.body,
                    topicIds: [artifact.topicId],
                    now: date
                )
                writes.append(try localWrite(
                    id: UUID(),
                    payload: concept,
                    parentId: artifact.topicId,
                    relationIds: [artifact.topicId, artifactId] + item.citedSourceIds
                ))
                result.concepts += 1
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
            now: date
        )
        let covered = Set(questions.flatMap(\.objectiveIds))
        blueprint.uncoveredObjectives = objectives.map(\.id).filter { !covered.contains($0) }
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

    @discardableResult
    public func createSource(
        type: ResourceKind,
        title: String,
        originalAssetId: UUID? = nil,
        canonicalURL: URL? = nil,
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
        source.currentVersionId = versionId
        let version = SourceVersionPayload(
            sourceId: sourceId,
            versionNumber: 1,
            originalAssetId: originalAssetId,
            now: date
        )
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

    @discardableResult
    public func linkConcept(
        _ conceptId: UUID,
        toEvidence evidenceId: UUID,
        relation: ConceptEvidenceKind
    ) async throws -> UUID {
        _ = try await payload(ConceptPayload.self, id: conceptId)
        _ = try await payload(EvidencePayload.self, id: evidenceId)
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
