@testable import Epistoria
import EpistoriaCore
import XCTest

@MainActor
final class WorkspacePresentationTests: XCTestCase {
    func testOnlyTheActiveEditorCanEndImmersivePresentation() {
        let presentation = EpistoriaWorkspacePresentation()
        let firstEditor = UUID()
        let secondEditor = UUID()

        presentation.beginImmersiveEditing(id: firstEditor)
        presentation.beginImmersiveEditing(id: secondEditor)
        presentation.endImmersiveEditing(id: firstEditor)

        XCTAssertTrue(presentation.isEditingImmersively)
        XCTAssertEqual(presentation.activeImmersiveEditorID, secondEditor)

        presentation.endImmersiveEditing(id: secondEditor)

        XCTAssertFalse(presentation.isEditingImmersively)
        XCTAssertNil(presentation.activeImmersiveEditorID)
    }

    func testResetAlwaysRestoresTheWorkspaceNavigation() {
        let presentation = EpistoriaWorkspacePresentation()
        presentation.beginImmersiveEditing(id: UUID())

        presentation.reset()

        XCTAssertFalse(presentation.isEditingImmersively)
        XCTAssertNil(presentation.activeImmersiveEditorID)
    }

    func testStudyRecommendationDestinationsOpenTheExactWorkItem() {
        let topicId = UUID()
        let cardId = UUID()
        let sessionId = UUID()
        let attemptId = UUID()
        let testId = UUID()
        let goalId = UUID()
        let questionId = UUID()

        func recommendation(_ kind: RecommendationKind, targetId: UUID? = nil) -> LocalStudyRecommendation {
            LocalStudyRecommendation(
                topicId: topicId,
                kind: kind,
                title: "Synthetic recommendation",
                explanation: "Synthetic reason",
                score: 1,
                targetId: targetId
            )
        }

        func resolve(_ value: LocalStudyRecommendation) -> StudyRecommendationDestination {
            StudyRecommendationDestination.resolve(
                value,
                dueCardIdsByTopic: [topicId: [cardId]],
                sessionIds: [sessionId],
                attemptIds: [attemptId],
                testIds: [testId]
            )
        }

        XCTAssertEqual(resolve(recommendation(.dueCards)), .card(cardId))
        XCTAssertEqual(resolve(recommendation(.pausedSession, targetId: sessionId)), .session(sessionId))
        XCTAssertEqual(resolve(recommendation(.unfinishedTest, targetId: attemptId)), .attempt(attemptId))
        XCTAssertEqual(resolve(recommendation(.testErrors, targetId: attemptId)), .attempt(attemptId))
        XCTAssertEqual(resolve(recommendation(.incompleteCoverage, targetId: testId)), .test(testId))
        XCTAssertEqual(resolve(recommendation(.goalDeadline, targetId: goalId)), .goal(goalId))
        XCTAssertEqual(resolve(recommendation(.unresolvedQuestion, targetId: questionId)), .question(questionId))
        XCTAssertEqual(resolve(recommendation(.neglectedTopic)), .topic(topicId))
        XCTAssertEqual(resolve(recommendation(.pausedSession, targetId: UUID())), .topic(topicId))
    }
}
