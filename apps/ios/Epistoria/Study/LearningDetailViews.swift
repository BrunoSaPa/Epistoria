import EpistoriaCore
import SwiftUI

struct FlashcardReviewView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let cardId: UUID
    @State private var card: IdentifiedPayload<FlashcardPayload>?
    @State private var revision: IdentifiedPayload<FlashcardRevisionPayload>?
    @State private var latestReview: IdentifiedPayload<FlashcardReviewPayload>?
    @State private var showsAnswer = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Text(showsAnswer ? "Answer" : "Prompt")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(showsAnswer ? (revision?.payload.answer ?? "") : (revision?.payload.prompt ?? "Loading…"))
                .font(.title2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 680)
            Spacer()
            if showsAnswer {
                HStack {
                    ForEach(FlashcardRating.allCases, id: \.self) { rating in
                        Button(rating.label) { Task { await review(rating) } }
                            .buttonStyle(.bordered)
                    }
                }
            } else {
                Button("Show answer") { showsAnswer = true }
                    .buttonStyle(.borderedProminent)
                    .tint(EpistoriaDesign.ink)
            }
        }
        .padding(40)
        .navigationTitle("Review card")
        .epistoriaPageBackground()
        .task { await load() }
        .alert("Flashcard error", isPresented: .constant(errorMessage != nil)) {
            Button("Dismiss", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func load() async {
        guard let store = model.store else { return }
        do {
            let loadedCard = try await store.payload(FlashcardPayload.self, id: cardId)
            async let loadedRevision = store.payload(FlashcardRevisionPayload.self, id: loadedCard.payload.currentRevisionId)
            async let loadedReviews = store.list(FlashcardReviewPayload.self, parentId: cardId)
            card = loadedCard
            revision = try await loadedRevision
            latestReview = try await loadedReviews.max { $0.payload.reviewedAt < $1.payload.reviewedAt }
        } catch { errorMessage = error.localizedDescription }
    }

    private func review(_ rating: FlashcardRating) async {
        guard let store = model.store else { return }
        do {
            let previous = latestReview?.payload.resultingState ?? FlashcardScheduleState()
            _ = try await store.reviewFlashcard(cardId: cardId, rating: rating, previousState: previous)
            model.noteLocalMutation()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct PracticeTestDetailView: View {
    @Bindable var model: AppModel
    let testId: UUID
    @State private var test: IdentifiedPayload<PracticeTestPayload>?
    @State private var blueprint: IdentifiedPayload<TestBlueprintPayload>?
    @State private var questions: [IdentifiedPayload<TestQuestionPayload>] = []
    @State private var attempts: [IdentifiedPayload<TestAttemptPayload>] = []
    @State private var openedAttemptId: UUID?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                LabeledContent("Questions", value: "\(questions.count)")
                LabeledContent("Objectives", value: "\(blueprint?.payload.objectives.count ?? 0)")
                if let gaps = blueprint?.payload.uncoveredObjectives.count, gaps > 0 {
                    LabeledContent("Coverage gaps", value: "\(gaps)")
                } else {
                    LabeledContent("Coverage", value: "Complete")
                }
                if attempts.allSatisfy({ $0.payload.state != .inProgress }),
                   let previous = attempts.first(where: { $0.payload.state == .submitted || $0.payload.state == .scored }) {
                    Button("Retake full test") { Task { await beginRetake(previous.id, missedOnly: false) } }
                    Button("Retake missed objectives") { Task { await beginRetake(previous.id, missedOnly: true) } }
                }
            }
            Section {
                if let current = attempts.first(where: { $0.payload.state == .inProgress }) {
                    Button("Continue attempt") { openedAttemptId = current.id }
                } else {
                    Button("Start attempt") { Task { await beginAttempt() } }
                }
            }
            Section("Attempt history") {
                if attempts.isEmpty { Text("No attempts yet.").foregroundStyle(.secondary) }
                ForEach(attempts, id: \.id) { attempt in
                    NavigationLink {
                        TestAttemptView(model: model, attemptId: attempt.id)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(attempt.payload.startedAt.formatted(date: .abbreviated, time: .shortened))
                            Text(attempt.payload.score.map { $0.formatted(.percent) } ?? attempt.payload.state.label)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(test?.payload.title ?? "Practice test")
        .epistoriaPageBackground()
        .task { await load() }
        .navigationDestination(item: $openedAttemptId) { id in
            TestAttemptView(model: model, attemptId: id)
        }
        .alert("Test error", isPresented: .constant(errorMessage != nil)) {
            Button("Dismiss", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func load() async {
        guard let store = model.store else { return }
        do {
            let loaded = try await store.payload(PracticeTestPayload.self, id: testId)
            async let loadedBlueprint = store.payload(TestBlueprintPayload.self, id: loaded.payload.blueprintId)
            async let loadedQuestions = store.list(TestQuestionPayload.self, parentId: testId)
            async let loadedAttempts = store.list(TestAttemptPayload.self, parentId: testId)
            test = loaded
            blueprint = try await loadedBlueprint
            questions = try await loadedQuestions.sorted { $0.payload.order < $1.payload.order }
            attempts = try await loadedAttempts.sorted { $0.payload.startedAt > $1.payload.startedAt }
        } catch { errorMessage = error.localizedDescription }
    }

    private func beginAttempt() async {
        guard let store = model.store else { return }
        do {
            openedAttemptId = try await store.beginTestAttempt(testId: testId)
            model.noteLocalMutation()
            await load()
        } catch { errorMessage = error.localizedDescription }
    }

    private func beginRetake(_ previousAttemptId: UUID, missedOnly: Bool) async {
        guard let store = model.store else { return }
        do {
            openedAttemptId = try await store.beginTestAttempt(
                testId: testId,
                retakeOfAttemptId: previousAttemptId,
                missedObjectivesOnly: missedOnly
            )
            model.noteLocalMutation()
            await load()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct TestAttemptView: View {
    private enum ReviewFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case incorrect = "Incorrect"
        case skipped = "Skipped"
        case lowConfidence = "Low Confidence"
        var id: Self { self }
    }

    @Bindable var model: AppModel
    let attemptId: UUID
    @State private var attempt: IdentifiedPayload<TestAttemptPayload>?
    @State private var responses: [UUID: IdentifiedPayload<TestResponsePayload>] = [:]
    @State private var questionIndex = 0
    @State private var answer = ""
    @State private var confidence = 3
    @State private var filter = ReviewFilter.all
    @State private var saveTask: Task<Void, Never>?
    @State private var saveMessage = "Saved locally"
    @State private var showScoreOverride = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let attempt, !visibleQuestions(attempt.payload).isEmpty {
                let visible = visibleQuestions(attempt.payload)
                let question = visible[min(questionIndex, visible.count - 1)]
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if attempt.payload.state != .inProgress {
                            Picker("Review filter", selection: $filter) {
                                ForEach(ReviewFilter.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)
                        }
                        Text("Question \(questionIndex + 1) of \(visible.count)")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(question.prompt).font(.title2.weight(.semibold))
                        TextEditor(text: $answer)
                            .frame(minHeight: 180)
                            .padding(8)
                            .overlay { RoundedRectangle(cornerRadius: 8).stroke(EpistoriaDesign.border) }
                            .disabled(attempt.payload.state != .inProgress)
                        Picker("Confidence", selection: $confidence) {
                            ForEach(1...5, id: \.self) { Text("\($0)").tag($0) }
                        }
                        .disabled(attempt.payload.state != .inProgress)
                        if attempt.payload.state != .inProgress {
                            reviewFeedback(question)
                            Button("Override score") { showScoreOverride = true }
                        }
                        HStack {
                            Button("Previous") { move(by: -1, in: visible) }.disabled(questionIndex == 0)
                            Spacer()
                            Text(saveMessage).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if questionIndex < visible.count - 1 {
                                Button("Next") { move(by: 1, in: visible) }
                            } else if attempt.payload.state == .inProgress {
                                Button("Submit test") { Task { await submit(attempt) } }
                                    .buttonStyle(.borderedProminent).tint(EpistoriaDesign.ink)
                            }
                        }
                    }
                    .padding(EpistoriaDesign.Spacing.page)
                    .frame(maxWidth: EpistoriaDesign.Layout.readingWidth)
                    .frame(maxWidth: .infinity)
                }
            } else {
                ProgressView("Opening attempt…")
            }
        }
        .navigationTitle("Test attempt")
        .epistoriaPageBackground()
        .task { await load() }
        .onChange(of: answer) { _, _ in scheduleSave() }
        .onChange(of: confidence) { _, _ in scheduleSave() }
        .onChange(of: filter) { _, _ in questionIndex = 0; loadCurrentAnswer() }
        .onDisappear { saveTask?.cancel(); Task { await persistCurrent() } }
        .sheet(isPresented: $showScoreOverride) {
            if let attempt {
                ScoreOverrideView(attempt: attempt.payload) { score, reason in
                    Task { await applyScoreOverride(score: score, reason: reason) }
                }
            }
        }
        .alert("Attempt error", isPresented: .constant(errorMessage != nil)) {
            Button("Dismiss", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    @ViewBuilder private func reviewFeedback(_ question: FrozenQuestionSnapshot) -> some View {
        let response = responses[question.questionId]?.payload
        VStack(alignment: .leading, spacing: 8) {
            Label(response?.isCorrect == true ? "Correct" : "Review needed", systemImage: response?.isCorrect == true ? "checkmark.circle" : "xmark.circle")
                .font(.headline)
            Text("Expected answer: \(question.correctAnswer)")
            Text(question.rubric).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func visibleQuestions(_ attempt: TestAttemptPayload) -> [FrozenQuestionSnapshot] {
        switch filter {
        case .all: return attempt.frozenQuestions
        case .incorrect: return attempt.frozenQuestions.filter { responses[$0.questionId]?.payload.isCorrect == false }
        case .skipped: return attempt.frozenQuestions.filter { responses[$0.questionId]?.payload.isSkipped == true }
        case .lowConfidence: return attempt.frozenQuestions.filter { (responses[$0.questionId]?.payload.confidence ?? 5) <= 2 }
        }
    }

    private func load() async {
        guard let store = model.store else { return }
        do {
            attempt = try await store.payload(TestAttemptPayload.self, id: attemptId)
            let loaded = try await store.list(TestResponsePayload.self, parentId: attemptId)
            responses = Dictionary(uniqueKeysWithValues: loaded.map { ($0.payload.questionId, $0) })
            loadCurrentAnswer()
        } catch { errorMessage = error.localizedDescription }
    }

    private func loadCurrentAnswer() {
        guard let attempt, let question = visibleQuestions(attempt.payload).element(at: questionIndex) else {
            answer = ""; confidence = 3; return
        }
        let response = responses[question.questionId]?.payload
        answer = response?.response ?? ""
        confidence = response?.confidence ?? 3
    }

    private func scheduleSave() {
        guard attempt?.payload.state == .inProgress else { return }
        saveMessage = "Saving…"
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await persistCurrent()
        }
    }

    private func persistCurrent() async {
        guard let store = model.store,
              let attempt,
              attempt.payload.state == .inProgress,
              let question = visibleQuestions(attempt.payload).element(at: questionIndex)
        else { return }
        var response = responses[question.questionId] ?? IdentifiedPayload(
            id: UUID(),
            payload: TestResponsePayload(attemptId: attemptId, questionId: question.questionId),
            revision: 0,
            syncState: .pending
        )
        response.payload.response = answer
        response.payload.confidence = confidence
        response.payload.isSkipped = answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        response.payload.updatedAt = .now
        do {
            _ = try await store.save(id: response.id, payload: response.payload, parentId: attemptId, relationIds: [attemptId, question.questionId])
            responses[question.questionId] = response
            saveMessage = "Saved locally"
            model.noteLocalMutation()
        } catch { errorMessage = error.localizedDescription; saveMessage = "Not saved" }
    }

    private func move(by offset: Int, in questions: [FrozenQuestionSnapshot]) {
        saveTask?.cancel()
        Task {
            await persistCurrent()
            questionIndex = min(max(questionIndex + offset, 0), questions.count - 1)
            loadCurrentAnswer()
        }
    }

    private func submit(_ identified: IdentifiedPayload<TestAttemptPayload>) async {
        await persistCurrent()
        guard let store = model.store else { return }
        var changed = identified
        var correct = 0
        for question in changed.payload.frozenQuestions {
            guard var response = responses[question.questionId] else { continue }
            let actual = response.payload.response.trimmedForScoring
            let expected = question.correctAnswer.trimmedForScoring
            response.payload.isCorrect = !actual.isEmpty && actual == expected
            response.payload.isSkipped = actual.isEmpty
            response.payload.updatedAt = .now
            if response.payload.isCorrect == true { correct += 1 }
            do {
                _ = try await store.save(id: response.id, payload: response.payload, parentId: attemptId, relationIds: [attemptId, question.questionId])
                responses[question.questionId] = response
            } catch { errorMessage = error.localizedDescription; return }
        }
        changed.payload.score = changed.payload.frozenQuestions.isEmpty ? 0 : Double(correct) / Double(changed.payload.frozenQuestions.count)
        changed.payload.state = .scored
        changed.payload.submittedAt = .now
        changed.payload.updatedAt = .now
        do {
            _ = try await store.save(id: changed.id, payload: changed.payload, parentId: changed.payload.testId, relationIds: [changed.payload.testId, changed.payload.topicId, changed.payload.scopeSnapshotId])
            attempt = changed
            filter = .all
            questionIndex = 0
            model.noteLocalMutation()
        } catch { errorMessage = error.localizedDescription }
    }

    private func applyScoreOverride(score: Double, reason: String) async {
        guard let store = model.store, var changed = attempt else { return }
        changed.payload.scoreOverride = min(max(score, 0), 1)
        changed.payload.scoreOverrideReason = reason
        changed.payload.updatedAt = .now
        do {
            _ = try await store.save(
                id: changed.id,
                payload: changed.payload,
                parentId: changed.payload.testId,
                relationIds: [changed.payload.testId, changed.payload.topicId, changed.payload.scopeSnapshotId]
            )
            attempt = changed
            model.noteLocalMutation()
            showScoreOverride = false
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct ScoreOverrideView: View {
    @Environment(\.dismiss) private var dismiss
    let attempt: TestAttemptPayload
    let onSave: (Double, String) -> Void
    @State private var percent: Double
    @State private var reason = ""

    init(attempt: TestAttemptPayload, onSave: @escaping (Double, String) -> Void) {
        self.attempt = attempt
        self.onSave = onSave
        _percent = State(initialValue: (attempt.scoreOverride ?? attempt.score ?? 0) * 100)
        _reason = State(initialValue: attempt.scoreOverrideReason ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("Score", value: "\(Int(percent.rounded()))%")
                Slider(value: $percent, in: 0...100, step: 1)
                TextField("Reason for correction", text: $reason, axis: .vertical)
                Text("The original calculated score remains in history. This stores a separate owner override.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("Score override")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(percent / 100, reason.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                    .disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private extension Collection {
    func element(at index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}

private extension String {
    var trimmedForScoring: String { trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
}

private extension FlashcardRating {
    var label: String {
        switch self { case .again: "Again"; case .hard: "Hard"; case .good: "Good"; case .easy: "Easy" }
    }
}

private extension TestAttemptState { var label: String { rawValue.replacingOccurrences(of: "_", with: " ").capitalized } }
