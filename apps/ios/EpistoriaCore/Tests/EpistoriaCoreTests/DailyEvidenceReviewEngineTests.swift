import Foundation
import XCTest
@testable import EpistoriaCore

final class DailyEvidenceReviewEngineTests: XCTestCase {
    func testQueueMixesSavedEvidenceDifficultConceptAndLatestMistake() throws {
        let fixture = makeFixture()

        let queue = DailyEvidenceReviewEngine.buildQueue(
            topics: [fixture.topic],
            sources: [fixture.source],
            evidence: [fixture.evidence],
            concepts: [fixture.concept],
            conceptEvidence: [fixture.relation],
            cards: [],
            cardRevisions: [],
            cardReviews: [],
            attempts: [fixture.attempt],
            testResponses: [fixture.response],
            reviewResponses: [],
            now: fixture.now,
            limit: 5
        )

        XCTAssertEqual(queue.totalDueCount, 3)
        XCTAssertEqual(queue.evidenceDueCount, 1)
        XCTAssertEqual(queue.conceptDueCount, 1)
        XCTAssertEqual(queue.mistakeDueCount, 1)
        XCTAssertEqual(queue.items.map(\.kind), [.testMistake, .concept, .evidence])
        XCTAssertEqual(queue.items.first?.evidenceIds, [fixture.evidence.id])
        XCTAssertTrue(queue.items.first?.answer?.contains("Reference answer: x = 2") == true)
        XCTAssertEqual(queue.items.last?.reason, "Saved Evidence · page 4")
    }

    func testLatestCorrectResponseRemovesEarlierMistakeAndConceptDifficulty() throws {
        let fixture = makeFixture()
        let laterAttemptId = UUID()
        var laterAttempt = TestAttemptPayload(
            testId: UUID(),
            topicId: fixture.topic.id,
            scopeSnapshotId: UUID(),
            frozenQuestions: fixture.attempt.payload.frozenQuestions,
            now: fixture.now.addingTimeInterval(60)
        )
        laterAttempt.state = .scored
        laterAttempt.submittedAt = fixture.now.addingTimeInterval(120)
        laterAttempt.updatedAt = fixture.now.addingTimeInterval(120)
        var laterResponse = TestResponsePayload(
            attemptId: laterAttemptId,
            questionId: fixture.response.payload.questionId,
            now: fixture.now.addingTimeInterval(120)
        )
        laterResponse.response = "x = 2"
        laterResponse.isCorrect = true
        laterResponse.confidence = 4

        let queue = DailyEvidenceReviewEngine.buildQueue(
            topics: [fixture.topic],
            sources: [fixture.source],
            evidence: [fixture.evidence],
            concepts: [fixture.concept],
            conceptEvidence: [fixture.relation],
            cards: [],
            cardRevisions: [],
            cardReviews: [],
            attempts: [fixture.attempt, identified(laterAttemptId, laterAttempt)],
            testResponses: [fixture.response, identified(UUID(), laterResponse)],
            reviewResponses: [],
            now: fixture.now.addingTimeInterval(180),
            limit: 5
        )

        XCTAssertEqual(queue.totalDueCount, 1)
        XCTAssertEqual(queue.items.map(\.kind), [.evidence])
    }

    func testArchivedSourceRemovesEvidenceAndItsConceptFromReview() throws {
        let fixture = makeFixture()
        var archivedSource = fixture.source.payload
        archivedSource.archivedAt = fixture.now

        let queue = DailyEvidenceReviewEngine.buildQueue(
            topics: [fixture.topic],
            sources: [identified(fixture.source.id, archivedSource)],
            evidence: [fixture.evidence],
            concepts: [fixture.concept],
            conceptEvidence: [fixture.relation],
            cards: [], cardRevisions: [], cardReviews: [],
            attempts: [fixture.attempt], testResponses: [fixture.response],
            reviewResponses: [],
            now: fixture.now,
            limit: 5
        )

        XCTAssertEqual(queue.items.map(\.kind), [.testMistake])
        XCTAssertEqual(queue.evidenceDueCount, 0)
        XCTAssertEqual(queue.conceptDueCount, 0)
    }

    func testOwnerResponseSchedulesLocallyAndEditedConceptBecomesDue() throws {
        let fixture = makeFixture()
        let calendar = utcCalendar()
        let responseId = UUID()
        let nextReviewAt = try XCTUnwrap(DailyEvidenceReviewEngine.nextReviewDate(
            action: .remembered,
            previousResponses: [],
            now: fixture.now,
            calendar: calendar
        ))
        let response = DailyReviewResponsePayload(
            itemKind: .concept,
            targetId: fixture.concept.id,
            topicId: fixture.topic.id,
            evidenceIds: [fixture.evidence.id],
            action: .remembered,
            targetUpdatedAt: fixture.concept.payload.updatedAt,
            reviewedAt: fixture.now,
            nextReviewAt: nextReviewAt
        )

        let beforeDue = DailyEvidenceReviewEngine.buildQueue(
            topics: [fixture.topic],
            sources: [fixture.source],
            evidence: [fixture.evidence],
            concepts: [fixture.concept],
            conceptEvidence: [fixture.relation],
            cards: [], cardRevisions: [], cardReviews: [],
            attempts: [fixture.attempt], testResponses: [fixture.response],
            reviewResponses: [identified(responseId, response)],
            now: fixture.now.addingTimeInterval(86_400),
            limit: 5
        )
        XCTAssertFalse(beforeDue.items.contains { $0.kind == .concept })

        var editedConcept = fixture.concept.payload
        editedConcept.conceptDescription = "An updated owner description."
        editedConcept.updatedAt = fixture.now.addingTimeInterval(120)
        let afterEdit = DailyEvidenceReviewEngine.buildQueue(
            topics: [fixture.topic],
            sources: [fixture.source],
            evidence: [fixture.evidence],
            concepts: [identified(fixture.concept.id, editedConcept)],
            conceptEvidence: [fixture.relation],
            cards: [], cardRevisions: [], cardReviews: [],
            attempts: [fixture.attempt], testResponses: [fixture.response],
            reviewResponses: [identified(responseId, response)],
            now: fixture.now.addingTimeInterval(86_400),
            limit: 5
        )
        XCTAssertTrue(afterEdit.items.contains { $0.kind == .concept })
        XCTAssertEqual(nextReviewAt, try date(2026, 9, 5, calendar: calendar))
    }

    func testResponsePersistsThroughRelaunchAndValidatesForPortableImport() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DailyEvidenceReviewTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("epistoria.sqlite")
        let key = Data(repeating: 91, count: 32)
        let store = EpistoriaStore(database: try SQLCipherDatabase(url: databaseURL, key: key))
        let topicId = try await store.createTopic(name: "Algebra")
        let sourceId = try await store.save(
            payload: SourcePayload(
                sourceType: .pdf,
                title: "Algebra notes",
                primaryTopicId: topicId
            ),
            parentId: topicId,
            relationIds: [topicId]
        )
        let evidenceId = try await store.save(
            payload: EvidencePayload(
                sourceId: sourceId,
                sourceVersionId: UUID(),
                kind: .excerpt,
                locator: SourceLocator(kind: .pdf, page: 2),
                excerpt: "A difference of squares has two conjugate factors."
            ),
            parentId: sourceId,
            relationIds: [sourceId]
        )

        let responseId = try await store.recordDailyReviewResponse(
            itemKind: .evidence,
            targetId: evidenceId,
            action: .remembered,
            at: Date(timeIntervalSince1970: 1_788_000_000)
        )
        let stored = try await store.payload(DailyReviewResponsePayload.self, id: responseId)
        XCTAssertEqual(stored.payload.evidenceIds, [evidenceId])
        XCTAssertEqual(stored.payload.action, .remembered)
        XCTAssertNoThrow(try EntityPayloadValidator.validate(
            entityType: .dailyReviewResponse,
            content: CanonicalJSON.encode(stored.payload)
        ))
        do {
            _ = try await store.recordDailyReviewResponse(
                itemKind: .evidence,
                targetId: evidenceId,
                action: .remembered,
                at: Date(timeIntervalSince1970: 1_788_086_400)
            )
            XCTFail("A response to an item that is no longer due must fail")
        } catch {
            XCTAssertEqual(error as? StoreError, .invalidDailyReviewItem)
        }

        let reopened = EpistoriaStore(database: try SQLCipherDatabase(url: databaseURL, key: key))
        let restored = try await reopened.payload(DailyReviewResponsePayload.self, id: responseId)
        XCTAssertEqual(restored.payload.targetId, evidenceId)
        let queue = try await reopened.dailyEvidenceReviewQueue(
            now: Date(timeIntervalSince1970: 1_788_086_400)
        )
        XCTAssertEqual(queue.totalDueCount, 0)
    }

    private func makeFixture() -> Fixture {
        let calendar = utcCalendar()
        let now = try! date(2026, 8, 29, hour: 12, calendar: calendar)
        let topicId = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
        let sourceId = UUID(uuidString: "00000000-0000-0000-0000-000000000202")!
        let evidenceId = UUID(uuidString: "00000000-0000-0000-0000-000000000203")!
        let conceptId = UUID(uuidString: "00000000-0000-0000-0000-000000000204")!
        let attemptId = UUID(uuidString: "00000000-0000-0000-0000-000000000205")!
        let questionId = UUID(uuidString: "00000000-0000-0000-0000-000000000206")!
        let topic = identified(topicId, TopicPayload(name: "Algebra", now: now.addingTimeInterval(-10_000)))
        let source = identified(sourceId, SourcePayload(
            sourceType: .pdf,
            title: "Algebra source",
            primaryTopicId: topicId,
            now: now.addingTimeInterval(-9_000)
        ))
        let evidence = identified(evidenceId, EvidencePayload(
            sourceId: sourceId,
            sourceVersionId: UUID(),
            kind: .excerpt,
            locator: SourceLocator(kind: .pdf, page: 4),
            excerpt: "Subtract two from both sides.",
            now: now.addingTimeInterval(-8_000)
        ))
        let concept = identified(conceptId, ConceptPayload(
            name: "Inverse operations",
            conceptDescription: "Use the inverse operation on both sides.",
            topicIds: [topicId],
            now: now.addingTimeInterval(-7_000)
        ))
        let relation = identified(UUID(), ConceptEvidenceRelationPayload(
            conceptId: conceptId,
            evidenceId: evidenceId,
            relation: .supporting,
            now: now.addingTimeInterval(-6_000)
        ))
        var attempt = TestAttemptPayload(
            testId: UUID(),
            topicId: topicId,
            scopeSnapshotId: UUID(),
            frozenQuestions: [FrozenQuestionSnapshot(
                questionId: questionId,
                kind: .shortAnswer,
                prompt: "Solve x + 2 = 4.",
                choices: [],
                rubric: "Isolate x.",
                correctAnswer: "x = 2",
                objectiveIds: [],
                evidenceIds: [evidenceId]
            )],
            now: now.addingTimeInterval(-5_000)
        )
        attempt.state = .scored
        attempt.submittedAt = now.addingTimeInterval(-4_000)
        attempt.updatedAt = now.addingTimeInterval(-4_000)
        var response = TestResponsePayload(
            attemptId: attemptId,
            questionId: questionId,
            now: now.addingTimeInterval(-4_000)
        )
        response.response = "x = 6"
        response.isCorrect = false
        response.confidence = 1
        return Fixture(
            now: now,
            topic: topic,
            source: source,
            evidence: evidence,
            concept: concept,
            relation: relation,
            attempt: identified(attemptId, attempt),
            response: identified(UUID(), response)
        )
    }

    private struct Fixture {
        var now: Date
        var topic: IdentifiedPayload<TopicPayload>
        var source: IdentifiedPayload<SourcePayload>
        var evidence: IdentifiedPayload<EvidencePayload>
        var concept: IdentifiedPayload<ConceptPayload>
        var relation: IdentifiedPayload<ConceptEvidenceRelationPayload>
        var attempt: IdentifiedPayload<TestAttemptPayload>
        var response: IdentifiedPayload<TestResponsePayload>
    }

    private func identified<Payload: EntityPayload>(
        _ id: UUID,
        _ payload: Payload
    ) -> IdentifiedPayload<Payload> {
        IdentifiedPayload(id: id, payload: payload, revision: 1, syncState: .synced)
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        hour: Int = 0,
        calendar: Calendar
    ) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour
        )))
    }
}
