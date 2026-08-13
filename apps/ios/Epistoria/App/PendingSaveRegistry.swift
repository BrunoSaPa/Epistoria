import Foundation

/// Keeps the newest unsaved editor snapshot for each block on the main actor.
///
/// Editors stage a snapshot immediately when their content changes. Their normal debounce
/// flushes that snapshot, while AppModel flushes every remaining snapshot before releasing
/// the encrypted database and account key.
@MainActor
final class PendingSaveRegistry {
    typealias Operation = @MainActor () async throws -> Void

    private struct Entry {
        var version: UInt64
        var operation: Operation
    }

    private var operations: [UUID: Entry] = [:]
    private var nextVersion: UInt64 = 0
    private var inFlight: Set<UUID> = []
    private var waiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    var count: Int { operations.count }

    func stage(id: UUID, operation: @escaping Operation) {
        nextVersion &+= 1
        operations[id] = Entry(version: nextVersion, operation: operation)
    }

    func discard(id: UUID) {
        operations[id] = nil
    }

    func flush(id: UUID) async throws {
        if inFlight.contains(id) {
            await withCheckedContinuation { continuation in
                waiters[id, default: []].append(continuation)
            }
            return try await flush(id: id)
        }
        guard let entry = operations[id] else { return }
        inFlight.insert(id)
        do {
            try await entry.operation()
            if operations[id]?.version == entry.version {
                operations[id] = nil
            }
            finishFlight(id: id)
        } catch {
            finishFlight(id: id)
            throw error
        }
    }

    func flushAll() async throws {
        while !operations.isEmpty {
            let identifiers = Array(operations.keys)
            for id in identifiers {
                try await flush(id: id)
            }
        }
    }

    private func finishFlight(id: UUID) {
        inFlight.remove(id)
        let continuations = waiters.removeValue(forKey: id) ?? []
        continuations.forEach { $0.resume() }
    }
}
