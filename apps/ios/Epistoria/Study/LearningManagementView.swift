import EpistoriaCore
import SwiftUI

struct LearningManagementView: View {
    @Bindable var model: AppModel
    @State private var topics: [IdentifiedPayload<TopicPayload>] = []
    @State private var decks: [IdentifiedPayload<FlashcardDeckPayload>] = []
    @State private var cards: [IdentifiedPayload<FlashcardPayload>] = []
    @State private var revisions: [UUID: IdentifiedPayload<FlashcardRevisionPayload>] = [:]
    @State private var goals: [IdentifiedPayload<StudyGoalPayload>] = []
    @State private var questions: [IdentifiedPayload<UnresolvedQuestionPayload>] = []
    @State private var concepts: [IdentifiedPayload<ConceptPayload>] = []
    @State private var tests: [IdentifiedPayload<PracticeTestPayload>] = []
    @State private var showNewDeck = false
    @State private var errorMessage: String?

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
                        ConceptEditorView(model: model, concept: concept, topics: topics) { Task { await load() } }
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
        }
        .navigationTitle("Manage Learning")
        .epistoriaPageBackground()
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $showNewDeck) {
            NewDeckView(model: model, topics: topics) { Task { await load() } }
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
            let values = try await (a, b, c, d, e, f, g, h)
            topics = values.0.filter { !$0.payload.archived }
            decks = values.1.sorted { $0.payload.name < $1.payload.name }
            cards = values.2.sorted { $0.payload.updatedAt > $1.payload.updatedAt }
            revisions = Dictionary(uniqueKeysWithValues: values.3.map { ($0.id, $0) })
            goals = values.4.sorted { $0.payload.updatedAt > $1.payload.updatedAt }
            questions = values.5.sorted { $0.payload.updatedAt > $1.payload.updatedAt }
            concepts = values.6.sorted { $0.payload.name < $1.payload.name }
            tests = values.7.sorted { $0.payload.updatedAt > $1.payload.updatedAt }
            errorMessage = nil
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
    @State private var errorMessage: String?

    init(model: AppModel, goal: IdentifiedPayload<StudyGoalPayload>, onSaved: @escaping () -> Void) {
        self.model = model
        self.goal = goal
        self.onSaved = onSaved
        _title = State(initialValue: goal.payload.title)
        _details = State(initialValue: goal.payload.details ?? "")
        _hasTargetDate = State(initialValue: goal.payload.targetDate != nil)
        _targetDate = State(initialValue: goal.payload.targetDate ?? .now)
        _priority = State(initialValue: goal.payload.priority)
        _state = State(initialValue: goal.payload.state)
    }

    var body: some View {
        Form {
            TextField("Goal", text: $title)
            TextField("Details", text: $details, axis: .vertical)
            Toggle("Target date", isOn: $hasTargetDate)
            if hasTargetDate { DatePicker("Due", selection: $targetDate, displayedComponents: .date) }
            Picker("Priority", selection: $priority) { ForEach(0...3, id: \.self) { Text("\($0)").tag($0) } }
            Picker("Status", selection: $state) {
                Text("Active").tag(LearningRecordState.active)
                Text("Completed").tag(LearningRecordState.completed)
                Text("Archived").tag(LearningRecordState.archived)
            }
            lifecycleError(errorMessage)
        }
        .navigationTitle("Edit Goal")
        .toolbar { Button("Save") { Task { await save() } }.disabled(title.trimmed.isEmpty) }
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
                state: state
            )
            model.noteLocalMutation(); onSaved()
        } catch { errorMessage = error.localizedDescription }
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
    let onSaved: () -> Void
    @State private var name: String
    @State private var details: String
    @State private var aliases: String
    @State private var selectedTopics: Set<UUID>
    @State private var archived: Bool
    @State private var errorMessage: String?

    init(model: AppModel, concept: IdentifiedPayload<ConceptPayload>, topics: [IdentifiedPayload<TopicPayload>], onSaved: @escaping () -> Void) {
        self.model = model; self.concept = concept; self.topics = topics; self.onSaved = onSaved
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
            Toggle("Archived", isOn: $archived)
            lifecycleError(errorMessage)
        }
        .navigationTitle("Edit Concept")
        .toolbar { Button("Save") { Task { await save() } }.disabled(name.trimmed.isEmpty || selectedTopics.isEmpty) }
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
