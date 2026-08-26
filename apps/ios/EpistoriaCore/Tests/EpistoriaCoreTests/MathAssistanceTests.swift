import Foundation
import XCTest

@testable import EpistoriaCore

final class MathAssistanceTests: XCTestCase {
    func testExpressionEvaluatorUsesDeterministicPrecedenceAndFunctions() throws {
        XCTAssertEqual(
            try MathExpressionEvaluator.evaluate("2 + 3*x^2", x: 2), 14, accuracy: 0.000_001)
        XCTAssertEqual(
            try MathExpressionEvaluator.evaluate("sqrt(9) + abs(-2)", x: 0), 5, accuracy: 0.000_001)
        XCTAssertEqual(
            try MathExpressionEvaluator.evaluate("sin(pi/2)", x: 0), 1, accuracy: 0.000_001)
    }

    func testExpressionEvaluatorRejectsImplicitExecutionAndUnknownNames() {
        XCTAssertThrowsError(try MathExpressionEvaluator.evaluate("2x", x: 3))
        XCTAssertThrowsError(try MathExpressionEvaluator.evaluate("system(x)", x: 3)) { error in
            XCTAssertEqual(error as? MathExpressionError, .unknownIdentifier("system"))
        }
        XCTAssertThrowsError(try MathExpressionEvaluator.evaluate("x;print(1)", x: 3))
    }

    func testGraphSamplingPreservesUndefinedPointsWithoutDroppingThePlot() throws {
        let samples = try MathExpressionEvaluator.samples(
            expression: "1/x",
            domain: MathGraphDomain(minimumX: -1, maximumX: 1),
            count: 41
        )

        XCTAssertEqual(samples.count, 41)
        XCTAssertNil(samples[20].y)
        XCTAssertEqual(samples.first?.y, -1)
        XCTAssertEqual(samples.last?.y, 1)
    }

    func testMathArtifactRoundTripsWithReviewableTypedResults() throws {
        let jobId = UUID()
        let noteId = UUID()
        let sourceId = UUID()
        let response = MathAssistanceResponse(
            recognizedExpression: "x^2 = 4",
            latex: "x^2 = 4",
            interpretation: "Solve over the real numbers.",
            steps: [MathWorkedStep(expression: "x = ±2", explanation: "Take both square roots.")],
            finalAnswer: "x = -2 or x = 2",
            diagnoses: [
                MathErrorDiagnosis(
                    kind: .method,
                    observed: "x = 2",
                    explanation: "The negative root was omitted.",
                    correction: "x = -2 or x = 2"
                )
            ],
            graphExpression: "x^2 - 4",
            graphDomain: MathGraphDomain(minimumX: -5, maximumX: 5),
            confidence: 0.92,
            uncertainties: ["The final symbol may be a 4."],
            citedSourceIds: [sourceId]
        )
        let artifact = MathAssistanceArtifact(
            jobId: jobId,
            noteId: noteId,
            mode: .diagnose,
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            sourceIds: [sourceId],
            trace: ProviderTrace(
                provider: "fake",
                model: "math-v1",
                promptVersion: "math-assistance/v1"
            ),
            response: response
        )

        let data = try CanonicalJSON.encode(artifact)
        let decoded = try CanonicalJSON.decode(MathAssistanceArtifact.self, from: data)

        XCTAssertEqual(decoded, artifact)
        XCTAssertEqual(decoded.schemaVersion, "ai-artifact/math-assistance/v1")
        XCTAssertNil(decoded.reviewState)
        XCTAssertEqual(decoded.response.diagnoses.first?.kind, .method)
    }

    func testGraphDomainFailsClosedToAUsableDefault() {
        XCTAssertEqual(MathGraphDomain(minimumX: 5, maximumX: 5), MathGraphDomain())
        XCTAssertEqual(MathGraphDomain(minimumX: .nan, maximumX: .infinity), MathGraphDomain())
    }

    func testImageMathFailsBeforeQueueingWhenReviewedRouteHasNoVision() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EpistoriaMathTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let accountId = UUID()
        let accountKey = try EntityCrypto().randomKey()
        let database = try SQLCipherDatabase(
            url: root.appendingPathComponent("test.sqlite"),
            key: try EntityCrypto().localDatabaseKey(accountKey: accountKey, accountId: accountId)
        )
        let store = EpistoriaStore(database: database)
        let api = EpistoriaAPIClient(
            baseURL: try XCTUnwrap(URL(string: "https://sync.example.test/v1")),
            credentials: DeviceCredentials(
                ownerId: accountId,
                deviceId: UUID(),
                token: String(repeating: "t", count: 43)
            )
        )
        let route = AIProviderRouteSnapshot(
            profileId: UUID(),
            configurationRevisionId: UUID(),
            displayName: "Text only",
            adapter: .openAICompatible,
            baseURL: "https://provider.example.test/v1",
            textModel: "text-only",
            transcriptionModel: nil,
            capabilities: [.text, .structuredOutput],
            structuredOutput: true
        )
        let jobId = UUID()
        let sourceId = UUID()
        let prepared = PreparedMathAssistanceRequest(
            request: MathAssistanceRequest(
                accountId: accountId,
                jobId: jobId,
                noteId: UUID(),
                noteTitle: "Synthetic",
                mode: .recognize,
                learnerInstructions: nil,
                outputLanguage: "English",
                selectionSources: [
                    NoteQuerySourceExcerpt(
                        sourceId: sourceId,
                        sourceKind: .lassoSelection,
                        title: "Synthetic",
                        locator: "selected item",
                        imageContent: "aW1hZ2U="
                    )
                ],
                contextSources: [],
                disclosureAcknowledged: false,
                providerRoute: nil
            ),
            selectionCount: 1,
            contextCount: 0,
            imageCount: 1,
            approximateTokens: 700
        )
        let coordinator = AIJobCoordinator(
            accountId: accountId,
            accountKey: accountKey,
            store: store,
            api: api,
            providerRouteSnapshot: route,
            requiresProviderRouteSnapshot: true
        )

        do {
            _ = try await coordinator.submitMathAssistance(prepared)
            XCTFail("A text-only route must fail before queueing image mathematics")
        } catch {
            XCTAssertEqual(error as? AIJobCoordinatorError, .mathVisionUnavailable)
        }
    }
}
