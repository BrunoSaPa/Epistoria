import EpistoriaCore
import SwiftUI

struct TopicStudioView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let topicId: UUID

    @State private var jobType = LearningAIJobType.topicSynthesis
    @State private var instructions = ""
    @State private var objectives = ""
    @State private var includeConnectedKnowledge = false
    @State private var prepared: PreparedLearningGenerationRequest?
    @State private var submittedJob: AIJobSummary?
    @State private var artifact: IdentifiedPayload<LearningGenerationArtifact>?
    @State private var selectedItemIds: Set<UUID> = []
    @State private var reviewedItems: [UUID: LearningDraftItem] = [:]
    @State private var reviewedSummary = ""
    @State private var editingItem: LearningDraftItem?
    @State private var isWorking = false
    @State private var acceptanceMessage: String?
    @State private var errorMessage: String?

    private let availableJobs: [LearningAIJobType] = [
        .topicSynthesis, .flashcardDrafts, .testBlueprint, .testGeneration,
        .conceptSuggestions, .weeklyReview,
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Create") {
                    Picker("Output", selection: $jobType) {
                        ForEach(availableJobs, id: \.self) { type in
                            Label(type.displayName, systemImage: type.symbol).tag(type)
                        }
                    }
                    TextField("Instructions (optional)", text: $instructions, axis: .vertical)
                    if jobType == .testBlueprint || jobType == .testGeneration {
                        TextField("Objectives, one per line", text: $objectives, axis: .vertical)
                    }
                    Toggle("Include connected knowledge", isOn: $includeConnectedKnowledge)
                    Text(includeConnectedKnowledge
                         ? "Includes Topics connected through the same Areas. The disclosure below shows the final scope."
                         : "Uses this Topic only. This is the default scope.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Review request", systemImage: "doc.text.magnifyingglass") {
                        Task { await prepare() }
                    }
                    .disabled(isWorking)
                }

                if let prepared {
                    Section("Review before sending") {
                        LabeledContent("Excerpts", value: prepared.sourceCount.formatted())
                        LabeledContent("Approximate tokens", value: prepared.approximateTokens.formatted())
                        Label("Paid provider processing requires this approval", systemImage: "hand.raised")
                            .font(.subheadline)
                        Button("Approve and queue", systemImage: "desktopcomputer") {
                            Task { await submit() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(EpistoriaDesign.ink)
                        .disabled(isWorking)
                    }
                }

                if let submittedJob {
                    Section("Queued") {
                        LabeledContent("Status", value: submittedJob.status.capitalized)
                        Text("Your trusted Mac processes the encrypted request. Sync after it finishes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let artifact {
                    Section("Latest draft") {
                        if supportsItemReview {
                            if artifact.payload.reviewState != .accepted {
                                TextField("Draft title", text: $reviewedSummary, axis: .vertical)
                                    .onSubmit { Task { await persistDraftReview() } }
                                HStack {
                                    Button("Select all") { Task { await selectAll() } }
                                    Button("Clear") { Task { await clearSelection() } }
                                    Spacer()
                                    Text("\(selectedItemIds.count) of \(artifact.payload.response.items.count) selected")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                Text((artifact.payload.editedResponse ?? artifact.payload.response).summary)
                            }

                            ForEach(artifact.payload.response.items) { original in
                                let item = reviewedItems[original.id] ?? original
                                HStack(alignment: .top, spacing: 12) {
                                    if artifact.payload.reviewState != .accepted {
                                        Toggle(
                                            "Include \(item.title)",
                                            isOn: selectionBinding(for: original.id)
                                        )
                                        .labelsHidden()
                                        .disabled(isWorking)
                                    } else {
                                        Image(systemName: selectedItemIds.contains(original.id)
                                              ? "checkmark.circle.fill" : "minus.circle")
                                            .foregroundStyle(selectedItemIds.contains(original.id) ? EpistoriaDesign.ink : .secondary)
                                    }
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(item.title).font(.headline)
                                        Text(item.body)
                                        if let answer = item.answer, !answer.isEmpty {
                                            Text(answer).font(.subheadline).foregroundStyle(.secondary)
                                        }
                                        if !item.objectiveTitles.isEmpty {
                                            Text(item.objectiveTitles.joined(separator: " · "))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Label(
                                            "\(item.citedSourceIds.count) citation\(item.citedSourceIds.count == 1 ? "" : "s")",
                                            systemImage: "link"
                                        )
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if artifact.payload.reviewState != .accepted {
                                        Button("Edit", systemImage: "pencil") {
                                            editingItem = item
                                        }
                                        .labelStyle(.iconOnly)
                                        .accessibilityLabel("Edit \(item.title)")
                                        .disabled(isWorking)
                                    }
                                }
                                .padding(.vertical, 5)
                                .opacity(selectedItemIds.contains(original.id) ? 1 : 0.5)
                            }

                            if !artifact.payload.response.coverageGaps.isEmpty {
                                LabeledContent(
                                    "Coverage gaps",
                                    value: artifact.payload.response.coverageGaps.joined(separator: ", ")
                                )
                            }

                            if artifact.payload.reviewState != .accepted {
                                HStack {
                                    Button("Accept selected", systemImage: "checkmark.circle") {
                                        Task { await acceptSelected() }
                                    }
                                    .disabled(selectedItemIds.isEmpty || isWorking)
                                    Button("Reject all", systemImage: "xmark.circle", role: .destructive) {
                                        Task { await review(.rejected) }
                                    }
                                }
                                Text("Only selected items become durable records. The original generated draft remains unchanged for provenance.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Label("Accepted", systemImage: "checkmark.circle.fill")
                            }
                        } else {
                            Text(artifact.payload.response.summary)
                            ForEach(artifact.payload.response.items) { item in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.title).font(.headline)
                                    Text(item.body)
                                }
                            }
                            HStack {
                                Button("Accept draft", systemImage: "checkmark.circle") {
                                    Task { await review(.accepted) }
                                }
                                Button("Reject", systemImage: "xmark.circle", role: .destructive) {
                                    Task { await review(.rejected) }
                                }
                            }
                        }
                        if let acceptanceMessage {
                            Text(acceptanceMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Topic Studio")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await loadArtifact() } }
                }
            }
            .task { await loadArtifact() }
            .sheet(item: $editingItem) { item in
                LearningDraftItemEditor(
                    item: item,
                    jobType: artifact?.payload.jobType ?? jobType
                ) { edited in
                    reviewedItems[edited.id] = edited
                    selectedItemIds.insert(edited.id)
                    editingItem = nil
                    Task { await persistDraftReview() }
                }
            }
            .onChange(of: jobType) {
                prepared = nil
                submittedJob = nil
                Task { await loadArtifact() }
            }
            .onChange(of: includeConnectedKnowledge) { prepared = nil }
        }
    }

    private func prepare() async {
        guard let coordinator = model.aiJobs else {
            errorMessage = "Connect the private server and pair your trusted Mac in Settings first."
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let objectiveTitles = objectives
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            prepared = try await coordinator.prepareTopicGeneration(
                topicId: topicId,
                jobType: jobType,
                objectiveTitles: objectiveTitles,
                userInstructions: instructions.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                includeConnectedKnowledge: includeConnectedKnowledge
            )
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func submit() async {
        guard let coordinator = model.aiJobs, let prepared else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            submittedJob = try await coordinator.submitTopicGeneration(prepared)
            self.prepared = nil
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func loadArtifact() async {
        do {
            artifact = try await model.aiJobs?.latestTopicGeneration(topicId: topicId, jobType: jobType)
            configureDraftReview()
        } catch { errorMessage = error.localizedDescription }
    }

    private var supportsItemReview: Bool {
        guard let type = artifact?.payload.jobType else { return false }
        return type == .flashcardDrafts || type == .testGeneration || type == .conceptSuggestions
    }

    private var selectedItems: [LearningDraftItem] {
        guard let artifact else { return [] }
        return artifact.payload.response.items.compactMap { original in
            guard selectedItemIds.contains(original.id) else { return nil }
            return reviewedItems[original.id] ?? original
        }
    }

    private func configureDraftReview() {
        guard let artifact else {
            selectedItemIds = []
            reviewedItems = [:]
            reviewedSummary = ""
            return
        }
        let reviewed = artifact.payload.editedResponse
        let items = reviewed?.items ?? artifact.payload.response.items
        selectedItemIds = Set(items.map(\.id))
        reviewedItems = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        reviewedSummary = reviewed?.summary ?? artifact.payload.response.summary
    }

    private func selectionBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedItemIds.contains(id) },
            set: { included in
                if included { selectedItemIds.insert(id) }
                else { selectedItemIds.remove(id) }
                Task { await persistDraftReview() }
            }
        )
    }

    private func selectAll() async {
        guard let artifact else { return }
        selectedItemIds = Set(artifact.payload.response.items.map(\.id))
        for item in artifact.payload.response.items where reviewedItems[item.id] == nil {
            reviewedItems[item.id] = item
        }
        await persistDraftReview()
    }

    private func clearSelection() async {
        selectedItemIds = []
        await persistDraftReview()
    }

    private func persistDraftReview() async {
        guard let store = model.store, let artifact, artifact.payload.reviewState != .accepted else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await store.saveLearningArtifactDraftReview(
                id: artifact.id,
                summary: reviewedSummary,
                selectedItems: selectedItems
            )
            model.noteLocalMutation()
            errorMessage = nil
            await loadArtifact()
        } catch {
            errorMessage = error.localizedDescription
            await loadArtifact()
        }
    }

    private func acceptSelected() async {
        await persistDraftReview()
        guard errorMessage == nil else { return }
        await review(.accepted)
    }

    private func review(_ state: AIArtifactReviewState) async {
        guard let store = model.store, var artifact else { return }
        do {
            if state == .accepted {
                let created = try await store.acceptLearningArtifact(id: artifact.id)
                acceptanceMessage = [
                    created.flashcards > 0 ? "\(created.flashcards) card\(created.flashcards == 1 ? "" : "s")" : nil,
                    created.tests > 0 ? "\(created.tests) test" : nil,
                    created.concepts > 0 ? "\(created.concepts) Concept\(created.concepts == 1 ? "" : "s")" : nil,
                ]
                .compactMap(\ .self)
                .joined(separator: ", ")
                .nilIfEmpty ?? "Draft accepted"
                await loadArtifact()
            } else {
                artifact.payload.reviewState = state
                artifact.payload.reviewedAt = .now
                _ = try await store.save(
                    id: artifact.id,
                    payload: artifact.payload,
                    parentId: topicId,
                    relationIds: [topicId] + artifact.payload.sourceIds
                )
                self.artifact = artifact
            }
            model.noteLocalMutation()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct LearningDraftItemEditor: View {
    @Environment(\.dismiss) private var dismiss
    let item: LearningDraftItem
    let jobType: LearningAIJobType
    let onSave: (LearningDraftItem) -> Void

    @State private var kind: String
    @State private var title: String
    @State private var bodyText: String
    @State private var answer: String
    @State private var choices: String
    @State private var objectives: String

    init(
        item: LearningDraftItem,
        jobType: LearningAIJobType,
        onSave: @escaping (LearningDraftItem) -> Void
    ) {
        self.item = item
        self.jobType = jobType
        self.onSave = onSave
        _kind = State(initialValue: item.kind)
        _title = State(initialValue: item.title)
        _bodyText = State(initialValue: item.body)
        _answer = State(initialValue: item.answer ?? "")
        _choices = State(initialValue: item.choices.joined(separator: "\n"))
        _objectives = State(initialValue: item.objectiveTitles.joined(separator: "\n"))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(itemLabel) {
                    Picker("Type", selection: $kind) {
                        ForEach(availableKinds, id: \.self) { value in
                            Text(value.replacingOccurrences(of: "_", with: " ").capitalized)
                                .tag(value)
                        }
                    }
                    TextField(titleLabel, text: $title, axis: .vertical)
                    TextField(bodyLabel, text: $bodyText, axis: .vertical)
                    if requiresAnswer {
                        TextField("Answer or answer key", text: $answer, axis: .vertical)
                    }
                }
                if jobType == .testGeneration {
                    Section("Test details") {
                        TextField("Choices, one per line", text: $choices, axis: .vertical)
                        TextField("Objectives, one per line", text: $objectives, axis: .vertical)
                    }
                }
                Section("Evidence") {
                    Label(
                        "\(item.citedSourceIds.count) source citation\(item.citedSourceIds.count == 1 ? "" : "s") retained",
                        systemImage: "link"
                    )
                    Text("Citations are fixed during this review. Remove the item if its evidence does not support it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Edit Draft Item")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(title.trimmed.isEmpty || (requiresAnswer && answer.trimmed.isEmpty))
                }
            }
        }
    }

    private var itemLabel: String {
        switch jobType {
        case .flashcardDrafts: "Flashcard"
        case .testGeneration: "Question"
        case .conceptSuggestions: "Concept"
        default: "Item"
        }
    }

    private var titleLabel: String {
        switch jobType {
        case .flashcardDrafts: "Prompt"
        case .testGeneration: "Question"
        case .conceptSuggestions: "Concept name"
        default: "Title"
        }
    }

    private var bodyLabel: String {
        switch jobType {
        case .testGeneration: "Rubric or grading guide"
        case .conceptSuggestions: "Description"
        default: "Explanation"
        }
    }

    private var requiresAnswer: Bool {
        jobType == .flashcardDrafts || jobType == .testGeneration
    }

    private var availableKinds: [String] {
        switch jobType {
        case .flashcardDrafts:
            FlashcardKind.allCases.map(\.rawValue)
        case .testGeneration:
            TestQuestionKind.allCases.map(\.rawValue)
        case .conceptSuggestions:
            ["CONCEPT"]
        default:
            [item.kind]
        }
    }

    private func save() {
        var edited = item
        edited.kind = kind
        edited.title = title.trimmed
        edited.body = bodyText.trimmed
        edited.answer = requiresAnswer ? answer.trimmed : nil
        edited.choices = choices.lines
        edited.objectiveTitles = objectives.lines
        onSave(edited)
        dismiss()
    }
}

private extension LearningAIJobType {
    var displayName: String {
        switch self {
        case .topicSynthesis: "Topic synthesis"
        case .flashcardDrafts: "Flashcard drafts"
        case .testBlueprint: "Test blueprint"
        case .testGeneration: "Practice test"
        case .conceptSuggestions: "Concept suggestions"
        case .weeklyReview: "Weekly review"
        default: rawValue.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    var symbol: String {
        switch self {
        case .flashcardDrafts: "rectangle.stack"
        case .testBlueprint, .testGeneration: "checkmark.square"
        case .conceptSuggestions: "point.3.connected.trianglepath.dotted"
        case .weeklyReview: "calendar.badge.clock"
        default: "sparkles"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var lines: [String] {
        split(whereSeparator: \.isNewline).map(String.init).map(\.trimmed).filter { !$0.isEmpty }
    }
}
