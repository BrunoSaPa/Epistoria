import EpistoriaCore
import SwiftUI

struct NotebookView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case notes = "Notes"
        case collections = "Lists"
        case archivedNotes = "Archived Notes"
        case archivedLists = "Archived Lists"
        var id: Self { self }
    }

    private enum Destination: Hashable {
        case note(UUID)
    }

    @Bindable var model: AppModel
    @State private var notes: [IdentifiedPayload<NotePayload>] = []
    @State private var archivedNotes: [IdentifiedPayload<NotePayload>] = []
    @State private var collections: [IdentifiedPayload<CollectionPayload>] = []
    @State private var sessions: [IdentifiedPayload<StudySessionPayload>] = []
    @State private var organizationByNoteId: [UUID: NoteOrganizationSummary] = [:]
    @State private var mode = Mode.notes
    @State private var showNewNote = false
    @State private var showNewCollection = false
    @State private var destination: Destination?
    @State private var createdNotePendingNavigation: UUID?
    @State private var pendingArchive: IdentifiedPayload<NotePayload>?
    @State private var pendingTrashNote: IdentifiedPayload<NotePayload>?
    @State private var pendingTrashList: IdentifiedPayload<CollectionPayload>?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if mode == .notes && notes.isEmpty {
                    ContentUnavailableView {
                        Label("A quiet notebook", systemImage: "book.pages")
                    } description: {
                        Text("Create a note, then write freely, place text, and annotate images on one page.")
                    } actions: {
                        Button("Create your first note") { showNewNote = true }
                            .buttonStyle(.borderedProminent)
                            .tint(EpistoriaDesign.ink)
                    }
                } else if mode == .notes {
                    List(notes, id: \.id) { note in
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
                                context: organizationByNoteId[note.id]?.label
                                    ?? "Unassigned · Organize later"
                            )
                        }
                        .accessibilityIdentifier("notebook.note.\(note.id.uuidString)")
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button(note.payload.pinnedAt == nil ? "Pin" : "Unpin", systemImage: note.payload.pinnedAt == nil ? "pin" : "pin.slash") {
                                Task { await setPinned(note, pinned: note.payload.pinnedAt == nil) }
                            }
                            .tint(EpistoriaDesign.ink)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Trash", systemImage: "trash", role: .destructive) {
                                pendingTrashNote = note
                            }
                            Button("Archive", systemImage: "archivebox") {
                                pendingArchive = note
                            }
                            .tint(.gray)
                        }
                    }
                } else if mode == .archivedNotes && archivedNotes.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing archived", systemImage: "archivebox")
                    } description: {
                        Text("Archived notes stay encrypted and searchable. Move a note here when you want it out of your active notebook.")
                    }
                } else if mode == .archivedNotes {
                    List(archivedNotes, id: \.id) { note in
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
                                context: "Archived · \(organizationByNoteId[note.id]?.label ?? "Unassigned")"
                            )
                        }
                        .accessibilityIdentifier("notebook.archived-note.\(note.id.uuidString)")
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button("Trash", systemImage: "trash", role: .destructive) {
                                pendingTrashNote = note
                            }
                            Button("Restore", systemImage: "arrow.uturn.backward") {
                                Task { await setArchived(note, archived: false) }
                            }
                            .tint(EpistoriaDesign.accent)
                        }
                    }
                } else if mode == .collections && activeCollections.isEmpty {
                    ContentUnavailableView {
                        Label("No lists yet", systemImage: "folder")
                    } description: {
                        Text("Lists are optional cross-topic groups. An item can belong to several lists without being duplicated.")
                    } actions: {
                        Button("Create a list") { showNewCollection = true }
                            .buttonStyle(.borderedProminent)
                            .tint(EpistoriaDesign.ink)
                    }
                } else if mode == .collections {
                    List {
                        Section {
                            Label("Lists group notes and sources across Topics. They are optional and never duplicate the underlying item.", systemImage: "folder")
                                .font(.subheadline)
                                .foregroundStyle(EpistoriaDesign.mutedInk)
                        }
                        Section("Lists") {
                            ForEach(activeCollections.filter { $0.payload.parentCollectionId == nil }, id: \.id) { collection in
                                NavigationLink {
                                    CollectionDetailView(model: model, collectionId: collection.id)
                                } label: {
                                    Label(collection.payload.name, systemImage: "folder")
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button("Trash", systemImage: "trash", role: .destructive) {
                                        pendingTrashList = collection
                                    }
                                    Button("Archive", systemImage: "archivebox") {
                                        Task { await setListArchived(collection, archived: true) }
                                    }
                                    .tint(.gray)
                                }
                            }
                        }
                    }
                } else if archivedCollections.isEmpty {
                    ContentUnavailableView {
                        Label("No archived Lists", systemImage: "archivebox")
                    } description: {
                        Text("Archived Lists keep their links and can be restored here.")
                    }
                } else {
                    List(archivedCollections, id: \.id) { collection in
                        NavigationLink {
                            CollectionDetailView(model: model, collectionId: collection.id)
                        } label: {
                            Label(collection.payload.name, systemImage: "folder")
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button("Trash", systemImage: "trash", role: .destructive) {
                                pendingTrashList = collection
                            }
                            Button("Restore", systemImage: "arrow.uturn.backward") {
                                Task { await setListArchived(collection, archived: false) }
                            }
                            .tint(EpistoriaDesign.accent)
                        }
                    }
                }
            }
            .navigationTitle("Notebook")
            .epistoriaPageBackground()
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Notebook view", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 390)
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Note", systemImage: "square.and.pencil") { showNewNote = true }
                        Button("List", systemImage: "folder.badge.plus") { showNewCollection = true }
                    } label: { Label("New", systemImage: "plus") }
                }
            }
            .sheet(isPresented: $showNewNote, onDismiss: openCreatedNoteIfNeeded) {
                NewNoteView(model: model) { id in
                    createdNotePendingNavigation = id
                }
            }
            .sheet(isPresented: $showNewCollection) {
                NewCollectionView(model: model, collections: collections) { Task { await load() } }
            }
            .task { await load() }
            .refreshable { await load() }
            .navigationDestination(item: $destination) { destination in
                switch destination {
                case let .note(id):
                    NoteEditorView(
                        model: model,
                        noteId: id,
                        onLifecycleChanged: { Task { await load() } }
                    )
                }
            }
            .confirmationDialog(
                "Archive this note?",
                isPresented: Binding(
                    get: { pendingArchive != nil },
                    set: { if !$0 { pendingArchive = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Move to Archive") {
                    guard let pendingArchive else { return }
                    Task { await setArchived(pendingArchive, archived: true) }
                    self.pendingArchive = nil
                }
                Button("Cancel", role: .cancel) { pendingArchive = nil }
            } message: {
                Text("The note stays encrypted and can be restored from the Archived tab.")
            }
            .confirmationDialog(
                "Move this note to Trash?",
                isPresented: Binding(
                    get: { pendingTrashNote != nil },
                    set: { if !$0 { pendingTrashNote = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Move to Trash", role: .destructive) {
                    guard let note = pendingTrashNote else { return }
                    Task { await moveNoteToTrash(note) }
                    pendingTrashNote = nil
                }
                Button("Cancel", role: .cancel) { pendingTrashNote = nil }
            } message: {
                Text("The note and its pages stay encrypted until you empty Trash manually.")
            }
            .confirmationDialog(
                "Move this List to Trash?",
                isPresented: Binding(
                    get: { pendingTrashList != nil },
                    set: { if !$0 { pendingTrashList = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Move to Trash", role: .destructive) {
                    guard let list = pendingTrashList else { return }
                    Task { await moveListToTrash(list) }
                    pendingTrashList = nil
                }
                Button("Cancel", role: .cancel) { pendingTrashList = nil }
            } message: {
                Text("The List and its links stay encrypted until you empty Trash manually.")
            }
            .alert("Notebook error", isPresented: .constant(errorMessage != nil)) {
                Button("Try again") { Task { await load() } }
                Button("Dismiss", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func load() async {
        guard let store = model.store else { return }
        do {
            async let loadedNotes = store.list(NotePayload.self)
            async let loadedCollections = store.list(CollectionPayload.self)
            async let loadedSessions = store.list(StudySessionPayload.self)
            async let loadedTrash = store.trashedTargetIds()
            let result = try await (loadedNotes, loadedCollections, loadedSessions, loadedTrash)
            notes = result.0
                .filter { $0.payload.archivedAt == nil && !result.3.contains($0.id) }
                .sorted(by: noteSort)
            archivedNotes = result.0
                .filter { $0.payload.archivedAt != nil && !result.3.contains($0.id) }
                .sorted { ($0.payload.archivedAt ?? .distantPast) > ($1.payload.archivedAt ?? .distantPast) }
            collections = result.1
                .filter { !result.3.contains($0.id) }
                .sorted { $0.payload.name.localizedCaseInsensitiveCompare($1.payload.name) == .orderedAscending }
            sessions = result.2.sorted { $0.payload.startedAt > $1.payload.startedAt }
            organizationByNoteId = try await NoteOrganizationIndex.load(
                store: store,
                notes: result.0,
                collections: result.1,
                sessions: result.2
            )
        }
        catch { errorMessage = error.localizedDescription }
    }

    private func noteSort(
        _ left: IdentifiedPayload<NotePayload>,
        _ right: IdentifiedPayload<NotePayload>
    ) -> Bool {
        switch (left.payload.pinnedAt, right.payload.pinnedAt) {
        case let (leftDate?, rightDate?): return leftDate > rightDate
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return left.payload.updatedAt > right.payload.updatedAt
        }
    }

    private func setPinned(_ note: IdentifiedPayload<NotePayload>, pinned: Bool) async {
        guard let store = model.store else { return }
        var changed = note.payload
        changed.schemaVersion = "note/v4"
        changed.pinnedAt = pinned ? .now : nil
        changed.updatedAt = .now
        do {
            _ = try await store.save(
                id: note.id,
                payload: changed,
                parentId: changed.courseId ?? changed.studySessionId,
                relationIds: [changed.courseId, changed.studySessionId].compactMap(\.self)
            )
            model.noteLocalMutation()
            await load()
        } catch { errorMessage = error.localizedDescription }
    }

    private func moveNoteToTrash(_ note: IdentifiedPayload<NotePayload>) async {
        guard let store = model.store else { return }
        do {
            _ = try await store.moveToTrash(
                targetId: note.id,
                targetType: .note,
                displayName: note.payload.title
            )
            model.noteLocalMutation()
            await load()
        } catch { errorMessage = error.localizedDescription }
    }

    private func moveListToTrash(_ list: IdentifiedPayload<CollectionPayload>) async {
        guard let store = model.store else { return }
        do {
            _ = try await store.moveToTrash(
                targetId: list.id,
                targetType: .collection,
                displayName: list.payload.name
            )
            model.noteLocalMutation()
            await load()
        } catch { errorMessage = error.localizedDescription }
    }

    private func setArchived(_ note: IdentifiedPayload<NotePayload>, archived: Bool) async {
        guard let store = model.store else { return }
        var changed = note
        changed.payload.archivedAt = archived ? .now : nil
        changed.payload.updatedAt = .now
        do {
            _ = try await store.save(
                id: changed.id,
                payload: changed.payload,
                parentId: changed.payload.courseId ?? changed.payload.studySessionId,
                relationIds: [changed.payload.courseId, changed.payload.studySessionId].compactMap(\.self)
            )
            model.noteLocalMutation()
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var activeCollections: [IdentifiedPayload<CollectionPayload>] {
        collections.filter { $0.payload.archivedAt == nil }
    }

    private var archivedCollections: [IdentifiedPayload<CollectionPayload>] {
        collections.filter { $0.payload.archivedAt != nil }
    }

    private func setListArchived(_ list: IdentifiedPayload<CollectionPayload>, archived: Bool) async {
        guard let store = model.store else { return }
        do {
            try await store.updateList(
                id: list.id,
                name: list.payload.name,
                parentListId: list.payload.parentCollectionId,
                archived: archived
            )
            model.noteLocalMutation()
            await load()
        } catch { errorMessage = error.localizedDescription }
    }

    private func openCreatedNoteIfNeeded() {
        guard let id = createdNotePendingNavigation else { return }
        createdNotePendingNavigation = nil
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            await load()
            destination = .note(id)
        }
    }
}

struct NewNoteView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var errorMessage: String?
    let courseId: UUID?
    let onCreated: (UUID) -> Void

    init(
        model: AppModel,
        courseId: UUID? = nil,
        onCreated: @escaping (UUID) -> Void
    ) {
        self.model = model
        self.courseId = courseId
        self.onCreated = onCreated
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Note title", text: $title)
                        .font(.title3)
                } footer: {
                    Text("This note starts unassigned. Add it to a Topic, List, or study session later.")
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle("New note")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            do {
                                guard let store = model.store else { return }
                                let id = try await store.createNote(
                                    title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                    courseId: courseId,
                                    canvas: NoteCanvasConfiguration(
                                        pageFormat: model.workspacePreferences.defaultPageFormat,
                                        orientation: model.workspacePreferences.defaultPageOrientation,
                                        paperStyle: model.workspacePreferences.defaultPaperStyle,
                                        paperColor: model.workspacePreferences.defaultPaperColor
                                    )
                                )
                                model.noteLocalMutation()
                                onCreated(id)
                                dismiss()
                            } catch { errorMessage = error.localizedDescription }
                        }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

struct NewCollectionView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let collections: [IdentifiedPayload<CollectionPayload>]
    var fixedParentId: UUID?
    let onCreated: () -> Void

    @State private var name = ""
    @State private var parentId: UUID?
    @State private var errorMessage: String?

    init(
        model: AppModel,
        collections: [IdentifiedPayload<CollectionPayload>],
        fixedParentId: UUID? = nil,
        onCreated: @escaping () -> Void
    ) {
        self.model = model
        self.collections = collections
        self.fixedParentId = fixedParentId
        self.onCreated = onCreated
        _parentId = State(initialValue: fixedParentId)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("List name", text: $name)
                if fixedParentId == nil {
                    Picker("Inside", selection: $parentId) {
                        Text("Top level").tag(UUID?.none)
                        ForEach(collections, id: \.id) { collection in
                            Text(collection.payload.name).tag(Optional(collection.id))
                        }
                    }
                }
                Text("Lists do not move or duplicate the underlying record; they add another encrypted relationship.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle("New list")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await create() } }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func create() async {
        guard let store = model.store else { return }
        do {
            let payload = CollectionPayload(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                parentCollectionId: parentId
            )
            _ = try await store.save(
                payload: payload,
                parentId: parentId,
                relationIds: [parentId].compactMap(\.self)
            )
            model.noteLocalMutation()
            onCreated()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
