import EpistoriaCore
import Foundation
import XCTest
@testable import Epistoria

@MainActor
final class SharedCaptureImporterTests: XCTestCase {
    func testDrainImportsTextLinkAndFileIntoUnassignedSourceInbox() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let text = SharedCaptureItem(
            kind: .text,
            title: "Lecture excerpt",
            payload: Data("A local-first shared paragraph.".utf8)
        )
        let link = SharedCaptureItem(
            kind: .link,
            title: "Reference",
            payload: Data("https://example.com/guide#section".utf8)
        )
        let file = SharedCaptureItem(
            kind: .file,
            filename: "../../reading.txt",
            payload: Data("Imported from another app.".utf8)
        )
        for item in [text, link, file] {
            try fixture.inbox.enqueue(item, key: fixture.captureKey)
        }

        let report = await fixture.importer.drain(
            store: fixture.store,
            assetManager: fixture.assetManager
        )

        XCTAssertEqual(report.importedCount, 3)
        XCTAssertEqual(report.failedCount, 0)
        XCTAssertEqual(report.remainingPendingCount, 0)
        let sources = try await fixture.store.list(SourcePayload.self)
        XCTAssertEqual(sources.count, 3)
        XCTAssertTrue(sources.allSatisfy { $0.payload.primaryTopicId == nil })
        XCTAssertEqual(Set(sources.map(\.payload.sourceType)), [.pastedText, .website])
        XCTAssertTrue(sources.contains { $0.payload.title == "reading" })
        for item in [text, link, file] {
            XCTAssertTrue(sources.contains {
                $0.payload.identifiers.contains(SharedCaptureImporter.identifier(for: item.id))
            })
        }
        let website = try XCTUnwrap(sources.first { $0.payload.sourceType == .website })
        XCTAssertEqual(website.payload.canonicalURL?.absoluteString, "https://example.com/guide")
        XCTAssertNil(website.payload.originalAssetId)
    }

    func testCaptureIdentifierMakesQueueCleanupRetryIdempotent() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let item = SharedCaptureItem(kind: .text, payload: Data("One durable Source".utf8))
        try fixture.inbox.enqueue(item, key: fixture.captureKey)
        let first = await fixture.importer.drain(store: fixture.store, assetManager: fixture.assetManager)
        XCTAssertEqual(first.importedCount, 1)

        try fixture.inbox.enqueue(item, key: fixture.captureKey)
        let second = await fixture.importer.drain(store: fixture.store, assetManager: fixture.assetManager)
        XCTAssertEqual(second.importedCount, 0)
        XCTAssertEqual(second.duplicateCount, 1)
        let sources = try await fixture.store.list(SourcePayload.self)
        XCTAssertEqual(sources.count, 1)
        XCTAssertTrue(try fixture.inbox.identifiers(in: .pending).isEmpty)
    }

    func testUnsupportedCaptureMovesToEncryptedFailedQueueUntilDiscarded() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let item = SharedCaptureItem(
            kind: .file,
            filename: "unsupported.binary",
            payload: Data([1, 2, 3, 4])
        )
        try fixture.inbox.enqueue(item, key: fixture.captureKey)

        let report = await fixture.importer.drain(store: fixture.store, assetManager: fixture.assetManager)
        XCTAssertEqual(report.importedCount, 0)
        XCTAssertEqual(report.failedCount, 1)
        XCTAssertEqual(try fixture.inbox.identifiers(in: .failed), [item.id])
        let sources = try await fixture.store.list(SourcePayload.self)
        XCTAssertTrue(sources.isEmpty)

        try fixture.importer.discardFailed()
        XCTAssertTrue(try fixture.inbox.identifiers(in: .failed).isEmpty)
    }
}

private struct Fixture {
    let root: URL
    let database: SQLCipherDatabase
    let store: EpistoriaStore
    let assetManager: AssetManager
    let inbox: SharedCaptureInbox
    let captureKey: Data
    let importer: SharedCaptureImporter

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EpistoriaSharedCaptureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let accountID = UUID()
        let accountKey = try EntityCrypto().randomKey()
        database = try SQLCipherDatabase(
            url: root.appendingPathComponent("test.sqlite"),
            key: try EntityCrypto().localDatabaseKey(accountKey: accountKey, accountId: accountID)
        )
        store = EpistoriaStore(database: database)
        assetManager = AssetManager(
            accountId: accountID,
            accountKey: accountKey,
            store: store,
            directory: root.appendingPathComponent("Assets", isDirectory: true)
        )
        inbox = SharedCaptureInbox(
            rootURL: root.appendingPathComponent("CaptureInbox", isDirectory: true)
        )
        captureKey = try EntityCrypto().randomKey()
        importer = SharedCaptureImporter(inbox: inbox, captureKey: captureKey)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
