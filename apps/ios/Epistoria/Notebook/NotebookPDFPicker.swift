import EpistoriaCore
import SwiftUI

struct NotebookPDFPicker: View {
    let model: AppModel
    let onSelect: (NotebookPDFTarget) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var sources: [IdentifiedPayload<SourcePayload>] = []
    @State private var cursor: EntityPageCursor?
    @State private var loading = false
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(sources, id: \.id) { source in
                        Button {
                            guard let versionId = source.payload.currentVersionId else { return }
                            onSelect(NotebookPDFTarget(sourceId: source.id, versionId: versionId))
                        } label: {
                            Label(source.payload.title, systemImage: "doc.richtext")
                        }
                        .accessibilityIdentifier("note.source.pick.\(source.id.uuidString)")
                    }
                } footer: {
                    Text("Opens the saved version beside your note. Download unavailable PDFs in Library first.")
                }
                if loading { ProgressView("Loading sources…") }
                if let error { Text(error).foregroundStyle(.secondary) }
                if sources.isEmpty, !loading, loaded {
                    Text(cursor == nil ? "No available PDF sources. Import a PDF in Library."
                         : "No PDFs in the sources loaded so far. Load more to continue.")
                        .foregroundStyle(.secondary)
                }
                if cursor != nil || error != nil {
                    Button(error == nil ? "Load more sources" : "Retry") { Task { await load() } }
                        .disabled(loading)
                        .accessibilityIdentifier("note.source.load-more")
                }
            }
            .navigationTitle("Open PDF beside note")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task { if !loaded { await load() } }
        }
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            guard let store = model.store else { throw StoreError.entityNotFound }
            let page = try await store.listPage(SourcePayload.self, limit: 30, after: cursor)
            try Task.checkCancellation()
            sources.append(contentsOf: page.items.filter { item in
                item.payload.sourceType == .pdf && item.payload.currentVersionId != nil
                    && item.payload.archivedAt == nil && !sources.contains(where: { $0.id == item.id })
            })
            cursor = page.nextCursor
            loaded = true
            error = nil
        } catch is CancellationError { return }
        catch {
            guard !Task.isCancelled else { return }
            self.error = "Sources could not be loaded. Retry after unlocking the notebook."
        }
    }
}
