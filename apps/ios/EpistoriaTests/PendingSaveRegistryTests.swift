@testable import Epistoria
import XCTest

@MainActor
final class PendingSaveRegistryTests: XCTestCase {
    func testFlushUsesNewestSnapshotForAnIdentifier() async throws {
        let registry = PendingSaveRegistry()
        var persisted: [String] = []
        let id = UUID()

        registry.stage(id: id) { persisted.append("old") }
        registry.stage(id: id) { persisted.append("new") }

        try await registry.flush(id: id)

        XCTAssertEqual(persisted, ["new"])
        XCTAssertEqual(registry.count, 0)
    }

    func testFlushAllKeepsSnapshotStagedDuringAnAwaitedWrite() async throws {
        let registry = PendingSaveRegistry()
        var persisted: [String] = []
        let id = UUID()

        registry.stage(id: id) {
            persisted.append("first")
            registry.stage(id: id) { persisted.append("newer") }
        }

        try await registry.flushAll()

        XCTAssertEqual(persisted, ["first", "newer"])
        XCTAssertEqual(registry.count, 0)
    }

    func testDiscardPreventsAWrite() async throws {
        let registry = PendingSaveRegistry()
        var didPersist = false
        let id = UUID()
        registry.stage(id: id) { didPersist = true }
        registry.discard(id: id)

        try await registry.flushAll()

        XCTAssertFalse(didPersist)
    }

    func testFailedWriteIsRetainedAndCanBeRetried() async throws {
        enum ExpectedFailure: Error { case write }
        let registry = PendingSaveRegistry()
        let id = UUID()
        var attempts = 0
        registry.stage(id: id) {
            attempts += 1
            if attempts == 1 { throw ExpectedFailure.write }
        }

        do {
            try await registry.flush(id: id)
            XCTFail("Expected the first save to fail")
        } catch is ExpectedFailure {
            // Expected.
        }
        XCTAssertEqual(registry.count, 1)

        try await registry.flush(id: id)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(registry.count, 0)
    }

    func testSuccessfulOlderWriteDoesNotRemoveNewerSnapshot() async throws {
        let registry = PendingSaveRegistry()
        let id = UUID()
        var persisted: [String] = []
        registry.stage(id: id) {
            persisted.append("old")
            registry.stage(id: id) { persisted.append("new") }
        }

        try await registry.flush(id: id)
        XCTAssertEqual(registry.count, 1)
        try await registry.flush(id: id)

        XCTAssertEqual(persisted, ["old", "new"])
        XCTAssertEqual(registry.count, 0)
    }

    func testOverlappingFlushesSerializeSoNewestSnapshotFinishesLast() async throws {
        let registry = PendingSaveRegistry()
        let id = UUID()
        var releaseOlder: CheckedContinuation<Void, Never>?
        var persisted: [String] = []
        registry.stage(id: id) {
            await withCheckedContinuation { releaseOlder = $0 }
            persisted.append("old")
        }
        let olderFlush = Task { try await registry.flush(id: id) }
        while releaseOlder == nil { await Task.yield() }

        registry.stage(id: id) { persisted.append("new") }
        let newerFlush = Task { try await registry.flush(id: id) }
        await Task.yield()
        XCTAssertTrue(persisted.isEmpty)

        releaseOlder?.resume()
        try await olderFlush.value
        try await newerFlush.value

        XCTAssertEqual(persisted, ["old", "new"])
        XCTAssertEqual(registry.count, 0)
    }
}
