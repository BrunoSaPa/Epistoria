import EpistoriaCore
import Testing
import Foundation
@testable import Epistoria

@MainActor
struct NoteReadingPositionTests {
    @Test func jumpHistoryReturnsLatestValidLocationAndRemainsBounded() {
        let first = UUID(), removed = UUID()
        var history = NotebookJumpHistory()
        let position = NoteReadingPosition(pageId: first, fraction: 0.4)
        history.record(.page(position))
        history.record(.page(NoteReadingPosition(pageId: removed, fraction: 0.2)))
        #expect(history.previous(pageIds: [first], infinite: false) == .page(position))
        #expect(history.isEmpty)
        for index in 0..<30 {
            history.record(.canvas(NoteCanvasViewport(centerX: Double(index), centerY: -200, zoom: 2)))
        }
        #expect(history.locations.count == 20)
        if case let .canvas(viewport) = history.previous(pageIds: [], infinite: true) {
            #expect(viewport.centerX == 29)
            #expect(viewport.zoom == 2)
        } else { Issue.record("Expected latest canvas view") }
        #expect(history.previous(pageIds: [first], infinite: false) == nil)
    }

    @Test func infiniteViewportPersistsWithoutOutboxAndRejectsLateOrInvalidWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("viewport.sqlite")
        let key = Data(repeating: 45, count: 32)
        let database = try SQLCipherDatabase(url: url, key: key)
        let id = UUID()
        let saved = NoteCanvasViewport(centerX: -40_000, centerY: 15_000, zoom: 2,
                                       recordedAt: Date(timeIntervalSince1970: 100))
        try await database.saveNoteCanvasViewport(noteId: id, viewport: saved)
        try await database.saveNoteCanvasViewport(noteId: id, viewport:
            NoteCanvasViewport(centerX: 0, centerY: 0, zoom: 1, recordedAt: Date(timeIntervalSince1970: 50)))
        try await database.saveNoteCanvasViewport(noteId: id, viewport:
            NoteCanvasViewport(centerX: .infinity, centerY: 0, zoom: 1))
        let reopened = try SQLCipherDatabase(url: url, key: key)
        #expect(try await reopened.noteCanvasViewport(noteId: id) == saved)
        #expect(try await reopened.pendingMutations().isEmpty)
        #expect(!NoteCanvasViewport(centerX: 0, centerY: 0, zoom: 0).isValid)
        #expect(!NoteCanvasViewport(centerX: 1e100, centerY: 0, zoom: 1).isValid)
    }

    @Test func currentPageUsesVisibleContentNotLazyPageFrames() {
        // The top is still on page one, but the viewport center is on page two.
        #expect(ContinuousNotebookPageSelection.nearestPage(
            heights: [1400, 1400], offset: 1320, viewportHeight: 900) == 1)
        // A tall page containing the center stays current even beside a short page.
        #expect(ContinuousNotebookPageSelection.nearestPage(
            heights: [2000, 200], offset: 1400, viewportHeight: 800) == 0)
        #expect(ContinuousNotebookPageSelection.nearestPage(
            heights: [], offset: 0, viewportHeight: 900) == nil)
        #expect(ContinuousNotebookPageSelection.nearestPage(
            heights: [1000], offset: .nan, viewportHeight: 900) == nil)
    }

    @Test func stablePageAndFractionSurviveReorderingAndResizing() throws {
        let first = UUID(), second = UUID()
        let saved = try #require(ContinuousNotebookPageSelection.readingPosition(
            pageIds: [first, second], heights: [1000, 800], offset: 1424))
        #expect(saved.pageId == second)
        #expect(saved.fraction == 0.5)
        #expect(ContinuousNotebookPageSelection.offset(for: saved, pageIds: [second, first], heights: [400, 500]) == 208)
        #expect(ContinuousNotebookPageSelection.pageWidth(viewportWidth: 1400) == 1384)
        #expect(ContinuousNotebookPageSelection.pageWidth(viewportWidth: 250) == 234)
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
