import EpistoriaCore
import SwiftUI

struct AdaptiveTutorView: View {
    @Bindable var model: AppModel
    let initialTopicId: UUID?
    let initialMessage: String?
    let preferredEvidenceIds: [UUID]
    var compact = false

    @Environment(\.dismiss) private var dismiss
    @State private var topics: [IdentifiedPayload<TopicPayload>] = []
    @State private var sources: [IdentifiedPayload<SourcePayload>] = []
    @State private var sessions: [IdentifiedPayload<TutorSessionPayload>] = []
    @State private var activeSession: IdentifiedPayload<TutorSessionPayload>?
    @State private var turns: [IdentifiedPayload<TutorTurnPayload>] = []
    @State private var signals: [IdentifiedPayload<LearningSignalPayload>] = []
    @State private var selectedCitation: TutorCitation?
    @State private var selectedTopicId: UUID?
    @State private var selectedSourceVersionIds = Set<UUID>()
    @State private var objective = ""
    @State private var timeTargetMinutes = 25
    @State private var includeConnectedKnowledge = false
    @State private var maximumTurns = 12
    @State private var spendingLimitMinorUnits = 100
    @State private var learnerMessage = ""
    @State private var confidence = 3
    @State private var requestTask: Task<Void, Never>?
    @State private var isWorking = false
    @State private var errorMessage: String?

    init(
        model: AppModel,
        topicId: UUID? = nil,
        initialMessage: String? = nil,
        preferredEvidenceIds: [UUID] = [],
        compact: Bool = false
    ) {
        self.model = model
        initialTopicId = topicId
        self.initialMessage = initialMessage
        self.preferredEvidenceIds = preferredEvidenceIds
        self.compact = compact
        _selectedTopicId = State(initialValue: topicId)
        _learnerMessage = State(initialValue: initialMessage ?? "")
    }

    var body: some View {
        NavigationStack {
            Group {
                if let activeSession {
                    conversation(activeSession)
                } else {
                    setup
                }
            }
            .navigationTitle(activeSession == nil ? "Tutor" : "Learning Guide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if compact {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") { dismiss() }
                            .labelStyle(.iconOnly)
                    }
                }
                if activeSession != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("Pause session", systemImage: "pause") { Task { await setSession(.paused) } }
                            Button("End session", systemImage: "checkmark") { beginRequest(.end) }
                            Button("Abandon session", systemImage: "xmark", role: .destructive) { Task { await setSession(.abandoned) } }
                        } label: { Label("Session actions", systemImage: "ellipsis.circle") }
                    }
                }
            }
            .task { await load() }
            .refreshable { await refresh() }
            .sheet(item: $selectedCitation) { citation in
                NavigationStack {
                    SourceDetailView(
                        model: model,
                        sourceId: citation.sourceId,
                        initialSourceVersionId: citation.sourceVersionId,
                        initialPageNumber: citation.locator.page,
                        highlightText: citation.excerpt,
                        initialMediaTimeSeconds: citation.locator.startSeconds
                    )
                }
            }
            .alert("Tutor error", isPresented: .constant(errorMessage != nil)) {
                Button("Dismiss", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    private var setup: some View {
        Form {
            Section {
                Picker("Topic", selection: $selectedTopicId) {
                    Text("Select a Topic").tag(UUID?.none)
                    ForEach(topics, id: \.id) { Text($0.payload.name).tag(UUID?.some($0.id)) }
                }
                TextField("Objective (optional)", text: $objective, axis: .vertical)
                Stepper("Time target: \(timeTargetMinutes) minutes", value: $timeTargetMinutes, in: 5...180, step: 5)
                Toggle("Include connected knowledge", isOn: $includeConnectedKnowledge)
            } header: {
                Text("Scope")
            } footer: {
                Text("The selected Topic is the default scope. Connected knowledge is included only when you turn it on.")
            }

            Section {
                if topicSources.isEmpty {
                    Text("This Topic has no available Source Version. Add a Source before starting a cited Tutor session.")
                        .foregroundStyle(.secondary)
                }
                ForEach(topicSources, id: \.id) { source in
                    Toggle(source.payload.title, isOn: sourceBinding(source))
                }
            } header: {
                Text("Sources")
            } footer: {
                Text("Tutor uses reviewed Evidence and analyzed Source references from the selected versions. If a Source has not been analyzed, create a Source guide or Evidence first.")
            }

            Section {
                Stepper("Maximum turns: \(maximumTurns)", value: $maximumTurns, in: 1...40)
                Stepper(
                    "Spending limit: \(Double(spendingLimitMinorUnits) / 100, format: .currency(code: "USD"))",
                    value: $spendingLimitMinorUnits,
                    in: 25...2_000,
                    step: 25
                )
                if model.aiJobs == nil {
                    Label("No provider is connected. You can save a local session, but Tutor requests wait until private sync and a provider are available.", systemImage: "icloud.slash")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Label("Approval applies only to this Topic, these Source Versions, this provider route, and the limits above.", systemImage: "hand.raised")
                        .font(.subheadline)
                }
                Button("Start Learning Guide", systemImage: "graduationcap") { Task { await start() } }
                    .buttonStyle(.borderedProminent)
                    .tint(EpistoriaDesign.ink)
                    .disabled(selectedTopicId == nil || selectedSourceVersionIds.isEmpty || isWorking)
            } header: { Text("Session approval") }

            if !sessions.isEmpty {
                Section("Previous sessions") {
                    ForEach(sessions.prefix(8), id: \.id) { session in
                        Button {
                            activeSession = session
                            Task { await loadSession(session.id) }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(session.payload.objective ?? topicName(session.payload.topicId))
                                    .foregroundStyle(.primary)
                                Text("\(session.payload.state.displayName) · \(session.payload.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func conversation(_ session: IdentifiedPayload<TutorSessionPayload>) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        sessionSummary(session)
                        if turns.isEmpty {
                            ContentUnavailableView {
                                Label("Start with a diagnostic", systemImage: "graduationcap")
                            } description: {
                                Text("The Tutor uses accepted learning history and cited Source excerpts to choose the next activity.")
                            } actions: {
                                Button("Begin", systemImage: "play") { beginRequest(.begin) }
                                    .buttonStyle(.borderedProminent)
                                    .tint(EpistoriaDesign.ink)
                            }
                        }
                        ForEach(turns, id: \.id) { turn in turnView(turn) }
                        proposedSignalReview
                    }
                    .padding(compact ? 14 : EpistoriaDesign.Spacing.page)
                }
                .onChange(of: turns.count) { _, _ in
                    if let last = turns.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            Divider()
            composer
        }
        .background(EpistoriaDesign.page)
    }

    private func sessionSummary(_ session: IdentifiedPayload<TutorSessionPayload>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(session.payload.objective ?? topicName(session.payload.topicId)).font(.headline)
                Spacer()
                Text(session.payload.state.displayName).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            let projection = TutorAdaptationEngine.project(
                objective: session.payload.objective ?? topicName(session.payload.topicId),
                signals: signals
            )
            Text(projection.explanation).font(.subheadline).foregroundStyle(.secondary)
            ProgressView(value: projection.score)
                .tint(EpistoriaDesign.ink)
                .accessibilityLabel("Accepted mastery evidence")
                .accessibilityValue(projection.level.displayName)
        }
        .padding(14)
        .background(EpistoriaDesign.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(EpistoriaDesign.border, lineWidth: 0.5) }
    }

    private func turnView(_ turn: IdentifiedPayload<TutorTurnPayload>) -> some View {
        VStack(alignment: turn.payload.role == .learner ? .trailing : .leading, spacing: 7) {
            Text(turn.payload.role == .learner ? "You" : "Tutor")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(turn.payload.text)
                .textSelection(.enabled)
                .padding(12)
                .background(
                    turn.payload.role == .learner ? EpistoriaDesign.ink : EpistoriaDesign.surface,
                    in: RoundedRectangle(cornerRadius: 10)
                )
                .foregroundStyle(turn.payload.role == .learner ? Color.white : Color.primary)
            if turn.payload.pending {
                Label("Saved locally · response pending", systemImage: "clock")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !turn.payload.citations.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(Array(turn.payload.citations.enumerated()), id: \.element.id) { index, citation in
                            Button("Source \(index + 1)", systemImage: "doc.text.magnifyingglass") {
                                selectedCitation = citation
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: turn.payload.role == .learner ? .trailing : .leading)
        .id(turn.id)
    }

    @ViewBuilder private var proposedSignalReview: some View {
        let proposed = signals.filter { $0.payload.reviewState == .proposed }
        if !proposed.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Review learning signals").font(.headline)
                Text("These assessments do not affect mastery until you accept them.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(proposed, id: \.id) { signal in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(signal.payload.objective).font(.subheadline.weight(.semibold))
                        Text(signal.payload.rationale ?? signal.payload.outcome.displayName)
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Accept", systemImage: "checkmark") { Task { await review(signal.id, .accepted) } }
                            Button("Reject", systemImage: "xmark", role: .destructive) { Task { await review(signal.id, .rejected) } }
                        }
                    }
                    .padding(12)
                    .background(EpistoriaDesign.surface, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    actionButton("Hint", "lightbulb", .hint)
                    actionButton("Explain directly", "text.book.closed", .explainDirectly)
                    actionButton("Another example", "arrow.triangle.2.circlepath", .tryAnotherExample)
                    actionButton("Why this next?", "questionmark.circle", .whyNext)
                    if requestTask != nil {
                        ProgressView("Waiting for provider")
                        Button("Cancel request", systemImage: "xmark.circle", role: .destructive) {
                            cancelRequest()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Answer or ask a question", text: $learnerMessage, axis: .vertical)
                        .lineLimit(1...5)
                        .textFieldStyle(.roundedBorder)
                    Picker("Confidence", selection: $confidence) {
                        ForEach(1...5, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityHint("1 is uncertain. 5 is very confident.")
                }
                Button("Send", systemImage: "arrow.up.circle.fill") { beginRequest(.answer) }
                    .labelStyle(.iconOnly).font(.title2)
                    .disabled(learnerMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
            }
        }
        .padding(compact ? 12 : 16)
        .background(.regularMaterial)
    }

    private func actionButton(_ title: String, _ symbol: String, _ action: TutorTurnAction) -> some View {
        Button(title, systemImage: symbol) { beginRequest(action) }
            .buttonStyle(.bordered).disabled(isWorking || requestTask != nil)
    }

    private var topicSources: [IdentifiedPayload<SourcePayload>] {
        guard let selectedTopicId else { return [] }
        return sources.filter {
            ($0.payload.primaryTopicId == selectedTopicId || $0.payload.relatedTopicIds.contains(selectedTopicId))
                && $0.payload.currentVersionId != nil && $0.payload.archivedAt == nil
        }
    }

    private func sourceBinding(_ source: IdentifiedPayload<SourcePayload>) -> Binding<Bool> {
        Binding(
            get: { source.payload.currentVersionId.map(selectedSourceVersionIds.contains) ?? false },
            set: { selected in
                guard let id = source.payload.currentVersionId else { return }
                if selected { selectedSourceVersionIds.insert(id) } else { selectedSourceVersionIds.remove(id) }
            }
        )
    }

    private func start() async {
        guard let topicId = selectedTopicId, let store = model.store else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let budget = TutorSessionBudget(
                maximumTurns: maximumTurns,
                spendingLimitMinorUnits: spendingLimitMinorUnits,
                expiresAt: .now.addingTimeInterval(4 * 60 * 60)
            )
            let id: UUID
            if let coordinator = model.aiJobs {
                id = try await coordinator.createTutorSession(
                    topicId: topicId,
                    objective: objective,
                    timeTargetMinutes: timeTargetMinutes,
                    sourceVersionIds: Array(selectedSourceVersionIds),
                    includeConnectedKnowledge: includeConnectedKnowledge,
                    budget: budget
                )
            } else {
                id = try await store.createTutorSession(
                    topicId: topicId,
                    objective: objective,
                    timeTargetMinutes: timeTargetMinutes,
                    sourceVersionIds: Array(selectedSourceVersionIds),
                    includeConnectedKnowledge: includeConnectedKnowledge,
                    budget: budget
                )
            }
            model.noteLocalMutation()
            await loadSession(id)
        } catch { errorMessage = error.localizedDescription }
    }

    private func send(_ action: TutorTurnAction) async {
        guard let sessionId = activeSession?.id, let store = model.store else { return }
        isWorking = true
        defer { isWorking = false }
        let message = learnerMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        var pendingJobId: UUID?
        do {
            guard let coordinator = model.aiJobs else {
                _ = try await store.appendOfflineTutorTurn(
                    sessionId: sessionId,
                    text: message.isEmpty ? action.displayLabel : message,
                    confidence: action == .answer ? confidence : nil
                )
                learnerMessage = ""
                model.noteLocalMutation()
                await loadSession(sessionId)
                return
            }
            let prepared = try await coordinator.prepareTutorTurn(
                sessionId: sessionId,
                action: action,
                learnerMessage: message.isEmpty ? nil : message,
                learnerConfidence: action == .answer ? confidence : nil,
                preferredEvidenceIds: preferredEvidenceIds
            )
            pendingJobId = prepared.request.jobId
            _ = try await model.generateTutorTurnDirect(prepared)
            learnerMessage = ""
            await loadSession(sessionId)
        } catch is CancellationError {
            if let pendingJobId {
                try? await store.resolvePendingTutorTurn(
                    sessionId: sessionId,
                    jobId: pendingJobId,
                    statusMessage: "The provider request was cancelled. Your message remains in this session."
                )
            }
            await loadSession(sessionId)
        } catch { errorMessage = error.localizedDescription }
    }

    private func beginRequest(_ action: TutorTurnAction) {
        guard requestTask == nil else { return }
        requestTask = Task {
            await send(action)
            requestTask = nil
        }
    }

    private func refresh() async {
        guard let sessionId = activeSession?.id else { await load(); return }
        isWorking = true
        defer { isWorking = false }
        await model.synchronize()
        await loadSession(sessionId)
    }

    private func cancelRequest() {
        requestTask?.cancel()
    }

    private func review(_ id: UUID, _ state: LearningSignalReviewState) async {
        do {
            try await model.store?.reviewLearningSignal(id: id, state: state)
            model.noteLocalMutation()
            if let sessionId = activeSession?.id { await loadSession(sessionId) }
        } catch { errorMessage = error.localizedDescription }
    }

    private func setSession(_ state: TutorSessionState) async {
        guard let id = activeSession?.id else { return }
        do {
            try await model.store?.setTutorSessionState(id: id, state: state)
            model.noteLocalMutation()
            activeSession = nil
            await load()
        } catch { errorMessage = error.localizedDescription }
    }

    private func load() async {
        guard let store = model.store else { return }
        do {
            async let topicValues = store.topics()
            async let sourceValues = store.list(SourcePayload.self)
            async let sessionValues = store.tutorSessions(topicId: initialTopicId)
            let values = try await (topicValues, sourceValues, sessionValues)
            topics = values.0
            sources = values.1
            sessions = values.2
            if selectedTopicId == nil { selectedTopicId = initialTopicId ?? topics.first?.id }
            if selectedSourceVersionIds.isEmpty {
                selectedSourceVersionIds = Set(topicSources.compactMap(\.payload.currentVersionId))
            }
            if activeSession == nil,
               let resumable = sessions.first(where: { $0.payload.state == .active || $0.payload.state == .paused }) {
                activeSession = resumable
                await loadSession(resumable.id)
            }
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func loadSession(_ id: UUID) async {
        guard let store = model.store else { return }
        do {
            async let sessionValue = store.payload(TutorSessionPayload.self, id: id)
            async let turnValues = store.tutorTurns(sessionId: id)
            async let signalValues = store.learningSignals(sessionId: id)
            let values = try await (sessionValue, turnValues, signalValues)
            activeSession = values.0
            turns = values.1
            signals = values.2
            if activeSession?.payload.state == .paused {
                try await store.setTutorSessionState(id: id, state: .active)
                activeSession = try await store.payload(TutorSessionPayload.self, id: id)
            }
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func topicName(_ id: UUID) -> String {
        topics.first { $0.id == id }?.payload.name ?? "Topic"
    }
}

private extension TutorSessionState {
    var displayName: String {
        switch self {
        case .active: "Active"
        case .paused: "Paused"
        case .ended: "Ended"
        case .abandoned: "Abandoned"
        }
    }
}

private extension MasteryLevel {
    var displayName: String {
        switch self {
        case .notAssessed: "Not assessed"
        case .needsWork: "Needs work"
        case .developing: "Developing"
        case .secure: "Secure"
        }
    }
}

private extension LearningSignalOutcome {
    var displayName: String {
        switch self {
        case .correct: "Correct"
        case .partial: "Partially correct"
        case .incorrect: "Incorrect"
        case .skipped: "Skipped"
        }
    }
}
