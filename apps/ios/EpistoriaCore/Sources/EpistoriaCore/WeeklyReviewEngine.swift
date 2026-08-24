import Foundation

public struct WeeklyTopicActivity: Equatable, Sendable, Identifiable {
    public var id: UUID { topicId }
    public var topicId: UUID
    public var completedSessions: Int
    public var focusedMinutes: Int
    public var cardReviews: Int
    public var completedTests: Int
}

public struct WeeklyTopicDifficulty: Equatable, Sendable, Identifiable {
    public var id: UUID { topicId }
    public var topicId: UUID
    public var difficultCardReviews: Int
    public var incorrectTestResponses: Int
    public var lowConfidenceResponses: Int

    public var signalCount: Int {
        difficultCardReviews + incorrectTestResponses + lowConfidenceResponses
    }
}

public struct WeeklyTopicReviewLoad: Equatable, Sendable, Identifiable {
    public var id: UUID { topicId }
    public var topicId: UUID
    public var overdueCards: Int
    public var upcomingCards: Int

    public var total: Int { overdueCards + upcomingCards }
}

public struct WeeklyReviewSummary: Sendable {
    public var periodStart: Date
    public var periodEnd: Date
    public var completedSessions: Int
    public var focusedMinutes: Int
    public var cardReviews: Int
    public var completedTests: Int
    public var averageTestScore: Double?
    public var topicActivity: [WeeklyTopicActivity]
    public var difficultTopics: [WeeklyTopicDifficulty]
    public var openQuestions: [IdentifiedPayload<UnresolvedQuestionPayload>]
    public var upcomingGoals: [IdentifiedPayload<StudyGoalPayload>]
    public var reviewLoad: [WeeklyTopicReviewLoad]
    public var nextActions: [LocalStudyRecommendation]

    public var hasCompletedWork: Bool {
        completedSessions + cardReviews + completedTests > 0
    }
}

public enum WeeklyReviewEngine {
    public static func summarize(
        topics: [IdentifiedPayload<TopicPayload>],
        sessions: [IdentifiedPayload<StudySessionPayload>],
        cards: [IdentifiedPayload<FlashcardPayload>],
        reviews: [IdentifiedPayload<FlashcardReviewPayload>],
        attempts: [IdentifiedPayload<TestAttemptPayload>],
        responses: [IdentifiedPayload<TestResponsePayload>],
        goals: [IdentifiedPayload<StudyGoalPayload>],
        unresolvedQuestions: [IdentifiedPayload<UnresolvedQuestionPayload>],
        nextActions: [LocalStudyRecommendation],
        now: Date,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> WeeklyReviewSummary {
        let periodStart = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        let upcomingEnd = calendar.date(byAdding: .day, value: 7, to: now) ?? now
        let activeTopicIds = Set(topics.filter { !$0.payload.archived }.map(\.id))
        let cardById = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0.payload) })
        let attemptById = Dictionary(uniqueKeysWithValues: attempts.map { ($0.id, $0.payload) })

        let completedSessions = sessions.filter {
            guard let topicId = $0.payload.courseId else { return false }
            return $0.payload.state == .ended
                && activeTopicIds.contains(topicId)
                && isWithin($0.payload.endedAt, start: periodStart, end: now)
        }
        let recentReviews = reviews.filter {
            guard let topicId = cardById[$0.payload.cardId]?.topicId else { return false }
            return isWithin($0.payload.reviewedAt, start: periodStart, end: now)
                && activeTopicIds.contains(topicId)
        }
        let completedAttempts = attempts.filter {
            ($0.payload.state == .submitted || $0.payload.state == .scored)
                && activeTopicIds.contains($0.payload.topicId)
                && isWithin($0.payload.submittedAt, start: periodStart, end: now)
        }
        let completedAttemptIds = Set(completedAttempts.map(\.id))
        let recentResponses = responses.filter { completedAttemptIds.contains($0.payload.attemptId) }

        var activityByTopic: [UUID: WeeklyTopicActivity] = [:]
        for session in completedSessions {
            guard let topicId = session.payload.courseId else { continue }
            var value = activityByTopic[topicId] ?? WeeklyTopicActivity(
                topicId: topicId,
                completedSessions: 0,
                focusedMinutes: 0,
                cardReviews: 0,
                completedTests: 0
            )
            value.completedSessions += 1
            if let endedAt = session.payload.endedAt {
                value.focusedMinutes += max(Int(endedAt.timeIntervalSince(session.payload.startedAt) / 60), 0)
            }
            activityByTopic[topicId] = value
        }
        for review in recentReviews {
            guard let topicId = cardById[review.payload.cardId]?.topicId else { continue }
            var value = activityByTopic[topicId] ?? WeeklyTopicActivity(
                topicId: topicId,
                completedSessions: 0,
                focusedMinutes: 0,
                cardReviews: 0,
                completedTests: 0
            )
            value.cardReviews += 1
            activityByTopic[topicId] = value
        }
        for attempt in completedAttempts {
            var value = activityByTopic[attempt.payload.topicId] ?? WeeklyTopicActivity(
                topicId: attempt.payload.topicId,
                completedSessions: 0,
                focusedMinutes: 0,
                cardReviews: 0,
                completedTests: 0
            )
            value.completedTests += 1
            activityByTopic[attempt.payload.topicId] = value
        }

        var difficultyByTopic: [UUID: WeeklyTopicDifficulty] = [:]
        for review in recentReviews where review.payload.rating == .again || review.payload.rating == .hard {
            guard let topicId = cardById[review.payload.cardId]?.topicId else { continue }
            var value = difficultyByTopic[topicId] ?? WeeklyTopicDifficulty(
                topicId: topicId,
                difficultCardReviews: 0,
                incorrectTestResponses: 0,
                lowConfidenceResponses: 0
            )
            value.difficultCardReviews += 1
            difficultyByTopic[topicId] = value
        }
        for response in recentResponses {
            guard let topicId = attemptById[response.payload.attemptId]?.topicId else { continue }
            var value = difficultyByTopic[topicId] ?? WeeklyTopicDifficulty(
                topicId: topicId,
                difficultCardReviews: 0,
                incorrectTestResponses: 0,
                lowConfidenceResponses: 0
            )
            if response.payload.isCorrect == false { value.incorrectTestResponses += 1 }
            if let confidence = response.payload.confidence, confidence <= 1 {
                value.lowConfidenceResponses += 1
            }
            difficultyByTopic[topicId] = value
        }

        let latestReviewByCard = Dictionary(grouping: reviews, by: \.payload.cardId).compactMapValues {
            $0.max { $0.payload.reviewedAt < $1.payload.reviewedAt }
        }
        var reviewLoadByTopic: [UUID: WeeklyTopicReviewLoad] = [:]
        for card in cards where card.payload.archivedAt == nil && card.payload.suspendedAt == nil {
            guard activeTopicIds.contains(card.payload.topicId) else { continue }
            let dueAt = latestReviewByCard[card.id]?.payload.resultingState.dueAt ?? card.payload.createdAt
            guard dueAt <= upcomingEnd else { continue }
            var value = reviewLoadByTopic[card.payload.topicId] ?? WeeklyTopicReviewLoad(
                topicId: card.payload.topicId,
                overdueCards: 0,
                upcomingCards: 0
            )
            if dueAt <= now {
                value.overdueCards += 1
            } else {
                value.upcomingCards += 1
            }
            reviewLoadByTopic[card.payload.topicId] = value
        }

        let scores = completedAttempts.compactMap { $0.payload.scoreOverride ?? $0.payload.score }
        return WeeklyReviewSummary(
            periodStart: periodStart,
            periodEnd: now,
            completedSessions: completedSessions.count,
            focusedMinutes: activityByTopic.values.reduce(0) { $0 + $1.focusedMinutes },
            cardReviews: recentReviews.count,
            completedTests: completedAttempts.count,
            averageTestScore: scores.isEmpty ? nil : scores.reduce(0, +) / Double(scores.count),
            topicActivity: activityByTopic.values.sorted {
                let left = $0.completedSessions + $0.cardReviews + $0.completedTests
                let right = $1.completedSessions + $1.cardReviews + $1.completedTests
                return left == right ? $0.topicId.uuidString < $1.topicId.uuidString : left > right
            },
            difficultTopics: difficultyByTopic.values.filter { $0.signalCount > 0 }.sorted {
                $0.signalCount == $1.signalCount
                    ? $0.topicId.uuidString < $1.topicId.uuidString
                    : $0.signalCount > $1.signalCount
            },
            openQuestions: unresolvedQuestions.filter {
                $0.payload.resolvedAt == nil && activeTopicIds.contains($0.payload.topicId)
            }.sorted { $0.payload.createdAt > $1.payload.createdAt },
            upcomingGoals: goals.filter {
                $0.payload.state == .active
                    && activeTopicIds.contains($0.payload.topicId)
                    && ($0.payload.targetDate.map { $0 <= upcomingEnd } ?? false)
            }.sorted {
                ($0.payload.targetDate ?? .distantFuture) < ($1.payload.targetDate ?? .distantFuture)
            },
            reviewLoad: reviewLoadByTopic.values.sorted {
                $0.total == $1.total
                    ? $0.topicId.uuidString < $1.topicId.uuidString
                    : $0.total > $1.total
            },
            nextActions: Array(nextActions.prefix(3))
        )
    }

    private static func isWithin(_ date: Date?, start: Date, end: Date) -> Bool {
        guard let date else { return false }
        return date >= start && date <= end
    }
}
