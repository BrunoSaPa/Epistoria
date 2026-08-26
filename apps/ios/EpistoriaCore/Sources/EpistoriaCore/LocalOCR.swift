import CryptoKit
import Foundation

public enum LocalOCRMode: String, Codable, CaseIterable, Sendable {
    case text = "TEXT"
    case formula = "FORMULA"
    case mixed = "MIXED"
}

public enum LocalOCRTargetKind: String, Codable, CaseIterable, Sendable {
    case notebookRegion = "NOTEBOOK_REGION"
    case image = "IMAGE"
    case sourcePage = "SOURCE_PAGE"
}

public enum LocalOCRContentKind: String, Codable, CaseIterable, Sendable {
    case text = "TEXT"
    case formula = "FORMULA"
}

public enum LocalOCREngineKind: String, Codable, CaseIterable, Sendable {
    case appleVision = "APPLE_VISION"
    case coreMLFormula = "CORE_ML_FORMULA"
    case ppFormulaNetPlusS = "PP_FORMULANET_PLUS_S"
    case deterministic = "DETERMINISTIC"
}

public enum OCRArtifactState: String, Codable, CaseIterable, Sendable {
    case current = "CURRENT"
    case stale = "STALE"
}

public struct LocalOCRRegion: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: LocalOCRContentKind
    public var text: String
    public var latex: String?
    public var normalizedExpression: String?
    public var confidence: Double?
    public var alternatives: [String]
    public var rectangles: [AnnotationRectangle]

    public init(
        id: UUID = UUID(),
        kind: LocalOCRContentKind,
        text: String,
        latex: String? = nil,
        normalizedExpression: String? = nil,
        confidence: Double? = nil,
        alternatives: [String] = [],
        rectangles: [AnnotationRectangle] = []
    ) {
        self.id = id
        self.kind = kind
        self.text = String(text.prefix(20_000))
        self.latex = latex.map { String($0.prefix(20_000)) }
        self.normalizedExpression = normalizedExpression.map { String($0.prefix(8_000)) }
        self.confidence = confidence.map { min(max($0.isFinite ? $0 : 0, 0), 1) }
        self.alternatives = Array(alternatives.prefix(5)).map { String($0.prefix(8_000)) }
        self.rectangles = Array(rectangles.prefix(64))
    }
}

public struct LocalOCRRequest: Codable, Equatable, Sendable {
    public var schemaVersion = "local-ocr-request/v1"
    public var accountId: UUID
    public var jobId: UUID
    public var targetKind: LocalOCRTargetKind
    public var targetId: UUID
    public var parentId: UUID
    public var noteId: UUID?
    public var sourceVersionId: UUID?
    public var inputRevision: Int
    public var pageNumber: Int?
    public var locator: SourceLocator?
    public var imageContent: String
    public var preferredLanguages: [String]
    public var mode: LocalOCRMode
    public var disclosureAcknowledged: Bool

    public init(
        accountId: UUID,
        jobId: UUID = UUID(),
        targetKind: LocalOCRTargetKind,
        targetId: UUID,
        parentId: UUID,
        noteId: UUID? = nil,
        sourceVersionId: UUID? = nil,
        inputRevision: Int,
        pageNumber: Int? = nil,
        locator: SourceLocator? = nil,
        imageData: Data,
        preferredLanguages: [String] = [],
        mode: LocalOCRMode,
        disclosureAcknowledged: Bool = true
    ) {
        self.accountId = accountId
        self.jobId = jobId
        self.targetKind = targetKind
        self.targetId = targetId
        self.parentId = parentId
        self.noteId = noteId
        self.sourceVersionId = sourceVersionId
        self.inputRevision = max(inputRevision, 0)
        self.pageNumber = pageNumber
        self.locator = locator
        imageContent = imageData.base64EncodedString()
        self.preferredLanguages = Array(Set(preferredLanguages.map {
            String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
        }.filter { !$0.isEmpty })).sorted()
        self.mode = mode
        self.disclosureAcknowledged = disclosureAcknowledged
    }
}

public struct LocalOCRResponse: Codable, Equatable, Sendable {
    public var schemaVersion = "local-ocr-response/v1"
    public var engine: LocalOCREngineKind
    public var engineVersion: String
    public var modelVersion: String?
    public var recognitionVersion: Int?
    public var regions: [LocalOCRRegion]
    public var warnings: [String]

    public init(
        engine: LocalOCREngineKind,
        engineVersion: String,
        modelVersion: String? = nil,
        recognitionVersion: Int? = nil,
        regions: [LocalOCRRegion],
        warnings: [String] = []
    ) {
        self.engine = engine
        self.engineVersion = String(engineVersion.prefix(128))
        self.modelVersion = modelVersion.map { String($0.prefix(128)) }
        self.recognitionVersion = recognitionVersion
        self.regions = Array(regions.prefix(256))
        self.warnings = Array(warnings.prefix(20)).map { String($0.prefix(500)) }
    }
}

public struct ResolvedOCRRegion: Equatable, Sendable {
    public var region: LocalOCRRegion
    public var content: String

    public init(region: LocalOCRRegion, content: String) {
        self.region = region
        self.content = content
    }
}

public struct OCRArtifactPayload: EntityPayload, Equatable {
    public static let entityType = EntityType.recognitionArtifact
    public var schemaVersion = "recognition-artifact/v1"
    public var jobId: UUID
    public var targetKind: LocalOCRTargetKind
    public var targetId: UUID
    public var parentId: UUID
    public var noteId: UUID?
    public var sourceVersionId: UUID?
    public var inputRevision: Int
    public var inputFingerprint: String
    public var pageNumber: Int?
    public var locator: SourceLocator?
    /// A bounded encrypted preview used only to compare the result with the original selection.
    public var inputPreview: String?
    public var generatedAt: Date
    public var state: OCRArtifactState
    public var response: LocalOCRResponse
    public var reviewState: AIArtifactReviewState?
    public var reviewedAt: Date?

    public var createdAt: Date { generatedAt }
    public var updatedAt: Date { reviewedAt ?? generatedAt }

    public init(request: LocalOCRRequest, response: LocalOCRResponse, generatedAt: Date = .now) {
        jobId = request.jobId
        targetKind = request.targetKind
        targetId = request.targetId
        parentId = request.parentId
        noteId = request.noteId
        sourceVersionId = request.sourceVersionId
        inputRevision = request.inputRevision
        inputFingerprint = SHA256.hash(data: Data(request.imageContent.utf8))
            .map { String(format: "%02x", $0) }.joined()
        pageNumber = request.pageNumber
        locator = request.locator
        inputPreview = request.imageContent.count <= 900_000 ? request.imageContent : nil
        self.generatedAt = generatedAt
        state = .current
        self.response = response
        reviewState = nil
        reviewedAt = nil
    }

    public var recognizedText: String {
        response.regions.map { region in
            region.latex?.isEmpty == false ? region.latex! : region.text
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

public struct OCRCorrectionPayload: EntityPayload, Equatable {
    public static let entityType = EntityType.recognitionDecision
    public var schemaVersion = "recognition-decision/v1"
    public var artifactId: UUID
    public var regionId: UUID
    public var targetId: UUID
    public var originalText: String
    public var correctedText: String
    public var reason: String?
    /// Corrections remain immutable. Supersession is represented by a newer correction that
    /// points at this record; parallel leaf records are treated as a conflict.
    public var state: OCRCorrectionState?
    public var supersedesCorrectionId: UUID?
    public var supersedesCorrectionIds: [UUID]?
    public var conflictsWithCorrectionId: UUID?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        artifactId: UUID,
        regionId: UUID,
        targetId: UUID,
        originalText: String,
        correctedText: String,
        reason: String? = nil,
        supersedesCorrectionId: UUID? = nil,
        supersedesCorrectionIds: [UUID] = [],
        conflictsWithCorrectionId: UUID? = nil,
        now: Date = .now
    ) {
        self.artifactId = artifactId
        self.regionId = regionId
        self.targetId = targetId
        self.originalText = String(originalText.prefix(20_000))
        self.correctedText = String(correctedText.prefix(20_000))
        self.reason = reason.map { String($0.prefix(1_000)) }
        state = .active
        self.supersedesCorrectionId = supersedesCorrectionId
        self.supersedesCorrectionIds = supersedesCorrectionIds.isEmpty
            ? nil : Array(Set(supersedesCorrectionIds)).sorted { $0.uuidString < $1.uuidString }
        self.conflictsWithCorrectionId = conflictsWithCorrectionId
        createdAt = now
        updatedAt = now
    }
}

public enum OCRCorrectionState: String, Codable, Sendable {
    case active = "ACTIVE"
    case conflicted = "CONFLICTED"
    case retracted = "RETRACTED"
}

public enum OCRReviewAction: String, Codable, Sendable {
    case accept = "ACCEPT"
    case reject = "REJECT"
    case acceptCorrection = "ACCEPT_CORRECTION"
}

/// Append-only owner review event. `OCRArtifactPayload.reviewState` remains a materialized summary
/// for compatibility with existing readers; this record preserves the action history and sync
/// conflict candidates independently.
public struct OCRReviewDecisionPayload: EntityPayload, Equatable {
    public static let entityType = EntityType.recognitionDecision
    public var schemaVersion = "recognition-decision/v1"
    public var artifactId: UUID
    public var targetId: UUID
    public var action: OCRReviewAction
    public var deviceId: UUID?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        artifactId: UUID,
        targetId: UUID,
        action: OCRReviewAction,
        deviceId: UUID? = nil,
        now: Date = .now
    ) {
        self.artifactId = artifactId
        self.targetId = targetId
        self.action = action
        self.deviceId = deviceId
        createdAt = now
        updatedAt = now
    }
}

public enum LocalModelControlOperation: String, Codable, Sendable {
    case status = "STATUS"
    case install = "INSTALL"
    case remove = "REMOVE"
}

public enum LocalModelInstallationState: String, Codable, Sendable {
    case notInstalled = "NOT_INSTALLED"
    case installed = "INSTALLED"
    case invalid = "INVALID"
}

public struct LocalModelControlRequest: Codable, Equatable, Sendable {
    public var schemaVersion = "local-model-control-request/v1"
    public var accountId: UUID
    public var jobId: UUID
    public var operation: LocalModelControlOperation
    public var modelId: String
    public var disclosureAcknowledged: Bool

    public init(
        accountId: UUID,
        jobId: UUID = UUID(),
        operation: LocalModelControlOperation,
        modelId: String = "PP-FormulaNet_plus-S",
        disclosureAcknowledged: Bool = true
    ) {
        self.accountId = accountId
        self.jobId = jobId
        self.operation = operation
        self.modelId = modelId
        self.disclosureAcknowledged = disclosureAcknowledged
    }
}

public struct LocalModelStatusArtifact: EntityPayload, Equatable {
    public static let entityType = EntityType.aiArtifact
    public var schemaVersion = "ai-artifact/local-model-status/v1"
    public var jobId: UUID
    public var modelId: String
    public var modelVersion: String
    public var operation: LocalModelControlOperation
    public var state: LocalModelInstallationState
    public var expectedBytes: Int64
    public var verifiedBytes: Int64
    public var license: String
    public var checkedAt: Date

    public var createdAt: Date { checkedAt }
    public var updatedAt: Date { checkedAt }
}

public extension AIJobCoordinator {
    func submitLocalOCR(_ request: LocalOCRRequest) async throws -> AIJobSummary {
        guard request.accountId == accountId,
              request.disclosureAcknowledged,
              request.schemaVersion == "local-ocr-request/v1",
              request.inputRevision >= 0,
              !request.imageContent.isEmpty,
              request.imageContent.count <= 1_100_000
        else { throw AIJobCoordinatorError.disclosureNotAcknowledged }
        let envelope = try EntityCrypto().encryptJob(
            CanonicalJSON.encode(request),
            accountKey: accountKey,
            accountId: accountId,
            jobType: "LOCAL_OCR",
            jobId: request.jobId
        )
        return try await api.createAIJob(id: request.jobId, type: "LOCAL_OCR", envelope: envelope)
    }

    func submitLocalModelControl(_ request: LocalModelControlRequest) async throws -> AIJobSummary {
        guard request.accountId == accountId,
              request.disclosureAcknowledged,
              request.schemaVersion == "local-model-control-request/v1"
        else { throw AIJobCoordinatorError.disclosureNotAcknowledged }
        let envelope = try EntityCrypto().encryptJob(
            CanonicalJSON.encode(request),
            accountKey: accountKey,
            accountId: accountId,
            jobType: "LOCAL_MODEL_CONTROL",
            jobId: request.jobId
        )
        return try await api.createAIJob(
            id: request.jobId,
            type: "LOCAL_MODEL_CONTROL",
            envelope: envelope
        )
    }

    func localProcessingJob(id: UUID) async throws -> AIJobSummary {
        try await api.aiJob(id: id)
    }

    func cancelLocalProcessingJob(id: UUID) async throws -> AIJobSummary {
        try await api.cancelAIJob(id: id)
    }
}

public extension EpistoriaStore {
    func localModelStatuses() async throws -> [IdentifiedPayload<LocalModelStatusArtifact>] {
        try await database.entities(type: .aiArtifact).compactMap { entity in
            guard let status = try? CanonicalJSON.decode(
                LocalModelStatusArtifact.self,
                from: entity.content
            ) else { return nil }
            return IdentifiedPayload(
                id: entity.id,
                payload: status,
                revision: entity.revision,
                syncState: entity.syncState
            )
        }.sorted { $0.payload.checkedAt > $1.payload.checkedAt }
    }

    @discardableResult
    func saveOCRArtifact(
        id: UUID = UUID(),
        request: LocalOCRRequest,
        response: LocalOCRResponse,
        generatedAt: Date = .now
    ) async throws -> UUID {
        let artifact = OCRArtifactPayload(
            request: request,
            response: response,
            generatedAt: generatedAt
        )
        let content = try CanonicalJSON.encode(artifact)
        _ = try await database.saveLocal(
            id: id,
            entityType: .recognitionArtifact,
            parentId: request.parentId,
            relationIds: [request.targetId, request.noteId, request.sourceVersionId].compactMap(\.self),
            content: content,
            searchProjection: Self.ocrSearchProjection(artifactId: id, artifact: artifact),
            modifiedAt: generatedAt
        )
        return id
    }

    func ocrArtifacts(parentId: UUID) async throws -> [IdentifiedPayload<OCRArtifactPayload>] {
        try await database.entities(type: .recognitionArtifact, parentId: parentId).compactMap { entity in
            guard let artifact = try? CanonicalJSON.decode(OCRArtifactPayload.self, from: entity.content)
            else { return nil }
            return IdentifiedPayload(
                id: entity.id,
                payload: artifact,
                revision: entity.revision,
                syncState: entity.syncState
            )
        }.sorted { $0.payload.generatedAt > $1.payload.generatedAt }
    }

    func markOCRArtifactsStale(targetId: UUID, exceptInputRevision: Int) async throws {
        let entities = try await database.entities(type: .recognitionArtifact)
        var artifacts: [(UUID, OCRArtifactPayload)] = []
        for entity in entities {
            guard var artifact = try? CanonicalJSON.decode(
                OCRArtifactPayload.self,
                from: entity.content
            ), artifact.targetId == targetId,
                artifact.inputRevision != exceptInputRevision,
                artifact.state == .current
            else { continue }
            artifact.state = .stale
            artifacts.append((entity.id, artifact))
        }
        for (id, artifact) in artifacts {
            let content = try CanonicalJSON.encode(artifact)
            _ = try await database.saveLocal(
                id: id,
                entityType: .recognitionArtifact,
                parentId: artifact.parentId,
                relationIds: [artifact.targetId, artifact.noteId, artifact.sourceVersionId].compactMap(\.self),
                content: content,
                searchProjection: Self.ocrSearchProjection(artifactId: id, artifact: artifact),
                modifiedAt: artifact.updatedAt
            )
        }
    }

    func reviewOCRArtifact(id: UUID, state: AIArtifactReviewState) async throws {
        var artifact = try await payload(OCRArtifactPayload.self, id: id).payload
        if state != .rejected, artifact.state != .current {
            throw StoreError.invalidDraftReview
        }
        if state != .rejected, artifact.targetKind == .notebookRegion {
            let currentTarget = try await payload(NoteBlockPayload.self, id: artifact.targetId)
            guard currentTarget.payload.ocrInputRevision == artifact.inputRevision else {
                throw StoreError.invalidDraftReview
            }
        }
        if state == .accepted || state == .edited {
            guard try await ocrCorrectionConflicts(artifactId: id).isEmpty else {
                throw StoreError.invalidDraftReview
            }
        }
        let action: OCRReviewAction = switch state {
        case .accepted: .accept
        case .edited: .acceptCorrection
        case .rejected: .reject
        }
        _ = try await save(
            payload: OCRReviewDecisionPayload(
                artifactId: id,
                targetId: artifact.targetId,
                action: action
            ),
            parentId: artifact.parentId,
            relationIds: [id, artifact.targetId]
        )
        artifact.reviewState = state
        artifact.reviewedAt = .now
        let content = try CanonicalJSON.encode(artifact)
        _ = try await database.saveLocal(
            id: id,
            entityType: .recognitionArtifact,
            parentId: artifact.parentId,
            relationIds: [artifact.targetId, artifact.noteId, artifact.sourceVersionId].compactMap(\.self),
            content: content,
            searchProjection: Self.ocrSearchProjection(artifactId: id, artifact: artifact),
            modifiedAt: artifact.updatedAt
        )
        try await refreshOCRSearchProjection(artifactId: id)
    }

    func resolvedOCRText(artifactId: UUID) async throws -> String {
        try await resolvedOCRRegions(artifactId: artifactId)
            .map(\.content)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    func resolvedOCRRegions(artifactId: UUID) async throws -> [ResolvedOCRRegion] {
        let artifact = try await payload(OCRArtifactPayload.self, id: artifactId).payload
        let entities = try await database.entities(type: .recognitionDecision)
        let corrections: [(id: UUID, payload: OCRCorrectionPayload)] = entities.compactMap {
            entity -> (id: UUID, payload: OCRCorrectionPayload)? in
            guard let correction = try? CanonicalJSON.decode(
                OCRCorrectionPayload.self,
                from: entity.content
            ), correction.artifactId == artifactId
            else { return nil }
            return (id: entity.id, payload: correction)
        }
        let latest = try Dictionary(grouping: corrections, by: { $0.payload.regionId }).compactMapValues {
            try Self.resolvedOCRCorrection($0)
        }
        return artifact.response.regions.map { region in
            ResolvedOCRRegion(
                region: region,
                content: latest[region.id]?.payload.correctedText ?? region.latex ?? region.text
            )
        }
    }

    @discardableResult
    func createOCRCorrection(
        artifactId: UUID,
        regionId: UUID,
        correctedText: String,
        reason: String? = nil,
        resolvesConflict: Bool = false
    ) async throws -> UUID {
        let artifact = try await payload(OCRArtifactPayload.self, id: artifactId).payload
        guard let region = artifact.response.regions.first(where: { $0.id == regionId }) else {
            throw StoreError.invalidDraftReview
        }
        let clean = correctedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw StoreError.invalidDraftReview }
        let entities = try await database.entities(type: .recognitionDecision)
        let existing: [(id: UUID, payload: OCRCorrectionPayload)] = entities.compactMap {
            entity -> (id: UUID, payload: OCRCorrectionPayload)? in
            guard let correction = try? CanonicalJSON.decode(
                OCRCorrectionPayload.self,
                from: entity.content
            ), correction.artifactId == artifactId,
                correction.regionId == regionId
            else { return nil }
            return (entity.id, correction)
        }
        let superseded = Self.supersededOCRCorrectionIds(existing.map(\.payload))
        let leaves = existing.filter {
            !superseded.contains($0.id)
                && ($0.payload.state ?? OCRCorrectionState.active) != .retracted
        }
        guard leaves.count <= 1 || resolvesConflict else { throw StoreError.invalidDraftReview }
        let correction = OCRCorrectionPayload(
            artifactId: artifactId,
            regionId: regionId,
            targetId: artifact.targetId,
            originalText: region.latex ?? region.text,
            correctedText: clean,
            reason: reason,
            supersedesCorrectionId: leaves.count == 1 ? leaves.first?.id : nil,
            supersedesCorrectionIds: leaves.count > 1 ? leaves.map(\.id) : []
        )
        let id = try await save(
            payload: correction,
            parentId: artifact.parentId,
            relationIds: [artifactId, artifact.targetId]
        )
        try await refreshOCRSearchProjection(artifactId: artifactId)
        return id
    }

    func refreshOCRSearchProjection(artifactId: UUID) async throws {
        let artifact = try await payload(OCRArtifactPayload.self, id: artifactId).payload
        let resolved = try await resolvedOCRRegions(artifactId: artifactId)
        try await database.replaceSearchProjection(
            Self.ocrSearchProjection(
                artifactId: artifactId,
                artifact: artifact,
                resolvedRegions: resolved
            )
        )
    }

    /// Recreates every OCR-derived segment from encrypted recognition entities.
    /// This is safe after synchronization, restore, or deletion of the derived index.
    func rebuildRecognitionSearchProjections() async throws {
        let entities = try await database.entities(type: .recognitionArtifact)
        for entity in entities where !entity.tombstone {
            guard let artifact = try? CanonicalJSON.decode(
                OCRArtifactPayload.self,
                from: entity.content
            ) else { continue }
            let resolved = try? await resolvedOCRRegions(artifactId: entity.id)
            try await database.replaceSearchProjection(
                Self.ocrSearchProjection(
                    artifactId: entity.id,
                    artifact: artifact,
                    resolvedRegions: resolved
                )
            )
        }
    }

    /// Rebuilds both exact and semantic source projections. Authoritative entities are unchanged.
    func rebuildSearchIndexes() async throws {
        try await database.rebuildBaseSearchProjection()
        try await rebuildRecognitionSearchProjections()
        _ = try await database.rebuildSemanticSearchIndex(batchLimit: 256)
    }

    private static func ocrSearchProjection(
        artifactId: UUID,
        artifact: OCRArtifactPayload,
        resolvedRegions: [ResolvedOCRRegion]? = nil
    ) -> SearchProjectionWrite {
        guard artifact.state == .current, artifact.reviewState != .rejected else {
            return SearchProjectionWrite(sourceEntityId: artifactId, segments: [])
        }
        let resolvedById = Dictionary(uniqueKeysWithValues: (resolvedRegions ?? []).compactMap {
            let original = $0.region.latex ?? $0.region.text
            return $0.content == original ? nil : ($0.region.id, $0.content)
        })
        let ownerId = artifact.noteId ?? artifact.parentId
        let origin: SearchSegmentOrigin = switch artifact.targetKind {
        case .notebookRegion: .handwritingOCR
        case .image: .imageOCR
        case .sourcePage: .sourceOCR
        }
        let reviewState: SearchSegmentReviewState = switch artifact.reviewState {
        case .accepted: .accepted
        case .edited: .corrected
        case .rejected: .unreviewed
        case nil: .unreviewed
        }
        let authority = switch reviewState {
        case .authored, .corrected: 100
        case .accepted: 80
        case .unreviewed: 30
        }
        return SearchProjectionWrite(
            sourceEntityId: artifactId,
            segments: artifact.response.regions.compactMap { region in
                let body = resolvedById[region.id] ?? region.latex ?? region.text
                guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                return SearchSegmentWrite(
                    id: region.id,
                    ownerEntityId: ownerId,
                    sourceEntityId: artifactId,
                    origin: resolvedById[region.id] == nil ? origin : .correctedRecognition,
                    reviewState: resolvedById[region.id] == nil ? reviewState : .corrected,
                    authority: resolvedById[region.id] == nil ? authority : 100,
                    title: "",
                    body: body,
                    locator: SearchSegmentLocator(
                        targetId: artifact.targetId,
                        sourceVersionId: artifact.sourceVersionId,
                        pageNumber: artifact.pageNumber,
                        rectangles: region.rectangles.isEmpty
                            ? (artifact.locator?.rectangles ?? []) : region.rectangles,
                        startSeconds: artifact.locator?.startSeconds
                    ),
                    contentRevision: artifact.inputRevision,
                    updatedAt: artifact.updatedAt
                )
            }
        )
    }

    private static func resolvedOCRCorrection(
        _ corrections: [(id: UUID, payload: OCRCorrectionPayload)]
    ) throws -> (id: UUID, payload: OCRCorrectionPayload)? {
        let superseded = supersededOCRCorrectionIds(corrections.map(\.payload))
        let leaves = corrections.filter {
            !superseded.contains($0.id)
                && ($0.payload.state ?? .active) != .retracted
        }
        guard leaves.count <= 1 else { throw StoreError.invalidDraftReview }
        return leaves.first
    }

    func ocrCorrectionConflicts(
        artifactId: UUID
    ) async throws -> [UUID: [String]] {
        let entities = try await database.entities(type: .recognitionDecision)
        let corrections: [(id: UUID, payload: OCRCorrectionPayload)] = entities.compactMap {
            entity -> (id: UUID, payload: OCRCorrectionPayload)? in
            guard let correction = try? CanonicalJSON.decode(
                OCRCorrectionPayload.self,
                from: entity.content
            ), correction.artifactId == artifactId
            else { return nil }
            return (entity.id, correction)
        }
        var result: [UUID: [String]] = [:]
        for (regionId, group) in Dictionary(grouping: corrections, by: { $0.payload.regionId }) {
            let superseded = Self.supersededOCRCorrectionIds(group.map(\.payload))
            let leaves = group.filter {
                !superseded.contains($0.id)
                    && ($0.payload.state ?? .active) != .retracted
            }
            if leaves.count > 1 {
                result[regionId] = leaves.map { $0.payload.correctedText }
            }
        }
        return result
    }

    private static func supersededOCRCorrectionIds(
        _ corrections: [OCRCorrectionPayload]
    ) -> Set<UUID> {
        Set(corrections.flatMap { correction in
            [correction.supersedesCorrectionId].compactMap(\.self)
                + (correction.supersedesCorrectionIds ?? [])
        })
    }
}
