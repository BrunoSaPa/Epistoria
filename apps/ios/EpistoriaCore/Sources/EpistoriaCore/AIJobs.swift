import Foundation

public enum DigestSourceKind: String, Codable, Sendable {
    case noteBlock = "NOTE_BLOCK"
    case annotation = "ANNOTATION"
    case pdfPage = "PDF_PAGE"
}

// MARK: - Note Query types

public enum NoteQuerySourceKind: String, Codable, Sendable {
    case noteBlock = "NOTE_BLOCK"
    case lassoSelection = "LASSO_SELECTION"
}

public struct NoteQuerySourceExcerpt: Codable, Equatable, Sendable {
    public var sourceId: UUID
    public var sourceKind: NoteQuerySourceKind
    public var title: String
    public var locator: String
    /// Plain text content. Present for text blocks and transcribed drawing blocks.
    public var excerpt: String?
    /// Base64-encoded PNG of a drawing block region. Nil for text-only sources.
    public var imageContent: String?

    public init(
        sourceId: UUID,
        sourceKind: NoteQuerySourceKind,
        title: String,
        locator: String,
        excerpt: String? = nil,
        imageContent: String? = nil
    ) {
        self.sourceId = sourceId
        self.sourceKind = sourceKind
        self.title = title
        self.locator = locator
        self.excerpt = excerpt
        self.imageContent = imageContent
    }
}

public struct NoteQueryRequest: Codable, Equatable, Sendable {
    public var schemaVersion = "note-query-request/v1"
    public var accountId: UUID
    public var jobId: UUID
    public var noteId: UUID
    public var noteTitle: String?
    public var question: String
    /// Blocks that the user lasso-selected — at most 10.
    public var selectionSources: [NoteQuerySourceExcerpt]
    /// All other blocks from the same note for context — at most 200.
    public var contextSources: [NoteQuerySourceExcerpt]
    public var disclosureAcknowledged: Bool
}

public struct NoteQueryResponse: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var answer: String
    public var citedSourceIds: [UUID]
    public var followUpQuestions: [String]

    public init(
        schemaVersion: String,
        answer: String,
        citedSourceIds: [UUID],
        followUpQuestions: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.answer = answer
        self.citedSourceIds = citedSourceIds
        self.followUpQuestions = followUpQuestions
    }
}

public struct NoteQueryArtifact: EntityPayload, Equatable {
    public static let entityType = EntityType.aiArtifact
    public var schemaVersion: String
    public var jobId: UUID
    /// The note this artifact is linked to (used as the entity's parentId).
    public var noteId: UUID
    public var question: String
    public var generatedAt: Date
    public var sourceIds: [UUID]
    public var trace: ProviderTrace
    public var response: NoteQueryResponse

    // Review state — set by the owner on the iPad, never by the worker.
    public var reviewState: AIArtifactReviewState?
    public var reviewedAt: Date?
    public var editedResponse: NoteQueryResponse?

    public var createdAt: Date { generatedAt }
    public var updatedAt: Date { reviewedAt ?? generatedAt }
}

public struct PreparedNoteQueryRequest: Equatable, Sendable {
    public var request: NoteQueryRequest
    public var selectionCount: Int
    public var contextCount: Int
    public var hasImages: Bool
    public var approximateTokens: Int
}

public struct DigestSourceExcerpt: Codable, Equatable, Sendable {
    public var sourceId: UUID
    public var sourceKind: DigestSourceKind
    public var title: String
    public var locator: String
    public var excerpt: String
}

public struct SessionDigestRequest: Codable, Equatable, Sendable {
    public var schemaVersion = "session-digest-request/v1"
    public var accountId: UUID
    public var jobId: UUID
    public var sessionId: UUID
    public var courseId: UUID?
    public var sessionTitle: String
    public var startedAt: Date
    public var endedAt: Date
    public var sources: [DigestSourceExcerpt]
    public var userInstructions: String?
    public var disclosureAcknowledged: Bool
}

public struct CitedStatement: Codable, Equatable, Sendable, Identifiable {
    public var id: String { text + sourceIds.map(\.uuidString).joined() }
    public var text: String
    public var sourceIds: [UUID]
}

public struct SessionDigest: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var title: String
    public var summary: String
    public var keyPoints: [CitedStatement]
    public var possibleMisconceptions: [CitedStatement]
    public var followUpQuestions: [String]
}

public struct ProviderTrace: Codable, Equatable, Sendable {
    public var provider: String
    public var model: String
    public var promptVersion: String
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var estimatedCostUsd: Double?
    public var providerRequestId: String?
}

public enum AIArtifactReviewState: String, Codable, Sendable {
    case accepted = "ACCEPTED"
    case edited = "EDITED"
    case rejected = "REJECTED"
}

public struct SessionDigestArtifact: EntityPayload, Equatable {
    public static let entityType = EntityType.aiArtifact
    public var schemaVersion: String
    public var jobId: UUID
    public var sessionId: UUID
    public var generatedAt: Date
    public var sourceIds: [UUID]
    public var trace: ProviderTrace
    public var digest: SessionDigest

    // The trusted worker does not set review fields. They are added by the person using
    // the iPad and sync as part of the encrypted artifact.
    public var reviewState: AIArtifactReviewState?
    public var reviewedAt: Date?
    public var editedDigest: SessionDigest?

    public var createdAt: Date { generatedAt }
    public var updatedAt: Date { reviewedAt ?? generatedAt }
}

public struct DigestDisclosurePreview: Equatable, Sendable {
    public var sourceCount: Int
    public var characterCount: Int
    public var approximateTokens: Int
    public var sourceTitles: [String]
}

public struct PreparedDigestRequest: Equatable, Sendable {
    public var request: SessionDigestRequest
    public var preview: DigestDisclosurePreview
}

public struct PDFExtractionRequest: Codable, Equatable, Sendable {
    public var schemaVersion = "pdf-extraction-request/v1"
    public var accountId: UUID
    public var jobId: UUID
    public var resourceId: UUID
    public var assetId: UUID
    public var assetKey: String
    public var expectedDedupeTag: String
    public var title: String
}

public struct ExtractedPDFPage: Codable, Equatable, Sendable {
    public var pageNumber: Int
    public var text: String
    public var characterCount: Int
    public var needsOcr: Bool
}

public struct PDFExtractionChunk: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var jobId: UUID
    public var resourceId: UUID
    public var chunkIndex: Int
    public var pages: [ExtractedPDFPage]
}

public struct PDFExtractionManifest: EntityPayload, Equatable {
    public static let entityType = EntityType.aiArtifact
    public var schemaVersion: String
    public var jobId: UUID
    public var resourceId: UUID
    public var generatedAt: Date
    public var pageCount: Int
    public var characterCount: Int
    public var pagesNeedingOcr: [Int]
    public var chunkEntityIds: [UUID]

    public var createdAt: Date { generatedAt }
    public var updatedAt: Date { generatedAt }
}

public enum AIJobCoordinatorError: Error, Equatable {
    case sessionNotEnded
    case noReadableSources
    case disclosureNotAcknowledged
    case resourceHasNoPDF
}

public actor AIJobCoordinator {
    private let accountId: UUID
    private let accountKey: Data
    private let database: SQLCipherDatabase
    private let store: EpistoriaStore
    private let api: EpistoriaAPIClient
    private let crypto = EntityCrypto()

    public init(
        accountId: UUID,
        accountKey: Data,
        store: EpistoriaStore,
        api: EpistoriaAPIClient
    ) {
        self.accountId = accountId
        self.accountKey = accountKey
        self.store = store
        database = store.database
        self.api = api
    }

    public func prepareSessionDigest(
        sessionId: UUID,
        userInstructions: String? = nil
    ) async throws -> PreparedDigestRequest {
        let session = try await store.payload(StudySessionPayload.self, id: sessionId).payload
        guard session.state == .ended, let endedAt = session.endedAt else {
            throw AIJobCoordinatorError.sessionNotEnded
        }
        var sources: [DigestSourceExcerpt] = []
        let notes = try await store.list(NotePayload.self)
            .filter { $0.payload.studySessionId == sessionId }
        for note in notes {
            let blocks = try await store.list(NoteBlockPayload.self, parentId: note.id)
                .sorted { $0.payload.orderKey < $1.payload.orderKey }
            for block in blocks {
                let text = [block.payload.plainText, block.payload.transcription]
                    .compactMap(\ .self)
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                sources.append(
                    DigestSourceExcerpt(
                        sourceId: block.id,
                        sourceKind: .noteBlock,
                        title: note.payload.title,
                        locator: "block \(block.payload.orderKey)",
                        excerpt: String(text.prefix(12_000))
                    )
                )
            }
        }
        let annotations = try await store.list(AnnotationPayload.self)
            .filter { $0.payload.studySessionId == sessionId }
        for annotation in annotations {
            let text = [annotation.payload.selectedText, annotation.payload.comment]
                .compactMap(\ .self)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            sources.append(
                DigestSourceExcerpt(
                    sourceId: annotation.id,
                    sourceKind: .annotation,
                    title: annotation.payload.annotationType.rawValue.capitalized,
                    locator: annotation.payload.pageNumber.map { "page \($0)" } ?? "annotation",
                    excerpt: String(text.prefix(12_000))
                )
            )
        }
        guard !sources.isEmpty else { throw AIJobCoordinatorError.noReadableSources }
        sources = Array(sources.prefix(200))
        let jobId = UUID()
        let request = SessionDigestRequest(
            accountId: accountId,
            jobId: jobId,
            sessionId: sessionId,
            courseId: session.courseId,
            sessionTitle: session.title,
            startedAt: session.startedAt,
            endedAt: endedAt,
            sources: sources,
            userInstructions: userInstructions,
            disclosureAcknowledged: false
        )
        let characters = sources.reduce(0) { $0 + $1.excerpt.count }
        return PreparedDigestRequest(
            request: request,
            preview: DigestDisclosurePreview(
                sourceCount: sources.count,
                characterCount: characters,
                approximateTokens: max(1, characters / 4),
                sourceTitles: Array(Set(sources.map(\.title))).sorted()
            )
        )
    }

    public func submitSessionDigest(_ prepared: PreparedDigestRequest) async throws -> AIJobSummary {
        var request = prepared.request
        guard !request.sources.isEmpty else { throw AIJobCoordinatorError.noReadableSources }
        request.disclosureAcknowledged = true
        let plaintext = try CanonicalJSON.encode(request)
        let envelope = try crypto.encryptJob(
            plaintext,
            accountKey: accountKey,
            accountId: accountId,
            jobType: "SESSION_DIGEST",
            jobId: request.jobId
        )
        return try await api.createAIJob(
            id: request.jobId,
            type: "SESSION_DIGEST",
            envelope: envelope
        )
    }

    public func latestDigest(sessionId: UUID) async throws -> IdentifiedPayload<SessionDigestArtifact>? {
        let entities = try await database.entities(type: .aiArtifact, parentId: sessionId)
        for entity in entities {
            if let artifact = try? CanonicalJSON.decode(
                SessionDigestArtifact.self,
                from: entity.content
            ) {
                return IdentifiedPayload(
                    id: entity.id,
                    payload: artifact,
                    revision: entity.revision,
                    syncState: entity.syncState
                )
            }
        }
        return nil
    }

    public func submitPDFExtraction(resourceId: UUID) async throws -> AIJobSummary {
        let resource = try await store.payload(ResourcePayload.self, id: resourceId).payload
        guard resource.resourceType == .pdf, let assetId = resource.originalAssetId else {
            throw AIJobCoordinatorError.resourceHasNoPDF
        }
        let asset = try await store.payload(AssetPayload.self, id: assetId).payload
        let jobId = UUID()
        let request = PDFExtractionRequest(
            accountId: accountId,
            jobId: jobId,
            resourceId: resourceId,
            assetId: assetId,
            assetKey: asset.assetKey,
            expectedDedupeTag: asset.dedupeTag,
            title: resource.title
        )
        let envelope = try crypto.encryptJob(
            CanonicalJSON.encode(request),
            accountKey: accountKey,
            accountId: accountId,
            jobType: "PDF_EXTRACTION",
            jobId: jobId
        )
        return try await api.createAIJob(id: jobId, type: "PDF_EXTRACTION", envelope: envelope)
    }

    public func latestPDFExtraction(
        resourceId: UUID
    ) async throws -> IdentifiedPayload<PDFExtractionManifest>? {
        let entities = try await database.entities(type: .aiArtifact, parentId: resourceId)
        for entity in entities {
            if let artifact = try? CanonicalJSON.decode(PDFExtractionManifest.self, from: entity.content),
               artifact.resourceId == resourceId
            {
                return IdentifiedPayload(
                    id: entity.id,
                    payload: artifact,
                    revision: entity.revision,
                    syncState: entity.syncState
                )
            }
        }
        return nil
    }

    // MARK: - Note Query

    public func prepareNoteQuery(
        noteId: UUID,
        selectedBlockIds: [UUID],
        selectionImagesByBlockId: [UUID: Data],
        question: String
    ) async throws -> PreparedNoteQueryRequest {
        guard !selectedBlockIds.isEmpty else {
            throw AIJobCoordinatorError.noReadableSources
        }
        let note = try await store.payload(NotePayload.self, id: noteId).payload
        let allBlocks = try await store.list(NoteBlockPayload.self, parentId: noteId)
            .sorted { $0.payload.orderKey < $1.payload.orderKey }

        let selectedSet = Set(selectedBlockIds)
        var selectionSources: [NoteQuerySourceExcerpt] = []
        var contextSources: [NoteQuerySourceExcerpt] = []

        for block in allBlocks {
            let isSelected = selectedSet.contains(block.id)
            if isSelected {
                if let imageData = selectionImagesByBlockId[block.id] {
                    // Selected Pencil or canvas-image visual — send as a bounded PNG.
                    selectionSources.append(
                        NoteQuerySourceExcerpt(
                            sourceId: block.id,
                            sourceKind: .lassoSelection,
                            title: note.title,
                            locator: "selected visual \(block.payload.orderKey)",
                            imageContent: imageData.base64EncodedString()
                        )
                    )
                } else {
                    // Text item (or handwriting with transcription).
                    let text = [block.payload.plainText, block.payload.transcription]
                        .compactMap(\.self)
                        .joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    selectionSources.append(
                        NoteQuerySourceExcerpt(
                            sourceId: block.id,
                            sourceKind: .noteBlock,
                            title: note.title,
                            locator: "canvas item \(block.payload.orderKey)",
                            excerpt: String(text.prefix(12_000))
                        )
                    )
                }
            } else {
                // Context-only: text and transcriptions, no images.
                let text = [block.payload.plainText, block.payload.transcription]
                    .compactMap(\.self)
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                contextSources.append(
                    NoteQuerySourceExcerpt(
                        sourceId: block.id,
                        sourceKind: .noteBlock,
                        title: note.title,
                        locator: "context item \(block.payload.orderKey)",
                        excerpt: String(text.prefix(12_000))
                    )
                )
            }
        }

        guard !selectionSources.isEmpty else {
            throw AIJobCoordinatorError.noReadableSources
        }
        selectionSources = Array(selectionSources.prefix(10))
        contextSources = Array(contextSources.prefix(200))

        let jobId = UUID()
        let request = NoteQueryRequest(
            accountId: accountId,
            jobId: jobId,
            noteId: noteId,
            noteTitle: note.title,
            question: question,
            selectionSources: selectionSources,
            contextSources: contextSources,
            disclosureAcknowledged: false
        )
        let hasImages = selectionSources.contains { $0.imageContent != nil }
        let characters = (selectionSources + contextSources)
            .compactMap(\.excerpt)
            .reduce(0) { $0 + $1.count }
        let imageTokenEstimate = selectionSources.filter { $0.imageContent != nil }.count * 500
        return PreparedNoteQueryRequest(
            request: request,
            selectionCount: selectionSources.count,
            contextCount: contextSources.count,
            hasImages: hasImages,
            approximateTokens: max(1, characters / 4 + imageTokenEstimate)
        )
    }

    public func submitNoteQuery(_ prepared: PreparedNoteQueryRequest) async throws -> AIJobSummary {
        var request = prepared.request
        guard !request.selectionSources.isEmpty else {
            throw AIJobCoordinatorError.noReadableSources
        }
        request.disclosureAcknowledged = true
        let plaintext = try CanonicalJSON.encode(request)
        let envelope = try crypto.encryptJob(
            plaintext,
            accountKey: accountKey,
            accountId: accountId,
            jobType: "NOTE_QUERY",
            jobId: request.jobId
        )
        return try await api.createAIJob(
            id: request.jobId,
            type: "NOTE_QUERY",
            envelope: envelope
        )
    }

    public func latestNoteQueryArtifacts(
        noteId: UUID
    ) async throws -> [IdentifiedPayload<NoteQueryArtifact>] {
        let entities = try await database.entities(type: .aiArtifact, parentId: noteId)
        return entities.compactMap { entity in
            guard let artifact = try? CanonicalJSON.decode(NoteQueryArtifact.self, from: entity.content),
                  artifact.noteId == noteId
            else { return nil }
            return IdentifiedPayload(
                id: entity.id,
                payload: artifact,
                revision: entity.revision,
                syncState: entity.syncState
            )
        }
        .sorted { $0.payload.generatedAt > $1.payload.generatedAt }
    }
}
