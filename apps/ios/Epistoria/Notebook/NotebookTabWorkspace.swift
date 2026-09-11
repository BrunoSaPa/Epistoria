import EpistoriaCore
import SwiftUI

@MainActor @Observable
final class NotebookTabSession {
    enum Request: Equatable { case open(UUID), close(UUID) }
    var tabs = NotebookOpenTabs()
    var titles: [UUID: String] = [:]
    var request: Request?
    var showsPicker = false

    func load(store: EpistoriaStore, opening id: UUID) async throws {
        var saved = try await store.database.notebookOpenTabs()
        var available = Set<UUID>()
        for candidate in Set(saved.noteIds + [id]) {
            guard let entity = try await store.database.entity(id: candidate),
                  !entity.tombstone, entity.entityType == .note else { continue }
            let note = try await store.payload(NotePayload.self, id: candidate)
            titles[candidate] = note.payload.title
            available.insert(candidate)
        }
        guard available.contains(id) else { throw StoreError.entityNotFound }
        saved.retainAvailable(available)
        saved.open(id)
        try await store.database.saveNotebookOpenTabs(saved)
        tabs = saved
    }

    /// Call only after the active editor has flushed pending content and reading position.
    func complete(_ action: Request, store: EpistoriaStore) async throws {
        var next = tabs
        switch action {
        case let .open(id):
            guard let entity = try await store.database.entity(id: id), !entity.tombstone,
                  entity.entityType == .note else { throw StoreError.entityNotFound }
            let note = try await store.payload(NotePayload.self, id: id)
            titles[id] = note.payload.title
            next.open(id)
        case let .close(id): next.close(id)
        }
        var available = Set<UUID>()
        for id in next.noteIds {
            if let entity = try await store.database.entity(id: id),
               !entity.tombstone, entity.entityType == .note { available.insert(id) }
        }
        next.retainAvailable(available)
        try await store.database.saveNotebookOpenTabs(next)
        tabs = next
        request = nil
    }
}

/// Owns navigation only. Inactive tabs never keep live Pencil canvases or image caches.
struct NoteEditorView: View {
    @Bindable var model: AppModel
    let noteId: UUID
    var focusedBlockId: UUID? = nil
    var highlightText: String? = nil
    var focusRectangles: [AnnotationRectangle] = []
    var onLifecycleChanged: (() -> Void)? = nil
    @State private var session = NotebookTabSession()
    @State private var loaded = false
    @State private var consumedInitialFocus = false
    @State private var error: String?
    @State private var immersiveID = UUID()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.epistoriaWorkspacePresentation) private var presentation

    var body: some View {
        Group {
            if let active = session.tabs.selectedId {
                NoteCanvasEditorView(
                    model: model, noteId: active,
                    focusedBlockId: !consumedInitialFocus && active == noteId ? focusedBlockId : nil,
                    highlightText: !consumedInitialFocus && active == noteId ? highlightText : nil,
                    focusRectangles: !consumedInitialFocus && active == noteId ? focusRectangles : [],
                    onLifecycleChanged: onLifecycleChanged, tabSession: session
                ).id(active)
            } else if let error {
                ContentUnavailableView("Cannot open note", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else { ProgressView("Opening note…") }
        }
        .task {
            presentation?.beginImmersiveEditing(id: immersiveID)
            guard !loaded else { return }
            guard let store = model.store else { error = "Unlock the notebook and try again."; return }
            do { try await session.load(store: store, opening: noteId); loaded = true }
            catch { self.error = error.localizedDescription }
        }
        .onDisappear { presentation?.endImmersiveEditing(id: immersiveID) }
        .onChange(of: session.tabs.selectedId) { old, selected in
            if old == noteId { consumedInitialFocus = true }
            if loaded, selected == nil { dismiss() }
        }
        .sheet(isPresented: $session.showsPicker) {
            NotebookTabPicker(model: model) { id in
                session.showsPicker = false
                session.request = .open(id)
            }
        }
    }
}

struct NotebookTabBar: View {
    @Bindable var session: NotebookTabSession
    @Binding var title: String
    let isEditable: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                ForEach(visibleIds, id: \.self) { id in
                    if id == session.tabs.selectedId { activeTitle }
                    else {
                        Button { session.request = .open(id) } label: {
                            Text(session.titles[id] ?? "Untitled note").lineLimit(1).frame(width: 100, height: 44)
                        }
                        .accessibilityIdentifier("note.tab.\(id.uuidString)")
                    }
                }
                actions
            }.fixedSize(horizontal: true, vertical: false)
            HStack(spacing: 4) { activeTitle; actions }
        }
        .disabled(session.request != nil)
    }

    private var visibleIds: [UUID] {
        var ids = Array(session.tabs.noteIds.prefix(3))
        if let active = session.tabs.selectedId, !ids.contains(active) { ids.append(active) }
        return ids
    }

    private var activeTitle: some View {
        HStack(spacing: 0) {
            TextField("Untitled note", text: $title)
                .font(.headline).textFieldStyle(.plain).frame(width: 150)
                .submitLabel(.done)
                .accessibilityIdentifier("note.title")
                .accessibilityLabel("Active note title")
                .disabled(!isEditable)
            Button {
                if let id = session.tabs.selectedId { session.request = .close(id) }
            } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                .accessibilityLabel("Close note tab")
                .accessibilityHint("Keeps the note in your notebook.")
                .accessibilityIdentifier("note.tab.close")
        }
        .padding(.leading, 8)
        .background(EpistoriaDesign.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(EpistoriaDesign.border, lineWidth: 0.5).allowsHitTesting(false) }
    }

    private var actions: some View {
        HStack(spacing: 0) {
            Menu {
                ForEach(session.tabs.noteIds, id: \.self) { id in
                    Button { session.request = .open(id) } label: {
                        Label(session.titles[id] ?? "Untitled note",
                              systemImage: id == session.tabs.selectedId ? "checkmark" : "doc")
                    }
                    .accessibilityIdentifier("note.tabs.menu.\(id.uuidString)")
                }
            } label: { Image(systemName: "chevron.down").frame(width: 44, height: 44) }
                .accessibilityLabel("Open note tabs")
                .accessibilityIdentifier("note.tabs.list")
            Button { session.showsPicker = true } label: {
                Image(systemName: "plus").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Open another note")
            .accessibilityIdentifier("note.tabs.open")
        }
    }
}

private struct NotebookTabPicker: View {
    @Bindable var model: AppModel
    let onOpen: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var notes: [IdentifiedPayload<NotePayload>] = []
    @State private var cursor: EntityPageCursor?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(notes, id: \.id) { note in
                    Button(note.payload.title) { onOpen(note.id) }
                        .accessibilityIdentifier("note.tabs.pick.\(note.id.uuidString)")
                }
                if let error { Text(error).foregroundStyle(.secondary) }
                if loading { ProgressView() }
                if cursor != nil || error != nil {
                    Button(error == nil ? "Load more notes" : "Retry") { Task { await load() } }
                        .disabled(loading)
                }
                if notes.isEmpty, !loading, error == nil { Text("No notes available.") }
            }
            .navigationTitle("Open note")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { await load() }
        }
    }

    private func load() async {
        guard !loading, let store = model.store else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await store.listPage(NotePayload.self, limit: 30, after: cursor)
            notes.append(contentsOf: page.items.filter { item in !notes.contains { $0.id == item.id } })
            cursor = page.nextCursor
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
