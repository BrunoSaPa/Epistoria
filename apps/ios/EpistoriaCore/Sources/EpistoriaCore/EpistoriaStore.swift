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
}

public enum EntitySearchIndexer {
    public static func document(for entityType: EntityType, content: Data) -> SearchDocument? {
        do {
            switch entityType {
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
                let value = try CanonicalJSON.decode(CoursePayload.self, from: content)
                return SearchDocument(
                    title: value.name,
                    body: [value.code, value.professor, value.courseDescription]
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
                let value = try CanonicalJSON.decode(ResourcePayload.self, from: content)
                return SearchDocument(title: value.title, body: value.authors.joined(separator: "\n"))
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
            case .collectionItem, .sessionNote, .sessionResource:
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
        let noteId = try await save(
            payload: NotePayload(
                title: title,
                courseId: courseId,
                studySessionId: sessionId,
                canvas: canvas
            ),
            parentId: courseId ?? sessionId,
            relationIds: [courseId, sessionId].compactMap(\ .self)
        )
        if let sessionId {
            let relation = RelationPayload(kind: .sessionNote, leftId: sessionId, rightId: noteId)
            _ = try await save(
                payload: relation,
                parentId: sessionId,
                relationIds: [sessionId, noteId],
                entityTypeOverride: .sessionNote
            )
        }
        return noteId
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
        goals: [String] = []
    ) async throws -> UUID {
        try await save(
            payload: StudySessionPayload(title: title, courseId: courseId, goals: goals),
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
}
