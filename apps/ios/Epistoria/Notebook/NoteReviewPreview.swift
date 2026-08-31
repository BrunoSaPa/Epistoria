import EpistoriaCore
import SwiftUI

private enum NoteOrganizationError: LocalizedError {
    case notebookUnavailable

    var errorDescription: String? {
        "The encrypted notebook is unavailable. Reopen it before organizing this note."
    }
}

struct NoteOrganizationSummary: Equatable {
    var collectionNames: [String] = []
    var sessionTitles: [String] = []

    var isUnassigned: Bool { collectionNames.isEmpty && sessionTitles.isEmpty }

    var label: String {
        if isUnassigned { return "Unassigned · Organize later" }
        var parts: [String] = []
        if let first = collectionNames.first {
            parts.append(collectionNames.count == 1 ? "List · \(first)" : "\(collectionNames.count) Lists")
        }
        if let first = sessionTitles.first {
            parts.append(sessionTitles.count == 1 ? "Session · \(first)" : "\(sessionTitles.count) sessions")
        }
        return parts.joined(separator: " · ")
    }
}

enum NoteOrganizationIndex {
    static func load(
        store: EpistoriaStore,
        notes: [IdentifiedPayload<NotePayload>],
        collections: [IdentifiedPayload<ListPayload>],
        sessions: [IdentifiedPayload<StudySessionPayload>]
    ) async throws -> [UUID: NoteOrganizationSummary] {
        async let collectionLinks = store.list(
            RelationPayload.self,
            entityTypeOverride: .listItem
        )
        async let sessionLinks = store.list(
            RelationPayload.self,
            entityTypeOverride: .sessionNote
        )
        let links = try await (collectionLinks, sessionLinks)
        let collectionNames = Dictionary(uniqueKeysWithValues: collections.map { ($0.id, $0.payload.name) })
        let sessionTitles = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.payload.title) })
        let noteIDs = Set(notes.map(\.id))
        var result = Dictionary(uniqueKeysWithValues: noteIDs.map { ($0, NoteOrganizationSummary()) })

        for link in links.0 where noteIDs.contains(link.payload.rightId) {
            guard link.payload.schemaVersion == .listItem,
                  let name = collectionNames[link.payload.leftId]
            else { continue }
            result[link.payload.rightId, default: NoteOrganizationSummary()].collectionNames.append(name)
        }
        for link in links.1 where noteIDs.contains(link.payload.rightId) {
            guard link.payload.schemaVersion == .sessionNote,
                  let title = sessionTitles[link.payload.leftId]
            else { continue }
            result[link.payload.rightId, default: NoteOrganizationSummary()].sessionTitles.append(title)
        }
        for note in notes {
            guard let legacySessionId = note.payload.studySessionId,
                  let title = sessionTitles[legacySessionId],
                  result[note.id]?.sessionTitles.contains(title) != true
            else { continue }
            result[note.id, default: NoteOrganizationSummary()].sessionTitles.append(title)
        }
        for id in Array(result.keys) {
            result[id]?.collectionNames.sort()
            result[id]?.sessionTitles.sort()
        }
        return result
    }
}

struct NoteReviewPreview: View {
    @Bindable var model: AppModel
    let note: IdentifiedPayload<NotePayload>
    var context: String?

    @State private var blocks: [IdentifiedPayload<NoteBlockPayload>] = []
    @State private var fixedPageCount = 1

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            NotePageMiniature(configuration: configuration, excerpt: excerpt, contentSymbol: contentSymbol)
            VStack(alignment: .leading, spacing: 5) {
                Text(note.payload.title)
                    .font(.headline)
                    .foregroundStyle(EpistoriaDesign.ink)
                    .lineLimit(2)
                Text(excerpt ?? emptyPreviewLabel)
                    .font(.subheadline)
                    .foregroundStyle(EpistoriaDesign.mutedInk)
                    .lineLimit(3)
                HStack(spacing: 6) {
                    if let context {
                        Text(context)
                    } else {
                        Text("Edited \(note.payload.updatedAt.formatted(.relative(presentation: .named)))")
                    }
                    Text("·")
                    Text(pageLabel)
                    if note.syncState != .synced {
                        Text("· Saved locally")
                    }
                }
                .font(.caption)
                .foregroundStyle(EpistoriaDesign.mutedInk)
                .lineLimit(2)
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .task(id: "\(note.id.uuidString)-\(note.revision)") { await loadPreview() }
    }

    private var configuration: NoteCanvasConfiguration {
        note.payload.canvas ?? NoteCanvasConfiguration()
    }

    private var sortedBlocks: [IdentifiedPayload<NoteBlockPayload>] {
        blocks.filter { !$0.payload.tombstone }.sorted { $0.payload.orderKey < $1.payload.orderKey }
    }

    private var excerpt: String? {
        let value = sortedBlocks.lazy
            .flatMap { [$0.payload.plainText, $0.payload.transcription] }
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return value.map { String($0.prefix(180)) }
    }

    private var contentSymbol: String {
        if sortedBlocks.contains(where: { $0.payload.blockType == .handwriting }) { return "pencil.tip" }
        if sortedBlocks.contains(where: { $0.payload.blockType == .image }) { return "photo" }
        if sortedBlocks.contains(where: { $0.payload.blockType == .shape }) { return "square.on.circle" }
        return "doc.text"
    }

    private var emptyPreviewLabel: String {
        if blocks.isEmpty { return "Blank note" }
        if sortedBlocks.contains(where: { $0.payload.blockType == .handwriting }) { return "Handwritten content" }
        if sortedBlocks.contains(where: { $0.payload.blockType == .image }) { return "Image content" }
        return "Notebook content"
    }

    private var pageLabel: String {
        if configuration.pageFormat == .infinite { return "Infinite canvas" }
        let count = fixedPageCount
        return "\(count) page\(count == 1 ? "" : "s")"
    }

    private func loadPreview() async {
        guard let store = model.store else { return }
        async let loadedBlocks = store.list(NoteBlockPayload.self, parentId: note.id)
        async let loadedPages = store.notePages(noteId: note.id)
        blocks = (try? await loadedBlocks) ?? []
        let pages = (try? await loadedPages) ?? []
        fixedPageCount = configuration.pageFormat == .infinite
            ? 1
            : max(pages.count, 1)
    }
}

private struct NotePageMiniature: View {
    let configuration: NoteCanvasConfiguration
    let excerpt: String?
    let contentSymbol: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(configuration.paperColor.swiftUIColor)
            NoteMiniaturePattern(configuration: configuration)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            if let excerpt {
                Text(excerpt)
                    .font(.system(size: 5.5, weight: .regular, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.72))
                    .lineSpacing(1.4)
                    .lineLimit(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(8)
            } else {
                Image(systemName: contentSymbol)
                    .font(.system(size: 17, weight: .light))
                    .foregroundStyle(Color.black.opacity(0.42))
            }
        }
        .frame(width: 62, height: 82)
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.black.opacity(0.16), lineWidth: 0.5)
        }
        .shadow(color: Color.black.opacity(0.06), radius: 2, y: 1)
        .accessibilityHidden(true)
    }
}

private struct NoteMiniaturePattern: View {
    let configuration: NoteCanvasConfiguration

    var body: some View {
        Canvas { context, size in
            let color = Color.black.opacity(configuration.paperColor == .stone ? 0.16 : 0.10)
            let spacing: CGFloat = 9
            switch configuration.paperStyle {
            case .plain:
                break
            case .ruled:
                for y in stride(from: spacing, through: size.height, by: spacing) {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(path, with: .color(color), lineWidth: 0.5)
                }
            case .grid:
                drawGrid(context: &context, size: size, spacing: spacing, color: color)
            case .dotted:
                for x in stride(from: spacing, through: size.width, by: spacing) {
                    for y in stride(from: spacing, through: size.height, by: spacing) {
                        context.fill(
                            Path(ellipseIn: CGRect(x: x - 0.6, y: y - 0.6, width: 1.2, height: 1.2)),
                            with: .color(color)
                        )
                    }
                }
            case .isometric:
                for offset in stride(from: -size.height, through: size.width, by: spacing) {
                    var rising = Path()
                    rising.move(to: CGPoint(x: offset, y: size.height))
                    rising.addLine(to: CGPoint(x: offset + size.height * 0.58, y: 0))
                    context.stroke(rising, with: .color(color), lineWidth: 0.5)
                    var falling = Path()
                    falling.move(to: CGPoint(x: offset, y: 0))
                    falling.addLine(to: CGPoint(x: offset + size.height * 0.58, y: size.height))
                    context.stroke(falling, with: .color(color), lineWidth: 0.5)
                }
            }
        }
    }

    private func drawGrid(
        context: inout GraphicsContext,
        size: CGSize,
        spacing: CGFloat,
        color: Color
    ) {
        for x in stride(from: spacing, through: size.width, by: spacing) {
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(path, with: .color(color), lineWidth: 0.5)
        }
        for y in stride(from: spacing, through: size.height, by: spacing) {
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(path, with: .color(color), lineWidth: 0.5)
        }
    }
}

struct NoteOrganizationView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let noteId: UUID
    var onChanged: (() -> Void)?

    @State private var note: IdentifiedPayload<NotePayload>?
    @State private var collections: [IdentifiedPayload<ListPayload>] = []
    @State private var sessions: [IdentifiedPayload<StudySessionPayload>] = []
    @State private var linkedCollectionIds: Set<UUID> = []
    @State private var linkedSessionIds: Set<UUID> = []
    @State private var workingIds: Set<UUID> = []
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let note {
                        NoteReviewPreview(
                            model: model,
                            note: note,
                            context: statusLabel
                        )
                    }
                } footer: {
                    Text("Lists group related notes across Topics. Sessions collect the notes used during one focused study period. Linking never duplicates the note.")
                }

                Section("Lists") {
                    if collections.isEmpty {
                        Text("No Lists available")
                            .foregroundStyle(EpistoriaDesign.mutedInk)
                    }
                    ForEach(collections, id: \.id) { collection in
                        organizationButton(
                            id: collection.id,
                            title: collection.payload.name,
                            detail: "Reusable topic group",
                            symbol: "folder",
                            linked: linkedCollectionIds.contains(collection.id)
                        ) { try await linkToCollection(collection.id) }
                    }
                }

                Section("Sessions · focused study periods") {
                    if sessions.isEmpty {
                        Text("No sessions available")
                            .foregroundStyle(EpistoriaDesign.mutedInk)
                    }
                    ForEach(sessions, id: \.id) { session in
                        organizationButton(
                            id: session.id,
                            title: session.payload.title,
                            detail: session.payload.startedAt.formatted(date: .abbreviated, time: .shortened),
                            symbol: session.payload.state == .active ? "timer" : "checkmark.circle",
                            linked: linkedSessionIds.contains(session.id)
                        ) { try await linkToSession(session.id) }
                    }
                }
            }
            .navigationTitle("Organize note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { await load() }
            .alert("Organization error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    private var statusLabel: String {
        linkedCollectionIds.isEmpty && linkedSessionIds.isEmpty
            ? "Unassigned · Ready to organize"
            : "Linked without duplication"
    }

    private func organizationButton(
        id: UUID,
        title: String,
        detail: String,
        symbol: String,
        linked: Bool,
        action: @escaping () async throws -> UUID
    ) -> some View {
        Button {
            guard !linked else { return }
            Task {
                workingIds.insert(id)
                defer { workingIds.remove(id) }
                do {
                    _ = try await action()
                    model.noteLocalMutation()
                    onChanged?()
                    await load()
                } catch { errorMessage = error.localizedDescription }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .foregroundStyle(EpistoriaDesign.mutedInk)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(EpistoriaDesign.ink)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(EpistoriaDesign.mutedInk)
                }
                Spacer()
                if workingIds.contains(id) {
                    ProgressView()
                } else if linked {
                    Label("Added", systemImage: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(EpistoriaDesign.mutedInk)
                } else {
                    Image(systemName: "plus")
                        .foregroundStyle(EpistoriaDesign.ink)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(EpistoriaPressButtonStyle())
        .disabled(linked || workingIds.contains(id))
        .accessibilityHint(linked ? "Already linked" : "Links this note without duplicating it")
    }

    private func load() async {
        guard let store = model.store else { return }
        do {
            async let loadedNote = store.payload(NotePayload.self, id: noteId)
            async let loadedCollections = store.list(ListPayload.self)
            async let loadedSessions = store.list(StudySessionPayload.self)
            async let collectionLinks = store.list(
                RelationPayload.self,
                entityTypeOverride: .listItem
            )
            async let sessionLinks = store.list(
                RelationPayload.self,
                entityTypeOverride: .sessionNote
            )
            let result = try await (
                loadedNote,
                loadedCollections,
                loadedSessions,
                collectionLinks,
                sessionLinks
            )
            note = result.0
            collections = result.1.sorted { $0.payload.name.localizedCaseInsensitiveCompare($1.payload.name) == .orderedAscending }
            sessions = result.2.sorted { $0.payload.startedAt > $1.payload.startedAt }
            linkedCollectionIds = Set(result.3.filter { $0.payload.rightId == noteId }.map(\.payload.leftId))
            linkedSessionIds = Set(result.4.filter { $0.payload.rightId == noteId }.map(\.payload.leftId))
            if let legacySessionId = result.0.payload.studySessionId {
                linkedSessionIds.insert(legacySessionId)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func linkToCollection(_ listId: UUID) async throws -> UUID {
        guard let store = model.store else { throw NoteOrganizationError.notebookUnavailable }
        return try await store.linkNote(noteId, toList: listId)
    }

    private func linkToSession(_ sessionId: UUID) async throws -> UUID {
        guard let store = model.store else { throw NoteOrganizationError.notebookUnavailable }
        return try await store.linkNote(noteId, toSession: sessionId)
    }
}

struct AddNotesToSessionView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let sessionId: UUID
    let onChanged: () -> Void

    @State private var notes: [IdentifiedPayload<NotePayload>] = []
    @State private var linkedIds: Set<UUID> = []
    @State private var workingIds: Set<UUID> = []
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Add existing notes to this focused study period. The original note stays in the notebook and in every List that already uses it.")
                        .font(.subheadline)
                        .foregroundStyle(EpistoriaDesign.mutedInk)
                }
                Section("Available notes") {
                    if availableNotes.isEmpty {
                        ContentUnavailableView(
                            "All notes are added",
                            systemImage: "checkmark.circle",
                            description: Text("Create a new session note or return when another note is available.")
                        )
                    }
                    ForEach(availableNotes, id: \.id) { note in
                        Button {
                            Task { await add(note) }
                        } label: {
                            HStack(spacing: 10) {
                                NoteReviewPreview(
                                    model: model,
                                    note: note,
                                    context: note.payload.studySessionId == nil ? "Unassigned" : "Existing note"
                                )
                                if workingIds.contains(note.id) {
                                    ProgressView()
                                } else {
                                    Image(systemName: "plus.circle")
                                        .foregroundStyle(EpistoriaDesign.ink)
                                }
                            }
                        }
                        .buttonStyle(EpistoriaPressButtonStyle())
                        .disabled(workingIds.contains(note.id))
                    }
                }
            }
            .navigationTitle("Add notes to session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { await load() }
            .alert("Session note error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    private var availableNotes: [IdentifiedPayload<NotePayload>] {
        notes.filter { !linkedIds.contains($0.id) && $0.payload.archivedAt == nil }
    }

    private func load() async {
        guard let store = model.store else { return }
        do {
            notes = try await store.list(NotePayload.self)
                .sorted { $0.payload.updatedAt > $1.payload.updatedAt }
            linkedIds = try await store.noteIdsLinkedToSession(sessionId)
        } catch { errorMessage = error.localizedDescription }
    }

    private func add(_ note: IdentifiedPayload<NotePayload>) async {
        guard let store = model.store else { return }
        workingIds.insert(note.id)
        defer { workingIds.remove(note.id) }
        do {
            _ = try await store.linkNote(note.id, toSession: sessionId)
            model.noteLocalMutation()
            linkedIds.insert(note.id)
            onChanged()
        } catch { errorMessage = error.localizedDescription }
    }
}
