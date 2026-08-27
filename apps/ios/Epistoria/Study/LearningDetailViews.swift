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
                if let blueprint {
                    LabeledContent("Mode", value: blueprint.payload.mode.detailDisplayName)
                }
                LabeledContent(
                    "Questions",
                    value: blueprint.map { "\(questions.count) of \($0.payload.requestedQuestionCount) planned" } ?? "\(questions.count)"
                )
                LabeledContent("Objectives", value: "\(blueprint?.payload.objectives.count ?? 0)")
                if let minutes = blueprint?.payload.timeLimitMinutes {
                    LabeledContent("Time limit", value: "\(minutes) min")
                } else {
                    LabeledContent("Time limit", value: "None")
                }
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
            if let blueprint {
                Section("Objectives") {
                    ForEach(blueprint.payload.objectives) { objective in
                        HStack(alignment: .top) {
                            Image(systemName: blueprint.payload.uncoveredObjectives.contains(objective.id)
                                  ? "exclamationmark.circle" : "checkmark.circle")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(objective.title)
                                Text(objective.dimensions.map(\.detailDisplayName).joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !(blueprint.payload.coverageNotes ?? []).isEmpty {
                    Section("Coverage report") {
                        ForEach(blueprint.payload.coverageNotes ?? [], id: \.self) { note in
                            Label(note, systemImage: "info.circle")
                                .foregroundStyle(.secondary)
                        }
                    }
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

private extension TestMode {
    var detailDisplayName: String {
        switch self {
        case .comprehensive: "Comprehensive"
        case .quickCheck: "Quick Check"
        case .custom: "Custom"
        }
    }
}

private extension TestCoverageDimension {
    var detailDisplayName: String { rawValue.replacingOccurrences(of: "_", with: " ").capitalized }
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
    @State private var feedbackContext: FeedbackReviewContext?
    @State private var questionScoreContext: QuestionScoreOverrideContext?
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
        .sheet(item: $feedbackContext) { context in
            FreeResponseFeedbackReviewView(
                model: model,
                attemptId: attemptId,
                responseId: context.responseId,
                question: context.question
            ) {
                await load()
            }
        }
        .sheet(item: $questionScoreContext) { context in
            QuestionScoreOverrideView(response: context.response.payload) { score, reason in
                Task {
                    await applyQuestionScoreOverride(
                        responseId: context.response.id,
                        score: score,
                        reason: reason
                    )
                }
            }
        }
        .alert("Attempt error", isPresented: .constant(errorMessage != nil)) {
            Button("Dismiss", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    @ViewBuilder private func reviewFeedback(_ question: FrozenQuestionSnapshot) -> some View {
        let identified = responses[question.questionId]
        let response = identified?.payload
        VStack(alignment: .leading, spacing: 8) {
            Label(response?.isCorrect == true ? "Correct" : "Review needed", systemImage: response?.isCorrect == true ? "checkmark.circle" : "xmark.circle")
                .font(.headline)
            Text("Expected answer: \(question.correctAnswer)")
            Text(question.rubric).font(.caption).foregroundStyle(.secondary)
            if let feedback = response?.feedback {
                Divider()
                Label("Accepted cited feedback", systemImage: "checkmark.seal")
                    .font(.headline)
                if let proposed = response?.score {
                    LabeledContent(
                        response?.scoreOverride == nil ? "Proposed question score" : "AI proposal",
                        value: proposed.formatted(.percent.precision(.fractionLength(0)))
                    )
                }
                if let scoreOverride = response?.scoreOverride {
                    LabeledContent(
                        "Owner override",
                        value: scoreOverride.formatted(.percent.precision(.fractionLength(0)))
                    )
                    if let reason = response?.scoreOverrideReason {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(feedback)
                if let strengths = response?.feedbackStrengths, !strengths.isEmpty {
                    Text("Strengths").font(.subheadline.weight(.semibold))
                    ForEach(strengths, id: \.self) { Text("• \($0)") }
                }
                if let improvements = response?.feedbackImprovements, !improvements.isEmpty {
                    Text("Improvements").font(.subheadline.weight(.semibold))
                    ForEach(improvements, id: \.self) { Text("• \($0)") }
                }
                if let uncertainty = response?.feedbackUncertainty {
                    Label(uncertainty, systemImage: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Label(
                    "\(response?.feedbackCitedSourceIds?.count ?? 0) cited record\((response?.feedbackCitedSourceIds?.count ?? 0) == 1 ? "" : "s")",
                    systemImage: "link"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let identified, !identified.payload.isSkipped,
               !identified.payload.response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack {
                    Button(
                        identified.payload.feedback == nil ? "Request cited feedback" : "Review or request feedback",
                        systemImage: "sparkles"
                    ) {
                        feedbackContext = FeedbackReviewContext(
                            responseId: identified.id,
                            question: question
                        )
                    }
                    Button("Question score", systemImage: "slider.horizontal.3") {
                        questionScoreContext = QuestionScoreOverrideContext(response: identified)
                    }
                }
                Text("AI feedback is a proposal. It cannot replace your saved answer, the original calculated result, or your score override.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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

    private func applyQuestionScoreOverride(
        responseId: UUID,
        score: Double?,
        reason: String?
    ) async {
        guard let store = model.store else { return }
        do {
            try await store.setTestResponseScoreOverride(
                id: responseId,
                score: score,
                reason: reason
            )
            model.noteLocalMutation()
            questionScoreContext = nil
            await load()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct FeedbackReviewContext: Identifiable {
    let responseId: UUID
    let question: FrozenQuestionSnapshot
    var id: UUID { responseId }
}

private struct QuestionScoreOverrideContext: Identifiable {
    let response: IdentifiedPayload<TestResponsePayload>
    var id: UUID { response.id }
}

private struct FreeResponseFeedbackReviewView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let attemptId: UUID
    let responseId: UUID
    let question: FrozenQuestionSnapshot
    let onChanged: () async -> Void

    @State private var prepared: PreparedFreeResponseFeedbackRequest?
    @State private var disclosure: DirectProviderDisclosure?
    @State private var artifact: IdentifiedPayload<FreeResponseFeedbackArtifact>?
    @State private var feedback = ""
    @State private var strengths = ""
    @State private var improvements = ""
    @State private var proposedScore = 0.0
    @State private var uncertainty = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Saved response") {
                    Text(question.prompt).font(.headline)
                    LabeledContent("Question type", value: question.kind.feedbackDisplayName)
                    Text("The submitted answer stays unchanged throughout this review.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if artifact == nil, prepared == nil {
                    Section("Cited feedback") {
                        Text("Prepare a request to see exactly what will leave this iPad before paid processing is allowed.")
                        Button("Review what leaves this iPad", systemImage: "doc.text.magnifyingglass") {
                            Task { await prepare() }
                        }
                        .disabled(isWorking)
                    }
                }

                if let prepared {
                    Section("Review before sending") {
                        LabeledContent("Evidence records", value: prepared.evidenceCount.formatted())
                        LabeledContent("Approximate tokens", value: prepared.approximateTokens.formatted())
                        if let disclosure {
                            LabeledContent("Provider", value: disclosure.provider)
                            LabeledContent("Model", value: disclosure.model)
                            LabeledContent("Destination", value: disclosure.destination)
                            LabeledContent(
                                "Maximum estimated cost",
                                value: disclosure.maximumEstimatedCostUsd.map {
                                    $0.formatted(.currency(code: "USD"))
                                } ?? "Not available"
                            )
                        }
                        DisclosureGroup("Exact data included") {
                            Text("The frozen question, grading guide, reference answer, your submitted response, confidence, and the readable Evidence linked to this question.")
                            ForEach(prepared.request.evidence, id: \.sourceId) { item in
                                LabeledContent(item.title, value: item.sourceKind.feedbackDisplayName)
                            }
                        }
                        Label("Paid provider processing requires this one-time approval", systemImage: "hand.raised")
                            .font(.subheadline)
                        Button("Approve and send", systemImage: "arrow.up.circle") {
                            Task { await submit() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(EpistoriaDesign.ink)
                        .disabled(isWorking || disclosure == nil)
                    }
                }

                if let artifact {
                    Section("Review generated feedback") {
                        TextField("Feedback", text: $feedback, axis: .vertical)
                            .disabled(artifact.payload.reviewState == .accepted)
                        TextField("Strengths, one per line", text: $strengths, axis: .vertical)
                            .disabled(artifact.payload.reviewState == .accepted)
                        TextField("Improvements, one per line", text: $improvements, axis: .vertical)
                            .disabled(artifact.payload.reviewState == .accepted)
                        LabeledContent(
                            "Proposed score",
                            value: proposedScore.formatted(.percent.precision(.fractionLength(0)))
                        )
                        Slider(value: $proposedScore, in: 0...1, step: 0.01)
                            .disabled(artifact.payload.reviewState == .accepted)
                        TextField("Uncertainty", text: $uncertainty, axis: .vertical)
                            .disabled(artifact.payload.reviewState == .accepted)
                        Label(
                            "\(reviewedResponse.citedSourceIds.count) citation\(reviewedResponse.citedSourceIds.count == 1 ? "" : "s")",
                            systemImage: "link"
                        )
                        .foregroundStyle(.secondary)

                        if artifact.payload.reviewState == .accepted {
                            Label("Accepted and stored with this response", systemImage: "checkmark.circle.fill")
                            Button("Prepare another review", systemImage: "arrow.clockwise") {
                                startAnotherReview()
                            }
                        } else if artifact.payload.reviewState == .rejected {
                            Label("Rejected. The generated artifact remains encrypted for provenance.", systemImage: "xmark.circle")
                            Button("Prepare another review", systemImage: "arrow.clockwise") {
                                startAnotherReview()
                            }
                        } else {
                            Button("Save edits locally", systemImage: "square.and.arrow.down") {
                                Task { await saveReview() }
                            }
                            Button("Accept feedback", systemImage: "checkmark.circle") {
                                Task { await accept() }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(EpistoriaDesign.ink)
                            Button("Reject", systemImage: "xmark.circle", role: .destructive) {
                                Task { await reject() }
                            }
                        }
                        Text("Acceptance copies the reviewed proposal to the durable response record. It does not overwrite your answer or the original calculated score.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Cited feedback")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await loadArtifact() } }
                }
            }
            .task { await loadArtifact() }
        }
    }

    private var reviewedResponse: FreeResponseFeedbackResponse {
        FreeResponseFeedbackResponse(
            feedback: feedback,
            strengths: strengths.nonEmptyLines,
            improvements: improvements.nonEmptyLines,
            proposedScore: proposedScore,
            uncertainty: uncertainty,
            citedSourceIds: artifact?.payload.response.citedSourceIds ?? []
        )
    }

    private func prepare() async {
        guard let aiJobs = model.aiJobs else {
            errorMessage = "Unlock the notebook before preparing feedback."
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let value = try await aiJobs.prepareFreeResponseFeedback(
                attemptId: attemptId,
                responseId: responseId
            )
            disclosure = try model.directProviderDisclosure(
                approximateInputTokens: value.approximateTokens,
                maximumOutputTokens: 4_096
            )
            prepared = value
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func submit() async {
        guard let prepared, let disclosure else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await model.generateFreeResponseFeedbackDirect(
                prepared,
                approvedRoute: disclosure.route
            )
            model.noteLocalMutation()
            self.prepared = nil
            self.disclosure = nil
            await loadArtifact()
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func loadArtifact() async {
        do {
            artifact = try await model.aiJobs?.latestFreeResponseFeedback(
                attemptId: attemptId,
                responseId: responseId
            )
            configureReview()
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func configureReview() {
        guard let artifact else { return }
        let response = artifact.payload.editedResponse ?? artifact.payload.response
        feedback = response.feedback
        strengths = response.strengths.joined(separator: "\n")
        improvements = response.improvements.joined(separator: "\n")
        proposedScore = response.proposedScore
        uncertainty = response.uncertainty
    }

    private func saveReview() async {
        guard let store = model.store, let artifact else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await store.saveFreeResponseFeedbackDraftReview(
                id: artifact.id,
                response: reviewedResponse
            )
            model.noteLocalMutation()
            errorMessage = nil
            await loadArtifact()
        } catch { errorMessage = error.localizedDescription }
    }

    private func accept() async {
        guard let store = model.store, let artifact else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await store.saveFreeResponseFeedbackDraftReview(
                id: artifact.id,
                response: reviewedResponse
            )
            try await store.reviewFreeResponseFeedbackArtifact(id: artifact.id, state: .accepted)
            model.noteLocalMutation()
            errorMessage = nil
            await loadArtifact()
            await onChanged()
        } catch { errorMessage = error.localizedDescription }
    }

    private func reject() async {
        guard let store = model.store, let artifact else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await store.reviewFreeResponseFeedbackArtifact(id: artifact.id, state: .rejected)
            model.noteLocalMutation()
            errorMessage = nil
            await loadArtifact()
        } catch { errorMessage = error.localizedDescription }
    }

    private func startAnotherReview() {
        artifact = nil
        prepared = nil
        disclosure = nil
        feedback = ""
        strengths = ""
        improvements = ""
        proposedScore = 0
        uncertainty = ""
        Task { await prepare() }
    }
}

private struct QuestionScoreOverrideView: View {
    @Environment(\.dismiss) private var dismiss
    let response: TestResponsePayload
    let onSave: (Double?, String?) -> Void
    @State private var percent: Double
    @State private var reason: String

    init(response: TestResponsePayload, onSave: @escaping (Double?, String?) -> Void) {
        self.response = response
        self.onSave = onSave
        let initial = response.scoreOverride ?? response.score ?? (response.isCorrect == true ? 1 : 0)
        _percent = State(initialValue: initial * 100)
        _reason = State(initialValue: response.scoreOverrideReason ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Question score") {
                    if let proposal = response.score {
                        LabeledContent(
                            "AI proposal",
                            value: proposal.formatted(.percent.precision(.fractionLength(0)))
                        )
                    }
                    LabeledContent("Override", value: "\(Int(percent.rounded()))%")
                    Slider(value: $percent, in: 0...100, step: 1)
                    TextField("Reason for correction", text: $reason, axis: .vertical)
                    Text("This stores an owner override. The submitted answer, calculated result, and AI proposal remain in history.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if response.scoreOverride != nil {
                        Button("Clear override", role: .destructive) {
                            onSave(nil, nil)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Question score")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(
                            percent / 100,
                            reason.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                        dismiss()
                    }
                    .disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
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
    var nonEmptyLines: [String] {
        components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private extension TestQuestionKind {
    var feedbackDisplayName: String {
        rawValue.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

private extension FeedbackEvidenceKind {
    var feedbackDisplayName: String {
        rawValue.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

private extension FlashcardRating {
    var label: String {
        switch self { case .again: "Again"; case .hard: "Hard"; case .good: "Good"; case .easy: "Easy" }
    }
}

private extension TestAttemptState { var label: String { rawValue.replacingOccurrences(of: "_", with: " ").capitalized } }
