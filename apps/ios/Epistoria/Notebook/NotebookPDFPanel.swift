import EpistoriaCore
import PDFKit
import SwiftUI

struct NotebookPDFTarget: Identifiable {
    let id: UUID
    let sourceId: UUID
    let versionId: UUID
    var locator = SourceLocator(kind: .pdf, page: 1)
    var excerpt: String? = nil

    init(sourceId: UUID, versionId: UUID) {
        id = versionId
        self.sourceId = sourceId
        self.versionId = versionId
    }

    init(id: UUID, evidence: EvidencePayload) {
        self.id = id
        sourceId = evidence.sourceId
        versionId = evidence.sourceVersionId
        locator = evidence.locator
        excerpt = evidence.excerpt
    }
}

/// Reads a frozen version selected by the owner; never substitutes a refreshed original.
struct NotebookPDFPanel: View {
    let model: AppModel
    let target: NotebookPDFTarget
    let onClose: () -> Void
    @State private var data: Data?
    @State private var title = "Source"
    @State private var pageNumber: Int
    @State private var pageCount = 0
    @State private var error: String?
    @State private var loadAttempt = 0

    init(model: AppModel, target: NotebookPDFTarget, onClose: @escaping () -> Void) {
        self.model = model
        self.target = target
        self.onClose = onClose
        _pageNumber = State(initialValue: target.locator.page ?? 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).lineLimit(1)
                    Text(target.excerpt == nil ? "Saved source version" : "Cited source version")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button(action: onClose) {
                    Image(systemName: "xmark").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Close source panel")
                .accessibilityIdentifier("note.source.close")
            }.padding(.horizontal, 12)
            Divider()
            if let data {
                PDFDocumentView(data: data, pageNumber: $pageNumber, pageCount: $pageCount,
                    highlightText: target.excerpt,
                    highlightRectangles: target.locator.rectangles,
                    highlightPageNumber: target.locator.page)
                    .accessibilityIdentifier("note.source.pdf")
                HStack {
                    Button { pageNumber = max(1, pageNumber - 1) } label: {
                        Image(systemName: "chevron.left").frame(width: 44, height: 44)
                    }.disabled(pageNumber <= 1).accessibilityLabel("Previous source page")
                    Spacer()
                    Text("Page \(pageNumber) of \(pageCount)").font(.caption).monospacedDigit()
                    Spacer()
                    Button { pageNumber = min(pageCount, pageNumber + 1) } label: {
                        Image(systemName: "chevron.right").frame(width: 44, height: 44)
                    }.disabled(pageNumber >= pageCount).accessibilityLabel("Next source page")
                }.padding(.horizontal, 8)
            } else if let error {
                ContentUnavailableView {
                    Label("Source unavailable", systemImage: "doc")
                } description: { Text(error) } actions: {
                    Button("Retry") { loadAttempt += 1 }
                }
            } else {
                ProgressView("Opening saved source…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(EpistoriaDesign.page)
        .overlay(alignment: .leading) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("note.source.panel")
        .task(id: loadAttempt) { await load() }
    }

    static func originalAsset(for target: NotebookPDFTarget, version: SourceVersionPayload) throws -> UUID {
        try target.locator.validate()
        guard target.locator.kind == .pdf, version.sourceId == target.sourceId else {
            throw SourceModelError.sourceVersionMismatch
        }
        guard let id = version.originalAssetId else { throw StoreError.entityNotFound }
        return id
    }

    private func load() async {
        error = nil
        do {
            guard let store = model.store, let assets = model.assetManager else {
                throw StoreError.entityNotFound
            }
            let version = try await store.payload(SourceVersionPayload.self, id: target.versionId)
            let assetId = try Self.originalAsset(for: target, version: version.payload)
            let source = try await store.payload(SourcePayload.self, id: target.sourceId)
            let bytes = try await assets.decryptedLocalData(assetId: assetId)
            try Task.checkCancellation()
            guard let document = PDFDocument(data: bytes), !document.isLocked,
                  let page = target.locator.page, page <= document.pageCount else {
                error = "The saved PDF cannot open this cited page. The current source will not replace it."
                return
            }
            title = source.payload.title
            data = bytes
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            self.error = "The cited source version must be available on this iPad. Download it in Library, then retry."
        }
    }
}
