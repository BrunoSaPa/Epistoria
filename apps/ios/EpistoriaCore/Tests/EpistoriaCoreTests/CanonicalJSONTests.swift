import Foundation
import XCTest
@testable import EpistoriaCore

final class CanonicalJSONTests: XCTestCase {
    private struct Value: Codable, Equatable {
        var zeta: Int
        var alpha: String
        var date: Date
    }

    func testJSONIsSortedAndUsesRFC3339() throws {
        let value = Value(zeta: 2, alpha: "one", date: Date(timeIntervalSince1970: 0.123))
        let encoded = try CanonicalJSON.encode(value)
        let string = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertTrue(string.hasPrefix("{\"alpha\":"))
        XCTAssertTrue(string.contains("1970-01-01T00:00:00.123Z"))
        XCTAssertEqual(try CanonicalJSON.decode(Value.self, from: encoded), value)
    }

    func testOwnerEditedNoteQueryResponseRoundTrips() throws {
        let sourceId = UUID()
        let response = NoteQueryResponse(
            schemaVersion: "note-query-response/v1",
            answer: "A reviewed answer.",
            citedSourceIds: [sourceId],
            followUpQuestions: ["What follows?"]
        )

        let encoded = try CanonicalJSON.encode(response)

        XCTAssertEqual(
            try CanonicalJSON.decode(NoteQueryResponse.self, from: encoded),
            response
        )
    }

    func testMediaTranscriptionContractsRoundTripWithTimestampedSegments() throws {
        let jobId = UUID()
        let sourceId = UUID()
        let sourceVersionId = UUID()
        let segment = TranscriptSegment(
            index: 0,
            startSeconds: 1.25,
            endSeconds: 4.5,
            text: "A timestamped explanation."
        )
        let chunk = MediaTranscriptionChunk(
            jobId: jobId,
            sourceId: sourceId,
            sourceVersionId: sourceVersionId,
            chunkIndex: 0,
            segments: [segment]
        )
        let chunkData = try CanonicalJSON.encode(chunk)
        XCTAssertEqual(
            try CanonicalJSON.decode(MediaTranscriptionChunk.self, from: chunkData),
            chunk
        )

        let manifest = MediaTranscriptionManifest(
            jobId: jobId,
            sourceId: sourceId,
            sourceVersionId: sourceVersionId,
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            language: "en",
            durationSeconds: 4.5,
            characterCount: segment.text.count,
            segmentCount: 1,
            trace: ProviderTrace(
                provider: "openai",
                model: "whisper-1",
                promptVersion: "media-transcription/v1",
                estimatedCostUsd: 0.00045
            ),
            chunkEntityIds: [UUID()]
        )
        let manifestData = try CanonicalJSON.encode(manifest)
        XCTAssertEqual(
            try CanonicalJSON.decode(MediaTranscriptionManifest.self, from: manifestData),
            manifest
        )

        let correction = TranscriptCorrectionPayload(
            sourceId: sourceId,
            sourceVersionId: sourceVersionId,
            transcriptionArtifactId: UUID(),
            segment: segment,
            correctedText: "A corrected timestamped explanation.",
            reason: "Verified against the recording.",
            now: Date(timeIntervalSince1970: 1_800_000_100)
        )
        let correctionData = try CanonicalJSON.encode(correction)
        XCTAssertEqual(
            try CanonicalJSON.decode(TranscriptCorrectionPayload.self, from: correctionData),
            correction
        )
    }

    func testLegacyEvidenceDecodesWithoutTranscriptProvenance() throws {
        let evidence = EvidencePayload(
            sourceId: UUID(),
            sourceVersionId: UUID(),
            kind: .excerpt,
            locator: SourceLocator(kind: .pdf, page: 2),
            excerpt: "Legacy excerpt"
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: CanonicalJSON.encode(evidence)) as? [String: Any]
        )
        object.removeValue(forKey: "transcriptionArtifactId")
        object.removeValue(forKey: "transcriptSegmentIndexes")
        object.removeValue(forKey: "transcriptCorrectionIds")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try CanonicalJSON.decode(EvidencePayload.self, from: legacyData)
        XCTAssertNil(decoded.transcriptionArtifactId)
        XCTAssertTrue(decoded.resolvedTranscriptSegmentIndexes.isEmpty)
        XCTAssertTrue(decoded.resolvedTranscriptCorrectionIds.isEmpty)
    }

    func testProviderConfigurationContractsRoundTrip() throws {
        let accountId = UUID()
        let profileId = UUID()
        let configurationRevisionId = UUID()
        let request = AIProviderConfigurationRequest(
            accountId: accountId,
            operation: .upsert,
            profileId: profileId,
            configurationRevisionId: configurationRevisionId,
            displayName: "Local model",
            adapter: .openAICompatible,
            baseURL: "http://127.0.0.1:11434/v1",
            apiKey: "synthetic-key",
            textModel: "test-model",
            capabilities: [.vision, .text, .text],
            structuredOutput: true,
            makeActive: true
        )

        let requestData = try CanonicalJSON.encode(request)
        let decodedRequest = try CanonicalJSON.decode(
            AIProviderConfigurationRequest.self,
            from: requestData
        )
        XCTAssertEqual(decodedRequest, request)
        XCTAssertEqual(decodedRequest.capabilities, [.text, .vision])

        let route = AIProviderRouteSnapshot(
            profileId: profileId,
            configurationRevisionId: configurationRevisionId,
            displayName: "Local model",
            adapter: .openAICompatible,
            baseURL: "http://127.0.0.1:11434/v1",
            textModel: "test-model",
            transcriptionModel: nil,
            capabilities: [.vision, .text],
            structuredOutput: true
        )
        let routeData = try CanonicalJSON.encode(route)
        XCTAssertEqual(
            try CanonicalJSON.decode(AIProviderRouteSnapshot.self, from: routeData),
            route
        )
        XCTAssertNil(routeData.range(of: Data("synthetic-key".utf8)))

        let artifactData = try XCTUnwrap(
            """
            {
              "schemaVersion":"ai-artifact/provider-configuration/v1",
              "jobId":"\(request.jobId.uuidString)",
              "profileId":"\(profileId.uuidString)",
              "configurationRevisionId":"\(configurationRevisionId.uuidString)",
              "operation":"UPSERT",
              "displayName":"Local model",
              "adapter":"OPENAI_COMPATIBLE",
              "baseURL":"http://127.0.0.1:11434/v1",
              "textModel":"test-model",
              "capabilities":["TEXT"],
              "isActive":true,
              "secretStored":true,
              "configuredAt":"2026-08-24T12:00:00.000Z"
            }
            """.data(using: .utf8)
        )
        let artifact = try CanonicalJSON.decode(
            AIProviderConfigurationArtifact.self,
            from: artifactData
        )
        XCTAssertEqual(artifact.profileId, profileId)
        XCTAssertEqual(artifact.configurationRevisionId, configurationRevisionId)
        XCTAssertTrue(artifact.secretStored)
        XCTAssertNil(artifactData.range(of: Data("synthetic-key".utf8)))
        XCTAssertNoThrow(
            try EntityPayloadValidator.validate(entityType: .aiArtifact, content: artifactData)
        )
    }

    func testSourceAnalysisArtifactPreservesExactPDFCitation() throws {
        let referenceId = UUID()
        let statement = SourceGuideStatement(
            text: "Entropy measures uncertainty.",
            sourceIds: [referenceId]
        )
        let artifact = SourceAnalysisArtifact(
            schemaVersion: "ai-artifact/source-analysis/v1",
            jobId: UUID(),
            sourceId: UUID(),
            sourceVersionId: UUID(),
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            pageCount: 4,
            analyzedPageCount: 4,
            references: [SourceCitationReference(
                sourceId: referenceId,
                kind: .text,
                pageNumber: 3,
                rectangles: [AnnotationRectangle(x: 0.1, y: 0.2, width: 0.7, height: 0.1)],
                excerpt: "Entropy measures uncertainty."
            )],
            trace: ProviderTrace(
                provider: "deterministic-test",
                model: "fixture-v1",
                promptVersion: "source-guide/v1"
            ),
            guide: SourceGuideResponse(
                schemaVersion: "source-guide-response/v1",
                sourceLanguage: "English",
                outputLanguage: "Spanish",
                summary: [statement],
                translatedSummary: [SourceGuideStatement(
                    text: "La entropía mide la incertidumbre.",
                    sourceIds: [referenceId]
                )],
                keyTopics: [],
                suggestedQuestions: [],
                imageInsights: [],
                coverageGaps: []
            )
        )

        let data = try CanonicalJSON.encode(artifact)
        let decoded = try CanonicalJSON.decode(SourceAnalysisArtifact.self, from: data)
        XCTAssertEqual(decoded, artifact)
        XCTAssertEqual(decoded.references[0].locator.page, 3)
        XCTAssertNoThrow(
            try EntityPayloadValidator.validate(entityType: .aiArtifact, content: data)
        )
    }
}
