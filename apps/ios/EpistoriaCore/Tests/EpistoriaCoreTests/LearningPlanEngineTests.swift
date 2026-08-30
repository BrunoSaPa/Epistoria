import XCTest
@testable import EpistoriaCore

final class LearningPlanEngineTests: XCTestCase {
    func testProjectionCalculatesCoverageDailyWorkAndOnTrackReadiness() throws {
        let calendar = utcCalendar()
        let start = try date(2026, 8, 3, calendar: calendar)
        let now = try date(2026, 8, 5, hour: 12, calendar: calendar)
        let target = try date(2026, 8, 9, calendar: calendar)
        var completed = LearningPlanObjective(title: "Linear factors", estimatedMinutes: 60)
        completed.state = .completed
        completed.completedAt = now
        let remaining = LearningPlanObjective(title: "Quadratic factors", estimatedMinutes: 60)
        let goal = plannedGoal(
            target: target,
            start: start,
            minutesPerDay: 30,
            objectives: [completed, remaining]
        )

        let projection = try XCTUnwrap(LearningPlanEngine.project(
            goal: goal,
            now: now,
            calendar: calendar
        ))

        XCTAssertEqual(projection.readiness, .onTrack)
        XCTAssertEqual(projection.completedObjectiveCount, 1)
        XCTAssertEqual(projection.objectiveCount, 2)
        XCTAssertEqual(projection.remainingMinutes, 60)
        XCTAssertEqual(projection.studyDaysRemaining, 5)
        XCTAssertEqual(projection.minutesRequiredPerStudyDay, 12)
        XCTAssertEqual(projection.catchUpMinutes, 0)
        XCTAssertTrue(projection.isStudyDayToday)
    }

    func testProjectionExplainsCatchUpAndCapacityRiskWithoutAI() throws {
        let calendar = utcCalendar()
        let start = try date(2026, 8, 3, calendar: calendar)
        let now = try date(2026, 8, 5, hour: 12, calendar: calendar)
        let laterTarget = try date(2026, 8, 9, calendar: calendar)
        let nearTarget = try date(2026, 8, 6, calendar: calendar)
        let objectives = [
            LearningPlanObjective(title: "Concepts", estimatedMinutes: 60),
            LearningPlanObjective(title: "Applications", estimatedMinutes: 60),
        ]

        let catchUp = try XCTUnwrap(LearningPlanEngine.project(
            goal: plannedGoal(
                target: laterTarget,
                start: start,
                minutesPerDay: 30,
                objectives: objectives
            ),
            now: now,
            calendar: calendar
        ))
        let atRisk = try XCTUnwrap(LearningPlanEngine.project(
            goal: plannedGoal(
                target: nearTarget,
                start: start,
                minutesPerDay: 30,
                objectives: objectives
            ),
            now: now,
            calendar: calendar
        ))

        XCTAssertEqual(catchUp.readiness, .catchUpNeeded)
        XCTAssertEqual(catchUp.catchUpMinutes, 34)
        XCTAssertEqual(catchUp.minutesRequiredPerStudyDay, 24)
        XCTAssertEqual(atRisk.readiness, .atRisk)
        XCTAssertEqual(atRisk.studyDaysRemaining, 2)
        XCTAssertEqual(atRisk.minutesRequiredPerStudyDay, 60)
    }

    func testCompletedCoverageWithWeakAssessmentRequestsReview() throws {
        let calendar = utcCalendar()
        let now = try date(2026, 8, 5, hour: 12, calendar: calendar)
        let sourceObjectiveId = UUID()
        let questionId = UUID()
        let attemptId = UUID()
        var objective = LearningPlanObjective(
            title: "Factor by grouping",
            estimatedMinutes: 45,
            sourceObjectiveId: sourceObjectiveId
        )
        objective.state = .completed
        objective.completedAt = now
        var attempt = TestAttemptPayload(
            testId: UUID(),
            topicId: fixedTopicId,
            scopeSnapshotId: UUID(),
            frozenQuestions: [FrozenQuestionSnapshot(
                questionId: questionId,
                kind: .explanation,
                prompt: "Explain grouping",
                choices: [],
                rubric: "Explain the common binomial.",
                correctAnswer: "",
                objectiveIds: [sourceObjectiveId],
                evidenceIds: []
            )],
            now: now.addingTimeInterval(-600)
        )
        attempt.state = .scored
        attempt.submittedAt = now.addingTimeInterval(-300)
        var response = TestResponsePayload(attemptId: attemptId, questionId: questionId, now: now)
        response.isCorrect = false
        response.confidence = 1

        let projection = try XCTUnwrap(LearningPlanEngine.project(
            goal: plannedGoal(
                target: try date(2026, 8, 9, calendar: calendar),
                start: try date(2026, 8, 3, calendar: calendar),
                minutesPerDay: 30,
                objectives: [objective]
            ),
            attempts: [identified(attemptId, attempt)],
            responses: [identified(UUID(), response)],
            now: now,
            calendar: calendar
        ))

        XCTAssertEqual(projection.readiness, .reviewRecommended)
        XCTAssertEqual(projection.assessedResponseCount, 1)
        XCTAssertEqual(projection.incorrectResponseCount, 1)
        XCTAssertEqual(projection.lowConfidenceResponseCount, 1)
        XCTAssertEqual(projection.objectives.first?.incorrectResponses, 1)

        let laterAttemptId = UUID()
        var laterAttempt = TestAttemptPayload(
            testId: UUID(),
            topicId: fixedTopicId,
            scopeSnapshotId: UUID(),
            frozenQuestions: attempt.frozenQuestions,
            now: now.addingTimeInterval(60)
        )
        laterAttempt.state = .scored
        laterAttempt.submittedAt = now.addingTimeInterval(120)
        var laterResponse = TestResponsePayload(
            attemptId: laterAttemptId,
            questionId: questionId,
            now: now.addingTimeInterval(120)
        )
        laterResponse.isCorrect = true
        laterResponse.confidence = 4
        let updated = try XCTUnwrap(LearningPlanEngine.project(
            goal: plannedGoal(
                target: try date(2026, 8, 9, calendar: calendar),
                start: try date(2026, 8, 3, calendar: calendar),
                minutesPerDay: 30,
                objectives: [objective]
            ),
            attempts: [identified(attemptId, attempt), identified(laterAttemptId, laterAttempt)],
            responses: [identified(UUID(), response), identified(UUID(), laterResponse)],
            now: now,
            calendar: calendar
        ))
        XCTAssertEqual(updated.readiness, .ready)
        XCTAssertEqual(updated.objectives.first?.correctResponses, 1)
        XCTAssertEqual(updated.incorrectResponseCount, 0)
    }

    func testLegacyGoalDecodesWithoutPlanAndValidatorAcceptsBothVersions() throws {
        let topicId = UUID()
        let legacy = Data("""
        {
          "schemaVersion":"study-goal/v1",
          "topicId":"\(topicId.uuidString)",
          "title":"Legacy goal",
          "details":null,
          "targetDate":null,
          "priority":1,
          "state":"ACTIVE",
          "createdAt":"2026-08-03T00:00:00Z",
          "updatedAt":"2026-08-03T00:00:00Z"
        }
        """.utf8)
        let decoded = try CanonicalJSON.decode(StudyGoalPayload.self, from: legacy)

        XCTAssertEqual(decoded.schemaVersion, "study-goal/v1")
        XCTAssertNil(decoded.learningPlan)
        XCTAssertNoThrow(try EntityPayloadValidator.validate(entityType: .studyGoal, content: legacy))

        let current = try CanonicalJSON.encode(plannedGoal(
            target: Date(timeIntervalSince1970: 1_800_000_000),
            start: Date(timeIntervalSince1970: 1_799_000_000),
            minutesPerDay: 30,
            objectives: []
        ))
        XCTAssertNoThrow(try EntityPayloadValidator.validate(entityType: .studyGoal, content: current))
    }

    func testStudyNextUsesExplainedPlanWorkload() throws {
        let calendar = utcCalendar()
        let now = try date(2026, 8, 5, hour: 12, calendar: calendar)
        let goalId = UUID()
        let goal = plannedGoal(
            target: try date(2026, 8, 6, calendar: calendar),
            start: try date(2026, 8, 3, calendar: calendar),
            minutesPerDay: 20,
            objectives: [LearningPlanObjective(title: "Applications", estimatedMinutes: 120)]
        )
        let projection = try XCTUnwrap(LearningPlanEngine.project(
            goalId: goalId,
            goal: goal,
            now: now,
            calendar: calendar
        ))

        let recommendations = StudyNextEngine.rank(
            topics: [identified(fixedTopicId, TopicPayload(name: "Algebra", now: now))],
            goals: [identified(goalId, goal)],
            unresolvedQuestions: [],
            sessions: [],
            tests: [],
            attempts: [],
            dueCardCounts: [:],
            learningPlanProjections: [goalId: projection],
            now: now
        )

        XCTAssertEqual(recommendations.first?.targetId, goalId)
        XCTAssertEqual(recommendations.first?.kind, .goalDeadline)
        XCTAssertEqual(recommendations.first?.explanation, "120 minutes remain; the plan requires 60 minutes per study day.")
    }

    private let fixedTopicId = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!

    private func plannedGoal(
        target: Date,
        start: Date,
        minutesPerDay: Int,
        objectives: [LearningPlanObjective]
    ) -> StudyGoalPayload {
        StudyGoalPayload(
            topicId: fixedTopicId,
            title: "Prepare for the assessment",
            targetDate: target,
            priority: 2,
            learningPlan: LearningPlanConfiguration(
                startedAt: start,
                minutesPerStudyDay: minutesPerDay,
                studyWeekdays: Array(1...7),
                objectives: objectives
            ),
            now: start
        )
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

    private func identified<Payload: EntityPayload>(
        _ id: UUID,
        _ payload: Payload
    ) -> IdentifiedPayload<Payload> {
        IdentifiedPayload(id: id, payload: payload, revision: 1, syncState: .synced)
    }
}
