@testable import Epistoria
import EpistoriaCore
import PDFKit
import SwiftUI
import Testing

@MainActor
struct PDFDocumentViewTests {
    @Test func citationRectanglesRemainOnTheirSourcePageWhileReading() async throws {
        var number = 2
        let rectangle = AnnotationRectangle(x: 0.1, y: 0.2, width: 0.3, height: 0.1)
        var parent = PDFDocumentView(data: Data(),
            pageNumber: Binding(get: { number }, set: { number = $0 }),
            pageCount: .constant(3), highlightText: nil,
            highlightRectangles: [rectangle], highlightPageNumber: 2)
        let coordinator = PDFDocumentView.Coordinator(parent: parent)
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        let document = PDFDocument()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 140)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 140))
        }
        for index in 0..<3 { document.insert(try #require(PDFPage(image: image)), at: index) }
        view.document = document
        coordinator.pdfView = view
        coordinator.initializePosition()
        await drainMainQueue()
        let citedPage = try #require(document.page(at: 1))
        let nextPage = try #require(document.page(at: 2))
        #expect(citedPage.annotations.count == 1)
        view.go(to: nextPage)
        coordinator.pageChanged()
        await drainMainQueue()
        #expect(number == 3)
        coordinator.applyRectangleHighlightsIfNeeded([rectangle])
        #expect(citedPage.annotations.count == 1)
        #expect(nextPage.annotations.isEmpty)
        #expect(view.currentPage === nextPage)

        parent.highlightPageNumber = 1
        number = 1
        coordinator.parent = parent
        coordinator.applyRectangleHighlightsIfNeeded([rectangle])
        #expect(citedPage.annotations.isEmpty)
        #expect(document.page(at: 0)?.annotations.count == 1)
        coordinator.applyRectangleHighlightsIfNeeded([])
        #expect(document.page(at: 0)?.annotations.isEmpty == true)
        PDFDocumentView.dismantleUIView(view, coordinator: coordinator)
    }

    @Test func initialSourcePageIsAppliedBeforePublishingTheVisiblePage() async throws {
        var number = 3
        var count = 0
        let parent = PDFDocumentView(data: Data(), pageNumber: Binding(get: { number }, set: { number = $0 }),
            pageCount: Binding(get: { count }, set: { count = $0 }), highlightText: nil)
        let coordinator = PDFDocumentView.Coordinator(parent: parent)
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        let document = PDFDocument()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 140)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 140))
        }
        for index in 0..<3 { document.insert(try #require(PDFPage(image: image)), at: index) }
        view.document = document
        coordinator.pdfView = view
        coordinator.initializePosition()
        await drainMainQueue()
        #expect(view.currentPage === document.page(at: 2))
        #expect(number == 3)
        #expect(count == 3)
        view.go(to: try #require(document.page(at: 1)))
        coordinator.pageChanged()
        #expect(number == 3, "PDFKit callbacks must not mutate SwiftUI bindings synchronously.")
        await drainMainQueue()
        #expect(number == 2)
        view.go(to: try #require(document.page(at: 0)))
        coordinator.pageChanged()
        PDFDocumentView.dismantleUIView(view, coordinator: coordinator)
        await drainMainQueue()
        #expect(number == 2, "A closed reader must not publish queued page changes.")
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
