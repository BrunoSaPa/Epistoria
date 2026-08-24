import EpistoriaCore
import Foundation

struct EpistoriaImportSummary: Sendable {
    let sourceAccountId: UUID
    let exportedAt: Date
    let formatVersion: String
    let includesDerivedAI: Bool
    let recordCount: Int
    let assetCount: Int
    let noteCount: Int
    let sourceCount: Int
    let topicCount: Int
    let flashcardCount: Int
    let testCount: Int
    let fileCount: Int
    let byteCount: Int64
}

struct EpistoriaImportResult: Identifiable, Sendable {
    let id = UUID()
    let summary: EpistoriaImportSummary
    let cleanupWarning: String?
}

struct EpistoriaImportPlan: Identifiable, Sendable {
    let id: UUID
    let summary: EpistoriaImportSummary
    fileprivate let stagingRoot: URL
    fileprivate let encryptedAssetsDirectory: URL
    fileprivate let finalAssetsDirectory: URL
    fileprivate let writes: [LocalEntityWrite]
    fileprivate let assets: [LocalAsset]
    fileprivate let conflicts: [ImportedLocalConflict]
}

enum EpistoriaImportError: Error, LocalizedError {
    case dependenciesUnavailable
    case requiresEmptyNotebook
    case unsupportedFormat
    case malformedManifest(String)
    case missingAsset(String)
    case assetSizeMismatch(String)
    case duplicateAssetContent
    case assetConflictUnsupported
    case activationFailed
    case cleanupFailed

    var errorDescription: String? {
        switch self {
        case .dependenciesUnavailable:
            "The unlocked notebook is not available for import."
        case .requiresEmptyNotebook:
            "Import requires an empty notebook. Existing data was not changed."
        case .unsupportedFormat:
            "This export cannot be restored. Create a new epistoria-export/5 archive first."
        case let .malformedManifest(field):
            "The export manifest is invalid at \(field). Existing data was not changed."
        case let .missingAsset(path):
            "The export is missing the original file at \(path). Existing data was not changed."
        case let .assetSizeMismatch(path):
            "The original file size does not match its record at \(path). Existing data was not changed."
        case .duplicateAssetContent:
            "The export contains duplicate asset records that cannot be restored safely. Existing data was not changed."
        case .assetConflictUnsupported:
            "The export contains an unresolved file conflict. Resolve it in the source notebook and export again."
        case .activationFailed:
            "Epistoria could not activate the staged import. Existing data was not changed."
        case .cleanupFailed:
            "Epistoria could not remove protected import staging data. Restart the app before trying again."
        }
    }
}

/// Validates readable input in an app-owned staging directory, re-encrypts every original with a
/// fresh account-bound key, then activates records and asset registrations in one SQL transaction.
actor EpistoriaPortableImportService {
    private let accountId: UUID
    private let accountKey: Data
    private let database: SQLCipherDatabase
    private let exportValidator: EpistoriaExportService
    private let assetsDirectory: URL
    private let fileManager: FileManager
    private let crypto = EntityCrypto()
    private let assetCrypto = AssetCrypto()

    init(
        accountId: UUID,
        accountKey: Data,
        database: SQLCipherDatabase,
        store: EpistoriaStore,
        assetManager: AssetManager,
        assetsDirectory: URL,
        fileManager: FileManager = .default
    ) {
        self.accountId = accountId
        self.accountKey = accountKey
        self.database = database
        exportValidator = EpistoriaExportService(
            accountId: accountId,
            store: store,
            database: database,
            assetManager: assetManager
        )
        self.assetsDirectory = assetsDirectory
        self.fileManager = fileManager
    }

    func prepare(from sourceURL: URL) async throws -> EpistoriaImportPlan {
        guard try await database.portableImportIsEmpty() else {
            throw EpistoriaImportError.requiresEmptyNotebook
        }
        try removeOrphanedImportAssetsFromEmptyNotebook()
        let importId = UUID()
        let stagingRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "EpistoriaImport-\(importId.uuidString)",
            isDirectory: true
        )
        let encryptedAssets = stagingRoot.appendingPathComponent("EncryptedAssets", isDirectory: true)
        let finalAssets = assetsDirectory
            .appendingPathComponent("Imports", isDirectory: true)
            .appendingPathComponent("EpistoriaImport-\(importId.uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
            try setCompleteProtection(on: stagingRoot)
            let package = try stagePackage(from: sourceURL, in: stagingRoot)
            let validation = try await exportValidator.validateDecryptedDirectory(
                at: package,
                requireMatchingAccount: false
            )
            let metadata = try readMetadata(in: package)
            guard metadata.formatVersion == "epistoria-export/5" else {
                throw EpistoriaImportError.unsupportedFormat
            }
            try fileManager.createDirectory(at: encryptedAssets, withIntermediateDirectories: true)
            let prepared = try prepareEntities(
                in: package,
                encryptedAssetsDirectory: encryptedAssets,
                finalAssetsDirectory: finalAssets
            )
            let conflicts = try prepareConflicts(in: package, writes: prepared.writes)
            let summary = EpistoriaImportSummary(
                sourceAccountId: metadata.accountId,
                exportedAt: metadata.exportedAt,
                formatVersion: metadata.formatVersion,
                includesDerivedAI: metadata.includesDerivedAI,
                recordCount: prepared.writes.count,
                assetCount: prepared.assets.count,
                noteCount: prepared.counts[.note, default: 0],
                sourceCount: prepared.counts[.resource, default: 0],
                topicCount: prepared.counts[.course, default: 0],
                flashcardCount: prepared.counts[.flashcard, default: 0],
                testCount: prepared.counts[.practiceTest, default: 0],
                fileCount: validation.fileCount,
                byteCount: validation.byteCount
            )
            return EpistoriaImportPlan(
                id: importId,
                summary: summary,
                stagingRoot: stagingRoot,
                encryptedAssetsDirectory: encryptedAssets,
                finalAssetsDirectory: finalAssets,
                writes: prepared.writes,
                assets: prepared.assets,
                conflicts: conflicts
            )
        } catch {
            do { try removeOwnedStaging(stagingRoot) }
            catch { throw EpistoriaImportError.cleanupFailed }
            throw error
        }
    }

    func commit(_ plan: EpistoriaImportPlan) async throws -> EpistoriaImportResult {
        guard try await database.portableImportIsEmpty() else {
            try? removeOwnedStaging(plan.stagingRoot)
            throw EpistoriaImportError.requiresEmptyNotebook
        }
        var assetsMoved = false
        do {
            try fileManager.createDirectory(
                at: plan.finalAssetsDirectory.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !plan.assets.isEmpty {
                try fileManager.moveItem(
                    at: plan.encryptedAssetsDirectory,
                    to: plan.finalAssetsDirectory
                )
                assetsMoved = true
            }
            try await database.saveLocalBatch(
                plan.writes,
                registeringAssets: plan.assets,
                registeringConflicts: plan.conflicts
            )
        } catch {
            if assetsMoved, fileManager.fileExists(atPath: plan.finalAssetsDirectory.path) {
                try? fileManager.removeItem(at: plan.finalAssetsDirectory)
            }
            try? removeOwnedStaging(plan.stagingRoot)
            if error is EpistoriaImportError { throw error }
            throw EpistoriaImportError.activationFailed
        }
        let cleanupWarning: String?
        do {
            try removeOwnedStaging(plan.stagingRoot)
            cleanupWarning = nil
        } catch {
            cleanupWarning = "Import completed, but temporary readable staging data could not be removed. Restart Epistoria before importing another archive."
        }
        return EpistoriaImportResult(summary: plan.summary, cleanupWarning: cleanupWarning)
    }

    func cancel(_ plan: EpistoriaImportPlan) throws {
        try removeOwnedStaging(plan.stagingRoot)
    }

    private struct Metadata {
        var formatVersion: String
        var exportedAt: Date
        var accountId: UUID
        var includesDerivedAI: Bool
    }

    private struct PreparedEntities {
        var writes: [LocalEntityWrite]
        var assets: [LocalAsset]
        var counts: [EntityType: Int]
    }

    private func stagePackage(from sourceURL: URL, in stagingRoot: URL) throws -> URL {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
        if sourceURL.pathExtension.lowercased() == "zip" {
            return try PortableArchiveExtractor().extract(zipURL: sourceURL, into: stagingRoot)
        }
        let values = try sourceURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw EpistoriaImportError.unsupportedFormat
        }
        let sourcePackage: URL
        if fileManager.fileExists(atPath: sourceURL.appendingPathComponent("metadata.json").path) {
            sourcePackage = sourceURL
        } else {
            sourcePackage = sourceURL.appendingPathComponent("epistoria-export", isDirectory: true)
        }
        guard fileManager.fileExists(atPath: sourcePackage.appendingPathComponent("metadata.json").path)
        else { throw EpistoriaImportError.unsupportedFormat }
        let destination = stagingRoot.appendingPathComponent("epistoria-export", isDirectory: true)
        try fileManager.copyItem(at: sourcePackage, to: destination)
        return destination
    }

    private func readMetadata(in package: URL) throws -> Metadata {
        let object = try dictionary(at: package.appendingPathComponent("metadata.json"))
        guard let version = object["formatVersion"] as? String,
              let exported = object["exportedAt"] as? String,
              let exportedAt = RFC3339Milliseconds.date(from: exported),
              let account = object["accountId"] as? String,
              let sourceAccountId = UUID(uuidString: account),
              let includesAI = object["includesDerivedAI"] as? Bool
        else { throw EpistoriaImportError.malformedManifest("metadata.json") }
        return Metadata(
            formatVersion: version,
            exportedAt: exportedAt,
            accountId: sourceAccountId,
            includesDerivedAI: includesAI
        )
    }

    private func prepareEntities(
        in package: URL,
        encryptedAssetsDirectory: URL,
        finalAssetsDirectory: URL
    ) throws -> PreparedEntities {
        let object = try JSONSerialization.jsonObject(
            with: try boundedData(at: package.appendingPathComponent("entities.json"), maximum: 64 * 1_024 * 1_024)
        )
        guard let records = object as? [[String: Any]], records.count <= 250_000 else {
            throw EpistoriaImportError.malformedManifest("entities.json")
        }
        var identifiers = Set<UUID>()
        var dedupeTags = Set<String>()
        var writes: [LocalEntityWrite] = []
        var assets: [LocalAsset] = []
        var counts: [EntityType: Int] = [:]
        for (index, record) in records.enumerated() {
            let field = "entities.json[\(index)]"
            guard let rawId = record["id"] as? String,
                  let id = UUID(uuidString: rawId),
                  identifiers.insert(id).inserted,
                  let rawType = record["entityType"] as? String,
                  let entityType = EntityType(rawValue: rawType),
                  let relations = record["relationIds"] as? [String],
                  relations.count <= 1_024,
                  let relationIds = parseUUIDs(relations),
                  let modified = record["modifiedAt"] as? String,
                  let modifiedAt = RFC3339Milliseconds.date(from: modified),
                  let contentObject = record["content"],
                  JSONSerialization.isValidJSONObject(contentObject)
            else { throw EpistoriaImportError.malformedManifest(field) }
            let parentId: UUID?
            if record["parentId"] is NSNull || record["parentId"] == nil {
                parentId = nil
            } else if let rawParent = record["parentId"] as? String,
                      let parsed = UUID(uuidString: rawParent) {
                parentId = parsed
            } else {
                throw EpistoriaImportError.malformedManifest("\(field).parentId")
            }

            let content: Data
            if entityType == .asset {
                guard let assetPath = record["assetPath"] as? String,
                      isSafeRelativePath(assetPath),
                      let metadata = contentObject as? [String: Any],
                      let mimeType = metadata["mimeType"] as? String,
                      let plaintextSize = int64(metadata["plaintextByteSize"]),
                      let originalFilename = metadata["originalFilename"] as? String,
                      let created = metadata["createdAt"] as? String,
                      let createdAt = RFC3339Milliseconds.date(from: created),
                      let updated = metadata["updatedAt"] as? String,
                      let updatedAt = RFC3339Milliseconds.date(from: updated)
                else { throw EpistoriaImportError.malformedManifest(field) }
                let plaintextURL = package.appendingPathComponent(assetPath)
                guard fileManager.fileExists(atPath: plaintextURL.path) else {
                    throw EpistoriaImportError.missingAsset(assetPath)
                }
                let plaintext = try boundedData(at: plaintextURL, maximum: 512 * 1_024 * 1_024)
                guard Int64(plaintext.count) == plaintextSize else {
                    throw EpistoriaImportError.assetSizeMismatch(assetPath)
                }
                let assetKey = try crypto.randomKey()
                let dedupeTag = try crypto.dedupeTag(
                    plaintext: plaintext,
                    accountKey: accountKey,
                    accountId: accountId
                )
                guard dedupeTags.insert(dedupeTag).inserted else {
                    throw EpistoriaImportError.duplicateAssetContent
                }
                let encrypted = try assetCrypto.encrypt(plaintext, key: assetKey)
                let stagingURL = encryptedAssetsDirectory.appendingPathComponent(
                    "\(id.uuidString.lowercased()).epistoria"
                )
                try protectedWrite(encrypted, to: stagingURL)
                let finalURL = finalAssetsDirectory.appendingPathComponent(stagingURL.lastPathComponent)
                var payload = AssetPayload(
                    mimeType: mimeType,
                    plaintextByteSize: plaintextSize,
                    encryptedByteSize: Int64(encrypted.count),
                    dedupeTag: dedupeTag,
                    assetKey: Base64URL.encode(assetKey),
                    originalFilename: String(originalFilename.prefix(512)),
                    now: createdAt
                )
                payload.updatedAt = updatedAt
                content = try CanonicalJSON.encode(payload)
                assets.append(LocalAsset(
                    id: id,
                    dedupeTag: dedupeTag,
                    encryptedFileURL: finalURL,
                    encryptedByteSize: Int64(encrypted.count),
                    uploadState: .pending,
                    lastErrorCode: nil
                ))
            } else {
                content = try JSONSerialization.data(
                    withJSONObject: contentObject,
                    options: [.sortedKeys, .withoutEscapingSlashes]
                )
            }
            guard content.count <= 2_097_152 else {
                throw EpistoriaImportError.malformedManifest("\(field).content")
            }
            do { try EntityPayloadValidator.validate(entityType: entityType, content: content) }
            catch { throw EpistoriaImportError.malformedManifest("\(field).content") }
            writes.append(LocalEntityWrite(
                id: id,
                entityType: entityType,
                parentId: parentId,
                relationIds: relationIds,
                content: content,
                search: EntitySearchIndexer.document(for: entityType, content: content),
                modifiedAt: modifiedAt
            ))
            counts[entityType, default: 0] += 1
        }
        return PreparedEntities(writes: writes, assets: assets, counts: counts)
    }

    private func prepareConflicts(
        in package: URL,
        writes: [LocalEntityWrite]
    ) throws -> [ImportedLocalConflict] {
        let object = try JSONSerialization.jsonObject(
            with: try boundedData(at: package.appendingPathComponent("conflicts.json"), maximum: 64 * 1_024 * 1_024)
        )
        guard let records = object as? [[String: Any]], records.count <= 100_000 else {
            throw EpistoriaImportError.malformedManifest("conflicts.json")
        }
        let entities = Dictionary(uniqueKeysWithValues: writes.map { ($0.id, $0.entityType) })
        var identifiers = Set<UUID>()
        return try records.enumerated().map { index, record in
            let field = "conflicts.json[\(index)]"
            guard let rawId = record["id"] as? String,
                  let id = UUID(uuidString: rawId),
                  identifiers.insert(id).inserted,
                  let rawEntityId = record["entityId"] as? String,
                  let entityId = UUID(uuidString: rawEntityId),
                  let rawType = record["entityType"] as? String,
                  let entityType = EntityType(rawValue: rawType),
                  entities[entityId] == entityType,
                  let rawRelations = record["relationIds"] as? [String],
                  let relationIds = parseUUIDs(rawRelations),
                  let rawCreated = record["createdAt"] as? String,
                  let createdAt = RFC3339Milliseconds.date(from: rawCreated),
                  let candidateObject = record["candidate"],
                  JSONSerialization.isValidJSONObject(candidateObject)
            else { throw EpistoriaImportError.malformedManifest(field) }
            guard entityType != .asset else { throw EpistoriaImportError.assetConflictUnsupported }
            let candidate = try JSONSerialization.data(
                withJSONObject: candidateObject,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            do { try EntityPayloadValidator.validate(entityType: entityType, content: candidate) }
            catch { throw EpistoriaImportError.malformedManifest("\(field).candidate") }
            return ImportedLocalConflict(
                id: id,
                entityId: entityId,
                entityType: entityType,
                parentId: try optionalUUID(record["parentId"], field: "\(field).parentId"),
                relationIds: relationIds,
                candidateContent: candidate,
                serverConflictId: try optionalUUID(
                    record["serverConflictId"],
                    field: "\(field).serverConflictId"
                ),
                createdAt: createdAt
            )
        }
    }

    private func dictionary(at url: URL) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(
            with: boundedData(at: url, maximum: 64 * 1_024 * 1_024)
        ) as? [String: Any] else {
            throw EpistoriaImportError.malformedManifest(url.lastPathComponent)
        }
        return value
    }

    private func boundedData(at url: URL, maximum: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size >= 0,
              size <= maximum
        else { throw EpistoriaImportError.malformedManifest(url.lastPathComponent) }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    private func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\\") else { return false }
        return value.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private func optionalUUID(_ value: Any?, field: String) throws -> UUID? {
        guard let value, !(value is NSNull) else { return nil }
        guard let raw = value as? String, let id = UUID(uuidString: raw) else {
            throw EpistoriaImportError.malformedManifest(field)
        }
        return id
    }

    private func parseUUIDs(_ values: [String]) -> [UUID]? {
        var result: [UUID] = []
        result.reserveCapacity(values.count)
        for value in values {
            guard let id = UUID(uuidString: value) else { return nil }
            result.append(id)
        }
        return result
    }

    private func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        return nil
    }

    private func protectedWrite(_ data: Data, to url: URL) throws {
        var options = Data.WritingOptions.atomic
        #if os(iOS)
        options.insert(.completeFileProtection)
        #endif
        try data.write(to: url, options: options)
    }

    private func setCompleteProtection(on url: URL) throws {
        #if os(iOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
        #endif
    }

    private func removeOwnedStaging(_ url: URL) throws {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        guard parent == fileManager.temporaryDirectory.standardizedFileURL,
              url.lastPathComponent.hasPrefix("EpistoriaImport-"),
              UUID(uuidString: String(
                url.lastPathComponent.dropFirst("EpistoriaImport-".count)
              )) != nil
        else { throw EpistoriaImportError.cleanupFailed }
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    private func removeOrphanedImportAssetsFromEmptyNotebook() throws {
        let imports = assetsDirectory.appendingPathComponent("Imports", isDirectory: true)
        guard fileManager.fileExists(atPath: imports.path) else { return }
        let children = try fileManager.contentsOfDirectory(
            at: imports,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        for child in children {
            let name = child.lastPathComponent
            guard name.hasPrefix("EpistoriaImport-"),
                  UUID(uuidString: String(name.dropFirst("EpistoriaImport-".count))) != nil
            else { continue }
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            try fileManager.removeItem(at: child)
        }
    }
}
