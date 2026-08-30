import Foundation
import XCTest
import ZIPFoundation
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

    func testUnassignedQuickNoteCanJoinCollectionAndSessionWithoutDuplication() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try SQLCipherDatabase(
            url: directory.appendingPathComponent("organization.sqlite"),
            key: Data(repeating: 31, count: 32)
        )
        let store = EpistoriaStore(database: database)
        let noteId = try await store.createNote(title: "Unassigned quick note")
        let collectionId = try await store.save(payload: CollectionPayload(name: "Algebra"))
        let sessionId = try await store.startSession(title: "Factoring practice")

        let firstCollectionLink = try await store.linkNote(noteId, toCollection: collectionId)
        let repeatedCollectionLink = try await store.linkNote(noteId, toCollection: collectionId)
        let firstSessionLink = try await store.linkNote(noteId, toSession: sessionId)
        let repeatedSessionLink = try await store.linkNote(noteId, toSession: sessionId)

        let note = try await store.payload(NotePayload.self, id: noteId)
        let collectionLinks = try await store.list(
            RelationPayload.self,
            parentId: collectionId,
            entityTypeOverride: .collectionItem
        )
        let sessionLinks = try await store.list(
            RelationPayload.self,
            parentId: sessionId,
            entityTypeOverride: .sessionNote
        )
        let linkedSessionNoteIds = try await store.noteIdsLinkedToSession(sessionId)

        XCTAssertNil(note.payload.studySessionId)
        XCTAssertEqual(firstCollectionLink, repeatedCollectionLink)
        XCTAssertEqual(firstSessionLink, repeatedSessionLink)
        XCTAssertEqual(collectionLinks.map(\.payload.rightId), [noteId])
        XCTAssertEqual(sessionLinks.map(\.payload.rightId), [noteId])
        XCTAssertEqual(linkedSessionNoteIds, [noteId])

        let activityCountBeforeUnlink = try await store.list(
            SessionActivityPayload.self,
            parentId: sessionId
        ).count
        try await store.unlinkNote(
            noteId,
            fromCollection: collectionId,
            at: Date(timeIntervalSince1970: 1_800_100_000)
        )
        try await store.unlinkNote(
            noteId,
            fromSession: sessionId,
            at: Date(timeIntervalSince1970: 1_800_100_001)
        )
        let collectionLinksAfterUnlink = try await store.list(
            RelationPayload.self,
            parentId: collectionId,
            entityTypeOverride: .collectionItem
        )
        let sessionNoteIdsAfterUnlink = try await store.noteIdsLinkedToSession(sessionId)
        let preservedNote = try await store.payload(NotePayload.self, id: noteId)
        let activityCountAfterUnlink = try await store.list(
            SessionActivityPayload.self,
            parentId: sessionId
        ).count
        let collectionLinkEntity = try await database.entity(id: firstCollectionLink)
        let sessionLinkEntity = try await database.entity(id: firstSessionLink)
        XCTAssertTrue(collectionLinksAfterUnlink.isEmpty)
        XCTAssertTrue(sessionNoteIdsAfterUnlink.isEmpty)
        XCTAssertEqual(preservedNote.id, noteId)
        XCTAssertEqual(activityCountAfterUnlink, activityCountBeforeUnlink)
        XCTAssertEqual(collectionLinkEntity?.tombstone, true)
        XCTAssertEqual(sessionLinkEntity?.tombstone, true)
        let deletionMutations = try await database.pendingMutations().filter {
            $0.entityId == firstCollectionLink || $0.entityId == firstSessionLink
        }
        XCTAssertEqual(deletionMutations.count, 2)
        XCTAssertTrue(deletionMutations.allSatisfy { $0.operation == .delete })

        let replacementCollectionLink = try await store.linkNote(noteId, toCollection: collectionId)
        let replacementSessionLink = try await store.linkNote(noteId, toSession: sessionId)
        XCTAssertNotEqual(replacementCollectionLink, firstCollectionLink)
        XCTAssertNotEqual(replacementSessionLink, firstSessionLink)

        let legacyNoteId = try await store.save(
            payload: NotePayload(
                title: "Legacy session note",
                studySessionId: sessionId,
                now: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            parentId: sessionId,
            relationIds: [sessionId]
        )
        let legacyMembershipBeforeUnlink = try await store.noteIdsLinkedToSession(sessionId)
        XCTAssertTrue(legacyMembershipBeforeUnlink.contains(legacyNoteId))
        try await store.unlinkNote(
            legacyNoteId,
            fromSession: sessionId,
            at: Date(timeIntervalSince1970: 1_800_100_002)
        )
        let upgradedLegacyNote = try await store.payload(NotePayload.self, id: legacyNoteId)
        let legacyMembershipAfterUnlink = try await store.noteIdsLinkedToSession(sessionId)
        XCTAssertNil(upgradedLegacyNote.payload.studySessionId)
        XCTAssertFalse(legacyMembershipAfterUnlink.contains(legacyNoteId))
        let preservedActivities = try await store.list(
            SessionActivityPayload.self,
            parentId: sessionId
        )
        XCTAssertEqual(preservedActivities.count, activityCountBeforeUnlink + 1)
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

    func testCanvasImageEditsRemainNonDestructiveAndDurable() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("image-edits.sqlite")
        let key = Data(repeating: 73, count: 32)
        let database = try SQLCipherDatabase(url: databaseURL, key: key)
        let store = EpistoriaStore(database: database)
        let originalAssetId = UUID()
        let replacementAssetId = UUID()
        for (id, filename) in [
            (originalAssetId, "original.png"),
            (replacementAssetId, "replacement.png"),
        ] {
            _ = try await store.save(
                id: id,
                payload: AssetPayload(
                    mimeType: "image/png",
                    plaintextByteSize: 100,
                    encryptedByteSize: 140,
                    dedupeTag: id.uuidString.lowercased(),
                    assetKey: "fixture/\(id.uuidString.lowercased())",
                    originalFilename: filename
                )
            )
        }
        let noteId = try await store.createNote(title: "Non-destructive image")
        let imageId = try await store.appendCanvasImage(
            noteId: noteId,
            assetId: originalAssetId,
            filename: "original.png",
            placement: NoteCanvasPlacement(x: 30, y: 40, width: 400, height: 300)
        )
        let originalOCRRevision = try await store.payload(NoteBlockPayload.self, id: imageId)
            .payload.ocrInputRevision
        let artifactId = try await store.saveOCRArtifact(
            request: LocalOCRRequest(
                accountId: UUID(),
                targetKind: .notebookRegion,
                targetId: imageId,
                parentId: noteId,
                noteId: noteId,
                inputRevision: originalOCRRevision,
                imageData: Data("original image crop".utf8),
                mode: .text
            ),
            response: LocalOCRResponse(
                engine: .deterministic,
                engineVersion: "fixture/v1",
                regions: [
                    LocalOCRRegion(
                        kind: .text,
                        text: "recognition that must become stale"
                    ),
                ]
            )
        )
        let configuration = NoteCanvasImageConfiguration(
            crop: NoteCanvasImageCrop(x: 0.12, y: 0.18, width: 0.72, height: 0.64),
            mask: .roundedRectangle,
            roundedCornerFraction: 0.2,
            rotationQuarterTurns: -1
        )
        _ = try await store.updateCanvasImage(
            id: imageId,
            configuration: configuration,
            replacementAssetId: replacementAssetId,
            replacementFilename: "replacement.png"
        )

        let reopened = EpistoriaStore(database: try SQLCipherDatabase(url: databaseURL, key: key))
        var image = try await reopened.payload(NoteBlockPayload.self, id: imageId)
        let storedConfiguration = try XCTUnwrap(image.payload.imageConfiguration)
        XCTAssertEqual(image.payload.schemaVersion, "note-block/v7")
        XCTAssertEqual(image.payload.assetId, replacementAssetId)
        XCTAssertEqual(image.payload.plainText, "replacement.png")
        XCTAssertEqual(storedConfiguration.crop, configuration.crop)
        XCTAssertEqual(storedConfiguration.mask, .roundedRectangle)
        XCTAssertEqual(storedConfiguration.roundedCornerFraction, 0.2)
        XCTAssertEqual(storedConfiguration.rotationQuarterTurns, 3)
        XCTAssertEqual(storedConfiguration.originalAssetId, originalAssetId)
        XCTAssertNotEqual(image.payload.ocrInputRevision, originalOCRRevision)
        let staleArtifact = try await reopened.payload(OCRArtifactPayload.self, id: artifactId)
        let staleSearch = try await reopened.database.search("must become stale")
        XCTAssertEqual(staleArtifact.payload.state, .stale)
        XCTAssertTrue(staleSearch.isEmpty)
        let storedEntity = try await reopened.database.entity(id: imageId)
        let entity = try XCTUnwrap(storedEntity)
        XCTAssertTrue(entity.relationIds.contains(originalAssetId))
        XCTAssertTrue(entity.relationIds.contains(replacementAssetId))

        _ = try await reopened.updateCanvasImage(
            id: imageId,
            configuration: NoteCanvasImageConfiguration(originalAssetId: originalAssetId),
            replacementAssetId: originalAssetId,
            replacementFilename: "original.png"
        )
        image = try await reopened.payload(NoteBlockPayload.self, id: imageId)
        XCTAssertEqual(image.payload.assetId, originalAssetId)
        XCTAssertEqual(image.payload.imageConfiguration?.originalAssetId, originalAssetId)
        XCTAssertTrue(image.payload.imageConfiguration?.crop.isFullFrame == true)
        XCTAssertEqual(image.payload.ocrInputRevision, originalOCRRevision)
        let storedRestoredEntity = try await reopened.database.entity(id: imageId)
        let restoredEntity = try XCTUnwrap(storedRestoredEntity)
        XCTAssertEqual(restoredEntity.relationIds, [noteId, originalAssetId])
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

    func testLegacyCourseBecomesTopicOnlyOnMutationAndKeepsRecoveryBackup() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try SQLCipherDatabase(
            url: directory.appendingPathComponent("topic-migration.sqlite"),
            key: Data(repeating: 41, count: 32)
        )
        let store = EpistoriaStore(database: database)
        let id = try await store.save(payload: CoursePayload(name: "Topology", code: "MATH-401"))
        let storedLegacy = try await database.entity(id: id)
        let legacyContent = try XCTUnwrap(storedLegacy?.content)

        var topic = try await store.topic(id: id).payload
        XCTAssertEqual(topic.schemaVersion, "course/v1")
        XCTAssertEqual(topic.name, "Topology")
        topic.topicDescription = "Open and closed sets"
        topic.updatedAt = .now
        _ = try await store.saveTopic(id: id, payload: topic)

        let upgraded = try await store.topic(id: id).payload
        let backup = try await database.migrationBackup(
            entityId: id,
            migrationName: "course-to-topic/v1"
        )
        XCTAssertEqual(upgraded.schemaVersion, "topic/v1")
        XCTAssertEqual(upgraded.topicDescription, "Open and closed sets")
        XCTAssertEqual(backup, legacyContent)
        let storedUpgraded = try await database.entity(id: id)
        let journal = try await database.migrationJournal()
        XCTAssertEqual(storedUpgraded?.entityType, .course)
        XCTAssertEqual(journal.count, 1)
        XCTAssertEqual(journal.first?.name, "course-to-topic/v1")
        XCTAssertNotNil(journal.first?.completedAt)
        XCTAssertNil(journal.first?.failureCode)
    }

    func testSourceCreationFreezesInitialVersionAtomically() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try SQLCipherDatabase(
            url: directory.appendingPathComponent("source.sqlite"),
            key: Data(repeating: 42, count: 32)
        )
        let store = EpistoriaStore(database: database)
        let areaId = try await store.createArea(name: "Mathematics")
        let topicId = try await store.createTopic(name: "Algebra", primaryAreaId: areaId)
        let assetId = try await store.save(
            payload: AssetPayload(
                mimeType: "text/plain",
                plaintextByteSize: 12,
                encryptedByteSize: 64,
                dedupeTag: String(repeating: "a", count: 64),
                assetKey: String(repeating: "A", count: 43),
                originalFilename: "factoring.txt"
            )
        )
        let sourceId = try await store.createSource(
            type: .pastedText,
            title: "Factoring",
            originalAssetId: assetId,
            primaryTopicId: topicId
        )
        let source = try await store.payload(SourcePayload.self, id: sourceId)
        let versionId = try XCTUnwrap(source.payload.currentVersionId)
        let version = try await store.payload(SourceVersionPayload.self, id: versionId)
        XCTAssertEqual(source.payload.schemaVersion, "source/v1")
        XCTAssertEqual(source.payload.primaryTopicId, topicId)
        XCTAssertEqual(version.payload.sourceId, sourceId)
        XCTAssertEqual(version.payload.originalAssetId, assetId)
    }

    func testCSVImportEncryptsOriginalAndMalformedInputCreatesNoPartialRecord() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try SQLCipherDatabase(
            url: directory.appendingPathComponent("csv-source.sqlite"),
            key: Data(repeating: 55, count: 32)
        )
        let store = EpistoriaStore(database: database)
        let manager = AssetManager(
            accountId: UUID(),
            accountKey: Data(repeating: 56, count: 32),
            store: store,
            directory: directory.appendingPathComponent("assets", isDirectory: true)
        )
        let validData = Data("name,value\nEuler,2.718".utf8)
        let validURL = directory.appendingPathComponent("constants.csv")
        try validData.write(to: validURL, options: .atomic)

        let imported = try await manager.importSource(from: validURL)
        let source = try await store.payload(SourcePayload.self, id: imported.resourceId)
        let decrypted = try await manager.decryptedData(assetId: imported.assetId)
        XCTAssertEqual(source.payload.sourceType, .csv)
        XCTAssertEqual(source.payload.title, "constants")
        XCTAssertEqual(decrypted, validData)
        XCTAssertNotNil(source.payload.currentVersionId)

        let malformedURL = directory.appendingPathComponent("broken.csv")
        try Data("name,\"unterminated".utf8).write(to: malformedURL, options: .atomic)
        do {
            _ = try await manager.importSource(from: malformedURL)
            XCTFail("Malformed CSV should fail before any record is created")
        } catch let error as SourceAdapterError {
            XCTAssertEqual(error, .malformed)
        }
        let sources = try await store.list(SourcePayload.self)
        let assets = try await store.list(AssetPayload.self)
        let versions = try await store.list(SourceVersionPayload.self)
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(assets.count, 1)
        XCTAssertEqual(versions.count, 1)
    }

    func testAudioImportEncryptsDecodableOriginalAndSpoofCreatesNoPartialRecord() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try SQLCipherDatabase(
            url: directory.appendingPathComponent("audio-source.sqlite"),
            key: Data(repeating: 57, count: 32)
        )
        let store = EpistoriaStore(database: database)
        let manager = AssetManager(
            accountId: UUID(),
            accountKey: Data(repeating: 58, count: 32),
            store: store,
            directory: directory.appendingPathComponent("assets", isDirectory: true)
        )
        let audio = testWAVEData()
        let audioURL = directory.appendingPathComponent("lecture.wav")
        try audio.write(to: audioURL, options: .atomic)

        let imported = try await manager.importSource(from: audioURL)
        let source = try await store.payload(SourcePayload.self, id: imported.resourceId)
        let decrypted = try await manager.decryptedData(assetId: imported.assetId)
        XCTAssertEqual(source.payload.sourceType, .audio)
        XCTAssertEqual(decrypted, audio)
        XCTAssertNotNil(source.payload.currentVersionId)

        let spoofURL = directory.appendingPathComponent("spoofed.mp3")
        try Data("not audio".utf8).write(to: spoofURL, options: .atomic)
        await XCTAssertThrowsErrorAsync(try await manager.importSource(from: spoofURL)) { error in
            XCTAssertEqual(error as? SourceAdapterError, .malformed)
        }
        let sources = try await store.list(SourcePayload.self)
        let versions = try await store.list(SourceVersionPayload.self)
        let assets = try await store.list(AssetPayload.self)
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(versions.count, 1)
        XCTAssertEqual(assets.count, 1)
    }

    func testVideoImportEncryptsDecodableOriginalAndSpoofCreatesNoPartialRecord() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try SQLCipherDatabase(
            url: directory.appendingPathComponent("video-source.sqlite"),
            key: Data(repeating: 59, count: 32)
        )
        let store = EpistoriaStore(database: database)
        let manager = AssetManager(
            accountId: UUID(),
            accountKey: Data(repeating: 60, count: 32),
            store: store,
            directory: directory.appendingPathComponent("assets", isDirectory: true)
        )
        let video = testMP4Data()
        let videoURL = directory.appendingPathComponent("lesson.mp4")
        try video.write(to: videoURL, options: .atomic)

        let imported = try await manager.importSource(from: videoURL)
        let source = try await store.payload(SourcePayload.self, id: imported.resourceId)
        let decrypted = try await manager.decryptedData(assetId: imported.assetId)
        XCTAssertEqual(source.payload.sourceType, .video)
        XCTAssertEqual(decrypted, video)
        XCTAssertNotNil(source.payload.currentVersionId)

        let spoofURL = directory.appendingPathComponent("spoofed.mp4")
        try Data("not video".utf8).write(to: spoofURL, options: .atomic)
        await XCTAssertThrowsErrorAsync(try await manager.importSource(from: spoofURL)) { error in
            XCTAssertEqual(error as? SourceAdapterError, .malformed)
        }
        let sources = try await store.list(SourcePayload.self)
        let versions = try await store.list(SourceVersionPayload.self)
        let assets = try await store.list(AssetPayload.self)
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(versions.count, 1)
        XCTAssertEqual(assets.count, 1)
    }

    func testWebSnapshotImportRefreshAndFailuresPreserveImmutableVersions() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try SQLCipherDatabase(
            url: directory.appendingPathComponent("web-source.sqlite"),
            key: Data(repeating: 61, count: 32)
        )
        let store = EpistoriaStore(database: database)
        let requestedURL = try XCTUnwrap(URL(string: "https://example.com/algebra"))
        let firstURL = try XCTUnwrap(URL(string: "https://www.example.com/algebra?v=1"))
        let secondURL = try XCTUnwrap(URL(string: "https://www.example.com/algebra?v=2"))
        let firstHTML = Data(
            "<html><head><title>Algebra</title></head><body><h1>Factoring</h1><p>Old example</p></body></html>".utf8
        )
        let secondHTML = Data(
            "<html><head><title>Algebra revised</title></head><body><h1>Factoring</h1><p>New example</p></body></html>".utf8
        )
        let capture = TestWebSnapshotCapture(outcomes: [
            .snapshot(TestWebSnapshotCapture.snapshot(
                requestedURL: requestedURL,
                capturedURL: firstURL,
                title: "Algebra",
                data: firstHTML
            )),
            .snapshot(TestWebSnapshotCapture.snapshot(
                requestedURL: requestedURL,
                capturedURL: secondURL,
                title: "Algebra revised",
                data: secondHTML
            )),
            .failure(.networkUnavailable),
            .snapshot(TestWebSnapshotCapture.snapshot(
                requestedURL: requestedURL,
                capturedURL: secondURL,
                title: "Malformed",
                data: Data([0, 1, 2])
            )),
            .snapshot(TestWebSnapshotCapture.snapshot(
                requestedURL: requestedURL,
                capturedURL: secondURL,
                title: "Oversized",
                data: Data(repeating: 65, count: WebSnapshotCaptureService.maximumBytes + 1)
            )),
        ])
        let manager = AssetManager(
            accountId: UUID(),
            accountKey: Data(repeating: 62, count: 32),
            store: store,
            directory: directory.appendingPathComponent("assets", isDirectory: true),
            webSnapshotCapture: capture
        )

        let imported = try await manager.importWebSnapshot(from: requestedURL)
        var source = try await store.payload(SourcePayload.self, id: imported.resourceId)
        XCTAssertEqual(source.payload.sourceType, .website)
        XCTAssertEqual(source.payload.canonicalURL, requestedURL)
        XCTAssertEqual(source.payload.title, "Algebra")
        let firstVersionId = try XCTUnwrap(source.payload.currentVersionId)
        let firstVersion = try await store.payload(SourceVersionPayload.self, id: firstVersionId)
        XCTAssertEqual(firstVersion.payload.capturedURL, firstURL)
        let decryptedFirstImport = try await manager.decryptedData(assetId: imported.assetId)
        XCTAssertEqual(decryptedFirstImport, firstHTML)

        let refreshed = try await manager.refreshWebSnapshot(id: imported.resourceId)
        XCTAssertEqual(refreshed.capturedURL, secondURL)
        XCTAssertEqual(refreshed.difference.addedExamples, ["New example"])
        XCTAssertEqual(refreshed.difference.removedExamples, ["Old example"])
        source = try await store.payload(SourcePayload.self, id: imported.resourceId)
        let secondAssetId = try XCTUnwrap(source.payload.originalAssetId)
        XCTAssertEqual(source.payload.currentVersionId, refreshed.versionId)
        let decryptedSecondImport = try await manager.decryptedData(assetId: secondAssetId)
        XCTAssertEqual(decryptedSecondImport, secondHTML)
        let versions = try await store.list(SourceVersionPayload.self, parentId: imported.resourceId)
        XCTAssertEqual(versions.count, 2)
        let oldVersionAssetId = try XCTUnwrap(firstVersion.payload.originalAssetId)
        let decryptedOldVersion = try await manager.decryptedData(assetId: oldVersionAssetId)
        XCTAssertEqual(decryptedOldVersion, firstHTML)

        await XCTAssertThrowsErrorAsync(try await manager.refreshWebSnapshot(id: imported.resourceId)) {
            XCTAssertEqual($0 as? WebSnapshotCaptureError, .networkUnavailable)
        }
        await XCTAssertThrowsErrorAsync(try await manager.importWebSnapshot(from: requestedURL)) {
            XCTAssertEqual($0 as? SourceAdapterError, .malformed)
        }
        await XCTAssertThrowsErrorAsync(try await manager.importWebSnapshot(from: requestedURL)) {
            XCTAssertEqual($0 as? SourceAdapterError, .tooLarge)
        }
        let remainingSources = try await store.list(SourcePayload.self)
        let remainingVersions = try await store.list(SourceVersionPayload.self)
        let remainingAssets = try await store.list(AssetPayload.self)
        XCTAssertEqual(remainingSources.count, 1)
        XCTAssertEqual(remainingVersions.count, 2)
        XCTAssertEqual(remainingAssets.count, 2)
    }

    func testGoogleWorkspaceImportRefreshAndFailuresPreserveImmutableVersions() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try SQLCipherDatabase(
            url: directory.appendingPathComponent("google-source.sqlite"),
            key: Data(repeating: 63, count: 32)
        )
        let store = EpistoriaStore(database: database)
        let requestedURL = try XCTUnwrap(URL(
            string: "https://docs.google.com/document/d/algebra123/edit?usp=sharing"
        ))
        let firstData = try testDOCXData(text: "Old factorization example")
        let secondData = try testDOCXData(text: "New factorization example")
        let sheetData = try testXLSXData(text: "Unexpected type")
        let capture = TestGoogleWorkspaceCapture(outcomes: [
            .snapshot(try TestGoogleWorkspaceCapture.snapshot(
                url: requestedURL,
                kind: .document,
                title: "Algebra notes",
                data: firstData
            )),
            .snapshot(try TestGoogleWorkspaceCapture.snapshot(
                url: requestedURL,
                kind: .document,
                title: "Algebra notes revised",
                data: secondData
            )),
            .failure(.networkUnavailable),
            .snapshot(try TestGoogleWorkspaceCapture.snapshot(
                url: try XCTUnwrap(URL(
                    string: "https://docs.google.com/spreadsheets/d/algebra123/edit"
                )),
                kind: .sheet,
                title: "Wrong kind",
                data: sheetData
            )),
            .snapshot(GoogleWorkspaceSnapshot(
                kind: .document,
                canonicalURL: try GoogleWorkspaceReference(url: requestedURL).canonicalURL,
                capturedURL: try GoogleWorkspaceReference(url: requestedURL).exportURL,
                mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                title: "Malformed",
                data: Data("not docx".utf8),
                readableText: ""
            )),
        ])
        let manager = AssetManager(
            accountId: UUID(),
            accountKey: Data(repeating: 64, count: 32),
            store: store,
            directory: directory.appendingPathComponent("assets", isDirectory: true),
            googleWorkspaceCapture: capture
        )

        let imported = try await manager.importGoogleWorkspaceSnapshot(from: requestedURL)
        var source = try await store.payload(SourcePayload.self, id: imported.resourceId)
        let reference = try GoogleWorkspaceReference(url: requestedURL)
        XCTAssertEqual(source.payload.sourceType, .googleDocument)
        XCTAssertEqual(source.payload.canonicalURL, reference.canonicalURL)
        XCTAssertEqual(source.payload.title, "Algebra notes")
        let firstVersionId = try XCTUnwrap(source.payload.currentVersionId)
        let firstVersion = try await store.payload(SourceVersionPayload.self, id: firstVersionId)
        XCTAssertEqual(firstVersion.payload.capturedURL, reference.exportURL)
        let decryptedFirstData = try await manager.decryptedData(assetId: imported.assetId)
        XCTAssertEqual(decryptedFirstData, firstData)

        let refreshed = try await manager.refreshGoogleWorkspaceSnapshot(id: imported.resourceId)
        XCTAssertEqual(refreshed.difference.addedExamples, ["New factorization example"])
        XCTAssertEqual(refreshed.difference.removedExamples, ["Old factorization example"])
        source = try await store.payload(SourcePayload.self, id: imported.resourceId)
        XCTAssertEqual(source.payload.currentVersionId, refreshed.versionId)
        let currentAssetId = try XCTUnwrap(source.payload.originalAssetId)
        let decryptedSecondData = try await manager.decryptedData(assetId: currentAssetId)
        XCTAssertEqual(decryptedSecondData, secondData)
        let oldAssetId = try XCTUnwrap(firstVersion.payload.originalAssetId)
        let decryptedOldData = try await manager.decryptedData(assetId: oldAssetId)
        XCTAssertEqual(decryptedOldData, firstData)

        await XCTAssertThrowsErrorAsync(
            try await manager.refreshGoogleWorkspaceSnapshot(id: imported.resourceId)
        ) { XCTAssertEqual($0 as? GoogleWorkspaceCaptureError, .networkUnavailable) }
        await XCTAssertThrowsErrorAsync(
            try await manager.refreshGoogleWorkspaceSnapshot(id: imported.resourceId)
        ) { XCTAssertEqual($0 as? SourceAdapterError, .unsupportedType) }
        await XCTAssertThrowsErrorAsync(
            try await manager.importGoogleWorkspaceSnapshot(from: requestedURL)
        ) { XCTAssertEqual($0 as? SourceAdapterError, .malformed) }

        let remainingSources = try await store.list(SourcePayload.self)
        let remainingVersions = try await store.list(SourceVersionPayload.self)
        let remainingAssets = try await store.list(AssetPayload.self)
        XCTAssertEqual(remainingSources.count, 1)
        XCTAssertEqual(remainingVersions.count, 2)
        XCTAssertEqual(remainingAssets.count, 2)
    }

    func testYouTubeImportStoresOnlyNormalizedReferenceAndCreatesNoAsset() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try SQLCipherDatabase(
            url: directory.appendingPathComponent("youtube-source.sqlite"),
            key: Data(repeating: 65, count: 32)
        )
        let store = EpistoriaStore(database: database)
        let manager = AssetManager(
            accountId: UUID(),
            accountKey: Data(repeating: 66, count: 32),
            store: store,
            directory: directory.appendingPathComponent("assets", isDirectory: true)
        )
        let topicId = try await store.createTopic(name: "Linear algebra")
        let sharedURL = try XCTUnwrap(URL(string: "https://youtu.be/dQw4w9WgXcQ?t=1m30s"))

        let imported = try await manager.importYouTubeReference(
            from: sharedURL,
            title: "  Matrix lesson  ",
            topicId: topicId
        )
        let source = try await store.payload(SourcePayload.self, id: imported.sourceId)
        XCTAssertEqual(imported.videoID, "dQw4w9WgXcQ")
        XCTAssertEqual(source.payload.sourceType, .youtube)
        XCTAssertEqual(source.payload.title, "Matrix lesson")
        XCTAssertEqual(
            source.payload.canonicalURL?.absoluteString,
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        )
        XCTAssertEqual(source.payload.identifiers, ["youtube:dQw4w9WgXcQ"])
        XCTAssertEqual(source.payload.primaryTopicId, topicId)
        XCTAssertNil(source.payload.originalAssetId)
        XCTAssertFalse(source.payload.locallyAvailable)

        let versionId = try XCTUnwrap(source.payload.currentVersionId)
        let version = try await store.payload(SourceVersionPayload.self, id: versionId)
        XCTAssertNil(version.payload.originalAssetId)
        XCTAssertEqual(
            version.payload.capturedURL?.absoluteString,
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=90s"
        )
        let initialAssets = try await store.list(AssetPayload.self)
        XCTAssertTrue(initialAssets.isEmpty)

        let invalid = try XCTUnwrap(URL(string: "https://www.youtube.com/playlist?list=private"))
        await XCTAssertThrowsErrorAsync(
            try await manager.importYouTubeReference(from: invalid)
        ) { error in
            XCTAssertEqual(error as? YouTubeReferenceError, .unsupportedVideo)
        }
        let remainingSources = try await store.list(SourcePayload.self)
        let remainingVersions = try await store.list(SourceVersionPayload.self)
        let remainingAssets = try await store.list(AssetPayload.self)
        XCTAssertEqual(remainingSources.count, 1)
        XCTAssertEqual(remainingVersions.count, 1)
        XCTAssertTrue(remainingAssets.isEmpty)
    }

    func testTimestampedTranscriptArtifactsRemainDurableAndVersionBound() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let accountId = UUID()
        let accountKey = Data(repeating: 67, count: 32)
        let database = try SQLCipherDatabase(
            url: directory.appendingPathComponent("transcript.sqlite"),
            key: Data(repeating: 68, count: 32)
        )
        let store = EpistoriaStore(database: database)
        let assetId = try await store.save(payload: AssetPayload(
            mimeType: "audio/wav",
            plaintextByteSize: 1_024,
            encryptedByteSize: 1_100,
            dedupeTag: String(repeating: "a", count: 64),
            assetKey: String(repeating: "A", count: 43),
            originalFilename: "lecture.wav"
        ))
        let sourceId = try await store.createSource(
            type: .audio,
            title: "Topology lecture",
            originalAssetId: assetId
        )
        let source = try await store.payload(SourcePayload.self, id: sourceId)
        let sourceVersionId = try XCTUnwrap(source.payload.currentVersionId)
        let jobId = UUID()
        let chunkId = UUID()
        let segments = [
            TranscriptSegment(index: 0, startSeconds: 0, endSeconds: 2, text: "Open sets."),
            TranscriptSegment(index: 1, startSeconds: 2, endSeconds: 5, text: "Closed sets."),
        ]
        let chunk = MediaTranscriptionChunk(
            jobId: jobId,
            sourceId: sourceId,
            sourceVersionId: sourceVersionId,
            chunkIndex: 0,
            segments: segments
        )
        _ = try await database.saveLocal(
            id: chunkId,
            entityType: .aiArtifact,
            parentId: sourceId,
            relationIds: [sourceId, sourceVersionId],
            content: try CanonicalJSON.encode(chunk),
            search: SearchDocument(title: "", body: "")
        )
        let manifest = MediaTranscriptionManifest(
            jobId: jobId,
            sourceId: sourceId,
            sourceVersionId: sourceVersionId,
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            language: "en",
            durationSeconds: 5,
            characterCount: 22,
            segmentCount: 2,
            trace: ProviderTrace(
                provider: "deterministic-test",
                model: "fixture-transcription-v1",
                promptVersion: "media-transcription/v1"
            ),
            chunkEntityIds: [chunkId]
        )
        let transcriptionArtifactId = try await store.save(
            payload: manifest,
            parentId: sourceId,
            relationIds: [sourceId, sourceVersionId, chunkId]
        )
        let api = EpistoriaAPIClient(
            baseURL: try XCTUnwrap(URL(string: "https://sync.example.test/v1")),
            credentials: DeviceCredentials(
                ownerId: accountId,
                deviceId: UUID(),
                token: String(repeating: "t", count: 43)
            )
        )
        let coordinator = AIJobCoordinator(
            accountId: accountId,
            accountKey: accountKey,
            store: store,
            api: api
        )

        let latest = try await coordinator.latestMediaTranscription(
            sourceId: sourceId,
            sourceVersionId: sourceVersionId
        )
        let loaded = try XCTUnwrap(latest)
        XCTAssertEqual(loaded.payload, manifest)
        let loadedSegments = try await coordinator.mediaTranscriptionSegments(
            manifest: loaded.payload
        )
        XCTAssertEqual(loadedSegments, segments)
        await XCTAssertThrowsErrorAsync(
            try await store.createTranscriptEvidence(
                transcriptionArtifactId: transcriptionArtifactId,
                segmentIndexes: [0]
            )
        ) { error in
            XCTAssertEqual(error as? StoreError, .transcriptReviewRequired)
        }

        let firstCorrectionId = try await store.createTranscriptCorrection(
            transcriptionArtifactId: transcriptionArtifactId,
            segmentIndex: 1,
            correctedText: "Closed subsets.",
            reason: "The lecturer said subsets.",
            at: Date(timeIntervalSince1970: 1_800_000_010)
        )
        var reviewed = try await store.reviewedTranscriptSegments(
            transcriptionArtifactId: transcriptionArtifactId
        )
        XCTAssertEqual(reviewed.map(\ .text), ["Open sets.", "Closed subsets."])
        XCTAssertEqual(reviewed[1].correctionId, firstCorrectionId)
        let reviewedManifest = try await store.payload(
            MediaTranscriptionManifest.self,
            id: transcriptionArtifactId
        )
        XCTAssertEqual(reviewedManifest.payload.reviewState, .edited)

        let secondCorrectionId = try await store.createTranscriptCorrection(
            transcriptionArtifactId: transcriptionArtifactId,
            segmentIndex: 1,
            correctedText: "Closed subsets in the space.",
            reason: "Added the complete phrase.",
            at: Date(timeIntervalSince1970: 1_800_000_020)
        )
        let correctionHistory = try await store.transcriptCorrections(
            transcriptionArtifactId: transcriptionArtifactId
        )
        XCTAssertEqual(correctionHistory.count, 2)
        XCTAssertEqual(
            correctionHistory.first(where: { $0.id == firstCorrectionId })?.payload.state,
            .superseded
        )
        XCTAssertEqual(
            correctionHistory.first(where: { $0.id == secondCorrectionId })?.payload.state,
            .active
        )
        XCTAssertEqual(
            correctionHistory.first(where: { $0.id == secondCorrectionId })?.payload.supersedesCorrectionId,
            firstCorrectionId
        )

        let evidenceId = try await store.createTranscriptEvidence(
            transcriptionArtifactId: transcriptionArtifactId,
            segmentIndexes: [0, 1],
            note: "Definition review",
            at: Date(timeIntervalSince1970: 1_800_000_030)
        )
        let evidence = try await store.payload(EvidencePayload.self, id: evidenceId)
        XCTAssertEqual(evidence.payload.kind, .mediaClip)
        XCTAssertEqual(evidence.payload.locator.kind, .media)
        XCTAssertEqual(evidence.payload.locator.startSeconds, 0)
        XCTAssertEqual(evidence.payload.locator.endSeconds, 5)
        XCTAssertEqual(evidence.payload.excerpt, "Open sets. Closed subsets in the space.")
        XCTAssertEqual(evidence.payload.transcriptionArtifactId, transcriptionArtifactId)
        XCTAssertEqual(evidence.payload.resolvedTranscriptSegmentIndexes, [0, 1])
        XCTAssertEqual(evidence.payload.resolvedTranscriptCorrectionIds, [secondCorrectionId])

        try await store.retractTranscriptCorrection(
            id: secondCorrectionId,
            at: Date(timeIntervalSince1970: 1_800_000_040)
        )
        reviewed = try await store.reviewedTranscriptSegments(
            transcriptionArtifactId: transcriptionArtifactId
        )
        XCTAssertEqual(reviewed.map(\ .text), ["Open sets.", "Closed sets."])
        let frozenEvidence = try await store.payload(EvidencePayload.self, id: evidenceId)
        XCTAssertEqual(frozenEvidence.payload.excerpt, "Open sets. Closed subsets in the space.")
        XCTAssertEqual(frozenEvidence.payload.resolvedTranscriptCorrectionIds, [secondCorrectionId])

        let deviceACorrectionId = try await store.save(
            payload: TranscriptCorrectionPayload(
                sourceId: sourceId,
                sourceVersionId: sourceVersionId,
                transcriptionArtifactId: transcriptionArtifactId,
                segment: segments[1],
                correctedText: "Closed subsets from device A.",
                now: Date(timeIntervalSince1970: 1_800_000_050)
            ),
            parentId: sourceId,
            relationIds: [sourceId, sourceVersionId, transcriptionArtifactId]
        )
        let deviceBCorrectionId = try await store.save(
            payload: TranscriptCorrectionPayload(
                sourceId: sourceId,
                sourceVersionId: sourceVersionId,
                transcriptionArtifactId: transcriptionArtifactId,
                segment: segments[1],
                correctedText: "Closed subsets from device B.",
                now: Date(timeIntervalSince1970: 1_800_000_051)
            ),
            parentId: sourceId,
            relationIds: [sourceId, sourceVersionId, transcriptionArtifactId]
        )
        await XCTAssertThrowsErrorAsync(
            try await store.reviewedTranscriptSegments(
                transcriptionArtifactId: transcriptionArtifactId
            )
        ) { error in
            XCTAssertEqual(error as? StoreError, .transcriptCorrectionConflict)
        }
        await XCTAssertThrowsErrorAsync(
            try await store.createTranscriptEvidence(
                transcriptionArtifactId: transcriptionArtifactId,
                segmentIndexes: [1]
            )
        ) { error in
            XCTAssertEqual(error as? StoreError, .transcriptCorrectionConflict)
        }

        try await store.resolveTranscriptCorrectionConflict(
            transcriptionArtifactId: transcriptionArtifactId,
            segmentIndex: 1,
            keeping: deviceACorrectionId,
            at: Date(timeIntervalSince1970: 1_800_000_060)
        )
        reviewed = try await store.reviewedTranscriptSegments(
            transcriptionArtifactId: transcriptionArtifactId
        )
        XCTAssertEqual(reviewed[1].text, "Closed subsets from device A.")
        var resolvedHistory = try await store.transcriptCorrections(
            transcriptionArtifactId: transcriptionArtifactId
        )
        XCTAssertEqual(
            resolvedHistory.first(where: { $0.id == deviceACorrectionId })?.payload.state,
            .active
        )
        XCTAssertEqual(
            resolvedHistory.first(where: { $0.id == deviceBCorrectionId })?.payload.state,
            .superseded
        )

        let deviceCCorrectionId = try await store.save(
            payload: TranscriptCorrectionPayload(
                sourceId: sourceId,
                sourceVersionId: sourceVersionId,
                transcriptionArtifactId: transcriptionArtifactId,
                segment: segments[1],
                correctedText: "Closed subsets from device C.",
                now: Date(timeIntervalSince1970: 1_800_000_061)
            ),
            parentId: sourceId,
            relationIds: [sourceId, sourceVersionId, transcriptionArtifactId]
        )
        try await store.resolveTranscriptCorrectionConflict(
            transcriptionArtifactId: transcriptionArtifactId,
            segmentIndex: 1,
            keeping: nil,
            at: Date(timeIntervalSince1970: 1_800_000_070)
        )
        reviewed = try await store.reviewedTranscriptSegments(
            transcriptionArtifactId: transcriptionArtifactId
        )
        XCTAssertEqual(reviewed[1].text, segments[1].text)
        resolvedHistory = try await store.transcriptCorrections(
            transcriptionArtifactId: transcriptionArtifactId
        )
        XCTAssertEqual(
            resolvedHistory.first(where: { $0.id == deviceACorrectionId })?.payload.state,
            .retracted
        )
        XCTAssertEqual(
            resolvedHistory.first(where: { $0.id == deviceCCorrectionId })?.payload.state,
            .retracted
        )
        let stillFrozenEvidence = try await store.payload(EvidencePayload.self, id: evidenceId)
        XCTAssertEqual(stillFrozenEvidence.payload.excerpt, "Open sets. Closed subsets in the space.")
        XCTAssertEqual(stillFrozenEvidence.payload.resolvedTranscriptCorrectionIds, [secondCorrectionId])
        await XCTAssertThrowsErrorAsync(
            try await coordinator.submitMediaTranscription(
                sourceId: sourceId,
                disclosureAcknowledged: false
            )
        ) { error in
            XCTAssertEqual(error as? AIJobCoordinatorError, .disclosureNotAcknowledged)
        }
    }

    func testFlashcardReviewsAreAppendOnlyAndSchedulerIsDeterministic() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try SQLCipherDatabase(
            url: directory.appendingPathComponent("cards.sqlite"),
            key: Data(repeating: 43, count: 32)
        )
        let store = EpistoriaStore(database: database)
        let topicId = try await store.createTopic(name: "Factorization")
        let cardId = try await store.createFlashcard(
            topicId: topicId,
            prompt: "Factor x² - 9",
            answer: "(x - 3)(x + 3)"
        )
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let previous = FlashcardScheduleState(dueAt: date)
        let expected = FlashcardScheduler.next(after: previous, rating: .good, reviewedAt: date)
        _ = try await store.reviewFlashcard(cardId: cardId, rating: .good, previousState: previous, at: date)
        _ = try await store.reviewFlashcard(cardId: cardId, rating: .hard, previousState: expected, at: date)
        let reviews = try await store.list(FlashcardReviewPayload.self, parentId: cardId)
        XCTAssertEqual(reviews.count, 2)
        XCTAssertTrue(reviews.contains { $0.payload.resultingState == expected })
        XCTAssertEqual(FlashcardScheduler.next(after: previous, rating: .good, reviewedAt: date), expected)
    }

    func testPracticeAttemptKeepsFrozenQuestionAfterTestChanges() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try SQLCipherDatabase(
            url: directory.appendingPathComponent("tests.sqlite"),
            key: Data(repeating: 44, count: 32)
        )
        let store = EpistoriaStore(database: database)
        let topicId = try await store.createTopic(name: "Factoring")
        let objective = TestObjective(title: "Difference of squares", dimensions: TestCoverageDimension.allCases)
        let testId = try await store.createPracticeTest(
            topicId: topicId,
            title: "Coverage test",
            objectives: [objective],
            questions: [ManualTestQuestion(
                objectiveIds: [objective.id],
                prompt: "Factor x² - 16",
                correctAnswer: "(x - 4)(x + 4)"
            )]
        )
        let attemptId = try await store.beginTestAttempt(testId: testId)
        let loadedQuestions = try await store.list(TestQuestionPayload.self, parentId: testId)
        var question = try XCTUnwrap(loadedQuestions.first)
        question.payload.prompt = "Changed after attempt"
        question.payload.updatedAt = .now
        _ = try await store.save(id: question.id, payload: question.payload, parentId: testId, relationIds: [testId, topicId])
        let attempt = try await store.payload(TestAttemptPayload.self, id: attemptId)
        XCTAssertEqual(attempt.payload.frozenQuestions.first?.prompt, "Factor x² - 16")
        XCTAssertEqual(attempt.payload.frozenQuestions.first?.correctAnswer, "(x - 4)(x + 4)")
    }

    func testOnlyOneSessionCanBeActivelyTimed() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try SQLCipherDatabase(
            url: directory.appendingPathComponent("session-state.sqlite"),
            key: Data(repeating: 45, count: 32)
        )
        let store = EpistoriaStore(database: database)
        let topicId = try await store.createTopic(name: "Topology")
        let activeId = try await store.startSession(
            title: "Open sets",
            courseId: topicId,
            requireTopic: true
        )
        let plannedId = try await store.startSession(
            title: "Compactness",
            courseId: topicId,
            state: .planned,
            requireTopic: true
        )
        await XCTAssertThrowsErrorAsync(
            try await store.setSessionState(id: plannedId, state: .active)
        ) { error in
            XCTAssertEqual(error as? StoreError, .activeSessionExists)
        }
        try await store.setSessionState(id: activeId, state: .paused)
        try await store.setSessionState(id: plannedId, state: .active)
        let planned = try await store.payload(StudySessionPayload.self, id: plannedId)
        XCTAssertEqual(planned.payload.state, .active)
    }

    func testSourceRefreshKeepsOldVersionAndEvidenceLocator() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try SQLCipherDatabase(
            url: directory.appendingPathComponent("source-refresh.sqlite"),
            key: Data(repeating: 46, count: 32)
        )
        let store = EpistoriaStore(database: database)
        func asset(_ character: Character, filename: String) async throws -> UUID {
            try await store.save(payload: AssetPayload(
                mimeType: "application/pdf",
                plaintextByteSize: 12,
                encryptedByteSize: 64,
                dedupeTag: String(repeating: character, count: 64),
                assetKey: String(repeating: "A", count: 43),
                originalFilename: filename
            ))
        }
        let firstAssetId = try await asset("a", filename: "first.pdf")
        let sourceId = try await store.createSource(
            type: .pdf,
            title: "Topology",
            originalAssetId: firstAssetId
        )
        let firstSource = try await store.payload(SourcePayload.self, id: sourceId)
        let firstVersionId = try XCTUnwrap(firstSource.payload.currentVersionId)
        var annotation = AnnotationPayload(
            resourceId: sourceId,
            annotationType: .important,
            pageNumber: 3,
            comment: "A compact subset is closed in a Hausdorff space."
        )
        annotation.selectedText = "compact subsets are closed"
        let evidence = try await store.createAnnotationEvidence(
            annotation: annotation,
            sourceVersionId: firstVersionId
        )
        let secondAssetId = try await asset("b", filename: "second.pdf")
        let secondVersionId = try await store.refreshSource(
            id: sourceId,
            originalAssetId: secondAssetId
        )
        let versions = try await store.list(SourceVersionPayload.self, parentId: sourceId)
        let storedEvidence = try await store.payload(EvidencePayload.self, id: evidence.evidenceId)
        XCTAssertEqual(versions.count, 2)
        XCTAssertNotEqual(firstVersionId, secondVersionId)
        XCTAssertEqual(storedEvidence.payload.sourceVersionId, firstVersionId)
        XCTAssertEqual(storedEvidence.payload.locator.page, 3)
    }

    func testEvidenceIsReusedAcrossNotesConceptsCardsAndTestsWithBacklinks() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try SQLCipherDatabase(
            url: directory.appendingPathComponent("evidence-backlinks.sqlite"),
            key: Data(repeating: 66, count: 32)
        )
        let store = EpistoriaStore(database: database)
        let topicId = try await store.createTopic(name: "Topology")
        let sourceId = try await store.createSource(
            type: .pastedText,
            title: "Compactness notes",
            primaryTopicId: topicId
        )
        let source = try await store.payload(SourcePayload.self, id: sourceId)
        let versionId = try XCTUnwrap(source.payload.currentVersionId)
        let evidenceId = try await store.createEvidence(
            sourceId: sourceId,
            sourceVersionId: versionId,
            kind: .excerpt,
            locator: SourceLocator(kind: .plainText, startOffset: 0, endOffset: 31),
            excerpt: "Every compact subset is closed."
        )
        let noteId = try await store.createNote(title: "Separation axioms", courseId: topicId)
        let blockId = try await store.appendCanvasEvidence(
            noteId: noteId,
            evidenceId: evidenceId,
            placement: NoteCanvasPlacement(x: 24, y: 40, width: 360, height: 160)
        )
        let conceptId = try await store.createConcept(name: "Hausdorff space", topicIds: [topicId])
        let conceptRelationId = try await store.linkConcept(
            conceptId,
            toEvidence: evidenceId,
            relation: .supporting
        )
        let cardId = try await store.createFlashcard(
            topicId: topicId,
            prompt: "What does compactness imply in a Hausdorff space?",
            answer: "Compact subsets are closed.",
            evidenceIds: [evidenceId]
        )
        let objective = TestObjective(title: "Apply compactness", dimensions: [.integrated])
        let testId = try await store.createPracticeTest(
            topicId: topicId,
            title: "Compactness check",
            objectives: [objective],
            questions: [ManualTestQuestion(
                objectiveIds: [objective.id],
                prompt: "Explain why a compact subset is closed in a Hausdorff space.",
                correctAnswer: "Separate each exterior point from the compact set.",
                evidenceIds: [evidenceId]
            )]
        )

        let block = try await store.payload(NoteBlockPayload.self, id: blockId)
        let evidence = try await store.payload(EvidencePayload.self, id: evidenceId)
        let allEvidence = try await store.list(EvidencePayload.self)
        let backlinks = try await store.evidenceBacklinks(evidenceId: evidenceId)

        XCTAssertEqual(block.payload.schemaVersion, "note-block/v7")
        XCTAssertEqual(block.payload.evidenceId, evidenceId)
        XCTAssertEqual(evidence.payload.sourceVersionId, versionId)
        XCTAssertEqual(allEvidence.count, 1)
        XCTAssertEqual(Set(backlinks.map(\.kind)), [.note, .concept, .flashcard, .testQuestion])
        XCTAssertTrue(backlinks.contains { $0.id == blockId && $0.ownerId == noteId })
        XCTAssertTrue(backlinks.contains { $0.id == conceptRelationId && $0.ownerId == conceptId })
        XCTAssertTrue(backlinks.contains { $0.ownerId == cardId })
        XCTAssertTrue(backlinks.contains { $0.ownerId == testId })
    }

    func testAcceptingFlashcardDraftsCreatesDurableRecordsOnce() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try SQLCipherDatabase(
            url: directory.appendingPathComponent("learning-acceptance.sqlite"),
            key: Data(repeating: 47, count: 32)
        )
        let store = EpistoriaStore(database: database)
        let topicId = try await store.createTopic(name: "Algebra")
        let sourceId = UUID()
        let artifact = LearningGenerationArtifact(
            schemaVersion: "ai-artifact/learning-generation/v1",
            jobId: UUID(),
            jobType: .flashcardDrafts,
            topicId: topicId,
            includeConnectedKnowledge: false,
            generatedAt: .now,
            sourceIds: [sourceId],
            trace: ProviderTrace(
                provider: "deterministic-test",
                model: "fixture-v1",
                promptVersion: "learning-generation/v1"
            ),
            response: LearningGenerationResponse(
                schemaVersion: "learning-generation-response/v1",
                summary: "One card",
                items: [LearningDraftItem(
                    id: UUID(),
                    kind: "BASIC",
                    title: "Factor x² - 9",
                    body: "Difference of squares",
                    answer: "(x - 3)(x + 3)",
                    choices: [],
                    objectiveTitles: ["Difference of squares"],
                    citedSourceIds: [sourceId]
                )],
                coverageGaps: []
            )
        )
        let artifactId = try await store.save(
            payload: artifact,
            parentId: topicId,
            relationIds: [topicId, sourceId]
        )
        let first = try await store.acceptLearningArtifact(id: artifactId)
        let second = try await store.acceptLearningArtifact(id: artifactId)
        let cards = try await store.list(FlashcardPayload.self)
        let revisions = try await store.list(FlashcardRevisionPayload.self)
        let accepted = try await store.payload(LearningGenerationArtifact.self, id: artifactId)
        XCTAssertEqual(first.flashcards, 1)
        XCTAssertEqual(second.flashcards, 0)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(revisions.count, 1)
        XCTAssertEqual(revisions.first?.payload.generatorArtifactId, artifactId)
        XCTAssertEqual(accepted.payload.reviewState, .accepted)
    }

    func testLearningLifecycleEditsPreserveHistoryAndLegacyLists() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try SQLCipherDatabase(
            url: directory.appendingPathComponent("learning-lifecycle.sqlite"),
            key: Data(repeating: 48, count: 32)
        )
        let store = EpistoriaStore(database: database)
        let topicId = try await store.createTopic(name: "Algebra")

        let legacyListJSON = """
        {
          "schemaVersion":"collection/v1",
          "name":"Legacy list",
          "parentCollectionId":null,
          "createdAt":"2026-08-20T12:00:00.000Z",
          "updatedAt":"2026-08-20T12:00:00.000Z"
        }
        """
        let legacyList = try CanonicalJSON.decode(CollectionPayload.self, from: Data(legacyListJSON.utf8))
        XCTAssertNil(legacyList.archivedAt)
        let listId = UUID()
        _ = try await database.saveLocal(
            id: listId,
            entityType: .collection,
            content: Data(legacyListJSON.utf8),
            search: SearchDocument(title: "Legacy list", body: "")
        )
        try await store.updateList(id: listId, name: "Reference", parentListId: nil, archived: true)
        let archivedList = try await store.payload(CollectionPayload.self, id: listId)
        let listBackup = try await database.migrationBackup(
            entityId: listId,
            migrationName: "collection-to-list/v2"
        )
        XCTAssertEqual(archivedList.payload.name, "Reference")
        XCTAssertEqual(archivedList.payload.schemaVersion, "collection/v2")
        XCTAssertNotNil(archivedList.payload.archivedAt)
        XCTAssertEqual(listBackup, Data(legacyListJSON.utf8))

        let deckId = try await store.createFlashcardDeck(topicId: topicId, name: "Core ideas")
        let cardId = try await store.createFlashcard(
            topicId: topicId,
            deckId: deckId,
            prompt: "Original prompt",
            answer: "Original answer"
        )
        let firstCard = try await store.payload(FlashcardPayload.self, id: cardId)
        let firstRevisionId = firstCard.payload.currentRevisionId
        _ = try await store.reviewFlashcard(
            cardId: cardId,
            rating: .good,
            previousState: FlashcardScheduleState()
        )
        let secondRevisionId = try await store.reviseFlashcard(
            id: cardId,
            kind: .explanation,
            prompt: "Revised prompt",
            answer: "Revised answer",
            deckId: deckId,
            evidenceIds: []
        )
        try await store.setFlashcardLifecycle(id: cardId, suspended: true)
        let revisedCard = try await store.payload(FlashcardPayload.self, id: cardId)
        let reviews = try await store.list(FlashcardReviewPayload.self, parentId: cardId)
        XCTAssertNotEqual(firstRevisionId, secondRevisionId)
        XCTAssertEqual(revisedCard.payload.currentRevisionId, secondRevisionId)
        XCTAssertNotNil(revisedCard.payload.suspendedAt)
        XCTAssertEqual(reviews.first?.payload.cardRevisionId, firstRevisionId)

        let goalId = try await store.save(
            payload: StudyGoalPayload(topicId: topicId, title: "Learn factoring"),
            parentId: topicId,
            relationIds: [topicId]
        )
        try await store.updateStudyGoal(
            id: goalId,
            title: "Master factoring",
            details: "Complete mixed practice",
            targetDate: nil,
            priority: 3,
            state: .completed
        )
        let goal = try await store.payload(StudyGoalPayload.self, id: goalId)
        XCTAssertEqual(goal.payload.state, .completed)
        XCTAssertEqual(goal.payload.priority, 3)

        let planObjective = LearningPlanObjective(title: "Mixed practice", estimatedMinutes: 90)
        let planTarget = Date.now.addingTimeInterval(7 * 86_400)
        try await store.updateStudyGoal(
            id: goalId,
            title: "Master factoring",
            details: "Complete mixed practice",
            targetDate: planTarget,
            priority: 3,
            state: .active,
            learningPlan: LearningPlanConfiguration(
                minutesPerStudyDay: 25,
                studyWeekdays: [2, 3, 4, 5, 6],
                objectives: [planObjective]
            )
        )
        let plannedGoal = try await store.payload(StudyGoalPayload.self, id: goalId)
        XCTAssertEqual(plannedGoal.payload.schemaVersion, "study-goal/v2")
        XCTAssertEqual(plannedGoal.payload.learningPlan?.minutesPerStudyDay, 25)
        XCTAssertEqual(plannedGoal.payload.learningPlan?.studyWeekdays, [2, 3, 4, 5, 6])
        XCTAssertEqual(plannedGoal.payload.learningPlan?.objectives.first?.title, "Mixed practice")
        await XCTAssertThrowsErrorAsync(try await store.updateStudyGoal(
            id: goalId,
            title: "Master factoring",
            details: nil,
            targetDate: nil,
            priority: 3,
            state: .active,
            learningPlan: LearningPlanConfiguration(objectives: [planObjective])
        )) { error in
            XCTAssertEqual(error as? StoreError, .invalidLearningPlan)
        }

        let questionId = try await store.save(
            payload: UnresolvedQuestionPayload(topicId: topicId, question: "Why does grouping work?"),
            parentId: topicId,
            relationIds: [topicId]
        )
        try await store.updateUnresolvedQuestion(
            id: questionId,
            question: "When does grouping work?",
            resolvedAnswer: "When a shared binomial factor appears.",
            resolved: true
        )
        let question = try await store.payload(UnresolvedQuestionPayload.self, id: questionId)
        XCTAssertNotNil(question.payload.resolvedAt)
        XCTAssertEqual(question.payload.resolvedAnswer, "When a shared binomial factor appears.")

        let sourceId = try await store.createSource(type: .pastedText, title: "Draft", primaryTopicId: topicId)
        try await store.updateSource(
            id: sourceId,
            title: "Factoring notes",
            primaryTopicId: topicId,
            relatedTopicIds: [],
            listIds: [listId],
            archived: true
        )
        let archivedSource = try await store.payload(SourcePayload.self, id: sourceId)
        XCTAssertNotNil(archivedSource.payload.archivedAt)

        let conceptId = try await store.createConcept(name: "Grouping", topicIds: [topicId])
        try await store.updateConcept(
            id: conceptId,
            name: "Factor by grouping",
            description: "Regroup terms to expose a common binomial.",
            aliases: ["grouping"],
            topicIds: [topicId],
            state: .archived
        )
        let archivedConcept = try await store.payload(ConceptPayload.self, id: conceptId)
        XCTAssertEqual(archivedConcept.payload.state, .archived)

        let objective = TestObjective(title: "Grouping", dimensions: [.conceptual])
        let testId = try await store.createPracticeTest(
            topicId: topicId,
            title: "Grouping check",
            objectives: [objective],
            questions: [ManualTestQuestion(
                objectiveIds: [objective.id],
                prompt: "Factor by grouping",
                correctAnswer: "A correct factorization"
            )]
        )
        try await store.updatePracticeTest(id: testId, title: "Grouping review", state: .archived)
        let test = try await store.payload(PracticeTestPayload.self, id: testId)
        XCTAssertEqual(test.payload.title, "Grouping review")
        XCTAssertEqual(test.payload.state, .archived)
    }

    func testReviewedLearningDraftAcceptsOnlySelectedEditedItems() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try SQLCipherDatabase(
            url: directory.appendingPathComponent("draft-review.sqlite"),
            key: Data(repeating: 49, count: 32)
        )
        let store = EpistoriaStore(database: database)
        let topicId = try await store.createTopic(name: "Algebra")
        let sourceId = UUID()

        func artifact(
            type: LearningAIJobType,
            summary: String,
            items: [LearningDraftItem]
        ) -> LearningGenerationArtifact {
            LearningGenerationArtifact(
                jobId: UUID(),
                jobType: type,
                topicId: topicId,
                includeConnectedKnowledge: false,
                generatedAt: .now,
                sourceIds: [sourceId],
                trace: ProviderTrace(
                    provider: "deterministic-test",
                    model: "fixture-v1",
                    promptVersion: "learning-generation/v1"
                ),
                response: LearningGenerationResponse(summary: summary, items: items)
            )
        }

        let keptCard = LearningDraftItem(
            kind: "BASIC",
            title: "Original card",
            body: "Explanation",
            answer: "Original answer",
            citedSourceIds: [sourceId]
        )
        let excludedCard = LearningDraftItem(
            kind: "BASIC",
            title: "Excluded card",
            body: "Unused",
            answer: "Excluded answer",
            citedSourceIds: [sourceId]
        )
        let cardArtifactId = try await store.save(
            payload: artifact(type: .flashcardDrafts, summary: "Two cards", items: [keptCard, excludedCard]),
            parentId: topicId,
            relationIds: [topicId, sourceId]
        )
        var editedCard = keptCard
        editedCard.title = "Reviewed card"
        editedCard.answer = "Reviewed answer"
        var unknownCard = editedCard
        unknownCard.id = UUID()
        await XCTAssertThrowsErrorAsync(
            try await store.saveLearningArtifactDraftReview(
                id: cardArtifactId,
                summary: "Invalid selection",
                selectedItems: [unknownCard]
            )
        ) { error in
            XCTAssertEqual(error as? StoreError, .invalidDraftReview)
        }
        try await store.saveLearningArtifactDraftReview(
            id: cardArtifactId,
            summary: "One selected card",
            selectedItems: [editedCard]
        )
        let cardResult = try await store.acceptLearningArtifact(id: cardArtifactId)
        let cards = try await store.list(FlashcardPayload.self)
        let revisions = try await store.list(FlashcardRevisionPayload.self)
        let savedCardArtifact = try await store.payload(LearningGenerationArtifact.self, id: cardArtifactId)
        XCTAssertEqual(cardResult.flashcards, 1)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(revisions.first?.payload.prompt, "Reviewed card")
        XCTAssertEqual(revisions.first?.payload.answer, "Reviewed answer")
        XCTAssertEqual(savedCardArtifact.payload.response.items.count, 2)
        XCTAssertEqual(savedCardArtifact.payload.editedResponse?.items.map(\.id), [keptCard.id])

        let keptConcept = LearningDraftItem(
            kind: "CONCEPT",
            title: "Reviewed Concept",
            body: "Accepted definition",
            citedSourceIds: [sourceId]
        )
        let conceptArtifactId = try await store.save(
            payload: artifact(
                type: .conceptSuggestions,
                summary: "Concepts",
                items: [keptConcept, LearningDraftItem(
                    kind: "CONCEPT",
                    title: "Excluded Concept",
                    body: "Unused",
                    citedSourceIds: [sourceId]
                )]
            ),
            parentId: topicId,
            relationIds: [topicId, sourceId]
        )
        try await store.saveLearningArtifactDraftReview(
            id: conceptArtifactId,
            summary: "One Concept",
            selectedItems: [keptConcept]
        )
        let conceptResult = try await store.acceptLearningArtifact(id: conceptArtifactId)
        let concepts = try await store.list(ConceptPayload.self)
        XCTAssertEqual(conceptResult.concepts, 1)
        XCTAssertEqual(concepts.map(\.payload.name), ["Reviewed Concept"])

        var keptQuestion = LearningDraftItem(
            kind: "EXPLANATION",
            title: "Original question",
            body: "Explain each step.",
            answer: "Original key",
            objectiveTitles: ["Difference of squares"],
            citedSourceIds: [sourceId]
        )
        let testArtifactId = try await store.save(
            payload: artifact(
                type: .testGeneration,
                summary: "Generated test",
                items: [keptQuestion, LearningDraftItem(
                    kind: "SHORT_ANSWER",
                    title: "Excluded question",
                    body: "Unused rubric",
                    answer: "Unused key",
                    citedSourceIds: [sourceId]
                )]
            ),
            parentId: topicId,
            relationIds: [topicId, sourceId]
        )
        keptQuestion.title = "Reviewed question"
        keptQuestion.answer = "Reviewed key"
        try await store.saveLearningArtifactDraftReview(
            id: testArtifactId,
            summary: "Reviewed test",
            selectedItems: [keptQuestion]
        )
        let testResult = try await store.acceptLearningArtifact(id: testArtifactId)
        let tests = try await store.list(PracticeTestPayload.self)
        let questions = try await store.list(TestQuestionPayload.self)
        XCTAssertEqual(testResult.tests, 1)
        XCTAssertEqual(tests.count, 1)
        XCTAssertEqual(tests.first?.payload.title, "Reviewed test")
        XCTAssertEqual(questions.map(\.payload.prompt), ["Reviewed question"])
        XCTAssertEqual(questions.map(\.payload.correctAnswer), ["Reviewed key"])
    }

    func testConceptLinksAreDurableIdempotentAndAIReviewable() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try SQLCipherDatabase(
            url: directory.appendingPathComponent("concept-links.sqlite"),
            key: Data(repeating: 58, count: 32)
        )
        let store = EpistoriaStore(database: database)
        let topicId = try await store.createTopic(name: "Algebra")
        let factorizationId = try await store.createConcept(
            name: "Factorization",
            topicIds: [topicId]
        )
        let rootsId = try await store.createConcept(name: "Roots", topicIds: [topicId])
        let sourceId = UUID()
        let versionId = UUID()
        let evidenceId = try await store.save(
            payload: EvidencePayload(
                sourceId: sourceId,
                sourceVersionId: versionId,
                kind: .excerpt,
                locator: SourceLocator(kind: .plainText, startOffset: 0, endOffset: 30),
                excerpt: "Factoring exposes polynomial roots."
            ),
            parentId: sourceId,
            relationIds: [sourceId, versionId]
        )

        let firstLinkId = try await store.createConceptLink(
            sourceConceptId: factorizationId,
            targetConceptId: rootsId,
            relation: .applies,
            rationale: "Factoring can reveal roots.",
            evidenceIds: [evidenceId]
        )
        let retriedLinkId = try await store.createConceptLink(
            sourceConceptId: factorizationId,
            targetConceptId: rootsId,
            relation: .applies,
            rationale: "A duplicate retry",
            evidenceIds: [evidenceId]
        )
        XCTAssertEqual(firstLinkId, retriedLinkId)
        try await store.updateConceptLink(
            id: firstLinkId,
            relation: .applies,
            rationale: "Reviewed manual rationale.",
            evidenceIds: [evidenceId]
        )
        let updatedManualLink = try await store.payload(ConceptLinkPayload.self, id: firstLinkId)
        XCTAssertEqual(updatedManualLink.payload.rationale, "Reviewed manual rationale.")
        let linksAfterManualUpdate = try await store.conceptLinks(conceptId: rootsId)
        XCTAssertEqual(linksAfterManualUpdate.count, 1)
        let removableLinkId = try await store.createConceptLink(
            sourceConceptId: rootsId,
            targetConceptId: factorizationId,
            relation: .related
        )
        try await store.removeConceptLink(id: removableLinkId)
        let conceptsAfterRemoval = try await store.list(ConceptPayload.self)
        let linksAfterRemoval = try await store.conceptLinks(conceptId: rootsId)
        XCTAssertEqual(conceptsAfterRemoval.count, 2)
        XCTAssertEqual(linksAfterRemoval.count, 1)
        await XCTAssertThrowsErrorAsync(
            try await store.createConceptLink(
                sourceConceptId: rootsId,
                targetConceptId: rootsId,
                relation: .related
            )
        ) { error in
            XCTAssertEqual(error as? StoreError, .invalidConceptLink)
        }

        let proposed = LearningDraftItem(
            kind: "CONCEPT",
            title: "Polynomial structure",
            body: "How terms and factors determine polynomial behavior.",
            citedSourceIds: [evidenceId]
        )
        let proposedLink = ConceptLinkDraft(
            sourceConceptId: factorizationId,
            sourceConceptName: "Factorization",
            targetConceptName: "Polynomial structure",
            relation: .partOf,
            rationale: "The cited excerpt treats factoring as part of polynomial structure.",
            citedSourceIds: [evidenceId]
        )
        let artifact = LearningGenerationArtifact(
            jobId: UUID(),
            jobType: .conceptSuggestions,
            topicId: topicId,
            includeConnectedKnowledge: false,
            generatedAt: .now,
            sourceIds: [evidenceId],
            trace: ProviderTrace(
                provider: "deterministic-test",
                model: "fixture-v1",
                promptVersion: "learning-generation/v2"
            ),
            response: LearningGenerationResponse(
                summary: "Concepts and connections",
                items: [proposed],
                conceptLinks: [proposedLink]
            ),
            knownConceptIds: [factorizationId]
        )
        let artifactId = try await store.save(
            payload: artifact,
            parentId: topicId,
            relationIds: [topicId, evidenceId, factorizationId]
        )
        try await store.saveLearningArtifactDraftReview(
            id: artifactId,
            summary: artifact.response.summary,
            selectedItems: [proposed],
            selectedConceptLinks: [proposedLink]
        )
        let accepted = try await store.acceptLearningArtifact(id: artifactId)
        let allLinks = try await store.list(ConceptLinkPayload.self)
        let reviewedLink = try XCTUnwrap(allLinks.first { $0.payload.provenance == .reviewedAI })
        XCTAssertEqual(accepted.concepts, 1)
        XCTAssertEqual(accepted.conceptLinks, 1)
        XCTAssertEqual(allLinks.count, 2)
        XCTAssertEqual(reviewedLink.payload.generatorArtifactId, artifactId)
        XCTAssertEqual(reviewedLink.payload.evidenceIds, [evidenceId])
    }

    func testAcceptedGeneratedTestPreservesPlanAndReportsCoverageGaps() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try SQLCipherDatabase(
            url: directory.appendingPathComponent("planned-test.sqlite"),
            key: Data(repeating: 51, count: 32)
        )
        let store = EpistoriaStore(database: database)
        let topicId = try await store.createTopic(name: "Factoring")
        let sourceId = UUID()
        let plan = TestGenerationPlan(
            mode: .comprehensive,
            questionCount: 3,
            timeLimitMinutes: 15,
            coverageDimensions: [.prerequisite, .conceptual, .integrated],
            objectiveTitles: ["Common factors", "Difference of squares", "Factoring by grouping"]
        )
        let artifact = LearningGenerationArtifact(
            jobId: UUID(),
            jobType: .testGeneration,
            topicId: topicId,
            includeConnectedKnowledge: false,
            generatedAt: .now,
            sourceIds: [sourceId],
            trace: ProviderTrace(
                provider: "deterministic-test",
                model: "fixture-v1",
                promptVersion: "learning-generation/v2"
            ),
            response: LearningGenerationResponse(
                summary: "Factoring coverage test",
                items: [LearningDraftItem(
                    kind: "MULTI_STEP_APPLICATION",
                    title: "Choose and apply a factoring method",
                    body: "Award credit for method selection, procedure, and verification.",
                    answer: "A supported worked solution",
                    objectiveTitles: ["common factors"],
                    citedSourceIds: [sourceId]
                )],
                coverageGaps: ["The available evidence does not support an integrated grouping question."]
            ),
            testPlan: plan
        )
        let artifactId = try await store.save(
            payload: artifact,
            parentId: topicId,
            relationIds: [topicId, sourceId]
        )

        let result = try await store.acceptLearningArtifact(id: artifactId)
        let blueprints = try await store.list(TestBlueprintPayload.self)
        let questions = try await store.list(TestQuestionPayload.self)

        XCTAssertEqual(result.tests, 1)
        XCTAssertEqual(blueprints.count, 1)
        XCTAssertEqual(blueprints[0].payload.schemaVersion, "test-blueprint/v2")
        XCTAssertEqual(blueprints[0].payload.mode, .comprehensive)
        XCTAssertEqual(blueprints[0].payload.requestedQuestionCount, 3)
        XCTAssertEqual(blueprints[0].payload.timeLimitMinutes, 15)
        XCTAssertEqual(blueprints[0].payload.objectives.map(\.title), plan.objectiveTitles)
        XCTAssertEqual(blueprints[0].payload.objectives[0].dimensions, plan.coverageDimensions)
        XCTAssertEqual(blueprints[0].payload.uncoveredObjectives.count, 2)
        XCTAssertEqual(blueprints[0].payload.coverageNotes, [
            "Generated 1 of 3 requested questions.",
            "The available evidence does not support an integrated grouping question.",
        ])
        XCTAssertEqual(questions.count, 1)
        XCTAssertEqual(questions[0].payload.objectiveIds, [blueprints[0].payload.objectives[0].id])
    }

    func testRecommendationResponsesAreAppendOnlySnapshotsWithStableLocalIdentity() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try SQLCipherDatabase(
            url: directory.appendingPathComponent("recommendation-history.sqlite"),
            key: Data(repeating: 53, count: 32)
        )
        let store = EpistoriaStore(database: database)
        let topicId = try await store.createTopic(name: "Topology")
        let firstDate = Date(timeIntervalSince1970: 1_800_000_000)
        let secondDate = firstDate.addingTimeInterval(60)
        let first = LocalStudyRecommendation(
            topicId: topicId,
            kind: .dueCards,
            title: "Review 1 due card",
            explanation: "One review is due.",
            score: 81
        )
        let changedCount = LocalStudyRecommendation(
            topicId: topicId,
            kind: .dueCards,
            title: "Review 3 due cards",
            explanation: "Three reviews are due.",
            score: 83
        )

        _ = try await store.respondToRecommendation(first, action: .pinned, at: firstDate)
        _ = try await store.respondToRecommendation(changedCount, action: .accepted, at: secondDate)

        let stored = try await store.list(StudyRecommendationPayload.self)
        let responses = try await store.list(RecommendationResponsePayload.self)
            .sorted { $0.payload.createdAt < $1.payload.createdAt }
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(responses.count, 2)
        XCTAssertEqual(responses.map(\.payload.action), [.pinned, .accepted])
        XCTAssertEqual(responses.map(\.payload.recommendationTitle), [first.title, changedCount.title])
        XCTAssertEqual(responses.map(\.payload.recommendationKind), [.dueCards, .dueCards])
        XCTAssertEqual(responses.map(\.payload.topicId), [topicId, topicId])
        XCTAssertEqual(responses.map(\.payload.targetEntityIds), [[], []])

        let topics = try await store.topics()
        let localReplay = StudyNextEngine.rank(
            topics: topics,
            goals: [],
            unresolvedQuestions: [],
            sessions: [],
            tests: [],
            attempts: [],
            dueCardCounts: [:],
            storedRecommendations: stored,
            now: secondDate
        )
        XCTAssertTrue(localReplay.isEmpty)

        var external = stored[0]
        external.payload.generatedLocally = false
        external.payload.targetEntityIds = [UUID()]
        let externalReplay = StudyNextEngine.rank(
            topics: topics,
            goals: [],
            unresolvedQuestions: [],
            sessions: [],
            tests: [],
            attempts: [],
            dueCardCounts: [:],
            storedRecommendations: [external],
            now: secondDate
        )
        XCTAssertEqual(externalReplay.count, 1)
        XCTAssertEqual(externalReplay[0].targetId, external.payload.targetEntityIds[0])
    }

    func testReviewedFreeResponseFeedbackPreservesAnswerAndCalculatedResult() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try SQLCipherDatabase(
            url: directory.appendingPathComponent("free-response-feedback.sqlite"),
            key: Data(repeating: 54, count: 32)
        )
        let store = EpistoriaStore(database: database)
        let topicId = try await store.createTopic(name: "Algebra")
        let objective = TestObjective(title: "Difference of squares", dimensions: [.conceptual])
        let testId = try await store.createPracticeTest(
            topicId: topicId,
            title: "Explanation check",
            objectives: [objective],
            questions: [ManualTestQuestion(
                objectiveIds: [objective.id],
                kind: .explanation,
                prompt: "Explain why the middle terms cancel.",
                correctAnswer: "The factors are conjugates.",
                rubric: "Identify conjugates and explain cancellation."
            )]
        )
        let attemptId = try await store.beginTestAttempt(testId: testId)
        var attempt = try await store.payload(TestAttemptPayload.self, id: attemptId)
        let questionId = try XCTUnwrap(attempt.payload.frozenQuestions.first?.questionId)
        let legacyResponse = try CanonicalJSON.decode(
            TestResponsePayload.self,
            from: Data("""
            {
              "schemaVersion":"test-response/v1",
              "attemptId":"\(attemptId.uuidString)",
              "questionId":"\(questionId.uuidString)",
              "response":"Legacy answer",
              "confidence":3,
              "elapsedMilliseconds":10,
              "isSkipped":false,
              "isCorrect":false,
              "feedback":null,
              "score":null,
              "createdAt":"2026-08-22T00:00:00.000Z",
              "updatedAt":"2026-08-22T00:00:00.000Z"
            }
            """.utf8)
        )
        XCTAssertEqual(legacyResponse.schemaVersion, "test-response/v1")
        XCTAssertNil(legacyResponse.feedbackArtifactId)
        XCTAssertNil(legacyResponse.scoreOverride)

        var savedResponse = TestResponsePayload(attemptId: attemptId, questionId: questionId)
        savedResponse.response = "The positive and negative middle terms add to zero."
        savedResponse.confidence = 4
        savedResponse.isCorrect = false
        let responseId = try await store.save(
            payload: savedResponse,
            parentId: attemptId,
            relationIds: [attemptId, questionId]
        )
        attempt.payload.state = .scored
        attempt.payload.score = 0
        attempt.payload.submittedAt = .now
        _ = try await store.save(
            id: attemptId,
            payload: attempt.payload,
            parentId: testId,
            relationIds: [testId, topicId, attempt.payload.scopeSnapshotId]
        )

        let generated = FreeResponseFeedbackResponse(
            feedback: "The cancellation claim is relevant but does not name conjugates.",
            strengths: ["Identifies cancellation."],
            improvements: ["Name the conjugate factors."],
            proposedScore: 0.5,
            uncertainty: "Low uncertainty because the frozen rubric is explicit.",
            citedSourceIds: [questionId]
        )
        let artifact = FreeResponseFeedbackArtifact(
            jobId: UUID(),
            attemptId: attemptId,
            responseId: responseId,
            questionId: questionId,
            topicId: topicId,
            generatedAt: .now,
            sourceIds: [questionId],
            trace: ProviderTrace(
                provider: "deterministic-test",
                model: "fixture-v1",
                promptVersion: "free-response-feedback/v1"
            ),
            response: generated
        )
        let artifactId = try await store.save(
            payload: artifact,
            parentId: attemptId,
            relationIds: [attemptId, responseId, questionId, topicId]
        )
        let reviewed = FreeResponseFeedbackResponse(
            feedback: "The answer explains cancellation and should also name the conjugate factors.",
            strengths: ["Explains why the middle terms sum to zero."],
            improvements: ["State that the factors are conjugates."],
            proposedScore: 0.75,
            uncertainty: "Low uncertainty based on the frozen rubric.",
            citedSourceIds: [questionId]
        )
        try await store.saveFreeResponseFeedbackDraftReview(
            id: artifactId,
            response: reviewed
        )
        try await store.reviewFreeResponseFeedbackArtifact(id: artifactId, state: .accepted)
        try await store.reviewFreeResponseFeedbackArtifact(id: artifactId, state: .accepted)

        var storedResponse = try await store.payload(TestResponsePayload.self, id: responseId)
        let storedArtifact = try await store.payload(FreeResponseFeedbackArtifact.self, id: artifactId)
        let storedAttempt = try await store.payload(TestAttemptPayload.self, id: attemptId)
        XCTAssertEqual(
            storedResponse.payload.response,
            "The positive and negative middle terms add to zero."
        )
        XCTAssertEqual(storedResponse.payload.isCorrect, false)
        XCTAssertEqual(storedResponse.payload.feedback, reviewed.feedback)
        XCTAssertEqual(storedResponse.payload.score, 0.75)
        XCTAssertEqual(storedResponse.payload.feedbackStrengths, reviewed.strengths)
        XCTAssertEqual(storedResponse.payload.feedbackImprovements, reviewed.improvements)
        XCTAssertEqual(storedResponse.payload.feedbackCitedSourceIds, [questionId])
        XCTAssertEqual(storedResponse.payload.feedbackArtifactId, artifactId)
        XCTAssertEqual(storedResponse.payload.schemaVersion, "test-response/v2")
        XCTAssertEqual(storedArtifact.payload.response, generated)
        XCTAssertEqual(storedArtifact.payload.editedResponse, reviewed)
        XCTAssertEqual(storedArtifact.payload.reviewState, .accepted)
        XCTAssertEqual(storedAttempt.payload.score, 0)

        try await store.setTestResponseScoreOverride(
            id: responseId,
            score: 0.9,
            reason: "Manual review awards method credit."
        )
        storedResponse = try await store.payload(TestResponsePayload.self, id: responseId)
        XCTAssertEqual(storedResponse.payload.score, 0.75)
        XCTAssertEqual(storedResponse.payload.scoreOverride, 0.9)
        XCTAssertEqual(
            storedResponse.payload.scoreOverrideReason,
            "Manual review awards method credit."
        )
    }

    func testAutomationGrantLifecycleAndJobIdentityAreDurableAndDeterministic() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try SQLCipherDatabase(
            url: directory.appendingPathComponent("automation-grants.sqlite"),
            key: Data(repeating: 55, count: 32)
        )
        let store = EpistoriaStore(database: database)
        let topicId = try await store.createTopic(name: "Topology")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let grantId = try await store.createAutomationGrant(
            topicIds: [topicId, topicId],
            jobTypes: [.weeklyReview, .weeklyReview],
            minimumIntervalHours: 24,
            expiresAt: now.addingTimeInterval(30 * 86_400),
            spendingLimitMinorUnits: 500,
            at: now
        )
        var grant = try await store.payload(AutomationGrantPayload.self, id: grantId)
        XCTAssertEqual(grant.payload.schemaVersion, "automation-grant/v3")
        XCTAssertEqual(grant.payload.topicIds, [topicId])
        XCTAssertEqual(grant.payload.jobTypes, [.weeklyReview])
        XCTAssertTrue(grant.payload.isActive(at: now))

        let scope = "\(topicId.uuidString.lowercased()):WEEKLY_REVIEW"
        let fingerprint = String(repeating: "a", count: 64)
        let firstJob = AIJobCoordinator.automaticJobId(
            grantId: grantId,
            scopeKey: scope,
            fingerprint: fingerprint
        )
        let repeatedJob = AIJobCoordinator.automaticJobId(
            grantId: grantId,
            scopeKey: scope,
            fingerprint: fingerprint
        )
        let changedJob = AIJobCoordinator.automaticJobId(
            grantId: grantId,
            scopeKey: scope,
            fingerprint: String(repeating: "b", count: 64)
        )
        XCTAssertEqual(firstJob, repeatedJob)
        XCTAssertNotEqual(firstJob, changedJob)

        try await store.recordAutomationQueue(
            grantId: grantId,
            scopeKey: scope,
            fingerprint: fingerprint,
            jobId: firstJob,
            estimatedSpentMinorUnits: 0,
            at: now
        )
        _ = try await store.setAutomationGrantPaused(
            id: grantId,
            paused: true,
            at: now.addingTimeInterval(60)
        )
        grant = try await store.payload(AutomationGrantPayload.self, id: grantId)
        XCTAssertEqual(grant.payload.queuedJobIds, [firstJob])
        XCTAssertEqual(grant.payload.lastInputFingerprintByScope?[scope], fingerprint)
        XCTAssertFalse(grant.payload.isActive(at: now.addingTimeInterval(60)))

        _ = try await store.setAutomationGrantPaused(
            id: grantId,
            paused: false,
            at: now.addingTimeInterval(120)
        )
        grant = try await store.payload(AutomationGrantPayload.self, id: grantId)
        XCTAssertTrue(grant.payload.isActive(at: now.addingTimeInterval(120)))
        _ = try await store.revokeAutomationGrant(
            id: grantId,
            at: now.addingTimeInterval(180)
        )
        grant = try await store.payload(AutomationGrantPayload.self, id: grantId)
        XCTAssertNotNil(grant.payload.revokedAt)
        XCTAssertFalse(grant.payload.isActive(at: now.addingTimeInterval(180)))
    }

    func testStablePagesSupportInsertionDuplicationReorderTrashAndRestore() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try SQLCipherDatabase(
            url: directory.appendingPathComponent("stable-pages.sqlite"),
            key: Data(repeating: 71, count: 32)
        )
        let store = EpistoriaStore(database: database)
        let noteId = try await store.createNote(
            title: "Stable pages",
            canvas: NoteCanvasConfiguration(pageCount: 2)
        )
        var pages = try await store.notePages(noteId: noteId)
        XCTAssertEqual(pages.count, 2)

        let sourcePageId = pages[1].id
        let blockId = try await store.appendCanvasText(
            noteId: noteId,
            text: "Content on the second stable page",
            placement: NoteCanvasPlacement(x: 20, y: 30, width: 240, height: 80),
            pageIndex: 1,
            pageId: sourcePageId
        )
        let insertedId = try await store.insertNotePage(noteId: noteId, before: pages[0].id)
        pages = try await store.notePages(noteId: noteId)
        XCTAssertEqual(pages.first?.id, insertedId)

        let duplicateId = try await store.duplicateNotePage(noteId: noteId, pageId: sourcePageId)
        var duplicatedBlocks = try await store.list(NoteBlockPayload.self, parentId: noteId)
            .filter { !$0.payload.tombstone && $0.payload.canvasPageId == duplicateId }
        XCTAssertEqual(duplicatedBlocks.count, 1)
        XCTAssertEqual(duplicatedBlocks.first?.payload.plainText, "Content on the second stable page")

        try await store.reorderNotePage(noteId: noteId, pageId: duplicateId, destinationIndex: 0)
        pages = try await store.notePages(noteId: noteId)
        XCTAssertEqual(pages.first?.id, duplicateId)

        let trashId = try await store.movePageToTrash(
            noteId: noteId,
            pageId: sourcePageId,
            displayName: "Second page"
        )
        pages = try await store.notePages(noteId: noteId)
        var originalBlock = try await store.payload(NoteBlockPayload.self, id: blockId)
        XCTAssertEqual(pages.count, 3)
        XCTAssertTrue(originalBlock.payload.tombstone)

        try await store.restoreTrashEntry(id: trashId)
        pages = try await store.notePages(noteId: noteId)
        originalBlock = try await store.payload(NoteBlockPayload.self, id: blockId)
        XCTAssertEqual(pages.count, 4)
        XCTAssertFalse(originalBlock.payload.tombstone)
        duplicatedBlocks = try await store.list(NoteBlockPayload.self, parentId: noteId)
            .filter { !$0.payload.tombstone && $0.payload.canvasPageId == duplicateId }
        XCTAssertEqual(duplicatedBlocks.count, 1)
    }

    func testTrashIsManualRecoverableAndProtectsDependencies() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try SQLCipherDatabase(
            url: directory.appendingPathComponent("trash.sqlite"),
            key: Data(repeating: 72, count: 32)
        )
        let store = EpistoriaStore(database: database)
        let recoverableId = try await store.createNote(title: "Recoverable")
        let restoreEntryId = try await store.moveToTrash(
            targetId: recoverableId,
            targetType: .note,
            displayName: "Recoverable"
        )
        var trashedIds = try await store.trashedTargetIds()
        XCTAssertTrue(trashedIds.contains(recoverableId))
        try await store.restoreTrashEntry(id: restoreEntryId)
        trashedIds = try await store.trashedTargetIds()
        XCTAssertFalse(trashedIds.contains(recoverableId))
        _ = try await store.payload(NotePayload.self, id: recoverableId)

        let protectedId = try await store.createNote(title: "Protected")
        _ = try await store.moveToTrash(
            targetId: protectedId,
            targetType: .note,
            displayName: "Protected",
            dependencyIds: [UUID()]
        )
        let removableId = try await store.createNote(title: "Removable")
        let removablePages = try await store.notePages(noteId: removableId)
        let removablePageId = try XCTUnwrap(removablePages.first?.id)
        let removableBlockId = try await store.appendCanvasText(
            noteId: removableId,
            text: "Delete with the note",
            placement: NoteCanvasPlacement(x: 20, y: 20, width: 200, height: 60),
            pageIndex: 0,
            pageId: removablePageId
        )
        _ = try await store.moveToTrash(
            targetId: removableId,
            targetType: .note,
            displayName: "Removable"
        )
        let result = try await store.emptyTrash()
        XCTAssertEqual(result.deletedCount, 1)
        XCTAssertEqual(result.protectedCount, 1)
        trashedIds = try await store.trashedTargetIds()
        XCTAssertTrue(trashedIds.contains(protectedId))
        XCTAssertFalse(trashedIds.contains(removableId))
        let remainingPages = try await store.list(NotePagePayload.self)
        let remainingBlocks = try await store.list(NoteBlockPayload.self)
        XCTAssertFalse(remainingPages.contains { $0.id == removablePageId })
        XCTAssertFalse(remainingBlocks.contains { $0.id == removableBlockId })
    }

    func testTrashAutomaticallyProtectsSourceEvidence() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try SQLCipherDatabase(
            url: directory.appendingPathComponent("trash-source-protection.sqlite"),
            key: Data(repeating: 73, count: 32)
        )
        let store = EpistoriaStore(database: database)
        let sourceId = try await store.createSource(type: .pastedText, title: "Protected source")
        let source = try await store.payload(SourcePayload.self, id: sourceId)
        let versionId = try XCTUnwrap(source.payload.currentVersionId)
        let evidenceId = try await store.createEvidence(
            sourceId: sourceId,
            sourceVersionId: versionId,
            kind: .excerpt,
            locator: SourceLocator(kind: .plainText, startOffset: 0, endOffset: 12),
            excerpt: "Keep this"
        )

        let trashId = try await store.moveToTrash(
            targetId: sourceId,
            targetType: .resource,
            displayName: "Protected source"
        )
        let entry = try await store.payload(TrashEntryPayload.self, id: trashId)
        XCTAssertEqual(entry.payload.dependencyIds, [evidenceId])

        let result = try await store.emptyTrash()
        XCTAssertEqual(result.deletedCount, 0)
        XCTAssertEqual(result.protectedCount, 1)
        _ = try await store.payload(SourcePayload.self, id: sourceId)
        _ = try await store.payload(EvidencePayload.self, id: evidenceId)
    }
}

private func testDOCXData(text: String) throws -> Data {
    try testArchiveData([
        "[Content_Types].xml": "<Types><Override PartName=\"/main.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>",
        "word/document.xml": "<w:document xmlns:w=\"word\"><w:body><w:p><w:r><w:t>\(text)</w:t></w:r></w:p></w:body></w:document>",
    ])
}

private func testXLSXData(text: String) throws -> Data {
    try testArchiveData([
        "[Content_Types].xml": "<Types><Override PartName=\"/main.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/></Types>",
        "xl/workbook.xml": "<workbook xmlns:r=\"relationships\"><sheets><sheet name=\"Plan\" r:id=\"rId1\"/></sheets></workbook>",
        "xl/_rels/workbook.xml.rels": "<Relationships><Relationship Id=\"rId1\" Target=\"worksheets/sheet1.xml\"/></Relationships>",
        "xl/sharedStrings.xml": "<sst><si><t>\(text)</t></si></sst>",
        "xl/worksheets/sheet1.xml": "<worksheet><sheetData><row><c t=\"s\"><v>0</v></c></row></sheetData></worksheet>",
    ])
}

private func testArchiveData(_ files: [String: String]) throws -> Data {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("epistoria-database-source-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("fixture.zip")
    let archive = try Archive(url: url, accessMode: .create)
    for (path, string) in files.sorted(by: { $0.key < $1.key }) {
        let data = Data(string.utf8)
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: .deflate
        ) { position, size in
            let start = Int(position)
            return data.subdata(in: start ..< min(start + size, data.count))
        }
    }
    return try Data(contentsOf: url)
}

private func testWAVEData() -> Data {
    func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }
    let sampleBytes = 16_000
    var data = Data("RIFF".utf8)
    data.append(contentsOf: littleEndian(UInt32(36 + sampleBytes)))
    data.append(Data("WAVEfmt ".utf8))
    data.append(contentsOf: littleEndian(UInt32(16)))
    data.append(contentsOf: littleEndian(UInt16(1)))
    data.append(contentsOf: littleEndian(UInt16(1)))
    data.append(contentsOf: littleEndian(UInt32(8_000)))
    data.append(contentsOf: littleEndian(UInt32(16_000)))
    data.append(contentsOf: littleEndian(UInt16(2)))
    data.append(contentsOf: littleEndian(UInt16(16)))
    data.append(Data("data".utf8))
    data.append(contentsOf: littleEndian(UInt32(sampleBytes)))
    data.append(Data(repeating: 0, count: sampleBytes))
    return data
}

private func testMP4Data() -> Data {
    Data(base64Encoded: "AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAN0bW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAAAMgAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAp90cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAAMgAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAABAAAAAQAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAADIAAAEAAABAAAAAAIXbWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAAAyAAAACgBVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAABwm1pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAYJzdGJsAAAAvnN0c2QAAAAAAAAAAQAAAK5hdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAABAAEABIAAAASAAAAAAAAAABFExhdmM2My4xLjEwMSBsaWJ4MjY0AAAAAAAAAAAAAAAAGP//AAAANGF2Y0MBZAAK/+EAF2dkAAqs2V7ARAAAAwAEAAADAMg8SJZYAQAGaOvjyyLA/fj4AAAAABBwYXNwAAAAAQAAAAEAAAAUYnRydAAAAAAAAHZIAAAAAAAAABhzdHRzAAAAAAAAAAEAAAAFAAACAAAAABRzdHNzAAAAAAAAAAEAAAABAAAAOGN0dHMAAAAAAAAABQAAAAEAAAQAAAAAAQAACgAAAAABAAAEAAAAAAEAAAAAAAAAAQAAAgAAAAAcc3RzYwAAAAAAAAABAAAAAQAAAAUAAAABAAAAKHN0c3oAAAAAAAAAAAAAAAUAAALFAAAADAAAAAwAAAAMAAAADAAAABRzdGNvAAAAAAAAAAEAAAOkAAAAYXVkdGEAAABZbWV0YQAAAAAAAAAhaGRscgAAAAAAAAAAbWRpcmFwcGwAAAAAAAAAAAAAAAAsaWxzdAAAACSpdG9vAAAAHGRhdGEAAAABAAAAAExhdmY2My4xLjEwMQAAAAhmcmVlAAAC/W1kYXQAAAKuBgX//6rcRem95tlIt5Ys2CDZI+7veDI2NCAtIGNvcmUgMTY1IHIzMjIyIGIzNTYwNWEgLSBILjI2NC9NUEVHLTQgQVZDIGNvZGVjIC0gQ29weWxlZnQgMjAwMy0yMDI1IC0gaHR0cDovL3d3dy52aWRlb2xhbi5vcmcveDI2NC5odG1sIC0gb3B0aW9uczogY2FiYWM9MSByZWY9MyBkZWJsb2NrPTE6MDowIGFuYWx5c2U9MHgzOjB4MTEzIG1lPWhleCBzdWJtZT03IHBzeT0xIHBzeV9yZD0xLjAwOjAuMDAgbWl4ZWRfcmVmPTEgbWVfcmFuZ2U9MTYgY2hyb21hX21lPTEgdHJlbGxpcz0xIDh4OGRjdD0xIGNxbT0wIGRlYWR6b25lPTIxLDExIGZhc3RfcHNraXA9MSBjaHJvbWFfcXBfb2Zmc2V0PS0yIHRocmVhZHM9MSBsb29rYWhlYWRfdGhyZWFkcz0xIHNsaWNlZF90aHJlYWRzPTAgbnI9MCBkZWNpbWF0ZT0xIGludGVybGFjZWQ9MCBibHVyYXlfY29tcGF0PTAgY29uc3RyYWluZWRfaW50cmE9MCBiZnJhbWVzPTMgYl9weXJhbWlkPTIgYl9hZGFwdD0xIGJfYmlhcz0wIGRpcmVjdD0xIHdlaWdodGI9MSBvcGVuX2dvcD0wIHdlaWdodHA9MiBrZXlpbnQ9MjUwIGtleWludF9taW49MjUgc2NlbmVjdXQ9NDAgaW50cmFfcmVmcmVzaD0wIHJjX2xvb2thaGVhZD00MCByYz1jcmYgbWJ0cmVlPTEgY3JmPTIzLjAgcWNvbXA9MC42MCBxcG1pbj0wIHFwbWF4PTY5IHFwc3RlcD00IGlwX3JhdGlvPTEuNDAgYXE9MToxLjAwAIAAAAAPZYiEADP//vbsvgU2FMjBAAAACEGaJGxCv/7AAAAACEGeQniF/8GBAAAACAGeYXRCv8SAAAAACAGeY2pCv8SB")!
}

private actor TestWebSnapshotCapture: WebSnapshotCapturing {
    enum Outcome: Sendable {
        case snapshot(WebSnapshot)
        case failure(WebSnapshotCaptureError)
    }

    private var outcomes: [Outcome]

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func capture(url _: URL) async throws -> WebSnapshot {
        guard !outcomes.isEmpty else { throw WebSnapshotCaptureError.networkUnavailable }
        switch outcomes.removeFirst() {
        case let .snapshot(snapshot): return snapshot
        case let .failure(error): throw error
        }
    }

    static func snapshot(
        requestedURL: URL,
        capturedURL: URL,
        title: String,
        data: Data
    ) -> WebSnapshot {
        WebSnapshot(
            requestedURL: requestedURL,
            capturedURL: capturedURL,
            mimeType: "text/html",
            title: title,
            data: data,
            readableText: (try? WebSnapshotSourceAdapter().extractText(data: data)) ?? ""
        )
    }
}

private actor TestGoogleWorkspaceCapture: GoogleWorkspaceCapturing {
    enum Outcome: Sendable {
        case snapshot(GoogleWorkspaceSnapshot)
        case failure(GoogleWorkspaceCaptureError)
    }

    private var outcomes: [Outcome]

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func capture(url _: URL) async throws -> GoogleWorkspaceSnapshot {
        guard !outcomes.isEmpty else { throw GoogleWorkspaceCaptureError.networkUnavailable }
        switch outcomes.removeFirst() {
        case let .snapshot(snapshot): return snapshot
        case let .failure(error): throw error
        }
    }

    static func snapshot(
        url: URL,
        kind: GoogleWorkspaceDocumentKind,
        title: String,
        data: Data
    ) throws -> GoogleWorkspaceSnapshot {
        let reference = try GoogleWorkspaceReference(url: url)
        let adapter = GoogleWorkspaceSourceAdapter(kind: kind)
        let mimeType = switch kind {
        case .document:
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case .slides:
            "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case .sheet:
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        }
        return GoogleWorkspaceSnapshot(
            kind: kind,
            canonicalURL: reference.canonicalURL,
            capturedURL: reference.exportURL,
            mimeType: mimeType,
            title: title,
            data: data,
            readableText: try adapter.extractText(data: data) ?? ""
        )
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        errorHandler(error)
    }
}
