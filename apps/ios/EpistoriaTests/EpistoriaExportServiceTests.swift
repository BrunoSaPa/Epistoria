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
        XCTAssertTrue(metadata.contains("epistoria-export/3"))
        XCTAssertTrue(taxonomy.lowercased().contains(topicId.uuidString.lowercased()))
        XCTAssertTrue(knowledge.lowercased().contains(annotationResult.evidenceId.uuidString.lowercased()))
        XCTAssertTrue(learning.contains("Review factoring"))

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
