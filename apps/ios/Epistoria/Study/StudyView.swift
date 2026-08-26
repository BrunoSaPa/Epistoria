import EpistoriaCore
import SwiftUI

enum StudyRecommendationDestination: Hashable, Identifiable {
    case card(UUID)
    case session(UUID)
    case attempt(UUID)
    case test(UUID)
    case goal(UUID)
    case question(UUID)
    case topic(UUID)

    var id: String {
        switch self {
        case .card(let id): "card:\(id.uuidString)"
        case .session(let id): "session:\(id.uuidString)"
        case .attempt(let id): "attempt:\(id.uuidString)"
        case .test(let id): "test:\(id.uuidString)"
        case .goal(let id): "goal:\(id.uuidString)"
        case .question(let id): "question:\(id.uuidString)"
        case .topic(let id): "topic:\(id.uuidString)"
        }
    }

    static func resolve(
        _ recommendation: LocalStudyRecommendation,
        dueCardIdsByTopic: [UUID: [UUID]],
        sessionIds: Set<UUID>,
        attemptIds: Set<UUID>,
        testIds: Set<UUID>
    ) -> StudyRecommendationDestination {
        switch recommendation.kind {
        case .dueCards:
            if let id = dueCardIdsByTopic[recommendation.topicId]?.first { return .card(id) }
        case .pausedSession:
            if let id = recommendation.targetId, sessionIds.contains(id) { return .session(id) }
        case .unfinishedTest:
            if let id = recommendation.targetId, attemptIds.contains(id) { return .attempt(id) }
        case .goalDeadline:
            if let id = recommendation.targetId { return .goal(id) }
        case .unresolvedQuestion:
            if let id = recommendation.targetId { return .question(id) }
        case .testErrors:
            if let id = recommendation.targetId {
                if attemptIds.contains(id) { return .attempt(id) }
                if testIds.contains(id) { return .test(id) }
            }
        case .incompleteCoverage:
            if let id = recommendation.targetId, testIds.contains(id) { return .test(id) }
        case .neglectedTopic:
            break
        }
        return .topic(recommendation.topicId)
    }
}

struct StudyView: View {
    private enum StudySection: String, CaseIterable, Identifiable {
        case guide = "Tutor"
        case next = "Study Next"
        case week = "Week"
        case sessions = "Sessions"
        case flashcards = "Flashcards"
        case tests = "Tests"
        case history = "History"
        var id: Self { self }
    }

    @Bindable var model: AppModel
    @State private var section = StudySection.next
    @State private var topics: [IdentifiedPayload<TopicPayload>] = []
    @State private var sessions: [IdentifiedPayload<StudySessionPayload>] = []
    @State private var cards: [IdentifiedPayload<FlashcardPayload>] = []
    @State private var revisions: [UUID: IdentifiedPayload<FlashcardRevisionPayload>] = [:]
    @State private var reviews: [IdentifiedPayload<FlashcardReviewPayload>] = []
    @State private var tests: [IdentifiedPayload<PracticeTestPayload>] = []
    @State private var attempts: [IdentifiedPayload<TestAttemptPayload>] = []
    @State private var testResponses: [IdentifiedPayload<TestResponsePayload>] = []
    @State private var goals: [IdentifiedPayload<StudyGoalPayload>] = []
    @State private var unresolved: [IdentifiedPayload<UnresolvedQuestionPayload>] = []
    @State private var recommendations: [IdentifiedPayload<StudyRecommendationPayload>] = []
    @State private var recommendationResponses: [IdentifiedPayload<RecommendationResponsePayload>] = []
    @State private var openedRecommendationDestination: StudyRecommendationDestination?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Study section", selection: $section) {
                    ForEach(StudySection.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, EpistoriaDesign.Spacing.page)
                .padding(.vertical, 12)

                List {
                    switch section {
                    case .guide: tutorContent
                    case .next: studyNextContent
                    case .week: weeklyReviewContent
                    case .sessions: sessionsContent
                    case .flashcards: flashcardsContent
                    case .tests: testsContent
                    case .history: historyContent
                    }
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle("Study")
            .epistoriaPageBackground()
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        LearningManagementView(model: model)
                    } label: {
                        Label("Manage learning records", systemImage: "slider.horizontal.3")
                    }
                }
            }
            .task { await load() }
            .refreshable { await load() }
            .navigationDestination(item: $openedRecommendationDestination) { destination in
                recommendationDestination(destination)
            }
            .alert("Study error", isPresented: .constant(errorMessage != nil)) {
                Button("Try again") { Task { await load() } }
                Button("Dismiss", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    @ViewBuilder private var tutorContent: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Label("Adaptive Learning Guide", systemImage: "graduationcap")
                    .font(.title2.weight(.semibold))
                Text("Work through cited explanations, examples, retrieval questions, and transfer problems. Tutor sessions and your answers are saved locally.")
                    .foregroundStyle(.secondary)
                NavigationLink {
                    AdaptiveTutorView(model: model)
                } label: {
                    Label("Start or resume Tutor", systemImage: "arrow.right.circle.fill")
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .tint(EpistoriaDesign.ink)
            }
            .padding(.vertical, 8)
        }

        Section("How it works") {
            StudyRow(title: "Grounded", detail: "Answers cite the exact frozen Source Version used.", symbol: "link")
            StudyRow(title: "Adaptive", detail: "Accepted results change the next activity. Draft assessments do not.", symbol: "arrow.triangle.branch")
            StudyRow(title: "Bounded", detail: "Each session has a reviewed Topic scope, provider route, turn limit, expiration, and spending limit.", symbol: "hand.raised")
        }
    }

    @ViewBuilder private var weeklyReviewContent: some View {
        let review = weeklyReview
        Section {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Weekly review")
                        .font(.title2.weight(.semibold))
                    Text("\(review.periodStart.formatted(date: .abbreviated, time: .omitted))–\(review.periodEnd.formatted(date: .abbreviated, time: .omitted))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 10)], spacing: 10) {
                    WeeklyMetric(title: "Focus", value: durationLabel(review.focusedMinutes), symbol: "timer")
                    WeeklyMetric(title: "Cards", value: "\(review.cardReviews)", symbol: "rectangle.stack")
                    WeeklyMetric(title: "Tests", value: "\(review.completedTests)", symbol: "checkmark.square")
                    WeeklyMetric(
                        title: "Average",
                        value: review.averageTestScore?.formatted(.percent.precision(.fractionLength(0))) ?? "—",
                        symbol: "chart.bar"
                    )
                }
            }
            .padding(.vertical, 6)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Weekly learning summary")
        }

        Section("Completed work") {
            if review.topicActivity.isEmpty {
                Text("No completed sessions, card reviews, or submitted tests in the last seven days.")
                    .foregroundStyle(.secondary)
            }
            ForEach(review.topicActivity) { activity in
                NavigationLink {
                    TopicDashboardView(model: model, topicId: activity.topicId)
                } label: {
                    StudyRow(
                        title: topicName(activity.topicId),
                        detail: activityDetail(activity),
                        symbol: "checkmark.circle"
                    )
                }
            }
        }

        Section("Difficult material") {
            if review.difficultTopics.isEmpty {
                Text("No difficult card ratings, incorrect answers, or low-confidence answers were recorded this week.")
                    .foregroundStyle(.secondary)
            }
            ForEach(review.difficultTopics) { difficulty in
                NavigationLink {
                    TopicDashboardView(model: model, topicId: difficulty.topicId)
                } label: {
                    StudyRow(
                        title: topicName(difficulty.topicId),
                        detail: difficultyDetail(difficulty),
                        symbol: "exclamationmark.circle"
                    )
                }
            }
        }

        Section("Open questions") {
            if review.openQuestions.isEmpty {
                Text("No unresolved questions.").foregroundStyle(.secondary)
            }
            ForEach(review.openQuestions.prefix(8), id: \.id) { question in
                NavigationLink {
                    LearningManagementView(model: model, initialTarget: .question(question.id))
                } label: {
                    StudyRow(
                        title: question.payload.question,
                        detail: topicName(question.payload.topicId),
                        symbol: "questionmark.circle"
                    )
                }
            }
        }

        Section("Next seven days") {
            if review.upcomingGoals.isEmpty && review.reviewLoad.isEmpty {
                Text("No dated goals or scheduled card reviews in the next seven days.")
                    .foregroundStyle(.secondary)
            }
            ForEach(review.upcomingGoals.prefix(8), id: \.id) { goal in
                NavigationLink {
                    LearningManagementView(model: model, initialTarget: .goal(goal.id))
                } label: {
                    StudyRow(
                        title: goal.payload.title,
                        detail: goal.payload.targetDate.map {
                            "\(topicName(goal.payload.topicId)) · \(goalDueLabel($0))"
                        } ?? topicName(goal.payload.topicId),
                        symbol: "target"
                    )
                }
            }
            ForEach(review.reviewLoad) { load in
                NavigationLink {
                    TopicDashboardView(model: model, topicId: load.topicId)
                } label: {
                    StudyRow(
                        title: topicName(load.topicId),
                        detail: reviewLoadDetail(load),
                        symbol: "calendar"
                    )
                }
            }
        }

        Section("Suggested next actions") {
            if review.nextActions.isEmpty {
                Text("No next action is available yet.").foregroundStyle(.secondary)
            }
            ForEach(review.nextActions) { recommendation in
                Button {
                    open(recommendation)
                } label: {
                    HStack(spacing: 12) {
                        StudyRow(
                            title: recommendation.title,
                            detail: recommendation.explanation,
                            symbol: recommendation.symbol
                        )
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
        }

        Section {
            Text("This review is calculated on this iPad from your durable learning history. It does not use a provider or create a paid AI job.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var studyNextContent: some View {
        Section("Recommended now") {
            if let recommendation = currentRecommendation {
                Button {
                    open(recommendation)
                } label: {
                    HStack(spacing: 12) {
                        StudyRow(
                            title: recommendation.title,
                            detail: recommendation.explanation,
                            symbol: recommendation.symbol
                        )
                        Spacer()
                        Text(recommendation.actionTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                Menu("Recommendation actions", systemImage: "ellipsis.circle") {
                    Button("Pin", systemImage: "pin") { Task { await respond(recommendation, action: .pinned) } }
                    Button("Snooze one day", systemImage: "clock") { Task { await respond(recommendation, action: .snoozed) } }
                    Button("Dismiss", systemImage: "xmark") { Task { await respond(recommendation, action: .dismissed) } }
                    Button("Not relevant", systemImage: "hand.thumbsdown") { Task { await respond(recommendation, action: .irrelevant) } }
                }
            } else {
                ContentUnavailableView(
                    "Nothing urgent",
                    systemImage: "checkmark.circle",
                    description: Text("Add a goal, cards, a test, or an unresolved question to receive a local recommendation.")
                )
            }
        }
        if !dueCards.isEmpty {
            Section("Due reviews") {
                ForEach(dueCards.prefix(5), id: \.id) { card in cardRow(card) }
            }
        }
        if !unfinishedAttempts.isEmpty {
            Section("Unfinished tests") {
                ForEach(unfinishedAttempts, id: \.id) { attempt in
                    NavigationLink {
                        TestAttemptView(model: model, attemptId: attempt.id)
                    } label: {
                        StudyRow(title: testName(attempt.payload.testId), detail: "Continue saved attempt", symbol: "square.and.pencil")
                    }
                }
            }
        }
        if !recommendationResponses.isEmpty {
            Section("Response history") {
                ForEach(recommendationResponses.sorted { $0.payload.createdAt > $1.payload.createdAt }.prefix(30), id: \.id) { response in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: response.payload.action.historySymbol)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(responseTitle(response.payload))
                                .lineLimit(2)
                            Text("\(response.payload.action.historyLabel) · \(response.payload.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let until = response.payload.snoozedUntil {
                                Text("Until \(until.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if response.payload.action != .accepted,
                           let recommendation = recommendation(from: response.payload) {
                            Button("Restore") {
                                Task { await respond(recommendation, action: .accepted) }
                            }
                            .font(.caption.weight(.semibold))
                        }
                    }
                }
                Text("Responses are append-only learning history. Restore adds a new response and does not erase the earlier action.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var sessionsContent: some View {
        Section {
            NavigationLink {
                SessionsView(model: model)
            } label: {
                StudyRow(title: "Open Sessions", detail: "Plan, time, pause, and review focused work", symbol: "timer")
            }
        }
        Section("Recent") {
            ForEach(sessions.prefix(12), id: \.id) { session in
                NavigationLink {
                    SessionDetailView(model: model, sessionId: session.id)
                } label: {
                    StudyRow(title: session.payload.title, detail: topicName(session.payload.courseId), symbol: "timer")
                }
            }
        }
    }

    @ViewBuilder private var flashcardsContent: some View {
        Section("Due now") {
            if dueCards.isEmpty { Text("No cards are due.").foregroundStyle(.secondary) }
            ForEach(dueCards, id: \.id) { card in cardRow(card) }
        }
        Section("All cards") {
            ForEach(cards.filter { $0.payload.archivedAt == nil }, id: \.id) { card in cardRow(card) }
        }
    }

    @ViewBuilder private var testsContent: some View {
        Section("Ready") {
            if tests.isEmpty { Text("Create a test from a Topic dashboard.").foregroundStyle(.secondary) }
            ForEach(tests.filter { $0.payload.state == .ready }, id: \.id) { test in
                NavigationLink {
                    PracticeTestDetailView(model: model, testId: test.id)
                } label: {
                    StudyRow(title: test.payload.title, detail: topicName(test.payload.topicId), symbol: "checkmark.square")
                }
            }
        }
        Section("In progress") {
            ForEach(unfinishedAttempts, id: \.id) { attempt in
                NavigationLink {
                    TestAttemptView(model: model, attemptId: attempt.id)
                } label: {
                    StudyRow(title: testName(attempt.payload.testId), detail: "Responses saved locally", symbol: "square.and.pencil")
                }
            }
        }
    }

    @ViewBuilder private var historyContent: some View {
        Section("Test attempts") {
            ForEach(attempts.filter { $0.payload.state == .submitted || $0.payload.state == .scored }, id: \.id) { attempt in
                NavigationLink {
                    TestAttemptView(model: model, attemptId: attempt.id)
                } label: {
                    StudyRow(
                        title: testName(attempt.payload.testId),
                        detail: attemptScore(attempt.payload),
                        symbol: "checkmark.square"
                    )
                }
            }
        }
        Section("Completed sessions") {
            ForEach(sessions.filter { $0.payload.state == .ended || $0.payload.state == .abandoned }, id: \.id) { session in
                NavigationLink {
                    SessionDetailView(model: model, sessionId: session.id)
                } label: {
                    StudyRow(title: session.payload.title, detail: session.payload.startedAt.formatted(date: .abbreviated, time: .shortened), symbol: "clock.arrow.circlepath")
                }
            }
        }
    }

    private func cardRow(_ card: IdentifiedPayload<FlashcardPayload>) -> some View {
        let revision = revisions[card.payload.currentRevisionId]
        return NavigationLink {
            FlashcardReviewView(model: model, cardId: card.id)
        } label: {
            StudyRow(
                title: revision?.payload.prompt ?? "Flashcard",
                detail: topicName(card.payload.topicId),
                symbol: "rectangle.stack"
            )
        }
    }

    private var dueCards: [IdentifiedPayload<FlashcardPayload>] {
        cards.filter { card in
            guard card.payload.archivedAt == nil, card.payload.suspendedAt == nil else { return false }
            let latest = reviews.filter { $0.payload.cardId == card.id }.max { $0.payload.reviewedAt < $1.payload.reviewedAt }
            return latest?.payload.resultingState.dueAt ?? card.payload.createdAt <= .now
        }
    }

    private var unfinishedAttempts: [IdentifiedPayload<TestAttemptPayload>] {
        attempts.filter { $0.payload.state == .inProgress }
    }

    private var currentRecommendation: LocalStudyRecommendation? {
        rankedRecommendations.first
    }

    private var weeklyReview: WeeklyReviewSummary {
        WeeklyReviewEngine.summarize(
            topics: topics,
            sessions: sessions,
            cards: cards,
            reviews: reviews,
            attempts: attempts,
            responses: testResponses,
            goals: goals,
            unresolvedQuestions: unresolved,
            nextActions: rankedRecommendations,
            now: .now
        )
    }

    private var rankedRecommendations: [LocalStudyRecommendation] {
        let ranked = StudyNextEngine.rank(
            topics: topics,
            goals: goals,
            unresolvedQuestions: unresolved,
            sessions: sessions,
            tests: tests,
            attempts: attempts,
            dueCardCounts: Dictionary(grouping: dueCards, by: \.payload.topicId).mapValues(\.count),
            storedRecommendations: recommendations,
            now: .now
        )
        let latestResponses = Dictionary(grouping: recommendationResponses, by: \.payload.recommendationId)
            .compactMapValues { $0.max { $0.payload.createdAt < $1.payload.createdAt }?.payload }
        var suppressed = Set<String>()
        var pinned = Set<String>()
        for stored in recommendations {
            guard let response = latestResponses[stored.id] else { continue }
            let key = recommendationKey(
                topicId: stored.payload.topicId,
                kind: stored.payload.kind,
                targetId: stored.payload.targetEntityIds.first
            )
            switch response.action {
            case .pinned: pinned.insert(key)
            case .snoozed:
                if response.snoozedUntil.map({ $0 > .now }) ?? true { suppressed.insert(key) }
            case .dismissed, .irrelevant: suppressed.insert(key)
            case .accepted: break
            }
        }
        var unique: [String: LocalStudyRecommendation] = [:]
        for item in ranked where !suppressed.contains(recommendationKey(item)) {
            let key = recommendationKey(item)
            if unique[key].map({ $0.score >= item.score }) != true { unique[key] = item }
        }
        return unique.values.sorted {
            let leftPinned = pinned.contains(recommendationKey($0))
            let rightPinned = pinned.contains(recommendationKey($1))
            if leftPinned != rightPinned { return leftPinned }
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.title < $1.title
        }
    }

    private func topicName(_ id: UUID?) -> String {
        guard let id else { return "Unassigned" }
        return topics.first { $0.id == id }?.payload.name ?? "Topic"
    }

    private func testName(_ id: UUID) -> String { tests.first { $0.id == id }?.payload.title ?? "Practice test" }

    private func attemptScore(_ attempt: TestAttemptPayload) -> String {
        let value = attempt.scoreOverride ?? attempt.score
        guard let value else { return "Submitted" }
        return value.formatted(.percent.precision(.fractionLength(0)))
    }

    private func load() async {
        guard let store = model.store else { return }
        do {
            async let a = store.topics()
            async let b = store.list(StudySessionPayload.self)
            async let c = store.list(FlashcardPayload.self)
            async let d = store.list(FlashcardRevisionPayload.self)
            async let e = store.list(FlashcardReviewPayload.self)
            async let f = store.list(PracticeTestPayload.self)
            async let g = store.list(TestAttemptPayload.self)
            async let h = store.list(StudyGoalPayload.self)
            async let i = store.list(UnresolvedQuestionPayload.self)
            async let j = store.list(StudyRecommendationPayload.self)
            async let k = store.list(RecommendationResponsePayload.self)
            async let l = store.list(TestResponsePayload.self)
            let value = try await (a, b, c, d, e, f, g, h, i, j, k, l)
            topics = value.0
            sessions = value.1.sorted { $0.payload.startedAt > $1.payload.startedAt }
            cards = value.2
            revisions = Dictionary(uniqueKeysWithValues: value.3.map { ($0.id, $0) })
            reviews = value.4
            tests = value.5
            attempts = value.6.sorted { $0.payload.startedAt > $1.payload.startedAt }
            goals = value.7
            unresolved = value.8
            recommendations = value.9
            recommendationResponses = value.10
            testResponses = value.11
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func respond(_ recommendation: LocalStudyRecommendation, action: RecommendationAction) async {
        guard let store = model.store else { return }
        do {
            let snoozedUntil = action == .snoozed
                ? Calendar.current.date(byAdding: .day, value: 1, to: .now)
                : nil
            _ = try await store.respondToRecommendation(
                recommendation,
                action: action,
                snoozedUntil: snoozedUntil
            )
            model.noteLocalMutation()
            await load()
        } catch { errorMessage = error.localizedDescription }
    }

    private func recommendationKey(_ recommendation: LocalStudyRecommendation) -> String {
        recommendationKey(
            topicId: recommendation.topicId,
            kind: recommendation.kind,
            targetId: recommendation.targetId
        )
    }

    private func recommendationKey(topicId: UUID, kind: RecommendationKind, targetId: UUID?) -> String {
        "\(topicId.uuidString):\(kind.rawValue):\(targetId?.uuidString ?? "aggregate")"
    }

    private func open(_ recommendation: LocalStudyRecommendation) {
        openedRecommendationDestination = destination(for: recommendation)
        Task { await respond(recommendation, action: .accepted) }
    }

    private func destination(for recommendation: LocalStudyRecommendation) -> StudyRecommendationDestination {
        StudyRecommendationDestination.resolve(
            recommendation,
            dueCardIdsByTopic: Dictionary(grouping: dueCards, by: \.payload.topicId).mapValues { $0.map(\.id) },
            sessionIds: Set(sessions.map(\.id)),
            attemptIds: Set(attempts.map(\.id)),
            testIds: Set(tests.map(\.id))
        )
    }

    @ViewBuilder
    private func recommendationDestination(_ destination: StudyRecommendationDestination) -> some View {
        switch destination {
        case .card(let id): FlashcardReviewView(model: model, cardId: id)
        case .session(let id): SessionDetailView(model: model, sessionId: id)
        case .attempt(let id): TestAttemptView(model: model, attemptId: id)
        case .test(let id): PracticeTestDetailView(model: model, testId: id)
        case .goal(let id): LearningManagementView(model: model, initialTarget: .goal(id))
        case .question(let id): LearningManagementView(model: model, initialTarget: .question(id))
        case .topic(let id): TopicDashboardView(model: model, topicId: id)
        }
    }

    private func responseTitle(_ response: RecommendationResponsePayload) -> String {
        if let title = response.recommendationTitle { return title }
        return recommendations.first(where: { $0.id == response.recommendationId })?.payload.title
            ?? "Study recommendation"
    }

    private func recommendation(from response: RecommendationResponsePayload) -> LocalStudyRecommendation? {
        if let stored = recommendations.first(where: { $0.id == response.recommendationId }) {
            return LocalStudyRecommendation(
                topicId: stored.payload.topicId,
                kind: stored.payload.kind,
                title: stored.payload.title,
                explanation: stored.payload.explanation,
                score: stored.payload.score,
                targetId: stored.payload.targetEntityIds.first
            )
        }
        guard let topicId = response.topicId,
              let kind = response.recommendationKind,
              let title = response.recommendationTitle
        else { return nil }
        return LocalStudyRecommendation(
            topicId: topicId,
            kind: kind,
            title: title,
            explanation: "Restored from Study Next history.",
            score: 0,
            targetId: response.targetEntityIds?.first
        )
    }

    private func durationLabel(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
    }

    private func activityDetail(_ activity: WeeklyTopicActivity) -> String {
        [
            activity.completedSessions == 0 ? nil : "\(activity.completedSessions) session\(activity.completedSessions == 1 ? "" : "s")",
            activity.focusedMinutes == 0 ? nil : durationLabel(activity.focusedMinutes),
            activity.cardReviews == 0 ? nil : "\(activity.cardReviews) card\(activity.cardReviews == 1 ? "" : "s")",
            activity.completedTests == 0 ? nil : "\(activity.completedTests) test\(activity.completedTests == 1 ? "" : "s")"
        ].compactMap { $0 }.joined(separator: " · ")
    }

    private func difficultyDetail(_ difficulty: WeeklyTopicDifficulty) -> String {
        [
            difficulty.difficultCardReviews == 0 ? nil : "\(difficulty.difficultCardReviews) difficult card rating\(difficulty.difficultCardReviews == 1 ? "" : "s")",
            difficulty.incorrectTestResponses == 0 ? nil : "\(difficulty.incorrectTestResponses) incorrect answer\(difficulty.incorrectTestResponses == 1 ? "" : "s")",
            difficulty.lowConfidenceResponses == 0 ? nil : "\(difficulty.lowConfidenceResponses) low-confidence answer\(difficulty.lowConfidenceResponses == 1 ? "" : "s")"
        ].compactMap { $0 }.joined(separator: " · ")
    }

    private func reviewLoadDetail(_ load: WeeklyTopicReviewLoad) -> String {
        [
            load.overdueCards == 0 ? nil : "\(load.overdueCards) due now",
            load.upcomingCards == 0 ? nil : "\(load.upcomingCards) later this week"
        ].compactMap { $0 }.joined(separator: " · ")
    }

    private func goalDueLabel(_ date: Date) -> String {
        let prefix = date < .now ? "Overdue since" : "Due"
        return "\(prefix) \(date.formatted(date: .abbreviated, time: .omitted))"
    }
}

private struct WeeklyMetric: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .padding(12)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(value)")
    }
}

private struct StudyRow: View {
    let title: String
    let detail: String
    let symbol: String
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(2)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        } icon: { Image(systemName: symbol).foregroundStyle(EpistoriaDesign.ink) }
    }
}

private extension LocalStudyRecommendation {
    var actionTitle: String {
        switch kind {
        case .dueCards: "Review"
        case .testErrors: "Review errors"
        case .unresolvedQuestion: "Resolve"
        case .incompleteCoverage: "Review coverage"
        case .pausedSession: "Resume"
        case .unfinishedTest: "Continue"
        case .neglectedTopic: "Open Topic"
        case .goalDeadline: "Open goal"
        }
    }
}

private extension RecommendationAction {
    var historyLabel: String {
        switch self {
        case .accepted: "Opened"
        case .pinned: "Pinned"
        case .snoozed: "Snoozed"
        case .dismissed: "Dismissed"
        case .irrelevant: "Marked not relevant"
        }
    }

    var historySymbol: String {
        switch self {
        case .accepted: "arrow.right.circle"
        case .pinned: "pin"
        case .snoozed: "clock"
        case .dismissed: "xmark.circle"
        case .irrelevant: "hand.thumbsdown"
        }
    }
}

struct NewFlashcardView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let topicId: UUID
    let onCreated: () -> Void
    @State private var kind = FlashcardKind.basic
    @State private var prompt = ""
    @State private var answer = ""
    @State private var decks: [IdentifiedPayload<FlashcardDeckPayload>] = []
    @State private var deckId: UUID?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Picker("Card type", selection: $kind) {
                    ForEach(FlashcardKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("Deck", selection: $deckId) {
                    Text("No deck").tag(UUID?.none)
                    ForEach(decks, id: \.id) { deck in
                        Text(deck.payload.name).tag(Optional(deck.id))
                    }
                }
                TextField("Prompt", text: $prompt, axis: .vertical)
                TextField("Answer", text: $answer, axis: .vertical)
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle("New flashcard")
            .task { await loadDecks() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await create() } }
                        .disabled(prompt.trimmed.isEmpty || answer.trimmed.isEmpty)
                }
            }
        }
    }

    private func create() async {
        guard let store = model.store else { return }
        do {
            _ = try await store.createFlashcard(
                topicId: topicId,
                deckId: deckId,
                kind: kind,
                prompt: prompt.trimmed,
                answer: answer.trimmed
            )
            model.noteLocalMutation()
            onCreated()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }

    private func loadDecks() async {
        guard let store = model.store else { return }
        do {
            decks = try await store.list(FlashcardDeckPayload.self)
                .filter { $0.payload.topicId == topicId && $0.payload.archivedAt == nil }
                .sorted { $0.payload.name < $1.payload.name }
        } catch { errorMessage = error.localizedDescription }
    }
}

struct NewPracticeTestView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let topicId: UUID
    let onCreated: () -> Void
    @State private var title = "Practice test"
    @State private var mode = TestMode.comprehensive
    @State private var objectives = ""
    @State private var questions = ""
    @State private var usesTimeLimit = false
    @State private var timeLimitMinutes = 30
    @State private var customCoverage = Set(TestCoverageDimension.allCases)
    @State private var includeConnectedKnowledge = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Test title", text: $title)
                Section("Plan") {
                    Picker("Mode", selection: $mode) {
                        ForEach(TestMode.allCases, id: \.self) { value in
                            Text(value.studyDisplayName).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(mode.studyExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Time limit", isOn: $usesTimeLimit)
                    if usesTimeLimit {
                        Stepper("Limit: \(timeLimitMinutes) minutes", value: $timeLimitMinutes, in: 5...600, step: 5)
                    }
                }
                Section("Objectives") {
                    TextEditor(text: $objectives).frame(minHeight: 100)
                    Text("Enter one objective per line. The saved blueprint reports any objective without a question.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Coverage dimensions") {
                    ForEach(TestCoverageDimension.allCases, id: \.self) { dimension in
                        Toggle(dimension.studyDisplayName, isOn: coverageBinding(for: dimension))
                            .disabled(mode != .custom)
                    }
                    if mode != .custom {
                        Text("Choose Custom to change these dimensions.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Questions") {
                    TextEditor(text: $questions).frame(minHeight: 140)
                    Text("Enter one question per line as: question | correct answer. Questions are assigned across the objectives in order.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let localCoverageWarning {
                        Label(localCoverageWarning, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle("Include connected knowledge", isOn: $includeConnectedKnowledge)
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle("New test")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await create() } }
                        .disabled(parsedObjectives.isEmpty || parsedQuestions.isEmpty || effectiveCoverage.isEmpty)
                }
            }
        }
    }

    private var parsedObjectives: [TestObjective] {
        objectives.split(whereSeparator: \.isNewline).map(String.init).map(\.trimmed).filter { !$0.isEmpty }.map {
            TestObjective(title: $0, dimensions: effectiveCoverage)
        }
    }

    private var parsedQuestions: [(String, String)] {
        questions.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[0].trimmed.isEmpty, !parts[1].trimmed.isEmpty else { return nil }
            return (parts[0].trimmed, parts[1].trimmed)
        }
    }

    private var effectiveCoverage: [TestCoverageDimension] {
        switch mode {
        case .comprehensive:
            TestCoverageDimension.allCases
        case .quickCheck:
            [.conceptual, .methodSelection, .verification]
        case .custom:
            TestCoverageDimension.allCases.filter(customCoverage.contains)
        }
    }

    private var localCoverageWarning: String? {
        if mode == .comprehensive, parsedQuestions.count < parsedObjectives.count {
            return "There are fewer questions than objectives. The saved test will identify objectives without a dedicated question."
        }
        if usesTimeLimit, timeLimitMinutes < parsedQuestions.count * 2 {
            return "The time limit allows under two minutes per question and may restrict broader answers."
        }
        return nil
    }

    private func coverageBinding(for dimension: TestCoverageDimension) -> Binding<Bool> {
        Binding(
            get: { effectiveCoverage.contains(dimension) },
            set: { selected in
                if selected { customCoverage.insert(dimension) }
                else { customCoverage.remove(dimension) }
            }
        )
    }

    private func create() async {
        guard let store = model.store else { return }
        let objectiveValues = parsedObjectives
        let questionValues = parsedQuestions.enumerated().map { index, item in
            ManualTestQuestion(
                objectiveIds: [objectiveValues[index % objectiveValues.count].id],
                prompt: item.0,
                correctAnswer: item.1
            )
        }
        do {
            _ = try await store.createPracticeTest(
                topicId: topicId,
                title: title.trimmed,
                mode: mode,
                objectives: objectiveValues,
                questions: questionValues,
                includeConnectedKnowledge: includeConnectedKnowledge,
                timeLimitMinutes: usesTimeLimit ? timeLimitMinutes : nil
            )
            model.noteLocalMutation()
            onCreated()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

private extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }
private extension FlashcardKind { var displayName: String { rawValue.replacingOccurrences(of: "_", with: " ").capitalized } }
private extension TestMode {
    var studyDisplayName: String {
        switch self {
        case .comprehensive: "Comprehensive"
        case .quickCheck: "Quick Check"
        case .custom: "Custom"
        }
    }

    var studyExplanation: String {
        switch self {
        case .comprehensive: "Plan broad coverage and record every objective that is not assessed."
        case .quickCheck: "Use a short check of concepts, method selection, and verification."
        case .custom: "Choose the exact coverage dimensions for this test."
        }
    }
}
private extension TestCoverageDimension {
    var studyDisplayName: String { rawValue.replacingOccurrences(of: "_", with: " ").capitalized }
}
