import EpistoriaCore
import SwiftUI

struct StudyView: View {
    private enum StudySection: String, CaseIterable, Identifiable {
        case next = "Study Next"
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
    @State private var goals: [IdentifiedPayload<StudyGoalPayload>] = []
    @State private var unresolved: [IdentifiedPayload<UnresolvedQuestionPayload>] = []
    @State private var recommendations: [IdentifiedPayload<StudyRecommendationPayload>] = []
    @State private var recommendationResponses: [IdentifiedPayload<RecommendationResponsePayload>] = []
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
                    case .next: studyNextContent
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
            .alert("Study error", isPresented: .constant(errorMessage != nil)) {
                Button("Try again") { Task { await load() } }
                Button("Dismiss", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    @ViewBuilder private var studyNextContent: some View {
        Section("Recommended now") {
            if let recommendation = currentRecommendation {
                NavigationLink {
                    TopicDashboardView(model: model, topicId: recommendation.topicId)
                } label: {
                    StudyRow(
                        title: recommendation.title,
                        detail: recommendation.explanation,
                        symbol: recommendation.symbol
                    )
                }
                Menu("Recommendation actions", systemImage: "ellipsis.circle") {
                    Button("Pin", systemImage: "pin") { Task { await respond(.pinned) } }
                    Button("Snooze one day", systemImage: "clock") { Task { await respond(.snoozed) } }
                    Button("Dismiss", systemImage: "xmark") { Task { await respond(.dismissed) } }
                    Button("Not relevant", systemImage: "hand.thumbsdown") { Task { await respond(.irrelevant) } }
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
                title: stored.payload.title
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
            let value = try await (a, b, c, d, e, f, g, h, i, j, k)
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
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func respond(_ action: RecommendationAction) async {
        guard let store = model.store, let recommendation = currentRecommendation else { return }
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
            title: recommendation.title
        )
    }

    private func recommendationKey(topicId: UUID, kind: RecommendationKind, title: String) -> String {
        "\(topicId.uuidString):\(kind.rawValue):\(title)"
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
    @State private var objectives = ""
    @State private var questions = ""
    @State private var includeConnectedKnowledge = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Test title", text: $title)
                Section("Objectives") {
                    TextEditor(text: $objectives).frame(minHeight: 100)
                    Text("Enter one objective per line. Comprehensive tests report any objective without a question.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Questions") {
                    TextEditor(text: $questions).frame(minHeight: 140)
                    Text("Enter one question per line as: question | correct answer. Questions are assigned across the objectives in order.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Include connected knowledge", isOn: $includeConnectedKnowledge)
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle("New test")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await create() } }
                        .disabled(parsedObjectives.isEmpty || parsedQuestions.isEmpty)
                }
            }
        }
    }

    private var parsedObjectives: [TestObjective] {
        objectives.split(whereSeparator: \.isNewline).map(String.init).map(\.trimmed).filter { !$0.isEmpty }.map {
            TestObjective(title: $0, dimensions: TestCoverageDimension.allCases)
        }
    }

    private var parsedQuestions: [(String, String)] {
        questions.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[0].trimmed.isEmpty, !parts[1].trimmed.isEmpty else { return nil }
            return (parts[0].trimmed, parts[1].trimmed)
        }
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
                objectives: objectiveValues,
                questions: questionValues,
                includeConnectedKnowledge: includeConnectedKnowledge
            )
            model.noteLocalMutation()
            onCreated()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

private extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }
private extension FlashcardKind { var displayName: String { rawValue.replacingOccurrences(of: "_", with: " ").capitalized } }
