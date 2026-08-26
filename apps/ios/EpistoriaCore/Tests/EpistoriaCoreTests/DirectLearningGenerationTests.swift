import Foundation
import XCTest
@testable import EpistoriaCore

final class DirectLearningGenerationTests: XCTestCase {
    func testBuildsBoundedPromptWithoutAccountOrProviderRoute() throws {
        let fixture = makeRequest()
        let providerRequest = try DirectLearningGeneration.providerRequest(for: fixture.request)

        XCTAssertTrue(providerRequest.prompt.contains(fixture.sourceId.uuidString))
        XCTAssertTrue(providerRequest.prompt.contains("Approved source text"))
        XCTAssertFalse(providerRequest.prompt.contains(fixture.request.accountId.uuidString))
        XCTAssertFalse(providerRequest.prompt.contains("providerRoute"))
        XCTAssertEqual(providerRequest.maximumOutputTokens, 4_096)
    }

    func testValidatesResponseAndCreatesReviewableArtifact() throws {
        let fixture = makeRequest()
        let response = LearningGenerationResponse(
            summary: "A grounded overview",
            items: [
                LearningDraftItem(
                    kind: "SUMMARY_POINT",
                    title: "Supported point",
                    body: "The approved excerpt supports this point.",
                    citedSourceIds: [fixture.sourceId]
                )
            ]
        )
        let data = try CanonicalJSON.encode(response)
        let decoded = try DirectLearningGeneration.validatedResponse(
            from: String(decoding: data, as: UTF8.self),
            request: fixture.request
        )
        let trace = ProviderTrace(
            provider: "Local provider",
            model: "test-model",
            promptVersion: DirectLearningGeneration.promptVersion
        )
        let artifact = try DirectLearningGeneration.artifact(
            request: fixture.request,
            response: decoded,
            trace: trace
        )

        XCTAssertEqual(artifact.jobId, fixture.request.jobId)
        XCTAssertEqual(artifact.sourceIds, [fixture.sourceId])
        XCTAssertNil(artifact.reviewState)
        XCTAssertEqual(artifact.trace.promptVersion, "learning-generation/v1")
        XCTAssertEqual(artifact.providerRoute, fixture.request.providerRoute)
    }

    func testRejectsCitationOutsideApprovedSources() throws {
        let fixture = makeRequest()
        let response = LearningGenerationResponse(
            summary: "Invalid",
            items: [
                LearningDraftItem(
                    kind: "SUMMARY_POINT",
                    title: "Unsupported point",
                    body: "This points outside the request.",
                    citedSourceIds: [UUID()]
                )
            ]
        )
        let text = String(decoding: try CanonicalJSON.encode(response), as: UTF8.self)

        XCTAssertThrowsError(
            try DirectLearningGeneration.validatedResponse(from: text, request: fixture.request)
        ) { error in
            XCTAssertEqual(error as? DirectLearningGenerationError, .invalidCitation)
        }
    }

    func testRejectsMarkdownWrappedOrUnknownResponseFields() throws {
        let fixture = makeRequest()
        let valid = LearningGenerationResponse(
            summary: "Summary",
            items: [
                LearningDraftItem(
                    kind: "SUMMARY_POINT",
                    title: "Point",
                    body: "Body",
                    citedSourceIds: [fixture.sourceId]
                )
            ]
        )
        let validText = String(decoding: try CanonicalJSON.encode(valid), as: UTF8.self)
        XCTAssertThrowsError(
            try DirectLearningGeneration.validatedResponse(
                from: "```json\n\(validText)\n```",
                request: fixture.request
            )
        )

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(validText.utf8)) as? [String: Any]
        )
        object["internalReasoning"] = "must not be retained"
        let unknownText = String(
            decoding: try JSONSerialization.data(withJSONObject: object),
            as: UTF8.self
        )
        XCTAssertThrowsError(
            try DirectLearningGeneration.validatedResponse(
                from: unknownText,
                request: fixture.request
            )
        ) { error in
            XCTAssertEqual(error as? DirectLearningGenerationError, .invalidSchema)
        }

        var nested = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(validText.utf8)) as? [String: Any]
        )
        var items = try XCTUnwrap(nested["items"] as? [[String: Any]])
        items[0]["hiddenReasoning"] = "must not be retained"
        nested["items"] = items
        let nestedText = String(
            decoding: try JSONSerialization.data(withJSONObject: nested),
            as: UTF8.self
        )
        XCTAssertThrowsError(
            try DirectLearningGeneration.validatedResponse(
                from: nestedText,
                request: fixture.request
            )
        ) { error in
            XCTAssertEqual(error as? DirectLearningGenerationError, .invalidSchema)
        }
    }

    private func makeRequest() -> (request: LearningGenerationRequest, sourceId: UUID) {
        let sourceId = UUID()
        var request = LearningGenerationRequest(
                accountId: UUID(),
                jobId: UUID(),
                jobType: .topicSynthesis,
                topicId: UUID(),
                includeConnectedKnowledge: false,
                sources: [
                    DigestSourceExcerpt(
                        sourceId: sourceId,
                        sourceKind: .noteBlock,
                        title: "Notebook page",
                        locator: "note block 1",
                        excerpt: "Approved source text"
                    )
                ],
                knownConcepts: [],
                objectiveTitles: [],
                disclosureAcknowledged: true
            )
        request.providerRoute = AIProviderRouteSnapshot(
            profileId: UUID(),
            configurationRevisionId: UUID(),
            displayName: "Synthetic provider",
            adapter: .openAICompatible,
            baseURL: "http://127.0.0.1:11434/v1",
            textModel: "synthetic",
            transcriptionModel: nil,
            capabilities: [.text],
            structuredOutput: true
        )
        return (request, sourceId)
    }
}
