import Foundation
import XCTest
@testable import EpistoriaCore

final class ProcessingTests: XCTestCase {
    func testRouterPrefersDeviceThenApprovedProviderThenComputeNode() {
        let router = ProcessingRouter()
        let approval = ProcessingApproval(
            providerProfileId: UUID(),
            expiresAt: Date().addingTimeInterval(60)
        )
        let availability = [
            ProcessingRouteAvailability(
                route: .computeNode,
                capabilities: [.formulaRecognition, .hostedProvider]
            ),
            ProcessingRouteAvailability(
                route: .directProvider,
                capabilities: [.hostedProvider]
            ),
            ProcessingRouteAvailability(
                route: .onDevice,
                capabilities: [.formulaRecognition]
            ),
        ]
        XCTAssertEqual(
            router.route(
                requiredCapabilities: [.formulaRecognition],
                approval: nil,
                availability: availability
            ),
            .onDevice
        )
        XCTAssertEqual(
            router.route(
                requiredCapabilities: [.hostedProvider],
                approval: approval,
                availability: availability
            ),
            .directProvider
        )
        XCTAssertEqual(
            router.route(
                requiredCapabilities: [.hostedProvider],
                approval: nil,
                availability: availability
            ),
            .computeNode
        )
    }

    func testProcessingJobsSurviveRelaunchAndNodeRemovalPreservesWork() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EpistoriaProcessingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("epistoria.sqlite")
        let key = Data(0 ..< 32)
        let nodeId = UUID()
        let original = ProcessingJob(
            kind: "TRANSCRIPTION",
            inputEntityId: UUID(),
            inputRevision: 2,
            inputFingerprint: String(repeating: "a", count: 64),
            requiredCapabilities: [.transcription],
            selectedRoute: .computeNode,
            computeNodeId: nodeId
        )
        var database: SQLCipherDatabase? = try SQLCipherDatabase(url: url, key: key)
        _ = try await database?.saveProcessingJob(original)
        _ = try await database?.transitionProcessingJob(
            id: original.id,
            to: .running,
            route: .computeNode,
            computeNodeId: nodeId
        )
        database = nil

        let reopened = try SQLCipherDatabase(url: url, key: key)
        let running = try await reopened.processingJob(id: original.id)
        XCTAssertEqual(running?.state, .running)
        let reroutedCount = try await reopened.rerouteJobs(fromComputeNode: nodeId)
        XCTAssertEqual(reroutedCount, 1)
        let waiting = try await reopened.processingJob(id: original.id)
        XCTAssertEqual(waiting?.state, .waitingForCapability)
        XCTAssertNil(waiting?.selectedRoute)
        XCTAssertNil(waiting?.computeNodeId)
        XCTAssertEqual(waiting?.errorCode, "COMPUTE_NODE_REMOVED")
    }
}
