import EpistoriaCore
import SwiftUI

struct ListDetailView: View {
    @Bindable var model: AppModel
    let listId: UUID

    @State private var collection: IdentifiedPayload<ListPayload>?
    @State private var notes: [IdentifiedPayload<NotePayload>] = []
    @State private var resources: [IdentifiedPayload<SourcePayload>] = []
    @State private var showAddItem = false
    @State private var showEditList = false
    @State private var showArchivedItems = false
    @State private var pendingUnlinkNote: IdentifiedPayload<NotePayload>?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                if visibleNotes.isEmpty { Text("No notes in this view").foregroundStyle(.secondary) }
                ForEach(visibleNotes, id: \.id) { note in
                    NavigationLink {
                        NoteEditorView(
                            model: model,
                            noteId: note.id,
                            onLifecycleChanged: { Task { await load() } }
                        )
                    } label: {
                        NoteReviewPreview(
                            model: model,
                            note: note,
                            context: "List · \(collection?.payload.name ?? "Untitled")"
                        )
                    }
                    .swipeActions {
                        Button("Remove from List", systemImage: "link.badge.minus", role: .destructive) {
                            pendingUnlinkNote = note
                        }
                    }
                    .contextMenu {
                        Button("Remove from List", systemImage: "link.badge.minus", role: .destructive) {
                            pendingUnlinkNote = note
                        }
                    }
                }
            } header: {
                Text("Notes")
            } footer: {
                Text("Linking does not move or duplicate material. Archived items are hidden unless Show archived items is enabled in List options.")
            }

            Section("Sources") {
                if visibleSources.isEmpty { Text("No Sources in this view").foregroundStyle(.secondary) }
                ForEach(visibleSources, id: \.id) { resource in
                    NavigationLink(resource.payload.title) {
                        SourceDetailView(model: model, sourceId: resource.id)
                    }
                }
            }
        }
        .navigationTitle(collection?.payload.name ?? "List")
        .toolbar {
            Menu {
                Toggle("Show archived items", isOn: $showArchivedItems)
                Button("Edit List", systemImage: "slider.horizontal.3") { showEditList = true }
                Button("Link existing item", systemImage: "link.badge.plus") { showAddItem = true }
                    .disabled(collection?.payload.archivedAt != nil)
            } label: { Label("List options", systemImage: "ellipsis.circle") }
        }
        .sheet(isPresented: $showAddItem) {
            AddListItemView(model: model, listId: listId) { Task { await load() } }
        }
        .sheet(isPresented: $showEditList) {
            if let collection {
                EditListView(
                    model: model,
                    list: collection
                ) {
                    showEditList = false
                    Task { await load() }
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog(
            "Remove this note from the List?",
            isPresented: Binding(
                get: { pendingUnlinkNote != nil },
                set: { if !$0 { pendingUnlinkNote = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove from List", role: .destructive) {
                guard let pendingUnlinkNote else { return }
                Task { await unlinkNote(pendingUnlinkNote.id) }
                self.pendingUnlinkNote = nil
            }
            Button("Cancel", role: .cancel) { pendingUnlinkNote = nil }
        } message: {
            Text("The note remains in the notebook and in any other Lists or Sessions.")
        }
        .alert("List error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func load() async {
        guard let store = model.store else { return }
        do {
            let trashedIds = try await store.trashedTargetIds()
            collection = try await store.payload(ListPayload.self, id: listId)
            let links = try await store.list(
                RelationPayload.self,
                parentId: listId,
                entityTypeOverride: .listItem
            )
            var loadedNotes: [IdentifiedPayload<NotePayload>] = []
            var loadedResources = try await store.sourcesInList(id: listId)
            let linkedIds = Set(links.filter { $0.payload.leftId == listId }.map(\.payload.rightId))
            for id in linkedIds where !trashedIds.contains(id) {
                guard let entity = try await store.database.entity(id: id), !entity.tombstone else { continue }
                if entity.entityType == .note,
                   let note = try? await store.payload(NotePayload.self, id: id) {
                    loadedNotes.append(note)
                } else if entity.entityType == .source,
                          let resource = try? await store.payload(SourcePayload.self, id: id) {
                    if !loadedResources.contains(where: { $0.id == resource.id }) { loadedResources.append(resource) }
                }
            }
            notes = loadedNotes
                .filter { !trashedIds.contains($0.id) }
                .sorted { $0.payload.updatedAt > $1.payload.updatedAt }
            resources = loadedResources.filter { !trashedIds.contains($0.id) }
        } catch { errorMessage = error.localizedDescription }
    }

    private var visibleNotes: [IdentifiedPayload<NotePayload>] {
        notes.filter { showArchivedItems || $0.payload.archivedAt == nil }
    }

    private var visibleSources: [IdentifiedPayload<SourcePayload>] {
        resources.filter { showArchivedItems || $0.payload.archivedAt == nil }
    }

    private func unlinkNote(_ noteId: UUID) async {
        guard let store = model.store else { return }
        do {
            try await store.unlinkNote(noteId, fromList: listId)
            model.noteLocalMutation()
            await load()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct EditListView: View {
    @Bindable var model: AppModel
    let list: IdentifiedPayload<ListPayload>
    let onSaved: () -> Void
    @State private var name: String
    @State private var archived: Bool
    @State private var errorMessage: String?

    init(
        model: AppModel,
        list: IdentifiedPayload<ListPayload>,
        onSaved: @escaping () -> Void
    ) {
        self.model = model
        self.list = list
        self.onSaved = onSaved
        _name = State(initialValue: list.payload.name)
        _archived = State(initialValue: list.payload.archivedAt != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("List name", text: $name)
                Toggle("Archived", isOn: $archived)
                Text("Archiving a List preserves every linked note and Source.")
                    .font(.caption).foregroundStyle(.secondary)
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle("Edit List")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onSaved() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() async {
        guard let store = model.store else { return }
        do {
            try await store.updateList(
                id: list.id,
                name: name,
                archived: archived
            )
            model.noteLocalMutation()
            onSaved()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct AddListItemView: View {
    private enum Kind: String, CaseIterable, Identifiable {
        case note = "Note"
        case resource = "Source"
        var id: Self { self }
    }

    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let listId: UUID
    let onAdded: () -> Void

    @State private var kind = Kind.note
    @State private var notes: [IdentifiedPayload<NotePayload>] = []
    @State private var resources: [IdentifiedPayload<SourcePayload>] = []
    @State private var selection: UUID?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Picker("Item type", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Item", selection: $selection) {
                    Text("Choose…").tag(UUID?.none)
                    if kind == .note {
                        ForEach(notes, id: \.id) { Text($0.payload.title).tag(Optional($0.id)) }
                    } else {
                        ForEach(resources, id: \.id) { Text($0.payload.title).tag(Optional($0.id)) }
                    }
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle("Link to List")
            .onChange(of: kind) { _, _ in selection = nil }
            .task { await load() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Link") { Task { await add() } }.disabled(selection == nil)
                }
            }
        }
    }

    private func load() async {
        guard let store = model.store else { return }
        do {
            async let loadedNotes = store.list(NotePayload.self)
            async let loadedResources = store.list(SourcePayload.self)
            async let loadedLinks = store.list(
                RelationPayload.self,
                parentId: listId,
                entityTypeOverride: .listItem
            )
            let (allNotes, allResources, links) = try await (
                loadedNotes,
                loadedResources,
                loadedLinks
            )
            let linked = Set(links.map(\.payload.rightId))
            let trashed = try await store.trashedTargetIds()
            notes = allNotes.filter {
                !linked.contains($0.id) && !trashed.contains($0.id) && $0.payload.archivedAt == nil
            }
            resources = allResources.filter {
                !linked.contains($0.id) && !$0.payload.listIds.contains(listId)
                    && !trashed.contains($0.id) && $0.payload.archivedAt == nil
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func add() async {
        guard let store = model.store, let selection else { return }
        do {
            if kind == .note {
                _ = try await store.linkNote(selection, toList: listId)
            } else {
                let source = try await store.payload(SourcePayload.self, id: selection).payload
                var memberships = try await store.sourceListIds(id: selection)
                memberships.insert(listId)
                try await store.updateSource(
                    id: selection, title: source.title, primaryTopicId: source.primaryTopicId,
                    relatedTopicIds: source.relatedTopicIds, listIds: Array(memberships),
                    archived: source.archivedAt != nil
                )
            }
            model.noteLocalMutation()
            onAdded()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
