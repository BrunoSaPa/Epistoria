import Foundation
import XCTest
@testable import EpistoriaCore

final class LocalSemanticSearchTests: XCTestCase {
    private func temporaryDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EpistoriaSemanticTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("epistoria.sqlite")
    }

    func testSearchKeepsExactMatchesFirstAndLabelsRelatedMatches() async throws {
        let url = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let database = try SQLCipherDatabase(
            url: url,
            key: Data(0 ..< 32),
            semanticEmbeddingProvider: TestSemanticEmbeddingProvider()
        )
        let exactId = UUID()
        let relatedId = UUID()
        let unrelatedId = UUID()
        _ = try await database.saveLocal(
            id: exactId,
            entityType: .note,
            content: Data("exact".utf8),
            search: SearchDocument(
                title: "Prediction checklist",
                body: "Uncertainty in predictions"
            )
        )
        _ = try await database.saveLocal(
            id: relatedId,
            entityType: .note,
            content: Data("related".utf8),
            search: SearchDocument(
                title: "Information theory",
                body: "Probability and entropy describe random variables."
            )
        )
        _ = try await database.saveLocal(
            id: unrelatedId,
            entityType: .note,
            content: Data("unrelated".utf8),
            search: SearchDocument(title: "Garden", body: "Healthy soil helps plants grow.")
        )

        let hits = try await database.search("uncertainty predictions")
        let immediate = try await database.search(
            "uncertainty predictions",
            includeRelated: false
        )

        XCTAssertEqual(hits.first?.id, exactId)
        XCTAssertEqual(hits.first?.matchKind, .exact)
        XCTAssertEqual(hits.dropFirst().first?.id, relatedId)
        XCTAssertEqual(hits.dropFirst().first?.matchKind, .related)
        XCTAssertEqual(try XCTUnwrap(hits.dropFirst().first?.relevance), 1, accuracy: 0.0001)
        XCTAssertFalse(hits.contains { $0.id == unrelatedId })
        XCTAssertEqual(immediate.map(\ .id), [exactId])
        XCTAssertTrue(immediate.allSatisfy { $0.matchKind == .exact })
    }

    func testSearchAppliesScopeBeforeExactAndRelatedLimits() async throws {
        let url = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let database = try SQLCipherDatabase(
            url: url,
            key: Data(0 ..< 32),
            semanticEmbeddingProvider: TestSemanticEmbeddingProvider()
        )
        let noteId = UUID()
        let sourceId = UUID()
        _ = try await database.saveLocal(
            id: noteId,
            entityType: .note,
            content: Data("note".utf8),
            search: SearchDocument(title: "Entropy", body: "Random variables")
        )
        _ = try await database.saveLocal(
            id: sourceId,
            entityType: .source,
            content: Data("resource".utf8),
            search: SearchDocument(title: "Uncertainty reference", body: "Predictions")
        )

        let notes = try await database.search(
            "uncertainty predictions",
            entityTypes: [.note],
            limit: 1
        )

        XCTAssertEqual(notes.map(\ .id), [noteId])
        XCTAssertEqual(notes.first?.matchKind, .related)
    }

    func testUnavailableSemanticModelPreservesExactSearch() async throws {
        let url = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let database = try SQLCipherDatabase(
            url: url,
            key: Data(0 ..< 32),
            semanticEmbeddingProvider: UnavailableSemanticEmbeddingProvider()
        )
        let noteId = UUID()
        _ = try await database.saveLocal(
            id: noteId,
            entityType: .note,
            content: Data("note".utf8),
            search: SearchDocument(title: "Linear algebra", body: "Eigenvector basis")
        )

        let hits = try await database.search("eigen")

        XCTAssertEqual(hits.map(\ .id), [noteId])
        XCTAssertTrue(hits.allSatisfy { $0.matchKind == .exact })
        let indexed = try await database.rebuildSemanticSearchIndex()
        XCTAssertEqual(indexed, 0)
    }

    func testSemanticIndexIsEncryptedAndCanBeRebuiltAfterRelaunch() async throws {
        let url = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let key = Data(0 ..< 32)
        let unavailable = try SQLCipherDatabase(
            url: url,
            key: key,
            semanticEmbeddingProvider: UnavailableSemanticEmbeddingProvider()
        )
        let noteId = UUID()
        _ = try await unavailable.saveLocal(
            id: noteId,
            entityType: .note,
            content: Data("note".utf8),
            search: SearchDocument(
                title: "Information theory",
                body: "Probability and entropy describe random variables."
            )
        )
        let database = try SQLCipherDatabase(
            url: url,
            key: key,
            semanticEmbeddingProvider: TestSemanticEmbeddingProvider()
        )

        let indexed = try await database.rebuildSemanticSearchIndex()
        XCTAssertEqual(indexed, 1)
        let hits = try await database.search("uncertainty predictions")
        XCTAssertEqual(hits.first?.id, noteId)
        XCTAssertEqual(hits.first?.matchKind, .related)

        try await database.checkpoint()
        for suffix in ["", "-wal", "-shm"] {
            let candidate = URL(fileURLWithPath: url.path + suffix)
            guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
            let raw = try Data(contentsOf: candidate)
            XCTAssertNil(raw.range(of: Data("Probability and entropy".utf8)))
        }
    }

    func testSourceMutationAndDeletionInvalidateRelatedResults() async throws {
        let url = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let database = try SQLCipherDatabase(
            url: url,
            key: Data(0 ..< 32),
            semanticEmbeddingProvider: TestSemanticEmbeddingProvider()
        )
        let noteId = UUID()
        _ = try await database.saveLocal(
            id: noteId,
            entityType: .note,
            content: Data("first".utf8),
            search: SearchDocument(title: "Entropy", body: "Random variables")
        )
        let initialHits = try await database.search("uncertainty predictions")
        XCTAssertEqual(initialHits.first?.id, noteId)

        _ = try await database.saveLocal(
            id: noteId,
            entityType: .note,
            content: Data("second".utf8),
            search: SearchDocument(title: "Garden", body: "Healthy soil helps plants grow.")
        )
        let staleHits = try await database.search("uncertainty predictions")
        let updatedHits = try await database.search("garden soil")
        XCTAssertTrue(staleHits.isEmpty)
        XCTAssertEqual(updatedHits.first?.id, noteId)

        try await database.deleteLocal(id: noteId)
        let deletedHits = try await database.search("garden soil")
        XCTAssertTrue(deletedHits.isEmpty)
    }

    func testChunkAndVectorRepresentationAreBoundedAndDeterministic() {
        let body = (0 ..< 30).map { "Paragraph \($0) " + String(repeating: "word ", count: 220) }
            .joined(separator: "\n")
        let chunks = LocalSemanticSearch.chunks(
            for: SearchDocument(title: "Long source", body: body)
        )
        XCTAssertLessThanOrEqual(chunks.count, LocalSemanticSearch.maximumChunksPerDocument)
        XCTAssertTrue(chunks.allSatisfy {
            $0.snippet.count <= LocalSemanticSearch.maximumSnippetCharacters
        })

        let vector = LocalSemanticSearch.normalized([3, 4, 0])!
        XCTAssertEqual(LocalSemanticSearch.decode(
            LocalSemanticSearch.encode(vector),
            dimension: vector.count
        ), vector)
        XCTAssertEqual(
            try XCTUnwrap(LocalSemanticSearch.similarity(vector, vector)),
            1,
            accuracy: 0.0001
        )
        XCTAssertNil(LocalSemanticSearch.normalized([.nan]))
    }
}

private struct TestSemanticEmbeddingProvider: LocalSemanticEmbeddingProviding {
    private let model = LocalSemanticEmbeddingModel(language: "test", revision: 1, dimension: 3)

    var isAvailable: Bool { true }

    func model(for _: String) -> LocalSemanticEmbeddingModel? { model }

    func vector(for text: String, model: LocalSemanticEmbeddingModel) -> [Float]? {
        guard model == self.model else { return nil }
        let lowercased = text.lowercased()
        if ["probability", "entropy", "random", "uncertainty", "prediction"].contains(where: lowercased.contains) {
            return [1, 0, 0]
        }
        if ["garden", "soil", "plant"].contains(where: lowercased.contains) {
            return [0, 1, 0]
        }
        return [0, 0, 1]
    }
}

private struct UnavailableSemanticEmbeddingProvider: LocalSemanticEmbeddingProviding {
    var isAvailable: Bool { false }
    func model(for _: String) -> LocalSemanticEmbeddingModel? { nil }
    func vector(for _: String, model _: LocalSemanticEmbeddingModel) -> [Float]? { nil }
}
