import CryptoKit
import EpistoriaCore
import Foundation
import UniformTypeIdentifiers

struct EpistoriaExportResult: Identifiable, Sendable {
    let id = UUID()
    let archiveURL: URL
    let fileCount: Int
    let byteCount: Int64
}

struct EpistoriaExportValidation: Sendable {
    let fileCount: Int
    let byteCount: Int64
}

enum EpistoriaExportError: Error, LocalizedError {
    case dependenciesUnavailable
    case invalidJSON(String)
    case validationFailed(String)
    case archiveCreationFailed
    case temporaryCleanupFailed

    var errorDescription: String? {
        switch self {
        case .dependenciesUnavailable:
            "The unlocked notebook is not available for export."
        case let .invalidJSON(path):
            "The export contains invalid JSON at \(path)."
        case let .validationFailed(reason):
            "The export did not pass validation: \(reason)"
        case .archiveCreationFailed:
            "Epistoria could not package the export directory."
        case .temporaryCleanupFailed:
            "Epistoria could not remove a temporary readable export. Restart Epistoria before exporting again."
        }
    }
}

/// Creates the documented, explicitly decrypted portability archive.
///
/// The archive never includes recovery words, account keys, device tokens, asset keys, server
/// credentials, or the SQLCipher database. Original resources are decrypted only into the
/// protected staging directory and the finished archive is removed by the UI after sharing.
actor EpistoriaExportService {
    private struct PreparedExport {
        var stagingRoot: URL
        var package: URL
        var validation: EpistoriaExportValidation
    }

    private struct Metadata: Codable {
        var formatVersion = "epistoria-export/4"
        var exportedAt: Date
        var accountId: UUID
        var mode = "DECRYPTED"
        var includesDerivedAI: Bool
        var warning = "This archive contains readable personal data. Store it securely."
    }

    private struct Record<Payload: Codable>: Codable {
        var id: UUID
        var payload: Payload
    }

    private struct UniversityRecords: Codable {
        var institutions: [Record<InstitutionPayload>]
        var academicTerms: [Record<AcademicTermPayload>]
        var courses: [Record<CoursePayload>]
    }

    private struct TaxonomyRecords: Codable {
        var areas: [Record<AreaPayload>]
        var topics: [Record<TopicPayload>]
        var topicAreaRelations: [Record<TopicAreaRelationPayload>]
    }

    private struct KnowledgeRecords: Codable {
        var sourceVersions: [Record<SourceVersionPayload>]
        var evidence: [Record<EvidencePayload>]
        var transcriptCorrections: [Record<TranscriptCorrectionPayload>]
        var concepts: [Record<ConceptPayload>]
        var conceptEvidence: [Record<ConceptEvidenceRelationPayload>]
        var conceptLinks: [Record<ConceptLinkPayload>]
    }

    private struct LearningRecords: Codable {
        var goals: [Record<StudyGoalPayload>]
        var unresolvedQuestions: [Record<UnresolvedQuestionPayload>]
        var sessionActivity: [Record<SessionActivityPayload>]
        var decks: [Record<FlashcardDeckPayload>]
        var cards: [Record<FlashcardPayload>]
        var cardRevisions: [Record<FlashcardRevisionPayload>]
        var cardReviews: [Record<FlashcardReviewPayload>]
        var scopeSnapshots: [Record<TopicScopeSnapshotPayload>]
        var testBlueprints: [Record<TestBlueprintPayload>]
        var tests: [Record<PracticeTestPayload>]
        var testQuestions: [Record<TestQuestionPayload>]
        var testAttempts: [Record<TestAttemptPayload>]
        var testResponses: [Record<TestResponsePayload>]
        var recommendations: [Record<StudyRecommendationPayload>]
        var recommendationResponses: [Record<RecommendationResponsePayload>]
        var automationGrants: [Record<AutomationGrantPayload>]
    }

    private struct CollectionRecords: Codable {
        var collections: [Record<CollectionPayload>]
        var links: [Record<RelationPayload>]
    }

    private struct SessionRecords: Codable {
        var sessions: [Record<StudySessionPayload>]
        var noteLinks: [Record<RelationPayload>]
        var resourceLinks: [Record<RelationPayload>]
    }

    private struct NoteRecord: Codable {
        var id: UUID
        var note: NotePayload
        var blocks: [Record<NoteBlockPayload>]
    }

    private struct ResourceRecord: Codable {
        var id: UUID
        var resource: SourcePayload
        var originalPath: String?
        var readablePath: String?
    }

    private struct CanvasAssetRecord: Codable {
        var noteId: UUID
        var itemId: UUID
        var assetId: UUID
        var originalFilename: String
        var mimeType: String
        var relativePath: String
    }

    private struct Provenance: Codable {
        var derivedRecordsIncluded: Bool
        var rule = "Derived records remain separate from original notes, drawings, and files."
        var exportedEntityType = "AI_ARTIFACT"
    }

    private final class CoordinationResult: @unchecked Sendable {
        var copyError: Error?
        var produced = false
    }

    private let accountId: UUID
    private let store: EpistoriaStore
    private let database: SQLCipherDatabase
    private let assetManager: AssetManager
    private let fileManager: FileManager

    init(
        accountId: UUID,
        store: EpistoriaStore,
        database: SQLCipherDatabase,
        assetManager: AssetManager,
        fileManager: FileManager = .default
    ) {
        self.accountId = accountId
        self.store = store
        self.database = database
        self.assetManager = assetManager
        self.fileManager = fileManager
    }

    func exportDecrypted(includingDerivedAI: Bool) async throws -> EpistoriaExportResult {
        try cleanupStaleTemporaryExports()
        let prepared = try await prepareDecryptedDirectory(
            includingDerivedAI: includingDerivedAI
        )
        var archive: URL?
        do {
            let producedArchive = try createArchive(from: prepared.package)
            archive = producedArchive
            try fileManager.removeItem(at: prepared.stagingRoot)
            return EpistoriaExportResult(
                archiveURL: producedArchive,
                fileCount: prepared.validation.fileCount,
                byteCount: prepared.validation.byteCount
            )
        } catch {
            let originalError = error
            var cleanupFailed = false
            if let archive, fileManager.fileExists(atPath: archive.path) {
                do { try fileManager.removeItem(at: archive) }
                catch { cleanupFailed = true }
            }
            if fileManager.fileExists(atPath: prepared.stagingRoot.path) {
                do { try fileManager.removeItem(at: prepared.stagingRoot) }
                catch { cleanupFailed = true }
            }
            if cleanupFailed { throw EpistoriaExportError.temporaryCleanupFailed }
            throw originalError
        }
    }

    #if DEBUG
    func prepareDecryptedDirectoryForTesting(includingDerivedAI: Bool) async throws -> URL {
        try cleanupStaleTemporaryExports()
        return try await prepareDecryptedDirectory(
            includingDerivedAI: includingDerivedAI
        ).package
    }
    #endif

    nonisolated static func removeTemporaryArchive(_ url: URL) throws {
        let fileManager = FileManager.default
        let parent = url.deletingLastPathComponent().standardizedFileURL
        guard url.isFileURL,
              parent == fileManager.temporaryDirectory.standardizedFileURL,
              url.pathExtension.lowercased() == "zip",
              url.lastPathComponent.hasPrefix("Epistoria-")
        else { return }
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    nonisolated static func removeAllTemporaryExports() throws {
        let fileManager = FileManager.default
        for url in try fileManager.contentsOfDirectory(
            at: fileManager.temporaryDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        ) {
            let name = url.lastPathComponent
            let isOwned = name.hasPrefix("EpistoriaExport-")
                || (name.hasPrefix("Epistoria-") && url.pathExtension.lowercased() == "zip")
                || (name.hasPrefix("Epistoria-") && url.pathExtension.lowercased() == "partial")
            if isOwned { try fileManager.removeItem(at: url) }
        }
    }

    func validateDecryptedDirectory(at directory: URL) throws -> EpistoriaExportValidation {
        guard directory.isFileURL else {
            throw EpistoriaExportError.validationFailed("the selected export is not a local directory")
        }
        let accessed = directory.startAccessingSecurityScopedResource()
        defer { if accessed { directory.stopAccessingSecurityScopedResource() } }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw EpistoriaExportError.validationFailed("the selected export root is not a regular directory")
        }
        return try validate(directory: directory.standardizedFileURL)
    }

    private func prepareDecryptedDirectory(
        includingDerivedAI: Bool
    ) async throws -> PreparedExport {
        try await database.checkpoint()
        let stagingRoot = fileManager.temporaryDirectory
            .appendingPathComponent("EpistoriaExport-\(UUID().uuidString)", isDirectory: true)
        let package = stagingRoot.appendingPathComponent("epistoria-export", isDirectory: true)
        try fileManager.createDirectory(at: package, withIntermediateDirectories: true)
        try setCompleteProtection(on: stagingRoot)

        do {
            try Task.checkCancellation()
            try write(
                Metadata(
                    exportedAt: .now,
                    accountId: accountId,
                    includesDerivedAI: includingDerivedAI
                ),
                to: package.appendingPathComponent("metadata.json")
            )
            try await exportCollections(to: package)
            try Task.checkCancellation()
            try await exportUniversity(to: package)
            try await exportTaxonomy(to: package)
            try Task.checkCancellation()
            try await exportSessions(to: package)
            try Task.checkCancellation()
            try await exportNotes(to: package)
            try Task.checkCancellation()
            try await exportResources(to: package)
            try Task.checkCancellation()
            try await exportAnnotations(to: package)
            try await exportKnowledge(to: package)
            try await exportLearning(to: package)
            try Task.checkCancellation()
            try await exportConflicts(to: package)
            try Task.checkCancellation()
            try await exportAI(to: package, included: includingDerivedAI)
            try write(
                Provenance(derivedRecordsIncluded: includingDerivedAI),
                to: package.appendingPathComponent("provenance.json")
            )
            try writeChecksums(in: package)
            let validation = try validate(directory: package)
            return PreparedExport(
                stagingRoot: stagingRoot,
                package: package,
                validation: validation
            )
        } catch {
            let originalError = error
            do {
                if fileManager.fileExists(atPath: stagingRoot.path) {
                    try fileManager.removeItem(at: stagingRoot)
                }
            } catch {
                throw EpistoriaExportError.temporaryCleanupFailed
            }
            throw originalError
        }
    }

    private func exportCollections(to root: URL) async throws {
        async let values = store.list(CollectionPayload.self)
        async let links = store.list(
            RelationPayload.self,
            entityTypeOverride: .collectionItem
        )
        let (resolvedValues, resolvedLinks) = try await (values, links)
        let payload = CollectionRecords(
            collections: resolvedValues.map { Record(id: $0.id, payload: $0.payload) },
            links: resolvedLinks.map { Record(id: $0.id, payload: $0.payload) }
        )
        try write(payload, to: root.appendingPathComponent("collections.json"))
    }

    private func exportUniversity(to root: URL) async throws {
        async let institutions = store.list(InstitutionPayload.self)
        async let terms = store.list(AcademicTermPayload.self)
        async let courses = store.list(CoursePayload.self)
        let (resolvedInstitutions, resolvedTerms, resolvedCourses) = try await (
            institutions,
            terms,
            courses
        )
        let payload = UniversityRecords(
            institutions: resolvedInstitutions.map { Record(id: $0.id, payload: $0.payload) },
            academicTerms: resolvedTerms.map { Record(id: $0.id, payload: $0.payload) },
            courses: resolvedCourses.map { Record(id: $0.id, payload: $0.payload) }
        )
        try write(payload, to: root.appendingPathComponent("university.json"))
    }

    private func exportTaxonomy(to root: URL) async throws {
        async let areas = store.list(AreaPayload.self)
        async let topics = store.topics()
        async let relations = store.list(TopicAreaRelationPayload.self)
        let value = try await TaxonomyRecords(
            areas: areas.map { Record(id: $0.id, payload: $0.payload) },
            topics: topics.map { Record(id: $0.id, payload: $0.payload) },
            topicAreaRelations: relations.map { Record(id: $0.id, payload: $0.payload) }
        )
        try write(value, to: root.appendingPathComponent("taxonomy.json"))
    }

    private func exportSessions(to root: URL) async throws {
        async let sessions = store.list(StudySessionPayload.self)
        async let noteLinks = store.list(RelationPayload.self, entityTypeOverride: .sessionNote)
        async let resourceLinks = store.list(RelationPayload.self, entityTypeOverride: .sessionResource)
        let (resolvedSessions, resolvedNoteLinks, resolvedResourceLinks) = try await (
            sessions,
            noteLinks,
            resourceLinks
        )
        let payload = SessionRecords(
            sessions: resolvedSessions.map { Record(id: $0.id, payload: $0.payload) },
            noteLinks: resolvedNoteLinks.map { Record(id: $0.id, payload: $0.payload) },
            resourceLinks: resolvedResourceLinks.map { Record(id: $0.id, payload: $0.payload) }
        )
        try write(payload, to: root.appendingPathComponent("sessions.json"))
    }

    private func exportNotes(to root: URL) async throws {
        let notesDirectory = root.appendingPathComponent("notes", isDirectory: true)
        let drawingsDirectory = notesDirectory.appendingPathComponent("drawings", isDirectory: true)
        let richTextDirectory = notesDirectory.appendingPathComponent("rich-text", isDirectory: true)
        let imagesDirectory = notesDirectory.appendingPathComponent("images", isDirectory: true)
        try fileManager.createDirectory(at: drawingsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: richTextDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        var canvasAssets: [CanvasAssetRecord] = []
        var exportedImagePaths: [UUID: String] = [:]
        let notes = try await store.list(NotePayload.self)
        for note in notes {
            let blocks = try await store.list(NoteBlockPayload.self, parentId: note.id)
                .sorted { $0.payload.orderKey < $1.payload.orderKey }
            let record = NoteRecord(
                id: note.id,
                note: note.payload,
                blocks: blocks.map { Record(id: $0.id, payload: $0.payload) }
            )
            try write(
                record,
                to: notesDirectory.appendingPathComponent("\(note.id.uuidString.lowercased()).json")
            )
            for block in blocks {
                if let drawing = block.payload.drawingData, !drawing.isEmpty {
                    try protectedWrite(
                        drawing,
                        to: drawingsDirectory.appendingPathComponent(
                            "\(block.id.uuidString.lowercased()).pkdrawing"
                        )
                    )
                }
                if let richText = block.payload.richTextRtf, !richText.isEmpty {
                    try protectedWrite(
                        richText,
                        to: richTextDirectory.appendingPathComponent(
                            "\(block.id.uuidString.lowercased()).rtf"
                        )
                    )
                }
                if block.payload.blockType == .image, let assetId = block.payload.assetId {
                    let metadata = try await store.payload(AssetPayload.self, id: assetId).payload
                    let relativePath: String
                    if let existing = exportedImagePaths[assetId] {
                        relativePath = existing
                    } else {
                        let filename = "\(assetId.uuidString.lowercased()).\(imageExtension(for: metadata.mimeType))"
                        relativePath = "notes/images/\(filename)"
                        let plaintext = try await assetManager.decryptedData(assetId: assetId)
                        try protectedWrite(
                            plaintext,
                            to: imagesDirectory.appendingPathComponent(filename)
                        )
                        exportedImagePaths[assetId] = relativePath
                    }
                    canvasAssets.append(
                        CanvasAssetRecord(
                            noteId: note.id,
                            itemId: block.id,
                            assetId: assetId,
                            originalFilename: metadata.originalFilename,
                            mimeType: metadata.mimeType,
                            relativePath: relativePath
                        )
                    )
                }
            }
        }
        try write(canvasAssets, to: notesDirectory.appendingPathComponent("canvas-assets.json"))
    }

    private func exportResources(to root: URL) async throws {
        let resourcesDirectory = root.appendingPathComponent("resources", isDirectory: true)
        let originalsDirectory = resourcesDirectory.appendingPathComponent("originals", isDirectory: true)
        let readableDirectory = resourcesDirectory.appendingPathComponent("readable", isDirectory: true)
        try fileManager.createDirectory(at: originalsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: readableDirectory, withIntermediateDirectories: true)
        let resources = try await store.list(SourcePayload.self)
        var records: [ResourceRecord] = []
        for resource in resources {
            var originalPath: String?
            var readablePath: String?
            if let assetId = resource.payload.originalAssetId {
                let metadata = try await store.payload(AssetPayload.self, id: assetId).payload
                let inferredExtension = UTType(mimeType: metadata.mimeType)?.preferredFilenameExtension
                let originalExtension = URL(fileURLWithPath: metadata.originalFilename)
                    .pathExtension.lowercased()
                let safeOriginalExtension = originalExtension.count <= 12
                    && !originalExtension.isEmpty
                    && originalExtension.unicodeScalars.allSatisfy {
                        CharacterSet.alphanumerics.contains($0)
                    }
                    ? originalExtension
                    : nil
                let extensionName = inferredExtension ?? safeOriginalExtension ?? "bin"
                let filename = "\(assetId.uuidString.lowercased()).\(extensionName)"
                let relativePath = "resources/originals/\(filename)"
                let plaintext = try await assetManager.decryptedData(assetId: assetId)
                try protectedWrite(plaintext, to: originalsDirectory.appendingPathComponent(filename))
                originalPath = relativePath
                if resource.payload.sourceType != .audio,
                   resource.payload.sourceType != .video,
                   let adapter = try? SourceAdapterRegistry().adapter(
                    for: resource.payload.sourceType
                ), let readable = try? adapter.readableExport(data: plaintext) {
                    let readableExtension = resource.payload.sourceType == .csv ? "csv" : "txt"
                    let readableFilename = "\(resource.id.uuidString.lowercased()).\(readableExtension)"
                    try protectedWrite(
                        readable,
                        to: readableDirectory.appendingPathComponent(readableFilename)
                    )
                    readablePath = "resources/readable/\(readableFilename)"
                }
            } else if resource.payload.sourceType == .youtube,
                      let canonicalURL = resource.payload.canonicalURL {
                let readableFilename = "\(resource.id.uuidString.lowercased()).txt"
                let readable = Data(
                    "\(resource.payload.title)\n\nYouTube URL: \(canonicalURL.absoluteString)\n".utf8
                )
                try protectedWrite(
                    readable,
                    to: readableDirectory.appendingPathComponent(readableFilename)
                )
                readablePath = "resources/readable/\(readableFilename)"
            }
            records.append(
                ResourceRecord(
                    id: resource.id,
                    resource: resource.payload,
                    originalPath: originalPath,
                    readablePath: readablePath
                )
            )
        }
        try write(records, to: resourcesDirectory.appendingPathComponent("resources.json"))
    }

    private func exportAnnotations(to root: URL) async throws {
        let values = try await store.list(AnnotationPayload.self)
        let drawingsDirectory = root
            .appendingPathComponent("annotation-drawings", isDirectory: true)
        try fileManager.createDirectory(at: drawingsDirectory, withIntermediateDirectories: true)
        for annotation in values {
            if let drawing = annotation.payload.drawingData, !drawing.isEmpty {
                try protectedWrite(
                    drawing,
                    to: drawingsDirectory.appendingPathComponent(
                        "\(annotation.id.uuidString.lowercased()).pkdrawing"
                    )
                )
            }
        }
        try write(
            values.map { Record(id: $0.id, payload: $0.payload) },
            to: root.appendingPathComponent("annotations.json")
        )
    }

    private func exportKnowledge(to root: URL) async throws {
        async let versions = store.list(SourceVersionPayload.self)
        async let evidence = store.list(EvidencePayload.self)
        async let transcriptCorrections = store.list(TranscriptCorrectionPayload.self)
        async let concepts = store.list(ConceptPayload.self)
        async let conceptEvidence = store.list(ConceptEvidenceRelationPayload.self)
        async let links = store.list(ConceptLinkPayload.self)
        let value = try await KnowledgeRecords(
            sourceVersions: versions.map { Record(id: $0.id, payload: $0.payload) },
            evidence: evidence.map { Record(id: $0.id, payload: $0.payload) },
            transcriptCorrections: transcriptCorrections.map { Record(id: $0.id, payload: $0.payload) },
            concepts: concepts.map { Record(id: $0.id, payload: $0.payload) },
            conceptEvidence: conceptEvidence.map { Record(id: $0.id, payload: $0.payload) },
            conceptLinks: links.map { Record(id: $0.id, payload: $0.payload) }
        )
        try write(value, to: root.appendingPathComponent("knowledge.json"))
    }

    private func exportLearning(to root: URL) async throws {
        async let goals = store.list(StudyGoalPayload.self)
        async let unresolved = store.list(UnresolvedQuestionPayload.self)
        async let activity = store.list(SessionActivityPayload.self)
        async let decks = store.list(FlashcardDeckPayload.self)
        async let cards = store.list(FlashcardPayload.self)
        async let revisions = store.list(FlashcardRevisionPayload.self)
        async let reviews = store.list(FlashcardReviewPayload.self)
        async let scopes = store.list(TopicScopeSnapshotPayload.self)
        async let blueprints = store.list(TestBlueprintPayload.self)
        async let tests = store.list(PracticeTestPayload.self)
        async let questions = store.list(TestQuestionPayload.self)
        async let attempts = store.list(TestAttemptPayload.self)
        async let responses = store.list(TestResponsePayload.self)
        async let recommendations = store.list(StudyRecommendationPayload.self)
        async let recommendationResponses = store.list(RecommendationResponsePayload.self)
        async let grants = store.list(AutomationGrantPayload.self)
        let value = try await LearningRecords(
            goals: goals.map { Record(id: $0.id, payload: $0.payload) },
            unresolvedQuestions: unresolved.map { Record(id: $0.id, payload: $0.payload) },
            sessionActivity: activity.map { Record(id: $0.id, payload: $0.payload) },
            decks: decks.map { Record(id: $0.id, payload: $0.payload) },
            cards: cards.map { Record(id: $0.id, payload: $0.payload) },
            cardRevisions: revisions.map { Record(id: $0.id, payload: $0.payload) },
            cardReviews: reviews.map { Record(id: $0.id, payload: $0.payload) },
            scopeSnapshots: scopes.map { Record(id: $0.id, payload: $0.payload) },
            testBlueprints: blueprints.map { Record(id: $0.id, payload: $0.payload) },
            tests: tests.map { Record(id: $0.id, payload: $0.payload) },
            testQuestions: questions.map { Record(id: $0.id, payload: $0.payload) },
            testAttempts: attempts.map { Record(id: $0.id, payload: $0.payload) },
            testResponses: responses.map { Record(id: $0.id, payload: $0.payload) },
            recommendations: recommendations.map { Record(id: $0.id, payload: $0.payload) },
            recommendationResponses: recommendationResponses.map { Record(id: $0.id, payload: $0.payload) },
            automationGrants: grants.map { Record(id: $0.id, payload: $0.payload) }
        )
        try write(value, to: root.appendingPathComponent("learning.json"))
    }

    private func exportConflicts(to root: URL) async throws {
        let conflicts = try await database.conflicts()
        var records: [[String: Any]] = []
        for conflict in conflicts {
            let current = try await database.entity(id: conflict.entityId)
            let currentObject: Any
            if let current {
                currentObject = try exportSafeJSONObject(
                    current.content,
                    entityType: current.entityType
                )
            } else {
                currentObject = NSNull()
            }
            records.append([
                "id": conflict.id.uuidString.lowercased(),
                "entityId": conflict.entityId.uuidString.lowercased(),
                "entityType": conflict.entityType.rawValue,
                "parentId": conflict.parentId?.uuidString.lowercased() ?? NSNull(),
                "relationIds": conflict.relationIds.map { $0.uuidString.lowercased() },
                "serverConflictId": conflict.serverConflictId?.uuidString.lowercased() ?? NSNull(),
                "createdAt": RFC3339Milliseconds.string(from: conflict.createdAt),
                "candidate": try exportSafeJSONObject(
                    conflict.candidateContent,
                    entityType: conflict.entityType
                ),
                "current": currentObject,
            ])
        }
        let data = try JSONSerialization.data(
            withJSONObject: records,
            options: [.prettyPrinted, .sortedKeys]
        )
        try protectedWrite(data + Data("\n".utf8), to: root.appendingPathComponent("conflicts.json"))
    }

    private func exportAI(to root: URL, included: Bool) async throws {
        guard included else {
            try protectedWrite(Data("[]\n".utf8), to: root.appendingPathComponent("ai-artifacts.json"))
            return
        }
        let entities = try await database.entities(type: .aiArtifact)
        let acceptedTranscriptChunkIds = Set(
            entities.compactMap { entity -> MediaTranscriptionManifest? in
                guard let manifest = try? CanonicalJSON.decode(
                    MediaTranscriptionManifest.self,
                    from: entity.content
                ), manifest.reviewState == .accepted || manifest.reviewState == .edited
                else { return nil }
                return manifest
            }.flatMap(\.chunkEntityIds)
        )
        let records: [[String: Any]] = try entities.compactMap { entity in
            let digest = try? CanonicalJSON.decode(SessionDigestArtifact.self, from: entity.content)
            let learning = try? CanonicalJSON.decode(LearningGenerationArtifact.self, from: entity.content)
            let transcription = try? CanonicalJSON.decode(
                MediaTranscriptionManifest.self,
                from: entity.content
            )
            let accepted = digest.map { $0.reviewState == .accepted || $0.reviewState == .edited }
                ?? learning.map { $0.reviewState == .accepted || $0.reviewState == .edited }
                ?? transcription.map { $0.reviewState == .accepted || $0.reviewState == .edited }
                ?? acceptedTranscriptChunkIds.contains(entity.id)
            guard accepted else { return nil }
            guard let content = try JSONSerialization.jsonObject(with: entity.content) as? [String: Any]
            else { throw EpistoriaExportError.invalidJSON("ai-artifacts.json") }
            return [
                "id": entity.id.uuidString.lowercased(),
                "parentId": entity.parentId.map { $0.uuidString.lowercased() } ?? NSNull(),
                "relationIds": entity.relationIds.map { $0.uuidString.lowercased() },
                "content": content,
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
        try protectedWrite(data + Data("\n".utf8), to: root.appendingPathComponent("ai-artifacts.json"))
    }

    private func exportSafeJSONObject(_ data: Data, entityType: EntityType) throws -> Any {
        if entityType == .asset {
            let asset = try CanonicalJSON.decode(AssetPayload.self, from: data)
            return [
                "schemaVersion": asset.schemaVersion,
                "mimeType": asset.mimeType,
                "plaintextByteSize": asset.plaintextByteSize,
                "encryptedByteSize": asset.encryptedByteSize,
                "dedupeTag": asset.dedupeTag,
                "originalFilename": asset.originalFilename,
                "createdAt": RFC3339Milliseconds.string(from: asset.createdAt),
                "updatedAt": RFC3339Milliseconds.string(from: asset.updatedAt),
            ]
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    private func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try protectedWrite(try encoder.encode(value) + Data("\n".utf8), to: url)
    }

    private func protectedWrite(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
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

    private func validate(directory: URL) throws -> EpistoriaExportValidation {
        var required = [
            "metadata.json", "collections.json", "university.json", "sessions.json",
            "resources/resources.json", "annotations.json", "ai-artifacts.json",
            "conflicts.json", "provenance.json", "checksums.sha256",
        ]
        let metadataURL = directory.appendingPathComponent("metadata.json")
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            throw EpistoriaExportError.validationFailed("missing metadata.json")
        }
        let metadataData = try Data(contentsOf: metadataURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(Metadata.self, from: metadataData)
        guard ["epistoria-export/1", "epistoria-export/2", "epistoria-export/3", "epistoria-export/4"].contains(metadata.formatVersion),
              metadata.mode == "DECRYPTED",
              metadata.accountId == accountId
        else {
            throw EpistoriaExportError.validationFailed("unsupported metadata version or mode")
        }
        if ["epistoria-export/2", "epistoria-export/3", "epistoria-export/4"].contains(metadata.formatVersion) {
            required.append("notes/canvas-assets.json")
        }
        if metadata.formatVersion == "epistoria-export/3" || metadata.formatVersion == "epistoria-export/4" {
            required.append(contentsOf: ["taxonomy.json", "knowledge.json", "learning.json"])
        }
        for path in required where !fileManager.fileExists(
            atPath: directory.appendingPathComponent(path).path
        ) {
            throw EpistoriaExportError.validationFailed("missing \(path)")
        }
        let manifestURL = directory.appendingPathComponent("checksums.sha256")
        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
        var expected: [String: String] = [:]
        for line in manifest.split(whereSeparator: { $0.isNewline }) {
            let raw = String(line)
            guard raw.count > 66 else {
                throw EpistoriaExportError.validationFailed("malformed checksum manifest")
            }
            let digestEnd = raw.index(raw.startIndex, offsetBy: 64)
            let pathStart = raw.index(digestEnd, offsetBy: 2)
            guard raw[digestEnd ..< pathStart] == "  " else {
                throw EpistoriaExportError.validationFailed("malformed checksum separator")
            }
            let digest = String(raw[..<digestEnd])
            let path = String(raw[pathStart...])
            let pathComponents = path.split(separator: "/", omittingEmptySubsequences: false)
            guard digest.count == 64,
                  digest == digest.lowercased(),
                  digest.allSatisfy(\.isHexDigit),
                  !path.isEmpty,
                  !path.hasPrefix("/"),
                  !path.contains("\\"),
                  path != "checksums.sha256",
                  pathComponents.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  expected[path] == nil
            else {
                throw EpistoriaExportError.validationFailed("invalid or duplicate checksum entry")
            }
            expected[path] = digest
        }
        let files = try regularFiles(in: directory).filter { $0.lastPathComponent != "checksums.sha256" }
        var total: Int64 = 0
        for file in files {
            let relative = relativePath(file, under: directory)
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            total += Int64(data.count)
            guard expected[relative] == sha256(data) else {
                throw EpistoriaExportError.validationFailed("checksum mismatch for \(relative)")
            }
            if file.pathExtension == "json" {
                guard (try? JSONSerialization.jsonObject(with: data)) != nil else {
                    throw EpistoriaExportError.invalidJSON(relative)
                }
            }
        }
        guard expected.count == files.count else {
            throw EpistoriaExportError.validationFailed("checksum manifest has unexpected entries")
        }
        return EpistoriaExportValidation(fileCount: files.count + 1, byteCount: total)
    }

    private func writeChecksums(in directory: URL) throws {
        let files = try regularFiles(in: directory)
            .filter { $0.lastPathComponent != "checksums.sha256" }
            .sorted { relativePath($0, under: directory) < relativePath($1, under: directory) }
        let lines = try files.map { file in
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            return "\(sha256(data))  \(relativePath(file, under: directory))"
        }
        try protectedWrite(
            Data((lines.joined(separator: "\n") + "\n").utf8),
            to: directory.appendingPathComponent("checksums.sha256")
        )
    }

    private func regularFiles(in directory: URL) throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else { return [] }
        return try enumerator.compactMap { value in
            guard let url = value as? URL else { return nil }
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            if values.isSymbolicLink == true {
                throw EpistoriaExportError.validationFailed("symbolic links are not allowed")
            }
            guard values.isRegularFile == true else { return nil }
            return url
        }
    }

    private func relativePath(_ url: URL, under directory: URL) -> String {
        String(url.path.dropFirst(directory.path.count + 1))
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func imageExtension(for mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/jpeg": "jpg"
        case "image/png": "png"
        case "image/gif": "gif"
        case "image/heic", "image/heif": "heic"
        case "image/tiff": "tiff"
        case "image/webp": "webp"
        default: "image"
        }
    }

    private func createArchive(from directory: URL) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss'Z'"
        let destination = fileManager.temporaryDirectory.appendingPathComponent(
            "Epistoria-\(formatter.string(from: .now))-\(UUID().uuidString.lowercased()).zip"
        )
        let partial = destination.deletingPathExtension().appendingPathExtension("partial")
        #if os(iOS)
        let attributes: [FileAttributeKey: Any] = [
            .protectionKey: FileProtectionType.complete,
        ]
        #else
        let attributes: [FileAttributeKey: Any] = [:]
        #endif
        guard fileManager.createFile(
            atPath: partial.path,
            contents: nil,
            attributes: attributes
        ) else { throw EpistoriaExportError.archiveCreationFailed }
        var coordinationError: NSError?
        let result = CoordinationResult()
        NSFileCoordinator().coordinate(
            readingItemAt: directory,
            options: .forUploading,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                let source = try FileHandle(forReadingFrom: coordinatedURL)
                let output = try FileHandle(forWritingTo: partial)
                defer {
                    try? source.close()
                    try? output.close()
                }
                while true {
                    try Task.checkCancellation()
                    guard let chunk = try source.read(upToCount: 1_048_576), !chunk.isEmpty else {
                        break
                    }
                    try output.write(contentsOf: chunk)
                }
                try output.synchronize()
                try output.close()
                try source.close()
                #if os(iOS)
                try fileManager.setAttributes(
                    [.protectionKey: FileProtectionType.complete],
                    ofItemAtPath: partial.path
                )
                #endif
                try fileManager.moveItem(at: partial, to: destination)
                result.produced = true
            } catch {
                result.copyError = error
            }
        }
        if let coordinationError {
            try? fileManager.removeItem(at: partial)
            try? fileManager.removeItem(at: destination)
            throw coordinationError
        }
        if let copyError = result.copyError {
            try? fileManager.removeItem(at: partial)
            try? fileManager.removeItem(at: destination)
            throw copyError
        }
        guard result.produced else {
            try? fileManager.removeItem(at: partial)
            try? fileManager.removeItem(at: destination)
            throw EpistoriaExportError.archiveCreationFailed
        }
        return destination
    }

    private func cleanupStaleTemporaryExports(now: Date = .now) throws {
        let directory = fileManager.temporaryDirectory
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsSubdirectoryDescendants]
        )
        let cutoff = now.addingTimeInterval(-24 * 60 * 60)
        for url in urls {
            let name = url.lastPathComponent
            let isStaging = name.hasPrefix("EpistoriaExport-")
            let isArchive = name.hasPrefix("Epistoria-")
                && url.pathExtension.lowercased() == "zip"
            let isPartial = name.hasPrefix("Epistoria-")
                && url.pathExtension.lowercased() == "partial"
            guard isStaging || isArchive || isPartial else { continue }
            if isPartial {
                try fileManager.removeItem(at: url)
                continue
            }
            let modified = try url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate ?? .distantPast
            if modified < cutoff {
                try fileManager.removeItem(at: url)
            }
        }
    }
}
