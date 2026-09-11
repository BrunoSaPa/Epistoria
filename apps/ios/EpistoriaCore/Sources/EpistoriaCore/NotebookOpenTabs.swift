import Foundation

/// Device-local navigation, outside encrypted entities, outbox, and readable export.
public struct NotebookOpenTabs: Codable, Equatable, Sendable {
    public private(set) var noteIds: [UUID]
    public private(set) var selectedId: UUID?

    public init(noteIds: [UUID] = [], selectedId: UUID? = nil) {
        var seen = Set<UUID>()
        self.noteIds = noteIds.filter { seen.insert($0).inserted }
        self.selectedId = selectedId.flatMap { self.noteIds.contains($0) ? $0 : nil } ?? self.noteIds.first
    }

    public mutating func open(_ id: UUID) {
        if !noteIds.contains(id) { noteIds.append(id) }
        selectedId = id
    }

    public mutating func close(_ id: UUID) {
        guard let index = noteIds.firstIndex(of: id) else { return }
        noteIds.remove(at: index)
        if selectedId == id {
            selectedId = noteIds.isEmpty ? nil : noteIds[min(index, noteIds.count - 1)]
        }
    }

    public mutating func retainAvailable(_ available: Set<UUID>) {
        self = Self(noteIds: noteIds.filter { available.contains($0) }, selectedId: selectedId)
    }
}
