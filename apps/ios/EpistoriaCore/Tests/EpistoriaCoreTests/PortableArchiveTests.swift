@testable import EpistoriaCore
import Foundation
import XCTest
import ZIPFoundation

final class PortableArchiveTests: XCTestCase {
    func testEntityValidatorRejectsUnknownSchemaEvenWhenPayloadWouldDecode() throws {
        var note = NotePayload(title: "Synthetic")
        note.schemaVersion = "note/v999"
        XCTAssertThrowsError(
            try EntityPayloadValidator.validate(
                entityType: .note,
                content: CanonicalJSON.encode(note)
            )
        ) { error in
            XCTAssertEqual(
                error as? EntityPayloadValidator.ValidationError,
                .unsupportedSchemaVersion
            )
        }
    }

    func testEntityValidatorAcceptsCurrentTopicAndRejectsLegacyCourseSchema() throws {
        let topic = TopicPayload(name: "Synthetic")
        try EntityPayloadValidator.validate(
            entityType: .topic,
            content: CanonicalJSON.encode(topic)
        )
        var legacy = topic
        legacy.schemaVersion = "course/v1"
        XCTAssertThrowsError(
            try EntityPayloadValidator.validate(
                entityType: .topic,
                content: CanonicalJSON.encode(legacy)
            )
        )
    }

    func testExtractorAcceptsBoundedPackageAndChecksCRC() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "EpistoriaPortableArchiveTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = root.appendingPathComponent("portable.zip")
        let data = Data("{\"formatVersion\":\"epistoria-export/5\"}".utf8)
        try makeArchive(at: zip, entries: ["epistoria-export/metadata.json": data])
        let destination = root.appendingPathComponent("output", isDirectory: true)
        let package = try PortableArchiveExtractor().extract(zipURL: zip, into: destination)
        XCTAssertEqual(
            try Data(contentsOf: package.appendingPathComponent("metadata.json")),
            data
        )
    }

    func testExtractorRejectsTraversalBeforeWritingOutsideDestination() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "EpistoriaPortableArchiveTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = root.appendingPathComponent("hostile.zip")
        try makeArchive(at: zip, entries: [
            "epistoria-export/metadata.json": Data("{}".utf8),
            "epistoria-export/../../outside.txt": Data("unsafe".utf8),
        ])
        let destination = root.appendingPathComponent("output", isDirectory: true)
        XCTAssertThrowsError(
            try PortableArchiveExtractor().extract(zipURL: zip, into: destination)
        ) { error in
            XCTAssertEqual(error as? PortableArchiveError, .unsafeEntry)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("outside.txt").path))
    }

    func testInspectorChecksLegacyArchiveVersionAndProducesStableChecksum() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "EpistoriaPortableArchiveInspectionTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = root.appendingPathComponent("version-7.zip")
        try makeArchive(at: zip, entries: [
            "epistoria-export/metadata.json": Data(
                "{\"formatVersion\":\"epistoria-export/7\"}".utf8
            ),
            "epistoria-export/notes/example.json": Data("{}".utf8),
        ])

        let inspector = PortableArchiveInspector()
        let first = try inspector.inspect(
            zipURL: zip,
            allowedFormats: ["epistoria-export/7"]
        )
        let second = try inspector.inspect(
            zipURL: zip,
            allowedFormats: ["epistoria-export/7"]
        )
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.formatVersion, "epistoria-export/7")
        XCTAssertEqual(first.sha256.count, 64)
        XCTAssertGreaterThan(first.byteCount, 0)
        XCTAssertThrowsError(
            try inspector.inspect(zipURL: zip, allowedFormats: ["epistoria-export/8"])
        ) { error in
            XCTAssertEqual(error as? PortableArchiveError, .unsupportedFormat)
        }
    }

    private func makeArchive(at url: URL, entries: [String: Data]) throws {
        let archive = try Archive(url: url, accessMode: .create)
        for (path, data) in entries.sorted(by: { $0.key < $1.key }) {
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
    }
}
