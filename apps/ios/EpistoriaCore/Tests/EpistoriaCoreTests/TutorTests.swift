import Foundation
import XCTest
@testable import EpistoriaCore

final class TutorTests: XCTestCase {
    func testTutorContractsRoundTripWithTypedCitation() throws {
        let sourceId = UUID()
        let versionId = UUID()
        let sessionId = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let turn = TutorTurnPayload(
            tutorSessionId: sessionId,
            sequence: 2,
            role: .tutor,
            kind: .workedExample,
            text: "Factor the common term first.",
            citations: [TutorCitation(
                excerptId: UUID(),
                sourceId: sourceId,
                sourceVersionId: versionId,
                locator: SourceLocator(kind: .pdf, page: 4),
                excerpt: "Take out the greatest common factor."
            )],
            now: now
        )

        let encoded = try CanonicalJSON.encode(turn)

        XCTAssertEqual(try CanonicalJSON.decode(TutorTurnPayload.self, from: encoded), turn)
        XCTAssertNoThrow(try EntityPayloadValidator.validate(entityType: .tutorTurn, content: encoded))
        XCTAssertEqual(turn.citations.first?.locator.page, 4)
    }

    func testMasteryUsesOnlyAcceptedSignalsAndAdaptsActivity() {
        let sessionId = UUID()
        let topicId = UUID()
        let proposed = LearningSignalPayload(
            tutorSessionId: sessionId,
            topicId: topicId,
            objective: "Factor quadratics",
            assessmentKind: .application,
            outcome: .correct
        )
        var accepted = LearningSignalPayload(
            tutorSessionId: sessionId,
            topicId: topicId,
            objective: "Factor quadratics",
            assessmentKind: .retrieval,
            outcome: .incorrect,
            confidence: 5
        )
        accepted.reviewState = .accepted
        let projection = TutorAdaptationEngine.project(
            objective: "Factor quadratics",
            signals: [
                IdentifiedPayload(id: UUID(), payload: proposed, revision: 1, syncState: .synced),
                IdentifiedPayload(id: UUID(), payload: accepted, revision: 1, syncState: .synced),
            ]
        )

        XCTAssertEqual(projection.acceptedSignalCount, 1)
        XCTAssertEqual(projection.level, .needsWork)
        XCTAssertEqual(projection.nextTurnKind, .workedExample)
    }

    func testTutorTranscriptAndReviewSurviveRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TutorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("epistoria.sqlite")
        let key = Data(repeating: 42, count: 32)
        let database = try SQLCipherDatabase(url: databaseURL, key: key)
        let store = EpistoriaStore(database: database)
        let topicId = try await store.createTopic(name: "Algebra")
        let sessionId = try await store.createTutorSession(topicId: topicId, objective: "Factor quadratics")
        _ = try await store.appendOfflineTutorTurn(
            sessionId: sessionId,
            text: "I would look for two factors.",
            confidence: 3
        )
        let signalId = try await store.save(
            payload: LearningSignalPayload(
                tutorSessionId: sessionId,
                topicId: topicId,
                objective: "Factor quadratics",
                assessmentKind: .selfExplanation,
                outcome: .partial,
                rationale: "The method is incomplete."
            ),
            parentId: sessionId,
            relationIds: [sessionId, topicId]
        )
        try await store.reviewLearningSignal(id: signalId, state: .accepted)
        try await database.checkpoint()

        let reopenedStore = EpistoriaStore(database: try SQLCipherDatabase(url: databaseURL, key: key))
        let turns = try await reopenedStore.tutorTurns(sessionId: sessionId)
        let signals = try await reopenedStore.learningSignals(sessionId: sessionId)

        XCTAssertEqual(turns.map(\.payload.text), ["I would look for two factors."])
        XCTAssertTrue(turns[0].payload.pending)
        XCTAssertEqual(signals[0].payload.reviewState, .accepted)
        XCTAssertEqual(signals[0].payload.provenance, .reviewedAI)
    }
}
