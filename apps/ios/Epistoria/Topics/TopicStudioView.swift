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
                        Text(artifact.payload.response.summary)
                        ForEach(artifact.payload.response.items) { item in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.title).font(.headline)
                                Text(item.body)
                                if let answer = item.answer, !answer.isEmpty {
                                    Text(answer).font(.subheadline).foregroundStyle(.secondary)
                                }
                                Text("\(item.citedSourceIds.count) cited item\(item.citedSourceIds.count == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                        if !artifact.payload.response.coverageGaps.isEmpty {
                            LabeledContent(
                                "Coverage gaps",
                                value: artifact.payload.response.coverageGaps.joined(separator: ", ")
                            )
                        }
                        HStack {
                            Button("Accept draft", systemImage: "checkmark.circle") {
                                Task { await review(.accepted) }
                            }
                            Button("Reject", systemImage: "xmark.circle", role: .destructive) {
                                Task { await review(.rejected) }
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
        } catch { errorMessage = error.localizedDescription }
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
}
