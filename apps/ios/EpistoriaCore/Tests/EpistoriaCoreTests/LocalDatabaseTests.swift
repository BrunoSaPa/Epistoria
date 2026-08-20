import Foundation
import XCTest
@testable import EpistoriaCore

final class LocalDatabaseTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EpistoriaCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testSaveSearchOutboxAndRelaunch() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("epistoria.sqlite")
        let key = Data(0 ..< 32)
        let database = try SQLCipherDatabase(url: url, key: key)
        let noteId = UUID()
        let content = try CanonicalJSON.encode(NotePayload(title: "Canary algebra notebook"))
        _ = try await database.saveLocal(
            id: noteId,
            entityType: .note,
            content: content,
            search: SearchDocument(title: "Canary algebra notebook", body: "eigenvector")
        )

        let stored = try await database.entity(id: noteId)
        let pending = try await database.pendingMutations()
        let hits = try await database.search("eigen")
        XCTAssertEqual(stored?.content, content)
        XCTAssertEqual(stored?.syncState, .pending)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(hits.first?.entity.id, noteId)

        let reopened = try SQLCipherDatabase(url: url, key: key)
        let reopenedEntity = try await reopened.entity(id: noteId)
        XCTAssertEqual(reopenedEntity?.content, content)
        XCTAssertThrowsError(try SQLCipherDatabase(url: url, key: Data(repeating: 99, count: 32)))

        try await database.checkpoint()
        for suffix in ["", "-wal", "-shm"] {
            let target = URL(fileURLWithPath: url.path + suffix)
            guard FileManager.default.fileExists(atPath: target.path) else { continue }
            let raw = try Data(contentsOf: target)
            XCTAssertNil(raw.range(of: Data("Canary algebra notebook".utf8)))
            XCTAssertNil(raw.range(of: Data("eigenvector".utf8)))
        }
    }

    func testRepositoryPersistsVerticalSliceOffline() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try SQLCipherDatabase(
            url: directory.appendingPathComponent("epistoria.sqlite"),
            key: Data(0 ..< 32)
        )
        let store = EpistoriaStore(database: database)
        let collectionId = try await store.save(payload: CollectionPayload(name: "Mathematics"))
        let institutionId = try await store.save(payload: InstitutionPayload(name: "Synthetic U"))
        let termId = try await store.save(
            payload: AcademicTermPayload(institutionId: institutionId, name: "Fall 2026"),
            parentId: institutionId,
            relationIds: [institutionId]
        )
        let courseId = try await store.save(
            payload: CoursePayload(
                name: "Probability",
                institutionId: institutionId,
                academicTermId: termId
            ),
            parentId: termId,
            relationIds: [institutionId, termId]
        )
        let sessionId = try await store.startSession(title: "Entropy", courseId: courseId)
        let noteId = try await store.createNote(
            title: "Entropy notes",
            courseId: courseId,
            sessionId: sessionId
        )
        _ = try await store.appendTextBlock(noteId: noteId, text: "Entropy measures uncertainty")
        _ = try await store.appendHandwritingBlock(noteId: noteId)
        let collectionLink = RelationPayload(
            kind: .collectionItem,
            leftId: collectionId,
            rightId: noteId
        )
        _ = try await store.save(
            payload: collectionLink,
            parentId: collectionId,
            relationIds: [collectionId, noteId],
            entityTypeOverride: .collectionItem
        )
        try await store.endSession(id: sessionId)

        let courses = try await store.list(CoursePayload.self)
        let blocks = try await store.list(NoteBlockPayload.self, parentId: noteId)
        let links = try await store.list(
            RelationPayload.self,
            parentId: collectionId,
            entityTypeOverride: .collectionItem
        )
        let pending = try await database.pendingMutations()
        XCTAssertEqual(courses.count, 1)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(links.first?.payload.rightId, noteId)
        let session = try await store.payload(StudySessionPayload.self, id: sessionId)
        XCTAssertEqual(session.payload.state, .ended)
        XCTAssertNotNil(session.payload.endedAt)
        XCTAssertGreaterThanOrEqual(pending.count, 7)
    }

    func testPDFImportStoresEncryptedOriginalAndReusesDedupe() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let accountId = UUID()
        let accountKey = Data(0 ..< 32)
        let database = try SQLCipherDatabase(
            url: directory.appendingPathComponent("epistoria.sqlite"),
            key: try EntityCrypto().localDatabaseKey(accountKey: accountKey, accountId: accountId)
        )
        let store = EpistoriaStore(database: database)
        let manager = AssetManager(
            accountId: accountId,
            accountKey: accountKey,
            store: store,
            directory: directory.appendingPathComponent("Assets", isDirectory: true)
        )
        let original = Data("%PDF-1.4\nSynthetic original bytes\n%%EOF".utf8)
        let source = directory.appendingPathComponent("source.pdf")
        try original.write(to: source)

        let first = try await manager.importPDF(from: source)
        let second = try await manager.importPDF(from: source)
        XCTAssertFalse(first.reusedExistingAsset)
        XCTAssertTrue(second.reusedExistingAsset)
        XCTAssertEqual(first.assetId, second.assetId)
        XCTAssertNotEqual(first.resourceId, second.resourceId)
        let decrypted = try await manager.decryptedData(assetId: first.assetId)
        XCTAssertEqual(decrypted, original)
        let annotationId = try await store.save(
            payload: AnnotationPayload(
                resourceId: first.resourceId,
                annotationType: .important,
                pageNumber: 4,
                comment: "Important explanation of autonomous equations."
            ),
            parentId: first.resourceId,
            relationIds: [first.resourceId]
        )
        let annotation = try await store.payload(AnnotationPayload.self, id: annotationId)
        XCTAssertEqual(annotation.payload.pageNumber, 4)
        XCTAssertEqual(annotation.payload.resourceId, first.resourceId)
        let local = try await database.localAsset(id: first.assetId)
        let encrypted = try Data(contentsOf: XCTUnwrap(local?.encryptedFileURL))
        XCTAssertNil(encrypted.range(of: Data("Synthetic original bytes".utf8)))
    }

    func testSpatialNoteAndEncryptedImageRoundTripOffline() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let accountId = UUID()
        let accountKey = Data(repeating: 17, count: 32)
        let database = try SQLCipherDatabase(
            url: directory.appendingPathComponent("canvas.sqlite"),
            key: try EntityCrypto().localDatabaseKey(accountKey: accountKey, accountId: accountId)
        )
        let store = EpistoriaStore(database: database)
        let manager = AssetManager(
            accountId: accountId,
            accountKey: accountKey,
            store: store,
            directory: directory.appendingPathComponent("Assets", isDirectory: true)
        )
        let png = try XCTUnwrap(
            Data(
                base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
            )
        )
        let imageURL = directory.appendingPathComponent("reference.png")
        try png.write(to: imageURL, options: .atomic)

        let first = try await manager.importImage(from: imageURL)
        let second = try await manager.importImage(from: imageURL)
        XCTAssertFalse(first.reusedExistingAsset)
        XCTAssertTrue(second.reusedExistingAsset)
        XCTAssertEqual(first.assetId, second.assetId)
        XCTAssertEqual(first.pixelWidth, 1)
        XCTAssertEqual(first.pixelHeight, 1)
        let decrypted = try await manager.decryptedData(assetId: first.assetId)
        XCTAssertEqual(decrypted, png)

        let noteId = try await store.createNote(
            title: "Spatial notebook",
            canvas: NoteCanvasConfiguration(
                pageFormat: .infinite,
                orientation: .landscape,
                paperStyle: .dotted
            )
        )
        let placement = NoteCanvasPlacement(
            x: -320,
            y: 140,
            width: 420,
            height: 280,
            rotationRadians: 0.2,
            zIndex: 4
        )
        let imageId = try await store.appendCanvasImage(
            noteId: noteId,
            assetId: first.assetId,
            filename: first.filename,
            placement: placement
        )
        _ = try await store.appendCanvasInkLayer(noteId: noteId)

        let note = try await store.payload(NotePayload.self, id: noteId)
        let image = try await store.payload(NoteBlockPayload.self, id: imageId)
        XCTAssertEqual(note.payload.canvas?.pageFormat, .infinite)
        XCTAssertEqual(note.payload.canvas?.paperStyle, .dotted)
        XCTAssertEqual(image.payload.blockType, .image)
        XCTAssertEqual(image.payload.assetId, first.assetId)
        XCTAssertEqual(image.payload.canvasPlacement, placement)
        XCTAssertTrue(image.payload.plainText.contains("reference.png"))

        let local = try await database.localAsset(id: first.assetId)
        let encrypted = try Data(contentsOf: XCTUnwrap(local?.encryptedFileURL))
        XCTAssertNotEqual(encrypted, png)
        XCTAssertNil(encrypted.range(of: png))
    }

    func testSpatialSchemasDecodeLegacyNotesWithoutDiscardingContent() throws {
        let legacyNote = """
        {
          "archivedAt": null,
          "courseId": null,
          "createdAt": "2026-08-13T12:00:00.000Z",
          "schemaVersion": "note/v1",
          "studySessionId": null,
          "title": "Legacy",
          "updatedAt": "2026-08-13T12:00:00.000Z"
        }
        """
        let legacyBlock = """
        {
          "assetId": null,
          "blockType": "TEXT",
          "createdAt": "2026-08-13T12:00:00.000Z",
          "drawingData": null,
          "noteId": "00000000-0000-0000-0000-000000000001",
          "orderKey": "000000000000",
          "plainText": "Preserved text",
          "richTextRtf": null,
          "schemaVersion": "note-block/v1",
          "tombstone": false,
          "transcription": null,
          "updatedAt": "2026-08-13T12:00:00.000Z"
        }
        """

        let note = try CanonicalJSON.decode(NotePayload.self, from: Data(legacyNote.utf8))
        let block = try CanonicalJSON.decode(NoteBlockPayload.self, from: Data(legacyBlock.utf8))
        XCTAssertEqual(note.schemaVersion, "note/v1")
        XCTAssertNil(note.canvas)
        XCTAssertEqual(block.plainText, "Preserved text")
        XCTAssertNil(block.canvasPlacement)
        XCTAssertNil(block.canvasRole)
    }

    func testPageFormatsUsePrintPointsAndSupportTwoDirectionalWorldCoordinates() {
        let a4 = NoteCanvasConfiguration(pageFormat: .a4, orientation: .portrait, pageCount: 3)
        XCTAssertEqual(a4.pageWidth, 595)
        XCTAssertEqual(a4.pageHeight, 842)
        XCTAssertEqual(a4.effectivePageCount, 3)

        let letterLandscape = NoteCanvasConfiguration(
            pageFormat: .letter,
            orientation: .landscape
        )
        XCTAssertEqual(letterLandscape.pageWidth, 792)
        XCTAssertEqual(letterLandscape.pageHeight, 612)

        let infinite = NoteCanvasConfiguration(pageFormat: .infinite)
        XCTAssertNil(infinite.pageWidth)
        XCTAssertNil(infinite.pageHeight)
        XCTAssertEqual(infinite.effectivePageCount, 1)
        let placement = NoteCanvasPlacement(x: -12_000, y: -8_000, width: 400, height: 200)
        XCTAssertLessThan(placement.x, 0)
        XCTAssertLessThan(placement.y, 0)

        let modifiedPaper = NoteCanvasConfiguration(
            pageFormat: .letter,
            paperStyle: .isometric,
            paperColor: .stone,
            paperSpacing: 18
        )
        XCTAssertEqual(modifiedPaper.schemaVersion, "note-canvas/v3")
        XCTAssertEqual(modifiedPaper.paperStyle, .isometric)
        XCTAssertEqual(modifiedPaper.paperColor, .stone)
        XCTAssertEqual(modifiedPaper.paperSpacing, 18)
    }

    func testLegacyCanvasDefaultsToOnePage() throws {
        let legacy = """
        {
          "orientation": "PORTRAIT",
          "pageFormat": "A4",
          "paperStyle": "PLAIN",
          "schemaVersion": "note-canvas/v1"
        }
        """

        let canvas = try CanonicalJSON.decode(
            NoteCanvasConfiguration.self,
            from: Data(legacy.utf8)
        )

        XCTAssertEqual(canvas.schemaVersion, "note-canvas/v1")
        XCTAssertEqual(canvas.effectivePageCount, 1)
        XCTAssertEqual(canvas.paperColor, .white)
        XCTAssertEqual(canvas.paperSpacing, 28)
    }

    func testFinitePagesPersistAsMetadataWithPageLocalBlocks() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try SQLCipherDatabase(
            url: directory.appendingPathComponent("pages.sqlite"),
            key: Data(repeating: 23, count: 32)
        )
        let store = EpistoriaStore(database: database)
        let noteId = try await store.createNote(
            title: "Paged note",
            canvas: NoteCanvasConfiguration(pageFormat: .a4, pageCount: 4)
        )

        let emptyPages = try await store.list(NoteBlockPayload.self, parentId: noteId)
        XCTAssertTrue(emptyPages.isEmpty)

        let textId = try await store.appendCanvasText(
            noteId: noteId,
            text: "Only on page four",
            placement: NoteCanvasPlacement(x: 40, y: 60, width: 320, height: 120),
            pageIndex: 3
        )
        let inkId = try await store.appendCanvasInkLayer(noteId: noteId, pageIndex: 3)
        let shapeId = try await store.appendCanvasShape(
            noteId: noteId,
            shape: NoteCanvasShape(
                kind: .triangle,
                strokeColor: .blue,
                fillColor: .graphite,
                lineWidth: 5
            ),
            placement: NoteCanvasPlacement(x: 80, y: 220, width: 180, height: 140),
            pageIndex: 3
        )
        let symbolId = try await store.appendCanvasEquation(
            noteId: noteId,
            symbol: "∫",
            placement: NoteCanvasPlacement(x: 280, y: 220, width: 100, height: 90),
            pageIndex: 3
        )

        let reopened = try EpistoriaStore(
            database: SQLCipherDatabase(
                url: directory.appendingPathComponent("pages.sqlite"),
                key: Data(repeating: 23, count: 32)
            )
        )
        let note = try await reopened.payload(NotePayload.self, id: noteId)
        let text = try await reopened.payload(NoteBlockPayload.self, id: textId)
        let ink = try await reopened.payload(NoteBlockPayload.self, id: inkId)
        let shape = try await reopened.payload(NoteBlockPayload.self, id: shapeId)
        let symbol = try await reopened.payload(NoteBlockPayload.self, id: symbolId)

        XCTAssertEqual(note.payload.canvas?.effectivePageCount, 4)
        XCTAssertEqual(text.payload.canvasPageIndex, 3)
        XCTAssertEqual(ink.payload.canvasPageIndex, 3)
        XCTAssertEqual(ink.payload.canvasRole, .inkLayer)
        XCTAssertEqual(shape.payload.canvasShape?.kind, .triangle)
        XCTAssertEqual(shape.payload.canvasShape?.strokeColor, .blue)
        XCTAssertEqual(shape.payload.canvasShape?.fillColor, .graphite)
        XCTAssertEqual(shape.payload.canvasShape?.lineWidth, 5)
        XCTAssertEqual(shape.payload.canvasPageIndex, 3)
        XCTAssertEqual(symbol.payload.blockType, .equation)
        XCTAssertEqual(symbol.payload.plainText, "∫")
        XCTAssertEqual(symbol.payload.canvasPageIndex, 3)
    }

    func testConflictCandidateKeepsContentAndRelationshipUntilResolved() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try SQLCipherDatabase(
            url: directory.appendingPathComponent("epistoria.sqlite"),
            key: Data(repeating: 3, count: 32)
        )
        let noteId = UUID()
        let courseId = UUID()
        let content = try CanonicalJSON.encode(NotePayload(title: "Preserve this version"))
        _ = try await database.saveLocal(
            id: noteId,
            entityType: .note,
            parentId: courseId,
            relationIds: [courseId],
            content: content,
            search: SearchDocument(title: "Preserve this version", body: "")
        )
        let pending = try await database.pendingMutations()
        let mutation = try XCTUnwrap(pending.first)
        try await database.markConflict(mutationId: mutation.mutationId, serverConflictId: UUID())

        let conflicts = try await database.conflicts()
        let conflict = try XCTUnwrap(conflicts.first)
        XCTAssertEqual(conflict.candidateContent, content)
        XCTAssertEqual(conflict.parentId, courseId)
        XCTAssertEqual(conflict.relationIds, [courseId])
        let beforeHealth = try await database.dataHealth()
        XCTAssertEqual(beforeHealth.unresolvedConflicts, 1)

        try await database.resolveLocalConflict(id: conflict.id)
        let remaining = try await database.conflicts()
        let resolvedEntity = try await database.entity(id: noteId)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(resolvedEntity?.syncState, .synced)
    }

    func testRemotePageRollsBackAllEntitiesAndCursorWhenOneChangeIsInvalid() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try SQLCipherDatabase(
            url: directory.appendingPathComponent("page.sqlite"),
            key: Data(repeating: 14, count: 32)
        )
        let firstId = UUID()
        let secondId = UUID()
        let firstContent = try CanonicalJSON.encode(NotePayload(title: "First remote note"))
        let secondContent = try CanonicalJSON.encode(NotePayload(title: "Invalid remote note"))
        let updates = [
            RemoteEntityUpdate(
                entity: StoredEntity(
                    id: firstId,
                    entityType: .note,
                    parentId: nil,
                    relationIds: [],
                    content: firstContent,
                    revision: 1,
                    tombstone: false,
                    clientModifiedAt: .now,
                    syncState: .synced
                ),
                search: SearchDocument(title: "First remote note", body: "")
            ),
            RemoteEntityUpdate(
                entity: StoredEntity(
                    id: secondId,
                    entityType: .note,
                    parentId: nil,
                    relationIds: [],
                    content: secondContent,
                    revision: -1,
                    tombstone: false,
                    clientModifiedAt: .now,
                    syncState: .synced
                ),
                search: SearchDocument(title: "Invalid remote note", body: "")
            ),
        ]

        do {
            try await database.applyRemotePage(updates, nextSequence: "2")
            XCTFail("Expected the entire pull page to roll back")
        } catch let error as LocalDatabaseError {
            XCTAssertEqual(error, .invalidRow)
        }

        let rolledBackFirst = try await database.entity(id: firstId)
        let rolledBackSecond = try await database.entity(id: secondId)
        let rolledBackSequence = try await database.serverSequence()
        XCTAssertNil(rolledBackFirst)
        XCTAssertNil(rolledBackSecond)
        XCTAssertEqual(rolledBackSequence, "0")

        try await database.applyRemotePage([updates[0]], nextSequence: "1")
        let appliedFirst = try await database.entity(id: firstId)
        let appliedSequence = try await database.serverSequence()
        XCTAssertEqual(appliedFirst?.content, firstContent)
        XCTAssertEqual(appliedSequence, "1")
    }

    func testRemotePageRefusesToMoveCursorBackward() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try SQLCipherDatabase(
            url: directory.appendingPathComponent("cursor.sqlite"),
            key: Data(repeating: 15, count: 32)
        )
        try await database.setServerSequence("12")

        do {
            try await database.applyRemotePage([], nextSequence: "11")
            XCTFail("Expected cursor regression to fail closed")
        } catch let error as LocalDatabaseError {
            XCTAssertEqual(error, .cursorRegression)
        }
        let sequenceAfterRejection = try await database.serverSequence()
        XCTAssertEqual(sequenceAfterRejection, "12")
    }
}
