import EpistoriaCore
import ImageIO
import PencilKit
import SwiftUI
import UniformTypeIdentifiers
import UIKit

private let maximumCanvasDrawingBytes = 1_350_000

private enum NoteEditorSaveError: LocalizedError {
    case encryptedStoreUnavailable
    case imagePreviewUnavailable

    var errorDescription: String? {
        switch self {
        case .encryptedStoreUnavailable:
            "The encrypted notebook is unavailable. Your latest changes remain queued for another save attempt."
        case .imagePreviewUnavailable:
            "The original image is safe, but Epistoria could not create its canvas preview."
        }
    }
}

private enum CanvasSaveState: Equatable {
    case idle
    case saving
    case saved
    case tooLarge(Int)

    var label: String {
        switch self {
        case .idle: "Saved locally"
        case .saving: "Saving locally…"
        case .saved: "Saved locally"
        case let .tooLarge(bytes):
            "Ink needs a new layer (\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))"
        }
    }
}

/// Keeps high-frequency Pencil save bookkeeping out of SwiftUI invalidation. The visible
/// drawing lives in `PKCanvasView`; SwiftUI receives a durable snapshot only after save settles.
@MainActor
private final class InkSaveBuffer {
    var generation: UInt64 = 0
    var pendingTask: Task<Void, Never>?
}

struct NoteEditorView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.epistoriaWorkspacePresentation) private var workspacePresentation
    let noteId: UUID
    var focusedBlockId: UUID?
    var highlightText: String?
    var onLifecycleChanged: (() -> Void)?

    @State private var note: IdentifiedPayload<NotePayload>?
    @State private var title = ""
    @State private var blocks: [IdentifiedPayload<NoteBlockPayload>] = []
    @State private var imagePreviews: [UUID: UIImage] = [:]
    @State private var configuration = NoteCanvasConfiguration()
    @State private var mode = SpatialNotebookMode.select
    @State private var selectedItemId: UUID?
    @State private var editingItemId: UUID?
    @State private var viewportCenter = CGPoint(x: 297.5, y: 421)
    @State private var activeInkData = Data()
    @State private var hasLiveInk = false
    @State private var inkSaveState = CanvasSaveState.idle
    @State private var inkSaveBuffer = InkSaveBuffer()
    @State private var blockSaveTasks: [UUID: Task<Void, Never>] = [:]
    @State private var pendingTitleSave: Task<Void, Never>?
    @State private var suppressNextTitleChange = false
    @State private var isLoading = true
    @State private var isImportingImage = false
    @State private var importProgress: String?
    @State private var errorMessage: String?
    @State private var pendingDeletion: IdentifiedPayload<NoteBlockPayload>?
    @State private var recentlyDeleted: IdentifiedPayload<NoteBlockPayload>?
    @State private var showArchiveConfirmation = false
    @State private var showClearInkConfirmation = false
    @State private var lassoSelection = LassoSelection()
    @State private var showNoteQuerySheet = false
    @State private var showNoteQueryArtifacts = false
    @State private var immersiveEditorID = UUID()

    init(
        model: AppModel,
        noteId: UUID,
        focusedBlockId: UUID? = nil,
        highlightText: String? = nil,
        onLifecycleChanged: (() -> Void)? = nil
    ) {
        self.model = model
        self.noteId = noteId
        self.focusedBlockId = focusedBlockId
        self.highlightText = highlightText
        self.onLifecycleChanged = onLifecycleChanged
    }

    var body: some View {
        ZStack {
            SpatialNotebookCanvas(
                configuration: configuration,
                items: canvasItems,
                inkData: activeInkData,
                inkBlockId: activeInkBlock?.id,
                mode: mode,
                selectedItemId: selectedItemId,
                lassoSelectedIds: Set(lassoSelection.selectedBlockIds),
                focus: focusedBlockId.map {
                    SpatialNotebookFocus(blockId: $0, highlightedText: highlightText)
                },
                editingItemId: editingItemId,
                onSelect: { selected in
                    selectedItemId = selected
                    if selected != nil { mode = .select }
                },
                onViewportChanged: { viewportCenter = $0 },
                onPlacementChanged: { id, placement in
                    savePlacement(id: id, placement: placement)
                },
                onTextChanged: { id, text, placement in
                    saveText(id: id, attributedText: text, placement: placement)
                },
                onTextEditingEnded: { id in
                    editingItemId = nil
                    Task { await flushBlock(id) }
                },
                onInkChanged: { data in
                    let containsInk = !data.isEmpty
                    if hasLiveInk != containsInk { hasLiveInk = containsInk }
                    saveInk(data)
                },
                onLassoSelection: { selection in
                    lassoSelection = selection
                },
                isReadOnly: isArchived
            )
            .accessibilityIdentifier("note.spatial-canvas")

            if isLoading {
                ProgressView("Opening encrypted notebook…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            } else if visibleContentBlocks.isEmpty && !hasLiveInk {
                VStack(spacing: 8) {
                    Image(systemName: "pencil.and.outline")
                        .font(.title2)
                        .foregroundStyle(EpistoriaDesign.mutedInk)
                    Text("A blank page")
                        .font(.headline)
                    Text("Choose Pen to write, Text to type, or Image to place a reference.")
                        .font(.subheadline)
                        .foregroundStyle(EpistoriaDesign.mutedInk)
                        .multilineTextAlignment(.center)
                }
                .padding(20)
                .allowsHitTesting(false)
                .accessibilityElement(children: .combine)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { editorToolbar }
        .toolbarBackground(.regularMaterial, for: .navigationBar)
        .fileImporter(
            isPresented: $isImportingImage,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            Task { await importImage(result) }
        }
        .overlay(alignment: .topLeading) { statusOverlay }
        .safeAreaInset(edge: .bottom, spacing: 0) { editorBottomInset }
        .task {
            workspacePresentation?.beginImmersiveEditing(id: immersiveEditorID)
            await load()
        }
        .onDisappear {
            workspacePresentation?.endImmersiveEditing(id: immersiveEditorID)
            Task { await saveAll() }
        }
        .sheet(isPresented: $showNoteQuerySheet) {
            NoteQuerySheetView(
                model: model,
                noteId: noteId,
                selection: lassoSelection,
                onDismiss: {
                    showNoteQuerySheet = false
                    mode = .select
                    lassoSelection = LassoSelection()
                }
            )
        }
        .sheet(isPresented: $showNoteQueryArtifacts) {
            NoteQueryArtifactsView(
                model: model,
                noteId: noteId,
                blocks: blocks,
                onInsertBlock: { text in Task { await addText(content: text) } }
            )
        }
        .confirmationDialog(
            "Remove this canvas item?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove item", role: .destructive) {
                guard let pendingDeletion else { return }
                Task { await deleteBlock(pendingDeletion) }
                self.pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("The item can be restored while this notebook remains open. Original image bytes are not erased.")
        }
        .confirmationDialog(
            "Clear all ink from this note?",
            isPresented: $showClearInkConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear ink", role: .destructive) { clearInk() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Text and images stay in place. You can undo from the Pencil palette before leaving the note.")
        }
        .confirmationDialog(
            "Archive this note?",
            isPresented: $showArchiveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Move to Archive") { Task { await setArchived(true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The note stays encrypted and can be restored from Notebook → Archived.")
        }
        .alert("Notebook needs attention", isPresented: .constant(errorMessage != nil)) {
            Button("Dismiss", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            TextField("Untitled note", text: $title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .textFieldStyle(.plain)
                .frame(minWidth: 180, idealWidth: 300, maxWidth: 380)
                .submitLabel(.done)
                .onSubmit { Task { await saveTitle() } }
                .onChange(of: title) { _, value in
                    if suppressNextTitleChange {
                        suppressNextTitleChange = false
                    } else {
                        scheduleTitleSave(value)
                    }
                }
                .accessibilityIdentifier("note.title")
                .disabled(isArchived)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            canvasMenu
            Menu {
                if let selectedBlock, !isArchived {
                    Button("Bring forward", systemImage: "square.2.layers.3d.top.filled") {
                        moveLayer(selectedBlock, direction: 1)
                    }
                    Button("Send backward", systemImage: "square.2.layers.3d.bottom.filled") {
                        moveLayer(selectedBlock, direction: -1)
                    }
                    Button("Remove selected item…", systemImage: "trash", role: .destructive) {
                        pendingDeletion = selectedBlock
                    }
                    Divider()
                }
                if activeInkBlock != nil, !isArchived {
                    Button("Clear ink…", systemImage: "eraser", role: .destructive) {
                        showClearInkConfirmation = true
                    }
                }
                if model.aiJobs != nil {
                    Button("Previous AI answers", systemImage: "sparkles") {
                        showNoteQueryArtifacts = true
                    }
                }
                Divider()
                if note?.payload.archivedAt != nil {
                    Button("Restore note", systemImage: "arrow.uturn.backward") {
                        Task { await setArchived(false) }
                    }
                } else {
                    Button("Move to Archive…", systemImage: "archivebox") {
                        showArchiveConfirmation = true
                    }
                }
                Button("Save now", systemImage: "checkmark") { Task { await saveAll() } }
                    .keyboardShortcut("s", modifiers: .command)
            } label: {
                Label("Notebook actions", systemImage: "ellipsis.circle")
            }
        }

    }

    private var canvasMenu: some View {
        Menu {
            Section("Page") {
                pageButton("A4 portrait", format: .a4, orientation: .portrait)
                pageButton("A4 landscape", format: .a4, orientation: .landscape)
                pageButton("US Letter portrait", format: .letter, orientation: .portrait)
                pageButton("US Letter landscape", format: .letter, orientation: .landscape)
                pageButton("Infinite canvas", format: .infinite, orientation: .portrait)
            }
            Section("Paper") {
                paperButton("Plain", style: .plain)
                paperButton("Ruled", style: .ruled)
                paperButton("Grid", style: .grid)
                paperButton("Dotted", style: .dotted)
            }
        } label: {
            Label(pageLabel, systemImage: configuration.pageFormat == .infinite ? "infinity" : "doc")
        }
        .disabled(isArchived)
        .accessibilityIdentifier("note.canvas-settings")
    }

    private func pageButton(
        _ label: String,
        format: NotePageFormat,
        orientation: NotePageOrientation
    ) -> some View {
        Button {
            Task { await setPage(format: format, orientation: orientation) }
        } label: {
            if configuration.pageFormat == format,
               (format == .infinite || configuration.orientation == orientation)
            {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
    }

    private func paperButton(_ label: String, style: NotePaperStyle) -> some View {
        Button {
            Task { await setPaperStyle(style) }
        } label: {
            if configuration.paperStyle == style {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        if !isLoading {
            HStack(spacing: 7) {
                Image(systemName: statusSymbol)
                    .accessibilityHidden(true)
                Text(statusLabel)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(EpistoriaDesign.mutedInk)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .padding(12)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("note.persistence-status")
        }
    }

    private var editorBottomInset: some View {
        VStack(spacing: 0) {
            transientBottomMessage
            Divider()
            canvasToolShelf
        }
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var canvasToolShelf: some View {
        HStack(spacing: 6) {
            if mode == .lasso {
                canvasToolButton("Cancel", systemImage: "xmark") {
                    mode = .select
                    lassoSelection = LassoSelection()
                }
                if !lassoSelection.isEmpty {
                    canvasToolButton("Ask", systemImage: "sparkles", selected: true) {
                        showNoteQuerySheet = true
                    }
                }
            } else {
                canvasToolButton(
                    "Select",
                    systemImage: mode == .select ? "cursorarrow.rays" : "cursorarrow",
                    selected: mode == .select
                ) {
                    mode = .select
                }
                .accessibilityIdentifier("note.tool.select")

                canvasToolButton("Pen", systemImage: "pencil.tip", selected: mode == .ink) {
                    Task { await activateInk() }
                }
                .disabled(isArchived)
                .accessibilityIdentifier("note.tool.pen")

                canvasToolButton("Text", systemImage: "textformat") {
                    Task { await addText() }
                }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(isArchived)
                .accessibilityIdentifier("note.tool.text")

                canvasToolButton("Image", systemImage: "photo.badge.plus") {
                    isImportingImage = true
                }
                .disabled(isArchived)
                .accessibilityIdentifier("note.tool.image")

                if model.aiJobs != nil {
                    canvasToolButton("Ask selection", systemImage: "lasso") {
                        selectedItemId = nil
                        lassoSelection = LassoSelection()
                        mode = .lasso
                    }
                    .accessibilityIdentifier("note.tool.lasso")
                }
            }
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(EpistoriaDesign.ink)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func canvasToolButton(
        _ title: String,
        systemImage: String,
        selected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    selected ? EpistoriaDesign.subtleFill : Color.clear,
                    in: RoundedRectangle(cornerRadius: EpistoriaDesign.compactRadius, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(EpistoriaPressButtonStyle())
    }

    @ViewBuilder
    private var transientBottomMessage: some View {
        if let importProgress {
            HStack(spacing: 10) {
                ProgressView()
                Text(importProgress)
            }
            .font(.subheadline)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 8)
        } else if let recentlyDeleted {
            HStack(spacing: 12) {
                Label("Item removed", systemImage: "trash")
                Button("Undo") { Task { await undoDelete(recentlyDeleted) } }
                    .fontWeight(.semibold)
            }
            .font(.subheadline)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 8)
        } else if isArchived {
            HStack(spacing: 12) {
                Label("Archived · preserved read-only", systemImage: "archivebox")
                Button("Restore") { Task { await setArchived(false) } }
                    .fontWeight(.semibold)
            }
            .font(.subheadline)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 8)
        }
    }

    private var canvasItems: [SpatialNotebookItem] {
        let activeInkId = activeInkBlock?.id
        return visibleContentBlocks.enumerated().compactMap { index, block in
            guard block.id != activeInkId else { return nil }
            let placement = block.payload.canvasPlacement ?? legacyPlacement(for: block, index: index)
            let content: SpatialNotebookItem.Content
            switch block.payload.blockType {
            case .text:
                content = .text(decodeRichText(block.payload))
            case .image:
                if let image = imagePreviews[block.id] {
                    content = .image(image, filename: block.payload.plainText)
                } else {
                    content = .unsupported("Image unavailable\n\(block.payload.plainText)")
                }
            case .handwriting:
                if let data = block.payload.drawingData,
                   let drawing = try? PKDrawing(data: data)
                {
                    content = .legacyDrawing(drawing)
                } else {
                    content = .unsupported("Empty legacy drawing")
                }
            default:
                content = .unsupported(
                    "Preserved \(block.payload.blockType.rawValue.lowercased()) item"
                )
            }
            return SpatialNotebookItem(id: block.id, placement: placement, content: content)
        }
    }

    private var visibleContentBlocks: [IdentifiedPayload<NoteBlockPayload>] {
        blocks.filter { !$0.payload.tombstone }
    }

    private var activeInkBlock: IdentifiedPayload<NoteBlockPayload>? {
        blocks.first { $0.payload.canvasRole == .inkLayer && !$0.payload.tombstone }
    }

    private var selectedBlock: IdentifiedPayload<NoteBlockPayload>? {
        guard let selectedItemId else { return nil }
        return blocks.first { $0.id == selectedItemId && $0.payload.canvasRole != .inkLayer }
    }

    private var isArchived: Bool { note?.payload.archivedAt != nil }

    private var pageLabel: String {
        switch configuration.pageFormat {
        case .a4: "A4"
        case .letter: "Letter"
        case .infinite: "Infinite"
        }
    }

    private var statusLabel: String {
        if case .tooLarge = inkSaveState { return inkSaveState.label }
        if inkSaveState == .saving || model.pendingSaves.count > 0 { return "Saving locally…" }
        let hasQueuedWork = model.pendingRecordCount + model.pendingFileCount > 0
        return note?.syncState == .synced && !hasQueuedWork
            ? "Saved · synced"
            : "Saved on this iPad"
    }

    private var statusSymbol: String {
        if case .tooLarge = inkSaveState { return "exclamationmark.triangle" }
        if inkSaveState == .saving || model.pendingSaves.count > 0 { return "arrow.triangle.2.circlepath" }
        let hasQueuedWork = model.pendingRecordCount + model.pendingFileCount > 0
        return note?.syncState == .synced && !hasQueuedWork ? "checkmark.circle" : "ipad"
    }

    private func load() async {
        guard let store = model.store else { return }
        do {
            async let loadedNote = store.payload(NotePayload.self, id: noteId)
            async let loadedBlocks = store.list(NoteBlockPayload.self, parentId: noteId)
            let result = try await (loadedNote, loadedBlocks)
            note = result.0
            configuration = result.0.payload.canvas ?? NoteCanvasConfiguration()
            if title != result.0.payload.title {
                suppressNextTitleChange = true
                title = result.0.payload.title
            }
            blocks = result.1.sorted { $0.payload.orderKey < $1.payload.orderKey }
            activeInkData = activeInkBlock?.payload.drawingData ?? Data()
            hasLiveInk = !activeInkData.isEmpty
            await loadImagePreviews()
            isLoading = false
        } catch {
            isLoading = false
            report(error)
        }
    }

    private func loadImagePreviews() async {
        guard let assetManager = model.assetManager else { return }
        var loaded: [UUID: UIImage] = [:]
        for block in blocks where block.payload.blockType == .image && !block.payload.tombstone {
            guard let assetId = block.payload.assetId else { continue }
            do {
                let data = try await assetManager.decryptedData(assetId: assetId)
                if let image = downsampledImage(data) { loaded[block.id] = image }
            } catch {
                report(error)
            }
        }
        imagePreviews = loaded
    }

    private func activateInk() async {
        guard !isArchived else { return }
        do {
            try await flushTitle()
            if activeInkBlock == nil {
                guard let store = model.store else {
                    throw NoteEditorSaveError.encryptedStoreUnavailable
                }
                _ = try await store.appendCanvasInkLayer(noteId: noteId)
                model.noteLocalMutation()
                await load()
            }
            selectedItemId = nil
            editingItemId = nil
            mode = .ink
        } catch { report(error) }
    }

    private func addText(content: String = "") async {
        guard !isArchived else { return }
        do {
            try await flushTitle()
            guard let store = model.store else {
                throw NoteEditorSaveError.encryptedStoreUnavailable
            }
            let width = min(380.0, max((configuration.pageWidth ?? 480) - 72, 240))
            let placement = placementCentered(width: width, height: 120, zIndex: nextZIndex)
            let id = try await store.appendCanvasText(
                noteId: noteId,
                text: content,
                placement: placement
            )
            model.noteLocalMutation()
            await load()
            selectedItemId = id
            editingItemId = id
            mode = .select
        } catch { report(error) }
    }

    private func importImage(_ result: Result<[URL], Error>) async {
        guard !isArchived, let assetManager = model.assetManager, let store = model.store else {
            return
        }
        do {
            let url = try result.get().first ?? { throw CancellationError() }()
            importProgress = "Encrypting original image…"
            try await flushTitle()
            let imported = try await assetManager.importImage(from: url)
            let ratio = CGFloat(imported.pixelWidth) / CGFloat(imported.pixelHeight)
            let width: CGFloat = min(420, max(180, ratio >= 1 ? 420 : 320 * ratio))
            let height: CGFloat = min(520, max(140, width / max(ratio, 0.01)))
            let placement = placementCentered(
                width: Double(width),
                height: Double(height),
                zIndex: nextZIndex
            )
            let id = try await store.appendCanvasImage(
                noteId: noteId,
                assetId: imported.assetId,
                filename: imported.filename,
                placement: placement
            )
            model.noteLocalMutation()
            importProgress = nil
            await load()
            selectedItemId = id
            mode = .select
        } catch is CancellationError {
            importProgress = nil
        } catch {
            importProgress = nil
            report(error)
        }
    }

    private func savePlacement(id: UUID, placement: NoteCanvasPlacement) {
        guard !isArchived, var block = blocks.first(where: { $0.id == id }) else { return }
        block.payload.schemaVersion = "note-block/v2"
        block.payload.canvasPlacement = placement
        block.payload.updatedAt = .now
        replaceLocalBlock(block)
        stageBlock(block)
        flushBlockSoon(id, delay: .milliseconds(120))
    }

    private func saveText(
        id: UUID,
        attributedText: NSAttributedString,
        placement: NoteCanvasPlacement
    ) {
        guard !isArchived, var block = blocks.first(where: { $0.id == id }) else { return }
        do {
            let rtf = try attributedText.data(
                from: NSRange(location: 0, length: attributedText.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            )
            block.payload.schemaVersion = "note-block/v2"
            block.payload.plainText = attributedText.string
            block.payload.richTextRtf = rtf
            block.payload.canvasPlacement = placement
            block.payload.updatedAt = .now
            replaceLocalBlock(block)
            stageBlock(block)
            flushBlockSoon(id, delay: .milliseconds(650))
        } catch { report(error) }
    }

    private func stageBlock(_ block: IdentifiedPayload<NoteBlockPayload>) {
        let snapshot = block.payload
        model.pendingSaves.stage(id: block.id) {
            guard let store = model.store else {
                throw NoteEditorSaveError.encryptedStoreUnavailable
            }
            _ = try await store.save(
                id: block.id,
                payload: snapshot,
                parentId: snapshot.noteId,
                relationIds: [snapshot.noteId, snapshot.assetId].compactMap(\.self)
            )
            model.noteLocalMutation()
        }
    }

    private func flushBlockSoon(_ id: UUID, delay: Duration) {
        blockSaveTasks[id]?.cancel()
        blockSaveTasks[id] = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await flushBlock(id)
        }
    }

    private func flushBlock(_ id: UUID) async {
        blockSaveTasks[id]?.cancel()
        do {
            try await model.pendingSaves.flush(id: id)
        } catch { report(error) }
    }

    private func saveInk(_ value: Data) {
        guard !isArchived, let inkBlock = activeInkBlock else { return }
        inkSaveBuffer.pendingTask?.cancel()
        inkSaveBuffer.generation &+= 1
        let generation = inkSaveBuffer.generation
        guard value.count <= maximumCanvasDrawingBytes else {
            inkSaveState = .tooLarge(value.count)
            return
        }
        inkSaveState = .saving
        var snapshot = inkBlock.payload
        snapshot.schemaVersion = "note-block/v2"
        snapshot.drawingData = value
        snapshot.updatedAt = .now
        model.pendingSaves.stage(id: inkBlock.id) {
            guard let store = model.store else {
                throw NoteEditorSaveError.encryptedStoreUnavailable
            }
            _ = try await store.save(
                id: inkBlock.id,
                payload: snapshot,
                parentId: snapshot.noteId,
                relationIds: [snapshot.noteId]
            )
            if generation == inkSaveBuffer.generation {
                activeInkData = value
                hasLiveInk = !value.isEmpty
                inkSaveState = .saved
            }
            model.noteLocalMutation()
        }
        inkSaveBuffer.pendingTask = Task {
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
            do {
                try await model.pendingSaves.flush(id: inkBlock.id)
            } catch {
                if generation == inkSaveBuffer.generation { inkSaveState = .idle }
                report(error)
            }
        }
    }

    private func clearInk() {
        guard !isArchived, activeInkBlock != nil else { return }
        activeInkData = Data()
        hasLiveInk = false
        saveInk(Data())
    }

    private func setPage(
        format: NotePageFormat,
        orientation: NotePageOrientation
    ) async {
        var changed = configuration
        changed.pageFormat = format
        changed.orientation = orientation
        await persistCanvasConfiguration(changed)
    }

    private func setPaperStyle(_ style: NotePaperStyle) async {
        var changed = configuration
        changed.paperStyle = style
        await persistCanvasConfiguration(changed)
    }

    private func persistCanvasConfiguration(_ changed: NoteCanvasConfiguration) async {
        guard changed != configuration, var note, let store = model.store else { return }
        do {
            try await flushTitle()
            try await model.pendingSaves.flushAll()
            note.payload.schemaVersion = "note/v2"
            note.payload.canvas = changed
            note.payload.updatedAt = .now
            _ = try await store.save(
                id: note.id,
                payload: note.payload,
                parentId: note.payload.courseId ?? note.payload.studySessionId,
                relationIds: [note.payload.courseId, note.payload.studySessionId].compactMap(\.self)
            )
            self.note = note
            configuration = changed
            model.noteLocalMutation()
        } catch { report(error) }
    }

    private func moveLayer(
        _ block: IdentifiedPayload<NoteBlockPayload>,
        direction: Int
    ) {
        let current = block.payload.canvasPlacement
            ?? legacyPlacement(for: block, index: visibleContentBlocks.firstIndex { $0.id == block.id } ?? 0)
        var changed = current
        changed.zIndex = min(max(current.zIndex + direction, -10_000), 10_000)
        savePlacement(id: block.id, placement: changed)
    }

    private func deleteBlock(_ block: IdentifiedPayload<NoteBlockPayload>) async {
        guard !isArchived, let database = model.database else { return }
        do {
            try await model.pendingSaves.flush(id: block.id)
            try await database.deleteLocal(id: block.id)
            recentlyDeleted = block
            selectedItemId = nil
            imagePreviews[block.id] = nil
            model.noteLocalMutation()
            await load()
        } catch { report(error) }
    }

    private func undoDelete(_ deleted: IdentifiedPayload<NoteBlockPayload>) async {
        guard let store = model.store else { return }
        do {
            _ = try await store.save(
                id: deleted.id,
                payload: deleted.payload,
                parentId: noteId,
                relationIds: [noteId, deleted.payload.assetId].compactMap(\.self)
            )
            recentlyDeleted = nil
            selectedItemId = deleted.id
            model.noteLocalMutation()
            await load()
        } catch { report(error) }
    }

    private func setArchived(_ archived: Bool) async {
        do {
            try await flushTitle()
            try await model.pendingSaves.flushAll()
        } catch {
            report(error)
            return
        }
        guard let store = model.store, var note else { return }
        guard (note.payload.archivedAt != nil) != archived else { return }
        note.payload.schemaVersion = "note/v2"
        note.payload.archivedAt = archived ? .now : nil
        note.payload.updatedAt = .now
        do {
            _ = try await store.save(
                id: note.id,
                payload: note.payload,
                parentId: note.payload.courseId ?? note.payload.studySessionId,
                relationIds: [note.payload.courseId, note.payload.studySessionId].compactMap(\.self)
            )
            self.note = note
            model.noteLocalMutation()
            onLifecycleChanged?()
            if archived { dismiss() }
        } catch { report(error) }
    }

    private func saveTitle() async {
        do { try await flushTitle() } catch { report(error) }
    }

    private func flushTitle() async throws {
        pendingTitleSave?.cancel()
        guard let note else { return }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            title = note.payload.title
            model.pendingSaves.discard(id: noteId)
            return
        }
        stageTitle(clean)
        try await model.pendingSaves.flush(id: noteId)
    }

    private func scheduleTitleSave(_ value: String) {
        pendingTitleSave?.cancel()
        guard note != nil else { return }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            model.pendingSaves.discard(id: noteId)
            return
        }
        stageTitle(clean)
        pendingTitleSave = Task {
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
            do { try await model.pendingSaves.flush(id: noteId) } catch { report(error) }
        }
    }

    private func stageTitle(_ clean: String) {
        model.pendingSaves.stage(id: noteId) { try await persistTitle(clean) }
    }

    private func persistTitle(_ clean: String) async throws {
        do {
            guard let store = model.store, var note else {
                throw NoteEditorSaveError.encryptedStoreUnavailable
            }
            guard clean != note.payload.title else { return }
            note.payload.schemaVersion = "note/v2"
            note.payload.title = clean
            note.payload.updatedAt = .now
            _ = try await store.save(
                id: note.id,
                payload: note.payload,
                parentId: note.payload.courseId ?? note.payload.studySessionId,
                relationIds: [note.payload.courseId, note.payload.studySessionId].compactMap(\.self)
            )
            self.note = note
            model.noteLocalMutation()
        } catch {
            report(error)
            throw error
        }
    }

    private func saveAll() async {
        inkSaveBuffer.pendingTask?.cancel()
        blockSaveTasks.values.forEach { $0.cancel() }
        do {
            try await flushTitle()
            try await model.pendingSaves.flushAll()
        } catch { report(error) }
    }

    private func replaceLocalBlock(_ changed: IdentifiedPayload<NoteBlockPayload>) {
        guard let index = blocks.firstIndex(where: { $0.id == changed.id }) else { return }
        blocks[index] = changed
    }

    private func legacyPlacement(
        for block: IdentifiedPayload<NoteBlockPayload>,
        index: Int
    ) -> NoteCanvasPlacement {
        let pageWidth = configuration.pageWidth ?? 595
        let width = min(max(pageWidth - 96, 260), 640)
        var y = 72.0
        for preceding in visibleContentBlocks.prefix(index) {
            y += legacyHeight(preceding.payload) + 24
        }
        return NoteCanvasPlacement(
            x: 48,
            y: y,
            width: width,
            height: legacyHeight(block.payload),
            zIndex: index
        )
    }

    private func legacyHeight(_ payload: NoteBlockPayload) -> Double {
        switch payload.blockType {
        case .text: 180
        case .handwriting: 320
        case .image: 260
        default: 140
        }
    }

    private var nextZIndex: Int {
        visibleContentBlocks.compactMap(\.payload.canvasPlacement?.zIndex).max().map { $0 + 1 } ?? 1
    }

    private func placementCentered(
        width: Double,
        height: Double,
        zIndex: Int
    ) -> NoteCanvasPlacement {
        var x = Double(viewportCenter.x) - width / 2
        var y = Double(viewportCenter.y) - height / 2
        if let pageWidth = configuration.pageWidth, let pageHeight = configuration.pageHeight {
            x = min(max(x, 24), max(pageWidth - width - 24, 24))
            y = min(max(y, 24), max(pageHeight - height - 24, 24))
        }
        return NoteCanvasPlacement(x: x, y: y, width: width, height: height, zIndex: zIndex)
    }

    private func decodeRichText(_ payload: NoteBlockPayload) -> NSAttributedString {
        if let rtf = payload.richTextRtf,
           let value = try? NSAttributedString(
               data: rtf,
               options: [.documentType: NSAttributedString.DocumentType.rtf],
               documentAttributes: nil
           )
        {
            return value
        }
        return NSAttributedString(
            string: payload.plainText,
            attributes: [.font: UIFont.preferredFont(forTextStyle: .body)]
        )
    }

    private func downsampledImage(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2_400,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return UIImage(cgImage: image)
    }

    private func report(_ error: Error) {
        errorMessage = error.localizedDescription
    }
}
