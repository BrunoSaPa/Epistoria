import EpistoriaCore
import SwiftUI
import UniformTypeIdentifiers

struct TopicDashboardView: View {
    @Bindable var model: AppModel
    let topicId: UUID

    @State private var topic: IdentifiedPayload<TopicPayload>?
    @State private var notes: [IdentifiedPayload<NotePayload>] = []
    @State private var sources: [IdentifiedPayload<SourcePayload>] = []
    @State private var sessions: [IdentifiedPayload<StudySessionPayload>] = []
    @State private var concepts: [IdentifiedPayload<ConceptPayload>] = []
    @State private var cards: [IdentifiedPayload<FlashcardPayload>] = []
    @State private var tests: [IdentifiedPayload<PracticeTestPayload>] = []
    @State private var questions: [IdentifiedPayload<UnresolvedQuestionPayload>] = []
    @State private var goals: [IdentifiedPayload<StudyGoalPayload>] = []
    @State private var recommendations: [IdentifiedPayload<StudyRecommendationPayload>] = []
    @State private var showNewNote = false
    @State private var showNewSession = false
    @State private var showNewCard = false
    @State private var showNewTest = false
    @State private var showNewConcept = false
    @State private var showStudio = false
    @State private var showNewGoal = false
    @State private var showNewQuestion = false
    @State private var isImportingSources = false
    @State private var selectedSessionId: UUID?
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                header
                actions
                continueSection
                learningSection
                knowledgeSection
            }
            .padding(EpistoriaDesign.Spacing.page)
            .frame(maxWidth: EpistoriaDesign.Layout.pageWidth)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(topic?.payload.name ?? "Topic")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selectedSessionId) { sessionId in
            SessionDetailView(model: model, sessionId: sessionId)
        }
        .epistoriaPageBackground()
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $showNewNote) {
            NewNoteView(model: model, courseId: topicId) { _ in Task { await load() } }
        }
        .sheet(isPresented: $showNewSession) {
            NewTopicSessionView(model: model, topicId: topicId) { Task { await load() } }
        }
        .sheet(isPresented: $showNewCard) {
            NewFlashcardView(model: model, topicId: topicId) { Task { await load() } }
        }
        .sheet(isPresented: $showNewTest) {
            NewPracticeTestView(model: model, topicId: topicId) { Task { await load() } }
        }
        .sheet(isPresented: $showNewConcept) {
            NewConceptView(model: model, topicId: topicId) { Task { await load() } }
        }
        .sheet(isPresented: $showStudio) {
            TopicStudioView(model: model, topicId: topicId)
        }
        .sheet(isPresented: $showNewGoal) {
            NewStudyGoalView(model: model, topicId: topicId) { Task { await load() } }
        }
        .sheet(isPresented: $showNewQuestion) {
            NewUnresolvedQuestionView(model: model, topicId: topicId) { Task { await load() } }
        }
        .fileImporter(
            isPresented: $isImportingSources,
            allowedContentTypes: EpistoriaSourceImportTypes.supported,
            allowsMultipleSelection: true
        ) { result in
            Task { await importSources(result) }
        }
        .alert("Topic error", isPresented: .constant(errorMessage != nil)) {
            Button("Try again") { Task { await load() } }
            Button("Dismiss", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(topic?.payload.name ?? "Topic")
                .font(.largeTitle.bold())
            if let description = topic?.payload.topicDescription, !description.isEmpty {
                Text(description).foregroundStyle(.secondary)
            } else {
                Text("Notes, Sources, practice, and learning history for this Topic.")
                    .foregroundStyle(.secondary)
            }
            let metadata = [topic?.payload.officialClassName, topic?.payload.code, topic?.payload.professor]
                .compactMap(\ .self)
            if !metadata.isEmpty {
                Text(metadata.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actions: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], spacing: 10) {
            EpistoriaQuickAction(title: "New note", subtitle: "Write in this Topic", symbol: "square.and.pencil", prominent: true) { showNewNote = true }
            EpistoriaQuickAction(title: activeSession == nil ? "Start session" : "Resume session", subtitle: "Focused Topic work", symbol: "timer") {
                if let activeSession { selectedSessionId = activeSession.id }
                else { showNewSession = true }
            }
            EpistoriaQuickAction(title: "Add Source", subtitle: "Documents, books, sheets, or images", symbol: "doc.badge.plus") { isImportingSources = true }
            EpistoriaQuickAction(title: "Ask Topic", subtitle: "Review a cited AI request", symbol: "sparkles") { showStudio = true }
            EpistoriaQuickAction(title: "Create cards", subtitle: "Durable review material", symbol: "rectangle.stack") { showNewCard = true }
            EpistoriaQuickAction(title: "Create test", subtitle: "Coverage-first blueprint", symbol: "checkmark.square") { showNewTest = true }
            EpistoriaQuickAction(title: "New Concept", subtitle: "Define an idea and connect evidence", symbol: "point.3.connected.trianglepath.dotted") { showNewConcept = true }
            EpistoriaQuickAction(title: "Add goal", subtitle: "Give Study Next a deadline", symbol: "target") { showNewGoal = true }
            EpistoriaQuickAction(title: "Open question", subtitle: "Track what remains unclear", symbol: "questionmark.circle") { showNewQuestion = true }
        }
    }

    @ViewBuilder
    private var continueSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            EpistoriaSectionHeading(title: "Continue", subtitle: "Return to recent work without changing its organization.")
            if let session = activeSession {
                NavigationLink {
                    SessionDetailView(model: model, sessionId: session.id)
                } label: {
                    dashboardRow(title: session.payload.title, detail: session.payload.state.displayName, symbol: "timer")
                }
                .buttonStyle(.plain)
            }
            ForEach(notes.prefix(3), id: \.id) { note in
                NavigationLink {
                    NoteEditorView(model: model, noteId: note.id)
                } label: {
                    dashboardRow(title: note.payload.title, detail: note.payload.updatedAt.formatted(date: .abbreviated, time: .shortened), symbol: "note.text")
                }
                .buttonStyle(.plain)
            }
            if activeSession == nil && notes.isEmpty {
                Text("Create a note or start a session to begin this Topic.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var learningSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            EpistoriaSectionHeading(title: "Learning", subtitle: "Practice records remain available offline and keep their history.")
            metricGrid
            if let next = recommendations.first {
                dashboardRow(title: next.payload.title, detail: next.payload.explanation, symbol: "arrow.forward.circle")
            }
            ForEach(questions.prefix(2), id: \.id) { item in
                dashboardRow(title: item.payload.question, detail: "Unresolved question", symbol: "questionmark.circle")
            }
        }
    }

    private var metricGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 10)], spacing: 10) {
            metric(title: "Cards", value: cards.count, symbol: "rectangle.stack")
            metric(title: "Tests", value: tests.count, symbol: "checkmark.square")
            metric(title: "Concepts", value: concepts.count, symbol: "point.3.connected.trianglepath.dotted")
            metric(title: "Goals", value: goals.filter { $0.payload.state == .active }.count, symbol: "target")
        }
    }

    private var knowledgeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            EpistoriaSectionHeading(title: "Knowledge", subtitle: "Sources and Concepts stay anchored to this Topic.")
            ForEach(sources.prefix(4), id: \.id) { source in
                NavigationLink {
                    ResourceDetailView(model: model, resourceId: source.id)
                } label: {
                    dashboardRow(title: source.payload.title, detail: source.payload.sourceType.displayName, symbol: source.payload.sourceType.epistoriaSymbol)
                }
                .buttonStyle(.plain)
            }
            ForEach(concepts.prefix(4), id: \.id) { concept in
                dashboardRow(title: concept.payload.name, detail: concept.payload.conceptDescription, symbol: "circle.hexagongrid")
            }
            if sources.isEmpty && concepts.isEmpty {
                Text("Add a Source or define a Concept when you have material to connect.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func dashboardRow(title: String, detail: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 24).foregroundStyle(EpistoriaDesign.ink)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium)).lineLimit(2)
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func metric(title: String, value: Int, symbol: String) -> some View {
        HStack {
            Image(systemName: symbol).foregroundStyle(.secondary)
            VStack(alignment: .leading) {
                Text("\(value)").font(.title3.bold())
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(EpistoriaDesign.border.opacity(0.7), lineWidth: 0.5) }
    }

    private var activeSession: IdentifiedPayload<StudySessionPayload>? {
        sessions.first { $0.payload.state == .active || $0.payload.state == .paused }
    }

    private func load() async {
        guard let store = model.store else { return }
        do {
            async let loadedTopic = store.topic(id: topicId)
            async let loadedNotes = store.list(NotePayload.self)
            async let loadedSources = store.list(SourcePayload.self)
            async let loadedSessions = store.list(StudySessionPayload.self)
            async let loadedConcepts = store.list(ConceptPayload.self)
            async let loadedCards = store.list(FlashcardPayload.self)
            async let loadedTests = store.list(PracticeTestPayload.self)
            async let loadedQuestions = store.list(UnresolvedQuestionPayload.self)
            async let loadedGoals = store.list(StudyGoalPayload.self)
            async let loadedRecommendations = store.list(StudyRecommendationPayload.self)
            let values = try await (loadedTopic, loadedNotes, loadedSources, loadedSessions, loadedConcepts, loadedCards, loadedTests, loadedQuestions, loadedGoals, loadedRecommendations)
            topic = values.0
            notes = values.1.filter { $0.payload.courseId == topicId && $0.payload.archivedAt == nil }.sorted { $0.payload.updatedAt > $1.payload.updatedAt }
            sources = values.2.filter { $0.payload.primaryTopicId == topicId || $0.payload.relatedTopicIds.contains(topicId) }.sorted { $0.payload.updatedAt > $1.payload.updatedAt }
            sessions = values.3.filter { $0.payload.courseId == topicId }.sorted { $0.payload.startedAt > $1.payload.startedAt }
            concepts = values.4.filter { $0.payload.topicIds.contains(topicId) }
            cards = values.5.filter { $0.payload.topicId == topicId && $0.payload.archivedAt == nil }
            tests = values.6.filter { $0.payload.topicId == topicId && $0.payload.state != .archived }
            questions = values.7.filter { $0.payload.topicId == topicId && $0.payload.resolvedAt == nil }
            goals = values.8.filter { $0.payload.topicId == topicId }
            recommendations = values.9.filter { $0.payload.topicId == topicId }.sorted { $0.payload.score > $1.payload.score }
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func importSources(_ result: Result<[URL], Error>) async {
        guard let manager = model.assetManager else { return }
        do {
            for url in try result.get() {
                _ = try await manager.importSource(from: url, topicId: topicId)
            }
            model.noteLocalMutation()
            await load()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct NewConceptView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let topicId: UUID
    let onCreated: () -> Void
    @State private var name = ""
    @State private var description = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Concept name", text: $name)
                TextField("Description", text: $description, axis: .vertical)
                Text("Concepts are user-owned. AI suggestions remain drafts until you accept them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle("New Concept")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await create() } }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func create() async {
        guard let store = model.store else { return }
        do {
            _ = try await store.createConcept(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                topicIds: [topicId]
            )
            model.noteLocalMutation()
            onCreated()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct NewStudyGoalView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let topicId: UUID
    let onCreated: () -> Void
    @State private var title = ""
    @State private var hasDeadline = false
    @State private var targetDate = Date.now.addingTimeInterval(7 * 86_400)
    @State private var priority = 1
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Goal", text: $title)
                Picker("Priority", selection: $priority) {
                    Text("Normal").tag(1)
                    Text("High").tag(2)
                    Text("Critical").tag(3)
                }
                Toggle("Set a target date", isOn: $hasDeadline)
                if hasDeadline { DatePicker("Target date", selection: $targetDate, displayedComponents: .date) }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle("New study goal")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await create() } }
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func create() async {
        guard let store = model.store else { return }
        do {
            _ = try await store.save(
                payload: StudyGoalPayload(
                    topicId: topicId,
                    title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                    targetDate: hasDeadline ? targetDate : nil,
                    priority: priority
                ),
                parentId: topicId,
                relationIds: [topicId]
            )
            model.noteLocalMutation()
            onCreated()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct NewUnresolvedQuestionView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let topicId: UUID
    let onCreated: () -> Void
    @State private var question = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("What is still unclear?", text: $question, axis: .vertical)
                Text("Study Next can surface this question without using AI.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle("Unresolved question")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await create() } }
                        .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func create() async {
        guard let store = model.store else { return }
        do {
            _ = try await store.save(
                payload: UnresolvedQuestionPayload(
                    topicId: topicId,
                    question: question.trimmingCharacters(in: .whitespacesAndNewlines)
                ),
                parentId: topicId,
                relationIds: [topicId]
            )
            model.noteLocalMutation()
            onCreated()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct NewTopicSessionView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let topicId: UUID
    let onCreated: () -> Void
    @State private var objective = ""
    @State private var startingNotes = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Objective", text: $objective)
                TextField("Starting notes (optional)", text: $startingNotes, axis: .vertical)
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle("Start session")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { Task { await create() } }
                        .disabled(objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func create() async {
        guard let store = model.store else { return }
        do {
            let cleanObjective = objective.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanNotes = startingNotes.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await store.startSession(
                title: cleanObjective,
                courseId: topicId,
                goals: [cleanObjective],
                requireTopic: true,
                objective: cleanObjective,
                startingNotes: cleanNotes.isEmpty ? nil : cleanNotes
            )
            model.noteLocalMutation()
            onCreated()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

private extension StudySessionState {
    var displayName: String {
        switch self {
        case .planned: "Planned"
        case .active: "Active"
        case .paused: "Paused"
        case .ended: "Ended"
        case .abandoned: "Abandoned"
        }
    }
}

private extension ResourceKind {
    var displayName: String { rawValue.replacingOccurrences(of: "_", with: " ").capitalized }
}
