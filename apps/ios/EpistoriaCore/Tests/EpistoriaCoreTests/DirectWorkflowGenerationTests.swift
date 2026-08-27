import Foundation
import XCTest
@testable import EpistoriaCore

final class DirectWorkflowGenerationTests: XCTestCase {
    func testNotePromptSeparatesBoundedImagesFromJSON() throws {
        let sourceId = UUID()
        let request = NoteQueryRequest(
            accountId: UUID(),
            jobId: UUID(),
            noteId: UUID(),
            noteTitle: "Algebra",
            question: "What does this show?",
            selectionSources: [
                NoteQuerySourceExcerpt(
                    sourceId: sourceId,
                    sourceKind: .lassoSelection,
                    title: "Algebra",
                    locator: "selected visual",
                    imageContent: Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()
                )
            ],
            contextSources: [],
            disclosureAcknowledged: true,
            providerRoute: nil
        )
        let providerRequest = try DirectWorkflowGeneration.noteQueryRequest(
            request,
            route: route(capabilities: [.text, .vision])
        )

        XCTAssertEqual(providerRequest.images.count, 1)
        XCTAssertTrue(providerRequest.prompt.contains(sourceId.uuidString))
        XCTAssertFalse(providerRequest.prompt.contains(request.selectionSources[0].imageContent!))
    }

    func testNoteResponseRejectsCitationOutsideReviewedScope() throws {
        let sourceId = UUID()
        let request = NoteQueryRequest(
            accountId: UUID(),
            jobId: UUID(),
            noteId: UUID(),
            noteTitle: nil,
            question: "Explain",
            selectionSources: [
                NoteQuerySourceExcerpt(
                    sourceId: sourceId,
                    sourceKind: .noteBlock,
                    title: "Note",
                    locator: "block 1",
                    excerpt: "Approved material"
                )
            ],
            contextSources: [],
            disclosureAcknowledged: true,
            providerRoute: nil
        )
        let response = NoteQueryResponse(
            schemaVersion: "note-query-response/v1",
            answer: "Unsupported",
            citedSourceIds: [UUID()],
            followUpQuestions: []
        )

        XCTAssertThrowsError(
            try DirectWorkflowGeneration.validateNoteQuery(
                String(decoding: try CanonicalJSON.encode(response), as: UTF8.self),
                request: request
            )
        ) { error in
            XCTAssertEqual(error as? DirectWorkflowError, .citationOutsideScope)
        }
    }

    func testVisionInputRequiresReviewedVisionCapability() throws {
        let request = NoteQueryRequest(
            accountId: UUID(),
            jobId: UUID(),
            noteId: UUID(),
            noteTitle: nil,
            question: "Explain",
            selectionSources: [
                NoteQuerySourceExcerpt(
                    sourceId: UUID(),
                    sourceKind: .lassoSelection,
                    title: "Note",
                    locator: "selection",
                    imageContent: Data([1, 2, 3]).base64EncodedString()
                )
            ],
            contextSources: [],
            disclosureAcknowledged: true,
            providerRoute: nil
        )

        XCTAssertThrowsError(
            try DirectWorkflowGeneration.noteQueryRequest(
                request,
                route: route(capabilities: [.text])
            )
        ) { error in
            XCTAssertEqual(error as? DirectWorkflowError, .visionUnavailable)
        }
    }

    private func route(capabilities: [AIProviderCapability]) -> AIProviderRouteSnapshot {
        AIProviderRouteSnapshot(
            profileId: UUID(),
            configurationRevisionId: UUID(),
            displayName: "Test provider",
            adapter: .openAICompatible,
            baseURL: "http://localhost:11434/v1",
            textModel: "test",
            transcriptionModel: "whisper",
            capabilities: capabilities,
            structuredOutput: true
        )
    }
}
