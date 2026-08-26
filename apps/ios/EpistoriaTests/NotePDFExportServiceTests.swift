@testable import Epistoria
import EpistoriaCore
import PDFKit
import PencilKit
import UIKit
import XCTest

@MainActor
final class NotePDFExportServiceTests: XCTestCase {
    func testFixedNotebookExportsReadableTextAtNativePageSize() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let configuration = NoteCanvasConfiguration(
            pageFormat: .letter,
            orientation: .landscape,
            paperStyle: .isometric,
            paperColor: .ivory,
            paperSpacing: 18,
            pageCount: 2
        )
        let noteID = try await fixture.store.createNote(
            title: "Factorization review",
            canvas: configuration
        )
        _ = try await fixture.store.appendCanvasText(
            noteId: noteID,
            text: "Common factor evidence",
            placement: NoteCanvasPlacement(x: 48, y: 72, width: 360, height: 120),
            pageIndex: 0
        )
        _ = try await fixture.store.appendCanvasText(
            noteId: noteID,
            text: "Difference of squares evidence",
            placement: NoteCanvasPlacement(x: 48, y: 72, width: 360, height: 120),
            pageIndex: 1
        )
        let sourceID = try await fixture.store.createSource(
            type: .pastedText,
            title: "Algebra source"
        )
        let source = try await fixture.store.payload(SourcePayload.self, id: sourceID)
        let sourceVersionID = try XCTUnwrap(source.payload.currentVersionId)
        let evidenceID = try await fixture.store.createEvidence(
            sourceId: sourceID,
            sourceVersionId: sourceVersionID,
            kind: .excerpt,
            locator: SourceLocator(kind: .plainText, startOffset: 0, endOffset: 28),
            excerpt: "Factor each term before grouping."
        )
        _ = try await fixture.store.appendCanvasEvidence(
            noteId: noteID,
            evidenceId: evidenceID,
            placement: NoteCanvasPlacement(x: 48, y: 220, width: 360, height: 150),
            pageIndex: 0
        )
        let imageURL = fixture.root.appendingPathComponent("factor-tree.png")
        let imageData = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 60)).pngData {
            UIColor.black.setFill()
            $0.fill(CGRect(x: 12, y: 12, width: 56, height: 36))
        }
        try imageData.write(to: imageURL, options: .atomic)
        let importedImage = try await fixture.assetManager.importImage(from: imageURL)
        _ = try await fixture.store.appendCanvasImage(
            noteId: noteID,
            assetId: importedImage.assetId,
            filename: importedImage.filename,
            placement: NoteCanvasPlacement(x: 440, y: 96, width: 180, height: 135, zIndex: 2),
            pageIndex: 0
        )

        let inkID = try await fixture.store.appendCanvasInkLayer(noteId: noteID, pageIndex: 1)
        var inkBlock = try await fixture.store.payload(NoteBlockPayload.self, id: inkID)
        inkBlock.payload.drawingData = makeDrawing().dataRepresentation()
        _ = try await fixture.store.save(
            id: inkID,
            payload: inkBlock.payload,
            parentId: noteID,
            relationIds: [noteID]
        )
        _ = try await fixture.store.appendCanvasShape(
            noteId: noteID,
            shape: NoteCanvasShape(
                kind: .arrow,
                strokeColor: .blue,
                lineWidth: 4
            ),
            placement: NoteCanvasPlacement(x: 380, y: 260, width: 220, height: 90, zIndex: 3),
            pageIndex: 1
        )
        _ = try await fixture.store.appendCanvasEquation(
            noteId: noteID,
            symbol: "∫",
            placement: NoteCanvasPlacement(x: 620, y: 250, width: 100, height: 90, zIndex: 4),
            pageIndex: 1
        )

        let result = try await fixture.service.export(noteId: noteID)
        let document = try XCTUnwrap(PDFDocument(url: result.fileURL))

        XCTAssertEqual(result.pageCount, 2)
        XCTAssertEqual(document.pageCount, 2)
        let firstPage = try XCTUnwrap(document.page(at: 0))
        let secondPage = try XCTUnwrap(document.page(at: 1))
        XCTAssertEqual(firstPage.bounds(for: .mediaBox).width, 792, accuracy: 0.01)
        XCTAssertEqual(firstPage.bounds(for: .mediaBox).height, 612, accuracy: 0.01)
        XCTAssertTrue(firstPage.string?.contains("Common factor evidence") == true)
        XCTAssertTrue(firstPage.string?.contains("Factor each term before grouping.") == true)
        XCTAssertTrue(firstPage.string?.contains("Algebra source · Saved excerpt · Version 1") == true)
        XCTAssertTrue(secondPage.string?.contains("Difference of squares evidence") == true)
        XCTAssertTrue(secondPage.string?.contains("∫") == true)
        XCTAssertGreaterThan(result.byteCount, 0)
    }

    func testInfiniteNotebookExportsUsedWorldBoundsToOneReadablePage() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let noteID = try await fixture.store.createNote(
            title: "Infinite map",
            canvas: NoteCanvasConfiguration(pageFormat: .infinite)
        )
        _ = try await fixture.store.appendCanvasText(
            noteId: noteID,
            text: "Negative quadrant concept",
            placement: NoteCanvasPlacement(x: -420, y: -180, width: 320, height: 100)
        )

        let result = try await fixture.service.export(noteId: noteID)
        let document = try XCTUnwrap(PDFDocument(url: result.fileURL))
        let page = try XCTUnwrap(document.page(at: 0))
        let bounds = page.bounds(for: .mediaBox)

        XCTAssertEqual(document.pageCount, 1)
        XCTAssertTrue(page.string?.contains("Negative quadrant concept") == true)
        XCTAssertGreaterThan(bounds.width, 0)
        XCTAssertGreaterThan(bounds.height, 0)
        XCTAssertLessThanOrEqual(max(bounds.width, bounds.height), 14_400)
    }

    func testAcceptedOCRAddsSearchableTextWithoutChangingInk() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let noteID = try await fixture.store.createNote(title: "OCR export")
        let inkID = try await fixture.store.appendCanvasInkLayer(noteId: noteID, pageIndex: 0)
        var ink = try await fixture.store.payload(NoteBlockPayload.self, id: inkID)
        let originalDrawing = makeDrawing().dataRepresentation()
        ink.payload.drawingData = originalDrawing
        _ = try await fixture.store.save(
            id: inkID,
            payload: ink.payload,
            parentId: noteID,
            relationIds: [noteID]
        )
        let savedInk = try await fixture.store.payload(NoteBlockPayload.self, id: inkID)
        let request = LocalOCRRequest(
            accountId: UUID(),
            targetKind: .notebookRegion,
            targetId: inkID,
            parentId: noteID,
            noteId: noteID,
            inputRevision: savedInk.payload.ocrInputRevision,
            pageNumber: 1,
            imageData: Data("synthetic crop".utf8),
            mode: .text
        )
        let artifactID = try await fixture.store.saveOCRArtifact(
            request: request,
            response: LocalOCRResponse(
                engine: .deterministic,
                engineVersion: "fixture/v1",
                regions: [
                    LocalOCRRegion(
                        kind: .text,
                        text: "accepted handwritten factorization",
                        rectangles: [
                            AnnotationRectangle(x: 0.1, y: 0.2, width: 0.6, height: 0.08)
                        ]
                    )
                ]
            )
        )
        try await fixture.store.reviewOCRArtifact(id: artifactID, state: .accepted)

        let result = try await fixture.service.export(noteId: noteID)
        let page = try XCTUnwrap(PDFDocument(url: result.fileURL)?.page(at: 0))

        XCTAssertTrue(page.string?.contains("accepted handwritten factorization") == true)
        let unchanged = try await fixture.store.payload(NoteBlockPayload.self, id: inkID)
        XCTAssertEqual(unchanged.payload.drawingData, originalDrawing)
    }

    func testCleanupRefusesPDFOutsideOwnedTemporaryLocation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EpistoriaPDFCleanupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let unowned = root.appendingPathComponent("Epistoria-Note-keep.pdf")
        try Data("not a PDF".utf8).write(to: unowned, options: .atomic)

        try NotePDFExportService.removeTemporaryPDF(unowned)

        XCTAssertTrue(FileManager.default.fileExists(atPath: unowned.path))
    }

    private struct Fixture {
        var root: URL
        var store: EpistoriaStore
        var assetManager: AssetManager
        var service: NotePDFExportService
    }

    private func makeDrawing() -> PKDrawing {
        let points = [
            PKStrokePoint(
                location: CGPoint(x: 80, y: 240),
                timeOffset: 0,
                size: CGSize(width: 5, height: 5),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            ),
            PKStrokePoint(
                location: CGPoint(x: 240, y: 300),
                timeOffset: 0.1,
                size: CGSize(width: 5, height: 5),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            ),
        ]
        let path = PKStrokePath(controlPoints: points, creationDate: .now)
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: path)])
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EpistoriaNotePDFTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let accountID = UUID()
        let accountKey = try EntityCrypto().randomKey()
        let database = try SQLCipherDatabase(
            url: root.appendingPathComponent("test.sqlite"),
            key: try EntityCrypto().localDatabaseKey(accountKey: accountKey, accountId: accountID)
        )
        let store = EpistoriaStore(database: database)
        let assetManager = AssetManager(
            accountId: accountID,
            accountKey: accountKey,
            store: store,
            directory: root.appendingPathComponent("Assets", isDirectory: true)
        )
        return Fixture(
            root: root,
            store: store,
            assetManager: assetManager,
            service: NotePDFExportService(
                store: store,
                assetManager: assetManager,
                outputDirectory: root
            )
        )
    }
}
