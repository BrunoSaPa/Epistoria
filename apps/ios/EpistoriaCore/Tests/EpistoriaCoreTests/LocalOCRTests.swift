import Foundation
import XCTest
@testable import EpistoriaCore

final class LocalOCRTests: XCTestCase {
    func testUnreviewedOCRIsSearchableAndCorrectionsSurviveRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EpistoriaOCRTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("epistoria.sqlite")
        let key = Data(0 ..< 32)
        let database = try SQLCipherDatabase(url: url, key: key)
        let store = EpistoriaStore(database: database)
        let noteId = try await store.createNote(title: "OCR fixture")
        let blockId = try await store.appendHandwritingBlock(noteId: noteId)
        let regionId = UUID()
        let request = LocalOCRRequest(
            accountId: UUID(),
            targetKind: .notebookRegion,
            targetId: blockId,
            parentId: noteId,
            noteId: noteId,
            inputRevision: try await store.payload(NoteBlockPayload.self, id: blockId)
                .payload.ocrInputRevision,
            pageNumber: 1,
            locator: SourceLocator(
                kind: .image,
                rectangles: [AnnotationRectangle(x: 0.1, y: 0.2, width: 0.5, height: 0.2)]
            ),
            imageData: Data("bounded-png-fixture".utf8),
            preferredLanguages: ["es-MX", "en-US"],
            mode: .formula
        )
        let response = LocalOCRResponse(
            engine: .deterministic,
            engineVersion: "fixture/v1",
            regions: [
                LocalOCRRegion(
                    id: regionId,
                    kind: .formula,
                    text: "x^2 - 4 = 0",
                    latex: "x^2 - 4 = 0",
                    confidence: nil,
                    rectangles: [AnnotationRectangle(x: 0.1, y: 0.2, width: 0.5, height: 0.2)]
                )
            ]
        )
        let artifactId = try await store.saveOCRArtifact(request: request, response: response)

        let search = try await database.search("x^2")
        XCTAssertEqual(search.first?.entity.id, artifactId)
        let unreviewed = try await store.payload(OCRArtifactPayload.self, id: artifactId)
        XCTAssertNil(unreviewed.payload.reviewState)

        _ = try await store.createOCRCorrection(
            artifactId: artifactId,
            regionId: regionId,
            correctedText: "x^2 - 4 = 0 \\Rightarrow x = \\pm 2"
        )
        try await store.reviewOCRArtifact(id: artifactId, state: .edited)

        let reopened = EpistoriaStore(database: try SQLCipherDatabase(url: url, key: key))
        let resolved = try await reopened.resolvedOCRText(artifactId: artifactId)
        XCTAssertEqual(resolved, "x^2 - 4 = 0 \\Rightarrow x = \\pm 2")
        let reviewed = try await reopened.payload(OCRArtifactPayload.self, id: artifactId)
        XCTAssertEqual(reviewed.payload.reviewState, .edited)
    }

    func testNewInputRevisionMarksOlderOCRStaleWithoutDeletingIt() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EpistoriaOCRTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try SQLCipherDatabase(
            url: directory.appendingPathComponent("epistoria.sqlite"),
            key: Data(0 ..< 32)
        )
        let store = EpistoriaStore(database: database)
        let noteId = UUID()
        let blockId = UUID()
        let request = LocalOCRRequest(
            accountId: UUID(),
            targetKind: .notebookRegion,
            targetId: blockId,
            parentId: noteId,
            noteId: noteId,
            inputRevision: 3,
            imageData: Data("png".utf8),
            mode: .text
        )
        let artifactId = try await store.saveOCRArtifact(
            request: request,
            response: LocalOCRResponse(
                engine: .deterministic,
                engineVersion: "fixture/v1",
                regions: [LocalOCRRegion(kind: .text, text: "previous handwriting")]
            )
        )

        try await store.markOCRArtifactsStale(targetId: blockId, exceptInputRevision: 4)

        let stale = try await store.payload(OCRArtifactPayload.self, id: artifactId)
        XCTAssertEqual(stale.payload.state, .stale)

        do {
            try await store.reviewOCRArtifact(id: artifactId, state: .accepted)
            XCTFail("Stale OCR must not be accepted")
        } catch StoreError.invalidDraftReview {
            // Expected: only the current input revision can cross the review boundary.
        }
    }

    func testLateOCRResultCannotBeAcceptedAfterInkRevisionChanges() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EpistoriaOCRTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EpistoriaStore(database: try SQLCipherDatabase(
            url: directory.appendingPathComponent("epistoria.sqlite"),
            key: Data(0 ..< 32)
        ))
        let noteId = try await store.createNote(title: "Changing ink")
        let blockId = try await store.appendHandwritingBlock(noteId: noteId)
        let original = try await store.payload(NoteBlockPayload.self, id: blockId)
        let request = LocalOCRRequest(
            accountId: UUID(),
            targetKind: .notebookRegion,
            targetId: blockId,
            parentId: noteId,
            noteId: noteId,
            inputRevision: original.payload.ocrInputRevision,
            imageData: Data("old-crop".utf8),
            mode: .formula
        )
        let artifactId = try await store.saveOCRArtifact(
            request: request,
            response: LocalOCRResponse(
                engine: .deterministic,
                engineVersion: "fixture/v1",
                regions: [LocalOCRRegion(kind: .formula, text: "x + 1")]
            )
        )
        var changedBlock = original.payload
        changedBlock.drawingData = Data("new-ink".utf8)
        _ = try await store.save(id: blockId, payload: changedBlock, parentId: noteId)

        do {
            try await store.reviewOCRArtifact(id: artifactId, state: .accepted)
            XCTFail("A late result for an older ink revision must not be accepted")
        } catch StoreError.invalidDraftReview {
            // Expected. The original ink remains authoritative.
        }

        try await store.reviewOCRArtifact(id: artifactId, state: .rejected)
        let rejected = try await store.payload(OCRArtifactPayload.self, id: artifactId)
        XCTAssertEqual(rejected.payload.reviewState, .rejected)
    }

    func testParallelCorrectionsFailClosed() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EpistoriaOCRTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EpistoriaStore(database: try SQLCipherDatabase(
            url: directory.appendingPathComponent("epistoria.sqlite"),
            key: Data(0 ..< 32)
        ))
        let noteId = UUID()
        let targetId = UUID()
        let regionId = UUID()
        let request = LocalOCRRequest(
            accountId: UUID(),
            targetKind: .notebookRegion,
            targetId: targetId,
            parentId: noteId,
            noteId: noteId,
            inputRevision: 1,
            imageData: Data("png".utf8),
            mode: .text
        )
        let artifactId = try await store.saveOCRArtifact(
            request: request,
            response: LocalOCRResponse(
                engine: .deterministic,
                engineVersion: "fixture/v1",
                regions: [LocalOCRRegion(id: regionId, kind: .text, text: "ambiguous")]
            )
        )
        for corrected in ["first owner edit", "parallel owner edit"] {
            _ = try await store.save(
                payload: OCRCorrectionPayload(
                    artifactId: artifactId,
                    regionId: regionId,
                    targetId: targetId,
                    originalText: "ambiguous",
                    correctedText: corrected
                ),
                parentId: noteId,
                relationIds: [artifactId, targetId]
            )
        }

        do {
            _ = try await store.resolvedOCRText(artifactId: artifactId)
            XCTFail("Parallel correction leaves must require explicit resolution")
        } catch StoreError.invalidDraftReview {
            // Expected. Neither owner edit is discarded or selected by timestamp.
        }

        let conflicts = try await store.ocrCorrectionConflicts(artifactId: artifactId)
        XCTAssertEqual(Set(conflicts[regionId] ?? []), ["first owner edit", "parallel owner edit"])
        _ = try await store.createOCRCorrection(
            artifactId: artifactId,
            regionId: regionId,
            correctedText: "resolved owner edit",
            resolvesConflict: true
        )
        let resolved = try await store.resolvedOCRText(artifactId: artifactId)
        XCTAssertEqual(resolved, "resolved owner edit")
    }
}
