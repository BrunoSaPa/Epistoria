import EpistoriaCore
import SwiftUI

struct NotePageManagerView: View {
    @Bindable var model: AppModel
    let noteId: UUID
    @Binding var pages: [IdentifiedPayload<NotePagePayload>]
    @Binding var currentPageIndex: Int
    let blocks: [IdentifiedPayload<NoteBlockPayload>]

    @Environment(\.dismiss) private var dismiss
    @State private var pagePendingDeletion: IdentifiedPayload<NotePagePayload>?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                        Button {
                            currentPageIndex = index
                            dismiss()
                        } label: {
                            HStack(spacing: 14) {
                                PageManagerThumbnail(
                                    configuration: page.payload.configuration,
                                    excerpt: excerpt(for: page.id)
                                )
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Page \(index + 1)")
                                        .font(.headline)
                                        .foregroundStyle(EpistoriaDesign.ink)
                                    Text(pageDescription(page.payload.configuration))
                                        .font(.subheadline)
                                        .foregroundStyle(EpistoriaDesign.mutedInk)
                                    if index == currentPageIndex {
                                        Text("Current page")
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(EpistoriaDesign.ink)
                                    }
                                }
                                Spacer()
                                Image(systemName: "line.3.horizontal")
                                    .foregroundStyle(EpistoriaDesign.mutedInk)
                                    .accessibilityHidden(true)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Insert before", systemImage: "plus.rectangle.on.rectangle") {
                                Task { await insert(before: page.id) }
                            }
                            Button("Insert after", systemImage: "rectangle.on.rectangle.angled") {
                                Task { await insert(after: page.id) }
                            }
                            Button("Duplicate", systemImage: "plus.square.on.square") {
                                Task { await duplicate(page.id) }
                            }
                            Menu("Page template", systemImage: "doc.badge.gearshape") {
                                pageTemplateButtons(page)
                            }
                            Divider()
                            Button("Move to Trash…", systemImage: "trash", role: .destructive) {
                                pagePendingDeletion = page
                            }
                            .disabled(pages.count <= 1)
                        }
                        .accessibilityIdentifier("note.page-manager.page.\(index + 1)")
                    }
                    .onMove { source, destination in
                        guard let sourceIndex = source.first, pages.indices.contains(sourceIndex) else { return }
                        let pageID = pages[sourceIndex].id
                        let adjusted = destination > sourceIndex ? destination - 1 : destination
                        Task { await reorder(pageID, to: adjusted) }
                    }
                } footer: {
                    Text("Drag pages to reorder them. Page identity and recognition links stay intact.")
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Pages")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Add page", systemImage: "plus") {
                        Task { await insert(after: pages.last?.id) }
                    }
                    .disabled(pages.isEmpty)
                }
            }
            .confirmationDialog(
                "Move this page to Trash?",
                isPresented: Binding(
                    get: { pagePendingDeletion != nil },
                    set: { if !$0 { pagePendingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Move page to Trash", role: .destructive) {
                    guard let page = pagePendingDeletion else { return }
                    Task { await remove(page) }
                    pagePendingDeletion = nil
                }
                Button("Cancel", role: .cancel) { pagePendingDeletion = nil }
            } message: {
                Text("The page and its contents remain encrypted and can be restored from Settings → Trash.")
            }
            .alert("Page error", isPresented: .constant(errorMessage != nil)) {
                Button("Dismiss", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    @ViewBuilder
    private func pageTemplateButtons(_ page: IdentifiedPayload<NotePagePayload>) -> some View {
        Button("A4 portrait") { Task { await setTemplate(page, format: .a4, orientation: .portrait) } }
        Button("A4 landscape") { Task { await setTemplate(page, format: .a4, orientation: .landscape) } }
        Button("US Letter portrait") { Task { await setTemplate(page, format: .letter, orientation: .portrait) } }
        Button("US Letter landscape") { Task { await setTemplate(page, format: .letter, orientation: .landscape) } }
        Divider()
        ForEach(NotePaperStyle.allCases, id: \.self) { style in
            Button(style.pageManagerTitle) { Task { await setPaperStyle(page, style: style) } }
        }
    }

    private func excerpt(for pageId: UUID) -> String? {
        blocks.lazy
            .filter { !$0.payload.tombstone && $0.payload.canvasPageId == pageId }
            .compactMap { block -> String? in
                let text = block.payload.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }
            .first
            .map { String($0.prefix(140)) }
    }

    private func pageDescription(_ configuration: NoteCanvasConfiguration) -> String {
        let format = configuration.pageFormat == .letter ? "US Letter" : "A4"
        return "\(format) · \(configuration.orientation == .portrait ? "Portrait" : "Landscape") · \(configuration.paperStyle.pageManagerTitle)"
    }

    private func reload(focus pageId: UUID? = nil) async throws {
        guard let store = model.store else { return }
        pages = try await store.notePages(noteId: noteId)
        if let pageId, let index = pages.firstIndex(where: { $0.id == pageId }) {
            currentPageIndex = index
        } else {
            currentPageIndex = min(currentPageIndex, max(pages.count - 1, 0))
        }
        model.noteLocalMutation()
    }

    private func insert(after pageId: UUID?) async {
        guard let store = model.store else { return }
        do {
            let created = try await store.insertNotePage(noteId: noteId, after: pageId)
            try await reload(focus: created)
        } catch { errorMessage = error.localizedDescription }
    }

    private func insert(before pageId: UUID) async {
        guard let store = model.store else { return }
        do {
            let created = try await store.insertNotePage(noteId: noteId, before: pageId)
            try await reload(focus: created)
        } catch { errorMessage = error.localizedDescription }
    }

    private func duplicate(_ pageId: UUID) async {
        guard let store = model.store else { return }
        do {
            let created = try await store.duplicateNotePage(noteId: noteId, pageId: pageId)
            try await reload(focus: created)
        } catch { errorMessage = error.localizedDescription }
    }

    private func reorder(_ pageId: UUID, to destination: Int) async {
        guard let store = model.store else { return }
        do {
            try await store.reorderNotePage(noteId: noteId, pageId: pageId, destinationIndex: destination)
            try await reload(focus: pageId)
        } catch { errorMessage = error.localizedDescription }
    }

    private func remove(_ page: IdentifiedPayload<NotePagePayload>) async {
        guard let store = model.store else { return }
        do {
            _ = try await store.movePageToTrash(
                noteId: noteId,
                pageId: page.id,
                displayName: "Page \((pages.firstIndex(where: { $0.id == page.id }) ?? 0) + 1)"
            )
            try await reload()
        } catch { errorMessage = error.localizedDescription }
    }

    private func setTemplate(
        _ page: IdentifiedPayload<NotePagePayload>,
        format: NotePageFormat,
        orientation: NotePageOrientation
    ) async {
        var changed = page.payload.configuration
        changed.pageFormat = format
        changed.orientation = orientation
        await update(page, configuration: changed)
    }

    private func setPaperStyle(
        _ page: IdentifiedPayload<NotePagePayload>,
        style: NotePaperStyle
    ) async {
        var changed = page.payload.configuration
        changed.paperStyle = style
        await update(page, configuration: changed)
    }

    private func update(
        _ page: IdentifiedPayload<NotePagePayload>,
        configuration: NoteCanvasConfiguration
    ) async {
        guard let store = model.store else { return }
        do {
            try await store.updateNotePageConfiguration(
                noteId: noteId,
                pageId: page.id,
                configuration: configuration
            )
            try await reload(focus: page.id)
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct PageManagerThumbnail: View {
    let configuration: NoteCanvasConfiguration
    let excerpt: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(configuration.paperColor.swiftUIColor)
            if configuration.paperStyle != .plain {
                Canvas { context, size in
                    let color = Color.black.opacity(0.10)
                    let spacing: CGFloat = 9
                    if configuration.paperStyle == .ruled {
                        for y in stride(from: spacing, through: size.height, by: spacing) {
                            var path = Path()
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: size.width, y: y))
                            context.stroke(path, with: .color(color), lineWidth: 0.5)
                        }
                    } else {
                        for x in stride(from: spacing, through: size.width, by: spacing) {
                            for y in stride(from: spacing, through: size.height, by: spacing) {
                                context.fill(
                                    Path(ellipseIn: CGRect(x: x - 0.6, y: y - 0.6, width: 1.2, height: 1.2)),
                                    with: .color(color)
                                )
                            }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            if let excerpt {
                Text(excerpt)
                    .font(.system(size: 5.5))
                    .foregroundStyle(Color.black.opacity(0.72))
                    .lineLimit(8)
                    .padding(7)
            }
        }
        .frame(width: 62, height: 82)
        .overlay { RoundedRectangle(cornerRadius: 4).stroke(Color.black.opacity(0.16), lineWidth: 0.5) }
        .accessibilityHidden(true)
    }
}

private extension NotePaperStyle {
    var pageManagerTitle: String {
        switch self {
        case .plain: "Plain"
        case .ruled: "Ruled"
        case .grid: "Grid"
        case .dotted: "Dotted"
        case .isometric: "Isometric"
        }
    }
}
