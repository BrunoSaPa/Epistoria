import Foundation
import Testing
@testable import EpistoriaCore

struct PageBookmarkTests {
    @Test func optionalMetadataDecodesOlderPages() throws {
        let page = NotePagePayload(noteId: UUID(), orderKey: "0", configuration: NoteCanvasConfiguration())
        let data = try JSONEncoder().encode(page)
        let decoded = try JSONDecoder().decode(NotePagePayload.self, from: data)
        #expect(decoded.title == nil)
        #expect(!decoded.isBookmarked)
    }

    @Test func metadataSurvivesPageOperationsAndReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("pages.sqlite")
        let key = Data(repeating: 71, count: 32)
        let database = try SQLCipherDatabase(url: url, key: key)
        let store = EpistoriaStore(database: database)
        let noteId = try await store.createNote(title: "Pages", canvas: NoteCanvasConfiguration())
        let pages = try await store.notePages(noteId: noteId)
        let pageId = try #require(pages.first?.id)
        try await store.setNotePageTitle(noteId: noteId, pageId: pageId, title: "  Examples  ")
        try await store.setNotePageBookmarked(noteId: noteId, pageId: pageId, bookmarked: true)
        let duplicateId = try await store.duplicateNotePage(noteId: noteId, pageId: pageId)
        let duplicate = try await store.payload(NotePagePayload.self, id: duplicateId)
        #expect(duplicate.payload.title == "Examples")
        #expect(!duplicate.payload.isBookmarked)
        try await store.reorderNotePage(noteId: noteId, pageId: pageId, destinationIndex: 1)
        let trashId = try await store.movePageToTrash(noteId: noteId, pageId: pageId, displayName: "Examples")
        await #expect(throws: (any Error).self) {
            try await store.setNotePageTitle(noteId: noteId, pageId: pageId, title: "Cannot edit trash")
        }
        try await store.restoreTrashEntry(id: trashId)
        let reopened = EpistoriaStore(database: try SQLCipherDatabase(url: url, key: key))
        let restored = try await reopened.payload(NotePagePayload.self, id: pageId)
        #expect(restored.payload.title == "Examples")
        #expect(restored.payload.isBookmarked)
        let roundTrip = try JSONDecoder().decode(NotePagePayload.self, from: JSONEncoder().encode(restored.payload))
        #expect(roundTrip == restored.payload)
        await #expect(throws: (any Error).self) {
            try await store.setNotePageBookmarked(noteId: UUID(), pageId: pageId, bookmarked: false)
        }
        await #expect(throws: (any Error).self) {
            try await store.setNotePageTitle(noteId: noteId, pageId: pageId, title: String(repeating: "x", count: 121))
        }
        try await store.setNotePageTitle(noteId: noteId, pageId: pageId, title: " \n ")
        try await store.setNotePageBookmarked(noteId: noteId, pageId: pageId, bookmarked: false)
        let cleared = try await store.payload(NotePagePayload.self, id: pageId)
        #expect(cleared.payload.title == nil)
        #expect(!cleared.payload.isBookmarked)
    }
}
