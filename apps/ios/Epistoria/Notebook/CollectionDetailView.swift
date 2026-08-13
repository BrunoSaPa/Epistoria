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
    @State private var errorMessage: String?

    var body: some View {
        List {
            if !childCollections.isEmpty {
                Section("Nested collections") {
                    ForEach(childCollections, id: \.id) { child in
                        NavigationLink {
                            CollectionDetailView(model: model, collectionId: child.id)
                        } label: {
                            Label(child.payload.name, systemImage: "folder")
                        }
                    }
                }
            }

            Section("Notes") {
                if notes.isEmpty { Text("No notes linked").foregroundStyle(.secondary) }
                ForEach(notes, id: \.id) { note in
                    NavigationLink(note.payload.title) {
                        NoteEditorView(model: model, noteId: note.id)
                    }
                }
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
        .navigationTitle(collection?.payload.name ?? "Collection")
        .toolbar {
            Menu {
                Button("Link existing item", systemImage: "link.badge.plus") { showAddItem = true }
                Button("Nested collection", systemImage: "folder.badge.plus") { showChildCollection = true }
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
        .task { await load() }
        .refreshable { await load() }
        .alert("Collection error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func load() async {
        guard let store = model.store else { return }
        do {
            collection = try await store.payload(CollectionPayload.self, id: collectionId)
            allCollections = try await store.list(CollectionPayload.self)
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
            resources = loadedResources
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
            model.noteLocalMutation()
            onAdded()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
