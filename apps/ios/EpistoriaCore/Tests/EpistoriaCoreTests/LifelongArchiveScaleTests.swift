import Foundation
import XCTest
@testable import EpistoriaCore

final class LifelongArchiveScaleTests: XCTestCase {
    struct Scale {
        var notes: Int
        var sources: Int
        var pages: Int
        var searchSegments: Int
        var learningHistory: Int

        static let smoke = Scale(
            notes: 50,
            sources: 20,
            pages: 250,
            searchSegments: 1_000,
            learningHistory: 500
        )

        static let lifelong = Scale(
            notes: 5_000,
            sources: 2_000,
            pages: 25_000,
            searchSegments: 100_000,
            learningHistory: 50_000
        )
    }

    func testScaleFixtureKeepsPrimaryReadsBounded() async throws {
        let fixture = try await makeFixture(scale: .smoke)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let store = EpistoriaStore(database: fixture.database)
        let snapshot = try await store.workspaceSnapshot(
            limits: WorkspaceReadLimits(notes: 12, lists: 1, sources: 8, topics: 8, sessions: 1)
        )
        XCTAssertEqual(snapshot.notes.items.count, 12)
        XCTAssertNotNil(snapshot.notes.nextCursor)
        XCTAssertEqual(snapshot.sources.items.count, 8)
        XCTAssertNotNil(snapshot.sources.nextCursor)

        let firstPage = try await store.listPage(NotePagePayload.self, limit: 40)
        XCTAssertEqual(firstPage.items.count, 40)
        XCTAssertNotNil(firstPage.nextCursor)

        let hits = try await fixture.database.search("lifelongneedle997")
        XCTAssertEqual(hits.first?.entity.entityType, .note)

        try await fixture.database.invalidateWorkspaceSummary()
        try await fixture.database.rebuildWorkspaceSummary()
        let rebuilt = try await store.workspaceSnapshot(
            limits: WorkspaceReadLimits(notes: 12, lists: 1, sources: 8, topics: 8, sessions: 1)
        )
        XCTAssertEqual(rebuilt.notes.items.map(\.id), snapshot.notes.items.map(\.id))
        XCTAssertEqual(rebuilt.sources.items.map(\.id), snapshot.sources.items.map(\.id))
    }

    func testFullLifelongArchiveScaleWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["EPISTORIA_RUN_SCALE_TESTS"] == "1" else {
            throw XCTSkip("Set EPISTORIA_RUN_SCALE_TESTS=1 to build the full lifelong archive fixture.")
        }
        let populationStart = ContinuousClock.now
        let fixture = try await makeFixture(scale: .lifelong)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let populationDuration = populationStart.duration(to: .now)
        let store = EpistoriaStore(database: fixture.database)

        let snapshotStart = ContinuousClock.now
        let snapshot = try await store.workspaceSnapshot()
        let snapshotDuration = snapshotStart.duration(to: .now)
        XCTAssertEqual(snapshot.notes.items.count, 50)
        XCTAssertNotNil(snapshot.notes.nextCursor)
        XCTAssertEqual(snapshot.sources.items.count, 50)
        XCTAssertNotNil(snapshot.sources.nextCursor)

        let searchStart = ContinuousClock.now
        let hits = try await fixture.database.search(
            "lifelongneedle99991",
            includeRelated: false
        )
        let searchDuration = searchStart.duration(to: .now)
        XCTAssertEqual(hits.first?.entity.entityType, .note)

        let rebuildStart = ContinuousClock.now
        try await fixture.database.invalidateWorkspaceSummary()
        try await fixture.database.rebuildWorkspaceSummary()
        let rebuildDuration = rebuildStart.duration(to: .now)
        let rebuilt = try await store.workspaceSnapshot()
        XCTAssertEqual(rebuilt.notes.items.map(\.id), snapshot.notes.items.map(\.id))

        print(
            "LIFELONG_SCALE population=\(populationDuration) "
                + "snapshot=\(snapshotDuration) search=\(searchDuration) "
                + "summaryRebuild=\(rebuildDuration)"
        )
    }

    private struct Fixture {
        var directory: URL
        var database: SQLCipherDatabase
    }

    private func makeFixture(scale: Scale) async throws -> Fixture {
        precondition(scale.notes > 0 && scale.pages >= scale.notes)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EpistoriaLifelongScale-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try SQLCipherDatabase(
            url: directory.appendingPathComponent("lifelong.sqlite"),
            key: Data(repeating: 91, count: 32)
        )
        let base = Date(timeIntervalSince1970: 1_900_000_000)
        let topicCount = min(max(scale.notes / 100, 1), 50)
        let topicIds = (0 ..< topicCount).map { fixtureId(kind: 1, index: $0) }

        try await writeBatches(count: topicCount, database: database) { index in
            let payload = TopicPayload(name: "Topic \(index)", now: base.addingTimeInterval(Double(index)))
            return LocalEntityWrite(
                id: topicIds[index],
                entityType: .topic,
                content: try CanonicalJSON.encode(payload),
                modifiedAt: payload.updatedAt
            )
        }

        let noteIds = (0 ..< scale.notes).map { fixtureId(kind: 2, index: $0) }
        try await writeBatches(count: scale.notes, database: database) { index in
            let topicId = topicIds[index % topicIds.count]
            let payload = NotePayload(
                title: "Archive note \(index)",
                topicId: topicId,
                now: base.addingTimeInterval(Double(index))
            )
            return LocalEntityWrite(
                id: noteIds[index],
                entityType: .note,
                parentId: topicId,
                relationIds: [topicId],
                content: try CanonicalJSON.encode(payload),
                modifiedAt: payload.updatedAt
            )
        }

        var pageIdsByNote = Array(repeating: [UUID](), count: scale.notes)
        let pageIds = (0 ..< scale.pages).map { index -> UUID in
            let id = fixtureId(kind: 3, index: index)
            pageIdsByNote[index % scale.notes].append(id)
            return id
        }
        try await writeBatches(count: scale.pages, database: database) { index in
            let noteIndex = index % scale.notes
            let pageNumber = index / scale.notes
            let payload = NotePagePayload(
                noteId: noteIds[noteIndex],
                orderKey: String(format: "%012d", pageNumber * 1_000),
                configuration: NoteCanvasConfiguration(),
                now: base.addingTimeInterval(Double(index))
            )
            return LocalEntityWrite(
                id: pageIds[index],
                entityType: .notePage,
                parentId: noteIds[noteIndex],
                relationIds: [noteIds[noteIndex]],
                content: try CanonicalJSON.encode(payload),
                modifiedAt: payload.updatedAt
            )
        }

        try await writeBatches(count: scale.sources, database: database) { index in
            let topicId = topicIds[index % topicIds.count]
            let payload = SourcePayload(
                sourceType: .pdf,
                title: "Archive Source \(index)",
                primaryTopicId: topicId,
                now: base.addingTimeInterval(Double(index))
            )
            return LocalEntityWrite(
                id: fixtureId(kind: 4, index: index),
                entityType: .source,
                parentId: topicId,
                relationIds: [topicId],
                content: try CanonicalJSON.encode(payload),
                modifiedAt: payload.updatedAt
            )
        }

        let segmentsPerNote = max(
            Int(ceil(Double(scale.searchSegments) / Double(scale.notes))),
            1
        )
        try await writeBatches(count: scale.searchSegments, database: database) { index in
            // Real note imports normally write adjacent blocks together. Keeping each note's
            // segments adjacent also verifies that one atomic batch rebuilds that owner once.
            let noteIndex = min(index / segmentsPerNote, scale.notes - 1)
            let segmentIndexInNote = index % segmentsPerNote
            let noteId = noteIds[noteIndex]
            let pageIds = pageIdsByNote[noteIndex]
            let pageId = pageIds[segmentIndexInNote % pageIds.count]
            let blockId = fixtureId(kind: 5, index: index)
            let searchableText = "lifelongneedle\(index) synthetic notebook content"
            var payload = NoteBlockPayload(
                noteId: noteId,
                blockType: .text,
                orderKey: String(format: "%012d", segmentIndexInNote * 1_000),
                plainText: searchableText,
                now: base.addingTimeInterval(Double(index))
            )
            payload.pageId = pageId
            let segment = SearchSegmentWrite(
                id: blockId,
                ownerEntityId: noteId,
                sourceEntityId: blockId,
                origin: .writtenText,
                reviewState: .authored,
                authority: 100,
                title: "Archive note \(noteIndex)",
                body: searchableText,
                locator: SearchSegmentLocator(targetId: blockId, pageNumber: nil),
                contentRevision: 1,
                updatedAt: payload.updatedAt
            )
            return LocalEntityWrite(
                id: blockId,
                entityType: .noteBlock,
                parentId: noteId,
                relationIds: [noteId, pageId],
                content: try CanonicalJSON.encode(payload),
                searchProjection: SearchProjectionWrite(sourceEntityId: blockId, segments: [segment]),
                modifiedAt: payload.updatedAt
            )
        }

        let cardCount = min(max(scale.learningHistory / 20, 1), 1_000)
        let cardIds = (0 ..< cardCount).map { fixtureId(kind: 6, index: $0) }
        let revisionIds = (0 ..< cardCount).map { fixtureId(kind: 7, index: $0) }
        try await writeBatches(count: cardCount, database: database) { index in
            let topicId = topicIds[index % topicIds.count]
            let payload = FlashcardRevisionPayload(
                cardId: cardIds[index],
                revisionNumber: 1,
                prompt: "Prompt \(index)",
                answer: "Answer \(index)",
                now: base.addingTimeInterval(Double(index))
            )
            return LocalEntityWrite(
                id: revisionIds[index],
                entityType: .flashcardRevision,
                parentId: cardIds[index],
                relationIds: [cardIds[index], topicId],
                content: try CanonicalJSON.encode(payload),
                modifiedAt: payload.updatedAt
            )
        }
        try await writeBatches(count: cardCount, database: database) { index in
            let topicId = topicIds[index % topicIds.count]
            let payload = FlashcardPayload(
                topicId: topicId,
                currentRevisionId: revisionIds[index],
                kind: .basic,
                now: base.addingTimeInterval(Double(index))
            )
            return LocalEntityWrite(
                id: cardIds[index],
                entityType: .flashcard,
                parentId: topicId,
                relationIds: [topicId, revisionIds[index]],
                content: try CanonicalJSON.encode(payload),
                modifiedAt: payload.updatedAt
            )
        }
        try await writeBatches(count: scale.learningHistory, database: database) { index in
            let cardIndex = index % cardCount
            let reviewedAt = base.addingTimeInterval(Double(index))
            let payload = FlashcardReviewPayload(
                cardId: cardIds[cardIndex],
                cardRevisionId: revisionIds[cardIndex],
                rating: FlashcardRating(rawValue: index % 4) ?? .good,
                previousState: FlashcardScheduleState(dueAt: reviewedAt),
                resultingState: FlashcardScheduleState(
                    dueAt: reviewedAt.addingTimeInterval(Double((index % 14) + 1) * 86_400),
                    intervalDays: (index % 14) + 1
                ),
                responseMilliseconds: 1_000 + index % 10_000,
                now: reviewedAt
            )
            return LocalEntityWrite(
                id: fixtureId(kind: 8, index: index),
                entityType: .flashcardReview,
                parentId: cardIds[cardIndex],
                relationIds: [cardIds[cardIndex], revisionIds[cardIndex]],
                content: try CanonicalJSON.encode(payload),
                modifiedAt: payload.updatedAt
            )
        }

        return Fixture(directory: directory, database: database)
    }

    private func writeBatches(
        count: Int,
        batchSize: Int = 250,
        database: SQLCipherDatabase,
        makeWrite: (Int) throws -> LocalEntityWrite
    ) async throws {
        for start in stride(from: 0, to: count, by: batchSize) {
            let end = min(start + batchSize, count)
            let writes = try (start ..< end).map(makeWrite)
            try await database.saveLocalBatch(writes)
        }
    }

    private func fixtureId(kind: UInt32, index: Int) -> UUID {
        let value = String(
            format: "%08X-0000-4000-8000-%012llX",
            kind,
            UInt64(index + 1)
        )
        return UUID(uuidString: value)!
    }
}
