import EpistoriaCore
import ImageIO
import PencilKit
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private let maximumCanvasDrawingBytes = 1_350_000

private enum NoteEditorSaveError: LocalizedError {
    case encryptedStoreUnavailable
    case imagePreviewUnavailable
    case multiPageRequiresFixedPaper

    var errorDescription: String? {
        switch self {
        case .encryptedStoreUnavailable:
            "The encrypted notebook is unavailable. Your latest changes remain queued for another save attempt."
        case .imagePreviewUnavailable:
            "The original image is safe, but Epistoria could not create its canvas preview."
        case .multiPageRequiresFixedPaper:
            "Infinite canvas is available only for a one-page note. Multi-page conversion is not available yet."
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
        case .tooLarge(let bytes):
            "Ink needs a new layer (\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))"
        }
    }
}

private enum OCRRecognitionState: Equatable {
    case idle
    case recognizing
    case formulaProcessing
}

private enum NotebookLassoPurpose {
    case question
    case mathematics
}

/// Keeps high-frequency Pencil save bookkeeping out of SwiftUI invalidation. The visible
/// drawing lives in `PKCanvasView`; SwiftUI receives a durable snapshot only after save settles.
@MainActor
private final class InkSaveBuffer {
    private(set) var generationByBlock: [UUID: UInt64] = [:]
    var pendingTaskByBlock: [UUID: Task<Void, Never>] = [:]

    func nextGeneration(for blockID: UUID) -> UInt64 {
        let next = (generationByBlock[blockID] ?? 0) &+ 1
        generationByBlock[blockID] = next
        return next
    }

    func isCurrent(_ generation: UInt64, for blockID: UUID) -> Bool {
        generationByBlock[blockID] == generation
    }
}

struct NoteEditorView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.epistoriaWorkspacePresentation) private var workspacePresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.scenePhase) private var scenePhase
    let noteId: UUID
    var focusedBlockId: UUID?
    var highlightText: String?
    var focusRectangles: [AnnotationRectangle]
    var onLifecycleChanged: (() -> Void)?

    @State private var note: IdentifiedPayload<NotePayload>?
    @State private var pages: [IdentifiedPayload<NotePagePayload>] = []
    @State private var title = ""
    @State private var blocks: [IdentifiedPayload<NoteBlockPayload>] = []
    @State private var evidence: [IdentifiedPayload<EvidencePayload>] = []
    @State private var sourcesById: [UUID: IdentifiedPayload<SourcePayload>] = [:]
    @State private var sourceVersionsById: [UUID: IdentifiedPayload<SourceVersionPayload>] = [:]
    @State private var imagePreviews: [UUID: UIImage] = [:]
    @State private var configuration = NoteCanvasConfiguration()
    @State private var currentPageIndex = 0
    @State private var mode = SpatialNotebookMode.select
    @State private var inkTool = SpatialNotebookInkTool.pen
    @State private var inkWidth: CGFloat = 4
    @State private var inkColor = NoteCanvasColor.black
    @State private var eraserMode = SpatialNotebookEraserMode.pixel
    @State private var eraserWidth: CGFloat = 24
    @State private var showPenOptions = false
    @State private var showMarkerOptions = false
    @State private var showEraserOptions = false
    @State private var showShapeOptions = false
    @State private var showSymbolOptions = false
    @State private var selectedShapeKind = NoteCanvasShapeKind.rectangle
    @State private var shapeStrokeColor = NoteCanvasColor.black
    @State private var shapeFillColor: NoteCanvasColor?
    @State private var shapeLineWidth: Double = 3
    @State private var selectedMathSymbol = "√"
    @State private var canvasCommand: SpatialNotebookCommand?
    @State private var selectedItemId: UUID?
    @State private var editingItemId: UUID?
    @State private var viewportCenter = CGPoint(x: 297.5, y: 421)
    @State private var inkDataByPage: [Int: Data] = [:]
    @State private var requestedPageIndex: Int?
    @State private var previewLoadGeneration: UInt64 = 0
    @State private var creatingInkPages: Set<Int> = []
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
    @State private var recentlyDeletedTrashEntryId: UUID?
    @State private var showArchiveConfirmation = false
    @State private var showClearInkConfirmation = false
    @State private var showPDFExportConfirmation = false
    @State private var pdfExportOptions = NotePDFExportOptions.allPages
    @State private var isExportingPDF = false
    @State private var pdfExportResult: NotePDFExportResult?
    @State private var pdfExportTask: Task<Void, Never>?
    @State private var lassoSelection = LassoSelection()
    @State private var lassoPurpose = NotebookLassoPurpose.question
    @State private var showNoteQuerySheet = false
    @State private var showNoteQueryArtifacts = false
    @State private var showMathAssistanceSheet = false
    @State private var showMathAssistanceArtifacts = false
    @State private var showOCRReview = false
    @State private var ocrArtifacts: [IdentifiedPayload<OCRArtifactPayload>] = []
    @State private var ocrRecognitionState = OCRRecognitionState.idle
    @State private var pencilStrokeActivePages: Set<Int> = []
    @State private var showOrganization = false
    @State private var showEvidenceShelf = false
    @State private var showTutor = false
    @State private var showPageManager = false
    @State private var editingImageBlockId: UUID?
    @State private var showMoreTools = false
    @State private var showFindInNote = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var activeFocusedBlockId: UUID?
    @State private var activeHighlightText: String?
    @State private var activeFocusRectangles: [AnnotationRectangle]
    @State private var openedEvidenceId: UUID?
    @State private var inspectedEvidenceId: UUID?
    @State private var inspectedEvidenceBacklinks: [EvidenceBacklink] = []
    @State private var immersiveEditorID = UUID()

    init(
        model: AppModel,
        noteId: UUID,
        focusedBlockId: UUID? = nil,
        highlightText: String? = nil,
        focusRectangles: [AnnotationRectangle] = [],
        onLifecycleChanged: (() -> Void)? = nil
    ) {
        self.model = model
        self.noteId = noteId
        self.focusedBlockId = focusedBlockId
        self.highlightText = highlightText
        self.focusRectangles = focusRectangles
        self.onLifecycleChanged = onLifecycleChanged
        _activeFocusedBlockId = State(initialValue: focusedBlockId)
        _activeHighlightText = State(initialValue: highlightText)
        _activeFocusRectangles = State(initialValue: focusRectangles)
    }

    var body: some View {
        editorExportDialogs
    }

    private var editorChrome: some View {
        editorCanvasContent
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
            .onChange(of: selectedPhotoItem) { _, item in
                guard let item else { return }
                Task { await importPhoto(item) }
            }
            .overlay(alignment: .topLeading) { statusOverlay }
            .safeAreaInset(edge: .leading, spacing: 0) { notebookToolRail }
            .safeAreaInset(edge: .trailing, spacing: 0) {
                if showEvidenceShelf { evidenceShelf }
            }
            .overlay(alignment: .trailing) {
                if showTutor { tutorOverlay }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { transientBottomMessage }
            .sensoryFeedback(.selection, trigger: currentPageIndex)
            .onChange(of: currentPageIndex) { oldPage, newPage in
                if configuration.pageFormat != .infinite,
                   let pageConfiguration = pageConfiguration(at: newPage)
                {
                    configuration = pageConfiguration
                }
                Task {
                    await recognizePageAfterExit(oldPage)
                    await currentPageDidChange()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase != .active else { return }
                Task {
                    await saveAll()
                    await recognizePageAfterExit(currentPageIndex)
                }
            }
            .task {
                workspacePresentation?.beginImmersiveEditing(id: immersiveEditorID)
                await load()
            }
            .onDisappear {
                workspacePresentation?.endImmersiveEditing(id: immersiveEditorID)
                pdfExportTask?.cancel()
                pdfExportTask = nil
                if let pdfExportResult {
                    try? NotePDFExportService.removeTemporaryPDF(pdfExportResult.fileURL)
                    self.pdfExportResult = nil
                }
                Task {
                    await saveAll()
                    await recognizePageAfterExit(currentPageIndex)
                }
            }
    }

    private var editorSheets: some View {
        editorChrome
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
            .sheet(isPresented: $showMathAssistanceSheet) {
                MathAssistanceSheetView(
                    model: model,
                    noteId: noteId,
                    selection: lassoSelection,
                    onDismiss: {
                        showMathAssistanceSheet = false
                        mode = .select
                        lassoSelection = LassoSelection()
                    }
                )
            }
            .sheet(isPresented: $showMathAssistanceArtifacts) {
                MathAssistanceArtifactsView(
                    model: model,
                    noteId: noteId,
                    onInsertExpression: { expression in
                        Task { await addEquation(content: expression) }
                    },
                    onInsertExplanation: { explanation in
                        Task { await addText(content: explanation) }
                    }
                )
            }
            .sheet(isPresented: $showOCRReview) {
                OCRReviewView(
                    model: model,
                    parentId: noteId,
                    artifacts: $ocrArtifacts,
                    onCreateEquation: { expression in
                        Task { await addEquation(content: expression) }
                    }
                )
            }
            .sheet(isPresented: $showOrganization) {
                NoteOrganizationView(model: model, noteId: noteId) {
                    onLifecycleChanged?()
                }
            }
            .sheet(isPresented: $showPageManager, onDismiss: {
                Task { await load() }
            }) {
                NotePageManagerView(
                    model: model,
                    noteId: noteId,
                    pages: $pages,
                    currentPageIndex: $currentPageIndex,
                    blocks: blocks
                )
            }
            .sheet(isPresented: $showFindInNote) {
                NoteFindInNoteView(
                    pages: pages,
                    blocks: blocks,
                    artifacts: ocrArtifacts
                ) { match in
                    activeFocusedBlockId = match.blockId
                    activeHighlightText = match.text
                    activeFocusRectangles = match.rectangles
                    currentPageIndex = match.pageIndex
                    requestedPageIndex = match.pageIndex
                }
            }
            .sheet(
                isPresented: Binding(
                    get: { editingImageBlockId != nil },
                    set: { if !$0 { editingImageBlockId = nil } }
                )
            ) {
                if let editingImageBlockId,
                   let block = blocks.first(where: { $0.id == editingImageBlockId }),
                   let image = imagePreviews[editingImageBlockId]
                {
                    NoteImageEditorView(
                        image: image,
                        filename: block.payload.plainText,
                        configuration: block.payload.imageConfiguration,
                        hasOriginalReference: block.payload.imageConfiguration?.originalAssetId != nil,
                        onSave: { configuration in
                            try await saveImageConfiguration(
                                blockId: editingImageBlockId,
                                configuration: configuration
                            )
                        },
                        onReplaceFile: { url, configuration in
                            try await replaceImage(
                                blockId: editingImageBlockId,
                                from: url,
                                configuration: configuration
                            )
                        },
                        onReplaceData: { data, filename, configuration in
                            try await replaceImage(
                                blockId: editingImageBlockId,
                                data: data,
                                filename: filename,
                                configuration: configuration
                            )
                        },
                        onRestoreOriginal: { configuration in
                            try await restoreOriginalImage(
                                blockId: editingImageBlockId,
                                configuration: configuration
                            )
                        }
                    )
                } else {
                    ContentUnavailableView(
                        "Image unavailable",
                        systemImage: "photo",
                        description: Text("Close this editor and reopen the image after it downloads.")
                    )
                }
            }
            .sheet(
                isPresented: Binding(
                    get: { openedEvidenceId != nil },
                    set: { if !$0 { openedEvidenceId = nil } }
                )
            ) {
                if let openedEvidenceId,
                    let item = evidence.first(where: { $0.id == openedEvidenceId })
                {
                    NavigationStack {
                        SourceDetailView(
                            model: model,
                            sourceId: item.payload.sourceId,
                            initialSourceVersionId: item.payload.sourceVersionId,
                            initialPageNumber: item.payload.locator.page,
                            highlightText: item.payload.excerpt,
                            initialMediaTimeSeconds: item.payload.locator.startSeconds
                        )
                    }
                }
            }
    }

    private var editorDestructiveDialogs: some View {
        editorSheets
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
                Text(
                    "The item remains encrypted and can be restored from Settings → Trash. Original image bytes are not erased."
                )
            }
            .confirmationDialog(
                "Clear ink from this page?",
                isPresented: $showClearInkConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear ink", role: .destructive) { clearInk() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "Text, images, and ink on other pages stay in place. You can undo from the tool rail before leaving the page."
                )
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
    }

    private var editorExportDialogs: some View {
        editorDestructiveDialogs
            .sheet(isPresented: $showPDFExportConfirmation) {
                NotePDFExportOptionsView(
                    pageCount: finitePageCount,
                    currentPageIndex: currentPageIndex
                ) { options in
                    showPDFExportConfirmation = false
                    pdfExportOptions = options
                    startPDFExport(options: options)
                }
            }
            .sheet(item: $pdfExportResult) { result in
                NotePDFExportReadyView(result: result) {
                    removePDFExport(result)
                }
            }
            .alert("Notebook needs attention", isPresented: .constant(errorMessage != nil)) {
                Button("Dismiss", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
    }

    private var editorCanvasContent: some View {
        ZStack {
            notebookSurface

            if isLoading {
                ProgressView("Opening encrypted notebook…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            } else if configuration.pageFormat == .infinite,
                visibleContentBlocks.isEmpty,
                !hasLiveInk(on: 0)
            {
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
    }

    @ViewBuilder
    private var notebookSurface: some View {
        if configuration.pageFormat == .infinite {
            notebookCanvas(
                pageIndex: 0,
                pageConfiguration: configuration,
                allowsViewportNavigation: true
            )
        } else {
            ContinuousNotebookPages(
                pageConfigurations: pageConfigurations,
                currentPageIndex: $currentPageIndex,
                requestedPageIndex: $requestedPageIndex,
                onPageVisible: { pageIndex in
                    Task { await prepareVisiblePage(pageIndex) }
                }
            ) { pageIndex, pageConfiguration in
                notebookCanvas(
                    pageIndex: pageIndex,
                    pageConfiguration: pageConfiguration,
                    allowsViewportNavigation: false
                )
            }
        }
    }

    private func notebookCanvas(
        pageIndex: Int,
        pageConfiguration: NoteCanvasConfiguration,
        allowsViewportNavigation: Bool
    ) -> some View {
        SpatialNotebookCanvas(
            configuration: pageConfiguration,
            pageIndex: pageIndex,
            items: canvasItems(on: pageIndex),
            inkData: inkDataByPage[pageIndex] ?? Data(),
            inkBlockId: inkBlock(on: pageIndex)?.id,
            mode: canvasMode(on: pageIndex),
            inkTool: inkTool,
            inkWidth: inkWidth,
            inkColor: inkColor,
            eraserMode: eraserMode,
            eraserWidth: eraserWidth,
            command: pageIndex == currentPageIndex ? canvasCommand : nil,
            allowsViewportNavigation: allowsViewportNavigation,
            selectedItemId: selectedItemId,
            lassoSelectedIds: Set(lassoSelection.selectedBlockIds),
            focus: focus(on: pageIndex),
            editingItemId: editingItemId,
            onSelect: { selected in
                currentPageIndex = pageIndex
                selectedItemId = selected
                if selected != nil { mode = .select }
            },
            onViewportChanged: { center in
                if pageIndex == currentPageIndex { viewportCenter = center }
            },
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
                saveInk(data, on: pageIndex)
            },
            onPencilActivityChanged: { isActive in
                if isActive {
                    pencilStrokeActivePages.insert(pageIndex)
                    if let block = inkBlock(on: pageIndex) {
                        inkSaveBuffer.pendingTaskByBlock[block.id]?.cancel()
                    }
                } else {
                    pencilStrokeActivePages.remove(pageIndex)
                }
            },
            onLassoSelection: { selection in
                currentPageIndex = pageIndex
                lassoSelection = selection
            },
            onCanvasTap: { point in
                Task { await placeActiveTool(at: point, pageIndex: pageIndex) }
            },
            isReadOnly: isArchived
        )
        .accessibilityIdentifier("note.spatial-canvas.\(pageIndex + 1)")
        .accessibilityValue("\(canvasItems(on: pageIndex).count) canvas items")
        .dropDestination(for: String.self) { values, _ in
            guard let value = values.first, let evidenceId = UUID(uuidString: value),
                evidence.contains(where: { $0.id == evidenceId })
            else { return false }
            Task { await addEvidence(evidenceId, pageIndex: pageIndex) }
            return true
        }
        .dropDestination(for: Data.self) { values, _ in
            guard let data = values.first else { return false }
            Task { await importImageData(data, filename: "Dropped image") }
            return true
        }
    }

    private func canvasMode(on pageIndex: Int) -> SpatialNotebookMode {
        switch mode {
        case .ink:
            inkBlock(on: pageIndex) == nil ? .select : .ink
        case .lasso:
            pageIndex == currentPageIndex ? .lasso : .select
        case .select:
            .select
        case .shape:
            pageIndex == currentPageIndex ? .shape : .select
        case .symbol:
            pageIndex == currentPageIndex ? .symbol : .select
        }
    }

    private func focus(on pageIndex: Int) -> SpatialNotebookFocus? {
        guard let activeFocusedBlockId,
            let block = blocks.first(where: { $0.id == activeFocusedBlockId }),
            blockPageIndex(block.payload) == pageIndex
        else { return nil }
        return SpatialNotebookFocus(
            blockId: activeFocusedBlockId,
            highlightedText: activeHighlightText,
            normalizedRectangles: activeFocusRectangles
        )
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
                    if let evidenceId = selectedBlock.payload.evidenceId,
                        let item = evidence.first(where: { $0.id == evidenceId })
                    {
                        Button("Open Evidence source", systemImage: "arrow.up.right.square") {
                            openedEvidenceId = item.id
                        }
                        Divider()
                    }
                    if selectedBlock.payload.blockType == .image {
                        Button("Edit image…", systemImage: "crop") {
                            editingImageBlockId = selectedBlock.id
                        }
                        .disabled(imagePreviews[selectedBlock.id] == nil)
                        Divider()
                    }
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
                    Button("Math results", systemImage: "function") {
                        showMathAssistanceArtifacts = true
                    }
                }
                Button("Recognized text", systemImage: "text.viewfinder") {
                    showOCRReview = true
                }
                .disabled(ocrArtifacts.isEmpty)
                Divider()
                Button("Organize note…", systemImage: "folder.badge.plus") {
                    showOrganization = true
                }
                .disabled(isArchived)
                Button("Export note as PDF…", systemImage: "doc.richtext") {
                    showPDFExportConfirmation = true
                }
                .disabled(isExportingPDF)
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
                paperButton("Isometric", style: .isometric)
            }
            Section("Pattern spacing") {
                paperSpacingButton("Compact", spacing: 18)
                paperSpacingButton("Standard", spacing: 28)
                paperSpacingButton("Wide", spacing: 40)
            }
            Section("Page color") {
                ForEach(NotePaperColor.allCases, id: \.self) { color in
                    paperColorButton(color)
                }
            }
        } label: {
            Label(
                pageLabel, systemImage: configuration.pageFormat == .infinite ? "infinity" : "doc")
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
                format == .infinite || configuration.orientation == orientation
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

    private func paperSpacingButton(_ label: String, spacing: Double) -> some View {
        Button {
            Task { await setPaperSpacing(spacing) }
        } label: {
            if configuration.paperSpacing == spacing {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
        .disabled(configuration.paperStyle == .plain)
    }

    private func paperColorButton(_ color: NotePaperColor) -> some View {
        Button {
            Task { await setPaperColor(color) }
        } label: {
            if configuration.paperColor == color {
                Label(color.label, systemImage: "checkmark")
            } else {
                Text(color.label)
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

    private var notebookToolRail: some View {
        VStack(spacing: 2) {
            ForEach(model.workspacePreferences.visibleNotebookTools) { tool in
                notebookRailTool(tool)
            }

            Button {
                showMoreTools = true
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .medium))
                    Text("More")
                        .font(.system(size: 9.5, weight: .medium))
                }
                .frame(width: 66, height: railButtonHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(EpistoriaPressButtonStyle())
            .popover(isPresented: $showMoreTools, arrowEdge: .leading) {
                moreToolsPanel
                    .presentationCompactAdaptation(.popover)
            }
            .accessibilityIdentifier("note.tool.more")
        }
        .foregroundStyle(EpistoriaDesign.ink)
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .frame(width: 82)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
        .overlay(alignment: .trailing) { Divider() }
        .accessibilityElement(children: .contain)
    }

    private var railButtonHeight: CGFloat {
        model.workspacePreferences.visibleNotebookTools.count > 13 ? 34 : 42
    }

    @ViewBuilder
    private func notebookRailTool(_ tool: NotebookToolID) -> some View {
        switch tool {
        case .select:
            compactRailToolButton(tool, selected: mode == .select) {
                mode = .select
                lassoSelection = LassoSelection()
            }
        case .pen:
            compactRailToolButton(tool, selected: mode == .ink && inkTool == .pen) {
                handleInkToolTap(.pen)
            }
            .disabled(isArchived)
            .popover(isPresented: $showPenOptions, arrowEdge: .leading) {
                inkOptions(title: "Pen", widths: [2, 4, 8]).presentationCompactAdaptation(.popover)
            }
        case .marker:
            compactRailToolButton(tool, selected: mode == .ink && inkTool == .marker) {
                handleInkToolTap(.marker)
            }
            .disabled(isArchived)
            .popover(isPresented: $showMarkerOptions, arrowEdge: .leading) {
                inkOptions(title: "Marker", widths: [12, 18, 28]).presentationCompactAdaptation(.popover)
            }
        case .eraser:
            compactRailToolButton(tool, selected: mode == .ink && inkTool == .eraser) {
                handleInkToolTap(.eraser)
            }
            .disabled(isArchived)
            .popover(isPresented: $showEraserOptions, arrowEdge: .leading) {
                eraserOptions.presentationCompactAdaptation(.popover)
            }
        case .text:
            compactRailToolButton(tool) { Task { await addText() } }
                .disabled(isArchived)
        case .image:
            compactRailToolButton(tool) { isImportingImage = true }
                .disabled(isArchived)
        case .shape:
            compactRailToolButton(tool, selected: mode == .shape) { handleShapeToolTap() }
                .disabled(isArchived)
                .popover(isPresented: $showShapeOptions, arrowEdge: .leading) {
                    shapeOptions.presentationCompactAdaptation(.popover)
                }
        case .pages:
            compactRailToolButton(tool, selected: showPageManager) { showPageManager = true }
                .disabled(configuration.pageFormat == .infinite)
        case .undo:
            compactRailToolButton(tool) { sendCanvasCommand(.undo) }
                .disabled(isArchived)
        case .redo:
            compactRailToolButton(tool) { sendCanvasCommand(.redo) }
                .disabled(isArchived)
        case .symbol:
            compactRailToolButton(tool, selected: mode == .symbol) { handleSymbolToolTap() }
                .disabled(isArchived)
                .popover(isPresented: $showSymbolOptions, arrowEdge: .leading) {
                    symbolOptions.presentationCompactAdaptation(.popover)
                }
        case .evidence:
            compactRailToolButton(tool, selected: showEvidenceShelf) { toggleEvidenceShelf() }
        case .ocr:
            compactRailToolButton(tool, selected: showOCRReview) { showOCRReview = true }
                .disabled(ocrArtifacts.isEmpty)
        case .learn:
            compactRailToolButton(tool) { openLearningHub() }
        case .ask:
            compactRailToolButton(
                tool,
                selected: mode == .lasso && lassoPurpose == .question
            ) { activateLasso(.question) }
            .disabled(model.aiJobs == nil)
        case .math:
            compactRailToolButton(
                tool,
                selected: mode == .lasso && lassoPurpose == .mathematics
            ) { activateLasso(.mathematics) }
            .disabled(model.aiJobs == nil)
        }
    }

    private func compactRailToolButton(
        _ tool: NotebookToolID,
        selected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: tool.symbol)
                    .font(.system(size: 17, weight: selected ? .semibold : .regular))
                Text(tool.title)
                    .font(.system(size: 9.5, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .frame(width: 66, height: railButtonHeight)
            .background(
                selected ? EpistoriaDesign.subtleFill : Color.clear,
                in: RoundedRectangle(cornerRadius: EpistoriaDesign.compactRadius, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(EpistoriaPressButtonStyle())
        .accessibilityLabel(tool.title)
        .accessibilityIdentifier("note.tool.\(tool.rawValue)")
    }

    private var moreToolsPanel: some View {
        NavigationStack {
            List {
                Section("Tools") {
                    ForEach(NotebookToolID.optional) { tool in
                        Button {
                            showMoreTools = false
                            runOptionalTool(tool)
                        } label: {
                            Label(tool.title, systemImage: tool.symbol)
                        }
                        .disabled(optionalToolDisabled(tool))
                    }
                }
                Section("Note") {
                    Button("Find in Note", systemImage: "doc.text.magnifyingglass") {
                        showMoreTools = false
                        showFindInNote = true
                    }
                    .accessibilityIdentifier("note.more.find")
                    Button("Organize", systemImage: "folder.badge.plus") {
                        showMoreTools = false
                        showOrganization = true
                    }
                    Button("Export PDF", systemImage: "doc.richtext") {
                        showMoreTools = false
                        showPDFExportConfirmation = true
                    }
                    .disabled(isExportingPDF)
                    .accessibilityIdentifier("note.more.export-pdf")
                    Button("Page and paper", systemImage: "doc.badge.gearshape") {
                        showMoreTools = false
                        showPageManager = configuration.pageFormat != .infinite
                    }
                    .disabled(configuration.pageFormat == .infinite)
                }
                Section("Add image") {
                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        Label("Photo Library", systemImage: "photo.on.rectangle")
                    }
                    .accessibilityIdentifier("note.more.image.photos")
                    Button("Files", systemImage: "folder") {
                        showMoreTools = false
                        isImportingImage = true
                    }
                    .accessibilityIdentifier("note.more.image.files")
                    Button("Paste Image", systemImage: "doc.on.clipboard") {
                        showMoreTools = false
                        Task { await pasteImage() }
                    }
                    .disabled(UIPasteboard.general.image == nil)
                    .accessibilityIdentifier("note.more.image.paste")
                }
                Section("Customize") {
                    ForEach(NotebookToolID.optional) { tool in
                        Toggle(
                            "Pin \(tool.title)",
                            isOn: Binding(
                                get: { model.workspacePreferences.pinnedOptionalTools.contains(tool) },
                                set: { isPinned in
                                    if isPinned { model.workspacePreferences.pinnedOptionalTools.insert(tool) }
                                    else { model.workspacePreferences.pinnedOptionalTools.remove(tool) }
                                }
                            )
                        )
                    }
                }
            }
            .navigationTitle("More")
            .frame(minWidth: 330, minHeight: 520)
        }
    }

    private func optionalToolDisabled(_ tool: NotebookToolID) -> Bool {
        switch tool {
        case .ocr: ocrArtifacts.isEmpty
        case .ask, .math: model.aiJobs == nil
        default: false
        }
    }

    private func runOptionalTool(_ tool: NotebookToolID) {
        switch tool {
        case .symbol: handleSymbolToolTap()
        case .evidence: toggleEvidenceShelf()
        case .ocr: showOCRReview = true
        case .learn: openLearningHub()
        case .ask: activateLasso(.question)
        case .math: activateLasso(.mathematics)
        default: break
        }
    }

    private func toggleEvidenceShelf() {
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .snappy(duration: 0.24, extraBounce: 0)) {
            showEvidenceShelf.toggle()
        }
    }

    private func activateLasso(_ purpose: NotebookLassoPurpose) {
        if mode == .lasso, lassoPurpose == purpose, !lassoSelection.isEmpty {
            if purpose == .question { showNoteQuerySheet = true }
            else { showMathAssistanceSheet = true }
        } else {
            selectedItemId = nil
            lassoSelection = LassoSelection()
            lassoPurpose = purpose
            mode = .lasso
        }
    }

    private func openLearningHub() {
        model.learningLaunchContext = LearningLaunchContext(
            topicId: note?.payload.topicId,
            noteId: noteId,
            selectedObjectIds: lassoSelection.selectedBlockIds,
            destination: .overview
        )
        model.selectedSection = .learning
    }

    private var legacyNotebookToolRail: some View {
        VStack(spacing: 4) {
            railToolButton(
                "Select",
                systemImage: "cursorarrow",
                selected: mode == .select
            ) {
                mode = .select
                lassoSelection = LassoSelection()
            }
            .accessibilityIdentifier("note.tool.select")

            Divider().padding(.vertical, 2)

            railToolButton(
                "Pen",
                systemImage: "pencil.tip",
                selected: mode == .ink && inkTool == .pen
            ) { handleInkToolTap(.pen) }
            .disabled(isArchived)
            .popover(isPresented: $showPenOptions, arrowEdge: .leading) {
                inkOptions(title: "Pen", widths: [2, 4, 8])
                    .presentationCompactAdaptation(.popover)
            }
            .accessibilityHint("When selected, tap again for width and color options")
            .accessibilityIdentifier("note.tool.pen")

            railToolButton(
                "Marker",
                systemImage: "highlighter",
                selected: mode == .ink && inkTool == .marker
            ) { handleInkToolTap(.marker) }
            .disabled(isArchived)
            .popover(isPresented: $showMarkerOptions, arrowEdge: .leading) {
                inkOptions(title: "Marker", widths: [12, 18, 28])
                    .presentationCompactAdaptation(.popover)
            }
            .accessibilityHint("When selected, tap again for width and color options")
            .accessibilityIdentifier("note.tool.marker")

            railToolButton(
                "Eraser",
                systemImage: "eraser",
                selected: mode == .ink && inkTool == .eraser
            ) {
                handleInkToolTap(.eraser)
            }
            .disabled(isArchived)
            .popover(isPresented: $showEraserOptions, arrowEdge: .leading) {
                eraserOptions
                    .presentationCompactAdaptation(.popover)
            }
            .accessibilityLabel("Eraser, \(eraserMode.label)")
            .accessibilityHint("When selected, tap again for eraser options")
            .accessibilityIdentifier("note.tool.eraser")

            Menu {
                strokeWidthButton("Fine", width: 2)
                strokeWidthButton("Medium", width: 4)
                strokeWidthButton("Broad", width: 8)
                strokeWidthButton("Marker", width: 18)
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 18, weight: .medium))
                    Text("Size")
                        .font(.caption2)
                }
                .frame(width: 68, height: 48)
                .contentShape(Rectangle())
            }
            .disabled(isArchived || mode != .ink || inkTool == .eraser)
            .accessibilityLabel("Stroke size, \(Int(inkWidth)) points")
            .accessibilityIdentifier("note.tool.size")

            Divider().padding(.vertical, 2)

            railToolButton(
                "Shape",
                systemImage: "square.on.circle",
                selected: mode == .shape
            ) { handleShapeToolTap() }
            .disabled(isArchived)
            .popover(isPresented: $showShapeOptions, arrowEdge: .leading) {
                shapeOptions
                    .presentationCompactAdaptation(.popover)
            }
            .accessibilityLabel("Shape, \(selectedShapeKind.label)")
            .accessibilityHint("When selected, tap again for shape options")
            .accessibilityIdentifier("note.tool.shape")

            railToolButton(
                "Symbol",
                systemImage: "function",
                selected: mode == .symbol
            ) { handleSymbolToolTap() }
            .disabled(isArchived)
            .popover(isPresented: $showSymbolOptions, arrowEdge: .leading) {
                symbolOptions
                    .presentationCompactAdaptation(.popover)
            }
            .accessibilityLabel("Math symbol, \(selectedMathSymbol)")
            .accessibilityHint("When selected, tap again for symbol options")
            .accessibilityIdentifier("note.tool.symbol")

            railToolButton("Text", systemImage: "textformat") {
                Task { await addText() }
            }
            .keyboardShortcut("t", modifiers: [.command, .option])
            .disabled(isArchived)
            .accessibilityIdentifier("note.tool.text")

            railToolButton("Image", systemImage: "photo.badge.plus") {
                isImportingImage = true
            }
            .disabled(isArchived)
            .accessibilityIdentifier("note.tool.image")

            railToolButton(
                "Evidence",
                systemImage: "quote.bubble",
                selected: showEvidenceShelf
            ) {
                withAnimation(.snappy(duration: 0.24, extraBounce: 0)) {
                    showEvidenceShelf.toggle()
                }
            }
            .accessibilityHint("Shows reusable excerpts anchored to their original Source Version")
            .accessibilityIdentifier("note.tool.evidence")

            railToolButton(
                "OCR",
                systemImage: "text.viewfinder",
                selected: showOCRReview
            ) {
                showOCRReview = true
            }
            .disabled(ocrArtifacts.isEmpty)
            .accessibilityHint("Review locally recognized handwriting before using it")
            .accessibilityIdentifier("note.tool.ocr-review")

            railToolButton(
                "Tutor",
                systemImage: "graduationcap",
                selected: showTutor
            ) {
                showEvidenceShelf = false
                withAnimation(
                    reduceMotion
                        ? .easeOut(duration: 0.12) : .snappy(duration: 0.26, extraBounce: 0)
                ) {
                    showTutor.toggle()
                }
            }
            .accessibilityHint("Opens an adaptive Tutor without closing or resizing the notebook")
            .accessibilityIdentifier("note.tool.tutor")

            if model.aiJobs != nil {
                railToolButton(
                    lassoSelection.isEmpty || lassoPurpose != .question ? "Ask" : "Send",
                    systemImage: lassoSelection.isEmpty || lassoPurpose != .question
                        ? "lasso"
                        : "sparkles",
                    selected: mode == .lasso && lassoPurpose == .question
                ) {
                    if mode == .lasso, lassoPurpose == .question, !lassoSelection.isEmpty {
                        showNoteQuerySheet = true
                    } else {
                        selectedItemId = nil
                        lassoSelection = LassoSelection()
                        lassoPurpose = .question
                        mode = .lasso
                    }
                }
                .accessibilityIdentifier("note.tool.lasso")

                railToolButton(
                    lassoSelection.isEmpty || lassoPurpose != .mathematics ? "Math" : "Analyze",
                    systemImage: lassoSelection.isEmpty || lassoPurpose != .mathematics
                        ? "function"
                        : "text.viewfinder",
                    selected: mode == .lasso && lassoPurpose == .mathematics
                ) {
                    if mode == .lasso, lassoPurpose == .mathematics, !lassoSelection.isEmpty {
                        showMathAssistanceSheet = true
                    } else {
                        selectedItemId = nil
                        lassoSelection = LassoSelection()
                        lassoPurpose = .mathematics
                        mode = .lasso
                    }
                }
                .accessibilityHint(
                    "Select handwritten mathematics for recognition, worked steps, graphing, or error diagnosis"
                )
                .accessibilityIdentifier("note.tool.math-assistance")
            }

            Spacer(minLength: 8)

            railToolButton("Undo", systemImage: "arrow.uturn.backward") {
                sendCanvasCommand(.undo)
            }
            .disabled(isArchived)
            .keyboardShortcut("z", modifiers: .command)
            .accessibilityIdentifier("note.tool.undo")

            railToolButton("Redo", systemImage: "arrow.uturn.forward") {
                sendCanvasCommand(.redo)
            }
            .disabled(isArchived)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .accessibilityIdentifier("note.tool.redo")

            if configuration.pageFormat != .infinite {
                Divider().padding(.vertical, 2)
                pageJumpMenu
                railToolButton("Add page", systemImage: "plus.rectangle.on.rectangle") {
                    Task { await addPage() }
                }
                .disabled(isArchived)
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .accessibilityIdentifier("note.page.add")
            }
        }
        .foregroundStyle(EpistoriaDesign.ink)
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .frame(width: 82)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .trailing) { Divider() }
        .accessibilityElement(children: .contain)
    }

    private var tutorOverlay: some View {
        AdaptiveTutorView(
            model: model,
            topicId: note?.payload.topicId,
            initialMessage: tutorSelectionMessage,
            preferredEvidenceIds: tutorSelectionEvidenceIds,
            compact: true
        )
        .frame(width: 410)
        .frame(maxHeight: .infinity)
        .background(reduceTransparency ? EpistoriaDesign.page : Color.clear)
        .overlay(alignment: .leading) { Divider() }
        .shadow(color: reduceTransparency ? .clear : .black.opacity(0.12), radius: 18, x: -4)
        .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
    }

    private var tutorSelectionEvidenceIds: [UUID] {
        blocks.filter { lassoSelection.selectedBlockIds.contains($0.id) }
            .compactMap(\.payload.evidenceId)
    }

    private var tutorSelectionMessage: String? {
        let selected = blocks.filter { lassoSelection.selectedBlockIds.contains($0.id) }
        let text = selected.compactMap { block -> String? in
            let value = block.payload.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
            return block.payload.transcription?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        guard !text.isEmpty else { return nil }
        return
            "Help me understand this selected notebook material:\n\n\(String(text.prefix(8_000)))"
    }

    private var evidenceShelf: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Evidence").font(.headline)
                    Text("Drag to a page or select Insert")
                        .font(.caption)
                        .foregroundStyle(EpistoriaDesign.mutedInk)
                }
                Spacer()
                Button("Close", systemImage: "xmark") { showEvidenceShelf = false }
                    .labelStyle(.iconOnly)
            }
            .padding(16)
            Divider()

            if evidence.isEmpty {
                ContentUnavailableView(
                    "No Evidence yet",
                    systemImage: "quote.bubble",
                    description: Text(
                        "Create an annotation from a Source. It will remain anchored to that exact version."
                    )
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(evidence, id: \.id) { item in
                            evidenceShelfCard(item)
                                .draggable(item.id.uuidString) {
                                    evidenceDragPreview(item)
                                }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(width: 310)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .leading) { Divider() }
        .popover(
            isPresented: Binding(
                get: { inspectedEvidenceId != nil },
                set: { if !$0 { inspectedEvidenceId = nil } }
            ), arrowEdge: .trailing
        ) {
            evidenceBacklinksPopover
                .presentationCompactAdaptation(.popover)
        }
        .accessibilityIdentifier("note.evidence-shelf")
    }

    private func evidenceShelfCard(_ item: IdentifiedPayload<EvidencePayload>) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(evidenceDisplayText(item.payload))
                .font(.subheadline)
                .lineLimit(5)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(evidenceCitation(item.payload))
                .font(.caption)
                .foregroundStyle(EpistoriaDesign.mutedInk)
                .lineLimit(2)
            HStack {
                Button("Open source") { openedEvidenceId = item.id }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                Button("Backlinks") { Task { await inspectEvidence(item.id) } }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                Spacer()
                Button("Insert") {
                    Task { await addEvidence(item.id, pageIndex: currentPageIndex) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isArchived)
            }
        }
        .padding(12)
        .background(EpistoriaDesign.page, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(EpistoriaDesign.border, lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("note.evidence.\(item.id.uuidString)")
    }

    private var evidenceBacklinksPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Evidence backlinks").font(.headline)
                Spacer()
                Button("Close", systemImage: "xmark") { inspectedEvidenceId = nil }
                    .labelStyle(.iconOnly)
            }
            if inspectedEvidenceBacklinks.isEmpty {
                Text(
                    "This Evidence is not used by another note, Concept, card, or test question yet."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            } else {
                ForEach(inspectedEvidenceBacklinks) { backlink in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(backlink.title).lineLimit(2)
                            Text(backlink.kind.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: backlink.kind.symbol)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
    }

    private func evidenceDragPreview(_ item: IdentifiedPayload<EvidencePayload>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(evidenceDisplayText(item.payload)).font(.subheadline).lineLimit(3)
            Text(evidenceCitation(item.payload)).font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 260, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var pageJumpMenu: some View {
        Menu {
            ForEach(0..<finitePageCount, id: \.self) { pageIndex in
                Button {
                    Task { await switchPage(to: pageIndex) }
                } label: {
                    if pageIndex == currentPageIndex {
                        Label("Page \(pageIndex + 1)", systemImage: "checkmark")
                    } else {
                        Text("Page \(pageIndex + 1)")
                    }
                }
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 18, weight: .medium))
                Text("\(currentPageIndex + 1) / \(finitePageCount)")
                    .font(.caption2.monospacedDigit())
            }
            .frame(width: 68, height: 48)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Page \(currentPageIndex + 1) of \(finitePageCount)")
        .accessibilityIdentifier("note.page.indicator")
    }

    private func railToolButton(
        _ title: String,
        systemImage: String,
        selected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: selected ? .semibold : .regular))
                Text(title)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(width: 68, height: 48)
            .background(
                selected ? EpistoriaDesign.subtleFill : Color.clear,
                in: RoundedRectangle(
                    cornerRadius: EpistoriaDesign.compactRadius, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(EpistoriaPressButtonStyle())
    }

    private func strokeWidthButton(_ title: String, width: CGFloat) -> some View {
        Button {
            inkWidth = width
        } label: {
            if inkWidth == width {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private func handleInkToolTap(_ tool: SpatialNotebookInkTool) {
        if mode == .ink, inkTool == tool {
            switch tool {
            case .pen: showPenOptions = true
            case .marker: showMarkerOptions = true
            case .eraser: showEraserOptions = true
            }
        } else {
            selectInkTool(tool)
        }
    }

    private func handleShapeToolTap() {
        if mode == .shape {
            showShapeOptions = true
        } else {
            selectedItemId = nil
            editingItemId = nil
            lassoSelection = LassoSelection()
            mode = .shape
        }
    }

    private func handleSymbolToolTap() {
        if mode == .symbol {
            showSymbolOptions = true
        } else {
            selectedItemId = nil
            editingItemId = nil
            lassoSelection = LassoSelection()
            mode = .symbol
        }
    }

    private func inkOptions(title: String, widths: [CGFloat]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text("Tap the selected \(title.lowercased()) again to reopen these options.")
                    .font(.subheadline)
                    .foregroundStyle(EpistoriaDesign.mutedInk)
            }
            NotebookModifierPreview(
                name: title,
                value: "\(inkColor.label) · \(Int(inkWidth)) pt"
            ) {
                NotebookInkPreview(
                    color: inkColor,
                    width: inkWidth,
                    isMarker: title == "Marker"
                )
            }
            Text("Width")
                .font(.subheadline.weight(.medium))
            HStack(spacing: 10) {
                ForEach(widths, id: \.self) { width in
                    Button {
                        inkWidth = width
                    } label: {
                        Circle()
                            .fill(EpistoriaDesign.ink)
                            .frame(width: max(width, 4), height: max(width, 4))
                            .frame(width: 44, height: 40)
                            .background(
                                inkWidth == width ? EpistoriaDesign.subtleFill : Color.clear,
                                in: RoundedRectangle(cornerRadius: 7)
                            )
                    }
                    .buttonStyle(EpistoriaPressButtonStyle())
                    .accessibilityLabel("\(Int(width)) point width")
                }
            }
            Text("Color")
                .font(.subheadline.weight(.medium))
            colorPalette(selection: inkColor) { inkColor = $0 }
        }
        .padding(20)
        .frame(width: 330)
    }

    private var shapeOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Shape")
                    .font(.headline)
                Text("Choose a shape, then tap the page to place it.")
                    .font(.subheadline)
                    .foregroundStyle(EpistoriaDesign.mutedInk)
            }
            NotebookModifierPreview(
                name: "Shape",
                value: "\(selectedShapeKind.label) · \(Int(shapeLineWidth)) pt"
            ) {
                NotebookShapePreview(
                    shape: NoteCanvasShape(
                        kind: selectedShapeKind,
                        strokeColor: shapeStrokeColor,
                        fillColor: shapeFillColor,
                        lineWidth: shapeLineWidth
                    )
                )
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 10) {
                ForEach(NoteCanvasShapeKind.allCases, id: \.self) { kind in
                    Button {
                        selectedShapeKind = kind
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: kind.systemImage)
                                .font(.title3)
                            Text(kind.label)
                                .font(.caption2)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(
                            selectedShapeKind == kind ? EpistoriaDesign.subtleFill : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                    }
                    .buttonStyle(EpistoriaPressButtonStyle())
                }
            }
            Text("Outline")
                .font(.subheadline.weight(.medium))
            colorPalette(selection: shapeStrokeColor) { shapeStrokeColor = $0 }
            HStack {
                Text("Line width")
                Slider(value: $shapeLineWidth, in: 1...12, step: 1)
                Text("\(Int(shapeLineWidth))")
                    .monospacedDigit()
                    .frame(width: 22)
            }
            .font(.subheadline)
            Toggle(
                "Fill shape",
                isOn: Binding(
                    get: { shapeFillColor != nil },
                    set: { shapeFillColor = $0 ? .graphite : nil }
                )
            )
            if let fill = shapeFillColor {
                colorPalette(selection: fill) { shapeFillColor = $0 }
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var symbolOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Math symbols")
                    .font(.headline)
                Text("Choose a symbol, then tap the page to place an editable equation item.")
                    .font(.subheadline)
                    .foregroundStyle(EpistoriaDesign.mutedInk)
            }
            NotebookModifierPreview(name: "Math symbol", value: selectedMathSymbol) {
                Text(selectedMathSymbol)
                    .font(.system(size: 36, weight: .regular, design: .rounded))
                    .foregroundStyle(EpistoriaDesign.ink)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 8) {
                    ForEach(Self.mathSymbols, id: \.self) { symbol in
                        Button {
                            selectedMathSymbol = symbol
                        } label: {
                            Text(symbol)
                                .font(.title3)
                                .frame(maxWidth: .infinity, minHeight: 42)
                                .background(
                                    selectedMathSymbol == symbol
                                        ? EpistoriaDesign.subtleFill
                                        : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 7)
                                )
                        }
                        .buttonStyle(EpistoriaPressButtonStyle())
                        .accessibilityLabel("Math symbol \(symbol)")
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .padding(20)
        .frame(width: 380)
    }

    private func colorPalette(
        selection: NoteCanvasColor,
        onSelect: @escaping (NoteCanvasColor) -> Void
    ) -> some View {
        HStack(spacing: 10) {
            ForEach(NoteCanvasColor.allCases, id: \.self) { color in
                Button {
                    onSelect(color)
                } label: {
                    Circle()
                        .fill(Color(uiColor: color.uiColor))
                        .frame(width: 28, height: 28)
                        .overlay {
                            Circle().stroke(
                                selection == color ? EpistoriaDesign.ink : EpistoriaDesign.border,
                                lineWidth: selection == color ? 3 : 1
                            )
                        }
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(EpistoriaPressButtonStyle())
                .accessibilityLabel(color.label)
            }
        }
    }

    private static let mathSymbols = [
        "±", "×", "÷", "≠", "≈", "∝",
        "√", "∛", "x²", "xⁿ", "∑", "∏",
        "∫", "∂", "∇", "∞", "lim", "∆",
        "α", "β", "γ", "θ", "λ", "π",
        "σ", "φ", "ω", "∈", "∉", "⊂",
        "⊆", "∪", "∩", "∅", "∀", "∃",
        "⇒", "⇔", "≤", "≥", "⊥", "∥",
    ]

    private var eraserOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Eraser")
                    .font(.headline)
                Text("Choose how Pencil marks are removed.")
                    .font(.subheadline)
                    .foregroundStyle(EpistoriaDesign.mutedInk)
            }

            NotebookModifierPreview(
                name: "Eraser",
                value: eraserMode == .pixel
                    ? "Round · \(Int(eraserWidth)) pt"
                    : "Whole stroke"
            ) {
                NotebookEraserPreview(mode: eraserMode, width: eraserWidth)
            }

            eraserModeButton(
                .pixel,
                systemImage: "circle.dotted",
                detail: "Erase only the area under the circle."
            )
            eraserModeButton(
                .stroke,
                systemImage: "scribble.variable",
                detail: "Remove the complete stroke you touch."
            )

            if eraserMode == .pixel {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Eraser size")
                        .font(.subheadline.weight(.medium))
                    HStack {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 7))
                        Slider(value: $eraserWidth, in: 8...64, step: 2)
                        Image(systemName: "circle.fill")
                            .font(.system(size: 20))
                    }
                    Text("\(Int(eraserWidth)) pt")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(EpistoriaDesign.mutedInk)
                }
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func eraserModeButton(
        _ option: SpatialNotebookEraserMode,
        systemImage: String,
        detail: String
    ) -> some View {
        Button {
            eraserMode = option
            selectInkTool(.eraser)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(option.label)
                        .font(.subheadline.weight(.semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(EpistoriaDesign.mutedInk)
                }
                Spacer(minLength: 8)
                if eraserMode == option {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.semibold))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(EpistoriaPressButtonStyle())
        .accessibilityElement(children: .combine)
    }

    private func sendCanvasCommand(_ action: SpatialNotebookCommand.Action) {
        let command = SpatialNotebookCommand(action: action)
        canvasCommand = command
        DispatchQueue.main.async {
            if canvasCommand?.id == command.id { canvasCommand = nil }
        }
    }

    @ViewBuilder
    private var transientBottomMessage: some View {
        if isExportingPDF {
            HStack(spacing: 10) {
                ProgressView()
                Text("Creating readable PDF…")
            }
            .font(.subheadline)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 8)
        } else if let importProgress {
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
        } else if mode == .shape {
            Label(
                "Tap the page to place a \(selectedShapeKind.label.lowercased())",
                systemImage: selectedShapeKind.systemImage
            )
            .font(.subheadline)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 8)
        } else if mode == .symbol {
            Label("Tap the page to place \(selectedMathSymbol)", systemImage: "function")
                .font(.subheadline)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 8)
        }
    }

    private func canvasItems(on pageIndex: Int) -> [SpatialNotebookItem] {
        let pageBlocks = contentBlocks(on: pageIndex)
        let activeInkId = inkBlock(on: pageIndex)?.id
        return pageBlocks.enumerated().compactMap { index, block in
            guard block.id != activeInkId else { return nil }
            let placement =
                block.payload.canvasPlacement ?? legacyPlacement(for: block, index: index)
            let content: SpatialNotebookItem.Content
            switch block.payload.blockType {
            case .text, .equation:
                content = .text(decodeRichText(block.payload))
            case .callout:
                if let evidenceId = block.payload.evidenceId,
                    let item = evidence.first(where: { $0.id == evidenceId })
                {
                    let citation = evidenceCitation(item.payload)
                    content = .evidence(
                        evidenceAttributedText(item.payload, citation: citation), citation: citation
                    )
                } else {
                    content = .unsupported("Evidence unavailable")
                }
            case .image:
                if let image = imagePreviews[block.id] {
                    content = .image(
                        image,
                        filename: block.payload.plainText,
                        configuration: block.payload.imageConfiguration
                    )
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
            case .shape:
                if let shape = block.payload.canvasShape {
                    content = .shape(shape)
                } else {
                    content = .unsupported("Shape data unavailable")
                }
            default:
                content = .unsupported(
                    "Preserved \(block.payload.blockType.rawValue.lowercased()) item"
                )
            }
            return SpatialNotebookItem(id: block.id, placement: placement, content: content)
        }
    }

    private func contentBlocks(on pageIndex: Int) -> [IdentifiedPayload<NoteBlockPayload>] {
        blocks.filter {
            !$0.payload.tombstone
                && blockPageIndex($0.payload) == pageIndex
        }
    }

    private var visibleContentBlocks: [IdentifiedPayload<NoteBlockPayload>] {
        contentBlocks(on: currentPageIndex)
    }

    private func inkBlock(on pageIndex: Int) -> IdentifiedPayload<NoteBlockPayload>? {
        blocks.first {
            $0.payload.canvasRole == .inkLayer
                && !$0.payload.tombstone
                && blockPageIndex($0.payload) == pageIndex
        }
    }

    private var activeInkBlock: IdentifiedPayload<NoteBlockPayload>? {
        inkBlock(on: currentPageIndex)
    }

    private func hasLiveInk(on pageIndex: Int) -> Bool {
        !(inkDataByPage[pageIndex] ?? Data()).isEmpty
    }

    private var selectedBlock: IdentifiedPayload<NoteBlockPayload>? {
        guard let selectedItemId else { return nil }
        return blocks.first { $0.id == selectedItemId && $0.payload.canvasRole != .inkLayer }
    }

    private var isArchived: Bool { note?.payload.archivedAt != nil }

    private var pageConfigurations: [NoteCanvasConfiguration] {
        if pages.isEmpty { return [configuration] }
        return pages.map(\.payload.configuration)
    }

    private var finitePageCount: Int {
        configuration.pageFormat == .infinite ? 1 : max(pages.count, 1)
    }

    private func pageId(at pageIndex: Int) -> UUID? {
        pages.indices.contains(pageIndex) ? pages[pageIndex].id : nil
    }

    private func pageConfiguration(at pageIndex: Int) -> NoteCanvasConfiguration? {
        pages.indices.contains(pageIndex) ? pages[pageIndex].payload.configuration : nil
    }

    private func blockPageIndex(_ payload: NoteBlockPayload) -> Int {
        guard configuration.pageFormat != .infinite else { return 0 }
        if let pageId = payload.pageId,
           let index = pages.firstIndex(where: { $0.id == pageId })
        {
            return index
        }
        return 0
    }

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
        if ocrRecognitionState == .recognizing { return "Recognizing handwriting…" }
        if ocrRecognitionState == .formulaProcessing { return "Recognizing formula on this iPad" }
        let hasQueuedWork = model.pendingRecordCount + model.pendingFileCount > 0
        return note?.syncState == .synced && !hasQueuedWork
            ? "Saved · synced"
            : "Saved on this iPad"
    }

    private var statusSymbol: String {
        if case .tooLarge = inkSaveState { return "exclamationmark.triangle" }
        if inkSaveState == .saving || model.pendingSaves.count > 0 {
            return "arrow.triangle.2.circlepath"
        }
        if ocrRecognitionState == .recognizing { return "text.viewfinder" }
        if ocrRecognitionState == .formulaProcessing { return "function" }
        let hasQueuedWork = model.pendingRecordCount + model.pendingFileCount > 0
        return note?.syncState == .synced && !hasQueuedWork ? "checkmark.circle" : "ipad"
    }

    private func load() async {
        guard let store = model.store else { return }
        let isInitialLoad = isLoading
        do {
            let loadedPages = try await store.ensureNotePages(noteId: noteId)
            let loadedNote = try await store.payload(NotePayload.self, id: noteId)
            async let loadedBlocks = store.list(NoteBlockPayload.self, parentId: noteId)
            async let loadedSourcePage = store.listPage(
                SourcePayload.self,
                parentId: loadedNote.payload.topicId,
                limit: 50
            )
            async let loadedOCR = store.ocrArtifacts(parentId: noteId)
            let (loadedBlockValues, sourcePage, initialOCR) = try await (
                loadedBlocks, loadedSourcePage, loadedOCR
            )
            note = loadedNote
            pages = loadedPages
            configuration = loadedPages.first?.payload.configuration
                ?? loadedNote.payload.canvas
                ?? NoteCanvasConfiguration()
            if title != loadedNote.payload.title {
                suppressNextTitleChange = true
                title = loadedNote.payload.title
            }
            blocks = loadedBlockValues.sorted { $0.payload.orderKey < $1.payload.orderKey }
            let shelfEvidence = try await store.list(
                EvidencePayload.self,
                parentIds: sourcePage.items.map(\.id),
                limit: 500
            )
            let referencedEvidence = try await store.payloads(
                EvidencePayload.self,
                ids: Array(Set(blocks.compactMap(\.payload.evidenceId)))
            )
            var evidenceById = Dictionary(uniqueKeysWithValues: shelfEvidence.map { ($0.id, $0) })
            for item in referencedEvidence { evidenceById[item.id] = item }
            let loadedEvidence = Array(evidenceById.values)
            var sourceById = Dictionary(uniqueKeysWithValues: sourcePage.items.map { ($0.id, $0) })
            let missingSourceIds = Array(Set(loadedEvidence.map(\.payload.sourceId))).filter { sourceById[$0] == nil }
            for source in try await store.payloads(SourcePayload.self, ids: missingSourceIds) {
                sourceById[source.id] = source
            }
            let loadedVersions = try await store.payloads(
                SourceVersionPayload.self,
                ids: Array(Set(loadedEvidence.map(\.payload.sourceVersionId)))
            )
            var reconciledOCR = false
            for block in blocks where initialOCR.contains(where: {
                $0.payload.targetKind == .notebookRegion
                    && $0.payload.targetId == block.id
                    && $0.payload.state == .current
                    && $0.payload.inputRevision != block.payload.ocrInputRevision
                }) {
                try await store.markOCRArtifactsStale(
                    targetId: block.id,
                    exceptInputRevision: block.payload.ocrInputRevision
                )
                reconciledOCR = true
            }
            sourcesById = sourceById
            sourceVersionsById = Dictionary(uniqueKeysWithValues: loadedVersions.map { ($0.id, $0) })
            ocrArtifacts = reconciledOCR
                ? try await store.ocrArtifacts(parentId: noteId)
                : initialOCR
            evidence = loadedEvidence.filter { sourcesById[$0.payload.sourceId] != nil }
                .sorted { $0.payload.updatedAt > $1.payload.updatedAt }
            if configuration.pageFormat == .infinite {
                currentPageIndex = 0
            } else if isInitialLoad,
                let activeFocusedBlockId,
                let focused = blocks.first(where: { $0.id == activeFocusedBlockId })
            {
                currentPageIndex = min(max(blockPageIndex(focused.payload), 0), finitePageCount - 1)
            } else {
                currentPageIndex = min(max(currentPageIndex, 0), finitePageCount - 1)
            }
            if let currentConfiguration = pageConfiguration(at: currentPageIndex),
               configuration.pageFormat != .infinite
            {
                configuration = currentConfiguration
            }
            var loadedInk: [Int: Data] = [:]
            for block in blocks
            where block.payload.canvasRole == .inkLayer && !block.payload.tombstone {
                loadedInk[blockPageIndex(block.payload)] = block.payload.drawingData ?? Data()
            }
            inkDataByPage = loadedInk
            viewportCenter = pageCenter
            await loadImagePreviews(around: currentPageIndex)
            isLoading = false
            if isInitialLoad, configuration.pageFormat != .infinite {
                requestedPageIndex = currentPageIndex
            }
        } catch {
            isLoading = false
            report(error)
        }
    }

    private func loadImagePreviews(around pageIndex: Int) async {
        guard let assetManager = model.assetManager else { return }
        previewLoadGeneration &+= 1
        let generation = previewLoadGeneration
        let lowerPage = max(pageIndex - 1, 0)
        let upperPage =
            configuration.pageFormat == .infinite
            ? 0
            : min(pageIndex + 1, finitePageCount - 1)
        let retainedBlocks = blocks.filter {
            !$0.payload.tombstone
                && $0.payload.blockType == .image
                && (lowerPage...upperPage).contains(blockPageIndex($0.payload))
        }
        let retainedIDs = Set(retainedBlocks.map(\.id))
        var loaded = imagePreviews.filter { retainedIDs.contains($0.key) }
        for block in retainedBlocks where loaded[block.id] == nil {
            guard let assetId = block.payload.assetId else { continue }
            do {
                let data = try await assetManager.decryptedData(assetId: assetId)
                if let image = downsampledImage(data) { loaded[block.id] = image }
            } catch {
                report(error)
            }
        }
        guard generation == previewLoadGeneration else { return }
        imagePreviews = loaded
    }

    private func prepareVisiblePage(_ pageIndex: Int) async {
        guard abs(pageIndex - currentPageIndex) <= 1 else { return }
        await loadImagePreviews(around: currentPageIndex)
    }

    private func currentPageDidChange() async {
        selectedItemId = nil
        editingItemId = nil
        lassoSelection = LassoSelection()
        viewportCenter = pageCenter
        inkSaveState = .idle
        await loadImagePreviews(around: currentPageIndex)
        if mode == .ink {
            do { try await ensureInkLayer(on: currentPageIndex) } catch { report(error) }
        }
    }

    private var pageCenter: CGPoint {
        CGPoint(
            x: (configuration.pageWidth ?? 595) / 2,
            y: (configuration.pageHeight ?? 842) / 2
        )
    }

    private func selectInkTool(_ tool: SpatialNotebookInkTool) {
        inkTool = tool
        switch tool {
        case .pen where inkWidth > 8:
            inkWidth = 4
        case .marker where inkWidth < 10:
            inkWidth = 18
        default:
            break
        }
        Task { await activateInk() }
    }

    private func activateInk() async {
        guard !isArchived else { return }
        do {
            try await flushTitle()
            try await ensureInkLayer(on: currentPageIndex)
            selectedItemId = nil
            editingItemId = nil
            mode = .ink
        } catch { report(error) }
    }

    private func ensureInkLayer(on pageIndex: Int) async throws {
        guard inkBlock(on: pageIndex) == nil else { return }
        guard !creatingInkPages.contains(pageIndex) else { return }
        guard let store = model.store else {
            throw NoteEditorSaveError.encryptedStoreUnavailable
        }
        creatingInkPages.insert(pageIndex)
        defer { creatingInkPages.remove(pageIndex) }
        let id = try await store.appendCanvasInkLayer(
            noteId: noteId,
            pageId: pageId(at: pageIndex)
        )
        let block = try await store.payload(NoteBlockPayload.self, id: id)
        blocks.append(block)
        blocks.sort { $0.payload.orderKey < $1.payload.orderKey }
        inkDataByPage[pageIndex] = block.payload.drawingData ?? Data()
        model.noteLocalMutation()
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
                placement: placement,
                pageId: pageId(at: currentPageIndex)
            )
            model.noteLocalMutation()
            try await refreshBlock(id)
            selectedItemId = id
            editingItemId = id
            mode = .select
        } catch { report(error) }
    }

    private func addEvidence(_ evidenceId: UUID, pageIndex: Int) async {
        guard !isArchived, evidence.contains(where: { $0.id == evidenceId }) else { return }
        do {
            try await flushTitle()
            guard let store = model.store else {
                throw NoteEditorSaveError.encryptedStoreUnavailable
            }
            let width = min(390.0, max((configuration.pageWidth ?? 480) - 72, 260))
            let placement = placementCentered(width: width, height: 170, zIndex: nextZIndex)
            let id = try await store.appendCanvasEvidence(
                noteId: noteId,
                evidenceId: evidenceId,
                placement: placement,
                pageId: pageId(at: pageIndex)
            )
            model.noteLocalMutation()
            try await refreshBlock(id)
            currentPageIndex = pageIndex
            selectedItemId = id
            editingItemId = nil
            mode = .select
        } catch { report(error) }
    }

    private func inspectEvidence(_ evidenceId: UUID) async {
        guard let store = model.store else { return }
        do {
            inspectedEvidenceBacklinks = try await store.evidenceBacklinks(evidenceId: evidenceId)
            inspectedEvidenceId = evidenceId
        } catch { report(error) }
    }

    private func placeActiveTool(at point: CGPoint, pageIndex: Int) async {
        guard pageIndex == currentPageIndex else { return }
        switch mode {
        case .shape:
            await addShape(at: point, pageIndex: pageIndex)
        case .symbol:
            await addMathSymbol(at: point, pageIndex: pageIndex)
        default:
            break
        }
    }

    private func addShape(at point: CGPoint, pageIndex: Int) async {
        guard !isArchived else { return }
        do {
            try await flushTitle()
            guard let store = model.store else {
                throw NoteEditorSaveError.encryptedStoreUnavailable
            }
            let isLinear = selectedShapeKind == .line || selectedShapeKind == .arrow
            let size = isLinear ? CGSize(width: 240, height: 96) : CGSize(width: 190, height: 150)
            let placement = placement(
                centeredAt: point,
                width: Double(size.width),
                height: Double(size.height),
                zIndex: nextZIndex
            )
            let shape = NoteCanvasShape(
                kind: selectedShapeKind,
                strokeColor: shapeStrokeColor,
                fillColor: isLinear ? nil : shapeFillColor,
                lineWidth: shapeLineWidth
            )
            let id = try await store.appendCanvasShape(
                noteId: noteId,
                shape: shape,
                placement: placement,
                pageId: pageId(at: pageIndex)
            )
            model.noteLocalMutation()
            try await refreshBlock(id)
            selectedItemId = id
        } catch { report(error) }
    }

    private func addMathSymbol(at point: CGPoint, pageIndex: Int) async {
        guard !isArchived else { return }
        do {
            try await flushTitle()
            guard let store = model.store else {
                throw NoteEditorSaveError.encryptedStoreUnavailable
            }
            let placement = placement(
                centeredAt: point,
                width: selectedMathSymbol.count > 1 ? 150 : 100,
                height: 84,
                zIndex: nextZIndex
            )
            let id = try await store.appendCanvasEquation(
                noteId: noteId,
                symbol: selectedMathSymbol,
                placement: placement,
                pageId: pageId(at: pageIndex)
            )
            model.noteLocalMutation()
            try await refreshBlock(id)
            selectedItemId = id
        } catch { report(error) }
    }

    private func addEquation(content: String) async {
        guard !isArchived else { return }
        let value = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do {
            try await flushTitle()
            guard let store = model.store else {
                throw NoteEditorSaveError.encryptedStoreUnavailable
            }
            let width = min(440.0, max((configuration.pageWidth ?? 520) - 72, 260))
            let placement = placementCentered(width: width, height: 100, zIndex: nextZIndex)
            let id = try await store.appendCanvasEquation(
                noteId: noteId,
                symbol: value,
                placement: placement,
                pageId: pageId(at: currentPageIndex)
            )
            model.noteLocalMutation()
            try await refreshBlock(id)
            selectedItemId = id
            editingItemId = nil
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
            try await placeImportedImage(imported, store: store)
        } catch is CancellationError {
            importProgress = nil
        } catch {
            importProgress = nil
            report(error)
        }
    }

    private func importPhoto(_ item: PhotosPickerItem) async {
        defer { selectedPhotoItem = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw NoteEditorSaveError.imagePreviewUnavailable
            }
            await importImageData(data, filename: "Photo")
        } catch { report(error) }
    }

    private func pasteImage() async {
        guard let image = UIPasteboard.general.image,
              let data = image.pngData()
        else { return }
        await importImageData(data, filename: "Pasted image.png")
    }

    private func importImageData(_ data: Data, filename: String) async {
        guard !isArchived, let assetManager = model.assetManager, let store = model.store else {
            return
        }
        do {
            importProgress = "Encrypting original image…"
            try await flushTitle()
            let imported = try await assetManager.importImage(data: data, filename: filename)
            try await placeImportedImage(imported, store: store)
        } catch {
            importProgress = nil
            report(error)
        }
    }

    private func placeImportedImage(_ imported: ImportedImage, store: EpistoriaStore) async throws {
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
            placement: placement,
            pageId: pageId(at: currentPageIndex)
        )
        model.noteLocalMutation()
        importProgress = nil
        try await refreshBlock(id)
        await loadImagePreviews(around: currentPageIndex)
        selectedItemId = id
        mode = .select
    }

    private func saveImageConfiguration(
        blockId: UUID,
        configuration: NoteCanvasImageConfiguration
    ) async throws {
        guard !isArchived, let store = model.store else {
            throw NoteEditorSaveError.encryptedStoreUnavailable
        }
        try await model.pendingSaves.flush(id: blockId)
        _ = try await store.updateCanvasImage(id: blockId, configuration: configuration)
        model.noteLocalMutation()
        try await refreshBlock(blockId)
    }

    private func replaceImage(
        blockId: UUID,
        from url: URL,
        configuration: NoteCanvasImageConfiguration
    ) async throws {
        guard !isArchived,
              let store = model.store,
              let assetManager = model.assetManager
        else { throw NoteEditorSaveError.encryptedStoreUnavailable }
        try await model.pendingSaves.flush(id: blockId)
        let imported = try await assetManager.importImage(from: url)
        _ = try await store.updateCanvasImage(
            id: blockId,
            configuration: configuration,
            replacementAssetId: imported.assetId,
            replacementFilename: imported.filename
        )
        model.noteLocalMutation()
        imagePreviews[blockId] = nil
        try await refreshBlock(blockId)
        ocrArtifacts = try await store.ocrArtifacts(parentId: noteId)
        await loadImagePreviews(around: currentPageIndex)
    }

    private func replaceImage(
        blockId: UUID,
        data: Data,
        filename: String,
        configuration: NoteCanvasImageConfiguration
    ) async throws {
        guard !isArchived,
              let store = model.store,
              let assetManager = model.assetManager
        else { throw NoteEditorSaveError.encryptedStoreUnavailable }
        try await model.pendingSaves.flush(id: blockId)
        let imported = try await assetManager.importImage(data: data, filename: filename)
        _ = try await store.updateCanvasImage(
            id: blockId,
            configuration: configuration,
            replacementAssetId: imported.assetId,
            replacementFilename: imported.filename
        )
        model.noteLocalMutation()
        imagePreviews[blockId] = nil
        try await refreshBlock(blockId)
        ocrArtifacts = try await store.ocrArtifacts(parentId: noteId)
        await loadImagePreviews(around: currentPageIndex)
    }

    private func restoreOriginalImage(
        blockId: UUID,
        configuration: NoteCanvasImageConfiguration
    ) async throws {
        guard !isArchived,
              let store = model.store,
              let block = blocks.first(where: { $0.id == blockId }),
              let originalAssetId = block.payload.imageConfiguration?.originalAssetId
        else { throw NoteEditorSaveError.imagePreviewUnavailable }
        let asset = try await store.payload(AssetPayload.self, id: originalAssetId)
        try await model.pendingSaves.flush(id: blockId)
        _ = try await store.updateCanvasImage(
            id: blockId,
            configuration: configuration,
            replacementAssetId: originalAssetId,
            replacementFilename: asset.payload.originalFilename
        )
        model.noteLocalMutation()
        imagePreviews[blockId] = nil
        try await refreshBlock(blockId)
        ocrArtifacts = try await store.ocrArtifacts(parentId: noteId)
        await loadImagePreviews(around: currentPageIndex)
    }

    private func savePlacement(id: UUID, placement: NoteCanvasPlacement) {
        guard !isArchived, var block = blocks.first(where: { $0.id == id }) else { return }
        block.payload.schemaVersion = "note-block/v8"
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
            block.payload.schemaVersion = "note-block/v8"
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
                relationIds: [
                    snapshot.noteId,
                    snapshot.pageId,
                    snapshot.assetId,
                    snapshot.imageConfiguration?.originalAssetId,
                    snapshot.evidenceId,
                ].compactMap(\.self)
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

    private func saveInk(_ value: Data, on pageIndex: Int) {
        guard !isArchived, let inkBlock = inkBlock(on: pageIndex) else { return }
        inkSaveBuffer.pendingTaskByBlock[inkBlock.id]?.cancel()
        let generation = inkSaveBuffer.nextGeneration(for: inkBlock.id)
        guard value.count <= maximumCanvasDrawingBytes else {
            if pageIndex == currentPageIndex { inkSaveState = .tooLarge(value.count) }
            return
        }
        inkDataByPage[pageIndex] = value
        if pageIndex == currentPageIndex { inkSaveState = .saving }
        let previousDrawingData = inkBlock.payload.drawingData
        var snapshot = inkBlock.payload
        snapshot.schemaVersion = "note-block/v8"
        snapshot.drawingData = value
        snapshot.updatedAt = .now
        var localBlock = inkBlock
        localBlock.payload = snapshot
        replaceLocalBlock(localBlock)
        model.pendingSaves.stage(id: inkBlock.id) {
            guard let store = model.store else {
                throw NoteEditorSaveError.encryptedStoreUnavailable
            }
            _ = try await store.save(
                id: inkBlock.id,
                payload: snapshot,
                parentId: snapshot.noteId,
                relationIds: [snapshot.noteId, snapshot.pageId].compactMap(\.self)
            )
            if inkSaveBuffer.isCurrent(generation, for: inkBlock.id),
                pageIndex == currentPageIndex
            {
                inkSaveState = .saved
            }
            model.noteLocalMutation()
        }
        inkSaveBuffer.pendingTaskByBlock[inkBlock.id] = Task {
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
            do {
                try await model.pendingSaves.flush(id: inkBlock.id)
                guard !Task.isCancelled,
                    inkSaveBuffer.isCurrent(generation, for: inkBlock.id)
                else { return }
                try? await Task.sleep(for: .milliseconds(2_350))
                guard !Task.isCancelled,
                    inkSaveBuffer.isCurrent(generation, for: inkBlock.id)
                else { return }
                await recognizeSavedInk(
                    blockId: inkBlock.id,
                    pageIndex: pageIndex,
                    drawingData: value,
                    previousDrawingData: previousDrawingData
                )
            } catch {
                if inkSaveBuffer.isCurrent(generation, for: inkBlock.id),
                    pageIndex == currentPageIndex
                {
                    inkSaveState = .idle
                }
                report(error)
            }
        }
    }

    private func recognizeSavedInk(
        blockId: UUID,
        pageIndex: Int,
        drawingData: Data,
        previousDrawingData: Data?
    ) async {
        guard !pencilStrokeActivePages.contains(pageIndex),
            model.localProcessingSettings.automaticNotebookOCR,
            !drawingData.isEmpty,
            let accountId = model.configuration?.accountId,
            let store = model.store
        else { return }
        do {
            let savedBlock = try await store.payload(NoteBlockPayload.self, id: blockId)
            guard savedBlock.payload.drawingData == drawingData else { return }
            try await store.markOCRArtifactsStale(
                targetId: blockId,
                exceptInputRevision: savedBlock.payload.ocrInputRevision
            )
            if ocrArtifacts.contains(where: {
                $0.payload.targetId == blockId
                    && $0.payload.inputRevision == savedBlock.payload.ocrInputRevision
                    && $0.payload.response.engine == .appleVision
                    && $0.payload.state == .current
            }) { return }
            ocrRecognitionState = .recognizing
            let captures = try await LocalTextOCRService.recognizeChangedInk(
                accountId: accountId,
                noteId: noteId,
                blockId: blockId,
                inputRevision: savedBlock.payload.ocrInputRevision,
                pageIndex: pageIndex,
                pageSize: CGSize(
                    width: configuration.pageWidth ?? 2_200,
                    height: configuration.pageHeight ?? 2_200
                ),
                drawingData: drawingData,
                previousDrawingData: previousDrawingData,
                preferredLanguages: model.localProcessingSettings.normalizedLanguages
            )
            for capture in captures {
                _ = try await store.saveOCRArtifact(
                    request: capture.request,
                    response: capture.response
                )
                if model.localProcessingSettings.localMathOCR,
                    capture.suggestsFormula || looksMathematical(capture.response)
                {
                    var formulaRequest = capture.request
                    formulaRequest.jobId = UUID()
                    formulaRequest.mode = .formula
                    ocrRecognitionState = .formulaProcessing
                    let formulaResponse = try await model.recognizeFormulaOnDevice(formulaRequest)
                    _ = try await store.saveOCRArtifact(
                        request: formulaRequest,
                        response: formulaResponse
                    )
                }
            }
            model.noteLocalMutation()
            ocrArtifacts = try await store.ocrArtifacts(parentId: noteId)
            ocrRecognitionState = .idle
        } catch LocalTextOCRError.emptyDrawing {
            ocrRecognitionState = .idle
        } catch {
            ocrRecognitionState = .idle
            report(error)
        }
    }

    private func recognizePageAfterExit(_ pageIndex: Int) async {
        guard model.localProcessingSettings.automaticNotebookOCR,
              let block = inkBlock(on: pageIndex),
              let drawingData = inkDataByPage[pageIndex] ?? block.payload.drawingData,
              !drawingData.isEmpty
        else { return }
        try? await model.pendingSaves.flush(id: block.id)
        await recognizeSavedInk(
            blockId: block.id,
            pageIndex: pageIndex,
            drawingData: drawingData,
            previousDrawingData: nil
        )
    }

    private func looksMathematical(_ response: LocalOCRResponse) -> Bool {
        let text = response.regions.map(\.text).joined(separator: " ")
        let markers = CharacterSet(charactersIn: "=+−-×÷/√∫∑^<>≤≥()[]{}")
        if text.rangeOfCharacter(from: markers) != nil { return true }
        return text.range(of: #"\b\d*[a-zA-Z]\s*[²³0-9]?\s*[=+\-/]"#, options: .regularExpression)
            != nil
    }

    private func clearInk() {
        guard !isArchived, activeInkBlock != nil else { return }
        inkDataByPage[currentPageIndex] = Data()
        saveInk(Data(), on: currentPageIndex)
    }

    private func setPage(
        format: NotePageFormat,
        orientation: NotePageOrientation
    ) async {
        do {
            if format == .infinite, finitePageCount > 1 {
                throw NoteEditorSaveError.multiPageRequiresFixedPaper
            }
            var changed = configuration
            changed.schemaVersion = "note-canvas/v4"
            changed.pageFormat = format
            changed.orientation = orientation
            try await persistCanvasConfiguration(changed)
            currentPageIndex =
                format == .infinite
                ? 0
                : min(currentPageIndex, max(pages.count - 1, 0))
            requestedPageIndex = format == .infinite ? nil : currentPageIndex
            viewportCenter = pageCenter
        } catch { report(error) }
    }

    private func setPaperStyle(_ style: NotePaperStyle) async {
        do {
            var changed = configuration
            changed.schemaVersion = "note-canvas/v4"
            changed.paperStyle = style
            try await persistCanvasConfiguration(changed)
        } catch { report(error) }
    }

    private func setPaperSpacing(_ spacing: Double) async {
        do {
            var changed = configuration
            changed.schemaVersion = "note-canvas/v4"
            changed.paperSpacing = min(max(spacing, 12), 72)
            try await persistCanvasConfiguration(changed)
        } catch { report(error) }
    }

    private func setPaperColor(_ color: NotePaperColor) async {
        do {
            var changed = configuration
            changed.schemaVersion = "note-canvas/v4"
            changed.paperColor = color
            try await persistCanvasConfiguration(changed)
        } catch { report(error) }
    }

    private func addPage() async {
        guard !isArchived, configuration.pageFormat != .infinite else { return }
        do {
            let continueInking = mode == .ink
            guard let store = model.store else {
                throw NoteEditorSaveError.encryptedStoreUnavailable
            }
            try await flushPendingChanges()
            let created = try await store.insertNotePage(
                noteId: noteId,
                after: pageId(at: currentPageIndex),
                configuration: configuration
            )
            pages = try await store.notePages(noteId: noteId)
            let newPageIndex = pages.firstIndex(where: { $0.id == created }) ?? max(pages.count - 1, 0)
            currentPageIndex = newPageIndex
            requestedPageIndex = newPageIndex
            if continueInking {
                try await ensureInkLayer(on: newPageIndex)
            }
            model.noteLocalMutation()
        } catch { report(error) }
    }

    private func switchPage(to requestedIndex: Int) async {
        guard configuration.pageFormat != .infinite else { return }
        let target = min(max(requestedIndex, 0), finitePageCount - 1)
        guard target != currentPageIndex else { return }
        do {
            try await flushPendingChanges()
            requestedPageIndex = target
        } catch { report(error) }
    }

    private func persistCanvasConfiguration(
        _ changed: NoteCanvasConfiguration
    ) async throws {
        guard changed != configuration else { return }
        guard let store = model.store else {
            throw NoteEditorSaveError.encryptedStoreUnavailable
        }
        try await flushPendingChanges()
        let currentPageId = pageId(at: currentPageIndex)
        try await store.updateNoteCanvasConfiguration(
            noteId: noteId,
            pageId: currentPageId,
            configuration: changed
        )
        note = try await store.payload(NotePayload.self, id: noteId)
        pages = try await store.notePages(noteId: noteId)
        blocks = try await store.list(NoteBlockPayload.self, parentId: noteId)
            .sorted { $0.payload.orderKey < $1.payload.orderKey }
        configuration = pages.first(where: { $0.id == currentPageId })?.payload.configuration
            ?? pages.first?.payload.configuration
            ?? note?.payload.canvas
            ?? changed
        model.noteLocalMutation()
    }

    private func moveLayer(
        _ block: IdentifiedPayload<NoteBlockPayload>,
        direction: Int
    ) {
        let current =
            block.payload.canvasPlacement
            ?? legacyPlacement(
                for: block, index: visibleContentBlocks.firstIndex { $0.id == block.id } ?? 0)
        var changed = current
        changed.zIndex = min(max(current.zIndex + direction, -10_000), 10_000)
        savePlacement(id: block.id, placement: changed)
    }

    private func deleteBlock(_ block: IdentifiedPayload<NoteBlockPayload>) async {
        guard !isArchived, let store = model.store else { return }
        do {
            try await model.pendingSaves.flush(id: block.id)
            let trashId = try await store.moveNoteBlockToTrash(
                id: block.id,
                displayName: block.payload.plainText.isEmpty ? "Canvas item" : String(block.payload.plainText.prefix(80))
            )
            recentlyDeleted = block
            recentlyDeletedTrashEntryId = trashId
            selectedItemId = nil
            imagePreviews[block.id] = nil
            blocks.removeAll { $0.id == block.id }
            model.noteLocalMutation()
        } catch { report(error) }
    }

    private func undoDelete(_ deleted: IdentifiedPayload<NoteBlockPayload>) async {
        guard let store = model.store, let trashId = recentlyDeletedTrashEntryId else { return }
        do {
            try await store.restoreTrashEntry(id: trashId)
            recentlyDeleted = nil
            recentlyDeletedTrashEntryId = nil
            selectedItemId = deleted.id
            model.noteLocalMutation()
            try await refreshBlock(deleted.id)
            await loadImagePreviews(around: currentPageIndex)
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
        note.payload.schemaVersion = "note/v5"
        note.payload.archivedAt = archived ? .now : nil
        note.payload.updatedAt = .now
        do {
            _ = try await store.save(
                id: note.id,
                payload: note.payload,
                parentId: note.payload.topicId ?? note.payload.studySessionId,
                relationIds: [note.payload.topicId, note.payload.studySessionId].compactMap(\.self)
            )
            self.note = note
            model.noteLocalMutation()
            onLifecycleChanged?()
            if archived { dismiss() }
        } catch { report(error) }
    }

    private func exportPDF(options: NotePDFExportOptions) async {
        guard !isExportingPDF else { return }
        isExportingPDF = true
        defer {
            isExportingPDF = false
            pdfExportTask = nil
        }
        do {
            pdfExportResult = try await model.createNotePDF(noteId: noteId, options: options)
        } catch is CancellationError {
            // Leaving the editor cancels the readable export and removes its partial file.
        } catch {
            report(error)
        }
    }

    private func startPDFExport(options: NotePDFExportOptions) {
        guard pdfExportTask == nil else { return }
        pdfExportTask = Task { await exportPDF(options: options) }
    }

    private func removePDFExport(_ result: NotePDFExportResult) {
        do {
            try NotePDFExportService.removeTemporaryPDF(result.fileURL)
            pdfExportResult = nil
        } catch {
            report(error)
        }
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
            note.payload.schemaVersion = "note/v5"
            note.payload.title = clean
            note.payload.updatedAt = .now
            _ = try await store.save(
                id: note.id,
                payload: note.payload,
                parentId: note.payload.topicId ?? note.payload.studySessionId,
                relationIds: [note.payload.topicId, note.payload.studySessionId].compactMap(\.self)
            )
            self.note = note
            model.noteLocalMutation()
        } catch {
            report(error)
            throw error
        }
    }

    private func saveAll() async {
        do { try await flushPendingChanges() } catch { report(error) }
    }

    private func flushPendingChanges() async throws {
        inkSaveBuffer.pendingTaskByBlock.values.forEach { $0.cancel() }
        blockSaveTasks.values.forEach { $0.cancel() }
        try await flushTitle()
        try await model.pendingSaves.flushAll()
    }

    private func replaceLocalBlock(_ changed: IdentifiedPayload<NoteBlockPayload>) {
        guard let index = blocks.firstIndex(where: { $0.id == changed.id }) else { return }
        blocks[index] = changed
    }

    private func refreshBlock(_ id: UUID) async throws {
        guard let store = model.store else {
            throw NoteEditorSaveError.encryptedStoreUnavailable
        }
        let changed = try await store.payload(NoteBlockPayload.self, id: id)
        if let index = blocks.firstIndex(where: { $0.id == id }) {
            blocks[index] = changed
        } else {
            blocks.append(changed)
        }
        blocks.sort { $0.payload.orderKey < $1.payload.orderKey }
    }

    private func legacyPlacement(
        for block: IdentifiedPayload<NoteBlockPayload>,
        index: Int
    ) -> NoteCanvasPlacement {
        let pageWidth = configuration.pageWidth ?? 595
        let width = min(max(pageWidth - 96, 260), 640)
        var y = 72.0
        for preceding in contentBlocks(on: blockPageIndex(block.payload)).prefix(index) {
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
        case .equation: 100
        case .shape: 160
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

    private func placement(
        centeredAt point: CGPoint,
        width: Double,
        height: Double,
        zIndex: Int
    ) -> NoteCanvasPlacement {
        var x = Double(point.x) - width / 2
        var y = Double(point.y) - height / 2
        if let pageWidth = configuration.pageWidth, let pageHeight = configuration.pageHeight {
            x = min(max(x, 16), max(pageWidth - width - 16, 16))
            y = min(max(y, 16), max(pageHeight - height - 16, 16))
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
        let font =
            payload.blockType == .equation
            ? UIFont.systemFont(ofSize: 34, weight: .regular)
            : UIFont.preferredFont(forTextStyle: .body)
        return NSAttributedString(string: payload.plainText, attributes: [.font: font])
    }

    private func evidenceDisplayText(_ payload: EvidencePayload) -> String {
        let excerpt = payload.excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !excerpt.isEmpty { return excerpt }
        return payload.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Evidence"
    }

    private func evidenceCitation(_ payload: EvidencePayload) -> String {
        let source = sourcesById[payload.sourceId]?.payload.title ?? "Source"
        let version: String
        if let number = sourceVersionsById[payload.sourceVersionId]?.payload.versionNumber {
            version = "Version \(number)"
        } else {
            version = "Saved version"
        }
        return "\(source) · \(evidenceLocatorLabel(payload.locator)) · \(version)"
    }

    private func evidenceLocatorLabel(_ locator: SourceLocator) -> String {
        switch locator.kind {
        case .pdf: return locator.page.map { "Page \($0)" } ?? "PDF"
        case .epub: return locator.chapter ?? "EPUB location"
        case .web: return locator.heading ?? "Web excerpt"
        case .media:
            let start = evidenceMediaTimeLabel(locator.startSeconds ?? 0)
            guard let end = locator.endSeconds, end > (locator.startSeconds ?? 0) else {
                return start
            }
            return "\(start)–\(evidenceMediaTimeLabel(end))"
        case .document:
            return locator.heading ?? locator.page.map { "Page \($0)" } ?? "Document excerpt"
        case .image: return "Image region"
        case .plainText: return "Text excerpt"
        case .slide: return locator.slide.map { "Slide \($0)" } ?? "Slide excerpt"
        case .sheet:
            let value = [locator.sheet, locator.cellRange].compactMap(\.self).joined(
                separator: " · ")
            return value.isEmpty ? "Sheet excerpt" : value
        }
    }

    private func evidenceMediaTimeLabel(_ value: Double) -> String {
        let seconds = max(Int(value.isFinite ? value.rounded(.down) : 0), 0)
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%d:%02d", minutes, remainder)
    }

    private func evidenceAttributedText(
        _ payload: EvidencePayload,
        citation: String
    ) -> NSAttributedString {
        let value = NSMutableAttributedString(
            string: evidenceDisplayText(payload),
            attributes: [
                .font: UIFont.preferredFont(forTextStyle: .body),
                .foregroundColor: UIColor.label,
            ]
        )
        value.append(
            NSAttributedString(
                string: "\n\n\(citation)",
                attributes: [
                    .font: UIFont.preferredFont(forTextStyle: .caption1),
                    .foregroundColor: UIColor.secondaryLabel,
                ]
            ))
        return value
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

extension EvidenceBacklinkKind {
    fileprivate var displayName: String {
        switch self {
        case .note: "Note"
        case .concept: "Concept"
        case .flashcard: "Flashcard"
        case .testQuestion: "Test question"
        }
    }

    fileprivate var symbol: String {
        switch self {
        case .note: "note.text"
        case .concept: "point.3.connected.trianglepath.dotted"
        case .flashcard: "rectangle.stack"
        case .testQuestion: "checkmark.square"
        }
    }
}

private struct NotePDFExportOptionsView: View {
    private enum PageSelection: String, CaseIterable, Identifiable {
        case all = "All pages"
        case current = "Current page"
        case range = "Page range"
        var id: Self { self }
    }

    private enum OrientationChoice: String, CaseIterable, Identifiable {
        case preserve = "Preserve each page"
        case portrait = "Portrait"
        case landscape = "Landscape"
        var id: Self { self }
    }

    let pageCount: Int
    let currentPageIndex: Int
    let onExport: (NotePDFExportOptions) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pageSelection = PageSelection.all
    @State private var firstPage = 1
    @State private var lastPage: Int
    @State private var paperSize = NotePDFPaperSize.original
    @State private var orientation = OrientationChoice.preserve

    init(
        pageCount: Int,
        currentPageIndex: Int,
        onExport: @escaping (NotePDFExportOptions) -> Void
    ) {
        self.pageCount = max(pageCount, 1)
        self.currentPageIndex = min(max(currentPageIndex, 0), max(pageCount - 1, 0))
        self.onExport = onExport
        _lastPage = State(initialValue: max(pageCount, 1))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Pages") {
                    Picker("Export", selection: $pageSelection) {
                        ForEach(PageSelection.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if pageSelection == .range {
                        Stepper("First page: \(firstPage)", value: $firstPage, in: 1 ... pageCount)
                        Stepper("Last page: \(lastPage)", value: $lastPage, in: 1 ... pageCount)
                    }
                }

                Section {
                    Picker("Paper size", selection: $paperSize) {
                        ForEach(NotePDFPaperSize.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Orientation", selection: $orientation) {
                        ForEach(OrientationChoice.allCases) { Text($0.rawValue).tag($0) }
                    }
                } header: {
                    Text("Output")
                } footer: {
                    Text("Original page size keeps each notebook page's own format. A4 or US Letter scales and centers the page without changing the note.")
                }

                Section {
                    Label(
                        "The PDF contains readable personal data. Save or print it only in a location you trust.",
                        systemImage: "exclamationmark.shield"
                    )
                    .foregroundStyle(EpistoriaDesign.attention)
                }
            }
            .navigationTitle("Export PDF")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create PDF") { onExport(options) }
                        .disabled(pageSelection == .range && firstPage > lastPage)
                        .accessibilityIdentifier("note.export-pdf.create")
                }
            }
        }
    }

    private var options: NotePDFExportOptions {
        let range: ClosedRange<Int>? = switch pageSelection {
        case .all: nil
        case .current: currentPageIndex ... currentPageIndex
        case .range: (firstPage - 1) ... (lastPage - 1)
        }
        let resolvedOrientation: NotePageOrientation? = switch orientation {
        case .preserve: nil
        case .portrait: .portrait
        case .landscape: .landscape
        }
        return NotePDFExportOptions(
            pageRange: range,
            paperSize: paperSize,
            orientation: resolvedOrientation
        )
    }
}

private struct NotePDFExportReadyView: View {
    let result: NotePDFExportResult
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Label("PDF ready", systemImage: "checkmark.seal")
                    .font(.title2.bold())
                Text(result.title)
                    .font(.headline)
                Text(
                    "\(result.pageCount) \(result.pageCount == 1 ? "page" : "pages") · "
                        + ByteCountFormatter.string(
                            fromByteCount: result.byteCount, countStyle: .file)
                )
                .foregroundStyle(EpistoriaDesign.mutedInk)
                Label(
                    "This file is readable personal data. Save it only to a location you trust.",
                    systemImage: "exclamationmark.shield"
                )
                .foregroundStyle(EpistoriaDesign.attention)
                ShareLink(item: result.fileURL) {
                    Label("Save or share PDF", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(EpistoriaPrimaryButtonStyle())
                .accessibilityIdentifier("note.export-pdf.share")
                Button {
                    printPDF()
                } label: {
                    Label("Print PDF", systemImage: "printer")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier("note.export-pdf.print")
                Spacer()
            }
            .padding(30)
            .navigationTitle("Note PDF")
            .toolbar { Button("Done") { onDone() } }
        }
        .interactiveDismissDisabled()
    }

    private func printPDF() {
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil)
        info.jobName = result.title
        info.outputType = .general
        controller.printInfo = info
        controller.printingItem = result.fileURL
        controller.showsNumberOfCopies = true
        controller.present(animated: true)
    }
}
