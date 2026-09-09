@testable import Epistoria
import EpistoriaCore
import Foundation
import Testing

struct NoteFindSearchTests {
    private func identified<P: EntityPayload>(_ payload: P, id: UUID = UUID()) -> IdentifiedPayload<P> {
        IdentifiedPayload(id: id, payload: payload, revision: 1, syncState: .pending)
    }

    private func block(_ text: String = "") -> IdentifiedPayload<NoteBlockPayload> {
        identified(NoteBlockPayload(noteId: UUID(), blockType: .text, orderKey: "a", plainText: text))
    }

    private func artifact(for block: IdentifiedPayload<NoteBlockPayload>,
        regions: [LocalOCRRegion], review: AIArtifactReviewState? = nil,
        kind: LocalOCRTargetKind = .notebookRegion) -> IdentifiedPayload<OCRArtifactPayload> {
        let request = LocalOCRRequest(accountId: UUID(), targetKind: kind, targetId: block.id,
            parentId: block.payload.noteId, inputRevision: block.payload.ocrInputRevision,
            imageData: Data(), mode: .text)
        var payload = OCRArtifactPayload(request: request,
            response: LocalOCRResponse(engine: .deterministic, engineVersion: "test", regions: regions))
        payload.reviewState = review
        return identified(payload)
    }

    @Test func matchingAndSnippetsUseTrimmedAccentInsensitiveQuery() {
        let source = block(String(repeating: "preface ", count: 50) + "ÁLGEBRA here")
        let matches = NoteFindSearch.matches(query: " algebra \n", pages: [], blocks: [source], artifacts: [])
        #expect(matches.count == 1)
        #expect(NoteFindSearch.snippet(source.payload.plainText, query: " algebra ").contains("ÁLGEBRA"))
        #expect(NoteFindSearch.matches(query: " \n", pages: [], blocks: [source], artifacts: []).isEmpty)
    }

    @Test func missingTrashedAndUnassignedFixedPagesAreExcluded() {
        var source = block("algebra")
        var page = identified(NotePagePayload(noteId: source.payload.noteId, orderKey: "a", configuration: .init()))
        #expect(NoteFindSearch.matches(query: "algebra", pages: [page], blocks: [source], artifacts: []).isEmpty)
        source.payload.pageId = UUID()
        #expect(NoteFindSearch.matches(query: "algebra", pages: [page], blocks: [source], artifacts: []).isEmpty)
        source.payload.pageId = page.id
        #expect(NoteFindSearch.matches(query: "algebra", pages: [page], blocks: [source], artifacts: []).count == 1)
        page.payload.trashedAt = .now
        #expect(NoteFindSearch.matches(query: "algebra", pages: [page], blocks: [source], artifacts: []).isEmpty)
    }

    @Test func onlyMatchingRegionIsHighlightedAndAcceptanceIsAccurate() throws {
        let source = block()
        let rectangle = AnnotationRectangle(x: 0.1, y: 0.2, width: 0.3, height: 0.1)
        let regions = [LocalOCRRegion(kind: .text, text: "algebra", rectangles: [rectangle]),
            LocalOCRRegion(kind: .text, text: "geometry")]
        let image = artifact(for: source, regions: regions, review: .accepted, kind: .image)
        let match = try #require(NoteFindSearch.matches(query: "algebra", pages: [], blocks: [source], artifacts: [image]).first)
        #expect(match.rectangles == [rectangle])
        #expect(match.text == "algebra")
        #expect(match.origin.label == "Recognized from image · Accepted")
        let ink = artifact(for: source, regions: regions)
        #expect(NoteFindSearch.matches(query: "algebra", pages: [], blocks: [source], artifacts: [ink]).first?.origin.label
            == "Recognized from handwriting · Unreviewed")
    }

    @Test func correctionsDoNotSearchOriginalTextOrUnresolvedConflicts() {
        let source = block()
        let region = LocalOCRRegion(kind: .text, text: "wrong")
        let edited = artifact(for: source, regions: [region], review: .edited)
        #expect(NoteFindSearch.matches(query: "wrong", pages: [], blocks: [source], artifacts: [edited]).isEmpty)
        let resolved = [edited.id: [ResolvedOCRRegion(region: region, content: "correct")]]
        #expect(NoteFindSearch.matches(query: "wrong", pages: [], blocks: [source], artifacts: [edited], correctedRegions: resolved).isEmpty)
        #expect(NoteFindSearch.matches(query: "correct", pages: [], blocks: [source], artifacts: [edited], correctedRegions: resolved).first?.origin.label == "Corrected by you")
    }

    @Test func staleRejectedAndChangedInkCannotAppear() {
        var source = block()
        let region = LocalOCRRegion(kind: .text, text: "algebra")
        var stale = artifact(for: source, regions: [region])
        stale.payload.state = .stale
        let rejected = artifact(for: source, regions: [region], review: .rejected)
        let obsolete = artifact(for: source, regions: [region])
        source.payload.drawingData = Data([1, 2, 3])
        #expect(NoteFindSearch.matches(query: "algebra", pages: [], blocks: [source], artifacts: [stale, rejected, obsolete]).isEmpty)
        source.payload.tombstone = true
        #expect(NoteFindSearch.matches(query: "algebra", pages: [], blocks: [source], artifacts: [obsolete]).isEmpty)
    }

    @Test func correctionBeforeReviewStillReplacesOriginalRecognition() {
        let source = block()
        let region = LocalOCRRegion(kind: .text, text: "wrong")
        let unreviewed = artifact(for: source, regions: [region])
        let resolved = [unreviewed.id: [ResolvedOCRRegion(region: region, content: "correct")]]
        #expect(NoteFindSearch.matches(query: "wrong", pages: [], blocks: [source], artifacts: [unreviewed], correctedRegions: resolved).isEmpty)
        #expect(NoteFindSearch.matches(query: "correct", pages: [], blocks: [source], artifacts: [unreviewed], correctedRegions: resolved).first?.origin.label == "Corrected by you")
    }
}
