import EpistoriaCore
import SwiftUI

// MARK: - Artifact list view (all AI answers for a note)

struct NoteQueryArtifactsView: View {
    @Bindable var model: AppModel
    let noteId: UUID
    let blocks: [IdentifiedPayload<NoteBlockPayload>]
    let onInsertBlock: (String) -> Void

    @State private var artifacts: [IdentifiedPayload<NoteQueryArtifact>] = []
    @State private var isLoading = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading AI answers…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if artifacts.isEmpty {
                    ContentUnavailableView {
                        Label("No AI answers yet", systemImage: "sparkles")
                    } description: {
                        Text("Use the lasso tool to select a region, then tap Ask to queue a question.")
                    }
                } else {
                    List(artifacts, id: \.id) { artifact in
                        NavigationLink {
                            NoteQueryArtifactDetailView(
                                model: model,
                                artifact: artifact,
                                blocks: blocks,
                                onInsertBlock: { text in
                                    onInsertBlock(text)
                                    dismiss()
                                },
                                onReviewChanged: { updated in
                                    if let idx = artifacts.firstIndex(where: { $0.id == updated.id }) {
                                        artifacts[idx] = updated
                                    }
                                }
                            )
                        } label: {
                            artifactRow(artifact)
                        }
                    }
                }
            }
            .navigationTitle("AI answers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private func artifactRow(_ artifact: IdentifiedPayload<NoteQueryArtifact>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(artifact.payload.question)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
            Text(artifact.payload.response.answer)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            HStack(spacing: 8) {
                Text(artifact.payload.generatedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let state = artifact.payload.reviewState {
                    Text(state.rawValue.capitalized)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        guard let aiJobs = model.aiJobs else {
            isLoading = false
            return
        }
        do {
            artifacts = try await aiJobs.latestNoteQueryArtifacts(noteId: noteId)
        } catch {
            // Non-fatal: show empty state.
        }
        isLoading = false
    }
}

// MARK: - Single artifact detail view

struct NoteQueryArtifactDetailView: View {
    @Bindable var model: AppModel
    let artifact: IdentifiedPayload<NoteQueryArtifact>
    let blocks: [IdentifiedPayload<NoteBlockPayload>]
    let onInsertBlock: (String) -> Void
    let onReviewChanged: (IdentifiedPayload<NoteQueryArtifact>) -> Void

    @State private var editedAnswer = ""
    @State private var isEditing = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Question") {
                Text(artifact.payload.question)
                    .font(.subheadline)
                    .accessibilityLabel("Question: \(artifact.payload.question)")
            }

            Section("Answer") {
                if isEditing {
                    TextEditor(text: $editedAnswer)
                        .frame(minHeight: 160)
                        .accessibilityLabel("Edit answer")
                        .accessibilityIdentifier("note-query-artifact.edit-answer")
                } else {
                    let answer = artifact.payload.editedResponse?.answer ?? artifact.payload.response.answer
                    Text(answer)
                        .font(.body)
                        .textSelection(.enabled)
                }
            }

            if !artifact.payload.response.followUpQuestions.isEmpty {
                Section("Follow-up questions") {
                    ForEach(artifact.payload.response.followUpQuestions, id: \.self) { q in
                        Text(q)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            reviewStateSection

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red).font(.subheadline)
                }
            }
        }
        .navigationTitle("AI answer")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            editedAnswer = artifact.payload.editedResponse?.answer ?? artifact.payload.response.answer
        }
    }

    @ViewBuilder
    private var reviewStateSection: some View {
        Section("Review") {
            if isEditing {
                Button {
                    Task { await saveEdit() }
                } label: {
                    HStack {
                        if isSaving { ProgressView().padding(.trailing, 6) }
                        Text(isSaving ? "Saving…" : "Save edit")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(EpistoriaDesign.ink)
                .disabled(isSaving)
                .accessibilityIdentifier("note-query-artifact.save-edit")

                Button("Cancel edit", role: .cancel) {
                    isEditing = false
                }
            } else {
                if artifact.payload.reviewState == nil {
                    Button {
                        Task { await review(.accepted) }
                    } label: {
                        Label("Accept", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(EpistoriaDesign.ink)
                    .accessibilityIdentifier("note-query-artifact.accept")

                    Button {
                        isEditing = true
                    } label: {
                        Label("Edit answer", systemImage: "pencil")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("note-query-artifact.edit")

                    Button(role: .destructive) {
                        Task { await review(.rejected) }
                    } label: {
                        Label("Reject", systemImage: "xmark")
                            .frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("note-query-artifact.reject")
                } else {
                    HStack {
                        Image(systemName: reviewIcon)
                        Text("Review state: \(artifact.payload.reviewState!.rawValue.capitalized)")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }

                Button {
                    let text = artifact.payload.editedResponse?.answer ?? artifact.payload.response.answer
                    onInsertBlock(text)
                } label: {
                    Label("Insert in note", systemImage: "plus.square.on.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("note-query-artifact.insert")
            }
        }
    }

    private var reviewIcon: String {
        switch artifact.payload.reviewState {
        case .accepted: "checkmark.circle"
        case .edited: "pencil.circle"
        case .rejected: "xmark.circle"
        case .none: "circle"
        }
    }

    // MARK: Actions

    private func review(_ state: AIArtifactReviewState) async {
        guard let store = model.store else { return }
        isSaving = true
        errorMessage = nil
        var updated = artifact
        updated.payload.reviewState = state
        updated.payload.reviewedAt = .now
        do {
            _ = try await store.save(
                id: updated.id,
                payload: updated.payload,
                parentId: artifact.payload.noteId,
                relationIds: artifact.payload.sourceIds
            )
            onReviewChanged(updated)
            model.noteLocalMutation()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }

    private func saveEdit() async {
        guard let store = model.store else { return }
        isSaving = true
        errorMessage = nil
        let trimmed = editedAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Answer cannot be empty."
            isSaving = false
            return
        }
        var updated = artifact
        updated.payload.reviewState = .edited
        updated.payload.reviewedAt = .now
        updated.payload.editedResponse = NoteQueryResponse(
            schemaVersion: artifact.payload.response.schemaVersion,
            answer: trimmed,
            citedSourceIds: artifact.payload.response.citedSourceIds,
            followUpQuestions: artifact.payload.response.followUpQuestions
        )
        do {
            _ = try await store.save(
                id: updated.id,
                payload: updated.payload,
                parentId: artifact.payload.noteId,
                relationIds: artifact.payload.sourceIds
            )
            onReviewChanged(updated)
            isEditing = false
            model.noteLocalMutation()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}
