import Foundation

public enum KnowledgeMapNodeKind: String, Codable, Sendable {
    case concept = "CONCEPT"
    case evidence = "EVIDENCE"
}

public struct KnowledgeMapNodePlacement: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID { nodeId }
    public var nodeId: UUID
    public var kind: KnowledgeMapNodeKind
    public var x: Double
    public var y: Double

    public init(nodeId: UUID, kind: KnowledgeMapNodeKind, x: Double, y: Double) {
        self.nodeId = nodeId
        self.kind = kind
        self.x = x
        self.y = y
    }
}

/// Stores only the owner's spatial arrangement. Nodes and edges are rebuilt from durable
/// Concepts, Evidence, and their typed relationships.
public struct KnowledgeMapPayload: EntityPayload, Equatable {
    public static let entityType = EntityType.knowledgeMap
    public var schemaVersion = "knowledge-map/v1"
    public var topicId: UUID
    public var placements: [KnowledgeMapNodePlacement]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        topicId: UUID,
        placements: [KnowledgeMapNodePlacement] = [],
        now: Date = .now
    ) {
        self.topicId = topicId
        self.placements = placements
        createdAt = now
        updatedAt = now
    }
}

public struct KnowledgeMapNode: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var kind: KnowledgeMapNodeKind
    public var title: String
    public var detail: String
    public var x: Double
    public var y: Double
    public var relationCount: Int

    public init(
        id: UUID,
        kind: KnowledgeMapNodeKind,
        title: String,
        detail: String,
        x: Double,
        y: Double,
        relationCount: Int
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.x = x
        self.y = y
        self.relationCount = relationCount
    }
}

public enum KnowledgeMapEdgeKind: String, Sendable {
    case concept = "CONCEPT_LINK"
    case evidence = "CONCEPT_EVIDENCE"
}

public struct KnowledgeMapEdge: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var sourceId: UUID
    public var targetId: UUID
    public var kind: KnowledgeMapEdgeKind
    public var label: String
    public var directed: Bool

    public init(
        id: UUID,
        sourceId: UUID,
        targetId: UUID,
        kind: KnowledgeMapEdgeKind,
        label: String,
        directed: Bool
    ) {
        self.id = id
        self.sourceId = sourceId
        self.targetId = targetId
        self.kind = kind
        self.label = label
        self.directed = directed
    }
}

public struct KnowledgeMapProjection: Equatable, Sendable {
    public var nodes: [KnowledgeMapNode]
    public var edges: [KnowledgeMapEdge]

    public init(nodes: [KnowledgeMapNode], edges: [KnowledgeMapEdge]) {
        self.nodes = nodes
        self.edges = edges
    }
}

public enum KnowledgeMapProjectionBuilder {
    public static let worldWidth = 1_800.0
    public static let worldHeight = 1_400.0

    public static func build(
        topicId: UUID,
        concepts: [IdentifiedPayload<ConceptPayload>],
        evidence: [IdentifiedPayload<EvidencePayload>],
        conceptEvidence: [IdentifiedPayload<ConceptEvidenceRelationPayload>],
        conceptLinks: [IdentifiedPayload<ConceptLinkPayload>],
        placements: [KnowledgeMapNodePlacement] = []
    ) -> KnowledgeMapProjection {
        let scopedConcepts = concepts
            .filter { $0.payload.state == .active && $0.payload.topicIds.contains(topicId) }
            .sorted {
                if $0.payload.name.localizedCaseInsensitiveCompare($1.payload.name) == .orderedSame {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.payload.name.localizedCaseInsensitiveCompare($1.payload.name) == .orderedAscending
            }
        let conceptIds = Set(scopedConcepts.map(\.id))
        let scopedRelations = conceptEvidence.filter { conceptIds.contains($0.payload.conceptId) }
        let evidenceIds = Set(scopedRelations.map(\.payload.evidenceId))
        let evidenceById = Dictionary(uniqueKeysWithValues: evidence
            .filter { evidenceIds.contains($0.id) }
            .map { ($0.id, $0) })
        let validRelations = scopedRelations.filter { evidenceById[$0.payload.evidenceId] != nil }
        let validLinks = conceptLinks.filter {
            conceptIds.contains($0.payload.sourceConceptId)
                && conceptIds.contains($0.payload.targetConceptId)
        }

        let placementById = Dictionary(
            placements.map { ($0.nodeId, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        let centerX = worldWidth / 2
        let centerY = worldHeight / 2
        let conceptRadius = min(500, max(220, Double(scopedConcepts.count) * 62))
        var positions: [UUID: (Double, Double)] = [:]

        for (index, concept) in scopedConcepts.enumerated() {
            let angle = scopedConcepts.count == 1
                ? -Double.pi / 2
                : -Double.pi / 2 + (Double(index) / Double(scopedConcepts.count)) * Double.pi * 2
            let fallback = (
                centerX + cos(angle) * conceptRadius,
                centerY + sin(angle) * conceptRadius
            )
            positions[concept.id] = resolvedPosition(
                nodeId: concept.id,
                kind: .concept,
                fallback: fallback,
                placementById: placementById
            )
        }

        let sortedEvidenceIds = evidenceIds.sorted { $0.uuidString < $1.uuidString }
        for (index, evidenceId) in sortedEvidenceIds.enumerated() {
            let relatedConceptIds = validRelations
                .filter { $0.payload.evidenceId == evidenceId }
                .map(\.payload.conceptId)
            let anchors = relatedConceptIds.compactMap { positions[$0] }
            let anchorX = anchors.isEmpty
                ? centerX
                : anchors.map(\.0).reduce(0, +) / Double(anchors.count)
            let anchorY = anchors.isEmpty
                ? centerY
                : anchors.map(\.1).reduce(0, +) / Double(anchors.count)
            let angle = (Double(index) * 2.399_963_229_728_653) - Double.pi / 2
            let distance = 150 + Double(index % 3) * 42
            let fallback = (
                anchorX + cos(angle) * distance,
                anchorY + sin(angle) * distance
            )
            positions[evidenceId] = resolvedPosition(
                nodeId: evidenceId,
                kind: .evidence,
                fallback: fallback,
                placementById: placementById
            )
        }

        var relationCounts: [UUID: Int] = [:]
        for relation in validRelations {
            relationCounts[relation.payload.conceptId, default: 0] += 1
            relationCounts[relation.payload.evidenceId, default: 0] += 1
        }
        for link in validLinks {
            relationCounts[link.payload.sourceConceptId, default: 0] += 1
            relationCounts[link.payload.targetConceptId, default: 0] += 1
        }

        let conceptNodes = scopedConcepts.map { concept -> KnowledgeMapNode in
            let position = positions[concept.id] ?? (centerX, centerY)
            return KnowledgeMapNode(
                id: concept.id,
                kind: .concept,
                title: concept.payload.name,
                detail: concept.payload.conceptDescription,
                x: position.0,
                y: position.1,
                relationCount: relationCounts[concept.id, default: 0]
            )
        }
        let evidenceNodes = sortedEvidenceIds.compactMap { evidenceId -> KnowledgeMapNode? in
            guard let item = evidenceById[evidenceId] else { return nil }
            let position = positions[evidenceId] ?? (centerX, centerY)
            let excerpt = item.payload.excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = excerpt.isEmpty ? (item.payload.note ?? "Evidence") : excerpt
            return KnowledgeMapNode(
                id: evidenceId,
                kind: .evidence,
                title: item.payload.kind.displayName,
                detail: detail,
                x: position.0,
                y: position.1,
                relationCount: relationCounts[evidenceId, default: 0]
            )
        }
        let evidenceEdges = validRelations.map {
            KnowledgeMapEdge(
                id: $0.id,
                sourceId: $0.payload.conceptId,
                targetId: $0.payload.evidenceId,
                kind: .evidence,
                label: $0.payload.relation.displayName,
                directed: false
            )
        }
        let conceptEdges = validLinks.map {
            KnowledgeMapEdge(
                id: $0.id,
                sourceId: $0.payload.sourceConceptId,
                targetId: $0.payload.targetConceptId,
                kind: .concept,
                label: $0.payload.relation.displayName,
                directed: $0.payload.relation != .related && $0.payload.relation != .contrasts
            )
        }
        return KnowledgeMapProjection(
            nodes: conceptNodes + evidenceNodes,
            edges: (conceptEdges + evidenceEdges).sorted { $0.id.uuidString < $1.id.uuidString }
        )
    }

    private static func resolvedPosition(
        nodeId: UUID,
        kind: KnowledgeMapNodeKind,
        fallback: (Double, Double),
        placementById: [UUID: KnowledgeMapNodePlacement]
    ) -> (Double, Double) {
        guard let placement = placementById[nodeId], placement.kind == kind else {
            return bounded(fallback)
        }
        return bounded((placement.x, placement.y))
    }

    private static func bounded(_ position: (Double, Double)) -> (Double, Double) {
        (
            min(max(position.0.isFinite ? position.0 : worldWidth / 2, 90), worldWidth - 90),
            min(max(position.1.isFinite ? position.1 : worldHeight / 2, 70), worldHeight - 70)
        )
    }
}

public extension EvidenceKind {
    var displayName: String {
        switch self {
        case .excerpt: "Excerpt"
        case .annotation: "Annotation"
        case .imageRegion: "Image region"
        case .mediaClip: "Media clip"
        }
    }
}

public extension ConceptEvidenceKind {
    var displayName: String {
        switch self {
        case .supporting: "Supports"
        case .contradicting: "Contradicts"
        case .example: "Example"
        case .prerequisite: "Prerequisite"
        case .application: "Application"
        }
    }
}
