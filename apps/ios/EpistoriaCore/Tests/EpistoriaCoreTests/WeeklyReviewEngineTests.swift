import XCTest
@testable import EpistoriaCore

final class WeeklyReviewEngineTests: XCTestCase {
    func testSummaryCombinesRecentWorkDifficultyUpcomingWorkAndNextActions() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let topicId = UUID()
        let cardId = UUID()
        let revisionId = UUID()
        let attemptId = UUID()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let topic = identified(topicId, TopicPayload(name: "Algebra", now: now))
        var session = StudySessionPayload(title: "Factorization", topicId: topicId, now: now.addingTimeInterval(-7_200))
        session.state = .ended
        session.endedAt = now.addingTimeInterval(-3_600)

        let card = FlashcardPayload(
            topicId: topicId,
            currentRevisionId: revisionId,
            kind: .basic,
            now: now.addingTimeInterval(-86_400 * 10)
        )
        let review = FlashcardReviewPayload(
            cardId: cardId,
            cardRevisionId: revisionId,
            rating: .hard,
            previousState: FlashcardScheduleState(dueAt: now.addingTimeInterval(-86_400)),
            resultingState: FlashcardScheduleState(dueAt: now.addingTimeInterval(86_400)),
            now: now.addingTimeInterval(-600)
        )

        var attempt = TestAttemptPayload(
            testId: UUID(),
            topicId: topicId,
            scopeSnapshotId: UUID(),
            frozenQuestions: [],
            now: now.addingTimeInterval(-2_000)
        )
        attempt.state = .scored
        attempt.submittedAt = now.addingTimeInterval(-1_800)
        attempt.score = 0.6
        var response = TestResponsePayload(attemptId: attemptId, questionId: UUID(), now: now.addingTimeInterval(-1_900))
        response.isCorrect = false
        response.confidence = 1

        let goalId = UUID()
        let questionId = UUID()
        let goal = StudyGoalPayload(
            topicId: topicId,
            title: "Finish quadratics",
            targetDate: now.addingTimeInterval(86_400 * 2),
            now: now
        )
        let question = UnresolvedQuestionPayload(topicId: topicId, question: "When is a root repeated?", now: now)
        let action = LocalStudyRecommendation(
            topicId: topicId,
            kind: .dueCards,
            title: "Review one card",
            explanation: "It is due.",
            score: 90,
            targetId: cardId
        )

        let summary = WeeklyReviewEngine.summarize(
            topics: [topic],
            sessions: [identified(UUID(), session)],
            cards: [identified(cardId, card)],
            reviews: [identified(UUID(), review)],
            attempts: [identified(attemptId, attempt)],
            responses: [identified(UUID(), response)],
            goals: [identified(goalId, goal)],
            unresolvedQuestions: [identified(questionId, question)],
            nextActions: [action],
            now: now,
            calendar: calendar
        )

        XCTAssertTrue(summary.hasCompletedWork)
        XCTAssertEqual(summary.completedSessions, 1)
        XCTAssertEqual(summary.focusedMinutes, 60)
        XCTAssertEqual(summary.cardReviews, 1)
        XCTAssertEqual(summary.completedTests, 1)
        XCTAssertEqual(summary.averageTestScore, 0.6)
        XCTAssertEqual(summary.topicActivity.first?.topicId, topicId)
        XCTAssertEqual(summary.difficultTopics.first?.difficultCardReviews, 1)
        XCTAssertEqual(summary.difficultTopics.first?.incorrectTestResponses, 1)
        XCTAssertEqual(summary.difficultTopics.first?.lowConfidenceResponses, 1)
        XCTAssertEqual(summary.openQuestions.map(\.id), [questionId])
        XCTAssertEqual(summary.upcomingGoals.map(\.id), [goalId])
        XCTAssertEqual(summary.reviewLoad.first?.upcomingCards, 1)
        XCTAssertEqual(summary.reviewLoad.first?.overdueCards, 0)
        XCTAssertEqual(summary.nextActions, [action])
    }

    func testSummaryExcludesOldAndArchivedTopicActivity() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let activeTopicId = UUID()
        let archivedTopicId = UUID()
        var archivedTopic = TopicPayload(name: "Archived", now: now)
        archivedTopic.archived = true
        var oldSession = StudySessionPayload(
            title: "Old session",
            topicId: activeTopicId,
            now: now.addingTimeInterval(-86_400 * 10)
        )
        oldSession.state = .ended
        oldSession.endedAt = now.addingTimeInterval(-86_400 * 9)
        var archivedSession = StudySessionPayload(
            title: "Archived Topic session",
            topicId: archivedTopicId,
            now: now.addingTimeInterval(-3_600)
        )
        archivedSession.state = .ended
        archivedSession.endedAt = now

        let summary = WeeklyReviewEngine.summarize(
            topics: [
                identified(activeTopicId, TopicPayload(name: "Active", now: now)),
                identified(archivedTopicId, archivedTopic)
            ],
            sessions: [identified(UUID(), oldSession), identified(UUID(), archivedSession)],
            cards: [],
            reviews: [],
            attempts: [],
            responses: [],
            goals: [],
            unresolvedQuestions: [],
            nextActions: [],
            now: now
        )

        XCTAssertFalse(summary.hasCompletedWork)
        XCTAssertTrue(summary.topicActivity.isEmpty)
        XCTAssertTrue(summary.difficultTopics.isEmpty)
        XCTAssertTrue(summary.reviewLoad.isEmpty)
    }

    private func identified<Payload: EntityPayload>(
        _ id: UUID,
        _ payload: Payload
    ) -> IdentifiedPayload<Payload> {
        IdentifiedPayload(id: id, payload: payload, revision: 1, syncState: .synced)
    }
}
