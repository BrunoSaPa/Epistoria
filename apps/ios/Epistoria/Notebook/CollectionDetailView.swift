import EpistoriaCore
import SwiftUI

struct CollectionDetailView: View {
    @Bindable var model: AppModel
    let collectionId: UUID

    @State private var collection: IdentifiedPayload<CollectionPayload>?
    @State private var allCollections: [IdentifiedPayload<CollectionPayload>] = []
    @State private var childCollections: [IdentifiedPayload<CollectionPayload>] = []
    @State private var notes: [IdentifiedPayload<NotePayload>] = []
    @State private var resources: [IdentifiedPayload<ResourcePayload>] = []
    @State private var showAddItem = false
    @State private var showChildCollection = false
    @State private var showEditList = false
    @State private var pendingUnlinkNote: IdentifiedPayload<NotePayload>?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if !childCollections.isEmpty {
                Section("Nested Lists") {
                    ForEach(childCollections, id: \.id) { child in
                        NavigationLink {
                            CollectionDetailView(model: model, collectionId: child.id)
                        } label: {
                            Label(child.payload.name, systemImage: "folder")
                        }
                    }
                }
            }

            Section {
                if notes.isEmpty { Text("No notes linked").foregroundStyle(.secondary) }
                ForEach(notes, id: \.id) { note in
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
                Text("A List groups reusable material. Linking a note does not move or duplicate it.")
            }

            Section("Resources") {
                if resources.isEmpty { Text("No resources linked").foregroundStyle(.secondary) }
                ForEach(resources, id: \.id) { resource in
                    NavigationLink(resource.payload.title) {
                        ResourceDetailView(model: model, resourceId: resource.id)
                    }
                }
            }
        }
        .navigationTitle(collection?.payload.name ?? "List")
        .toolbar {
            Menu {
                Button("Edit List", systemImage: "slider.horizontal.3") { showEditList = true }
                Button("Link existing item", systemImage: "link.badge.plus") { showAddItem = true }
                    .disabled(collection?.payload.archivedAt != nil)
                Button("Nested List", systemImage: "folder.badge.plus") { showChildCollection = true }
                    .disabled(collection?.payload.archivedAt != nil)
            } label: { Label("Add", systemImage: "plus") }
        }
        .sheet(isPresented: $showAddItem) {
            AddCollectionItemView(model: model, collectionId: collectionId) { Task { await load() } }
        }
        .sheet(isPresented: $showChildCollection) {
            NewCollectionView(
                model: model,
                collections: allCollections,
                fixedParentId: collectionId
            ) { Task { await load() } }
        }
        .sheet(isPresented: $showEditList) {
            if let collection {
                EditListView(
                    model: model,
                    list: collection,
                    allLists: allCollections
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
            collection = try await store.payload(CollectionPayload.self, id: collectionId)
            allCollections = try await store.list(CollectionPayload.self)
                .filter { !trashedIds.contains($0.id) }
            childCollections = allCollections.filter { $0.payload.parentCollectionId == collectionId }
            let links = try await store.list(
                RelationPayload.self,
                parentId: collectionId,
                entityTypeOverride: .collectionItem
            )
            var loadedNotes: [IdentifiedPayload<NotePayload>] = []
            var loadedResources: [IdentifiedPayload<ResourcePayload>] = []
            for link in links where link.payload.leftId == collectionId {
                if let note = try? await store.payload(NotePayload.self, id: link.payload.rightId) {
                    loadedNotes.append(note)
                } else if let resource = try? await store.payload(ResourcePayload.self, id: link.payload.rightId) {
                    loadedResources.append(resource)
                }
            }
            notes = loadedNotes
                .filter { !trashedIds.contains($0.id) }
                .sorted { $0.payload.updatedAt > $1.payload.updatedAt }
            resources = loadedResources.filter { !trashedIds.contains($0.id) }
        } catch { errorMessage = error.localizedDescription }
    }

    private func unlinkNote(_ noteId: UUID) async {
        guard let store = model.store else { return }
        do {
            try await store.unlinkNote(noteId, fromCollection: collectionId)
            model.noteLocalMutation()
            await load()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct EditListView: View {
    @Bindable var model: AppModel
    let list: IdentifiedPayload<CollectionPayload>
    let allLists: [IdentifiedPayload<CollectionPayload>]
    let onSaved: () -> Void
    @State private var name: String
    @State private var parentId: UUID?
    @State private var archived: Bool
    @State private var errorMessage: String?

    init(
        model: AppModel,
        list: IdentifiedPayload<CollectionPayload>,
        allLists: [IdentifiedPayload<CollectionPayload>],
        onSaved: @escaping () -> Void
    ) {
        self.model = model
        self.list = list
        self.allLists = allLists
        self.onSaved = onSaved
        _name = State(initialValue: list.payload.name)
        _parentId = State(initialValue: list.payload.parentCollectionId)
        _archived = State(initialValue: list.payload.archivedAt != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("List name", text: $name)
                Picker("Inside", selection: $parentId) {
                    Text("Top level").tag(UUID?.none)
                    ForEach(allLists.filter { $0.id != list.id && $0.payload.archivedAt == nil }, id: \.id) {
                        Text($0.payload.name).tag(Optional($0.id))
                    }
                }
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
                parentListId: parentId,
                archived: archived
            )
            model.noteLocalMutation()
            onSaved()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct AddCollectionItemView: View {
    private enum Kind: String, CaseIterable, Identifiable {
        case note = "Note"
        case resource = "Resource"
        var id: Self { self }
    }

    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let collectionId: UUID
    let onAdded: () -> Void

    @State private var kind = Kind.note
    @State private var notes: [IdentifiedPayload<NotePayload>] = []
    @State private var resources: [IdentifiedPayload<ResourcePayload>] = []
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
            .navigationTitle("Link to collection")
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
            async let loadedResources = store.list(ResourcePayload.self)
            async let loadedLinks = store.list(
                RelationPayload.self,
                parentId: collectionId,
                entityTypeOverride: .collectionItem
            )
            let (allNotes, allResources, links) = try await (
                loadedNotes,
                loadedResources,
                loadedLinks
            )
            let linked = Set(links.map(\.payload.rightId))
            notes = allNotes.filter { !linked.contains($0.id) }
            resources = allResources.filter { !linked.contains($0.id) }
        } catch { errorMessage = error.localizedDescription }
    }

    private func add() async {
        guard let store = model.store, let selection else { return }
        do {
            if kind == .note {
                _ = try await store.linkNote(selection, toCollection: collectionId)
            } else {
                let relation = RelationPayload(
                    kind: .collectionItem,
                    leftId: collectionId,
                    rightId: selection
                )
                _ = try await store.save(
                    payload: relation,
                    parentId: collectionId,
                    relationIds: [collectionId, selection],
                    entityTypeOverride: .collectionItem
                )
            }
            model.noteLocalMutation()
            onAdded()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
