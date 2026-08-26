@testable import Epistoria
import EpistoriaCore
import XCTest

@MainActor
final class EpistoriaExportServiceTests: XCTestCase {
    private struct Fixture {
        var root: URL
        var accountId: UUID
        var accountKey: Data
        var database: SQLCipherDatabase
        var store: EpistoriaStore
        var assetManager: AssetManager
        var service: EpistoriaExportService
    }

    func testDecryptedExportIsCompleteExcludesKeysAndIsRemovable() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let noteId = try await fixture.store.createNote(
            title: "A durable thought",
            canvas: NoteCanvasConfiguration(pageCount: 2)
        )
        let areaId = try await fixture.store.createArea(name: "Mathematics")
        let topicId = try await fixture.store.createTopic(name: "Algebra", primaryAreaId: areaId)
        _ = try await fixture.store.createFlashcard(
            topicId: topicId,
            prompt: "Factor x² - 9",
            answer: "(x - 3)(x + 3)"
        )
        _ = try await fixture.store.save(
            payload: StudyGoalPayload(topicId: topicId, title: "Review factoring"),
            parentId: topicId,
            relationIds: [topicId]
        )
        let tutorSessionId = try await fixture.store.createTutorSession(
            topicId: topicId,
            objective: "Factor quadratics"
        )
        _ = try await fixture.store.appendOfflineTutorTurn(
            sessionId: tutorSessionId,
            text: "I would identify the leading coefficient.",
            confidence: 3
        )
        let learningSignalId = try await fixture.store.save(
            payload: LearningSignalPayload(
                tutorSessionId: tutorSessionId,
                topicId: topicId,
                objective: "Factor quadratics",
                assessmentKind: .selfExplanation,
                outcome: .partial,
                rationale: "The explanation needs the factor pair."
            ),
            parentId: tutorSessionId,
            relationIds: [tutorSessionId, topicId]
        )
        try await fixture.store.reviewLearningSignal(id: learningSignalId, state: .accepted)
        _ = try await fixture.store.appendTextBlock(
            noteId: noteId,
            text: "Evidence stays portable."
        )
        var richBlock = NoteBlockPayload(
            noteId: noteId,
            blockType: .handwriting,
            orderKey: "z"
        )
        let noteDrawing = Data([0x50, 0x4b, 0x44, 0x52, 0x41, 0x57])
        let richText = Data("{\\rtf1 Portable rich text}".utf8)
        richBlock.drawingData = noteDrawing
        richBlock.richTextRtf = richText
        let richBlockId = try await fixture.store.save(
            payload: richBlock,
            parentId: noteId,
            relationIds: [noteId]
        )

        let png = try XCTUnwrap(
            Data(
                base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
            )
        )
        let imageURL = fixture.root.appendingPathComponent("diagram.png")
        try png.write(to: imageURL, options: .atomic)
        let importedImage = try await fixture.assetManager.importImage(from: imageURL)
        let imageItemId = try await fixture.store.appendCanvasImage(
            noteId: noteId,
            assetId: importedImage.assetId,
            filename: importedImage.filename,
            placement: NoteCanvasPlacement(x: 40, y: 80, width: 240, height: 180, zIndex: 2),
            pageIndex: 1
        )

        let pdf = Data("%PDF-1.4\n% Epistoria portability test\n%%EOF\n".utf8)
        let pdfURL = fixture.root.appendingPathComponent("source.pdf")
        try pdf.write(to: pdfURL, options: .atomic)
        let imported = try await fixture.assetManager.importPDF(from: pdfURL)
        let asset = try await fixture.store.payload(AssetPayload.self, id: imported.assetId)
        let csv = Data("objective,status\nFactorization,ready\n".utf8)
        let csvURL = fixture.root.appendingPathComponent("plan.csv")
        try csv.write(to: csvURL, options: .atomic)
        let importedCSV = try await fixture.assetManager.importSource(from: csvURL)
        let webHTML = Data(
            "<html><head><title>Exported page</title></head><body><p>Readable theorem</p><script>ignored()</script></body></html>".utf8
        )
        let webURL = fixture.root.appendingPathComponent("captured.html")
        try webHTML.write(to: webURL, options: .atomic)
        let importedHTML = try await fixture.assetManager.importSource(from: webURL)
        let canonicalWebURL = try XCTUnwrap(URL(string: "https://example.com/theorem"))
        let webSourceId = try await fixture.store.createSource(
            type: .website,
            title: "Exported page",
            originalAssetId: importedHTML.assetId,
            canonicalURL: canonicalWebURL,
            capturedURL: canonicalWebURL
        )
        let googleDocument = try XCTUnwrap(Data(base64Encoded:
            "UEsDBBQAAAAIALwgFl0FejLKdgAAAI8AAAATABwAW0NvbnRlbnRfVHlwZXNdLnhtbFVUCQADhHSJaoR0iWp1eAsAAQT1AQAABAAAAAA9jjEOwjAMRXdOUWVFJBdIu7ADAxewEgdZiu3ICQVuTysk5v/+04v3T8O+xOuKZpRxuoGNCzDOLjCQ+DdXN51VBsrY2dlBa5USDFIJq2SvDWWjihrD6CcthRJmTU/eLv6llptpwt5JHlz9f9n1x10flhh+GYcvUEsDBAoAAAAAALwgFl0AAAAAAAAAAAAAAAAFABwAd29yZC9VVAkAA4R0iWqHdIlqdXgLAAEE9QEAAAQAAAAAUEsDBBQAAAAIALwgFl0GDEA/VAAAAHIAAAARABwAd29yZC9kb2N1bWVudC54bWxVVAkAA4R0iWqEdIlqdXgLAAEE9QEAAAQAAAAAsym3SslPLs1NzStRqMjNySu2KrdVKs8vSlGysym3SspPqQTRBSCiCESU2AWlJqYkJuWkKrjn56cDqZKM1Pyi1FwbfZAkiCwCkwVgEmKAPsISOy4AUEsBAh4DFAAAAAgAvCAWXQV6Msp2AAAAjwAAABMAGAAAAAAAAQAAAKSBAAAAAFtDb250ZW50X1R5cGVzXS54bWxVVAUAA4R0iWp1eAsAAQT1AQAABAAAAABQSwECHgMKAAAAAAC8IBZdAAAAAAAAAAAAAAAABQAYAAAAAAAAABAA7UHDAAAAd29yZC9VVAUAA4R0iWp1eAsAAQT1AQAABAAAAABQSwECHgMUAAAACAC8IBZdBgxAP1QAAAByAAAAEQAYAAAAAAABAAAApIECAQAAd29yZC9kb2N1bWVudC54bWxVVAUAA4R0iWp1eAsAAQT1AQAABAAAAABQSwUGAAAAAAMAAwD7AAAAoQEAAAAA"
        ))
        let googleDocumentURL = fixture.root.appendingPathComponent("google-export.docx")
        try googleDocument.write(to: googleDocumentURL, options: .atomic)
        let importedGoogleDocument = try await fixture.assetManager.importSource(
            from: googleDocumentURL
        )
        let googleShareURL = try XCTUnwrap(URL(
            string: "https://docs.google.com/document/d/export-test"
        ))
        let googleSourceId = try await fixture.store.createSource(
            type: .googleDocument,
            title: "Google theorem",
            originalAssetId: importedGoogleDocument.assetId,
            canonicalURL: googleShareURL,
            capturedURL: try GoogleWorkspaceReference(url: googleShareURL).exportURL
        )
        let youtubeURL = try XCTUnwrap(URL(
            string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        ))
        let youtubeSourceId = try await fixture.store.createSource(
            type: .youtube,
            title: "Video reference",
            canonicalURL: youtubeURL,
            capturedURL: youtubeURL,
            identifiers: ["youtube:dQw4w9WgXcQ"]
        )

        var annotation = AnnotationPayload(
            resourceId: imported.resourceId,
            annotationType: .drawing,
            pageNumber: 1,
            comment: "Margin idea"
        )
        let annotationDrawing = Data([0x41, 0x4e, 0x4e, 0x4f, 0x54])
        annotation.drawingData = annotationDrawing
        let importedSource = try await fixture.store.payload(SourcePayload.self, id: imported.resourceId)
        let annotationResult = try await fixture.store.createAnnotationEvidence(
            annotation: annotation,
            sourceVersionId: try XCTUnwrap(importedSource.payload.currentVersionId)
        )
        let annotationId = annotationResult.annotationId
        let firstConceptId = try await fixture.store.createConcept(
            name: "Factorization",
            topicIds: [topicId]
        )
        let secondConceptId = try await fixture.store.createConcept(
            name: "Roots",
            topicIds: [topicId]
        )
        let conceptLinkId = try await fixture.store.createConceptLink(
            sourceConceptId: firstConceptId,
            targetConceptId: secondConceptId,
            relation: .applies,
            rationale: "Factoring can expose roots.",
            evidenceIds: [annotationResult.evidenceId]
        )

        let package = try await fixture.service.prepareDecryptedDirectoryForTesting(
            includingDerivedAI: false
        )
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }

        let validation = try await fixture.service.validateDecryptedDirectory(at: package)
        XCTAssertGreaterThan(validation.fileCount, 12)
        XCTAssertGreaterThan(validation.byteCount, 0)
        XCTAssertEqual(
            try Data(contentsOf: package.appendingPathComponent(
                "resources/originals/\(imported.assetId.uuidString.lowercased()).pdf"
            )),
            pdf
        )
        XCTAssertEqual(
            try Data(contentsOf: package.appendingPathComponent(
                "resources/readable/\(importedCSV.resourceId.uuidString.lowercased()).csv"
            )),
            csv
        )
        XCTAssertEqual(
            try Data(contentsOf: package.appendingPathComponent(
                "resources/originals/\(importedHTML.assetId.uuidString.lowercased()).html"
            )),
            webHTML
        )
        XCTAssertEqual(
            try String(
                contentsOf: package.appendingPathComponent(
                    "resources/readable/\(webSourceId.uuidString.lowercased()).txt"
                ),
                encoding: .utf8
            ),
            "Readable theorem"
        )
        XCTAssertEqual(
            try Data(contentsOf: package.appendingPathComponent(
                "resources/originals/\(importedGoogleDocument.assetId.uuidString.lowercased()).docx"
            )),
            googleDocument
        )
        XCTAssertEqual(
            try String(
                contentsOf: package.appendingPathComponent(
                    "resources/readable/\(googleSourceId.uuidString.lowercased()).txt"
                ),
                encoding: .utf8
            ),
            "Readable Google theorem"
        )
        XCTAssertEqual(
            try String(
                contentsOf: package.appendingPathComponent(
                    "resources/readable/\(youtubeSourceId.uuidString.lowercased()).txt"
                ),
                encoding: .utf8
            ),
            "Video reference\n\nYouTube URL: https://www.youtube.com/watch?v=dQw4w9WgXcQ\n"
        )
        XCTAssertEqual(
            try Data(contentsOf: package.appendingPathComponent(
                "notes/drawings/\(richBlockId.uuidString.lowercased()).pkdrawing"
            )),
            noteDrawing
        )
        XCTAssertEqual(
            try Data(contentsOf: package.appendingPathComponent(
                "notes/rich-text/\(richBlockId.uuidString.lowercased()).rtf"
            )),
            richText
        )
        XCTAssertEqual(
            try Data(contentsOf: package.appendingPathComponent(
                "annotation-drawings/\(annotationId.uuidString.lowercased()).pkdrawing"
            )),
            annotationDrawing
        )
        XCTAssertEqual(
            try Data(contentsOf: package.appendingPathComponent(
                "notes/images/\(importedImage.assetId.uuidString.lowercased()).png"
            )),
            png
        )
        let canvasAssets = try String(
            contentsOf: package.appendingPathComponent("notes/canvas-assets.json"),
            encoding: .utf8
        )
        XCTAssertTrue(canvasAssets.lowercased().contains(imageItemId.uuidString.lowercased()))
        XCTAssertTrue(canvasAssets.lowercased().contains(importedImage.assetId.uuidString.lowercased()))
        XCTAssertTrue(canvasAssets.contains("notes/images/"))
        let noteRecord = try String(
            contentsOf: package.appendingPathComponent(
                "notes/\(noteId.uuidString.lowercased()).json"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(noteRecord.contains("\"pageCount\" : 2"))
        XCTAssertTrue(noteRecord.contains("\"canvasPageIndex\" : 1"))
        let metadata = try String(contentsOf: package.appendingPathComponent("metadata.json"), encoding: .utf8)
        let taxonomy = try String(contentsOf: package.appendingPathComponent("taxonomy.json"), encoding: .utf8)
        let knowledge = try String(contentsOf: package.appendingPathComponent("knowledge.json"), encoding: .utf8)
        let learning = try String(contentsOf: package.appendingPathComponent("learning.json"), encoding: .utf8)
        XCTAssertTrue(metadata.contains("epistoria-export/5"))
        let entities = try String(
            contentsOf: package.appendingPathComponent("entities.json"),
            encoding: .utf8
        )
        XCTAssertTrue(entities.lowercased().contains(noteId.uuidString.lowercased()))
        XCTAssertFalse(entities.contains(asset.payload.assetKey))
        XCTAssertFalse(entities.contains(asset.payload.dedupeTag))
        let entityRecords = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(entities.utf8)) as? [[String: Any]]
        )
        for record in entityRecords {
            let entityType = try XCTUnwrap(
                (record["entityType"] as? String).flatMap(EntityType.init(rawValue:))
            )
            if entityType == .asset { continue }
            let content = try XCTUnwrap(record["content"])
            try EntityPayloadValidator.validate(
                entityType: entityType,
                content: JSONSerialization.data(
                    withJSONObject: content,
                    options: [.sortedKeys, .withoutEscapingSlashes]
                )
            )
        }
        XCTAssertTrue(taxonomy.lowercased().contains(topicId.uuidString.lowercased()))
        XCTAssertTrue(knowledge.lowercased().contains(annotationResult.evidenceId.uuidString.lowercased()))
        XCTAssertTrue(knowledge.lowercased().contains(conceptLinkId.uuidString.lowercased()))
        XCTAssertTrue(knowledge.contains("Factoring can expose roots."))
        XCTAssertTrue(learning.contains("Review factoring"))
        XCTAssertTrue(learning.contains("I would identify the leading coefficient."))
        XCTAssertTrue(learning.contains("The explanation needs the factor pair."))

        let exportedBytes = try recursiveFileData(in: package)
        XCTAssertFalse(exportedBytes.contains { $0.range(of: fixture.accountKey) != nil })
        XCTAssertFalse(exportedBytes.compactMap { String(data: $0, encoding: .utf8) }
            .contains { $0.contains(asset.payload.assetKey) })

        let result = try await fixture.service.exportDecrypted(includingDerivedAI: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.archiveURL.path))
        XCTAssertGreaterThan(result.fileCount, 12)
        XCTAssertGreaterThan(result.byteCount, 0)

        try EpistoriaExportService.removeTemporaryArchive(result.archiveURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.archiveURL.path))
    }

    func testAcceptedTranscriptManifestAndChunksExportAsDerivedData() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sourceId = try await fixture.store.createSource(
            type: .audio,
            title: "Synthetic lecture"
        )
        let source = try await fixture.store.payload(SourcePayload.self, id: sourceId)
        let sourceVersionId = try XCTUnwrap(source.payload.currentVersionId)
        let jobId = UUID()
        let chunkId = UUID()
        let chunk = MediaTranscriptionChunk(
            jobId: jobId,
            sourceId: sourceId,
            sourceVersionId: sourceVersionId,
            chunkIndex: 0,
            segments: [TranscriptSegment(
                index: 0,
                startSeconds: 0,
                endSeconds: 2,
                text: "Accepted transcript text."
            )]
        )
        _ = try await fixture.database.saveLocal(
            id: chunkId,
            entityType: .aiArtifact,
            parentId: sourceId,
            relationIds: [sourceId, sourceVersionId],
            content: try CanonicalJSON.encode(chunk),
            search: SearchDocument(title: "", body: "")
        )
        var manifest = MediaTranscriptionManifest(
            jobId: jobId,
            sourceId: sourceId,
            sourceVersionId: sourceVersionId,
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            language: "en",
            durationSeconds: 2,
            characterCount: 25,
            segmentCount: 1,
            trace: ProviderTrace(
                provider: "deterministic-test",
                model: "fixture-transcription-v1",
                promptVersion: "media-transcription/v1"
            ),
            chunkEntityIds: [chunkId]
        )
        manifest.reviewState = .accepted
        manifest.reviewedAt = Date(timeIntervalSince1970: 1_800_000_100)
        let manifestId = try await fixture.store.save(
            payload: manifest,
            parentId: sourceId,
            relationIds: [sourceId, sourceVersionId, chunkId]
        )
        let correctionId = try await fixture.store.createTranscriptCorrection(
            transcriptionArtifactId: manifestId,
            segmentIndex: 0,
            correctedText: "Owner-corrected transcript text.",
            reason: "Checked against the recording."
        )
        let evidenceId = try await fixture.store.createTranscriptEvidence(
            transcriptionArtifactId: manifestId,
            segmentIndexes: [0]
        )

        let package = try await fixture.service.prepareDecryptedDirectoryForTesting(
            includingDerivedAI: true
        )
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }
        let artifacts = try String(
            contentsOf: package.appendingPathComponent("ai-artifacts.json"),
            encoding: .utf8
        )
        let knowledge = try String(
            contentsOf: package.appendingPathComponent("knowledge.json"),
            encoding: .utf8
        )
        XCTAssertTrue(artifacts.lowercased().contains(manifestId.uuidString.lowercased()))
        XCTAssertTrue(artifacts.lowercased().contains(chunkId.uuidString.lowercased()))
        XCTAssertTrue(artifacts.contains("Accepted transcript text."))
        XCTAssertFalse(artifacts.contains("Owner-corrected transcript text."))
        XCTAssertTrue(knowledge.lowercased().contains(correctionId.uuidString.lowercased()))
        XCTAssertTrue(knowledge.lowercased().contains(evidenceId.uuidString.lowercased()))
        XCTAssertTrue(knowledge.contains("Owner-corrected transcript text."))
    }

    func testVersionFiveExportRestoresStableRecordsAndHistoricalAssetsIntoCleanAccount() async throws {
        let source = try makeFixture()
        defer { try? FileManager.default.removeItem(at: source.root) }
        let areaId = try await source.store.createArea(name: "Mathematics")
        let topicId = try await source.store.createTopic(name: "Factorization", primaryAreaId: areaId)
        let noteId = try await source.store.createNote(title: "Difference of squares", courseId: topicId)
        _ = try await source.store.appendTextBlock(noteId: noteId, text: "a² - b²")

        let firstPDF = Data("%PDF-1.4\nfirst immutable version\n%%EOF\n".utf8)
        let secondPDF = Data("%PDF-1.4\nsecond immutable version\n%%EOF\n".utf8)
        let pdfURL = source.root.appendingPathComponent("factorization.pdf")
        try firstPDF.write(to: pdfURL, options: .atomic)
        let imported = try await source.assetManager.importPDF(from: pdfURL, courseId: topicId)
        try secondPDF.write(to: pdfURL, options: .atomic)
        _ = try await source.assetManager.refreshSource(id: imported.resourceId, from: pdfURL)
        let sourceVersions = try await source.store.list(
            SourceVersionPayload.self,
            parentId: imported.resourceId
        )
        let assetIds = try sourceVersions.map { try XCTUnwrap($0.payload.originalAssetId) }
        XCTAssertEqual(assetIds.count, 2)

        let package = try await source.service.prepareDecryptedDirectoryForTesting(
            includingDerivedAI: false
        )
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }

        let targetRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "EpistoriaImportTarget-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: targetRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: targetRoot) }
        let targetAccountId = UUID()
        let targetAccountKey = try EntityCrypto().randomKey()
        let targetDatabase = try SQLCipherDatabase(
            url: targetRoot.appendingPathComponent("target.sqlite"),
            key: try EntityCrypto().localDatabaseKey(
                accountKey: targetAccountKey,
                accountId: targetAccountId
            )
        )
        let targetStore = EpistoriaStore(database: targetDatabase)
        let targetAssets = targetRoot.appendingPathComponent("Assets", isDirectory: true)
        let targetAssetManager = AssetManager(
            accountId: targetAccountId,
            accountKey: targetAccountKey,
            store: targetStore,
            directory: targetAssets
        )
        let importer = EpistoriaPortableImportService(
            accountId: targetAccountId,
            accountKey: targetAccountKey,
            database: targetDatabase,
            store: targetStore,
            assetManager: targetAssetManager,
            assetsDirectory: targetAssets
        )

        let plan = try await importer.prepare(from: package)
        XCTAssertEqual(plan.summary.sourceAccountId, source.accountId)
        XCTAssertEqual(plan.summary.noteCount, 1)
        XCTAssertEqual(plan.summary.sourceCount, 1)
        XCTAssertEqual(plan.summary.assetCount, 2)
        _ = try await importer.commit(plan)

        let restoredNote = try await targetStore.payload(NotePayload.self, id: noteId)
        let restoredTopic = try await targetStore.payload(TopicPayload.self, id: topicId)
        let restoredVersions = try await targetStore.list(
            SourceVersionPayload.self,
            parentId: imported.resourceId
        )
        XCTAssertEqual(restoredNote.payload.title, "Difference of squares")
        XCTAssertEqual(restoredTopic.payload.name, "Factorization")
        XCTAssertEqual(restoredVersions.count, 2)
        var restored: [Data] = []
        for assetId in assetIds {
            restored.append(try await targetAssetManager.decryptedData(assetId: assetId))
        }
        XCTAssertEqual(Set(restored), Set([firstPDF, secondPDF]))
        let health = try await targetDatabase.dataHealth()
        XCTAssertGreaterThan(health.pendingMutations, 0)
        XCTAssertEqual(health.pendingAssets, 2)
    }

    func testPortableImportRejectsNonEmptyTargetWithoutChangingIt() async throws {
        let source = try makeFixture()
        defer { try? FileManager.default.removeItem(at: source.root) }
        _ = try await source.store.createNote(title: "Source note")
        let package = try await source.service.prepareDecryptedDirectoryForTesting(
            includingDerivedAI: false
        )
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }

        let target = try makeFixture()
        defer { try? FileManager.default.removeItem(at: target.root) }
        let existingId = try await target.store.createNote(title: "Keep me")
        let importer = EpistoriaPortableImportService(
            accountId: target.accountId,
            accountKey: target.accountKey,
            database: target.database,
            store: target.store,
            assetManager: target.assetManager,
            assetsDirectory: target.root.appendingPathComponent("Assets", isDirectory: true)
        )
        do {
            _ = try await importer.prepare(from: package)
            XCTFail("Expected non-empty import rejection")
        } catch let error as EpistoriaImportError {
            guard case .requiresEmptyNotebook = error else {
                return XCTFail("Unexpected import error: \(error)")
            }
        }
        let existing = try await target.store.payload(NotePayload.self, id: existingId)
        let notes = try await target.store.list(NotePayload.self)
        XCTAssertEqual(existing.payload.title, "Keep me")
        XCTAssertEqual(notes.count, 1)
    }

    func testValidationRejectsTamperingDuplicateEntriesHiddenFilesAndOtherAccounts() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.store.createNote(title: "Integrity")

        var package = try await fixture.service.prepareDecryptedDirectoryForTesting(
            includingDerivedAI: false
        )
        try Data("{}\n".utf8).write(
            to: package.appendingPathComponent("collections.json"),
            options: .atomic
        )
        await assertValidationFails(fixture.service, directory: package)
        try? FileManager.default.removeItem(at: package.deletingLastPathComponent())

        package = try await fixture.service.prepareDecryptedDirectoryForTesting(
            includingDerivedAI: false
        )
        let manifestURL = package.appendingPathComponent("checksums.sha256")
        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
        let firstLine = try XCTUnwrap(manifest.split(whereSeparator: { $0.isNewline }).first)
        try Data((manifest + firstLine + "\n").utf8).write(to: manifestURL, options: .atomic)
        await assertValidationFails(fixture.service, directory: package)
        try? FileManager.default.removeItem(at: package.deletingLastPathComponent())

        package = try await fixture.service.prepareDecryptedDirectoryForTesting(
            includingDerivedAI: false
        )
        try Data("secret".utf8).write(
            to: package.appendingPathComponent(".account-key"),
            options: .atomic
        )
        await assertValidationFails(fixture.service, directory: package)

        let otherAccountService = EpistoriaExportService(
            accountId: UUID(),
            store: fixture.store,
            database: fixture.database,
            assetManager: fixture.assetManager
        )
        await assertValidationFails(otherAccountService, directory: package)
        try? FileManager.default.removeItem(at: package.deletingLastPathComponent())
    }

    func testValidationRejectsSymbolicLinksAndCleanupRefusesUnownedPaths() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let package = try await fixture.service.prepareDecryptedDirectoryForTesting(
            includingDerivedAI: false
        )
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }
        try FileManager.default.createSymbolicLink(
            at: package.appendingPathComponent("metadata-link.json"),
            withDestinationURL: package.appendingPathComponent("metadata.json")
        )
        await assertValidationFails(fixture.service, directory: package)

        let unowned = fixture.root.appendingPathComponent("Epistoria-do-not-delete.zip")
        try Data("not an export".utf8).write(to: unowned, options: .atomic)
        try EpistoriaExportService.removeTemporaryArchive(unowned)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unowned.path))
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EpistoriaExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let accountId = UUID()
        let accountKey = try EntityCrypto().randomKey()
        let database = try SQLCipherDatabase(
            url: root.appendingPathComponent("test.sqlite"),
            key: try EntityCrypto().localDatabaseKey(
                accountKey: accountKey,
                accountId: accountId
            )
        )
        let store = EpistoriaStore(database: database)
        let assetManager = AssetManager(
            accountId: accountId,
            accountKey: accountKey,
            store: store,
            directory: root.appendingPathComponent("Assets", isDirectory: true)
        )
        return Fixture(
            root: root,
            accountId: accountId,
            accountKey: accountKey,
            database: database,
            store: store,
            assetManager: assetManager,
            service: EpistoriaExportService(
                accountId: accountId,
                store: store,
                database: database,
                assetManager: assetManager
            )
        )
    }

    private func assertValidationFails(
        _ service: EpistoriaExportService,
        directory: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await service.validateDecryptedDirectory(at: directory)
            XCTFail("Expected export validation to fail", file: file, line: line)
        } catch {
            // Expected: callers only need a typed failure rather than a process trap.
        }
    }

    private func recursiveFileData(in directory: URL) throws -> [Data] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }
        return try enumerator.compactMap { value in
            guard let url = value as? URL,
                  try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            else { return nil }
            return try Data(contentsOf: url, options: .mappedIfSafe)
        }
    }
}
