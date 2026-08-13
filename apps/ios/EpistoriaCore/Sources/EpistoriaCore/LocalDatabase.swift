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

public struct SearchHit: Equatable, Sendable, Identifiable {
    public var id: UUID { entity.id }
    public var entity: StoredEntity
    public var snippet: String
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
}

public struct DataHealthSnapshot: Equatable, Sendable {
    public var pendingMutations: Int
    public var unresolvedConflicts: Int
    public var pendingAssets: Int
    public var lastServerSequence: String
    public var databaseIntegrity: String
}

public enum LocalDatabaseError: Error, Equatable {
    case openFailed(String)
    case keyRejected
    case queryFailed(String)
    case invalidRow
    case payloadTooLarge
    case cursorRegression
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
    public nonisolated let url: URL

    public init(url: URL, key: Data) throws {
        guard key.count == 32 else { throw LocalDatabaseError.keyRejected }
        self.url = url
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
            try Self.execute(database, "PRAGMA cipher_memory_security = ON")
            try Self.execute(database, "PRAGMA foreign_keys = ON")
            try Self.execute(database, "PRAGMA secure_delete = ON")
            try Self.execute(database, "PRAGMA journal_mode = WAL")
            try Self.execute(database, "PRAGMA synchronous = FULL")
            try Self.execute(database, "PRAGMA temp_store = MEMORY")
            try Self.migrate(database)
            Self.applyFileProtection(url)
            connection = SQLCipherConnection(database)
        } catch {
            sqlite3_close(database)
            if case LocalDatabaseError.queryFailed = error {
                throw LocalDatabaseError.keyRejected
            }
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
            try updateSearch(id: id, document: search)
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

    public func search(_ text: String, limit: Int = 50) throws -> [SearchHit] {
        let tokens = text
            .split { !$0.isLetter && !$0.isNumber }
            .prefix(12)
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }
        guard !tokens.isEmpty else { return [] }
        let expression = tokens.joined(separator: " AND ")
        let rows = try query(
            """
            SELECT e.*, snippet(search_index, 2, '[', ']', '…', 18) AS result_snippet
            FROM search_index JOIN entities e ON e.id = search_index.entity_id
            WHERE search_index MATCH ? AND e.tombstone=0
            ORDER BY bm25(search_index), e.client_modified_at DESC
            LIMIT ?
            """,
            [.text(expression), .integer(Int64(min(max(limit, 1), 200)))]
        )
        return try rows.map { row in
            guard case let .text(snippet) = row["result_snippet"] else {
                throw LocalDatabaseError.invalidRow
            }
            return SearchHit(entity: try entityFromRow(row), snippet: snippet)
        }
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

    private static func migrate(_ database: OpaquePointer) throws {
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

        CREATE VIRTUAL TABLE IF NOT EXISTS search_index USING fts5(
            entity_id UNINDEXED,
            title,
            body,
            tokenize='unicode61 remove_diacritics 2'
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

    private func updateSearch(id: UUID, document: SearchDocument?) throws {
        try run("DELETE FROM search_index WHERE entity_id=?", [.text(canonical(id))])
        if let document {
            try run(
                "INSERT INTO search_index(entity_id, title, body) VALUES (?, ?, ?)",
                [.text(canonical(id)), .text(document.title), .text(document.body)]
            )
        }
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
        try updateSearch(id: entity.id, document: entity.tombstone ? nil : search)
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
