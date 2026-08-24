import Foundation

public struct LocalStudyRecommendation: Equatable, Sendable, Identifiable {
    public var id: String { "\(topicId.uuidString):\(kind.rawValue):\(targetId?.uuidString ?? "none")" }
    public var topicId: UUID
    public var kind: RecommendationKind
    public var title: String
    public var explanation: String
    public var score: Double
    public var targetId: UUID?

    public init(
        topicId: UUID,
        kind: RecommendationKind,
        title: String,
        explanation: String,
        score: Double,
        targetId: UUID? = nil
    ) {
        self.topicId = topicId
        self.kind = kind
        self.title = title
        self.explanation = explanation
        self.score = score
        self.targetId = targetId
    }

    public var symbol: String {
        switch kind {
        case .dueCards: "rectangle.stack"
        case .testErrors: "xmark.square"
        case .unresolvedQuestion: "questionmark.circle"
        case .incompleteCoverage: "square.dashed"
        case .pausedSession: "pause.circle"
        case .unfinishedTest: "square.and.pencil"
        case .neglectedTopic: "clock.arrow.circlepath"
        case .goalDeadline: "target"
        }
    }
}

public enum StudyNextEngine {
    public static func rank(
        topics: [IdentifiedPayload<TopicPayload>],
        goals: [IdentifiedPayload<StudyGoalPayload>],
        unresolvedQuestions: [IdentifiedPayload<UnresolvedQuestionPayload>],
        sessions: [IdentifiedPayload<StudySessionPayload>],
        tests: [IdentifiedPayload<PracticeTestPayload>],
        attempts: [IdentifiedPayload<TestAttemptPayload>],
        dueCardCounts: [UUID: Int],
        storedRecommendations: [IdentifiedPayload<StudyRecommendationPayload>] = [],
        now: Date
    ) -> [LocalStudyRecommendation] {
        var values: [LocalStudyRecommendation] = []
        let activeTopics = Dictionary(uniqueKeysWithValues: topics.filter { !$0.payload.archived }.map { ($0.id, $0.payload) })

        for (topicId, count) in dueCardCounts where count > 0 && activeTopics[topicId] != nil {
            values.append(LocalStudyRecommendation(
                topicId: topicId,
                kind: .dueCards,
                title: "Review \(count) due card\(count == 1 ? "" : "s")",
                explanation: "These reviews are due now and can be completed offline.",
                score: 80 + min(Double(count), 20)
            ))
        }

        for goal in goals where goal.payload.state == .active && activeTopics[goal.payload.topicId] != nil {
            let days = goal.payload.targetDate.map {
                Calendar(identifier: .gregorian).dateComponents([.day], from: now, to: $0).day ?? 365
            } ?? 365
            let urgency = days <= 0 ? 120 : days <= 3 ? 105 : days <= 7 ? 90 : 60
            values.append(LocalStudyRecommendation(
                topicId: goal.payload.topicId,
                kind: .goalDeadline,
                title: goal.payload.title,
                explanation: goal.payload.targetDate == nil
                    ? "This active goal has no deadline."
                    : "Target date: \(goal.payload.targetDate!.formatted(date: .abbreviated, time: .omitted)).",
                score: Double(urgency + goal.payload.priority * 5),
                targetId: goal.id
            ))
        }

        for question in unresolvedQuestions where question.payload.resolvedAt == nil && activeTopics[question.payload.topicId] != nil {
            values.append(LocalStudyRecommendation(
                topicId: question.payload.topicId,
                kind: .unresolvedQuestion,
                title: "Resolve: \(question.payload.question)",
                explanation: "This question is still open in the Topic.",
                score: 75,
                targetId: question.id
            ))
        }

        for session in sessions where session.payload.state == .paused {
            guard let topicId = session.payload.courseId, activeTopics[topicId] != nil else {
                continue
            }
            values.append(LocalStudyRecommendation(
                topicId: topicId,
                kind: .pausedSession,
                title: "Resume \(session.payload.title)",
                explanation: "This focused session is paused.",
                score: 88,
                targetId: session.id
            ))
        }

        for attempt in attempts where attempt.payload.state == .inProgress && activeTopics[attempt.payload.topicId] != nil {
            let title = tests.first { $0.id == attempt.payload.testId }?.payload.title ?? "practice test"
            values.append(LocalStudyRecommendation(
                topicId: attempt.payload.topicId,
                kind: .unfinishedTest,
                title: "Continue \(title)",
                explanation: "Your responses and frozen question set are saved.",
                score: 100,
                targetId: attempt.id
            ))
        }

        values.append(contentsOf: storedRecommendations.compactMap { value in
            guard !value.payload.generatedLocally,
                  activeTopics[value.payload.topicId] != nil,
                  value.payload.expiresAt.map({ $0 > now }) ?? true
            else { return nil }
            return LocalStudyRecommendation(
                topicId: value.payload.topicId,
                kind: value.payload.kind,
                title: value.payload.title,
                explanation: value.payload.explanation,
                score: value.payload.score,
                targetId: value.payload.targetEntityIds.first
            )
        })

        return values.sorted {
            if $0.score == $1.score { return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            return $0.score > $1.score
        }
    }
}
