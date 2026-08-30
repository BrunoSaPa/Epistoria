import Foundation

public enum DailyReviewItemKind: String, Codable, CaseIterable, Sendable {
    case evidence = "EVIDENCE"
    case concept = "CONCEPT"
    case testMistake = "TEST_MISTAKE"
}

public enum DailyReviewAction: String, Codable, CaseIterable, Sendable {
    case remembered = "REMEMBERED"
    case difficult = "DIFFICULT"
    case later = "LATER"
    case dismissed = "DISMISSED"
}

/// One append-only owner response to a locally selected review item.
///
/// The item content remains in its authoritative Evidence, Concept, or frozen test record. This
/// payload stores only scheduling state and references, so a review never copies or rewrites the
/// original material.
public struct DailyReviewResponsePayload: EntityPayload, Equatable {
    public static let entityType = EntityType.dailyReviewResponse
    public var schemaVersion = "daily-review-response/v1"
    public var itemKind: DailyReviewItemKind
    public var targetId: UUID
    public var topicId: UUID?
    public var evidenceIds: [UUID]
    public var action: DailyReviewAction
    public var targetUpdatedAt: Date
    public var reviewedAt: Date
    public var nextReviewAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        itemKind: DailyReviewItemKind,
        targetId: UUID,
        topicId: UUID?,
        evidenceIds: [UUID],
        action: DailyReviewAction,
        targetUpdatedAt: Date,
        reviewedAt: Date,
        nextReviewAt: Date?
    ) {
        self.itemKind = itemKind
        self.targetId = targetId
        self.topicId = topicId
        self.evidenceIds = Array(Set(evidenceIds)).sorted { $0.uuidString < $1.uuidString }
        self.action = action
        self.targetUpdatedAt = targetUpdatedAt
        self.reviewedAt = reviewedAt
        self.nextReviewAt = nextReviewAt
        createdAt = reviewedAt
        updatedAt = reviewedAt
    }
}

/// A disposable local projection. It contains readable material only while the notebook is
/// unlocked and is never synchronized as a queue or stored as an AI artifact.
public struct DailyEvidenceReviewItem: Identifiable, Equatable, Sendable {
    public var id: String { "\(kind.rawValue):\(targetId.uuidString)" }
    public var kind: DailyReviewItemKind
    public var targetId: UUID
    public var topicId: UUID?
    public var title: String
    public var prompt: String
    public var answer: String?
    public var reason: String
    public var evidenceIds: [UUID]
    public var targetUpdatedAt: Date
    public var dueAt: Date
    public var reviewCount: Int
    public var priority: Int
}

public struct DailyEvidenceReviewQueue: Equatable, Sendable {
    public var items: [DailyEvidenceReviewItem]
    public var totalDueCount: Int
    public var evidenceDueCount: Int
    public var conceptDueCount: Int
    public var mistakeDueCount: Int

    public static let empty = DailyEvidenceReviewQueue(
        items: [],
        totalDueCount: 0,
        evidenceDueCount: 0,
        conceptDueCount: 0,
        mistakeDueCount: 0
    )
}

public enum DailyEvidenceReviewEngine {
    private struct Candidate {
        var item: DailyEvidenceReviewItem
        var categoryOrder: Int
    }

    private struct LatestQuestionResponse {
        var response: IdentifiedPayload<TestResponsePayload>
        var attempt: IdentifiedPayload<TestAttemptPayload>
        var question: FrozenQuestionSnapshot
        var date: Date
    }

    public static func buildQueue(
        topics: [IdentifiedPayload<TopicPayload>],
        sources: [IdentifiedPayload<SourcePayload>],
        evidence: [IdentifiedPayload<EvidencePayload>],
        concepts: [IdentifiedPayload<ConceptPayload>],
        conceptEvidence: [IdentifiedPayload<ConceptEvidenceRelationPayload>],
        cards: [IdentifiedPayload<FlashcardPayload>],
        cardRevisions: [IdentifiedPayload<FlashcardRevisionPayload>],
        cardReviews: [IdentifiedPayload<FlashcardReviewPayload>],
        attempts: [IdentifiedPayload<TestAttemptPayload>],
        testResponses: [IdentifiedPayload<TestResponsePayload>],
        reviewResponses: [IdentifiedPayload<DailyReviewResponsePayload>],
        now: Date,
        limit: Int = 5
    ) -> DailyEvidenceReviewQueue {
        guard limit > 0 else { return .empty }
        let activeTopicIds = Set(topics.filter { !$0.payload.archived }.map(\.id))
        let topicNames = Dictionary(uniqueKeysWithValues: topics.map { ($0.id, $0.payload.name) })
        let sourceById = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.payload) })
        let evidenceById = Dictionary(uniqueKeysWithValues: evidence.map { ($0.id, $0.payload) })
        let activeEvidenceIds = Set<UUID>(evidence.compactMap { value -> UUID? in
            guard sourceById[value.payload.sourceId]?.archivedAt == nil else { return nil }
            return value.id
        })
        let latestResponseByItem = latestResponses(reviewResponses)
        let responseCountByItem = Dictionary(grouping: reviewResponses) {
            responseKey(kind: $0.payload.itemKind, targetId: $0.payload.targetId)
        }.mapValues(\.count)
        let latestQuestions = latestQuestionResponses(attempts: attempts, responses: testResponses)
        let difficultEvidenceCounts = difficultEvidenceCounts(
            cards: cards,
            revisions: cardRevisions,
            reviews: cardReviews,
            latestQuestions: latestQuestions
        )

        var candidates: [Candidate] = []
        for value in evidence {
            guard let source = sourceById[value.payload.sourceId], source.archivedAt == nil else { continue }
            let topicId = source.primaryTopicId
            guard topicId.map(activeTopicIds.contains) ?? true else { continue }
            let key = responseKey(kind: .evidence, targetId: value.id)
            guard isDue(
                latestResponseByItem[key],
                targetUpdatedAt: value.payload.updatedAt,
                now: now
            ) else { continue }
            let reviewCount = responseCountByItem[key, default: 0]
            let dueAt = dueDate(
                response: latestResponseByItem[key],
                targetCreatedAt: value.payload.createdAt
            )
            let location = locatorLabel(value.payload.locator)
            candidates.append(Candidate(
                item: DailyEvidenceReviewItem(
                    kind: .evidence,
                    targetId: value.id,
                    topicId: topicId,
                    title: source.title,
                    prompt: value.payload.excerpt,
                    answer: value.payload.note,
                    reason: location.map { "Saved Evidence · \($0)" } ?? "Saved Evidence",
                    evidenceIds: [value.id],
                    targetUpdatedAt: value.payload.updatedAt,
                    dueAt: dueAt,
                    reviewCount: reviewCount,
                    priority: 100 + min(reviewCount, 20)
                ),
                categoryOrder: 2
            ))
        }

        let evidenceIdsByConcept = Dictionary(grouping: conceptEvidence, by: \.payload.conceptId)
            .mapValues { Array(Set($0.map(\.payload.evidenceId))) }
        for value in concepts where value.payload.state == .active {
            let topicId = value.payload.topicIds.first(where: activeTopicIds.contains)
            guard topicId != nil || value.payload.topicIds.isEmpty else { continue }
            let linkedEvidenceIds = Array(evidenceIdsByConcept[value.id, default: []].filter {
                evidenceById[$0] != nil
                    && activeEvidenceIds.contains($0)
                    && difficultEvidenceCounts[$0, default: 0] > 0
            }.sorted { $0.uuidString < $1.uuidString }.prefix(12))
            let difficulty = linkedEvidenceIds.reduce(0) { $0 + difficultEvidenceCounts[$1, default: 0] }
            guard difficulty > 0, !value.payload.conceptDescription.isEmpty || !linkedEvidenceIds.isEmpty else {
                continue
            }
            let key = responseKey(kind: .concept, targetId: value.id)
            guard isDue(
                latestResponseByItem[key],
                targetUpdatedAt: value.payload.updatedAt,
                now: now
            ) else { continue }
            candidates.append(Candidate(
                item: DailyEvidenceReviewItem(
                    kind: .concept,
                    targetId: value.id,
                    topicId: topicId,
                    title: value.payload.name,
                    prompt: "Explain this Concept before revealing the saved description.",
                    answer: value.payload.conceptDescription.isEmpty
                        ? nil
                        : value.payload.conceptDescription,
                    reason: "Connected to \(difficulty) difficult review signal\(difficulty == 1 ? "" : "s")",
                    evidenceIds: linkedEvidenceIds,
                    targetUpdatedAt: value.payload.updatedAt,
                    dueAt: dueDate(
                        response: latestResponseByItem[key],
                        targetCreatedAt: value.payload.createdAt
                    ),
                    reviewCount: responseCountByItem[key, default: 0],
                    priority: 200 + min(difficulty, 50)
                ),
                categoryOrder: 1
            ))
        }

        for latest in latestQuestions.values {
            let response = latest.response.payload
            let isDifficult = response.isCorrect == false || response.confidence.map { $0 <= 1 } == true
            guard isDifficult, activeTopicIds.contains(latest.attempt.payload.topicId) else { continue }
            let key = responseKey(kind: .testMistake, targetId: latest.response.id)
            guard isDue(
                latestResponseByItem[key],
                targetUpdatedAt: response.updatedAt,
                now: now
            ) else { continue }
            let reason: String
            if response.isCorrect == false, response.confidence.map({ $0 <= 1 }) == true {
                reason = "Incorrect and low confidence"
            } else if response.isCorrect == false {
                reason = "Earlier incorrect answer"
            } else {
                reason = "Earlier low-confidence answer"
            }
            let ownerAnswer = response.isSkipped || response.response.isEmpty ? "Skipped" : response.response
            let answer = "Your answer: \(ownerAnswer)\n\nReference answer: \(latest.question.correctAnswer)"
            let topicName = topicNames[latest.attempt.payload.topicId] ?? "Topic"
            candidates.append(Candidate(
                item: DailyEvidenceReviewItem(
                    kind: .testMistake,
                    targetId: latest.response.id,
                    topicId: latest.attempt.payload.topicId,
                    title: "Earlier mistake · \(topicName)",
                    prompt: latest.question.prompt,
                    answer: answer,
                    reason: reason,
                    evidenceIds: Array(Set(latest.question.evidenceIds).sorted {
                        $0.uuidString < $1.uuidString
                    }.prefix(12)),
                    targetUpdatedAt: latest.date,
                    dueAt: dueDate(
                        response: latestResponseByItem[key],
                        targetCreatedAt: latest.date
                    ),
                    reviewCount: responseCountByItem[key, default: 0],
                    priority: 300 + (response.isCorrect == false ? 20 : 0)
                ),
                categoryOrder: 0
            ))
        }

        let sorted = candidates.sorted(by: candidatePrecedes)
        var selected: [Candidate] = []
        var selectedIds = Set<String>()
        for category in 0...2 {
            guard selected.count < limit,
                  let candidate = sorted.first(where: { $0.categoryOrder == category })
            else { continue }
            selected.append(candidate)
            selectedIds.insert(candidate.item.id)
        }
        for candidate in sorted where selected.count < limit && !selectedIds.contains(candidate.item.id) {
            selected.append(candidate)
            selectedIds.insert(candidate.item.id)
        }

        return DailyEvidenceReviewQueue(
            items: selected.map(\.item),
            totalDueCount: candidates.count,
            evidenceDueCount: candidates.filter { $0.item.kind == .evidence }.count,
            conceptDueCount: candidates.filter { $0.item.kind == .concept }.count,
            mistakeDueCount: candidates.filter { $0.item.kind == .testMistake }.count
        )
    }

    public static func nextReviewDate(
        action: DailyReviewAction,
        previousResponses: [IdentifiedPayload<DailyReviewResponsePayload>],
        now: Date,
        calendar suppliedCalendar: Calendar? = nil
    ) -> Date? {
        guard action != .dismissed else { return nil }
        var calendar = suppliedCalendar ?? Calendar(identifier: .gregorian)
        if suppliedCalendar == nil { calendar.timeZone = .current }
        let start = calendar.startOfDay(for: now)
        let days: Int
        switch action {
        case .difficult, .later:
            days = 1
        case .remembered:
            let rememberedCount = previousResponses.count { $0.payload.action == .remembered }
            let intervals = [7, 21, 60, 120]
            days = intervals[min(rememberedCount, intervals.count - 1)]
        case .dismissed:
            return nil
        }
        return calendar.date(byAdding: .day, value: days, to: start)
    }

    private static func latestResponses(
        _ responses: [IdentifiedPayload<DailyReviewResponsePayload>]
    ) -> [String: IdentifiedPayload<DailyReviewResponsePayload>] {
        Dictionary(grouping: responses) {
            responseKey(kind: $0.payload.itemKind, targetId: $0.payload.targetId)
        }.compactMapValues { values in
            values.max {
                if $0.payload.reviewedAt != $1.payload.reviewedAt {
                    return $0.payload.reviewedAt < $1.payload.reviewedAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }
        }
    }

    private static func isDue(
        _ response: IdentifiedPayload<DailyReviewResponsePayload>?,
        targetUpdatedAt: Date,
        now: Date
    ) -> Bool {
        guard let response else { return true }
        if targetUpdatedAt > response.payload.targetUpdatedAt { return true }
        if response.payload.action == .dismissed { return false }
        return response.payload.nextReviewAt.map { $0 <= now } ?? true
    }

    private static func dueDate(
        response: IdentifiedPayload<DailyReviewResponsePayload>?,
        targetCreatedAt: Date
    ) -> Date {
        response?.payload.nextReviewAt ?? targetCreatedAt
    }

    private static func difficultEvidenceCounts(
        cards: [IdentifiedPayload<FlashcardPayload>],
        revisions: [IdentifiedPayload<FlashcardRevisionPayload>],
        reviews: [IdentifiedPayload<FlashcardReviewPayload>],
        latestQuestions: [UUID: LatestQuestionResponse]
    ) -> [UUID: Int] {
        let revisionById = Dictionary(uniqueKeysWithValues: revisions.map { ($0.id, $0.payload) })
        let latestReviewByCard = Dictionary(grouping: reviews, by: \.payload.cardId).compactMapValues {
            $0.max { $0.payload.reviewedAt < $1.payload.reviewedAt }
        }
        var counts: [UUID: Int] = [:]
        for card in cards where card.payload.archivedAt == nil && card.payload.suspendedAt == nil {
            guard let review = latestReviewByCard[card.id],
                  review.payload.rating == .again || review.payload.rating == .hard,
                  let revision = revisionById[card.payload.currentRevisionId]
            else { continue }
            for evidenceId in Set(revision.evidenceIds) { counts[evidenceId, default: 0] += 1 }
        }
        for latest in latestQuestions.values {
            let response = latest.response.payload
            guard response.isCorrect == false || response.confidence.map({ $0 <= 1 }) == true else {
                continue
            }
            for evidenceId in Set(latest.question.evidenceIds) { counts[evidenceId, default: 0] += 1 }
        }
        return counts
    }

    private static func latestQuestionResponses(
        attempts: [IdentifiedPayload<TestAttemptPayload>],
        responses: [IdentifiedPayload<TestResponsePayload>]
    ) -> [UUID: LatestQuestionResponse] {
        let eligibleAttempts: [(UUID, IdentifiedPayload<TestAttemptPayload>)] = attempts.compactMap { attempt in
            guard attempt.payload.state == .submitted || attempt.payload.state == .scored else { return nil }
            return (attempt.id, attempt)
        }
        let attemptById = Dictionary(uniqueKeysWithValues: eligibleAttempts)
        var result: [UUID: LatestQuestionResponse] = [:]
        for response in responses {
            guard let attempt = attemptById[response.payload.attemptId],
                  let question = attempt.payload.frozenQuestions.first(where: {
                      $0.questionId == response.payload.questionId
                  })
            else { continue }
            let date = attempt.payload.submittedAt ?? attempt.payload.updatedAt
            let candidate = LatestQuestionResponse(
                response: response,
                attempt: attempt,
                question: question,
                date: date
            )
            if let current = result[question.questionId] {
                if current.date > date { continue }
                if current.date == date, current.response.id.uuidString > response.id.uuidString { continue }
            }
            result[question.questionId] = candidate
        }
        return result
    }

    private static func candidatePrecedes(_ left: Candidate, _ right: Candidate) -> Bool {
        if left.item.dueAt != right.item.dueAt { return left.item.dueAt < right.item.dueAt }
        if left.item.priority != right.item.priority { return left.item.priority > right.item.priority }
        if left.categoryOrder != right.categoryOrder { return left.categoryOrder < right.categoryOrder }
        return left.item.id < right.item.id
    }

    private static func responseKey(kind: DailyReviewItemKind, targetId: UUID) -> String {
        "\(kind.rawValue):\(targetId.uuidString)"
    }

    private static func locatorLabel(_ locator: SourceLocator) -> String? {
        switch locator.kind {
        case .pdf: locator.page.map { "page \($0)" }
        case .media: locator.startSeconds.map { seconds in
            let total = max(Int(seconds), 0)
            return String(format: "%d:%02d", total / 60, total % 60)
        }
        case .slide: locator.slide.map { "slide \($0)" }
        case .sheet: locator.sheet
        case .epub: locator.chapter
        case .web, .document: locator.heading
        case .image: "image region"
        case .plainText: "text excerpt"
        }
    }
}
