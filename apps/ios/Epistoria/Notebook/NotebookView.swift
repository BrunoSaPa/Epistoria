import EpistoriaCore
import SwiftUI

struct NotebookView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case notes = "Notes"
        case lists = "Lists"
        var id: Self { self }
    }

    private enum Destination: Hashable {
        case note(UUID)
    }

    @Bindable var model: AppModel
    @State private var notes: [IdentifiedPayload<NotePayload>] = []
    @State private var archivedNotes: [IdentifiedPayload<NotePayload>] = []
    @State private var lists: [IdentifiedPayload<ListPayload>] = []
    @State private var sessions: [IdentifiedPayload<StudySessionPayload>] = []
    @State private var organizationByNoteId: [UUID: NoteOrganizationSummary] = [:]
    @State private var mode = Mode.notes
    @State private var showArchived = false
    @State private var showNewNote = false
    @State private var showNewList = false
    @State private var noteCursor: EntityPageCursor?
    @State private var listCursor: EntityPageCursor?
    @State private var isLoadingMore = false
    @State private var destination: Destination?
    @State private var createdNotePendingNavigation: UUID?
    @State private var pendingArchive: IdentifiedPayload<NotePayload>?
    @State private var pendingTrashNote: IdentifiedPayload<NotePayload>?
    @State private var pendingTrashList: IdentifiedPayload<ListPayload>?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if mode == .notes && displayedNotes.isEmpty {
                    ContentUnavailableView {
                        Label(showArchived ? "Nothing archived" : "A quiet notebook", systemImage: showArchived ? "archivebox" : "book.pages")
                    } description: {
                        Text(showArchived
                             ? "Archived notes stay encrypted and searchable."
                             : "Create a note, then write freely, place text, and annotate images.")
                    } actions: {
                        if !showArchived {
                            Button("Create your first note") { showNewNote = true }
                                .buttonStyle(.borderedProminent)
                                .tint(EpistoriaDesign.ink)
                        }
                        if noteCursor != nil { loadMoreButton }
                    }
                } else if mode == .notes {
                    List {
                        ForEach(displayedNotes, id: \.id) { note in
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
                                context: showArchived
                                    ? "Archived · \(organizationByNoteId[note.id]?.label ?? "Unassigned")"
                                    : organizationByNoteId[note.id]?.label ?? "Unassigned · Organize later"
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
                            Button(showArchived ? "Restore" : "Archive", systemImage: showArchived ? "arrow.uturn.backward" : "archivebox") {
                                if showArchived {
                                    Task { await setArchived(note, archived: false) }
                                } else {
                                    pendingArchive = note
                                }
                            }
                            .tint(.gray)
                            }
                        }
                        if noteCursor != nil {
                            loadMoreButton
                        }
                    }
                } else if displayedLists.isEmpty {
                    ContentUnavailableView {
                        Label(showArchived ? "No archived Lists" : "No Lists yet", systemImage: showArchived ? "archivebox" : "folder")
                    } description: {
                        Text(showArchived
                             ? "Archived Lists keep their links and can be restored here."
                             : "Lists are optional cross-Topic groups. An item can belong to several Lists without being duplicated.")
                    } actions: {
                        if !showArchived {
                            Button("Create a List") { showNewList = true }
                                .buttonStyle(.borderedProminent)
                                .tint(EpistoriaDesign.ink)
                        }
                        if listCursor != nil { loadMoreButton }
                    }
                } else {
                    List {
                        if !showArchived {
                            Label("Lists group notes and sources across Topics. They are optional and never duplicate the underlying item.", systemImage: "folder")
                                .font(.subheadline)
                                .foregroundStyle(EpistoriaDesign.mutedInk)
                        }
                        Section("Lists") {
                            ForEach(displayedLists, id: \.id) { list in
                                NavigationLink {
                                    ListDetailView(model: model, listId: list.id)
                                } label: {
                                    Label(list.payload.name, systemImage: "folder")
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button("Trash", systemImage: "trash", role: .destructive) {
                                        pendingTrashList = list
                                    }
                                    Button(showArchived ? "Restore" : "Archive", systemImage: showArchived ? "arrow.uturn.backward" : "archivebox") {
                                        Task { await setListArchived(list, archived: !showArchived) }
                                    }
                                    .tint(.gray)
                                }
                            }
                            if listCursor != nil {
                                loadMoreButton
                            }
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
                    .frame(width: 220)
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        Button("Active", systemImage: "book.pages") { showArchived = false }
                        Button("Archived", systemImage: "archivebox") { showArchived = true }
                    } label: {
                        Label(showArchived ? "Archived" : "Active", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    Menu {
                        Button("Note", systemImage: "square.and.pencil") { showNewNote = true }
                        Button("List", systemImage: "folder.badge.plus") { showNewList = true }
                    } label: { Label("New", systemImage: "plus") }
                    .accessibilityIdentifier("notebook.new")
                }
            }
            .sheet(isPresented: $showNewNote, onDismiss: openCreatedNoteIfNeeded) {
                NewNoteView(model: model) { id in
                    createdNotePendingNavigation = id
                }
            }
            .sheet(isPresented: $showNewList) {
                NewListView(model: model) { Task { await load() } }
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
            async let loadedWorkspace = store.workspaceSnapshot()
            let workspace = try await loadedWorkspace
            noteCursor = workspace.notes.nextCursor
            listCursor = workspace.lists.nextCursor
            notes = workspace.notes.items
                .filter { $0.payload.archivedAt == nil }
                .sorted(by: noteSort)
            archivedNotes = workspace.notes.items
                .filter { $0.payload.archivedAt != nil }
                .sorted { ($0.payload.archivedAt ?? .distantPast) > ($1.payload.archivedAt ?? .distantPast) }
            lists = workspace.lists.items
                .sorted { $0.payload.name.localizedCaseInsensitiveCompare($1.payload.name) == .orderedAscending }
            sessions = workspace.sessions.items.sorted { $0.payload.startedAt > $1.payload.startedAt }
            organizationByNoteId = try await NoteOrganizationIndex.load(
                store: store,
                notes: workspace.notes.items,
                collections: workspace.lists.items,
                sessions: workspace.sessions.items
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
        changed.schemaVersion = "note/v5"
        changed.pinnedAt = pinned ? .now : nil
        changed.updatedAt = .now
        do {
            _ = try await store.save(
                id: note.id,
                payload: changed,
                parentId: changed.topicId ?? changed.studySessionId,
                relationIds: [changed.topicId, changed.studySessionId].compactMap(\.self)
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

    private func moveListToTrash(_ list: IdentifiedPayload<ListPayload>) async {
        guard let store = model.store else { return }
        do {
            _ = try await store.moveToTrash(
                targetId: list.id,
                targetType: .list,
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
                parentId: changed.payload.topicId ?? changed.payload.studySessionId,
                relationIds: [changed.payload.topicId, changed.payload.studySessionId].compactMap(\.self)
            )
            model.noteLocalMutation()
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var activeLists: [IdentifiedPayload<ListPayload>] {
        lists.filter { $0.payload.archivedAt == nil }
    }

    private var archivedLists: [IdentifiedPayload<ListPayload>] {
        lists.filter { $0.payload.archivedAt != nil }
    }

    private var displayedNotes: [IdentifiedPayload<NotePayload>] {
        showArchived ? archivedNotes : notes
    }

    private var displayedLists: [IdentifiedPayload<ListPayload>] {
        showArchived ? archivedLists : activeLists
    }

    private func setListArchived(_ list: IdentifiedPayload<ListPayload>, archived: Bool) async {
        guard let store = model.store else { return }
        do {
            try await store.updateList(
                id: list.id,
                name: list.payload.name,
                archived: archived
            )
            model.noteLocalMutation()
            await load()
        } catch { errorMessage = error.localizedDescription }
    }

    private var loadMoreButton: some View {
        Button {
            Task { await loadMore() }
        } label: {
            HStack {
                Spacer()
                if isLoadingMore { ProgressView() }
                Text(isLoadingMore ? "Loading…" : "Load more")
                Spacer()
            }
        }
        .disabled(isLoadingMore)
    }

    private func loadMore() async {
        guard let store = model.store, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            if mode == .notes, let noteCursor {
                let page = try await store.listPage(NotePayload.self, after: noteCursor)
                self.noteCursor = page.nextCursor
                let active = page.items.filter { $0.payload.archivedAt == nil }
                let archived = page.items.filter { $0.payload.archivedAt != nil }
                notes = (notes + active).sorted(by: noteSort)
                archivedNotes = (archivedNotes + archived).sorted {
                    ($0.payload.archivedAt ?? .distantPast) > ($1.payload.archivedAt ?? .distantPast)
                }
            } else if mode == .lists, let listCursor {
                let page = try await store.listPage(ListPayload.self, after: listCursor)
                self.listCursor = page.nextCursor
                lists = (lists + page.items).sorted {
                    $0.payload.name.localizedCaseInsensitiveCompare($1.payload.name) == .orderedAscending
                }
            }
            organizationByNoteId = try await NoteOrganizationIndex.load(
                store: store,
                notes: notes + archivedNotes,
                collections: lists,
                sessions: sessions
            )
        } catch {
            errorMessage = error.localizedDescription
        }
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
    let topicId: UUID?
    let onCreated: (UUID) -> Void

    init(
        model: AppModel,
        topicId: UUID? = nil,
        onCreated: @escaping (UUID) -> Void
    ) {
        self.model = model
        self.topicId = topicId
        self.onCreated = onCreated
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Note title", text: $title)
                        .font(.title3)
                        .accessibilityIdentifier("notebook.new-note.title")
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
                                    topicId: topicId,
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
                    .accessibilityIdentifier("notebook.new-note.create")
                }
            }
        }
    }
}

struct NewListView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let onCreated: () -> Void

    @State private var name = ""
    @State private var errorMessage: String?

    init(
        model: AppModel,
        onCreated: @escaping () -> Void
    ) {
        self.model = model
        self.onCreated = onCreated
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("List name", text: $name)
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
            _ = try await store.createList(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            model.noteLocalMutation()
            onCreated()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
