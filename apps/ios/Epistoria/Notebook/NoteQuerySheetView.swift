import EpistoriaCore
import SwiftUI

// MARK: - Question sheet (lasso selection → ask AI)

struct NoteQuerySheetView: View {
    @Bindable var model: AppModel
    let noteId: UUID
    let selection: LassoSelection
    let onDismiss: () -> Void

    @State private var question = ""
    @State private var prepared: PreparedNoteQueryRequest?
    @State private var isPreparing = false
    @State private var isSubmitting = false
    @State private var submitted = false
    @State private var errorMessage: String?

    private let maxQuestionLength = 2_000

    var body: some View {
        NavigationStack {
            Form {
                selectionSummarySection
                questionSection
                if prepared == nil && !submitted {
                    prepareSection
                }
                if let prepared, !submitted {
                    disclosureSection(prepared)
                    submitSection(prepared)
                }
                if submitted {
                    submittedSection
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.subheadline)
                    }
                }
            }
            .navigationTitle("Ask about selection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss() }
                }
            }
        }
    }

    // MARK: Sections

    private var selectionSummarySection: some View {
        Section("Selected region") {
            HStack(spacing: 10) {
                Image(systemName: "lasso")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(selection.selectedBlockIds.count) item\(selection.selectedBlockIds.count == 1 ? "" : "s") selected")
                        .font(.subheadline.weight(.medium))
                    if !selection.drawingImagesByBlockId.isEmpty {
                        Text("Includes \(selection.drawingImagesByBlockId.count) visual crop\(selection.drawingImagesByBlockId.count == 1 ? "" : "s") — sent as images")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var questionSection: some View {
        Section {
            TextEditor(text: $question)
                .frame(minHeight: 100, maxHeight: 200)
                .accessibilityLabel("Question about selected region")
                .accessibilityIdentifier("note-query.question")
            HStack {
                Spacer()
                Text("\(question.count) / \(maxQuestionLength)")
                    .font(.caption)
                    .foregroundStyle(question.count > maxQuestionLength - 100 ? EpistoriaDesign.attention : Color.secondary)
            }
        } header: {
            Text("Your question")
        } footer: {
            Text("Review the selected content and provider route before sending. Epistoria does not silently switch providers or processing routes.")
                .font(.caption)
        }
    }

    private var prepareSection: some View {
        Section {
            Button {
                Task { await prepare() }
            } label: {
                HStack {
                    if isPreparing {
                        ProgressView().padding(.trailing, 6)
                    }
                    Text(isPreparing ? "Preparing…" : "Preview what leaves your Mac")
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(
                question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || question.count > maxQuestionLength
                || isPreparing
            )
            .accessibilityIdentifier("note-query.prepare")
        }
    }

    @ViewBuilder
    private func disclosureSection(_ prep: PreparedNoteQueryRequest) -> some View {
        Section("What leaves your Mac") {
            LabeledContent("Selected items", value: "\(prep.selectionCount)")
            LabeledContent("Context items", value: "\(prep.contextCount)")
            if prep.hasImages {
                LabeledContent("Includes images", value: "Yes — selected visuals sent as PNG")
            }
            LabeledContent("Approximate tokens", value: prep.approximateTokens.formatted())
        }
    }

    @ViewBuilder
    private func submitSection(_ prep: PreparedNoteQueryRequest) -> some View {
        Section {
            Button {
                Task { await submit(prep) }
            } label: {
                HStack {
                    if isSubmitting {
                        ProgressView()
                            .padding(.trailing, 6)
                    }
                    Text(isSubmitting ? "Queuing…" : "Approve and queue")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(EpistoriaDesign.ink)
            .disabled(isSubmitting)
            .accessibilityIdentifier("note-query.submit")
        } footer: {
            Text("The answer will appear in the note's AI answers panel after the approved processing route completes.")
                .font(.caption)
        }
    }

    private var submittedSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(EpistoriaDesign.positive)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Question queued")
                        .font(.subheadline.weight(.medium))
                    Text("The approved route will process it when available. Check AI answers in the note toolbar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            Button("Done") { onDismiss() }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("note-query.done")
        }
    }

    // MARK: Actions

    private func prepare() async {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let aiJobs = model.aiJobs else { return }
        isPreparing = true
        errorMessage = nil
        do {
            prepared = try await aiJobs.prepareNoteQuery(
                noteId: noteId,
                selectedBlockIds: selection.selectedBlockIds,
                selectionImagesByBlockId: selection.drawingImagesByBlockId,
                question: question.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } catch {
            errorMessage = error.localizedDescription
        }
        isPreparing = false
    }

    private func submit(_ prep: PreparedNoteQueryRequest) async {
        guard let aiJobs = model.aiJobs else { return }
        isSubmitting = true
        errorMessage = nil
        do {
            _ = try await aiJobs.submitNoteQuery(prep)
            submitted = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isSubmitting = false
    }
}

// MARK: - Preview button behavior: prepare on question commit

extension NoteQuerySheetView {
    // Triggered by the question text changing — auto-prepare after a brief pause.
    // Implemented via .onChange in the parent, but the prepare() function is internal.
    func triggerPrepare() async {
        await prepare()
    }
}
