import Foundation
import XCTest
@testable import EpistoriaCore

final class KnowledgeMapTests: XCTestCase {
    func testProjectionIsScopedTypedAndDeterministic() {
        let topicId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let otherTopicId = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let conceptA = identified(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            payload: ConceptPayload(name: "Derivative", topicIds: [topicId])
        )
        let conceptB = identified(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
            payload: ConceptPayload(name: "Rate of change", topicIds: [topicId])
        )
        let excluded = identified(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!,
            payload: ConceptPayload(name: "Unrelated", topicIds: [otherTopicId])
        )
        let evidenceId = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        let evidence = identified(
            id: evidenceId,
            payload: EvidencePayload(
                sourceId: UUID(),
                sourceVersionId: UUID(),
                kind: .excerpt,
                locator: SourceLocator(kind: .pdf, page: 3),
                excerpt: "The derivative measures instantaneous change."
            )
        )
        let relation = identified(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
            payload: ConceptEvidenceRelationPayload(
                conceptId: conceptA.id,
                evidenceId: evidenceId,
                relation: .supporting
            )
        )
        let link = identified(
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000001")!,
            payload: ConceptLinkPayload(
                sourceConceptId: conceptA.id,
                targetConceptId: conceptB.id,
                relation: .related
            )
        )
        let placements = [KnowledgeMapNodePlacement(
            nodeId: conceptA.id,
            kind: .concept,
            x: 444,
            y: 333
        )]

        let first = KnowledgeMapProjectionBuilder.build(
            topicId: topicId,
            concepts: [conceptB, excluded, conceptA],
            evidence: [evidence],
            conceptEvidence: [relation],
            conceptLinks: [link],
            placements: placements
        )
        let second = KnowledgeMapProjectionBuilder.build(
            topicId: topicId,
            concepts: [conceptA, conceptB, excluded],
            evidence: [evidence],
            conceptEvidence: [relation],
            conceptLinks: [link],
            placements: placements
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(Set(first.nodes.map(\.id)), [conceptA.id, conceptB.id, evidenceId])
        XCTAssertEqual(first.edges.map(\.kind), [.evidence, .concept])
        XCTAssertEqual(first.nodes.first { $0.id == conceptA.id }?.x, 444)
        XCTAssertEqual(first.nodes.first { $0.id == conceptA.id }?.y, 333)
        XCTAssertFalse(first.nodes.contains { $0.id == excluded.id })
    }

    func testPlacementAndEvidenceConnectionSurviveRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KnowledgeMapTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("epistoria.sqlite")
        let key = Data(repeating: 74, count: 32)
        let store = EpistoriaStore(database: try SQLCipherDatabase(url: databaseURL, key: key))
        let topicId = try await store.createTopic(name: "Calculus")
        let conceptId = try await store.createConcept(name: "Derivative", topicIds: [topicId])
        let evidenceId = try await store.save(payload: EvidencePayload(
            sourceId: UUID(),
            sourceVersionId: UUID(),
            kind: .excerpt,
            locator: SourceLocator(kind: .plainText, startOffset: 0, endOffset: 25),
            excerpt: "A derivative is a rate of change."
        ))
        let firstRelation = try await store.linkConcept(
            conceptId,
            toEvidence: evidenceId,
            relation: .supporting
        )
        let repeatedRelation = try await store.linkConcept(
            conceptId,
            toEvidence: evidenceId,
            relation: .supporting
        )
        XCTAssertEqual(firstRelation, repeatedRelation)
        try await store.saveKnowledgeMapPlacement(
            topicId: topicId,
            nodeId: evidenceId,
            kind: .evidence,
            x: 612,
            y: 487
        )
        try await store.saveKnowledgeMapPlacement(
            topicId: topicId,
            nodeId: conceptId,
            kind: .concept,
            x: 310,
            y: 280
        )

        let reopened = EpistoriaStore(database: try SQLCipherDatabase(url: databaseURL, key: key))
        let reopenedMap = try await reopened.knowledgeMap(topicId: topicId)
        let map = try XCTUnwrap(reopenedMap)
        let relations = try await reopened.list(ConceptEvidenceRelationPayload.self)

        XCTAssertEqual(map.payload.placements.count, 2)
        XCTAssertEqual(map.payload.placements.first { $0.nodeId == evidenceId }?.x, 612)
        XCTAssertEqual(relations.count, 1)
        XCTAssertNoThrow(try EntityPayloadValidator.validate(
            entityType: .knowledgeMap,
            content: CanonicalJSON.encode(map.payload)
        ))

        try await reopened.resetKnowledgeMapLayout(topicId: topicId)
        let resetValue = try await reopened.knowledgeMap(topicId: topicId)
        let resetMap = try XCTUnwrap(resetValue)
        XCTAssertTrue(resetMap.payload.placements.isEmpty)

        let otherTopicId = try await reopened.createTopic(name: "Topology")
        let otherConceptId = try await reopened.createConcept(
            name: "Homeomorphism",
            topicIds: [otherTopicId]
        )
        do {
            try await reopened.saveKnowledgeMapPlacement(
                topicId: topicId,
                nodeId: otherConceptId,
                kind: .concept,
                x: 100,
                y: 100
            )
            XCTFail("A map must reject a Concept outside its Topic.")
        } catch {
            XCTAssertEqual(error as? StoreError, .relationshipNotFound)
        }

        try await reopened.removeConceptEvidenceRelation(id: firstRelation)
        let remainingRelations = try await reopened.list(ConceptEvidenceRelationPayload.self)
        let retainedConcept = try await reopened.payload(ConceptPayload.self, id: conceptId)
        let retainedEvidence = try await reopened.payload(EvidencePayload.self, id: evidenceId)
        XCTAssertTrue(remainingRelations.isEmpty)
        XCTAssertEqual(retainedConcept.payload.name, "Derivative")
        XCTAssertEqual(retainedEvidence.payload.excerpt, "A derivative is a rate of change.")
    }

    private func identified<Payload: EntityPayload>(
        id: UUID,
        payload: Payload
    ) -> IdentifiedPayload<Payload> {
        IdentifiedPayload(id: id, payload: payload, revision: 1, syncState: .synced)
    }
}
