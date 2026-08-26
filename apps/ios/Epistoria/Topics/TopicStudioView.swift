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
    @State private var testMode = TestMode.comprehensive
    @State private var questionCount = 12
    @State private var usesTimeLimit = false
    @State private var timeLimitMinutes = 30
    @State private var customCoverage = Set(TestCoverageDimension.allCases)
    @State private var detectedObjectives: [DetectedTestObjective] = []
    @State private var selectedObjectiveTitles: Set<String> = []
    @State private var isDetectingObjectives = false
    @State private var prepared: PreparedLearningGenerationRequest?
    @State private var directDisclosure: DirectProviderDisclosure?
    @State private var artifact: IdentifiedPayload<LearningGenerationArtifact>?
    @State private var selectedItemIds: Set<UUID> = []
    @State private var reviewedItems: [UUID: LearningDraftItem] = [:]
    @State private var selectedConceptLinkIds: Set<UUID> = []
    @State private var reviewedConceptLinks: [UUID: ConceptLinkDraft] = [:]
    @State private var reviewedSummary = ""
    @State private var editingItem: LearningDraftItem?
    @State private var editingConceptLink: ConceptLinkDraft?
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
                    Toggle("Include connected knowledge", isOn: $includeConnectedKnowledge)
                    Text(includeConnectedKnowledge
                         ? "Includes Topics connected through the same Areas. The disclosure below shows the final scope."
                         : "Uses this Topic only. This is the default scope.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Review request", systemImage: "doc.text.magnifyingglass") {
                        Task { await prepare() }
                    }
                    .disabled(isWorking || (isTestJob && (requestedObjectiveTitles.isEmpty || effectiveCoverage.isEmpty)))
                }

                if isTestJob {
                    testPlanSection
                }

                if let prepared {
                    Section("Review before sending") {
                        LabeledContent("Excerpts", value: prepared.sourceCount.formatted())
                        LabeledContent("Approximate tokens", value: prepared.approximateTokens.formatted())
                        if let plan = prepared.request.testPlan {
                            LabeledContent("Mode", value: plan.mode.displayName)
                            LabeledContent("Questions", value: plan.questionCount.formatted())
                            LabeledContent("Objectives", value: plan.objectiveTitles.count.formatted())
                            LabeledContent("Coverage", value: plan.coverageDimensions.map(\.displayName).joined(separator: ", "))
                            LabeledContent("Time limit", value: plan.timeLimitMinutes.map { "\($0) min" } ?? "None")
                        }
                        if let disclosure = directDisclosure {
                            LabeledContent("Provider", value: disclosure.provider)
                            LabeledContent("Model", value: disclosure.model)
                            LabeledContent("Destination", value: disclosure.destination)
                            LabeledContent(
                                "Maximum estimate",
                                value: disclosure.maximumEstimatedCostUsd.map {
                                    $0.formatted(.currency(code: "USD"))
                                } ?? "Pricing not configured"
                            )
                        }
                        Label(
                            "The approved excerpts go directly from this iPad to this provider.",
                            systemImage: "hand.raised"
                        )
                            .font(.subheadline)
                        Button("Approve and generate", systemImage: "ipad.and.arrow.forward") {
                            Task { await submit() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(EpistoriaDesign.ink)
                        .disabled(isWorking)
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

                            if artifact.payload.jobType == .conceptSuggestions,
                               !artifact.payload.response.resolvedConceptLinks.isEmpty {
                                Divider()
                                HStack {
                                    Text("Concept connections").font(.headline)
                                    Spacer()
                                    Text("\(selectedConceptLinkIds.count) of \(artifact.payload.response.resolvedConceptLinks.count) selected")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                ForEach(artifact.payload.response.resolvedConceptLinks) { original in
                                    let link = reviewedConceptLinks[original.id] ?? original
                                    HStack(alignment: .top, spacing: 12) {
                                        if artifact.payload.reviewState != .accepted {
                                            Toggle(
                                                "Include connection from \(link.sourceConceptName) to \(link.targetConceptName)",
                                                isOn: conceptLinkSelectionBinding(for: original.id)
                                            )
                                            .labelsHidden()
                                            .disabled(isWorking)
                                        } else {
                                            Image(systemName: selectedConceptLinkIds.contains(original.id)
                                                  ? "checkmark.circle.fill" : "minus.circle")
                                                .foregroundStyle(selectedConceptLinkIds.contains(original.id) ? EpistoriaDesign.ink : .secondary)
                                        }
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text("\(link.sourceConceptName) → \(link.targetConceptName)")
                                                .font(.headline)
                                            Text(link.relation.displayName)
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                            Text(link.rationale)
                                            Label(
                                                "\(link.citedSourceIds.count) citation\(link.citedSourceIds.count == 1 ? "" : "s")",
                                                systemImage: "link"
                                            )
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if artifact.payload.reviewState != .accepted {
                                            Button("Edit", systemImage: "pencil") {
                                                editingConceptLink = link
                                            }
                                            .labelStyle(.iconOnly)
                                            .accessibilityLabel("Edit connection from \(link.sourceConceptName) to \(link.targetConceptName)")
                                            .disabled(isWorking)
                                        }
                                    }
                                    .padding(.vertical, 5)
                                    .opacity(selectedConceptLinkIds.contains(original.id) ? 1 : 0.5)
                                }
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
                                    .disabled(
                                        (selectedItemIds.isEmpty && selectedConceptLinkIds.isEmpty)
                                            || isWorking
                                    )
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
            .sheet(item: $editingConceptLink) { link in
                ConceptLinkDraftEditor(link: link) { edited in
                    reviewedConceptLinks[edited.id] = edited
                    selectedConceptLinkIds.insert(edited.id)
                    editingConceptLink = nil
                    Task { await persistDraftReview() }
                }
            }
            .onChange(of: jobType) {
                prepared = nil
                directDisclosure = nil
                Task { await loadArtifact() }
            }
            .onChange(of: includeConnectedKnowledge) {
                prepared = nil
                directDisclosure = nil
                detectedObjectives = []
                selectedObjectiveTitles = []
            }
            .onChange(of: testMode) {
                prepared = nil
                directDisclosure = nil
                applyTestModeDefaults()
            }
        }
    }

    @ViewBuilder
    private var testPlanSection: some View {
        Section("Test plan") {
            Picker("Mode", selection: $testMode) {
                ForEach(TestMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(testMode.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)

            Stepper("Questions: \(questionCount)", value: $questionCount, in: 1...100)
                .onChange(of: questionCount) { prepared = nil }
            Toggle("Time limit", isOn: $usesTimeLimit)
                .onChange(of: usesTimeLimit) { prepared = nil }
            if usesTimeLimit {
                Stepper("Limit: \(timeLimitMinutes) minutes", value: $timeLimitMinutes, in: 5...600, step: 5)
                    .onChange(of: timeLimitMinutes) { prepared = nil }
            }

            DisclosureGroup("Coverage dimensions (\(effectiveCoverage.count))") {
                ForEach(TestCoverageDimension.allCases, id: \.self) { dimension in
                    Toggle(dimension.displayName, isOn: coverageBinding(for: dimension))
                        .disabled(testMode != .custom)
                }
                if testMode != .custom {
                    Text("Choose Custom to change the coverage dimensions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button("Detect objectives from Topic", systemImage: "scope") {
                Task { await detectObjectives() }
            }
            .disabled(isDetectingObjectives || isWorking)

            if isDetectingObjectives {
                ProgressView("Reading local Topic records…")
            } else if detectedObjectives.isEmpty {
                Text("Detection uses local Concept, Source, note, and unresolved-question titles. Review the results before generation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(detectedObjectives) { objective in
                    Toggle(isOn: objectiveBinding(for: objective.title)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(objective.title)
                            Text("\(objective.origin) · \(objective.supportingRecordCount) supporting record\(objective.supportingRecordCount == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(testMode == .comprehensive)
                }
            }

            TextField("Additional objectives, one per line", text: $objectives, axis: .vertical)
                .onChange(of: objectives) { prepared = nil }

            if requestedObjectiveTitles.isEmpty {
                Label("Add or detect at least one objective before reviewing the request.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let coverageConstraint {
                Label(coverageConstraint, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func prepare() async {
        guard let coordinator = model.aiJobs else {
            errorMessage = "Unlock the notebook before preparing this request."
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let objectiveTitles = requestedObjectiveTitles
            let plan = isTestJob ? TestGenerationPlan(
                mode: testMode,
                questionCount: questionCount,
                timeLimitMinutes: usesTimeLimit ? timeLimitMinutes : nil,
                coverageDimensions: effectiveCoverage,
                objectiveTitles: objectiveTitles
            ) : nil
            let candidate = try await coordinator.prepareTopicGeneration(
                topicId: topicId,
                jobType: jobType,
                objectiveTitles: objectiveTitles,
                testPlan: plan,
                userInstructions: instructions.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                includeConnectedKnowledge: includeConnectedKnowledge
            )
            directDisclosure = try model.directTopicStudioDisclosure(
                approximateInputTokens: candidate.approximateTokens,
                jobType: candidate.request.jobType
            )
            prepared = candidate
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func detectObjectives() async {
        guard let coordinator = model.aiJobs else {
            errorMessage = "Unlock the notebook before detecting objectives."
            return
        }
        isDetectingObjectives = true
        defer { isDetectingObjectives = false }
        do {
            detectedObjectives = try await coordinator.detectTestObjectives(
                topicId: topicId,
                includeConnectedKnowledge: includeConnectedKnowledge
            )
            applyTestModeSelection()
            prepared = nil
            directDisclosure = nil
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private var isTestJob: Bool {
        jobType == .testBlueprint || jobType == .testGeneration
    }

    private var requestedObjectiveTitles: [String] {
        let selected = detectedObjectives
            .filter { selectedObjectiveTitles.contains($0.title) }
            .map(\.title)
        return (selected + objectives.lines).reduce(into: []) { result, title in
            if !result.contains(where: { $0.localizedCaseInsensitiveCompare(title) == .orderedSame }) {
                result.append(title)
            }
        }
    }

    private var effectiveCoverage: [TestCoverageDimension] {
        switch testMode {
        case .comprehensive:
            TestCoverageDimension.allCases
        case .quickCheck:
            [.conceptual, .methodSelection, .verification]
        case .custom:
            TestCoverageDimension.allCases.filter(customCoverage.contains)
        }
    }

    private var coverageConstraint: String? {
        if testMode == .comprehensive, questionCount < requestedObjectiveTitles.count {
            return "There are fewer questions than objectives. Questions may assess related objectives together; any remaining gap must be reported."
        }
        if usesTimeLimit, timeLimitMinutes < questionCount * 2 {
            return "The time limit allows under two minutes per question. This may restrict procedural and integrated coverage."
        }
        if effectiveCoverage.isEmpty {
            return "Select at least one coverage dimension."
        }
        return nil
    }

    private func applyTestModeDefaults() {
        switch testMode {
        case .comprehensive:
            questionCount = max(12, detectedObjectives.count)
        case .quickCheck:
            questionCount = 5
        case .custom:
            questionCount = 10
        }
        applyTestModeSelection()
    }

    private func applyTestModeSelection() {
        switch testMode {
        case .comprehensive:
            selectedObjectiveTitles = Set(detectedObjectives.map(\.title))
        case .quickCheck:
            selectedObjectiveTitles = Set(detectedObjectives.prefix(3).map(\.title))
        case .custom:
            selectedObjectiveTitles = Set(detectedObjectives.map(\.title))
        }
    }

    private func objectiveBinding(for title: String) -> Binding<Bool> {
        Binding(
            get: { selectedObjectiveTitles.contains(title) },
            set: { selected in
                if selected { selectedObjectiveTitles.insert(title) }
                else { selectedObjectiveTitles.remove(title) }
                prepared = nil
            }
        )
    }

    private func coverageBinding(for dimension: TestCoverageDimension) -> Binding<Bool> {
        Binding(
            get: { effectiveCoverage.contains(dimension) },
            set: { selected in
                if selected { customCoverage.insert(dimension) }
                else { customCoverage.remove(dimension) }
                prepared = nil
            }
        )
    }

    private func submit() async {
        guard let prepared, let approvedDisclosure = directDisclosure else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await model.generateTopicStudioDirect(
                prepared,
                approvedRoute: approvedDisclosure.route
            )
            self.prepared = nil
            directDisclosure = nil
            errorMessage = nil
            await loadArtifact()
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

    private var selectedConceptLinks: [ConceptLinkDraft] {
        guard let artifact else { return [] }
        return artifact.payload.response.resolvedConceptLinks.compactMap { original in
            guard selectedConceptLinkIds.contains(original.id) else { return nil }
            return reviewedConceptLinks[original.id] ?? original
        }
    }

    private func configureDraftReview() {
        guard let artifact else {
            selectedItemIds = []
            reviewedItems = [:]
            selectedConceptLinkIds = []
            reviewedConceptLinks = [:]
            reviewedSummary = ""
            return
        }
        let reviewed = artifact.payload.editedResponse
        let items = reviewed?.items ?? artifact.payload.response.items
        selectedItemIds = Set(items.map(\.id))
        reviewedItems = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let conceptLinks = reviewed?.resolvedConceptLinks
            ?? artifact.payload.response.resolvedConceptLinks
        selectedConceptLinkIds = Set(conceptLinks.map(\.id))
        reviewedConceptLinks = Dictionary(uniqueKeysWithValues: conceptLinks.map { ($0.id, $0) })
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

    private func conceptLinkSelectionBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedConceptLinkIds.contains(id) },
            set: { included in
                if included { selectedConceptLinkIds.insert(id) }
                else { selectedConceptLinkIds.remove(id) }
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
        selectedConceptLinkIds = Set(artifact.payload.response.resolvedConceptLinks.map(\.id))
        for link in artifact.payload.response.resolvedConceptLinks where reviewedConceptLinks[link.id] == nil {
            reviewedConceptLinks[link.id] = link
        }
        await persistDraftReview()
    }

    private func clearSelection() async {
        selectedItemIds = []
        selectedConceptLinkIds = []
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
                selectedItems: selectedItems,
                selectedConceptLinks: selectedConceptLinks
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
                    created.conceptLinks > 0 ? "\(created.conceptLinks) Concept connection\(created.conceptLinks == 1 ? "" : "s")" : nil,
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

private struct ConceptLinkDraftEditor: View {
    @Environment(\.dismiss) private var dismiss
    let link: ConceptLinkDraft
    let onSave: (ConceptLinkDraft) -> Void

    @State private var sourceName: String
    @State private var targetName: String
    @State private var relation: ConceptLinkKind
    @State private var rationale: String

    init(link: ConceptLinkDraft, onSave: @escaping (ConceptLinkDraft) -> Void) {
        self.link = link
        self.onSave = onSave
        _sourceName = State(initialValue: link.sourceConceptName)
        _targetName = State(initialValue: link.targetConceptName)
        _relation = State(initialValue: link.relation)
        _rationale = State(initialValue: link.rationale)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    TextField("From Concept", text: $sourceName)
                    TextField("To Concept", text: $targetName)
                    Picker("Relationship", selection: $relation) {
                        ForEach(ConceptLinkKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    TextField("Evidence-grounded reason", text: $rationale, axis: .vertical)
                }
                Section("Evidence") {
                    Label(
                        "\(link.citedSourceIds.count) source citation\(link.citedSourceIds.count == 1 ? "" : "s") retained",
                        systemImage: "link"
                    )
                    Text("Citations are fixed during review. Exclude the connection if its evidence does not support it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Edit Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(
                            sourceName.trimmed.isEmpty
                                || targetName.trimmed.isEmpty
                                || rationale.trimmed.isEmpty
                        )
                }
            }
        }
    }

    private func save() {
        var edited = link
        let sourceChanged = edited.sourceConceptName != sourceName.trimmed
        let targetChanged = edited.targetConceptName != targetName.trimmed
        edited.sourceConceptName = sourceName.trimmed
        edited.targetConceptName = targetName.trimmed
        if sourceChanged { edited.sourceConceptId = nil }
        if targetChanged { edited.targetConceptId = nil }
        edited.relation = relation
        edited.rationale = rationale.trimmed
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

private extension TestMode {
    var displayName: String {
        switch self {
        case .comprehensive: "Comprehensive"
        case .quickCheck: "Quick Check"
        case .custom: "Custom"
        }
    }

    var explanation: String {
        switch self {
        case .comprehensive:
            "Uses every selected objective and coverage dimension. Any unsupported or omitted requirement is reported as a gap."
        case .quickCheck:
            "Creates a short check of core concepts, method selection, and verification. It does not claim complete Topic coverage."
        case .custom:
            "Uses only the objectives, coverage dimensions, question count, and time limit you select."
        }
    }
}

private extension TestCoverageDimension {
    var displayName: String {
        switch self {
        case .prerequisite: "Prerequisites"
        case .conceptual: "Concepts"
        case .methodSelection: "Method selection"
        case .procedural: "Procedure"
        case .verification: "Verification"
        case .errorAnalysis: "Error analysis"
        case .integrated: "Integrated application"
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
