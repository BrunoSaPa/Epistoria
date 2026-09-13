import Foundation
import Testing
@testable import EpistoriaCore

struct AtomicEditExpectationTests {
    @Test func groupMoveUndoAndRedoPreserveSpacingAndRejectLaterEdits() async throws {
        let (db, directory) = try database()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EpistoriaStore(database: db)
        let noteId = try await store.save(payload: NotePayload(title: "Move", canvas: NoteCanvasConfiguration(pageFormat: .infinite)))
        var block = NoteBlockPayload(noteId: noteId, blockType: .text, orderKey: "a", plainText: "Preserved")
        block.evidenceId = UUID()
        block.canvasPlacement = NoteCanvasPlacement(x: -50, y: 100, width: 120, height: 80, rotationRadians: 0.4)
        let first = try await store.save(payload: block, parentId: noteId)
        block.canvasPlacement?.x = 250
        let second = try await store.save(payload: block, parentId: noteId)
        let selected = try await [#require(db.entity(id: first)), #require(db.entity(id: second))]
        let move = try await store.moveCanvasObjects(selected: selected, noteId: noteId, deltaX: 75, deltaY: -20)
        for (old, new) in zip(move.before, move.after) {
            let original = try CanonicalJSON.decode(NoteBlockPayload.self, from: old.content)
            let moved = try CanonicalJSON.decode(NoteBlockPayload.self, from: new.content)
            #expect(moved.canvasPlacement?.x == (original.canvasPlacement?.x ?? 0) + 75)
            #expect(moved.canvasPlacement?.y == (original.canvasPlacement?.y ?? 0) - 20)
            #expect(moved.canvasPlacement?.rotationRadians == original.canvasPlacement?.rotationRadians)
            #expect(moved.evidenceId == original.evidenceId && moved.plainText == original.plainText)
        }
        for mutation in try await db.pendingMutations() {
            try await db.markAccepted(mutationId: mutation.mutationId, revision: 4)
        }
        let undo = try await store.undoCanvasObjectMove(move)
        #expect(try await store.payload(NoteBlockPayload.self, id: first).payload.canvasPlacement?.x == -50)
        let redo = try await store.undoCanvasObjectMove(undo)
        #expect(try await store.payload(NoteBlockPayload.self, id: first).payload.canvasPlacement?.x == 25)
        var edited = try await store.payload(NoteBlockPayload.self, id: second).payload
        edited.plainText = "Later edit"
        _ = try await store.save(id: second, payload: edited, parentId: noteId)
        let before = try await db.pendingMutations()
        await #expect(throws: LocalDatabaseError.staleLocalEdit) { try await store.undoCanvasObjectMove(redo) }
        #expect(try await db.pendingMutations() == before)
        #expect(try await store.payload(NoteBlockPayload.self, id: first).payload.canvasPlacement?.x == 25)
    }

    @Test func undoDuplicateAllowsSyncAcknowledgementButUsesCurrentBaseRevision() async throws {
        let (db, directory) = try database()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EpistoriaStore(database: db)
        let noteId = try await store.save(payload: NotePayload(title: "Synced copies", canvas: NoteCanvasConfiguration(pageFormat: .infinite)))
        var block = NoteBlockPayload(noteId: noteId, blockType: .text, orderKey: "a", plainText: "Keep original")
        block.canvasPlacement = NoteCanvasPlacement(x: 20, y: 20, width: 100, height: 100)
        let id = try await store.save(payload: block, parentId: noteId)
        let selected = try #require(await db.entity(id: id))
        let copies = try await store.duplicateCanvasObjects(selected: [selected], noteId: noteId)
        for mutation in try await db.pendingMutations() {
            try await db.markAccepted(mutationId: mutation.mutationId, revision: 7)
        }
        _ = try await store.moveCanvasObjectsToTrash(selected: copies, noteId: noteId)
        let copiedId = try #require(copies.first?.id)
        let mutation = try #require(await db.pendingMutations().first { $0.entityId == copiedId })
        #expect(mutation.baseRevision == 7)
        #expect(try await store.payload(NoteBlockPayload.self, id: copiedId).payload.tombstone)
        #expect(try await store.payload(NoteBlockPayload.self, id: id).payload.tombstone == false)
    }

    @Test func availableExpectationNeverOverwritesAConflict() async throws {
        let (db, directory) = try database()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        _ = try await db.saveLocal(id: id, entityType: .noteBlock, content: Data("original".utf8))
        let selected = try #require(await db.entity(id: id))
        let pending = try #require(await db.pendingMutations().first)
        try await db.markConflict(mutationId: pending.mutationId, serverConflictId: UUID())
        let conflicted = try await db.entity(id: id)
        let before = try await db.pendingMutations()
        await #expect(throws: LocalDatabaseError.staleLocalEdit) {
            try await db.saveLocalBatch([LocalEntityWrite(id: id, entityType: .noteBlock, content: Data("replacement".utf8))], expecting: [.available(selected)])
        }
        #expect(try await db.entity(id: id) == conflicted)
        #expect(try await db.pendingMutations() == before)
    }

    @Test(arguments: [0.0000001, 123456789.1234567, 810000000.1234567])
    func duplicateGroupReusesReferencesAndLeavesOriginalsUnchanged(referenceSeconds: Double) async throws {
        let (db, directory) = try database()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EpistoriaStore(database: db)
        let noteId = try await store.save(payload: NotePayload(title: "Copies", canvas: NoteCanvasConfiguration(pageFormat: .infinite)))
        var block = NoteBlockPayload(noteId: noteId, blockType: .image, orderKey: "a")
        block.assetId = UUID()
        block.evidenceId = UUID()
        block.canvasPlacement = NoteCanvasPlacement(x: -100, y: 50, width: 200, height: 100, rotationRadians: 0.5)
        let first = try await store.save(payload: block, parentId: noteId)
        block.orderKey = "b"
        block.canvasPlacement?.x = 300
        let second = try await store.save(payload: block, parentId: noteId)
        let selected = try await [#require(db.entity(id: first)), #require(db.entity(id: second))]
        let copies = try await store.duplicateCanvasObjects(selected: selected, noteId: noteId,
            at: Date(timeIntervalSinceReferenceDate: referenceSeconds))
        #expect(copies.count == 2)
        #expect(Set(copies.map(\.id)).isDisjoint(with: [first, second]))
        for (original, copy) in zip(selected, copies) {
            let source = try CanonicalJSON.decode(NoteBlockPayload.self, from: original.content)
            let result = try CanonicalJSON.decode(NoteBlockPayload.self, from: copy.content)
            #expect(result.assetId == source.assetId && result.evidenceId == source.evidenceId)
            #expect(result.canvasPlacement?.x == (source.canvasPlacement?.x ?? 0) + 24)
            #expect(result.canvasPlacement?.rotationRadians == source.canvasPlacement?.rotationRadians)
            #expect(try await db.entity(id: original.id) == original)
            #expect(try await db.entity(id: copy.id) == copy)
        }
        _ = try await store.moveCanvasObjectsToTrash(selected: copies, noteId: noteId)
        #expect(try await store.payload(NoteBlockPayload.self, id: first).payload.tombstone == false)
        let pending = try await db.pendingMutations()
        _ = try await store.save(id: first, payload: block, parentId: noteId)
        let beforeRejectedCopy = try await db.pendingMutations()
        await #expect(throws: LocalDatabaseError.staleLocalEdit) {
            try await store.duplicateCanvasObjects(selected: selected, noteId: noteId)
        }
        #expect(try await db.pendingMutations() == beforeRejectedCopy)
        #expect(beforeRejectedCopy.count == pending.count)
    }

    @Test func mixedObjectAndInkLayerDeletionFailsWithoutChangingEither() async throws {
        let (db, directory) = try database()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EpistoriaStore(database: db)
        let noteId = try await store.save(payload: NotePayload(title: "Ink guard", canvas: NoteCanvasConfiguration(pageFormat: .infinite)))
        let object = NoteBlockPayload(noteId: noteId, blockType: .text, orderKey: "a", plainText: "Keep this object")
        var ink = NoteBlockPayload(noteId: noteId, blockType: .handwriting, orderKey: "b")
        ink.canvasRole = .inkLayer
        ink.drawingData = Data([1, 2, 3, 4])
        let objectId = try await store.save(payload: object, parentId: noteId)
        let inkId = try await store.save(payload: ink, parentId: noteId)
        let selected = try await [#require(db.entity(id: objectId)), #require(db.entity(id: inkId))]
        let pending = try await db.pendingMutations()
        await #expect(throws: LocalDatabaseError.invalidRow) {
            try await store.moveCanvasObjectsToTrash(selected: selected, noteId: noteId)
        }
        #expect(try await db.entity(id: objectId) == selected[0])
        #expect(try await db.entity(id: inkId) == selected[1])
        #expect(try await db.pendingMutations() == pending)
        #expect(try await store.trashEntries().isEmpty)
    }

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
        let parentTrash = try await store.moveToTrash(targetId: noteId, targetType: .note, displayName: "Parent")
        let pendingBeforeRestore = try await db.pendingMutations()
        await #expect(throws: LocalDatabaseError.staleLocalEdit) {
            try await store.restoreCanvasObjectGroup(entryIds: entries)
        }
        #expect(try await db.pendingMutations() == pendingBeforeRestore)
        #expect(try await store.payload(NoteBlockPayload.self, id: first).payload.tombstone)
        try await store.restoreTrashEntry(id: parentTrash)
        try await store.restoreCanvasObjectGroup(entryIds: entries)
        #expect(try await store.payload(NoteBlockPayload.self, id: first).payload.tombstone == false)
        #expect(try await store.payload(NoteBlockPayload.self, id: second).payload.tombstone == false)
        #expect(try await store.payload(NoteBlockPayload.self, id: second).payload.plainText == "Newer content")
        #expect(try await store.trashEntries().isEmpty)
        let pendingAfterRestore = try await db.pendingMutations()
        await #expect(throws: LocalDatabaseError.staleLocalEdit) {
            try await store.restoreCanvasObjectGroup(entryIds: entries)
        }
        #expect(try await db.pendingMutations() == pendingAfterRestore)
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
