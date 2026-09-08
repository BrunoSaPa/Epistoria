import Foundation
import Testing
@testable import EpistoriaCore

struct CanvasRefinementTests {
    @Test func alignmentUsesEdgesCentersAndReleasesOutsideTolerance() {
        let target = NoteCanvasPlacement(x: 100, y: 200, width: 100, height: 80)
        let moving = NoteCanvasPlacement(x: 104, y: 195, width: 100, height: 80)
        let result = CanvasAlignment.align(moving, to: [target])
        #expect(result.placement.x == 100)
        #expect(result.placement.y == 200)
        #expect(result.verticalGuide != nil && result.horizontalGuide != nil)
        let far = NoteCanvasPlacement(x: 122, y: 222, width: 100, height: 80)
        #expect(CanvasAlignment.align(far, to: [target]).placement == far)
    }

    @Test func alignmentSupportsNegativeCanvasCoordinatesAndFixedPageCenter() {
        let negative = NoteCanvasPlacement(x: -202, y: -103, width: 50, height: 50)
        let target = NoteCanvasPlacement(x: -200, y: -100, width: 50, height: 50)
        #expect(CanvasAlignment.align(negative, to: [target]).placement.x == -200)
        let center = NoteCanvasPlacement(x: 251, y: 351, width: 100, height: 100)
        let result = CanvasAlignment.align(center, to: [], pageWidth: 600, pageHeight: 800)
        #expect(result.placement.x == 250)
        #expect(result.placement.y == 350)
    }

    @Test func oldShapeDecodesAsSolidAndNewStyleRoundTrips() throws {
        let old = Data(#"{"kind":"RECTANGLE","strokeColor":"BLACK","lineWidth":3}"#.utf8)
        let decoded = try JSONDecoder().decode(NoteCanvasShape.self, from: old)
        #expect(decoded.dashPattern.isEmpty)
        let changed = NoteCanvasShape(kind: .ellipse, lineWidth: 4, lineStyle: .dashed)
        #expect(try JSONDecoder().decode(NoteCanvasShape.self, from: JSONEncoder().encode(changed)) == changed)
        #expect(changed.dashPattern == [12, 8])
    }

    @Test func editingShapePreservesIdentityPageAndPlacement() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ShapeEdit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try SQLCipherDatabase(url: directory.appendingPathComponent("test.sqlite"), key: Data(repeating: 7, count: 32))
        let store = EpistoriaStore(database: database)
        let note = try await store.createNote(title: "Synthetic shapes")
        let page = try await store.notePages(noteId: note).first?.id
        let placement = NoteCanvasPlacement(x: 42, y: 70, width: 120, height: 90)
        let id = try await store.appendCanvasShape(noteId: note, shape: NoteCanvasShape(kind: .rectangle), placement: placement, pageId: page)
        let changed = NoteCanvasShape(kind: .ellipse, strokeColor: .graphite, fillColor: .black, lineWidth: 6, lineStyle: .dotted)
        try await store.updateCanvasShape(id: id, shape: changed)
        let block = try await store.payload(NoteBlockPayload.self, id: id).payload
        #expect(block.canvasShape == changed)
        #expect(block.canvasPlacement == placement)
        #expect(block.pageId == page && block.noteId == note)
    }
}
