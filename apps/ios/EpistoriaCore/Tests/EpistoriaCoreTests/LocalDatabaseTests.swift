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
