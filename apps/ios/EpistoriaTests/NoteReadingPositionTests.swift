import EpistoriaCore
import Testing
import Foundation
@testable import Epistoria

@MainActor
struct NoteReadingPositionTests {
    @Test func stablePageAndFractionSurviveReorderingAndResizing() throws {
        let first = UUID(), second = UUID()
        let saved = try #require(ContinuousNotebookPageSelection.readingPosition(
            pageIds: [first, second], heights: [1000, 800], offset: 1452))
        #expect(saved.pageId == second)
        #expect(saved.fraction == 0.5)
        #expect(ContinuousNotebookPageSelection.offset(for: saved, pageIds: [second, first], heights: [400, 500]) == 228)
        #expect(ContinuousNotebookPageSelection.offset(for: saved, pageIds: [first], heights: [1000]) == nil)
        #expect(ContinuousNotebookPageSelection.readingPosition(pageIds: [first], heights: [0], offset: 2) == nil)
        #expect(NoteReadingPosition(pageId: first, fraction: .nan).fraction == 0)
    }

    @Test func localPositionSurvivesReopenAndRejectsLateWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("position.sqlite")
        let key = Data(repeating: 41, count: 32)
        let database = try SQLCipherDatabase(url: url, key: key)
        let note = UUID(), page = UUID()
        let saved = NoteReadingPosition(pageId: page, fraction: 0.6, recordedAt: Date(timeIntervalSince1970: 100))
        try await database.saveNoteReadingPosition(noteId: note, position: saved)
        try await database.saveNoteReadingPosition(noteId: note, position: NoteReadingPosition(pageId: page, fraction: 0.1, recordedAt: Date(timeIntervalSince1970: 50)))
        let reopened = try SQLCipherDatabase(url: url, key: key)
        #expect(try await reopened.noteReadingPosition(noteId: note) == saved)
        #expect(try await reopened.noteReadingPosition(noteId: UUID()) == nil)
        #expect(try await reopened.pendingMutations().isEmpty)
    }
}
