import Foundation

public struct SyncReport: Equatable, Sendable {
    public var uploadedAssets: Int = 0
    public var pushedMutations: Int = 0
    public var conflictsCreated: Int = 0
    public var conflictsHydrated: Int = 0
    public var pulledChanges: Int = 0
    public var finalSequence: String = "0"

    public init() {}
}

public enum SyncEngineError: Error, Equatable {
    case missingRevision
    case missingConflictId
    case invalidTimestamp
    case deduplicatedAssetIdentityMismatch
    case unsupportedWireVersion
    case invalidSequence
    case conflictPayloadTooLarge
    case invalidPushResponse
    case unsupportedEntitySchema
}

public actor SyncEngine {
    private let accountId: UUID
    private let accountKey: Data
    private let database: SQLCipherDatabase
    private let api: EpistoriaAPIClient
    private let crypto = EntityCrypto()

    public init(
        accountId: UUID,
        accountKey: Data,
        database: SQLCipherDatabase,
        api: EpistoriaAPIClient
    ) {
        self.accountId = accountId
        self.accountKey = accountKey
        self.database = database
        self.api = api
    }

    public func synchronize() async throws -> SyncReport {
        var report = SyncReport()
        try await uploadPendingAssets(report: &report)
        try await pushPendingMutations(report: &report)
        try await pullRemoteChanges(report: &report)
        try await hydrateServerConflicts(report: &report)
        report.finalSequence = try await database.serverSequence()
        return report
    }

    private func uploadPendingAssets(report: inout SyncReport) async throws {
        while true {
            let pending = try await database.pendingAssets(limit: 10)
            guard !pending.isEmpty else { return }
            var madeProgress = false
            for asset in pending {
                let prepared = try await api.prepareAsset(asset)
                guard prepared.assetId == asset.id else {
                    try await database.markAssetFailed(
                        id: asset.id,
                        code: "DEDUPLICATED_ASSET_ID_MISMATCH"
                    )
                    throw SyncEngineError.deduplicatedAssetIdentityMismatch
                }
                if prepared.state == "AVAILABLE" {
                    try await database.markAssetUploaded(id: asset.id)
                    madeProgress = true
                    continue
                }
                guard let upload = prepared.upload else {
                    try await database.markAssetFailed(id: asset.id, code: "UPLOAD_DESCRIPTOR_MISSING")
                    continue
                }
                let encrypted = try Data(contentsOf: asset.encryptedFileURL, options: .mappedIfSafe)
                try await api.uploadAsset(data: encrypted, prepared: upload)
                _ = try await api.confirmAsset(id: asset.id, byteSize: asset.encryptedByteSize)
                try await database.markAssetUploaded(id: asset.id)
                report.uploadedAssets += 1
                madeProgress = true
            }
            if !madeProgress { return }
        }
    }

    private func pushPendingMutations(report: inout SyncReport) async throws {
        while true {
            let pending = try await database.pendingMutations(limit: 100)
            guard !pending.isEmpty else { return }
            let wire = try pending.map { mutation in
                var envelope = try crypto.encryptEntity(
                    mutation.content,
                    accountKey: accountKey,
                    accountId: accountId,
                    entityType: mutation.entityType,
                    entityId: mutation.entityId,
                    contentVersion: 1
                )
                if mutation.entityType == .asset,
                   let payload = try? CanonicalJSON.decode(AssetPayload.self, from: mutation.content)
                {
                    envelope.dedupeTag = payload.dedupeTag
                }
                return SyncMutationWire(
                    mutationId: mutation.mutationId,
                    entityId: mutation.entityId,
                    entityType: mutation.entityType,
                    operation: mutation.operation,
                    baseRevision: mutation.baseRevision,
                    parentId: mutation.parentId,
                    relationIds: mutation.relationIds,
                    clientModifiedAt: RFC3339Milliseconds.string(from: mutation.clientModifiedAt),
                    envelope: envelope
                )
            }
            let response = try await api.push(wire)
            guard response.wireVersion == 1 else {
                throw SyncEngineError.unsupportedWireVersion
            }
            guard isValidSequence(response.serverSequence) else {
                throw SyncEngineError.invalidSequence
            }
            let pendingByMutationId = Dictionary(
                uniqueKeysWithValues: pending.map { ($0.mutationId, $0) }
            )
            guard response.results.count == pending.count,
                  Set(response.results.map(\.mutationId)) == Set(pendingByMutationId.keys)
            else { throw SyncEngineError.invalidPushResponse }
            for result in response.results {
                guard let mutation = pendingByMutationId[result.mutationId],
                      result.entityId == mutation.entityId
                else { throw SyncEngineError.invalidPushResponse }
                switch result.status {
                case .accepted:
                    guard let revision = result.revision,
                          revision == mutation.baseRevision + 1
                    else {
                        throw SyncEngineError.missingRevision
                    }
                    try await database.markAccepted(
                        mutationId: result.mutationId,
                        revision: revision
                    )
                    report.pushedMutations += 1
                case .conflict:
                    guard let conflictId = result.conflictId else {
                        throw SyncEngineError.missingConflictId
                    }
                    try await database.markConflict(
                        mutationId: result.mutationId,
                        serverConflictId: conflictId
                    )
                    report.conflictsCreated += 1
                }
            }
        }
    }

    private func pullRemoteChanges(report: inout SyncReport) async throws {
        var cursor = try await database.serverSequence()
        while true {
            let response = try await api.pull(after: cursor)
            guard response.wireVersion == 1 else {
                throw SyncEngineError.unsupportedWireVersion
            }
            try validatePullPage(response, after: cursor)
            var updates: [RemoteEntityUpdate] = []
            updates.reserveCapacity(response.changes.count)
            for change in response.changes {
                guard (0 ... 2_097_152).contains(change.envelope.payloadSize) else {
                    throw SyncEngineError.conflictPayloadTooLarge
                }
                guard let modifiedAt = RFC3339Milliseconds.date(from: change.clientModifiedAt) else {
                    throw SyncEngineError.invalidTimestamp
                }
                let plaintext = try crypto.decryptEntity(
                    change.envelope,
                    accountKey: accountKey,
                    accountId: accountId,
                    entityType: change.entityType,
                    entityId: change.entityId
                )
                do {
                    try EntityPayloadValidator.validate(
                        entityType: change.entityType,
                        content: plaintext
                    )
                } catch {
                    throw SyncEngineError.unsupportedEntitySchema
                }
                let entity = StoredEntity(
                    id: change.entityId,
                    entityType: change.entityType,
                    parentId: change.parentId,
                    relationIds: change.relationIds,
                    content: plaintext,
                    revision: change.revision,
                    tombstone: change.operation == .delete,
                    clientModifiedAt: modifiedAt,
                    syncState: .synced
                )
                updates.append(
                    RemoteEntityUpdate(
                        entity: entity,
                        search: EntitySearchIndexer.document(
                        for: change.entityType,
                        content: plaintext
                        )
                    )
                )
            }
            try await database.applyRemotePage(updates, nextSequence: response.nextSequence)
            report.pulledChanges += updates.count
            cursor = response.nextSequence
            guard response.hasMore else { return }
        }
    }

    private func hydrateServerConflicts(report: inout SyncReport) async throws {
        let response = try await api.listUnresolvedConflicts()
        var candidates: [HydratedServerConflict] = []
        candidates.reserveCapacity(response.conflicts.count)
        for conflict in response.conflicts {
            guard (0 ... 2_097_152).contains(conflict.envelope.payloadSize) else {
                throw SyncEngineError.conflictPayloadTooLarge
            }
            guard conflict.baseRevision >= 0,
                  conflict.currentRevision >= 0,
                  RFC3339Milliseconds.date(from: conflict.clientModifiedAt) != nil,
                  let createdAt = RFC3339Milliseconds.date(from: conflict.createdAt)
            else { throw SyncEngineError.invalidTimestamp }
            let plaintext = try crypto.decryptEntity(
                conflict.envelope,
                accountKey: accountKey,
                accountId: accountId,
                entityType: conflict.entityType,
                entityId: conflict.entityId
            )
            do {
                try EntityPayloadValidator.validate(
                    entityType: conflict.entityType,
                    content: plaintext
                )
            } catch {
                throw SyncEngineError.unsupportedEntitySchema
            }
            candidates.append(
                HydratedServerConflict(
                    serverConflictId: conflict.id,
                    entityId: conflict.entityId,
                    entityType: conflict.entityType,
                    parentId: conflict.parentId,
                    relationIds: conflict.relationIds,
                    candidateContent: plaintext,
                    createdAt: createdAt
                )
            )
        }
        report.conflictsHydrated += try await database.hydrateServerConflicts(candidates)
    }

    private func validatePullPage(_ response: SyncPullResponse, after cursor: String) throws {
        guard isValidSequence(cursor),
              isValidSequence(response.nextSequence),
              isValidSequence(response.latestSequence),
              compareSequences(response.nextSequence, cursor) != .orderedAscending,
              compareSequences(response.latestSequence, response.nextSequence) != .orderedAscending
        else { throw SyncEngineError.invalidSequence }

        var previous = cursor
        for change in response.changes {
            guard isValidSequence(change.sequence),
                  compareSequences(change.sequence, previous) == .orderedDescending
            else { throw SyncEngineError.invalidSequence }
            previous = change.sequence
        }
        if let last = response.changes.last {
            guard last.sequence == response.nextSequence else {
                throw SyncEngineError.invalidSequence
            }
        } else if response.nextSequence != cursor {
            throw SyncEngineError.invalidSequence
        }
        if response.hasMore && response.changes.isEmpty {
            throw SyncEngineError.invalidSequence
        }
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
}
