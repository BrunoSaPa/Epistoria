import Foundation

public enum LearningPlanReadiness: String, Codable, Equatable, Sendable {
    case needsDeadline = "NEEDS_DEADLINE"
    case needsObjectives = "NEEDS_OBJECTIVES"
    case onTrack = "ON_TRACK"
    case catchUpNeeded = "CATCH_UP_NEEDED"
    case atRisk = "AT_RISK"
    case reviewRecommended = "REVIEW_RECOMMENDED"
    case ready = "READY"
    case overdue = "OVERDUE"
}

public struct LearningPlanObjectiveProjection: Equatable, Sendable, Identifiable {
    public var id: UUID { objective.id }
    public var objective: LearningPlanObjective
    public var assessedResponses: Int
    public var correctResponses: Int
    public var incorrectResponses: Int
    public var lowConfidenceResponses: Int

    public init(
        objective: LearningPlanObjective,
        assessedResponses: Int = 0,
        correctResponses: Int = 0,
        incorrectResponses: Int = 0,
        lowConfidenceResponses: Int = 0
    ) {
        self.objective = objective
        self.assessedResponses = assessedResponses
        self.correctResponses = correctResponses
        self.incorrectResponses = incorrectResponses
        self.lowConfidenceResponses = lowConfidenceResponses
    }
}

public struct LearningPlanProjection: Equatable, Sendable {
    public var goalId: UUID?
    public var topicId: UUID
    public var readiness: LearningPlanReadiness
    public var objectiveCount: Int
    public var completedObjectiveCount: Int
    public var totalEstimatedMinutes: Int
    public var remainingMinutes: Int
    public var studyDaysRemaining: Int
    public var minutesRequiredPerStudyDay: Int
    public var preferredMinutesPerStudyDay: Int
    public var catchUpMinutes: Int
    public var isStudyDayToday: Bool
    public var nextStudyDate: Date?
    public var assessedResponseCount: Int
    public var incorrectResponseCount: Int
    public var lowConfidenceResponseCount: Int
    public var objectives: [LearningPlanObjectiveProjection]
}

public enum LearningPlanEngine {
    public static func project(
        goalId: UUID? = nil,
        goal: StudyGoalPayload,
        attempts: [IdentifiedPayload<TestAttemptPayload>] = [],
        responses: [IdentifiedPayload<TestResponsePayload>] = [],
        now: Date,
        calendar suppliedCalendar: Calendar? = nil
    ) -> LearningPlanProjection? {
        guard let plan = goal.learningPlan else { return nil }
        var calendar = suppliedCalendar ?? Calendar(identifier: .gregorian)
        if suppliedCalendar == nil { calendar.timeZone = .current }

        let objectiveEvidence = assessmentEvidence(
            topicId: goal.topicId,
            attempts: attempts,
            responses: responses
        )
        let objectives = plan.objectives.map { objective in
            let evidenceId = objective.sourceObjectiveId ?? objective.id
            let evidence = objectiveEvidence[evidenceId] ?? AssessmentEvidence()
            return LearningPlanObjectiveProjection(
                objective: objective,
                assessedResponses: evidence.assessed,
                correctResponses: evidence.correct,
                incorrectResponses: evidence.incorrect,
                lowConfidenceResponses: evidence.lowConfidence
            )
        }

        let totalMinutes = objectives.reduce(0) { $0 + $1.objective.estimatedMinutes }
        let completedObjectives = objectives.filter { $0.objective.state == .completed }
        let completedMinutes = completedObjectives.reduce(0) { $0 + $1.objective.estimatedMinutes }
        let remainingMinutes = max(totalMinutes - completedMinutes, 0)
        let weekdays = Set(plan.studyWeekdays.filter { (1...7).contains($0) })
        let today = calendar.startOfDay(for: now)
        let start = calendar.startOfDay(for: plan.startedAt)
        let target = goal.targetDate.map { calendar.startOfDay(for: $0) }

        let remainingDates = target.map {
            studyDates(from: max(today, start), through: $0, weekdays: weekdays, calendar: calendar)
        } ?? []
        let allDates = target.map {
            studyDates(from: start, through: $0, weekdays: weekdays, calendar: calendar)
        } ?? []
        let elapsedDates = allDates.filter { $0 < today }
        let expectedMinutes = allDates.isEmpty
            ? 0
            : Int((Double(totalMinutes) * Double(elapsedDates.count) / Double(allDates.count)).rounded(.down))
        let catchUpMinutes = max(expectedMinutes - completedMinutes, 0)
        let daysRemaining = remainingDates.count
        let requiredPerDay = remainingMinutes == 0
            ? 0
            : Int(ceil(Double(remainingMinutes) / Double(max(daysRemaining, 1))))
        let assessed = objectives.reduce(0) { $0 + $1.assessedResponses }
        let incorrect = objectives.reduce(0) { $0 + $1.incorrectResponses }
        let lowConfidence = objectives.reduce(0) { $0 + $1.lowConfidenceResponses }

        let readiness: LearningPlanReadiness
        if goal.targetDate == nil {
            readiness = .needsDeadline
        } else if objectives.isEmpty {
            readiness = .needsObjectives
        } else if remainingMinutes == 0 {
            readiness = incorrect > 0 || lowConfidence > 0 ? .reviewRecommended : .ready
        } else if target.map({ $0 < today }) == true {
            readiness = .overdue
        } else if daysRemaining == 0 || requiredPerDay > plan.minutesPerStudyDay {
            readiness = .atRisk
        } else if catchUpMinutes > 0 {
            readiness = .catchUpNeeded
        } else {
            readiness = .onTrack
        }

        return LearningPlanProjection(
            goalId: goalId,
            topicId: goal.topicId,
            readiness: readiness,
            objectiveCount: objectives.count,
            completedObjectiveCount: completedObjectives.count,
            totalEstimatedMinutes: totalMinutes,
            remainingMinutes: remainingMinutes,
            studyDaysRemaining: daysRemaining,
            minutesRequiredPerStudyDay: requiredPerDay,
            preferredMinutesPerStudyDay: plan.minutesPerStudyDay,
            catchUpMinutes: catchUpMinutes,
            isStudyDayToday: remainingDates.first == today,
            nextStudyDate: remainingDates.first,
            assessedResponseCount: assessed,
            incorrectResponseCount: incorrect,
            lowConfidenceResponseCount: lowConfidence,
            objectives: objectives
        )
    }

    private struct AssessmentEvidence {
        var assessed = 0
        var correct = 0
        var incorrect = 0
        var lowConfidence = 0
    }

    private static func assessmentEvidence(
        topicId: UUID,
        attempts: [IdentifiedPayload<TestAttemptPayload>],
        responses: [IdentifiedPayload<TestResponsePayload>]
    ) -> [UUID: AssessmentEvidence] {
        let eligibleAttempts = attempts.filter {
            $0.payload.topicId == topicId
                && ($0.payload.state == .submitted || $0.payload.state == .scored)
        }
        let attemptById = Dictionary(uniqueKeysWithValues: eligibleAttempts.map { ($0.id, $0.payload) })
        var latestAttemptByObjective: [UUID: (id: UUID, date: Date)] = [:]
        for identified in eligibleAttempts {
            let date = identified.payload.submittedAt ?? identified.payload.updatedAt
            let objectiveIds = Set(identified.payload.frozenQuestions.flatMap(\.objectiveIds))
            for objectiveId in objectiveIds {
                if let current = latestAttemptByObjective[objectiveId],
                   current.date > date || (current.date == date && current.id.uuidString > identified.id.uuidString) {
                    continue
                }
                latestAttemptByObjective[objectiveId] = (identified.id, date)
            }
        }
        var values: [UUID: AssessmentEvidence] = [:]
        for response in responses {
            guard let attempt = attemptById[response.payload.attemptId],
                  let correct = response.payload.isCorrect,
                  let question = attempt.frozenQuestions.first(where: { $0.questionId == response.payload.questionId })
            else { continue }
            for objectiveId in question.objectiveIds {
                guard latestAttemptByObjective[objectiveId]?.id == response.payload.attemptId else { continue }
                var evidence = values[objectiveId] ?? AssessmentEvidence()
                evidence.assessed += 1
                if correct { evidence.correct += 1 } else { evidence.incorrect += 1 }
                if response.payload.confidence.map({ $0 <= 1 }) == true {
                    evidence.lowConfidence += 1
                }
                values[objectiveId] = evidence
            }
        }
        return values
    }

    private static func studyDates(
        from start: Date,
        through end: Date,
        weekdays: Set<Int>,
        calendar: Calendar
    ) -> [Date] {
        guard !weekdays.isEmpty, start <= end else { return [] }
        var values: [Date] = []
        var date = start
        var inspected = 0
        while date <= end && inspected < 7_500 {
            if weekdays.contains(calendar.component(.weekday, from: date)) {
                values.append(date)
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { break }
            date = next
            inspected += 1
        }
        return values
    }
}
