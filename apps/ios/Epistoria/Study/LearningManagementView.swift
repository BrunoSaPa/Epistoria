import EpistoriaCore
import SwiftUI

enum LearningManagementTarget: Hashable, Identifiable {
    case goal(UUID)
    case question(UUID)

    var id: String {
        switch self {
        case .goal(let id): "goal:\(id.uuidString)"
        case .question(let id): "question:\(id.uuidString)"
        }
    }
}

struct LearningManagementView: View {
    @Bindable var model: AppModel
    let initialTarget: LearningManagementTarget?
    @State private var topics: [IdentifiedPayload<TopicPayload>] = []
    @State private var decks: [IdentifiedPayload<FlashcardDeckPayload>] = []
    @State private var cards: [IdentifiedPayload<FlashcardPayload>] = []
    @State private var revisions: [UUID: IdentifiedPayload<FlashcardRevisionPayload>] = [:]
    @State private var goals: [IdentifiedPayload<StudyGoalPayload>] = []
    @State private var questions: [IdentifiedPayload<UnresolvedQuestionPayload>] = []
    @State private var concepts: [IdentifiedPayload<ConceptPayload>] = []
    @State private var tests: [IdentifiedPayload<PracticeTestPayload>] = []
    @State private var automationGrants: [IdentifiedPayload<AutomationGrantPayload>] = []
    @State private var showNewDeck = false
    @State private var showNewAutomation = false
    @State private var automationMessage: String?
    @State private var openedTarget: LearningManagementTarget?
    @State private var openedInitialTarget = false
    @State private var errorMessage: String?

    init(model: AppModel, initialTarget: LearningManagementTarget? = nil) {
        self.model = model
        self.initialTarget = initialTarget
    }

    var body: some View {
        List {
            Section("Goals") {
                lifecycleEmpty(goals, "No goals")
                ForEach(goals, id: \.id) { goal in
                    NavigationLink {
                        GoalEditorView(model: model, goal: goal) { Task { await load() } }
                    } label: {
                        managementRow(
                            goal.payload.title,
                            detail: "\(topicName(goal.payload.topicId)) · \(goal.payload.state.label)",
                            symbol: "target"
                        )
                    }
                }
            }
            Section("Questions") {
                lifecycleEmpty(questions, "No questions")
                ForEach(questions, id: \.id) { question in
                    NavigationLink {
                        QuestionEditorView(model: model, item: question) { Task { await load() } }
                    } label: {
                        managementRow(
                            question.payload.question,
                            detail: question.payload.resolvedAt == nil ? "Open" : "Resolved",
                            symbol: "questionmark.circle"
                        )
                    }
                }
            }
            Section("Decks") {
                if decks.isEmpty { Text("No decks").foregroundStyle(.secondary) }
                ForEach(decks, id: \.id) { deck in
                    NavigationLink {
                        DeckEditorView(model: model, deck: deck) { Task { await load() } }
                    } label: {
                        managementRow(
                            deck.payload.name,
                            detail: "\(topicName(deck.payload.topicId)) · \(deck.payload.archivedAt == nil ? "Active" : "Archived")",
                            symbol: "rectangle.stack.badge.plus"
                        )
                    }
                }
                Button("New deck", systemImage: "plus") { showNewDeck = true }
            }
            Section("Cards") {
                if cards.isEmpty { Text("No cards").foregroundStyle(.secondary) }
                ForEach(cards, id: \.id) { card in
                    NavigationLink {
                        FlashcardEditorView(
                            model: model,
                            card: card,
                            revision: revisions[card.payload.currentRevisionId],
                            decks: decks
                        ) { Task { await load() } }
                    } label: {
                        managementRow(
                            revisions[card.payload.currentRevisionId]?.payload.prompt ?? "Flashcard",
                            detail: cardState(card.payload),
                            symbol: "rectangle.stack"
                        )
                    }
                }
            }
            Section("Concepts") {
                if concepts.isEmpty { Text("No Concepts").foregroundStyle(.secondary) }
                ForEach(concepts, id: \.id) { concept in
                    NavigationLink {
                        ConceptEditorView(
                            model: model,
                            concept: concept,
                            topics: topics,
                            concepts: concepts
                        ) { Task { await load() } }
                    } label: {
                        managementRow(
                            concept.payload.name,
                            detail: concept.payload.state == .active ? "Active" : "Archived",
                            symbol: "point.3.connected.trianglepath.dotted"
                        )
                    }
                }
            }
            Section("Tests") {
                if tests.isEmpty { Text("No tests").foregroundStyle(.secondary) }
                ForEach(tests, id: \.id) { test in
                    NavigationLink {
                        PracticeTestEditorView(model: model, test: test) { Task { await load() } }
                    } label: {
                        managementRow(
                            test.payload.title,
                            detail: test.payload.state.label,
                            symbol: "checkmark.square"
                        )
                    }
                }
            }
            Section("Proactive automation") {
                Text("Study Next suggestions remain local. Automatic provider work runs only under an active permission listed here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if automationGrants.isEmpty {
                    Text("No automatic processing permissions").foregroundStyle(.secondary)
                }
                ForEach(automationGrants, id: \.id) { grant in
                    NavigationLink {
                        AutomationGrantEditorView(
                            model: model,
                            grant: grant,
                            topics: topics
                        ) { Task { await load() } }
                    } label: {
                        managementRow(
                            grant.payload.jobTypes.map(\.displayName).joined(separator: ", "),
                            detail: "\(grant.payload.topicIds.count) Topic\(grant.payload.topicIds.count == 1 ? "" : "s") · \(grantStatus(grant.payload))",
                            symbol: "bolt.shield"
                        )
                    }
                }
                Button("New permission", systemImage: "plus") { showNewAutomation = true }
                Button("Run due automations", systemImage: "play") {
                    Task { await runDueAutomations() }
                }
                .disabled(automationGrants.allSatisfy { !$0.payload.isActive(at: .now) })
                if let automationMessage {
                    Text(automationMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Manage Learning")
        .epistoriaPageBackground()
        .task {
            await load()
            if !openedInitialTarget {
                openedInitialTarget = true
                openedTarget = initialTarget
            }
        }
        .refreshable { await load() }
        .navigationDestination(item: $openedTarget) { target in
            learningTargetDestination(target)
        }
        .sheet(isPresented: $showNewDeck) {
            NewDeckView(model: model, topics: topics) { Task { await load() } }
        }
        .sheet(isPresented: $showNewAutomation) {
            AutomationGrantEditorView(model: model, grant: nil, topics: topics) {
                showNewAutomation = false
                Task { await load() }
            }
        }
        .alert("Learning error", isPresented: .constant(errorMessage != nil)) {
            Button("Dismiss", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    @ViewBuilder private func lifecycleEmpty<T>(_ values: [T], _ text: String) -> some View {
        if values.isEmpty { Text(text).foregroundStyle(.secondary) }
    }

    private func managementRow(_ title: String, detail: String, symbol: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(2)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        } icon: { Image(systemName: symbol).foregroundStyle(EpistoriaDesign.ink) }
    }

    private func topicName(_ id: UUID) -> String {
        topics.first { $0.id == id }?.payload.name ?? "Topic"
    }

    private func cardState(_ card: FlashcardPayload) -> String {
        if card.archivedAt != nil { return "Archived" }
        if card.suspendedAt != nil { return "Suspended" }
        return topicName(card.topicId)
    }

    private func grantStatus(_ grant: AutomationGrantPayload) -> String {
        if grant.revokedAt != nil { return "Revoked" }
        if grant.expiresAt <= .now { return "Expired" }
        if grant.pausedAt != nil { return "Paused" }
        if (grant.estimatedSpentMinorUnits ?? 0) >= grant.spendingLimitMinorUnits {
            return "Budget reached"
        }
        return "Active"
    }

    @ViewBuilder
    private func learningTargetDestination(_ target: LearningManagementTarget) -> some View {
        switch target {
        case .goal(let id):
            if let goal = goals.first(where: { $0.id == id }) {
                GoalEditorView(model: model, goal: goal) { Task { await load() } }
            } else {
                ContentUnavailableView("Goal unavailable", systemImage: "target")
            }
        case .question(let id):
            if let question = questions.first(where: { $0.id == id }) {
                QuestionEditorView(model: model, item: question) { Task { await load() } }
            } else {
                ContentUnavailableView("Question unavailable", systemImage: "questionmark.circle")
            }
        }
    }

    private func load() async {
        guard let store = model.store else { return }
        do {
            async let a = store.topics()
            async let b = store.list(FlashcardDeckPayload.self)
            async let c = store.list(FlashcardPayload.self)
            async let d = store.list(FlashcardRevisionPayload.self)
            async let e = store.list(StudyGoalPayload.self)
            async let f = store.list(UnresolvedQuestionPayload.self)
            async let g = store.list(ConceptPayload.self)
            async let h = store.list(PracticeTestPayload.self)
            async let i = store.list(AutomationGrantPayload.self)
            let values = try await (a, b, c, d, e, f, g, h, i)
            topics = values.0.filter { !$0.payload.archived }
            decks = values.1.sorted { $0.payload.name < $1.payload.name }
            cards = values.2.sorted { $0.payload.updatedAt > $1.payload.updatedAt }
            revisions = Dictionary(uniqueKeysWithValues: values.3.map { ($0.id, $0) })
            goals = values.4.sorted { $0.payload.updatedAt > $1.payload.updatedAt }
            questions = values.5.sorted { $0.payload.updatedAt > $1.payload.updatedAt }
            concepts = values.6.sorted { $0.payload.name < $1.payload.name }
            tests = values.7.sorted { $0.payload.updatedAt > $1.payload.updatedAt }
            automationGrants = values.8.sorted { $0.payload.updatedAt > $1.payload.updatedAt }
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func runDueAutomations() async {
        guard model.aiJobs != nil else {
            errorMessage = "Unlock the notebook before running automatic work."
            return
        }
        do {
            let outcomes = try await model.runDueAutomationsDirect()
            let queued = outcomes.filter {
                if case .queued = $0 { return true }
                return false
            }.count
            let unchanged = outcomes.filter {
                if case .unchanged = $0 { return true }
                return false
            }.count
            automationMessage = queued > 0
                ? "Generated \(queued) reviewable draft\(queued == 1 ? "" : "s")."
                : unchanged > 0 ? "Nothing generated because the allowed material is unchanged." : "No permission is due."
            model.noteLocalMutation()
            await load()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct GoalEditorView: View {
    @Bindable var model: AppModel
    let goal: IdentifiedPayload<StudyGoalPayload>
    let onSaved: () -> Void
    @State private var title: String
    @State private var details: String
    @State private var hasTargetDate: Bool
    @State private var targetDate: Date
    @State private var priority: Int
    @State private var state: LearningRecordState
    @State private var planEnabled: Bool
    @State private var planStartedAt: Date
    @State private var minutesPerStudyDay: Int
    @State private var studyWeekdays: Set<Int>
    @State private var objectives: [LearningPlanObjective]
    @State private var blueprints: [IdentifiedPayload<TestBlueprintPayload>] = []
    @State private var attempts: [IdentifiedPayload<TestAttemptPayload>] = []
    @State private var responses: [IdentifiedPayload<TestResponsePayload>] = []
    @State private var showNewObjective = false
    @State private var errorMessage: String?

    init(model: AppModel, goal: IdentifiedPayload<StudyGoalPayload>, onSaved: @escaping () -> Void) {
        self.model = model
        self.goal = goal
        self.onSaved = onSaved
        _title = State(initialValue: goal.payload.title)
        _details = State(initialValue: goal.payload.details ?? "")
        _hasTargetDate = State(initialValue: goal.payload.targetDate != nil)
        _targetDate = State(initialValue: goal.payload.targetDate ?? Date.now.addingTimeInterval(7 * 86_400))
        _priority = State(initialValue: goal.payload.priority)
        _state = State(initialValue: goal.payload.state)
        _planEnabled = State(initialValue: goal.payload.learningPlan != nil)
        _planStartedAt = State(initialValue: goal.payload.learningPlan?.startedAt ?? .now)
        _minutesPerStudyDay = State(initialValue: goal.payload.learningPlan?.minutesPerStudyDay ?? 30)
        _studyWeekdays = State(initialValue: Set(goal.payload.learningPlan?.studyWeekdays ?? Array(1...7)))
        _objectives = State(initialValue: goal.payload.learningPlan?.objectives ?? [])
    }

    var body: some View {
        Form {
            Section("Goal") {
                TextField("Goal", text: $title)
                TextField("Details", text: $details, axis: .vertical)
                Toggle("Target date", isOn: $hasTargetDate)
                    .disabled(planEnabled)
                if hasTargetDate { DatePicker("Due", selection: $targetDate, displayedComponents: .date) }
                Picker("Priority", selection: $priority) { ForEach(0...3, id: \.self) { Text("\($0)").tag($0) } }
                Picker("Status", selection: $state) {
                    Text("Active").tag(LearningRecordState.active)
                    Text("Completed").tag(LearningRecordState.completed)
                    Text("Archived").tag(LearningRecordState.archived)
                }
            }

            Section("Learning plan") {
                Toggle("Plan daily work", isOn: $planEnabled)
                    .onChange(of: planEnabled) { _, enabled in
                        if enabled { hasTargetDate = true }
                    }
                if planEnabled {
                    if let projection = draftProjection {
                        learningPlanSummary(projection)
                    }
                    Stepper(
                        "Preferred workload: \(minutesPerStudyDay) min",
                        value: $minutesPerStudyDay,
                        in: 5...720,
                        step: 5
                    )
                    Text("Readiness is calculated on this iPad from your target date, completed objectives, and test history. It is not an AI mastery score.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Use a plan when a goal has a deadline. Simple goals remain available without a schedule.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if planEnabled {
                Section("Study days") {
                    ForEach(1...7, id: \.self) { weekday in
                        Toggle(weekdayName(weekday), isOn: weekdayBinding(weekday))
                    }
                }

                Section("Objective coverage") {
                    if objectives.isEmpty {
                        Text("Add the material this goal must cover. The plan cannot report readiness until it has objectives.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach($objectives) { $objective in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Button {
                                    objective.state = objective.state == .completed ? .remaining : .completed
                                    objective.completedAt = objective.state == .completed ? .now : nil
                                } label: {
                                    Image(systemName: objective.state == .completed ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(objective.state == .completed ? EpistoriaDesign.ink : .secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(objective.state == .completed ? "Mark remaining" : "Mark complete")
                                TextField("Objective", text: $objective.title, axis: .vertical)
                            }
                            Stepper(
                                "Estimated work: \(objective.estimatedMinutes) min",
                                value: $objective.estimatedMinutes,
                                in: 5...1_440,
                                step: 5
                            )
                            .font(.caption)
                            if let evidence = draftProjection?.objectives.first(where: { $0.id == objective.id }),
                               evidence.assessedResponses > 0 {
                                Text(assessmentDetail(evidence))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete { objectives.remove(atOffsets: $0) }

                    Button("Add objective", systemImage: "plus") { showNewObjective = true }
                    Button("Import test objectives", systemImage: "square.and.arrow.down") {
                        importTestObjectives()
                    }
                    .disabled(availableTestObjectives.isEmpty)
                }
            }
            lifecycleError(errorMessage)
        }
        .navigationTitle("Edit Goal")
        .toolbar {
            Button("Save") { Task { await save() } }
                .disabled(!canSave)
        }
        .task { await loadLearningEvidence() }
        .sheet(isPresented: $showNewObjective) {
            NewLearningPlanObjectiveView { objective in
                objectives.append(objective)
                showNewObjective = false
            }
        }
    }

    private var canSave: Bool {
        !title.trimmed.isEmpty
            && (!planEnabled || (hasTargetDate
                && !studyWeekdays.isEmpty
                && objectives.allSatisfy { !$0.title.trimmed.isEmpty }))
    }

    private var draftGoal: StudyGoalPayload {
        var value = goal.payload
        value.targetDate = hasTargetDate ? targetDate : nil
        value.learningPlan = planEnabled ? LearningPlanConfiguration(
            startedAt: planStartedAt,
            minutesPerStudyDay: minutesPerStudyDay,
            studyWeekdays: Array(studyWeekdays),
            objectives: objectives
        ) : nil
        return value
    }

    private var draftProjection: LearningPlanProjection? {
        LearningPlanEngine.project(
            goalId: goal.id,
            goal: draftGoal,
            attempts: attempts,
            responses: responses,
            now: .now
        )
    }

    @ViewBuilder
    private func learningPlanSummary(_ projection: LearningPlanProjection) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(readinessTitle(projection.readiness), systemImage: readinessSymbol(projection.readiness))
                .font(.headline)
            Text("\(projection.completedObjectiveCount) of \(projection.objectiveCount) objectives complete")
            if projection.remainingMinutes > 0 {
                Text("\(projection.remainingMinutes) estimated minutes across \(projection.studyDaysRemaining) remaining study days · \(projection.minutesRequiredPerStudyDay) min per study day")
            }
            if projection.catchUpMinutes > 0 {
                Text("Catch-up estimate: \(projection.catchUpMinutes) min")
            }
            if projection.incorrectResponseCount > 0 || projection.lowConfidenceResponseCount > 0 {
                Text("Recorded evidence: \(projection.incorrectResponseCount) incorrect and \(projection.lowConfidenceResponseCount) low-confidence responses")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private var availableTestObjectives: [TestObjective] {
        let existing = Set(objectives.compactMap(\.sourceObjectiveId))
        return (blueprints.first?.payload.objectives ?? [])
            .filter { !existing.contains($0.id) }
    }

    private func importTestObjectives() {
        objectives.append(contentsOf: availableTestObjectives.map {
            LearningPlanObjective(
                title: $0.title,
                estimatedMinutes: max(30, Int(($0.weight * 60).rounded())),
                sourceObjectiveId: $0.id
            )
        })
    }

    private func weekdayBinding(_ weekday: Int) -> Binding<Bool> {
        Binding(
            get: { studyWeekdays.contains(weekday) },
            set: { selected in
                if selected { studyWeekdays.insert(weekday) } else { studyWeekdays.remove(weekday) }
            }
        )
    }

    private func weekdayName(_ weekday: Int) -> String {
        let names = Calendar.current.weekdaySymbols
        return names.indices.contains(weekday - 1) ? names[weekday - 1] : "Day \(weekday)"
    }

    private func readinessTitle(_ readiness: LearningPlanReadiness) -> String {
        switch readiness {
        case .needsDeadline: "Needs a target date"
        case .needsObjectives: "Needs coverage objectives"
        case .onTrack: "On track"
        case .catchUpNeeded: "Catch-up needed"
        case .atRisk: "At risk"
        case .reviewRecommended: "Review recommended"
        case .ready: "Ready to finish"
        case .overdue: "Target date passed"
        }
    }

    private func readinessSymbol(_ readiness: LearningPlanReadiness) -> String {
        switch readiness {
        case .ready: "checkmark.circle"
        case .onTrack: "calendar.badge.checkmark"
        case .needsDeadline, .needsObjectives: "calendar"
        case .catchUpNeeded, .atRisk, .reviewRecommended, .overdue: "exclamationmark.circle"
        }
    }

    private func assessmentDetail(_ evidence: LearningPlanObjectiveProjection) -> String {
        "Test evidence: \(evidence.correctResponses) correct, \(evidence.incorrectResponses) incorrect, \(evidence.lowConfidenceResponses) low confidence"
    }

    private func loadLearningEvidence() async {
        guard let store = model.store else { return }
        do {
            async let loadedBlueprints = store.list(TestBlueprintPayload.self)
            async let loadedAttempts = store.list(TestAttemptPayload.self)
            async let loadedResponses = store.list(TestResponsePayload.self)
            let values = try await (loadedBlueprints, loadedAttempts, loadedResponses)
            blueprints = values.0
                .filter { $0.payload.topicId == goal.payload.topicId }
                .sorted { $0.payload.updatedAt > $1.payload.updatedAt }
            attempts = values.1.filter { $0.payload.topicId == goal.payload.topicId }
            let attemptIds = Set(attempts.map(\.id))
            responses = values.2.filter { attemptIds.contains($0.payload.attemptId) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() async {
        guard let store = model.store else { return }
        do {
            try await store.updateStudyGoal(
                id: goal.id,
                title: title,
                details: details,
                targetDate: hasTargetDate ? targetDate : nil,
                priority: priority,
                state: state,
                learningPlan: planEnabled ? LearningPlanConfiguration(
                    startedAt: planStartedAt,
                    minutesPerStudyDay: minutesPerStudyDay,
                    studyWeekdays: Array(studyWeekdays),
                    objectives: objectives
                ) : nil
            )
            model.noteLocalMutation(); onSaved()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct NewLearningPlanObjectiveView: View {
    @Environment(\.dismiss) private var dismiss
    let onCreate: (LearningPlanObjective) -> Void
    @State private var title = ""
    @State private var estimatedMinutes = 60

    var body: some View {
        NavigationStack {
            Form {
                TextField("Objective", text: $title, axis: .vertical)
                Stepper(
                    "Estimated work: \(estimatedMinutes) min",
                    value: $estimatedMinutes,
                    in: 5...1_440,
                    step: 5
                )
                Text("Use one objective for each area the goal must cover. Estimates only determine workload; they are not a mastery score.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("New Objective")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onCreate(LearningPlanObjective(
                            title: title.trimmed,
                            estimatedMinutes: estimatedMinutes
                        ))
                        dismiss()
                    }
                    .disabled(title.trimmed.isEmpty)
                }
            }
        }
    }
}

private struct QuestionEditorView: View {
    @Bindable var model: AppModel
    let item: IdentifiedPayload<UnresolvedQuestionPayload>
    let onSaved: () -> Void
    @State private var question: String
    @State private var resolved: Bool
    @State private var answer: String
    @State private var errorMessage: String?

    init(model: AppModel, item: IdentifiedPayload<UnresolvedQuestionPayload>, onSaved: @escaping () -> Void) {
        self.model = model; self.item = item; self.onSaved = onSaved
        _question = State(initialValue: item.payload.question)
        _resolved = State(initialValue: item.payload.resolvedAt != nil)
        _answer = State(initialValue: item.payload.resolvedAnswer ?? "")
    }

    var body: some View {
        Form {
            TextField("Question", text: $question, axis: .vertical)
            Toggle("Resolved", isOn: $resolved)
            if resolved { TextField("Resolution", text: $answer, axis: .vertical) }
            lifecycleError(errorMessage)
        }
        .navigationTitle("Edit Question")
        .toolbar { Button("Save") { Task { await save() } }.disabled(question.trimmed.isEmpty) }
    }

    private func save() async {
        guard let store = model.store else { return }
        do {
            try await store.updateUnresolvedQuestion(
                id: item.id,
                question: question,
                resolvedAnswer: answer,
                resolved: resolved
            )
            model.noteLocalMutation(); onSaved()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct DeckEditorView: View {
    @Bindable var model: AppModel
    let deck: IdentifiedPayload<FlashcardDeckPayload>
    let onSaved: () -> Void
    @State private var name: String
    @State private var archived: Bool
    @State private var errorMessage: String?

    init(model: AppModel, deck: IdentifiedPayload<FlashcardDeckPayload>, onSaved: @escaping () -> Void) {
        self.model = model; self.deck = deck; self.onSaved = onSaved
        _name = State(initialValue: deck.payload.name)
        _archived = State(initialValue: deck.payload.archivedAt != nil)
    }

    var body: some View {
        Form {
            TextField("Deck name", text: $name)
            Toggle("Archived", isOn: $archived)
            Text("Archiving a deck does not archive its cards or erase review history.")
                .font(.caption).foregroundStyle(.secondary)
            lifecycleError(errorMessage)
        }
        .navigationTitle("Edit Deck")
        .toolbar { Button("Save") { Task { await save() } }.disabled(name.trimmed.isEmpty) }
    }

    private func save() async {
        guard let store = model.store else { return }
        do {
            try await store.updateFlashcardDeck(id: deck.id, name: name, archived: archived)
            model.noteLocalMutation(); onSaved()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct NewDeckView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let topics: [IdentifiedPayload<TopicPayload>]
    let onCreated: () -> Void
    @State private var topicId: UUID?
    @State private var name = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Picker("Topic", selection: $topicId) {
                    Text("Choose a Topic").tag(UUID?.none)
                    ForEach(topics, id: \.id) { Text($0.payload.name).tag(Optional($0.id)) }
                }
                TextField("Deck name", text: $name)
                lifecycleError(errorMessage)
            }
            .navigationTitle("New Deck")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await create() } }
                        .disabled(topicId == nil || name.trimmed.isEmpty)
                }
            }
        }
    }

    private func create() async {
        guard let store = model.store, let topicId else { return }
        do {
            _ = try await store.createFlashcardDeck(topicId: topicId, name: name)
            model.noteLocalMutation(); onCreated(); dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct FlashcardEditorView: View {
    @Bindable var model: AppModel
    let card: IdentifiedPayload<FlashcardPayload>
    let revision: IdentifiedPayload<FlashcardRevisionPayload>?
    let decks: [IdentifiedPayload<FlashcardDeckPayload>]
    let onSaved: () -> Void
    @State private var kind: FlashcardKind
    @State private var prompt: String
    @State private var answer: String
    @State private var deckId: UUID?
    @State private var suspended: Bool
    @State private var archived: Bool
    @State private var errorMessage: String?

    init(
        model: AppModel,
        card: IdentifiedPayload<FlashcardPayload>,
        revision: IdentifiedPayload<FlashcardRevisionPayload>?,
        decks: [IdentifiedPayload<FlashcardDeckPayload>],
        onSaved: @escaping () -> Void
    ) {
        self.model = model; self.card = card; self.revision = revision; self.decks = decks; self.onSaved = onSaved
        _kind = State(initialValue: card.payload.kind)
        _prompt = State(initialValue: revision?.payload.prompt ?? "")
        _answer = State(initialValue: revision?.payload.answer ?? "")
        _deckId = State(initialValue: card.payload.deckId)
        _suspended = State(initialValue: card.payload.suspendedAt != nil)
        _archived = State(initialValue: card.payload.archivedAt != nil)
    }

    var body: some View {
        Form {
            Picker("Card type", selection: $kind) {
                ForEach(FlashcardKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Picker("Deck", selection: $deckId) {
                Text("No deck").tag(UUID?.none)
                ForEach(decks.filter { $0.payload.topicId == card.payload.topicId && $0.payload.archivedAt == nil }, id: \.id) {
                    Text($0.payload.name).tag(Optional($0.id))
                }
            }
            TextField("Prompt", text: $prompt, axis: .vertical)
            TextField("Answer", text: $answer, axis: .vertical)
            Toggle("Suspend reviews", isOn: $suspended)
            Toggle("Archived", isOn: $archived)
            Text("Saving content creates a new revision. Earlier reviews remain bound to the revision that was shown.")
                .font(.caption).foregroundStyle(.secondary)
            lifecycleError(errorMessage)
        }
        .navigationTitle("Edit Card")
        .toolbar { Button("Save") { Task { await save() } }.disabled(prompt.trimmed.isEmpty || answer.trimmed.isEmpty) }
    }

    private func save() async {
        guard let store = model.store else { return }
        do {
            _ = try await store.reviseFlashcard(
                id: card.id,
                kind: kind,
                prompt: prompt,
                answer: answer,
                deckId: deckId,
                evidenceIds: revision?.payload.evidenceIds ?? []
            )
            try await store.setFlashcardLifecycle(id: card.id, suspended: suspended, archived: archived)
            model.noteLocalMutation(); onSaved()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct ConceptEditorView: View {
    @Bindable var model: AppModel
    let concept: IdentifiedPayload<ConceptPayload>
    let topics: [IdentifiedPayload<TopicPayload>]
    let concepts: [IdentifiedPayload<ConceptPayload>]
    let onSaved: () -> Void
    @State private var name: String
    @State private var details: String
    @State private var aliases: String
    @State private var selectedTopics: Set<UUID>
    @State private var archived: Bool
    @State private var links: [IdentifiedPayload<ConceptLinkPayload>] = []
    @State private var isCreatingLink = false
    @State private var editingLink: IdentifiedPayload<ConceptLinkPayload>?
    @State private var pendingLinkRemoval: IdentifiedPayload<ConceptLinkPayload>?
    @State private var errorMessage: String?

    init(
        model: AppModel,
        concept: IdentifiedPayload<ConceptPayload>,
        topics: [IdentifiedPayload<TopicPayload>],
        concepts: [IdentifiedPayload<ConceptPayload>],
        onSaved: @escaping () -> Void
    ) {
        self.model = model
        self.concept = concept
        self.topics = topics
        self.concepts = concepts
        self.onSaved = onSaved
        _name = State(initialValue: concept.payload.name)
        _details = State(initialValue: concept.payload.conceptDescription)
        _aliases = State(initialValue: concept.payload.aliases.joined(separator: ", "))
        _selectedTopics = State(initialValue: Set(concept.payload.topicIds))
        _archived = State(initialValue: concept.payload.state == .archived)
    }

    var body: some View {
        Form {
            TextField("Concept name", text: $name)
            TextField("Description", text: $details, axis: .vertical)
            TextField("Aliases, separated by commas", text: $aliases)
            Section("Topics") {
                ForEach(topics, id: \.id) { topic in
                    Toggle(topic.payload.name, isOn: Binding(
                        get: { selectedTopics.contains(topic.id) },
                        set: { selected in
                            if selected { selectedTopics.insert(topic.id) }
                            else { selectedTopics.remove(topic.id) }
                        }
                    ))
                }
            }
            Section("Connections") {
                if links.isEmpty {
                    Text("No Concept connections").foregroundStyle(.secondary)
                }
                ForEach(links, id: \.id) { link in
                    Button {
                        editingLink = link
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(connectionTitle(link.payload))
                                .foregroundStyle(.primary)
                            HStack(spacing: 6) {
                                Text(link.payload.relation.displayName)
                                Text("·")
                                Text(link.payload.provenance == .user ? "Manual" : "Reviewed AI")
                                if !link.payload.evidenceIds.isEmpty {
                                    Text("· \(link.payload.evidenceIds.count) Evidence")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            if let rationale = link.payload.rationale {
                                Text(rationale)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Remove", systemImage: "trash", role: .destructive) {
                            pendingLinkRemoval = link
                        }
                    }
                }
                Button("Add connection", systemImage: "link.badge.plus") {
                    isCreatingLink = true
                }
                .disabled(concepts.filter { $0.id != concept.id && $0.payload.state == .active }.isEmpty)
            }
            Toggle("Archived", isOn: $archived)
            lifecycleError(errorMessage)
        }
        .navigationTitle("Edit Concept")
        .toolbar { Button("Save") { Task { await save() } }.disabled(name.trimmed.isEmpty || selectedTopics.isEmpty) }
        .task { await loadLinks() }
        .sheet(isPresented: $isCreatingLink) {
            ConceptLinkEditorView(
                model: model,
                sourceConceptId: concept.id,
                concepts: concepts,
                link: nil
            ) {
                isCreatingLink = false
                Task { await loadLinks() }
            }
        }
        .sheet(
            isPresented: Binding(
                get: { editingLink != nil },
                set: { if !$0 { editingLink = nil } }
            )
        ) {
            if let editingLink {
                ConceptLinkEditorView(
                    model: model,
                    sourceConceptId: concept.id,
                    concepts: concepts,
                    link: editingLink
                ) {
                    self.editingLink = nil
                    Task { await loadLinks() }
                }
            }
        }
        .confirmationDialog(
            "Remove this Concept connection?",
            isPresented: Binding(
                get: { pendingLinkRemoval != nil },
                set: { if !$0 { pendingLinkRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove connection", role: .destructive) {
                guard let pendingLinkRemoval else { return }
                Task { await removeLink(pendingLinkRemoval.id) }
                self.pendingLinkRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingLinkRemoval = nil }
        } message: {
            Text("The Concepts and their Evidence remain in the notebook.")
        }
    }

    private func save() async {
        guard let store = model.store else { return }
        do {
            try await store.updateConcept(
                id: concept.id,
                name: name,
                description: details,
                aliases: aliases.split(separator: ",").map(String.init),
                topicIds: Array(selectedTopics),
                state: archived ? .archived : .active
            )
            model.noteLocalMutation(); onSaved()
        } catch { errorMessage = error.localizedDescription }
    }

    private func loadLinks() async {
        guard let store = model.store else { return }
        do {
            links = try await store.conceptLinks(conceptId: concept.id)
        } catch { errorMessage = error.localizedDescription }
    }

    private func removeLink(_ id: UUID) async {
        guard let store = model.store else { return }
        do {
            try await store.removeConceptLink(id: id)
            model.noteLocalMutation()
            await loadLinks()
        } catch { errorMessage = error.localizedDescription }
    }

    private func connectionTitle(_ link: ConceptLinkPayload) -> String {
        let isOutgoing = link.sourceConceptId == concept.id
        let otherId = isOutgoing ? link.targetConceptId : link.sourceConceptId
        let otherName = concepts.first { $0.id == otherId }?.payload.name ?? "Concept"
        return isOutgoing ? "\(concept.payload.name) → \(otherName)" : "\(otherName) → \(concept.payload.name)"
    }
}

private struct ConceptLinkEditorView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let sourceConceptId: UUID
    let concepts: [IdentifiedPayload<ConceptPayload>]
    let link: IdentifiedPayload<ConceptLinkPayload>?
    let onSaved: () -> Void

    @State private var targetConceptId: UUID?
    @State private var relation: ConceptLinkKind
    @State private var rationale: String
    @State private var selectedEvidenceIds: Set<UUID>
    @State private var evidence: [IdentifiedPayload<EvidencePayload>] = []
    @State private var isWorking = false
    @State private var errorMessage: String?

    init(
        model: AppModel,
        sourceConceptId: UUID,
        concepts: [IdentifiedPayload<ConceptPayload>],
        link: IdentifiedPayload<ConceptLinkPayload>?,
        onSaved: @escaping () -> Void
    ) {
        self.model = model
        self.sourceConceptId = sourceConceptId
        self.concepts = concepts
        self.link = link
        self.onSaved = onSaved
        let firstTarget = concepts.first { $0.id != sourceConceptId && $0.payload.state == .active }?.id
        _targetConceptId = State(initialValue: link?.payload.targetConceptId ?? firstTarget)
        _relation = State(initialValue: link?.payload.relation ?? .related)
        _rationale = State(initialValue: link?.payload.rationale ?? "")
        _selectedEvidenceIds = State(initialValue: Set(link?.payload.evidenceIds ?? []))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Concepts") {
                    if let link {
                        LabeledContent("From", value: conceptName(link.payload.sourceConceptId))
                        LabeledContent("To", value: conceptName(link.payload.targetConceptId))
                        Text("Endpoints remain fixed so the connection keeps a stable meaning. Create another connection to use different Concepts.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        LabeledContent("From", value: conceptName(sourceConceptId))
                        Picker("To", selection: $targetConceptId) {
                            ForEach(concepts.filter { $0.id != sourceConceptId && $0.payload.state == .active }, id: \.id) {
                                Text($0.payload.name).tag(Optional($0.id))
                            }
                        }
                    }
                    Picker("Relationship", selection: $relation) {
                        ForEach(ConceptLinkKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    TextField("Why are these Concepts connected?", text: $rationale, axis: .vertical)
                }

                Section("Supporting Evidence") {
                    if evidence.isEmpty {
                        Text("No reusable Evidence is available yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(evidence, id: \.id) { item in
                        Toggle(isOn: Binding(
                            get: { selectedEvidenceIds.contains(item.id) },
                            set: { selected in
                                if selected { selectedEvidenceIds.insert(item.id) }
                                else { selectedEvidenceIds.remove(item.id) }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.payload.excerpt).lineLimit(3)
                                Text(item.payload.kind.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("Evidence stays bound to its exact immutable Source Version.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle(link == nil ? "Add Connection" : "Edit Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(isWorking || (link == nil && targetConceptId == nil))
                }
            }
            .task { await loadEvidence() }
        }
    }

    private func conceptName(_ id: UUID) -> String {
        concepts.first { $0.id == id }?.payload.name ?? "Concept"
    }

    private func loadEvidence() async {
        guard let store = model.store else { return }
        do {
            evidence = try await store.list(EvidencePayload.self)
                .sorted { $0.payload.updatedAt > $1.payload.updatedAt }
        } catch { errorMessage = error.localizedDescription }
    }

    private func save() async {
        guard let store = model.store else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            if let link {
                try await store.updateConceptLink(
                    id: link.id,
                    relation: relation,
                    rationale: rationale,
                    evidenceIds: Array(selectedEvidenceIds)
                )
            } else if let targetConceptId {
                _ = try await store.createConceptLink(
                    sourceConceptId: sourceConceptId,
                    targetConceptId: targetConceptId,
                    relation: relation,
                    rationale: rationale,
                    evidenceIds: Array(selectedEvidenceIds)
                )
            }
            model.noteLocalMutation()
            onSaved()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct PracticeTestEditorView: View {
    @Bindable var model: AppModel
    let test: IdentifiedPayload<PracticeTestPayload>
    let onSaved: () -> Void
    @State private var title: String
    @State private var archived: Bool
    @State private var errorMessage: String?

    init(model: AppModel, test: IdentifiedPayload<PracticeTestPayload>, onSaved: @escaping () -> Void) {
        self.model = model; self.test = test; self.onSaved = onSaved
        _title = State(initialValue: test.payload.title)
        _archived = State(initialValue: test.payload.state == .archived)
    }

    var body: some View {
        Form {
            TextField("Test title", text: $title)
            Toggle("Archived", isOn: $archived)
            Text("Attempts and frozen questions remain available after the test is archived.")
                .font(.caption).foregroundStyle(.secondary)
            lifecycleError(errorMessage)
        }
        .navigationTitle("Edit Test")
        .toolbar { Button("Save") { Task { await save() } }.disabled(title.trimmed.isEmpty) }
    }

    private func save() async {
        guard let store = model.store else { return }
        do {
            try await store.updatePracticeTest(id: test.id, title: title, state: archived ? .archived : .ready)
            model.noteLocalMutation(); onSaved()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct AutomationGrantEditorView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let grant: IdentifiedPayload<AutomationGrantPayload>?
    let topics: [IdentifiedPayload<TopicPayload>]
    let onSaved: () -> Void

    @State private var selectedTopics: Set<UUID>
    @State private var selectedJobs: Set<AutomationJobKind>
    @State private var intervalHours: Int
    @State private var expiresAt: Date
    @State private var budgetDollars: Int
    @State private var acknowledged = false
    @State private var showRevokeConfirmation = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    private let availableJobs: [AutomationJobKind] = [
        .topicSynthesis, .flashcardDrafts, .conceptSuggestions, .sourceDiscovery, .weeklyReview,
    ]

    init(
        model: AppModel,
        grant: IdentifiedPayload<AutomationGrantPayload>?,
        topics: [IdentifiedPayload<TopicPayload>],
        onSaved: @escaping () -> Void
    ) {
        self.model = model
        self.grant = grant
        self.topics = topics
        self.onSaved = onSaved
        _selectedTopics = State(initialValue: Set(grant?.payload.topicIds ?? []))
        _selectedJobs = State(initialValue: Set(grant?.payload.jobTypes.filter {
            $0.learningJobType != nil
        } ?? []))
        _intervalHours = State(initialValue: grant?.payload.minimumIntervalHours ?? 168)
        _expiresAt = State(initialValue: grant?.payload.expiresAt ?? .now.addingTimeInterval(30 * 86_400))
        _budgetDollars = State(initialValue: max((grant?.payload.spendingLimitMinorUnits ?? 500) / 100, 1))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Allowed Topics") {
                    ForEach(topics, id: \.id) { topic in
                        Toggle(topic.payload.name, isOn: membershipBinding(topic.id, in: $selectedTopics))
                    }
                }
                Section("Allowed tasks") {
                    ForEach(availableJobs, id: \.self) { job in
                        Toggle(job.displayName, isOn: membershipBinding(job, in: $selectedJobs))
                    }
                    Text("Every result returns as a draft. Nothing is accepted into the notebook automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Limits") {
                    Stepper(
                        "At most once every \(intervalHours) hour\(intervalHours == 1 ? "" : "s") per Topic and task",
                        value: $intervalHours,
                        in: 1...8_760
                    )
                    DatePicker(
                        "Expires",
                        selection: $expiresAt,
                        in: Date.now.addingTimeInterval(3_600)...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    Stepper("Spending limit: $\(budgetDollars) USD", value: $budgetDollars, in: 1...10_000)
                    if let payload = grant?.payload {
                        LabeledContent(
                            "Recorded estimate",
                            value: (Double(payload.estimatedSpentMinorUnits ?? 0) / 100)
                                .formatted(.currency(code: "USD"))
                        )
                        LabeledContent("Generated jobs", value: (payload.queuedJobIds?.count ?? 0).formatted())
                        if let route = payload.providerRoute {
                            LabeledContent("Provider", value: route.displayName)
                            LabeledContent("Model", value: route.textModel)
                        }
                        if let history = payload.lastQueuedAtByScope, !history.isEmpty {
                            DisclosureGroup("Run history") {
                                ForEach(history.keys.sorted(), id: \.self) { key in
                                    LabeledContent(
                                        automationScopeLabel(key),
                                        value: history[key]?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown"
                                    )
                                }
                            }
                        }
                    }
                    Text("This iPad stops new automatic work when the recorded provider estimate reaches this limit. It also enforces the approved provider route, Topic, task, cadence, and expiration fields.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Approval") {
                    Toggle("I approve recurring processing for this exact scope", isOn: $acknowledged)
                    Text("Opening a note or Study does not create this permission. Pause or revoke it here at any time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let payload = grant?.payload {
                    Section("State") {
                        if payload.revokedAt != nil {
                            Label("Revoked", systemImage: "xmark.circle")
                        } else {
                            Button(payload.pausedAt == nil ? "Pause" : "Resume") {
                                Task { await setPaused(payload.pausedAt == nil) }
                            }
                            .disabled(isWorking)
                            Button("Revoke permission", role: .destructive) {
                                showRevokeConfirmation = true
                            }
                            .disabled(isWorking)
                        }
                        Text("Pause and revocation stop new queueing and request cancellation for nonterminal jobs. Completed drafts remain reviewable.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                lifecycleError(errorMessage)
            }
            .navigationTitle(grant == nil ? "New automation" : "Automation permission")
            .toolbar {
                if grant == nil {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(
                            isWorking || !acknowledged || selectedTopics.isEmpty
                                || selectedJobs.isEmpty || expiresAt <= .now
                                || grant?.payload.revokedAt != nil
                        )
                }
            }
            .confirmationDialog(
                "Revoke this permission?",
                isPresented: $showRevokeConfirmation,
                titleVisibility: .visible
            ) {
                Button("Revoke", role: .destructive) { Task { await revoke() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This cannot be undone. Create a new permission if you want automation later.")
            }
        }
    }

    private func membershipBinding<Value: Hashable>(
        _ value: Value,
        in selection: Binding<Set<Value>>
    ) -> Binding<Bool> {
        Binding(
            get: { selection.wrappedValue.contains(value) },
            set: { included in
                if included { selection.wrappedValue.insert(value) }
                else { selection.wrappedValue.remove(value) }
            }
        )
    }

    private func save() async {
        guard let store = model.store else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let providerRoute = try model.directProviderDisclosure(
                approximateInputTokens: 0,
                maximumOutputTokens: 12_000
            ).route
            if let grant {
                try await store.updateAutomationGrant(
                    id: grant.id,
                    topicIds: Array(selectedTopics),
                    jobTypes: Array(selectedJobs),
                    minimumIntervalHours: intervalHours,
                    expiresAt: expiresAt,
                    spendingLimitMinorUnits: budgetDollars * 100,
                    providerRoute: providerRoute
                )
            } else {
                _ = try await store.createAutomationGrant(
                    topicIds: Array(selectedTopics),
                    jobTypes: Array(selectedJobs),
                    minimumIntervalHours: intervalHours,
                    expiresAt: expiresAt,
                    spendingLimitMinorUnits: budgetDollars * 100,
                    providerRoute: providerRoute
                )
            }
            model.noteLocalMutation()
            onSaved()
            if grant == nil { dismiss() }
        } catch { errorMessage = error.localizedDescription }
    }

    private func setPaused(_ paused: Bool) async {
        guard let id = grant?.id, let store = model.store else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            if let aiJobs = model.aiJobs {
                try await aiJobs.setAutomationGrantPaused(id: id, paused: paused)
            } else {
                _ = try await store.setAutomationGrantPaused(id: id, paused: paused)
            }
            model.noteLocalMutation()
            onSaved()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }

    private func revoke() async {
        guard let id = grant?.id, let store = model.store else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            if let aiJobs = model.aiJobs {
                try await aiJobs.revokeAutomationGrant(id: id)
            } else {
                _ = try await store.revokeAutomationGrant(id: id)
            }
            model.noteLocalMutation()
            onSaved()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }

    private func automationScopeLabel(_ key: String) -> String {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let topicId = UUID(uuidString: parts[0]) else { return key }
        let topic = topics.first { $0.id == topicId }?.payload.name ?? "Topic"
        return "\(topic) · \(parts[1].replacingOccurrences(of: "_", with: " ").capitalized)"
    }
}

@ViewBuilder private func lifecycleError(_ message: String?) -> some View {
    if let message { Text(message).foregroundStyle(.red) }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

private extension FlashcardKind {
    var displayName: String { rawValue.replacingOccurrences(of: "_", with: " ").capitalized }
}

private extension LearningRecordState {
    var label: String { rawValue.capitalized }
}

private extension PracticeTestState {
    var label: String { rawValue.capitalized }
}

private extension AutomationJobKind {
    var displayName: String {
        switch self {
        case .topicSynthesis: "Topic synthesis"
        case .flashcardDrafts: "Flashcard drafts"
        case .conceptSuggestions: "Concept suggestions"
        case .sourceDiscovery: "Source discovery"
        case .weeklyReview: "Weekly review"
        default: rawValue.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
