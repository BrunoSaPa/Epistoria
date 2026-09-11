@testable import Epistoria
import EpistoriaCore
import PencilKit
import Testing
import UIKit

@MainActor
struct NotePagePreviewTests {
    @Test func noteCoversUseFirstActivePageAndInfiniteContentWithoutWrites() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let id = try await f.store.createNote(title: "Synthetic cover")
        var note = try await f.store.payload(NotePayload.self, id: id)
        let first = try #require(try await f.store.notePages(noteId: id).first)
        var second = first
        second.id = UUID()
        second.payload.orderKey = "zzzz"
        let text = block(page: first, kind: .text, text: "Actual cover text")
        let mutations = try await f.store.database.pendingMutations()
        let expected = try await f.service.pagePreview(page: first, blocks: [text])
        let cover = try await f.service.notePreview(note: note, pages: [second, first], blocks: [text])
        #expect(cover.pngData() == expected.pngData())
        var trashed = first
        trashed.payload.trashedAt = .now
        let secondBlank = try await f.service.pagePreview(page: second, blocks: [])
        #expect(try await f.service.notePreview(note: note, pages: [trashed, second], blocks: [text]).pngData() == secondBlank.pngData())
        note.payload.canvas = NoteCanvasConfiguration(pageFormat: .infinite)
        var infiniteText = text
        infiniteText.payload.pageId = nil
        infiniteText.payload.canvasPlacement = NoteCanvasPlacement(x: -5000, y: 2000, width: 300, height: 120)
        let infinite = try await f.service.notePreview(note: note, pages: [], blocks: [infiniteText])
        #expect(max(infinite.size.width, infinite.size.height) <= 384.01)
        #expect(min(infinite.size.width, infinite.size.height) > 0)
        #expect(try await f.store.database.pendingMutations() == mutations)
    }

    private struct Fixture {
        let root: URL
        let store: EpistoriaStore
        let service: NotePDFExportService
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PagePreviewTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let account = UUID()
        let key = try EntityCrypto().randomKey()
        let database = try SQLCipherDatabase(url: root.appendingPathComponent("test.sqlite"),
            key: try EntityCrypto().localDatabaseKey(accountKey: key, accountId: account))
        let store = EpistoriaStore(database: database)
        let assets = AssetManager(accountId: account, accountKey: key, store: store,
            directory: root.appendingPathComponent("Assets"))
        return Fixture(root: root, store: store,
            service: NotePDFExportService(store: store, assetManager: assets, outputDirectory: root))
    }

    private func block(page: IdentifiedPayload<NotePagePayload>, kind: NoteBlockKind,
        text: String = "") -> IdentifiedPayload<NoteBlockPayload> {
        var payload = NoteBlockPayload(noteId: page.payload.noteId, blockType: kind, orderKey: "a", plainText: text)
        payload.pageId = page.id
        payload.canvasPlacement = NoteCanvasPlacement(x: 30, y: 30, width: 300, height: 120)
        return IdentifiedPayload(id: UUID(), payload: payload, revision: 0, syncState: .pending)
    }

    @Test func previewsRespectPageContentOrientationAndDoNotExportFiles() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let note = try await f.store.createNote(title: "Preview fixture", canvas: .init(pageFormat: .a4))
        var page = try #require(try await f.store.notePages(noteId: note).first)
        let blank = try await f.service.pagePreview(page: page, blocks: [])
        #expect(blank.size.height == 384)
        #expect(blank.size.width < blank.size.height)
        let text = block(page: page, kind: .text, text: "A real page preview")
        let content = try await f.service.pagePreview(page: page, blocks: [text])
        #expect(content.pngData() != blank.pngData())
        var elsewhere = text
        elsewhere.payload.pageId = UUID()
        #expect(try await f.service.pagePreview(page: page, blocks: [elsewhere]).pngData() == blank.pngData())
        elsewhere.payload.pageId = page.id
        elsewhere.payload.tombstone = true
        #expect(try await f.service.pagePreview(page: page, blocks: [elsewhere]).pngData() == blank.pngData())
        page.payload.configuration.orientation = .landscape
        let landscape = try await f.service.pagePreview(page: page, blocks: [text])
        #expect(landscape.size.width == 384)
        #expect(landscape.size.height < landscape.size.width)
        let files = try FileManager.default.contentsOfDirectory(at: f.root, includingPropertiesForKeys: nil)
        #expect(!files.contains { ["pdf", "png", "partial"].contains($0.pathExtension) })
    }

    @Test func inkIsVisibleAndInvalidInkFailsInsteadOfLookingBlank() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let note = try await f.store.createNote(title: "Ink fixture", canvas: .init(pageFormat: .a4))
        let page = try #require(try await f.store.notePages(noteId: note).first)
        var ink = block(page: page, kind: .handwriting)
        ink.payload.canvasRole = .inkLayer
        let points = [CGPoint(x: 50, y: 50), CGPoint(x: 400, y: 600)].enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index), size: CGSize(width: 12, height: 12),
                opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        ink.payload.drawingData = PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black),
            path: PKStrokePath(controlPoints: points, creationDate: .now))]).dataRepresentation()
        let blank = try await f.service.pagePreview(page: page, blocks: [])
        let rendered = try await f.service.pagePreview(page: page, blocks: [ink])
        #expect(rendered.pngData() != blank.pngData())
        ink.payload.drawingData = Data([1, 2, 3])
        await #expect(throws: (any Error).self) { try await f.service.pagePreview(page: page, blocks: [ink]) }
    }

    @Test func cacheRequiresExactContentNotJustServerRevision() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let note = try await f.store.createNote(title: "Cache fixture", canvas: .init(pageFormat: .a4))
        let page = try #require(try await f.store.notePages(noteId: note).first)
        let original = block(page: page, kind: .text, text: "Before")
        let input = NotePagePreviewInput(page: page, blocks: [original])
        let image = try await f.service.pagePreview(page: page, blocks: [original])
        let cache = NotePagePreviewCache()
        cache.insert(image, for: input)
        #expect(cache.image(for: input) === image)
        var changed = original
        changed.payload.plainText = "After"
        #expect(cache.image(for: .init(page: page, blocks: [changed])) == nil)
        var changedPage = page
        changedPage.payload.configuration.orientation = .landscape
        #expect(cache.image(for: .init(page: changedPage, blocks: [original])) == nil)
        #expect(NotePagePreviewCache().image(for: input) == nil)
    }

    @Test func missingImagesAndTrashedPagesDoNotProduceMisleadingPreviews() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let note = try await f.store.createNote(title: "Unavailable fixture", canvas: .init(pageFormat: .a4))
        var page = try #require(try await f.store.notePages(noteId: note).first)
        var image = block(page: page, kind: .image)
        image.payload.assetId = UUID()
        await #expect(throws: (any Error).self) { try await f.service.pagePreview(page: page, blocks: [image]) }
        page.payload.trashedAt = .now
        await #expect(throws: NotePDFExportError.self) { try await f.service.pagePreview(page: page, blocks: []) }
    }
}
