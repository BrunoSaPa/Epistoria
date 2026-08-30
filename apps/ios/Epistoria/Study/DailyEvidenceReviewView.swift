import EpistoriaCore
import SwiftUI

struct DailyEvidenceReviewView: View {
    @Bindable var model: AppModel
    @State private var queue = DailyEvidenceReviewQueue.empty
    @State private var evidenceById: [UUID: IdentifiedPayload<EvidencePayload>] = [:]
    @State private var isRevealed = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let item = queue.items.first {
                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .firstTextBaseline) {
                            Label(kindTitle(item.kind), systemImage: kindSymbol(item.kind))
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("\(queue.totalDueCount) due")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(item.title)
                            .font(.title2.weight(.semibold))
                        Text(item.prompt)
                            .font(.body)
                            .textSelection(.enabled)
                        Text(item.reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                    .accessibilityElement(children: .contain)
                }

                if let answer = item.answer {
                    Section("Review") {
                        if isRevealed {
                            Text(answer)
                                .textSelection(.enabled)
                            sourceLink(for: item)
                        } else {
                            Button("Reveal saved answer", systemImage: "eye") {
                                isRevealed = true
                            }
                            .accessibilityHint("Shows the saved description or reference answer")
                        }
                    }
                } else {
                    Section("Source") {
                        sourceLink(for: item)
                    }
                }

                Section("How was this review?") {
                    Button("Remembered", systemImage: "checkmark.circle") {
                        Task { await respond(.remembered, to: item) }
                    }
                    Button("Difficult", systemImage: "exclamationmark.circle") {
                        Task { await respond(.difficult, to: item) }
                    }
                    Button("Later", systemImage: "clock") {
                        Task { await respond(.later, to: item) }
                    }
                }
                .disabled(isSaving)
            } else {
                Section {
                    ContentUnavailableView(
                        "Daily review complete",
                        systemImage: "checkmark.circle",
                        description: Text("New saved Evidence, difficult Concepts, and earlier mistakes will appear here when due.")
                    )
                }
            }

            Section("About this review") {
                Text("Epistoria selects this queue on the iPad from your saved records. It does not use AI, send notebook content, or change the original Evidence, Concept, or test attempt.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Daily review")
        .navigationBarTitleDisplayMode(.inline)
        .epistoriaPageBackground()
        .task { await load() }
        .refreshable { await load() }
        .alert("Review problem", isPresented: .constant(errorMessage != nil)) {
            Button("Try again") { Task { await load() } }
            Button("Dismiss", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func sourceLink(for item: DailyEvidenceReviewItem) -> some View {
        if let evidence = item.evidenceIds.compactMap({ evidenceById[$0] }).first {
            NavigationLink {
                ResourceDetailView(
                    model: model,
                    resourceId: evidence.payload.sourceId,
                    initialSourceVersionId: evidence.payload.sourceVersionId,
                    initialPageNumber: evidence.payload.locator.page,
                    highlightText: evidence.payload.excerpt,
                    initialMediaTimeSeconds: evidence.payload.locator.startSeconds,
                    initialHighlightRectangles: evidence.payload.locator.rectangles
                )
            } label: {
                Label("Show exact Source", systemImage: "arrow.up.forward.square")
            }
        } else {
            Text("This item has no linked Source excerpt.")
                .foregroundStyle(.secondary)
        }
    }

    private func respond(_ action: DailyReviewAction, to item: DailyEvidenceReviewItem) async {
        guard let store = model.store else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await store.recordDailyReviewResponse(
                itemKind: item.kind,
                targetId: item.targetId,
                action: action
            )
            model.noteLocalMutation()
            isRevealed = false
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func load() async {
        guard let store = model.store else { return }
        do {
            async let reviewQueue = store.dailyEvidenceReviewQueue(now: .now)
            async let evidence = store.list(EvidencePayload.self)
            let values = try await (reviewQueue, evidence)
            queue = values.0
            evidenceById = Dictionary(uniqueKeysWithValues: values.1.map { ($0.id, $0) })
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func kindTitle(_ kind: DailyReviewItemKind) -> String {
        switch kind {
        case .evidence: "Saved Evidence"
        case .concept: "Difficult Concept"
        case .testMistake: "Earlier mistake"
        }
    }

    private func kindSymbol(_ kind: DailyReviewItemKind) -> String {
        switch kind {
        case .evidence: "quote.bubble"
        case .concept: "point.3.connected.trianglepath.dotted"
        case .testMistake: "arrow.uturn.backward.circle"
        }
    }
}
