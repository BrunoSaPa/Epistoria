import Foundation
@preconcurrency import SQLCipher

public enum LocalSyncState: String, Codable, Sendable {
    case pending = "PENDING"
    case synced = "SYNCED"
    case conflict = "CONFLICT"
}

public enum MutationOperation: String, Codable, Sendable {
    case upsert = "UPSERT"
    case delete = "DELETE"
}

public struct StoredEntity: Equatable, Sendable {
    public var id: UUID
    public var entityType: EntityType
    public var parentId: UUID?
    public var relationIds: [UUID]
    public var content: Data
    public var revision: Int
    public var tombstone: Bool
    public var clientModifiedAt: Date
    public var syncState: LocalSyncState

    public init(
        id: UUID,
        entityType: EntityType,
        parentId: UUID?,
        relationIds: [UUID],
        content: Data,
        revision: Int,
        tombstone: Bool,
        clientModifiedAt: Date,
        syncState: LocalSyncState
    ) {
        self.id = id
        self.entityType = entityType
        self.parentId = parentId
        self.relationIds = relationIds
        self.content = content
        self.revision = revision
        self.tombstone = tombstone
        self.clientModifiedAt = clientModifiedAt
        self.syncState = syncState
    }
}

public struct EntityPageCursor: Codable, Equatable, Sendable {
    public var modifiedAt: Date
    public var entityId: UUID

    public init(modifiedAt: Date, entityId: UUID) {
        self.modifiedAt = modifiedAt
        self.entityId = entityId
    }
}

public struct StoredEntityPage: Equatable, Sendable {
    public var entities: [StoredEntity]
    public var nextCursor: EntityPageCursor?

    public init(entities: [StoredEntity], nextCursor: EntityPageCursor?) {
        self.entities = entities
        self.nextCursor = nextCursor
    }
}

public struct EntitySnapshotRequest: Equatable, Sendable {
    public var type: EntityType
    public var parentId: UUID?
    public var limit: Int

    public init(type: EntityType, parentId: UUID? = nil, limit: Int) {
        self.type = type
        self.parentId = parentId
        self.limit = limit
    }
}

public struct EntitySnapshotSlice: Equatable, Sendable {
    public var request: EntitySnapshotRequest
    public var page: StoredEntityPage
}

public struct BoundedEntitySnapshot: Equatable, Sendable {
    public var readAt: Date
    public var slices: [EntitySnapshotSlice]
}

public struct LocalEntityWrite: Equatable, Sendable {
    public var id: UUID
    public var entityType: EntityType
    public var parentId: UUID?
    public var relationIds: [UUID]
    public var content: Data
    public var search: SearchDocument?
    public var searchProjection: SearchProjectionWrite?
    public var modifiedAt: Date

    public init(
        id: UUID,
        entityType: EntityType,
        parentId: UUID? = nil,
        relationIds: [UUID] = [],
        content: Data,
        search: SearchDocument? = nil,
        searchProjection: SearchProjectionWrite? = nil,
        modifiedAt: Date = .now
    ) {
        self.id = id
        self.entityType = entityType
        self.parentId = parentId
        self.relationIds = relationIds
        self.content = content
        self.search = search
        self.searchProjection = searchProjection
        self.modifiedAt = modifiedAt
    }
}

public enum SearchSegmentOrigin: String, Codable, CaseIterable, Sendable {
    case writtenText = "WRITTEN_TEXT"
    case handwritingOCR = "HANDWRITING_OCR"
    case imageOCR = "IMAGE_OCR"
    case sourceExtraction = "SOURCE_EXTRACTION"
    case sourceOCR = "SOURCE_OCR"
    case transcript = "TRANSCRIPT"
    case evidence = "EVIDENCE"
    case correctedRecognition = "CORRECTED_RECOGNITION"
}

public enum SearchSegmentReviewState: String, Codable, CaseIterable, Sendable {
    case authored = "AUTHORED"
    case unreviewed = "UNREVIEWED"
    case accepted = "ACCEPTED"
    case corrected = "CORRECTED"
}

public struct SearchSegmentLocator: Codable, Equatable, Sendable {
    public var targetId: UUID?
    public var sourceVersionId: UUID?
    public var pageNumber: Int?
    public var rectangles: [AnnotationRectangle]
    public var startSeconds: Double?

    public init(
        targetId: UUID? = nil,
        sourceVersionId: UUID? = nil,
        pageNumber: Int? = nil,
        rectangles: [AnnotationRectangle] = [],
        startSeconds: Double? = nil
    ) {
        self.targetId = targetId
        self.sourceVersionId = sourceVersionId
        self.pageNumber = pageNumber
        self.rectangles = Array(rectangles.prefix(64))
        self.startSeconds = startSeconds
    }
}

public struct SearchSegmentWrite: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var ownerEntityId: UUID
    public var sourceEntityId: UUID
    public var origin: SearchSegmentOrigin
    public var reviewState: SearchSegmentReviewState
    public var authority: Int
    public var language: String?
    public var title: String
    public var body: String
    public var locator: SearchSegmentLocator?
    public var contentRevision: Int
    public var updatedAt: Date

    public init(
        id: UUID,
        ownerEntityId: UUID,
        sourceEntityId: UUID,
        origin: SearchSegmentOrigin,
        reviewState: SearchSegmentReviewState,
        authority: Int,
        language: String? = nil,
        title: String,
        body: String,
        locator: SearchSegmentLocator? = nil,
        contentRevision: Int = 0,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.ownerEntityId = ownerEntityId
        self.sourceEntityId = sourceEntityId
        self.origin = origin
        self.reviewState = reviewState
        self.authority = min(max(authority, 0), 100)
        self.language = language.map { String($0.prefix(32)) }
        self.title = String(title.prefix(1_000))
        self.body = String(body.prefix(500_000))
        self.locator = locator
        self.contentRevision = max(contentRevision, 0)
        self.updatedAt = updatedAt
    }
}

public struct SearchProjectionWrite: Equatable, Sendable {
    public var sourceEntityId: UUID
    public var segments: [SearchSegmentWrite]

    public init(sourceEntityId: UUID, segments: [SearchSegmentWrite]) {
        self.sourceEntityId = sourceEntityId
        self.segments = segments
    }
}

public struct PendingMutation: Equatable, Sendable {
    public var mutationId: UUID
    public var entityId: UUID
    public var entityType: EntityType
    public var operation: MutationOperation
    public var baseRevision: Int
    public var parentId: UUID?
    public var relationIds: [UUID]
    public var content: Data
    public var clientModifiedAt: Date
    public var attemptCount: Int
}

public enum SearchMatchKind: String, Equatable, Sendable {
    case exact
    case related
}

public struct SearchHit: Equatable, Sendable, Identifiable {
    public var id: UUID { entity.id }
    public var entity: StoredEntity
    public var snippet: String
    public var matchKind: SearchMatchKind
    public var relevance: Double?
    public var origin: SearchSegmentOrigin?
    public var reviewState: SearchSegmentReviewState?
    public var sourceEntityId: UUID?
    public var locator: SearchSegmentLocator?
    public var additionalSnippets: [String]

    public init(
        entity: StoredEntity,
        snippet: String,
        matchKind: SearchMatchKind,
        relevance: Double?,
        origin: SearchSegmentOrigin? = nil,
        reviewState: SearchSegmentReviewState? = nil,
        sourceEntityId: UUID? = nil,
        locator: SearchSegmentLocator? = nil,
        additionalSnippets: [String] = []
    ) {
        self.entity = entity
        self.snippet = snippet
        self.matchKind = matchKind
        self.relevance = relevance
        self.origin = origin
        self.reviewState = reviewState
        self.sourceEntityId = sourceEntityId
        self.locator = locator
        self.additionalSnippets = Array(additionalSnippets.prefix(2))
    }
}

public struct LocalConflict: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var entityId: UUID
    public var entityType: EntityType
    public var parentId: UUID?
    public var relationIds: [UUID]
    public var candidateContent: Data
    public var serverConflictId: UUID?
    public var createdAt: Date
}

/// A conflict restored from a readable portability package. The candidate remains separate from
/// the current entity so import never chooses a winner on the owner's behalf.
public struct ImportedLocalConflict: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var entityId: UUID
    public var entityType: EntityType
    public var parentId: UUID?
    public var relationIds: [UUID]
    public var candidateContent: Data
    public var serverConflictId: UUID?
    public var createdAt: Date

    public init(
        id: UUID,
        entityId: UUID,
        entityType: EntityType,
        parentId: UUID?,
        relationIds: [UUID],
        candidateContent: Data,
        serverConflictId: UUID?,
        createdAt: Date
    ) {
        self.id = id
        self.entityId = entityId
        self.entityType = entityType
        self.parentId = parentId
        self.relationIds = relationIds
        self.candidateContent = candidateContent
        self.serverConflictId = serverConflictId
        self.createdAt = createdAt
    }
}

public struct RemoteEntityUpdate: Equatable, Sendable {
    public var entity: StoredEntity
    public var search: SearchDocument?

    public init(entity: StoredEntity, search: SearchDocument?) {
        self.entity = entity
        self.search = search
    }
}

public struct HydratedServerConflict: Equatable, Sendable {
    public var serverConflictId: UUID
    public var entityId: UUID
    public var entityType: EntityType
    public var parentId: UUID?
    public var relationIds: [UUID]
    public var candidateContent: Data
    public var createdAt: Date

    public init(
        serverConflictId: UUID,
        entityId: UUID,
        entityType: EntityType,
        parentId: UUID?,
        relationIds: [UUID],
        candidateContent: Data,
        createdAt: Date
    ) {
        self.serverConflictId = serverConflictId
        self.entityId = entityId
        self.entityType = entityType
        self.parentId = parentId
        self.relationIds = relationIds
        self.candidateContent = candidateContent
        self.createdAt = createdAt
    }
}

public enum LocalAssetUploadState: String, Codable, Sendable {
    case pending = "PENDING"
    case available = "AVAILABLE"
    case failed = "FAILED"
}

public struct LocalAsset: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var dedupeTag: String
    public var encryptedFileURL: URL
    public var encryptedByteSize: Int64
    public var uploadState: LocalAssetUploadState
    public var lastErrorCode: String?

    public init(
        id: UUID,
        dedupeTag: String,
        encryptedFileURL: URL,
        encryptedByteSize: Int64,
        uploadState: LocalAssetUploadState,
        lastErrorCode: String? = nil
    ) {
        self.id = id
        self.dedupeTag = dedupeTag
        self.encryptedFileURL = encryptedFileURL
        self.encryptedByteSize = encryptedByteSize
        self.uploadState = uploadState
        self.lastErrorCode = lastErrorCode
    }
}

public struct DataHealthSnapshot: Equatable, Sendable {
    public var pendingMutations: Int
    public var unresolvedConflicts: Int
    public var pendingAssets: Int
    public var lastServerSequence: String
    public var databaseIntegrity: String
}

public enum LocalDatabaseError: Error, Equatable, LocalizedError {
    case openFailed(String)
    case keyRejected
    case queryFailed(String)
    case invalidRow
    case payloadTooLarge
    case cursorRegression
    case incompatibleSchema(Int)

    public var errorDescription: String? {
        switch self {
        case .openFailed:
            "Epistoria could not open its protected notebook file."
        case .keyRejected:
            "The available key could not unlock this notebook. It may belong to another account or be damaged. No local data was changed."
        case .queryFailed:
            "Epistoria could not read or update its protected notebook."
        case .invalidRow:
            "Epistoria found an invalid local notebook record and stopped before changing it."
        case .payloadTooLarge:
            "This item is larger than the local notebook limit. The previous saved version remains available."
        case .cursorRegression:
            "Epistoria rejected an older synchronization position. Local data was not changed."
        case .incompatibleSchema:
            "This development notebook uses an older storage generation. Create and verify its readable archive before resetting it. No local data was changed."
        }
    }
}

private final class SQLCipherConnection: @unchecked Sendable {
    let pointer: OpaquePointer

    init(_ pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        sqlite3_close(pointer)
    }
}

public actor SQLCipherDatabase {
    private enum SQLValue {
        case text(String)
        case integer(Int64)
        case real(Double)
        case blob(Data)
        case null
    }

    private let connection: SQLCipherConnection
    private let semanticEmbeddingProvider: any LocalSemanticEmbeddingProviding
    public nonisolated let url: URL

    public init(url: URL, key: Data, schemaGeneration: Int = 2) throws {
        try self.init(
            url: url,
            key: key,
            semanticEmbeddingProvider: AppleLocalSemanticEmbeddingProvider(),
            schemaGeneration: schemaGeneration
        )
    }

    init(
        url: URL,
        key: Data,
        semanticEmbeddingProvider: any LocalSemanticEmbeddingProviding,
        schemaGeneration: Int = 2
    ) throws {
        guard key.count == 32 else { throw LocalDatabaseError.keyRejected }
        self.url = url
        self.semanticEmbeddingProvider = semanticEmbeddingProvider
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK,
              let database
        else {
            let message = database.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:))
                ?? "unknown SQLite error"
            sqlite3_close(database)
            throw LocalDatabaseError.openFailed(message)
        }
        let keyResult = key.withUnsafeBytes { bytes in
            sqlite3_key(database, bytes.baseAddress, Int32(key.count))
        }
        guard keyResult == SQLITE_OK else {
            sqlite3_close(database)
            throw LocalDatabaseError.keyRejected
        }
        do {
            try Self.execute(database, "SELECT count(*) FROM sqlite_master")
        } catch {
            sqlite3_close(database)
            throw LocalDatabaseError.keyRejected
        }
        do {
            try Self.execute(database, "PRAGMA cipher_memory_security = ON")
            try Self.execute(database, "PRAGMA foreign_keys = ON")
            try Self.execute(database, "PRAGMA secure_delete = ON")
            try Self.execute(database, "PRAGMA journal_mode = WAL")
            try Self.execute(database, "PRAGMA synchronous = FULL")
            try Self.execute(database, "PRAGMA temp_store = MEMORY")
            let existingVersion = try Self.userVersion(database)
            guard existingVersion <= 6 else {
                throw LocalDatabaseError.incompatibleSchema(existingVersion)
            }
            if schemaGeneration >= 2, (1 ... 4).contains(existingVersion) {
                throw LocalDatabaseError.incompatibleSchema(existingVersion)
            }
            try Self.migrate(database, schemaGeneration: schemaGeneration)
            Self.applyFileProtection(url)
            connection = SQLCipherConnection(database)
        } catch {
            sqlite3_close(database)
            throw error
        }
    }

    @discardableResult
    public func saveLocal(
        id: UUID,
        entityType: EntityType,
        parentId: UUID? = nil,
        relationIds: [UUID] = [],
        content: Data,
        search: SearchDocument? = nil,
        searchProjection: SearchProjectionWrite? = nil,
        modifiedAt: Date = .now
    ) throws -> StoredEntity {
        guard content.count <= 2_097_152 else { throw LocalDatabaseError.payloadTooLarge }
        let existing = try entity(id: id)
        let revision = existing?.revision ?? 0
        let relationJSON = try encodeUUIDs(relationIds)
        let mutationId = UUID()
        try transaction {
            try run(
                """
                INSERT INTO entities
                    (id, entity_type, parent_id, relation_ids, content, revision, tombstone,
                     client_modified_at, sync_state)
                VALUES (?, ?, ?, ?, ?, ?, 0, ?, 'PENDING')
                ON CONFLICT(id) DO UPDATE SET
                    entity_type=excluded.entity_type,
                    parent_id=excluded.parent_id,
                    relation_ids=excluded.relation_ids,
                    content=excluded.content,
                    tombstone=0,
                    client_modified_at=excluded.client_modified_at,
                    sync_state='PENDING'
                """,
                [
                    .text(canonical(id)),
                    .text(entityType.rawValue),
                    parentId.map { .text(canonical($0)) } ?? .null,
                    .text(relationJSON),
                    .blob(content),
                    .integer(Int64(revision)),
                    .real(modifiedAt.timeIntervalSince1970),
                ]
            )
            try run("DELETE FROM outbox WHERE entity_id = ?", [.text(canonical(id))])
            try run(
                """
                INSERT INTO outbox
                    (mutation_id, entity_id, entity_type, operation, base_revision, parent_id,
                     relation_ids, content, client_modified_at, attempt_count, created_at)
                VALUES (?, ?, ?, 'UPSERT', ?, ?, ?, ?, ?, 0, ?)
                """,
                [
                    .text(canonical(mutationId)),
                    .text(canonical(id)),
                    .text(entityType.rawValue),
                    .integer(Int64(revision)),
                    parentId.map { .text(canonical($0)) } ?? .null,
                    .text(relationJSON),
                    .blob(content),
                    .real(modifiedAt.timeIntervalSince1970),
                    .real(Date.now.timeIntervalSince1970),
                ]
            )
            try updateSearch(
                id: id,
                entityType: entityType,
                document: search,
                projection: searchProjection,
                modifiedAt: modifiedAt
            )
            try updateWorkspaceSummary(
                id: id,
                entityType: entityType,
                parentId: parentId,
                content: content,
                tombstone: false,
                modifiedAt: modifiedAt
            )
        }
        return StoredEntity(
            id: id,
            entityType: entityType,
            parentId: parentId,
            relationIds: relationIds,
            content: content,
            revision: revision,
            tombstone: false,
            clientModifiedAt: modifiedAt,
            syncState: .pending
        )
    }

    /// Saves and tombstones a related set of encrypted records and their outbox mutations as one
    /// transaction. Any malformed or oversized write rejects the complete batch.
    public func saveLocalBatch(
        _ writes: [LocalEntityWrite],
        deleting deletionIds: [UUID] = [],
        deletedAt: Date = .now,
        registeringAssets assets: [LocalAsset] = [],
        registeringConflicts conflicts: [ImportedLocalConflict] = []
    ) throws {
        guard !writes.isEmpty || !deletionIds.isEmpty || !assets.isEmpty || !conflicts.isEmpty else {
            return
        }
        guard Set(writes.map(\.id)).count == writes.count else {
            throw LocalDatabaseError.queryFailed("duplicate entity in atomic write")
        }
        guard Set(deletionIds).count == deletionIds.count,
              Set(writes.map(\.id)).isDisjoint(with: deletionIds)
        else {
            throw LocalDatabaseError.queryFailed("duplicate entity in atomic write")
        }
        guard writes.allSatisfy({ $0.content.count <= 2_097_152 }) else {
            throw LocalDatabaseError.payloadTooLarge
        }
        guard Set(assets.map(\.id)).count == assets.count,
              Set(assets.map(\.dedupeTag)).count == assets.count,
              Set(conflicts.map(\.id)).count == conflicts.count,
              conflicts.allSatisfy({ $0.candidateContent.count <= 2_097_152 })
        else {
            throw LocalDatabaseError.invalidRow
        }
        let prepared = try writes.map { write in
            (
                write: write,
                revision: try entity(id: write.id)?.revision ?? 0,
                relationJSON: try encodeUUIDs(write.relationIds),
                mutationId: UUID()
            )
        }
        let preparedDeletions = try deletionIds.compactMap { id -> StoredEntity? in
            guard let current = try entity(id: id), !current.tombstone else { return nil }
            return current
        }
        do {
            try transaction {
                var affectedSearchOwners = Set<String>()
                for item in prepared {
                    let write = item.write
                    try run(
                        """
                        INSERT INTO entities
                            (id, entity_type, parent_id, relation_ids, content, revision, tombstone,
                             client_modified_at, sync_state)
                        VALUES (?, ?, ?, ?, ?, ?, 0, ?, 'PENDING')
                        ON CONFLICT(id) DO UPDATE SET
                            entity_type=excluded.entity_type,
                            parent_id=excluded.parent_id,
                            relation_ids=excluded.relation_ids,
                            content=excluded.content,
                            tombstone=0,
                            client_modified_at=excluded.client_modified_at,
                            sync_state='PENDING'
                        """,
                        [
                            .text(canonical(write.id)),
                            .text(write.entityType.rawValue),
                            write.parentId.map { .text(canonical($0)) } ?? .null,
                            .text(item.relationJSON),
                            .blob(write.content),
                            .integer(Int64(item.revision)),
                            .real(write.modifiedAt.timeIntervalSince1970),
                        ]
                    )
                    try run("DELETE FROM outbox WHERE entity_id = ?", [.text(canonical(write.id))])
                    try run(
                        """
                        INSERT INTO outbox
                            (mutation_id, entity_id, entity_type, operation, base_revision, parent_id,
                             relation_ids, content, client_modified_at, attempt_count, created_at)
                        VALUES (?, ?, ?, 'UPSERT', ?, ?, ?, ?, ?, 0, ?)
                        """,
                        [
                            .text(canonical(item.mutationId)),
                            .text(canonical(write.id)),
                            .text(write.entityType.rawValue),
                            .integer(Int64(item.revision)),
                            write.parentId.map { .text(canonical($0)) } ?? .null,
                            .text(item.relationJSON),
                            .blob(write.content),
                            .real(write.modifiedAt.timeIntervalSince1970),
                            .real(Date.now.timeIntervalSince1970),
                        ]
                    )
                    affectedSearchOwners.formUnion(try updateSearch(
                        id: write.id,
                        entityType: write.entityType,
                        document: write.search,
                        projection: write.searchProjection,
                        modifiedAt: write.modifiedAt,
                        rebuildOwners: false
                    ))
                    try updateWorkspaceSummary(
                        id: write.id,
                        entityType: write.entityType,
                        parentId: write.parentId,
                        content: write.content,
                        tombstone: false,
                        modifiedAt: write.modifiedAt
                    )
                }
                for current in preparedDeletions {
                    try run(
                        "UPDATE entities SET tombstone=1, sync_state='PENDING', client_modified_at=? WHERE id=?",
                        [.real(deletedAt.timeIntervalSince1970), .text(canonical(current.id))]
                    )
                    try run("DELETE FROM outbox WHERE entity_id=?", [.text(canonical(current.id))])
                    try run(
                        """
                        INSERT INTO outbox
                            (mutation_id, entity_id, entity_type, operation, base_revision, parent_id,
                             relation_ids, content, client_modified_at, attempt_count, created_at)
                        VALUES (?, ?, ?, 'DELETE', ?, ?, ?, ?, ?, 0, ?)
                        """,
                        [
                            .text(canonical(UUID())),
                            .text(canonical(current.id)),
                            .text(current.entityType.rawValue),
                            .integer(Int64(current.revision)),
                            current.parentId.map { .text(canonical($0)) } ?? .null,
                            .text(try encodeUUIDs(current.relationIds)),
                            .blob(current.content),
                            .real(deletedAt.timeIntervalSince1970),
                            .real(Date.now.timeIntervalSince1970),
                        ]
                    )
                    affectedSearchOwners.formUnion(try updateSearch(
                        id: current.id,
                        entityType: current.entityType,
                        document: nil,
                        modifiedAt: deletedAt,
                        rebuildOwners: false
                    ))
                    try run(
                        "DELETE FROM workspace_summary WHERE entity_id=?",
                        [.text(canonical(current.id))]
                    )
                }
                for asset in assets {
                    try registerLocalAsset(asset)
                }
                for conflict in conflicts {
                    let currentType = try entity(id: conflict.entityId)?.entityType
                    guard currentType == conflict.entityType
                    else { throw LocalDatabaseError.invalidRow }
                    try run(
                        """
                        INSERT INTO local_conflicts
                            (id, entity_id, entity_type, parent_id, relation_ids, candidate_content,
                             server_conflict_id, created_at, resolved_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL)
                        """,
                        [
                            .text(canonical(conflict.id)),
                            .text(canonical(conflict.entityId)),
                            .text(conflict.entityType.rawValue),
                            conflict.parentId.map { .text(canonical($0)) } ?? .null,
                            .text(try encodeUUIDs(conflict.relationIds)),
                            .blob(conflict.candidateContent),
                            conflict.serverConflictId.map { .text(canonical($0)) } ?? .null,
                            .real(conflict.createdAt.timeIntervalSince1970),
                        ]
                    )
                    try run(
                        "UPDATE entities SET sync_state='CONFLICT' WHERE id=?",
                        [.text(canonical(conflict.entityId))]
                    )
                }
                for owner in affectedSearchOwners.sorted() {
                    try rebuildOwnerSearchDocument(ownerEntityId: owner)
                }
            }
        } catch {
            throw error
        }
    }

    public func deleteLocal(id: UUID, modifiedAt: Date = .now) throws {
        guard let current = try entity(id: id) else { return }
        let mutationId = UUID()
        try transaction {
            try run(
                "UPDATE entities SET tombstone=1, sync_state='PENDING', client_modified_at=? WHERE id=?",
                [.real(modifiedAt.timeIntervalSince1970), .text(canonical(id))]
            )
            try run("DELETE FROM outbox WHERE entity_id=?", [.text(canonical(id))])
            try run(
                """
                INSERT INTO outbox
                    (mutation_id, entity_id, entity_type, operation, base_revision, parent_id,
                     relation_ids, content, client_modified_at, attempt_count, created_at)
                VALUES (?, ?, ?, 'DELETE', ?, ?, ?, ?, ?, 0, ?)
                """,
                [
                    .text(canonical(mutationId)),
                    .text(canonical(id)),
                    .text(current.entityType.rawValue),
                    .integer(Int64(current.revision)),
                    current.parentId.map { .text(canonical($0)) } ?? .null,
                    .text(try encodeUUIDs(current.relationIds)),
                    .blob(current.content),
                    .real(modifiedAt.timeIntervalSince1970),
                    .real(Date.now.timeIntervalSince1970),
                ]
            )
            try run("DELETE FROM search_index WHERE entity_id=?", [.text(canonical(id))])
            try run("DELETE FROM search_embeddings WHERE entity_id=?", [.text(canonical(id))])
            try run("DELETE FROM search_embedding_status WHERE entity_id=?", [.text(canonical(id))])
            try run("DELETE FROM workspace_summary WHERE entity_id=?", [.text(canonical(id))])
        }
    }

    public func entity(id: UUID) throws -> StoredEntity? {
        let rows = try query(
            "SELECT * FROM entities WHERE id=? LIMIT 1",
            [.text(canonical(id))]
        )
        return try rows.first.map(entityFromRow)
    }

    public func entities(
        type: EntityType,
        parentId: UUID? = nil,
        includeTombstones: Bool = false
    ) throws -> [StoredEntity] {
        var sql = "SELECT * FROM entities WHERE entity_type=?"
        var values: [SQLValue] = [.text(type.rawValue)]
        if let parentId {
            sql += " AND parent_id=?"
            values.append(.text(canonical(parentId)))
        }
        if !includeTombstones {
            sql += " AND tombstone=0"
        }
        sql += " ORDER BY client_modified_at DESC, id ASC"
        return try query(sql, values).map(entityFromRow)
    }

    /// Reads a bounded set of authoritative entities in one database operation. The returned
    /// order follows the requested identifiers and excludes tombstoned or trashed records.
    public func entities(ids: [UUID]) throws -> [StoredEntity] {
        let uniqueIds = Array(Set(ids))
        guard uniqueIds.count <= 500 else { throw LocalDatabaseError.invalidRow }
        guard !uniqueIds.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: uniqueIds.count).joined(separator: ",")
        let rows = try query(
            """
            SELECT * FROM entities
            WHERE id IN (\(placeholders))
              AND tombstone=0
              AND NOT EXISTS (
                    SELECT 1 FROM workspace_summary trash
                    WHERE trash.entity_type='TRASH_ENTRY'
                      AND trash.parent_id=entities.id
                  )
            """,
            uniqueIds.map { .text(canonical($0)) }
        ).map(entityFromRow)
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        return ids.compactMap { byId[$0] }
    }

    /// Reads children of several known parents without scanning the complete entity type.
    public func entities(
        type: EntityType,
        parentIds: [UUID],
        limit: Int = 500
    ) throws -> [StoredEntity] {
        let uniqueParentIds = Array(Set(parentIds))
        guard uniqueParentIds.count <= 500 else { throw LocalDatabaseError.invalidRow }
        guard !uniqueParentIds.isEmpty else { return [] }
        let boundedLimit = min(max(limit, 1), 500)
        let placeholders = Array(repeating: "?", count: uniqueParentIds.count).joined(separator: ",")
        var values: [SQLValue] = [.text(type.rawValue)]
        values.append(contentsOf: uniqueParentIds.map { .text(canonical($0)) })
        values.append(.integer(Int64(boundedLimit)))
        return try query(
            """
            SELECT * FROM entities
            WHERE entity_type=?
              AND parent_id IN (\(placeholders))
              AND tombstone=0
              AND NOT EXISTS (
                    SELECT 1 FROM workspace_summary trash
                    WHERE trash.entity_type='TRASH_ENTRY'
                      AND trash.parent_id=entities.id
                  )
            ORDER BY client_modified_at DESC, id ASC
            LIMIT ?
            """,
            values
        ).map(entityFromRow)
    }

    /// Reads one bounded page using a stable `(modifiedAt, id)` cursor. Cursors are local query
    /// state; they never synchronize and can be discarded after a projection rebuild.
    public func entitiesPage(
        type: EntityType,
        parentId: UUID? = nil,
        includeTombstones: Bool = false,
        limit: Int = 50,
        after cursor: EntityPageCursor? = nil
    ) throws -> StoredEntityPage {
        try entitiesPageInsideSnapshot(
            type: type,
            parentId: parentId,
            includeTombstones: includeTombstones,
            limit: limit,
            after: cursor
        )
    }

    /// Produces all requested first pages on the database actor without allowing another read or
    /// write to interleave. This is the common foundation for Today, Notebook, Library, Topics,
    /// and Learning snapshots.
    public func boundedSnapshot(_ requests: [EntitySnapshotRequest]) throws -> BoundedEntitySnapshot {
        guard requests.count <= 32 else { throw LocalDatabaseError.invalidRow }
        let slices = try requests.map { request in
            EntitySnapshotSlice(
                request: request,
                page: try entitiesPageInsideSnapshot(
                    type: request.type,
                    parentId: request.parentId,
                    includeTombstones: false,
                    limit: request.limit,
                    after: nil
                )
            )
        }
        return BoundedEntitySnapshot(readAt: .now, slices: slices)
    }

    public func workspaceSummary(
        types: Set<EntityType> = [],
        topicId: UUID? = nil,
        lifecycleState: String? = nil,
        limit: Int = 100
    ) throws -> [WorkspaceSummaryRecord] {
        let boundedLimit = min(max(limit, 1), 500)
        var clauses: [String] = []
        var values: [SQLValue] = []
        if !types.isEmpty {
            clauses.append("entity_type IN (\(Array(repeating: "?", count: types.count).joined(separator: ",")))")
            values.append(contentsOf: types.sorted { $0.rawValue < $1.rawValue }.map { .text($0.rawValue) })
        }
        if let topicId {
            clauses.append("topic_id=?")
            values.append(.text(canonical(topicId)))
        }
        if let lifecycleState {
            clauses.append("lifecycle_state=?")
            values.append(.text(lifecycleState))
        }
        var sql = "SELECT * FROM workspace_summary"
        if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
        sql += " ORDER BY COALESCE(pinned_at, activity_at) DESC, activity_at DESC, entity_id ASC LIMIT ?"
        values.append(.integer(Int64(boundedLimit)))
        return try query(sql, values).map(workspaceSummaryFromRow)
    }

    public func sourceInboxCount() throws -> Int {
        try scalarInteger(
            """
            SELECT count(*)
            FROM workspace_summary source
            WHERE source.entity_type='SOURCE'
              AND source.topic_id IS NULL
              AND source.lifecycle_state != 'ARCHIVED'
              AND NOT EXISTS (
                SELECT 1 FROM workspace_summary trash
                WHERE trash.entity_type='TRASH_ENTRY'
                  AND trash.parent_id=source.entity_id
              )
            """
        )
    }

    /// Returns due card identifiers from the disposable local projection. The latest review is
    /// selected deterministically; archived, suspended, trashed, and tombstoned cards are omitted.
    public func dueFlashcardIds(now: Date, limit: Int = 100) throws -> [UUID] {
        let boundedLimit = min(max(limit, 1), 500)
        let rows = try query(
            """
            SELECT card.entity_id
            FROM workspace_summary card
            WHERE card.entity_type='FLASHCARD'
              AND card.lifecycle_state='ACTIVE'
              AND COALESCE(
                    (
                        SELECT review.due_at
                        FROM workspace_summary review
                        WHERE review.entity_type='FLASHCARD_REVIEW'
                          AND review.parent_id=card.entity_id
                        ORDER BY review.activity_at DESC, review.entity_id DESC
                        LIMIT 1
                    ),
                    card.due_at
                  ) <= ?
              AND NOT EXISTS (
                    SELECT 1 FROM workspace_summary trash
                    WHERE trash.entity_type='TRASH_ENTRY'
                      AND trash.parent_id=card.entity_id
                  )
            ORDER BY COALESCE(
                        (
                            SELECT review.due_at
                            FROM workspace_summary review
                            WHERE review.entity_type='FLASHCARD_REVIEW'
                              AND review.parent_id=card.entity_id
                            ORDER BY review.activity_at DESC, review.entity_id DESC
                            LIMIT 1
                        ),
                        card.due_at
                     ) ASC,
                     card.entity_id ASC
            LIMIT ?
            """,
            [.real(now.timeIntervalSince1970), .integer(Int64(boundedLimit))]
        )
        return try rows.map { row in
            guard case let .text(raw) = row["entity_id"], let id = UUID(uuidString: raw)
            else { throw LocalDatabaseError.invalidRow }
            return id
        }
    }

    /// Counts all due cards by Topic without loading card or review payloads.
    public func dueFlashcardCountsByTopic(now: Date) throws -> [UUID: Int] {
        let rows = try query(
            """
            SELECT card.topic_id, count(*) AS due_count
            FROM workspace_summary card
            WHERE card.entity_type='FLASHCARD'
              AND card.lifecycle_state='ACTIVE'
              AND card.topic_id IS NOT NULL
              AND COALESCE(
                    (
                        SELECT review.due_at
                        FROM workspace_summary review
                        WHERE review.entity_type='FLASHCARD_REVIEW'
                          AND review.parent_id=card.entity_id
                        ORDER BY review.activity_at DESC, review.entity_id DESC
                        LIMIT 1
                    ),
                    card.due_at
                  ) <= ?
              AND NOT EXISTS (
                    SELECT 1 FROM workspace_summary trash
                    WHERE trash.entity_type='TRASH_ENTRY'
                      AND trash.parent_id=card.entity_id
                  )
            GROUP BY card.topic_id
            """,
            [.real(now.timeIntervalSince1970)]
        )
        return try Dictionary(uniqueKeysWithValues: rows.map { row in
            guard case let .text(rawTopicId) = row["topic_id"],
                  let topicId = UUID(uuidString: rawTopicId),
                  case let .integer(count) = row["due_count"]
            else { throw LocalDatabaseError.invalidRow }
            return (topicId, Int(count))
        })
    }

    /// Deletes and reconstructs only the disposable summary projection from authoritative rows.
    public func rebuildWorkspaceSummary() throws {
        let liveEntities = try query("SELECT * FROM entities WHERE tombstone=0").map(entityFromRow)
        try transaction {
            try run("DELETE FROM workspace_summary")
            for entity in liveEntities {
                try updateWorkspaceSummary(
                    id: entity.id,
                    entityType: entity.entityType,
                    parentId: entity.parentId,
                    content: entity.content,
                    tombstone: false,
                    modifiedAt: entity.clientModifiedAt
                )
            }
            try run(
                "UPDATE local_projection_state SET is_current=1 WHERE name='workspace-summary-v1'"
            )
        }
    }

    public func workspaceSummaryNeedsRebuild() throws -> Bool {
        try scalarInteger(
            "SELECT is_current FROM local_projection_state WHERE name='workspace-summary-v1'"
        ) == 0
    }

    public func invalidateWorkspaceSummary() throws {
        try transaction {
            try run("DELETE FROM workspace_summary")
            try run(
                "UPDATE local_projection_state SET is_current=0 WHERE name='workspace-summary-v1'"
            )
        }
    }

    /// Returns every live entity for complete portability snapshots.
    public func allEntities() throws -> [StoredEntity] {
        try query(
            "SELECT * FROM entities WHERE tombstone=0 ORDER BY entity_type ASC, id ASC"
        ).map(entityFromRow)
    }

    /// Portable import is deliberately replace-free. Server cursors do not make a newly created
    /// local notebook non-empty, but any record, mutation, asset, or conflict does.
    public func portableImportIsEmpty() throws -> Bool {
        try scalarInteger("SELECT count(*) FROM entities") == 0
            && scalarInteger("SELECT count(*) FROM outbox") == 0
            && scalarInteger("SELECT count(*) FROM local_assets") == 0
            && scalarInteger("SELECT count(*) FROM local_conflicts") == 0
    }

    @discardableResult
    public func saveProcessingJob(_ job: ProcessingJob) throws -> ProcessingJob {
        guard !job.kind.isEmpty, !job.inputFingerprint.isEmpty,
              job.requiredCapabilities.count <= ProcessingCapability.allCases.count,
              job.attemptCount >= 0
        else { throw LocalDatabaseError.invalidRow }
        let capabilities = try JSONEncoder().encode(job.requiredCapabilities)
        guard let capabilitiesText = String(data: capabilities, encoding: .utf8) else {
            throw LocalDatabaseError.invalidRow
        }
        let approval = try job.approval.map(CanonicalJSON.encode)
        try run(
            """
            INSERT INTO processing_jobs(
                id, kind, state, input_entity_id, input_revision, input_fingerprint,
                required_capabilities, selected_route, compute_node_id, approval,
                attempt_count, progress, error_code, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                kind=excluded.kind,
                state=excluded.state,
                input_entity_id=excluded.input_entity_id,
                input_revision=excluded.input_revision,
                input_fingerprint=excluded.input_fingerprint,
                required_capabilities=excluded.required_capabilities,
                selected_route=excluded.selected_route,
                compute_node_id=excluded.compute_node_id,
                approval=excluded.approval,
                attempt_count=excluded.attempt_count,
                progress=excluded.progress,
                error_code=excluded.error_code,
                updated_at=excluded.updated_at
            """,
            [
                .text(canonical(job.id)), .text(job.kind), .text(job.state.rawValue),
                job.inputEntityId.map { .text(canonical($0)) } ?? .null,
                job.inputRevision.map { .integer(Int64($0)) } ?? .null,
                .text(job.inputFingerprint), .text(capabilitiesText),
                job.selectedRoute.map { .text($0.rawValue) } ?? .null,
                job.computeNodeId.map { .text(canonical($0)) } ?? .null,
                approval.map(SQLValue.blob) ?? .null,
                .integer(Int64(job.attemptCount)),
                job.progress.map(SQLValue.real) ?? .null,
                job.errorCode.map(SQLValue.text) ?? .null,
                .real(job.createdAt.timeIntervalSince1970),
                .real(job.updatedAt.timeIntervalSince1970),
            ]
        )
        return job
    }

    public func processingJob(id: UUID) throws -> ProcessingJob? {
        try query(
            "SELECT * FROM processing_jobs WHERE id=? LIMIT 1",
            [.text(canonical(id))]
        ).first.map(processingJobFromRow)
    }

    public func processingJobs(states: [ProcessingJobState]? = nil) throws -> [ProcessingJob] {
        let uniqueStates = Array(Set(states ?? [])).sorted { $0.rawValue < $1.rawValue }
        var sql = "SELECT * FROM processing_jobs"
        var values: [SQLValue] = []
        if states != nil {
            if uniqueStates.isEmpty { return [] }
            sql += " WHERE state IN (\(Array(repeating: "?", count: uniqueStates.count).joined(separator: ",")))"
            values = uniqueStates.map { .text($0.rawValue) }
        }
        sql += " ORDER BY updated_at DESC, id ASC"
        return try query(sql, values).map(processingJobFromRow)
    }

    public func transitionProcessingJob(
        id: UUID,
        to state: ProcessingJobState,
        route: ProcessingRoute? = nil,
        computeNodeId: UUID? = nil,
        progress: Double? = nil,
        errorCode: String? = nil,
        at date: Date = .now
    ) throws -> ProcessingJob {
        guard var job = try processingJob(id: id),
              Self.allowedProcessingTransitions[job.state]?.contains(state) == true
        else { throw LocalDatabaseError.invalidRow }
        job.state = state
        if let route { job.selectedRoute = route }
        job.computeNodeId = computeNodeId ?? job.computeNodeId
        if state == .running { job.attemptCount += 1 }
        job.progress = progress.map { min(max($0.isFinite ? $0 : 0, 0), 1) }
        job.errorCode = errorCode.map { String($0.prefix(128)) }
        job.updatedAt = date
        return try saveProcessingJob(job)
    }

    public func rerouteJobs(fromComputeNode nodeId: UUID, at date: Date = .now) throws -> Int {
        let jobs = try processingJobs().filter {
            $0.computeNodeId == nodeId && !$0.state.isTerminal
        }
        for var job in jobs {
            job.state = .waitingForCapability
            job.selectedRoute = nil
            job.computeNodeId = nil
            job.progress = nil
            job.errorCode = "COMPUTE_NODE_REMOVED"
            job.updatedAt = date
            _ = try saveProcessingJob(job)
        }
        return jobs.count
    }

    /// Replaces disposable local search state without mutating or synchronizing an entity.
    public func replaceSearchProjection(_ projection: SearchProjectionWrite) throws {
        try transaction {
            let previousOwners = try query(
                "SELECT DISTINCT owner_entity_id FROM search_segments WHERE source_entity_id=?",
                [.text(canonical(projection.sourceEntityId))]
            ).compactMap { row -> String? in
                guard case let .text(value) = row["owner_entity_id"] else { return nil }
                return value
            }
            try replaceSearchProjectionInsideTransaction(projection)
            let currentOwners = projection.segments.map { canonical($0.ownerEntityId) }
            for owner in Set(previousOwners + currentOwners) {
                try rebuildOwnerSearchDocument(ownerEntityId: owner)
            }
        }
    }

    /// Deletes and rebuilds the disposable exact-search projection from authoritative entities.
    /// Dedicated recognition projections are rebuilt separately by `EpistoriaStore` because
    /// their owner, locator, and current review state are derived from multiple entities.
    public func rebuildBaseSearchProjection() throws {
        let rows = try query("SELECT * FROM entities WHERE tombstone=0 ORDER BY id ASC")
        let entities = try rows.map(entityFromRow)
        try transaction {
            try run("DELETE FROM search_segments_fts")
            try run("DELETE FROM search_segments")
            try run("DELETE FROM search_index")
            try run("DELETE FROM search_embeddings")
            try run("DELETE FROM search_embedding_status")
            for entity in entities {
                guard entity.entityType != .recognitionArtifact,
                      entity.entityType != .recognitionDecision
                else { continue }
                try updateSearch(
                    id: entity.id,
                    entityType: entity.entityType,
                    document: EntitySearchIndexer.document(
                        for: entity.entityType,
                        content: entity.content
                    ),
                    modifiedAt: entity.clientModifiedAt
                )
            }
        }
    }

    private static let allowedProcessingTransitions: [ProcessingJobState: Set<ProcessingJobState>] = [
        .queued: [.running, .paused, .waitingForCapability, .waitingForNetwork, .cancelled],
        .running: [.queued, .paused, .waitingForCapability, .waitingForNetwork, .completed, .failed, .cancelled],
        .paused: [.queued, .cancelled],
        .waitingForCapability: [.queued, .cancelled],
        .waitingForNetwork: [.queued, .cancelled],
        .completed: [],
        .failed: [.queued],
        .cancelled: [],
    ]

    public func search(
        _ text: String,
        entityTypes: [EntityType]? = nil,
        limit: Int = 50,
        includeRelated: Bool = true
    ) throws -> [SearchHit] {
        let tokens = text
            .split { !$0.isLetter && !$0.isNumber }
            .prefix(12)
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }
        guard !tokens.isEmpty else { return [] }
        let expression = tokens.joined(separator: " AND ")
        let resultLimit = min(max(limit, 1), 200)
        let scope = Array(Set(entityTypes ?? [])).sorted { $0.rawValue < $1.rawValue }
        if entityTypes != nil, scope.isEmpty { return [] }
        var scopeSQL = ""
        var scopeValues: [SQLValue] = []
        if !scope.isEmpty {
            scopeSQL = " AND e.entity_type IN (\(Array(repeating: "?", count: scope.count).joined(separator: ",")))"
            scopeValues = scope.map { .text($0.rawValue) }
        }
        let rows = try query(
            """
            SELECT e.*, s.source_entity_id AS matched_source_entity_id,
                   s.origin AS matched_origin, s.review_state AS matched_review_state,
                   s.locator AS matched_locator,
                   snippet(search_segments_fts, -1, '[', ']', '…', 18) AS result_snippet
            FROM search_segments_fts
            JOIN search_segments s ON s.id = search_segments_fts.segment_id
            JOIN entities e ON e.id = s.owner_entity_id
            WHERE search_segments_fts MATCH ? AND e.tombstone=0\(scopeSQL)
            ORDER BY bm25(search_segments_fts, 0.0, 8.0, 1.0) - (s.authority * 0.002),
                     s.updated_at DESC, e.client_modified_at DESC
            LIMIT ?
            """,
            [.text(expression)] + scopeValues + [.integer(Int64(resultLimit * 6))]
        )
        var exactById: [UUID: SearchHit] = [:]
        var exactOrder: [UUID] = []
        for row in rows {
            guard case let .text(snippet) = row["result_snippet"],
                  case let .text(originRaw) = row["matched_origin"],
                  case let .text(reviewRaw) = row["matched_review_state"],
                  case let .text(sourceRaw) = row["matched_source_entity_id"],
                  let origin = SearchSegmentOrigin(rawValue: originRaw),
                  let reviewState = SearchSegmentReviewState(rawValue: reviewRaw),
                  let sourceEntityId = UUID(uuidString: sourceRaw)
            else { throw LocalDatabaseError.invalidRow }
            let entity = try entityFromRow(row)
            if var existing = exactById[entity.id] {
                if existing.snippet != snippet,
                   !existing.additionalSnippets.contains(snippet),
                   existing.additionalSnippets.count < 2 {
                    existing.additionalSnippets.append(snippet)
                    exactById[entity.id] = existing
                }
                continue
            }
            let locator: SearchSegmentLocator?
            if case let .blob(data) = row["matched_locator"] {
                locator = try? CanonicalJSON.decode(SearchSegmentLocator.self, from: data)
            } else {
                locator = nil
            }
            exactOrder.append(entity.id)
            exactById[entity.id] = SearchHit(
                entity: entity,
                snippet: snippet,
                matchKind: .exact,
                relevance: nil,
                origin: origin,
                reviewState: reviewState,
                sourceEntityId: sourceEntityId,
                locator: locator
            )
        }
        let exact = exactOrder.prefix(resultLimit).compactMap { exactById[$0] }
        guard includeRelated,
              exact.count < resultLimit,
              semanticEmbeddingProvider.isAvailable
        else {
            return exact
        }
        _ = try? rebuildSemanticSearchIndex(batchLimit: 8)
        let related = try relatedSearchHits(
            text,
            excluding: Set(exact.map(\ .id)),
            entityTypes: scope,
            limit: resultLimit - exact.count
        )
        return exact + related
    }

    /// Builds a bounded batch of the disposable local semantic index.
    ///
    /// The source text already exists in SQLCipher's full-text table. Embedding failure never
    /// changes an entity or its synchronization state.
    @discardableResult
    public func rebuildSemanticSearchIndex(batchLimit: Int = 48) throws -> Int {
        guard semanticEmbeddingProvider.isAvailable else { return 0 }
        let boundedLimit = min(max(batchLimit, 1), 256)
        let rows = try query(
            """
            SELECT search_index.entity_id, search_index.title, search_index.body
            FROM search_index
            WHERE NOT EXISTS (
                SELECT 1 FROM search_embedding_status
                WHERE search_embedding_status.entity_id = search_index.entity_id
                  AND search_embedding_status.engine_version = ?
            )
            ORDER BY search_index.rowid ASC
            LIMIT ?
            """,
            [
                .integer(Int64(LocalSemanticSearch.engineVersion)),
                .integer(Int64(boundedLimit)),
            ]
        )
        var processed = 0
        for row in rows {
            guard case let .text(entityId) = row["entity_id"],
                  case let .text(title) = row["title"],
                  case let .text(body) = row["body"]
            else { continue }
            do {
                _ = try replaceSemanticSearch(
                    entityId: entityId,
                    document: SearchDocument(title: title, body: body)
                )
                processed += 1
            } catch {
                try? run("DELETE FROM search_embeddings WHERE entity_id=?", [.text(entityId)])
                try? run("DELETE FROM search_embedding_status WHERE entity_id=?", [.text(entityId)])
            }
        }
        return processed
    }

    public func pendingMutations(limit: Int = 100) throws -> [PendingMutation] {
        try query(
            "SELECT * FROM outbox ORDER BY created_at ASC LIMIT ?",
            [.integer(Int64(min(max(limit, 1), 100)))]
        ).map(mutationFromRow)
    }

    public func markAccepted(mutationId: UUID, revision: Int) throws {
        try transaction {
            let rows = try query(
                "SELECT entity_id FROM outbox WHERE mutation_id=?",
                [.text(canonical(mutationId))]
            )
            guard case let .text(entityId)? = rows.first?["entity_id"] else { return }
            try run(
                "UPDATE entities SET revision=?, sync_state='SYNCED' WHERE id=?",
                [.integer(Int64(revision)), .text(entityId)]
            )
            try run(
                "DELETE FROM outbox WHERE mutation_id=?",
                [.text(canonical(mutationId))]
            )
        }
    }

    public func markConflict(mutationId: UUID, serverConflictId: UUID) throws {
        try transaction {
            let rows = try query(
                "SELECT * FROM outbox WHERE mutation_id=?",
                [.text(canonical(mutationId))]
            )
            guard let row = rows.first else { return }
            let mutation = try mutationFromRow(row)
            try run(
                """
                INSERT INTO local_conflicts
                    (id, entity_id, entity_type, parent_id, relation_ids, candidate_content,
                     server_conflict_id, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(canonical(UUID())),
                    .text(canonical(mutation.entityId)),
                    .text(mutation.entityType.rawValue),
                    mutation.parentId.map { .text(canonical($0)) } ?? .null,
                    .text(try encodeUUIDs(mutation.relationIds)),
                    .blob(mutation.content),
                    .text(canonical(serverConflictId)),
                    .real(Date.now.timeIntervalSince1970),
                ]
            )
            try run(
                "UPDATE entities SET sync_state='CONFLICT' WHERE id=?",
                [.text(canonical(mutation.entityId))]
            )
            try run(
                "DELETE FROM outbox WHERE mutation_id=?",
                [.text(canonical(mutationId))]
            )
        }
    }

    public func conflicts() throws -> [LocalConflict] {
        try query(
            "SELECT * FROM local_conflicts WHERE resolved_at IS NULL ORDER BY created_at ASC"
        ).map { row in
            guard case let .text(id) = row["id"],
                  case let .text(entityId) = row["entity_id"],
                  case let .text(entityType) = row["entity_type"],
                  case let .blob(content) = row["candidate_content"],
                  case let .real(createdAt) = row["created_at"],
                  let parsedId = UUID(uuidString: id),
                  let parsedEntityId = UUID(uuidString: entityId),
                  let parsedType = EntityType(rawValue: entityType)
            else { throw LocalDatabaseError.invalidRow }
            let serverId: UUID?
            if case let .text(raw)? = row["server_conflict_id"] {
                serverId = UUID(uuidString: raw)
            } else {
                serverId = nil
            }
            let parentId: UUID?
            if case let .text(raw)? = row["parent_id"] {
                parentId = UUID(uuidString: raw)
            } else {
                parentId = nil
            }
            guard case let .text(relations)? = row["relation_ids"] else {
                throw LocalDatabaseError.invalidRow
            }
            return LocalConflict(
                id: parsedId,
                entityId: parsedEntityId,
                entityType: parsedType,
                parentId: parentId,
                relationIds: try decodeUUIDs(relations),
                candidateContent: content,
                serverConflictId: serverId,
                createdAt: Date(timeIntervalSince1970: createdAt)
            )
        }
    }

    public func resolveLocalConflict(id: UUID) throws {
        try transaction {
            let rows = try query(
                "SELECT entity_id FROM local_conflicts WHERE id=? AND resolved_at IS NULL",
                [.text(canonical(id))]
            )
            guard case let .text(entityId)? = rows.first?["entity_id"] else { return }
            try run(
                "UPDATE local_conflicts SET resolved_at=? WHERE id=?",
                [.real(Date.now.timeIntervalSince1970), .text(canonical(id))]
            )
            try run(
                """
                UPDATE entities SET sync_state='SYNCED'
                WHERE id=? AND sync_state='CONFLICT'
                  AND NOT EXISTS (
                      SELECT 1 FROM local_conflicts
                      WHERE entity_id=? AND resolved_at IS NULL
                  )
                """,
                [.text(entityId), .text(entityId)]
            )
        }
    }

    public func applyRemote(_ entity: StoredEntity, search: SearchDocument?) throws {
        guard entity.content.count <= 2_097_152 else { throw LocalDatabaseError.payloadTooLarge }
        try transaction {
            try applyRemoteInsideTransaction(entity, search: search)
        }
    }

    public func applyRemotePage(
        _ updates: [RemoteEntityUpdate],
        nextSequence: String
    ) throws {
        guard isValidSequence(nextSequence) else { throw LocalDatabaseError.invalidRow }
        for update in updates {
            guard update.entity.content.count <= 2_097_152 else {
                throw LocalDatabaseError.payloadTooLarge
            }
        }
        try transaction {
            guard compareSequences(nextSequence, try serverSequence()) != .orderedAscending else {
                throw LocalDatabaseError.cursorRegression
            }
            for update in updates {
                try applyRemoteInsideTransaction(update.entity, search: update.search)
            }
            try run(
                "UPDATE sync_cursor SET sequence=? WHERE singleton=1",
                [.text(nextSequence)]
            )
        }
    }

    @discardableResult
    public func hydrateServerConflicts(_ candidates: [HydratedServerConflict]) throws -> Int {
        for candidate in candidates {
            guard candidate.candidateContent.count <= 2_097_152 else {
                throw LocalDatabaseError.payloadTooLarge
            }
        }
        var inserted = 0
        try transaction {
            for candidate in candidates {
                let existing = try query(
                    "SELECT id FROM local_conflicts WHERE server_conflict_id=? LIMIT 1",
                    [.text(canonical(candidate.serverConflictId))]
                )
                if !existing.isEmpty {
                    try run(
                        "UPDATE entities SET sync_state='CONFLICT' WHERE id=?",
                        [.text(canonical(candidate.entityId))]
                    )
                    continue
                }
                try run(
                    """
                    INSERT INTO local_conflicts
                        (id, entity_id, entity_type, parent_id, relation_ids, candidate_content,
                         server_conflict_id, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .text(canonical(UUID())),
                        .text(canonical(candidate.entityId)),
                        .text(candidate.entityType.rawValue),
                        candidate.parentId.map { .text(canonical($0)) } ?? .null,
                        .text(try encodeUUIDs(candidate.relationIds)),
                        .blob(candidate.candidateContent),
                        .text(canonical(candidate.serverConflictId)),
                        .real(candidate.createdAt.timeIntervalSince1970),
                    ]
                )
                try run(
                    "UPDATE entities SET sync_state='CONFLICT' WHERE id=?",
                    [.text(canonical(candidate.entityId))]
                )
                inserted += 1
            }
        }
        return inserted
    }

    public func serverSequence() throws -> String {
        let rows = try query("SELECT sequence FROM sync_cursor WHERE singleton=1")
        if case let .text(value)? = rows.first?["sequence"] { return value }
        return "0"
    }

    public func setServerSequence(_ sequence: String) throws {
        guard isValidSequence(sequence) else {
            throw LocalDatabaseError.invalidRow
        }
        guard compareSequences(sequence, try serverSequence()) != .orderedAscending else {
            throw LocalDatabaseError.cursorRegression
        }
        try run("UPDATE sync_cursor SET sequence=? WHERE singleton=1", [.text(sequence)])
    }

    public func registerLocalAsset(_ asset: LocalAsset) throws {
        try run(
            """
            INSERT INTO local_assets
                (id, dedupe_tag, encrypted_path, encrypted_byte_size, upload_state, last_error_code)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                dedupe_tag=excluded.dedupe_tag,
                encrypted_path=excluded.encrypted_path,
                encrypted_byte_size=excluded.encrypted_byte_size,
                upload_state=excluded.upload_state,
                last_error_code=excluded.last_error_code
            """,
            [
                .text(canonical(asset.id)),
                .text(asset.dedupeTag),
                .text(asset.encryptedFileURL.path),
                .integer(asset.encryptedByteSize),
                .text(asset.uploadState.rawValue),
                asset.lastErrorCode.map(SQLValue.text) ?? .null,
            ]
        )
    }

    public func localAsset(id: UUID) throws -> LocalAsset? {
        try query("SELECT * FROM local_assets WHERE id=?", [.text(canonical(id))])
            .first.map(assetFromRow)
    }

    public func localAsset(dedupeTag: String) throws -> LocalAsset? {
        try query("SELECT * FROM local_assets WHERE dedupe_tag=?", [.text(dedupeTag)])
            .first.map(assetFromRow)
    }

    /// Rolls back only a just-created local asset registration. Callers must separately remove
    /// the owned encrypted file; synchronized asset entities use the normal tombstone path.
    public func unregisterLocalAsset(id: UUID) throws {
        try run("DELETE FROM local_assets WHERE id=?", [.text(canonical(id))])
    }

    public func pendingAssets(limit: Int = 10) throws -> [LocalAsset] {
        try query(
            "SELECT * FROM local_assets WHERE upload_state!='AVAILABLE' ORDER BY id LIMIT ?",
            [.integer(Int64(min(max(limit, 1), 50)))]
        ).map(assetFromRow)
    }

    public func markAssetUploaded(id: UUID) throws {
        try run(
            "UPDATE local_assets SET upload_state='AVAILABLE', last_error_code=NULL WHERE id=?",
            [.text(canonical(id))]
        )
    }

    public func markAssetFailed(id: UUID, code: String) throws {
        try run(
            "UPDATE local_assets SET upload_state='FAILED', last_error_code=? WHERE id=?",
            [.text(code), .text(canonical(id))]
        )
    }

    public func dataHealth() throws -> DataHealthSnapshot {
        let pending = try scalarInteger("SELECT count(*) FROM outbox")
        let conflicts = try scalarInteger(
            "SELECT count(*) FROM local_conflicts WHERE resolved_at IS NULL"
        )
        let assets = try scalarInteger(
            "SELECT count(*) FROM local_assets WHERE upload_state!='AVAILABLE'"
        )
        let integrityRows = try query("PRAGMA cipher_integrity_check")
        let integrity: String
        if let first = integrityRows.first,
           case let .text(value)? = first.values.first
        {
            integrity = value
        } else {
            integrity = "unknown"
        }
        return DataHealthSnapshot(
            pendingMutations: pending,
            unresolvedConflicts: conflicts,
            pendingAssets: assets,
            lastServerSequence: try serverSequence(),
            databaseIntegrity: integrity
        )
    }

    public func checkpoint() throws {
        _ = try query("PRAGMA wal_checkpoint(FULL)")
    }

    private static func migrate(_ database: OpaquePointer, schemaGeneration: Int) throws {
        let migrations = """
        CREATE TABLE IF NOT EXISTS entities (
            id TEXT PRIMARY KEY,
            entity_type TEXT NOT NULL,
            parent_id TEXT,
            relation_ids TEXT NOT NULL,
            content BLOB NOT NULL,
            revision INTEGER NOT NULL DEFAULT 0 CHECK (revision >= 0),
            tombstone INTEGER NOT NULL DEFAULT 0 CHECK (tombstone IN (0, 1)),
            client_modified_at REAL NOT NULL,
            sync_state TEXT NOT NULL CHECK (sync_state IN ('PENDING', 'SYNCED', 'CONFLICT'))
        );
        CREATE INDEX IF NOT EXISTS entities_type_modified
            ON entities(entity_type, client_modified_at DESC);
        CREATE INDEX IF NOT EXISTS entities_parent ON entities(parent_id);

        CREATE TABLE IF NOT EXISTS workspace_summary (
            entity_id TEXT PRIMARY KEY,
            entity_type TEXT NOT NULL,
            parent_id TEXT,
            topic_id TEXT,
            lifecycle_state TEXT NOT NULL,
            pinned_at REAL,
            due_at REAL,
            activity_at REAL NOT NULL,
            FOREIGN KEY(entity_id) REFERENCES entities(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS workspace_summary_type_activity
            ON workspace_summary(entity_type, activity_at DESC);
        CREATE INDEX IF NOT EXISTS workspace_summary_topic_activity
            ON workspace_summary(topic_id, activity_at DESC);
        CREATE INDEX IF NOT EXISTS workspace_summary_due
            ON workspace_summary(due_at ASC) WHERE due_at IS NOT NULL;

        CREATE TABLE IF NOT EXISTS local_projection_state (
            name TEXT PRIMARY KEY,
            is_current INTEGER NOT NULL CHECK (is_current IN (0, 1))
        );
        INSERT OR IGNORE INTO local_projection_state(name, is_current)
            VALUES ('workspace-summary-v1', 0);

        CREATE TABLE IF NOT EXISTS outbox (
            mutation_id TEXT PRIMARY KEY,
            entity_id TEXT NOT NULL UNIQUE,
            entity_type TEXT NOT NULL,
            operation TEXT NOT NULL CHECK (operation IN ('UPSERT', 'DELETE')),
            base_revision INTEGER NOT NULL CHECK (base_revision >= 0),
            parent_id TEXT,
            relation_ids TEXT NOT NULL,
            content BLOB NOT NULL,
            client_modified_at REAL NOT NULL,
            attempt_count INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL,
            FOREIGN KEY(entity_id) REFERENCES entities(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS local_conflicts (
            id TEXT PRIMARY KEY,
            entity_id TEXT NOT NULL,
            entity_type TEXT NOT NULL,
            candidate_content BLOB NOT NULL,
            server_conflict_id TEXT,
            created_at REAL NOT NULL,
            resolved_at REAL
        );

        CREATE TABLE IF NOT EXISTS sync_cursor (
            singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
            sequence TEXT NOT NULL
        );
        INSERT OR IGNORE INTO sync_cursor(singleton, sequence) VALUES (1, '0');

        CREATE TABLE IF NOT EXISTS local_assets (
            id TEXT PRIMARY KEY,
            dedupe_tag TEXT NOT NULL UNIQUE,
            encrypted_path TEXT NOT NULL,
            encrypted_byte_size INTEGER NOT NULL CHECK (encrypted_byte_size > 0),
            upload_state TEXT NOT NULL CHECK (upload_state IN ('PENDING', 'AVAILABLE', 'FAILED')),
            last_error_code TEXT
        );

        CREATE TABLE IF NOT EXISTS processing_jobs (
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            state TEXT NOT NULL,
            input_entity_id TEXT,
            input_revision INTEGER,
            input_fingerprint TEXT NOT NULL,
            required_capabilities TEXT NOT NULL,
            selected_route TEXT,
            compute_node_id TEXT,
            approval BLOB,
            attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
            progress REAL,
            error_code TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS processing_jobs_state_updated
            ON processing_jobs(state, updated_at ASC);
        CREATE INDEX IF NOT EXISTS processing_jobs_compute_node
            ON processing_jobs(compute_node_id, state);

        CREATE VIRTUAL TABLE IF NOT EXISTS search_index USING fts5(
            entity_id UNINDEXED,
            title,
            body,
            tokenize='unicode61 remove_diacritics 2'
        );

        CREATE TABLE IF NOT EXISTS search_segments (
            id TEXT PRIMARY KEY,
            owner_entity_id TEXT NOT NULL,
            source_entity_id TEXT NOT NULL,
            origin TEXT NOT NULL,
            review_state TEXT NOT NULL,
            authority INTEGER NOT NULL CHECK (authority >= 0 AND authority <= 100),
            language TEXT,
            locator BLOB,
            content_revision INTEGER NOT NULL DEFAULT 0 CHECK (content_revision >= 0),
            updated_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS search_segments_owner
            ON search_segments(owner_entity_id, authority DESC, updated_at DESC);
        CREATE INDEX IF NOT EXISTS search_segments_source ON search_segments(source_entity_id);
        CREATE VIRTUAL TABLE IF NOT EXISTS search_segments_fts USING fts5(
            segment_id UNINDEXED,
            title,
            body,
            tokenize='unicode61 remove_diacritics 2'
        );

        CREATE TABLE IF NOT EXISTS search_embeddings (
            entity_id TEXT NOT NULL,
            chunk_index INTEGER NOT NULL CHECK (chunk_index >= 0),
            engine_version INTEGER NOT NULL CHECK (engine_version > 0),
            language TEXT NOT NULL,
            model_revision INTEGER NOT NULL CHECK (model_revision >= 0),
            dimension INTEGER NOT NULL CHECK (dimension > 0),
            vector BLOB NOT NULL,
            snippet TEXT NOT NULL,
            PRIMARY KEY(entity_id, chunk_index),
            FOREIGN KEY(entity_id) REFERENCES entities(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS search_embeddings_model
            ON search_embeddings(language, model_revision, dimension);

        CREATE TABLE IF NOT EXISTS search_embedding_status (
            entity_id TEXT PRIMARY KEY,
            engine_version INTEGER NOT NULL CHECK (engine_version > 0),
            FOREIGN KEY(entity_id) REFERENCES entities(id) ON DELETE CASCADE
        );

        """
        try execute(database, migrations)
        let version = try userVersion(database)
        if version < 2 {
            try execute(
                database,
                """
                ALTER TABLE local_conflicts ADD COLUMN parent_id TEXT;
                ALTER TABLE local_conflicts ADD COLUMN relation_ids TEXT NOT NULL DEFAULT '[]';
                PRAGMA user_version = 2;
                """
            )
        }
        if version < 3 {
            try execute(database, "PRAGMA user_version = 3;")
        }
        if version < 4 {
            try execute(
                database,
                """
                INSERT OR IGNORE INTO search_segments(
                    id, owner_entity_id, source_entity_id, origin, review_state, authority,
                    content_revision, updated_at
                )
                SELECT e.id, e.id, e.id, 'WRITTEN_TEXT', 'AUTHORED', 100,
                       e.revision, e.client_modified_at
                FROM entities e JOIN search_index f ON f.entity_id=e.id
                WHERE e.tombstone=0 AND e.entity_type NOT IN ('AI_ARTIFACT');
                INSERT INTO search_segments_fts(segment_id, title, body)
                SELECT f.entity_id, f.title, f.body
                FROM search_index f JOIN entities e ON e.id=f.entity_id
                WHERE e.tombstone=0 AND e.entity_type NOT IN ('AI_ARTIFACT')
                  AND NOT EXISTS (
                    SELECT 1 FROM search_segments_fts existing
                    WHERE existing.segment_id=f.entity_id
                  );
                """
            )
            try execute(database, "PRAGMA user_version = 4;")
        }
        if schemaGeneration >= 2, version < 5 {
            try execute(database, "PRAGMA user_version = 5;")
        }
        if schemaGeneration >= 2, version < 6 {
            try execute(database, "PRAGMA user_version = 6;")
        }
    }

    private static func userVersion(_ database: OpaquePointer) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
              let statement
        else { throw LocalDatabaseError.queryFailed("could not read local schema version") }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw LocalDatabaseError.queryFailed("could not read local schema version")
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private static func execute(_ database: OpaquePointer, _ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "SQLite execution failed"
            sqlite3_free(errorMessage)
            throw LocalDatabaseError.queryFailed(message)
        }
    }

    private func run(_ sql: String, _ values: [SQLValue] = []) throws {
        let handle = connection.pointer
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw LocalDatabaseError.queryFailed(String(cString: sqlite3_errmsg(handle)))
        }
    }

    private func query(
        _ sql: String,
        _ values: [SQLValue] = []
    ) throws -> [[String: SQLValue]] {
        let handle = connection.pointer
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var rows: [[String: SQLValue]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else {
                throw LocalDatabaseError.queryFailed(String(cString: sqlite3_errmsg(handle)))
            }
            var row: [String: SQLValue] = [:]
            for index in 0 ..< sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER:
                    row[name] = .integer(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT:
                    row[name] = .real(sqlite3_column_double(statement, index))
                case SQLITE_TEXT:
                    row[name] = .text(String(cString: sqlite3_column_text(statement, index)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, index))
                    if count == 0 {
                        row[name] = .blob(Data())
                    } else if let bytes = sqlite3_column_blob(statement, index) {
                        row[name] = .blob(Data(bytes: bytes, count: count))
                    } else {
                        throw LocalDatabaseError.invalidRow
                    }
                case SQLITE_NULL:
                    row[name] = .null
                default:
                    throw LocalDatabaseError.invalidRow
                }
            }
            rows.append(row)
        }
    }

    private func prepare(_ sql: String, _ values: [SQLValue]) throws -> OpaquePointer {
        let handle = connection.pointer
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw LocalDatabaseError.queryFailed(String(cString: sqlite3_errmsg(handle)))
        }
        do {
            for (offset, value) in values.enumerated() {
                try bind(value, to: statement, index: Int32(offset + 1))
            }
        } catch {
            sqlite3_finalize(statement)
            throw error
        }
        return statement
    }

    private func bind(_ value: SQLValue, to statement: OpaquePointer, index: Int32) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let result: Int32
        switch value {
        case let .text(text):
            result = sqlite3_bind_text(statement, index, text, -1, transient)
        case let .integer(integer):
            result = sqlite3_bind_int64(statement, index, integer)
        case let .real(double):
            result = sqlite3_bind_double(statement, index, double)
        case let .blob(data):
            result = data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(data.count), transient)
            }
        case .null:
            result = sqlite3_bind_null(statement, index)
        }
        guard result == SQLITE_OK else {
            throw LocalDatabaseError.queryFailed("failed to bind SQLite value")
        }
    }

    private func transaction(_ body: () throws -> Void) throws {
        try run("BEGIN IMMEDIATE")
        do {
            try body()
            try run("COMMIT")
        } catch {
            try? run("ROLLBACK")
            throw error
        }
    }

    @discardableResult
    private func updateSearch(
        id: UUID,
        entityType: EntityType,
        document: SearchDocument?,
        projection: SearchProjectionWrite? = nil,
        modifiedAt: Date,
        rebuildOwners: Bool = true
    ) throws -> Set<String> {
        let entityId = canonical(id)
        let previousOwners = try query(
            "SELECT DISTINCT owner_entity_id FROM search_segments WHERE source_entity_id=?",
            [.text(projection.map { canonical($0.sourceEntityId) } ?? entityId)]
        ).compactMap { row -> String? in
            guard case let .text(value) = row["owner_entity_id"] else { return nil }
            return value
        }
        let resolvedProjection: SearchProjectionWrite
        if let projection {
            resolvedProjection = projection
        } else {
            let segment = document.map {
                SearchSegmentWrite(
                    id: id,
                    ownerEntityId: id,
                    sourceEntityId: id,
                    origin: Self.defaultSearchOrigin(for: entityType),
                    reviewState: .authored,
                    authority: Self.defaultSearchAuthority(for: entityType),
                    title: $0.title,
                    body: $0.body,
                    updatedAt: modifiedAt
                )
            }
            resolvedProjection = SearchProjectionWrite(
                sourceEntityId: id,
                segments: segment.map { [$0] } ?? []
            )
        }
        try replaceSearchProjectionInsideTransaction(resolvedProjection)
        let currentOwners = Set(resolvedProjection.segments.map { canonical($0.ownerEntityId) })
        let affectedOwners = Set(previousOwners).union(currentOwners)
        if rebuildOwners {
            for owner in affectedOwners.sorted() {
                try rebuildOwnerSearchDocument(ownerEntityId: owner)
            }
        }
        return affectedOwners
    }

    private func replaceSearchProjectionInsideTransaction(_ projection: SearchProjectionWrite) throws {
        let sourceId = canonical(projection.sourceEntityId)
        let prior = try query(
            "SELECT id FROM search_segments WHERE source_entity_id=?",
            [.text(sourceId)]
        ).compactMap { row -> String? in
            guard case let .text(value) = row["id"] else { return nil }
            return value
        }
        for segmentId in prior {
            try run("DELETE FROM search_segments_fts WHERE segment_id=?", [.text(segmentId)])
        }
        try run("DELETE FROM search_segments WHERE source_entity_id=?", [.text(sourceId)])
        for segment in projection.segments where !segment.title.isEmpty || !segment.body.isEmpty {
            guard segment.sourceEntityId == projection.sourceEntityId else {
                throw LocalDatabaseError.invalidRow
            }
            let locator = try segment.locator.map(CanonicalJSON.encode)
            let segmentId = canonical(segment.id)
            try run(
                """
                INSERT INTO search_segments(
                    id, owner_entity_id, source_entity_id, origin, review_state, authority,
                    language, locator, content_revision, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(segmentId), .text(canonical(segment.ownerEntityId)), .text(sourceId),
                    .text(segment.origin.rawValue), .text(segment.reviewState.rawValue),
                    .integer(Int64(segment.authority)), segment.language.map(SQLValue.text) ?? .null,
                    locator.map(SQLValue.blob) ?? .null,
                    .integer(Int64(segment.contentRevision)),
                    .real(segment.updatedAt.timeIntervalSince1970),
                ]
            )
            try run(
                "INSERT INTO search_segments_fts(segment_id, title, body) VALUES (?, ?, ?)",
                [.text(segmentId), .text(segment.title), .text(segment.body)]
            )
        }
    }

    private func rebuildOwnerSearchDocument(ownerEntityId: String) throws {
        try run("DELETE FROM search_index WHERE entity_id=?", [.text(ownerEntityId)])
        try run("DELETE FROM search_embeddings WHERE entity_id=?", [.text(ownerEntityId)])
        try run("DELETE FROM search_embedding_status WHERE entity_id=?", [.text(ownerEntityId)])
        let rows = try query(
            """
            SELECT f.title AS segment_title, f.body AS segment_body
            FROM search_segments s JOIN search_segments_fts f ON f.segment_id=s.id
            WHERE s.owner_entity_id=?
            ORDER BY s.authority DESC, s.updated_at DESC, s.id ASC
            """,
            [.text(ownerEntityId)]
        )
        let titles = rows.compactMap { row -> String? in
            guard case let .text(value) = row["segment_title"], !value.isEmpty else { return nil }
            return value
        }
        let bodies = rows.compactMap { row -> String? in
            guard case let .text(value) = row["segment_body"], !value.isEmpty else { return nil }
            return value
        }
        guard !titles.isEmpty || !bodies.isEmpty else { return }
        try run(
            "INSERT INTO search_index(entity_id, title, body) VALUES (?, ?, ?)",
            [.text(ownerEntityId), .text(titles.joined(separator: "\n")), .text(bodies.joined(separator: "\n"))]
        )
    }

    private static func defaultSearchOrigin(for entityType: EntityType) -> SearchSegmentOrigin {
        switch entityType {
        case .source, .sourceVersion: .sourceExtraction
        case .transcriptCorrection: .transcript
        case .evidence: .evidence
        default: .writtenText
        }
    }

    private static func defaultSearchAuthority(for entityType: EntityType) -> Int {
        switch entityType {
        case .source, .sourceVersion, .transcriptCorrection: 70
        default: 100
        }
    }

    private func replaceSemanticSearch(
        entityId: String,
        document: SearchDocument
    ) throws -> Bool {
        try run("DELETE FROM search_embeddings WHERE entity_id=?", [.text(entityId)])
        try run("DELETE FROM search_embedding_status WHERE entity_id=?", [.text(entityId)])
        var inserted = 0
        for (index, chunk) in LocalSemanticSearch.chunks(for: document).enumerated() {
            guard let model = semanticEmbeddingProvider.model(for: chunk.text),
                  let rawVector = semanticEmbeddingProvider.vector(for: chunk.text, model: model),
                  let vector = LocalSemanticSearch.normalized(rawVector),
                  vector.count == model.dimension
            else { continue }
            try run(
                """
                INSERT INTO search_embeddings(
                    entity_id, chunk_index, engine_version, language, model_revision,
                    dimension, vector, snippet
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(entityId),
                    .integer(Int64(index)),
                    .integer(Int64(LocalSemanticSearch.engineVersion)),
                    .text(model.language),
                    .integer(Int64(model.revision)),
                    .integer(Int64(model.dimension)),
                    .blob(LocalSemanticSearch.encode(vector)),
                    .text(chunk.snippet),
                ]
            )
            inserted += 1
        }
        try run(
            "INSERT OR REPLACE INTO search_embedding_status(entity_id, engine_version) VALUES (?, ?)",
            [
                .text(entityId),
                .integer(Int64(LocalSemanticSearch.engineVersion)),
            ]
        )
        return inserted > 0
    }

    private func relatedSearchHits(
        _ text: String,
        excluding exactIds: Set<UUID>,
        entityTypes: [EntityType],
        limit: Int
    ) throws -> [SearchHit] {
        guard limit > 0 else { return [] }
        var scopeSQL = ""
        var values: [SQLValue] = [.integer(Int64(LocalSemanticSearch.engineVersion))]
        if !entityTypes.isEmpty {
            let placeholders = Array(repeating: "?", count: entityTypes.count)
                .joined(separator: ",")
            scopeSQL = " AND e.entity_type IN (\(placeholders))"
            values += entityTypes.map { .text($0.rawValue) }
        }
        let rows = try query(
            """
            SELECT e.*, search_embeddings.language AS semantic_language,
                   search_embeddings.model_revision AS semantic_revision,
                   search_embeddings.dimension AS semantic_dimension,
                   search_embeddings.vector AS semantic_vector,
                   search_embeddings.snippet AS semantic_snippet
            FROM search_embeddings
            JOIN entities e ON e.id = search_embeddings.entity_id
            WHERE search_embeddings.engine_version=? AND e.tombstone=0\(scopeSQL)
            """,
            values
        )
        var queryVectors: [LocalSemanticEmbeddingModel: [Float]] = [:]
        var unavailableModels: Set<LocalSemanticEmbeddingModel> = []
        var bestByEntity: [UUID: SearchHit] = [:]
        for row in rows {
            guard let entity = try? entityFromRow(row), !exactIds.contains(entity.id),
                  case let .text(language) = row["semantic_language"],
                  case let .integer(rawRevision) = row["semantic_revision"],
                  case let .integer(rawDimension) = row["semantic_dimension"],
                  case let .blob(data) = row["semantic_vector"],
                  case let .text(snippet) = row["semantic_snippet"],
                  rawRevision >= 0, rawDimension > 0,
                  rawRevision <= Int64(Int.max), rawDimension <= Int64(Int.max)
            else { continue }
            let model = LocalSemanticEmbeddingModel(
                language: language,
                revision: Int(rawRevision),
                dimension: Int(rawDimension)
            )
            let queryVector: [Float]
            if let cached = queryVectors[model] {
                queryVector = cached
            } else {
                guard !unavailableModels.contains(model),
                      let raw = semanticEmbeddingProvider.vector(for: text, model: model),
                      let normalized = LocalSemanticSearch.normalized(raw),
                      normalized.count == model.dimension
                else {
                    unavailableModels.insert(model)
                    continue
                }
                queryVectors[model] = normalized
                queryVector = normalized
            }
            guard let documentVector = LocalSemanticSearch.decode(
                data,
                dimension: model.dimension
            ), let similarity = LocalSemanticSearch.similarity(queryVector, documentVector),
               similarity >= LocalSemanticSearch.minimumSimilarity
            else { continue }
            let hit = SearchHit(
                entity: entity,
                snippet: snippet,
                matchKind: .related,
                relevance: similarity
            )
            if similarity > (bestByEntity[entity.id]?.relevance ?? -.infinity) {
                bestByEntity[entity.id] = hit
            }
        }
        return bestByEntity.values.sorted { left, right in
            let leftScore = left.relevance ?? -.infinity
            let rightScore = right.relevance ?? -.infinity
            if leftScore != rightScore { return leftScore > rightScore }
            if left.entity.clientModifiedAt != right.entity.clientModifiedAt {
                return left.entity.clientModifiedAt > right.entity.clientModifiedAt
            }
            return left.id.uuidString < right.id.uuidString
        }.prefix(limit).map(\ .self)
    }

    private func applyRemoteInsideTransaction(
        _ entity: StoredEntity,
        search: SearchDocument?
    ) throws {
        guard entity.revision >= 0 else { throw LocalDatabaseError.invalidRow }
        if let current = try self.entity(id: entity.id),
           current.revision >= entity.revision
        {
            return
        }
        let pending = try query(
            "SELECT * FROM outbox WHERE entity_id=? LIMIT 1",
            [.text(canonical(entity.id))]
        )
        if let row = pending.first {
            let mutation = try mutationFromRow(row)
            try run(
                """
                INSERT INTO local_conflicts
                    (id, entity_id, entity_type, parent_id, relation_ids, candidate_content,
                     created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(canonical(UUID())),
                    .text(canonical(entity.id)),
                    .text(entity.entityType.rawValue),
                    mutation.parentId.map { .text(canonical($0)) } ?? .null,
                    .text(try encodeUUIDs(mutation.relationIds)),
                    .blob(mutation.content),
                    .real(Date.now.timeIntervalSince1970),
                ]
            )
            try run("DELETE FROM outbox WHERE entity_id=?", [.text(canonical(entity.id))])
        }
        let hasUnresolvedConflict = try !query(
            "SELECT id FROM local_conflicts WHERE entity_id=? AND resolved_at IS NULL LIMIT 1",
            [.text(canonical(entity.id))]
        ).isEmpty
        try run(
            """
            INSERT INTO entities
                (id, entity_type, parent_id, relation_ids, content, revision, tombstone,
                 client_modified_at, sync_state)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                entity_type=excluded.entity_type,
                parent_id=excluded.parent_id,
                relation_ids=excluded.relation_ids,
                content=excluded.content,
                revision=excluded.revision,
                tombstone=excluded.tombstone,
                client_modified_at=excluded.client_modified_at,
                sync_state=excluded.sync_state
            """,
            [
                .text(canonical(entity.id)),
                .text(entity.entityType.rawValue),
                entity.parentId.map { .text(canonical($0)) } ?? .null,
                .text(try encodeUUIDs(entity.relationIds)),
                .blob(entity.content),
                .integer(Int64(entity.revision)),
                .integer(entity.tombstone ? 1 : 0),
                .real(entity.clientModifiedAt.timeIntervalSince1970),
                .text(hasUnresolvedConflict ? LocalSyncState.conflict.rawValue : LocalSyncState.synced.rawValue),
            ]
        )
        try updateSearch(
            id: entity.id,
            entityType: entity.entityType,
            document: entity.tombstone ? nil : search,
            modifiedAt: entity.clientModifiedAt
        )
        try updateWorkspaceSummary(
            id: entity.id,
            entityType: entity.entityType,
            parentId: entity.parentId,
            content: entity.content,
            tombstone: entity.tombstone,
            modifiedAt: entity.clientModifiedAt
        )
    }

    private func entitiesPageInsideSnapshot(
        type: EntityType,
        parentId: UUID?,
        includeTombstones: Bool,
        limit: Int,
        after cursor: EntityPageCursor?
    ) throws -> StoredEntityPage {
        let boundedLimit = min(max(limit, 1), 200)
        var sql = "SELECT * FROM entities WHERE entity_type=?"
        var values: [SQLValue] = [.text(type.rawValue)]
        if let parentId {
            sql += " AND parent_id=?"
            values.append(.text(canonical(parentId)))
        }
        if !includeTombstones { sql += " AND tombstone=0" }
        sql += " AND NOT EXISTS (SELECT 1 FROM workspace_summary trash WHERE trash.entity_type='TRASH_ENTRY' AND trash.parent_id=entities.id)"
        if let cursor {
            sql += " AND (client_modified_at < ? OR (client_modified_at = ? AND id > ?))"
            values.append(.real(cursor.modifiedAt.timeIntervalSince1970))
            values.append(.real(cursor.modifiedAt.timeIntervalSince1970))
            values.append(.text(canonical(cursor.entityId)))
        }
        sql += " ORDER BY client_modified_at DESC, id ASC LIMIT ?"
        values.append(.integer(Int64(boundedLimit + 1)))
        let decoded = try query(sql, values).map(entityFromRow)
        let hasMore = decoded.count > boundedLimit
        let pageEntities = Array(decoded.prefix(boundedLimit))
        let nextCursor: EntityPageCursor?
        if hasMore, let last = pageEntities.last {
            nextCursor = EntityPageCursor(modifiedAt: last.clientModifiedAt, entityId: last.id)
        } else {
            nextCursor = nil
        }
        return StoredEntityPage(entities: pageEntities, nextCursor: nextCursor)
    }

    private func updateWorkspaceSummary(
        id: UUID,
        entityType: EntityType,
        parentId: UUID?,
        content: Data,
        tombstone: Bool,
        modifiedAt: Date
    ) throws {
        guard !tombstone,
              let record = WorkspaceSummaryIndexer.record(
                id: id,
                entityType: entityType,
                parentId: parentId,
                content: content,
                modifiedAt: modifiedAt
              )
        else {
            try run("DELETE FROM workspace_summary WHERE entity_id=?", [.text(canonical(id))])
            return
        }
        try run(
            """
            INSERT INTO workspace_summary(
                entity_id, entity_type, parent_id, topic_id, lifecycle_state,
                pinned_at, due_at, activity_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(entity_id) DO UPDATE SET
                entity_type=excluded.entity_type,
                parent_id=excluded.parent_id,
                topic_id=excluded.topic_id,
                lifecycle_state=excluded.lifecycle_state,
                pinned_at=excluded.pinned_at,
                due_at=excluded.due_at,
                activity_at=excluded.activity_at
            """,
            [
                .text(canonical(record.id)),
                .text(record.entityType.rawValue),
                record.parentId.map { .text(canonical($0)) } ?? .null,
                record.topicId.map { .text(canonical($0)) } ?? .null,
                .text(record.lifecycleState),
                record.pinnedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                record.dueAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                .real(record.activityAt.timeIntervalSince1970),
            ]
        )
    }

    private func workspaceSummaryFromRow(_ row: [String: SQLValue]) throws -> WorkspaceSummaryRecord {
        guard case let .text(idRaw) = row["entity_id"],
              let id = UUID(uuidString: idRaw),
              case let .text(typeRaw) = row["entity_type"],
              let entityType = EntityType(rawValue: typeRaw),
              case let .text(lifecycleState) = row["lifecycle_state"],
              case let .real(activityRaw) = row["activity_at"],
              activityRaw.isFinite
        else { throw LocalDatabaseError.invalidRow }
        func optionalUUID(_ key: String) throws -> UUID? {
            guard let value = row[key] else { throw LocalDatabaseError.invalidRow }
            switch value {
            case .null: return nil
            case let .text(raw):
                guard let value = UUID(uuidString: raw) else { throw LocalDatabaseError.invalidRow }
                return value
            default: throw LocalDatabaseError.invalidRow
            }
        }
        func optionalDate(_ key: String) throws -> Date? {
            guard let value = row[key] else { throw LocalDatabaseError.invalidRow }
            switch value {
            case .null: return nil
            case let .real(raw):
                guard raw.isFinite else { throw LocalDatabaseError.invalidRow }
                return Date(timeIntervalSince1970: raw)
            default: throw LocalDatabaseError.invalidRow
            }
        }
        return WorkspaceSummaryRecord(
            id: id,
            entityType: entityType,
            parentId: try optionalUUID("parent_id"),
            topicId: try optionalUUID("topic_id"),
            lifecycleState: lifecycleState,
            pinnedAt: try optionalDate("pinned_at"),
            dueAt: try optionalDate("due_at"),
            activityAt: Date(timeIntervalSince1970: activityRaw)
        )
    }

    private func isValidSequence(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0 >= "0" && $0 <= "9" }
    }

    private func compareSequences(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let normalizedLeft = String(lhs.drop { $0 == "0" })
        let normalizedRight = String(rhs.drop { $0 == "0" })
        let left = normalizedLeft.isEmpty ? "0" : normalizedLeft
        let right = normalizedRight.isEmpty ? "0" : normalizedRight
        if left.count != right.count {
            return left.count < right.count ? .orderedAscending : .orderedDescending
        }
        if left == right { return .orderedSame }
        return left < right ? .orderedAscending : .orderedDescending
    }

    private func processingJobFromRow(_ row: [String: SQLValue]) throws -> ProcessingJob {
        guard case let .text(idRaw) = row["id"], let id = UUID(uuidString: idRaw),
              case let .text(kind) = row["kind"],
              case let .text(stateRaw) = row["state"], let state = ProcessingJobState(rawValue: stateRaw),
              case let .text(fingerprint) = row["input_fingerprint"],
              case let .text(capabilitiesRaw) = row["required_capabilities"],
              let capabilitiesData = capabilitiesRaw.data(using: .utf8),
              let capabilities = try? JSONDecoder().decode([ProcessingCapability].self, from: capabilitiesData),
              case let .integer(attemptRaw) = row["attempt_count"], attemptRaw >= 0,
              case let .real(createdRaw) = row["created_at"], createdRaw.isFinite,
              case let .real(updatedRaw) = row["updated_at"], updatedRaw.isFinite
        else { throw LocalDatabaseError.invalidRow }
        let inputEntityId: UUID?
        if case let .text(raw) = row["input_entity_id"] {
            guard let parsed = UUID(uuidString: raw) else { throw LocalDatabaseError.invalidRow }
            inputEntityId = parsed
        } else { inputEntityId = nil }
        let inputRevision: Int?
        if case let .integer(raw) = row["input_revision"], raw >= 0, raw <= Int64(Int.max) {
            inputRevision = Int(raw)
        } else { inputRevision = nil }
        let selectedRoute: ProcessingRoute?
        if case let .text(raw) = row["selected_route"] {
            guard let parsed = ProcessingRoute(rawValue: raw) else { throw LocalDatabaseError.invalidRow }
            selectedRoute = parsed
        } else { selectedRoute = nil }
        let computeNodeId: UUID?
        if case let .text(raw) = row["compute_node_id"] {
            guard let parsed = UUID(uuidString: raw) else { throw LocalDatabaseError.invalidRow }
            computeNodeId = parsed
        } else { computeNodeId = nil }
        let approval: ProcessingApproval?
        if case let .blob(data) = row["approval"] {
            approval = try CanonicalJSON.decode(ProcessingApproval.self, from: data)
        } else { approval = nil }
        let progress: Double?
        if case let .real(raw) = row["progress"], raw.isFinite, (0 ... 1).contains(raw) {
            progress = raw
        } else { progress = nil }
        let errorCode: String?
        if case let .text(raw) = row["error_code"] { errorCode = raw } else { errorCode = nil }
        return ProcessingJob(
            id: id,
            kind: kind,
            state: state,
            inputEntityId: inputEntityId,
            inputRevision: inputRevision,
            inputFingerprint: fingerprint,
            requiredCapabilities: capabilities,
            selectedRoute: selectedRoute,
            computeNodeId: computeNodeId,
            approval: approval,
            attemptCount: Int(attemptRaw),
            progress: progress,
            errorCode: errorCode,
            createdAt: Date(timeIntervalSince1970: createdRaw),
            updatedAt: Date(timeIntervalSince1970: updatedRaw)
        )
    }

    private func entityFromRow(_ row: [String: SQLValue]) throws -> StoredEntity {
        guard case let .text(id) = row["id"],
              case let .text(entityType) = row["entity_type"],
              case let .text(relations) = row["relation_ids"],
              case let .blob(content) = row["content"],
              case let .integer(revision) = row["revision"],
              case let .integer(tombstone) = row["tombstone"],
              case let .real(modifiedAt) = row["client_modified_at"],
              case let .text(syncState) = row["sync_state"],
              let parsedId = UUID(uuidString: id),
              let parsedType = EntityType(rawValue: entityType),
              let parsedState = LocalSyncState(rawValue: syncState)
        else { throw LocalDatabaseError.invalidRow }
        let parentId: UUID?
        if case let .text(parent)? = row["parent_id"] {
            parentId = UUID(uuidString: parent)
        } else {
            parentId = nil
        }
        return StoredEntity(
            id: parsedId,
            entityType: parsedType,
            parentId: parentId,
            relationIds: try decodeUUIDs(relations),
            content: content,
            revision: Int(revision),
            tombstone: tombstone == 1,
            clientModifiedAt: Date(timeIntervalSince1970: modifiedAt),
            syncState: parsedState
        )
    }

    private func mutationFromRow(_ row: [String: SQLValue]) throws -> PendingMutation {
        guard case let .text(mutationId) = row["mutation_id"],
              case let .text(entityId) = row["entity_id"],
              case let .text(entityType) = row["entity_type"],
              case let .text(operation) = row["operation"],
              case let .integer(baseRevision) = row["base_revision"],
              case let .text(relations) = row["relation_ids"],
              case let .blob(content) = row["content"],
              case let .real(modifiedAt) = row["client_modified_at"],
              case let .integer(attempts) = row["attempt_count"],
              let parsedMutationId = UUID(uuidString: mutationId),
              let parsedEntityId = UUID(uuidString: entityId),
              let parsedType = EntityType(rawValue: entityType),
              let parsedOperation = MutationOperation(rawValue: operation)
        else { throw LocalDatabaseError.invalidRow }
        let parentId: UUID?
        if case let .text(parent)? = row["parent_id"] {
            parentId = UUID(uuidString: parent)
        } else {
            parentId = nil
        }
        return PendingMutation(
            mutationId: parsedMutationId,
            entityId: parsedEntityId,
            entityType: parsedType,
            operation: parsedOperation,
            baseRevision: Int(baseRevision),
            parentId: parentId,
            relationIds: try decodeUUIDs(relations),
            content: content,
            clientModifiedAt: Date(timeIntervalSince1970: modifiedAt),
            attemptCount: Int(attempts)
        )
    }

    private func assetFromRow(_ row: [String: SQLValue]) throws -> LocalAsset {
        guard case let .text(id) = row["id"],
              case let .text(tag) = row["dedupe_tag"],
              case let .text(path) = row["encrypted_path"],
              case let .integer(size) = row["encrypted_byte_size"],
              case let .text(state) = row["upload_state"],
              let parsedId = UUID(uuidString: id),
              let parsedState = LocalAssetUploadState(rawValue: state)
        else { throw LocalDatabaseError.invalidRow }
        let errorCode: String?
        if case let .text(code)? = row["last_error_code"] {
            errorCode = code
        } else {
            errorCode = nil
        }
        return LocalAsset(
            id: parsedId,
            dedupeTag: tag,
            encryptedFileURL: URL(fileURLWithPath: path),
            encryptedByteSize: size,
            uploadState: parsedState,
            lastErrorCode: errorCode
        )
    }

    private func scalarInteger(_ sql: String) throws -> Int {
        guard let first = try query(sql).first,
              case let .integer(value)? = first.values.first
        else { throw LocalDatabaseError.invalidRow }
        return Int(value)
    }

    private func encodeUUIDs(_ values: [UUID]) throws -> String {
        let data = try JSONEncoder().encode(values.map(canonical))
        guard let string = String(data: data, encoding: .utf8) else {
            throw LocalDatabaseError.invalidRow
        }
        return string
    }

    private func decodeUUIDs(_ value: String) throws -> [UUID] {
        let strings = try JSONDecoder().decode([String].self, from: Data(value.utf8))
        let values = strings.compactMap(UUID.init(uuidString:))
        guard values.count == strings.count else { throw LocalDatabaseError.invalidRow }
        return values
    }

    private func canonical(_ value: UUID) -> String {
        value.uuidString.lowercased()
    }

    private static func applyFileProtection(_ url: URL) {
        #if os(iOS)
        let manager = FileManager.default
        for target in [url, URL(fileURLWithPath: url.path + "-wal"), URL(fileURLWithPath: url.path + "-shm")] {
            guard manager.fileExists(atPath: target.path) else { continue }
            try? manager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: target.path)
        }
        #endif
    }
}
