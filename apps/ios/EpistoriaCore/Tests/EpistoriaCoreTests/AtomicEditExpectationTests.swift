import Foundation
import Testing
@testable import EpistoriaCore

struct AtomicEditExpectationTests {
    @Test func trashedParentCannotAuthorizeGroupDeletion() async throws {
        let (db, directory) = try database()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EpistoriaStore(database: db)
        let noteId = try await store.save(payload: NotePayload(title: "Parent"))
        let blockId = try await store.save(payload: NoteBlockPayload(noteId: noteId, blockType: .text, orderKey: "a"), parentId: noteId)
        let selected = try #require(await db.entity(id: blockId))
        _ = try await store.moveToTrash(targetId: noteId, targetType: .note, displayName: "Parent")
        let pending = try await db.pendingMutations()
        await #expect(throws: LocalDatabaseError.staleLocalEdit) {
            try await store.moveCanvasObjectsToTrash(selected: [selected], noteId: noteId)
        }
        #expect(try await db.entity(id: blockId) == selected)
        #expect(try await db.pendingMutations() == pending)
    }

    @Test func groupedObjectTrashPreservesOriginalsAndRejectsStaleSelection() async throws {
        let (db, directory) = try database()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EpistoriaStore(database: db)
        let noteId = try await store.save(payload: NotePayload(title: "Group", canvas: NoteCanvasConfiguration(pageFormat: .infinite)))
        var block = NoteBlockPayload(noteId: noteId, blockType: .text, orderKey: "a", plainText: "Original")
        let first = try await store.save(payload: block, parentId: noteId)
        let second = try await store.save(payload: block, parentId: noteId)
        let snapshot = try await [#require(db.entity(id: first)), #require(db.entity(id: second))]
        block.plainText = "Newer content"
        _ = try await store.save(id: second, payload: block, parentId: noteId)
        await #expect(throws: LocalDatabaseError.staleLocalEdit) {
            try await store.moveCanvasObjectsToTrash(selected: snapshot, noteId: noteId)
        }
        #expect(try await store.trashEntries().isEmpty)
        #expect(try await store.payload(NoteBlockPayload.self, id: first).payload.tombstone == false)
        let current = try await [#require(db.entity(id: first)), #require(db.entity(id: second))]
        let entries = try await store.moveCanvasObjectsToTrash(selected: current, noteId: noteId)
        #expect(entries.count == 2)
        let trash = try await store.trashEntries()
        #expect(Set(trash.map(\.payload.deletionGroupId)).count == 1)
        #expect(try await store.payload(NoteBlockPayload.self, id: first).payload.plainText == "Original")
        #expect(try await store.payload(NoteBlockPayload.self, id: second).payload.plainText == "Newer content")
        #expect(try await store.payload(NoteBlockPayload.self, id: second).payload.tombstone)
    }
    private func database() throws -> (SQLCipherDatabase, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AtomicEditTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (try SQLCipherDatabase(url: directory.appendingPathComponent("notebook.sqlite"),
            key: Data(repeating: 42, count: 32)), directory)
    }

    @Test func interveningLocalEditWithSameSyncRevisionRejectsEntireGroup() async throws {
        let (db, directory) = try database()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = UUID(), second = UUID()
        let original = Data("original".utf8), replacement = Data("replacement".utf8)
        _ = try await db.saveLocal(id: first, entityType: .noteBlock, content: original)
        _ = try await db.saveLocal(id: second, entityType: .noteBlock, content: original)
        let expectedFirst = try #require(await db.entity(id: first))
        let expectedSecond = try #require(await db.entity(id: second))
        _ = try await db.saveLocal(id: second, entityType: .noteBlock, content: Data("newer".utf8))
        let currentSecond = try #require(await db.entity(id: second))
        #expect(currentSecond.revision == expectedSecond.revision)
        let pending = try await db.pendingMutations()
        await #expect(throws: LocalDatabaseError.staleLocalEdit) {
            try await db.saveLocalBatch([
                LocalEntityWrite(id: first, entityType: .noteBlock, content: replacement),
                LocalEntityWrite(id: second, entityType: .noteBlock, content: replacement)
            ], expecting: [.unchanged(expectedFirst), .unchanged(expectedSecond)])
        }
        #expect(try await db.entity(id: first) == expectedFirst)
        #expect(try await db.entity(id: second) == currentSecond)
        #expect(try await db.pendingMutations() == pending)
    }

    @Test func unchangedGroupWritesAndEnqueuesTogether() async throws {
        let (db, directory) = try database()
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = UUID(), inserted = UUID()
        _ = try await db.saveLocal(id: existing, entityType: .noteBlock, content: Data("before".utf8))
        let expected = try #require(await db.entity(id: existing))
        let content = Data("after".utf8)
        try await db.saveLocalBatch([
            LocalEntityWrite(id: existing, entityType: .noteBlock, content: content),
            LocalEntityWrite(id: inserted, entityType: .noteBlock, content: content)
        ], expecting: [.unchanged(expected), .absent(inserted)])
        #expect(try await db.entity(id: existing)?.content == content)
        #expect(try await db.entity(id: inserted)?.content == content)
        #expect(try await db.pendingMutations().count == 2)
    }

    @Test func absentGuardRejectsExistingTombstoneAndPreservesOtherDeletion() async throws {
        let (db, directory) = try database()
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = UUID(), deleted = UUID()
        _ = try await db.saveLocal(id: existing, entityType: .noteBlock, content: Data())
        _ = try await db.saveLocal(id: deleted, entityType: .noteBlock, content: Data())
        try await db.deleteLocal(id: deleted)
        let pending = try await db.pendingMutations()
        await #expect(throws: LocalDatabaseError.staleLocalEdit) {
            try await db.saveLocalBatch([
                LocalEntityWrite(id: deleted, entityType: .noteBlock, content: Data())
            ], deleting: [existing], expecting: [.absent(deleted)])
        }
        #expect(try await db.entity(id: existing)?.tombstone == false)
        #expect(try await db.entity(id: deleted)?.tombstone == true)
        #expect(try await db.pendingMutations() == pending)
    }
}
