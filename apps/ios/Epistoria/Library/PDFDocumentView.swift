import EpistoriaCore
import PDFKit
import SwiftUI

struct PDFDocumentView: UIViewRepresentable {
    let data: Data
    @Binding var pageNumber: Int
    @Binding var pageCount: Int
    let highlightText: String?
    var highlightRectangles: [AnnotationRectangle] = []
    var highlightPageNumber: Int? = nil

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .secondarySystemBackground
        view.document = PDFDocument(data: data)
        context.coordinator.pdfView = view
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged),
            name: .PDFViewPageChanged,
            object: view
        )
        DispatchQueue.main.async {
            context.coordinator.initializePosition()
        }
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.parent = self
        // `data` is immutable for the lifetime of this detail view. Re-serializing the
        // PDFDocument here would copy the entire file on routine page/highlight updates.
        context.coordinator.applyHighlightIfNeeded(highlightText)
        context.coordinator.applyRectangleHighlightsIfNeeded(highlightRectangles)
        context.coordinator.showRequestedPage()
    }

    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator, name: .PDFViewPageChanged, object: view)
        coordinator.pdfView = nil
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: PDFDocumentView
        weak var pdfView: PDFView?
        private var lastHighlight: String?
        private var lastTextPage = 0
        private let initialPageNumber: Int
        private var lastRectangles: [AnnotationRectangle] = []
        private var lastRectanglePage = 0
        private var transientAnnotations: [(PDFPage, PDFAnnotation)] = []
        private var pageUpdateScheduled = false

        init(parent: PDFDocumentView) {
            self.parent = parent
            initialPageNumber = parent.pageNumber
        }

        private var citationPageNumber: Int { parent.highlightPageNumber ?? initialPageNumber }

        @objc func pageChanged() { updatePage() }

        func initializePosition() {
            showRequestedPage()
            applyHighlightIfNeeded(parent.highlightText)
            applyRectangleHighlightsIfNeeded(parent.highlightRectangles)
            updatePage()
        }

        func showRequestedPage() {
            guard let view = pdfView, let document = view.document,
                  parent.pageNumber > 0, parent.pageNumber <= document.pageCount,
                  let page = document.page(at: parent.pageNumber - 1), view.currentPage !== page else { return }
            view.go(to: page)
        }

        func updatePage() {
            guard !pageUpdateScheduled else { return }
            pageUpdateScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pageUpdateScheduled = false
                self.publishPage()
            }
        }

        private func publishPage() {
            guard let view = pdfView, let document = view.document else { return }
            if parent.pageCount != document.pageCount { parent.pageCount = document.pageCount }
            if let current = view.currentPage {
                let number = document.index(for: current) + 1
                if parent.pageNumber != number { parent.pageNumber = number }
            }
        }

        func applyHighlightIfNeeded(_ value: String?) {
            let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard clean != lastHighlight || citationPageNumber != lastTextPage else { return }
            lastHighlight = clean
            lastTextPage = citationPageNumber
            guard let clean, clean.count >= 2, let view = pdfView, let document = view.document else {
                viewClearHighlights()
                return
            }
            let selections = document.findString(clean, withOptions: .caseInsensitive)
            let preferredPageIndex = max(citationPageNumber - 1, 0)
            let preferred = selections.first { selection in
                guard let page = selection.pages.first else { return false }
                return document.index(for: page) == preferredPageIndex
            } ?? selections.first
            guard let preferred else { return }
            preferred.color = UIColor.systemYellow.withAlphaComponent(0.45)
            view.highlightedSelections = [preferred]
            view.go(to: preferred)
            updatePage()
            UIAccessibility.post(notification: .announcement, argument: "Matched PDF text highlighted")
        }

        func applyRectangleHighlightsIfNeeded(_ rectangles: [AnnotationRectangle]) {
            guard rectangles != lastRectangles || citationPageNumber != lastRectanglePage else {
                return
            }
            lastRectangles = rectangles
            lastRectanglePage = citationPageNumber
            for (page, annotation) in transientAnnotations {
                page.removeAnnotation(annotation)
            }
            transientAnnotations = []
            guard !rectangles.isEmpty,
                  let view = pdfView,
                  let document = view.document,
                  citationPageNumber > 0,
                  citationPageNumber <= document.pageCount,
                  let page = document.page(at: citationPageNumber - 1)
            else { return }
            let pageBounds = page.bounds(for: .cropBox)
            for rectangle in rectangles {
                let bounds = CGRect(
                    x: pageBounds.minX + rectangle.x * pageBounds.width,
                    y: pageBounds.maxY
                        - (rectangle.y + rectangle.height) * pageBounds.height,
                    width: rectangle.width * pageBounds.width,
                    height: rectangle.height * pageBounds.height
                )
                let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                annotation.color = UIColor.systemGray.withAlphaComponent(0.35)
                page.addAnnotation(annotation)
                transientAnnotations.append((page, annotation))
            }
            view.go(to: CGRect(
                x: pageBounds.minX,
                y: transientAnnotations.first?.1.bounds.midY ?? pageBounds.midY,
                width: pageBounds.width,
                height: 1
            ), on: page)
            UIAccessibility.post(
                notification: .announcement,
                argument: "Opened cited region on PDF page \(citationPageNumber)"
            )
        }

        private func viewClearHighlights() {
            pdfView?.highlightedSelections = nil
        }
    }

}
