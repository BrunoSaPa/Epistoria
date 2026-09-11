import EpistoriaCore
import Foundation
import Testing
@testable import Epistoria

@MainActor
struct NotebookOpenTabsTests {
    @Test func openingAndClosingDoNotDuplicateOrLoseNeighbors() {
        let a = UUID(), b = UUID(), c = UUID()
        var tabs = NotebookOpenTabs(noteIds: [a, b, a, c], selectedId: b)
        #expect(tabs.noteIds == [a, b, c])
        tabs.open(a)
        #expect(tabs.noteIds == [a, b, c])
        tabs.close(b)
        #expect(tabs.selectedId == a)
        tabs.close(a)
        #expect(tabs.selectedId == c)
        tabs.close(c)
        #expect(tabs.selectedId == nil)
        #expect(tabs.noteIds.isEmpty)
    }

    @Test func missingTabsArePrunedWithoutInventingDestinations() {
        let a = UUID(), b = UUID()
        var tabs = NotebookOpenTabs(noteIds: [a, b], selectedId: b)
        tabs.retainAvailable([a])
        #expect(tabs.selectedId == a)
        #expect(tabs.noteIds == [a])
    }

    @Test func tabStateSurvivesReopenWithoutSyncMutations() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("tabs.sqlite")
        let key = Data(repeating: 43, count: 32)
        let database = try SQLCipherDatabase(url: url, key: key)
        let a = UUID(), b = UUID()
        let saved = NotebookOpenTabs(noteIds: [a, b], selectedId: b)
        try await database.saveNotebookOpenTabs(saved)
        let reopened = try SQLCipherDatabase(url: url, key: key)
        #expect(try await reopened.notebookOpenTabs() == saved)
        #expect(try await reopened.pendingMutations().isEmpty)
        try await reopened.saveNotebookOpenTabs(NotebookOpenTabs())
        #expect(try await database.notebookOpenTabs().noteIds.isEmpty)
    }

    @Test func failedDestinationKeepsActiveNoteAndClosingPreservesContent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try SQLCipherDatabase(url: root.appendingPathComponent("session.sqlite"),
                                            key: Data(repeating: 44, count: 32))
        let store = EpistoriaStore(database: database)
        let note = try await store.createNote(title: "Synthetic tab note")
        let original = try await database.entity(id: note)
        let mutations = try await database.pendingMutations()
        let session = NotebookTabSession()
        try await session.load(store: store, opening: note)
        do {
            try await session.complete(.open(UUID()), store: store)
            Issue.record("Missing destination should not open")
        } catch { #expect(error as? StoreError == .entityNotFound) }
        #expect(session.tabs.selectedId == note)
        #expect(try await database.notebookOpenTabs().selectedId == note)
        try await session.complete(.close(note), store: store)
        #expect(session.tabs.selectedId == nil)
        #expect(try await database.entity(id: note) == original)
        #expect(try await database.pendingMutations() == mutations)
    }
}
