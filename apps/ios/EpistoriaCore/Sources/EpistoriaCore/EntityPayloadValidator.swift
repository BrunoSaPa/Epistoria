import Foundation

/// Strictly decodes every transport entity before a portable import reaches local storage.
public enum EntityPayloadValidator {
    public static func validate(entityType: EntityType, content: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: content) as? [String: Any],
              let schemaVersion = object["schemaVersion"] as? String,
              acceptedSchemaVersions(for: entityType).contains(schemaVersion)
        else { throw ValidationError.unsupportedSchemaVersion }
        switch entityType {
        case .area: _ = try CanonicalJSON.decode(AreaPayload.self, from: content)
        case .topicArea: _ = try CanonicalJSON.decode(TopicAreaRelationPayload.self, from: content)
        case .collection: _ = try CanonicalJSON.decode(CollectionPayload.self, from: content)
        case .collectionItem, .sessionNote, .sessionResource:
            let relation = try CanonicalJSON.decode(RelationPayload.self, from: content)
            guard relation.resolvedEntityType == entityType else { throw ValidationError.typeMismatch }
        case .institution: _ = try CanonicalJSON.decode(InstitutionPayload.self, from: content)
        case .academicTerm: _ = try CanonicalJSON.decode(AcademicTermPayload.self, from: content)
        case .course: _ = try CanonicalJSON.decode(TopicPayload.self, from: content)
        case .studySession: _ = try CanonicalJSON.decode(StudySessionPayload.self, from: content)
        case .note: _ = try CanonicalJSON.decode(NotePayload.self, from: content)
        case .noteBlock: _ = try CanonicalJSON.decode(NoteBlockPayload.self, from: content)
        case .resource: _ = try CanonicalJSON.decode(SourcePayload.self, from: content)
        case .asset: _ = try CanonicalJSON.decode(AssetPayload.self, from: content)
        case .annotation: _ = try CanonicalJSON.decode(AnnotationPayload.self, from: content)
        case .aiArtifact:
            break
        case .transcriptCorrection:
            _ = try CanonicalJSON.decode(TranscriptCorrectionPayload.self, from: content)
        case .sourceVersion: _ = try CanonicalJSON.decode(SourceVersionPayload.self, from: content)
        case .evidence: _ = try CanonicalJSON.decode(EvidencePayload.self, from: content)
        case .concept: _ = try CanonicalJSON.decode(ConceptPayload.self, from: content)
        case .conceptEvidence:
            _ = try CanonicalJSON.decode(ConceptEvidenceRelationPayload.self, from: content)
        case .conceptLink: _ = try CanonicalJSON.decode(ConceptLinkPayload.self, from: content)
        case .studyGoal: _ = try CanonicalJSON.decode(StudyGoalPayload.self, from: content)
        case .unresolvedQuestion:
            _ = try CanonicalJSON.decode(UnresolvedQuestionPayload.self, from: content)
        case .sessionActivity:
            _ = try CanonicalJSON.decode(SessionActivityPayload.self, from: content)
        case .flashcardDeck: _ = try CanonicalJSON.decode(FlashcardDeckPayload.self, from: content)
        case .flashcard: _ = try CanonicalJSON.decode(FlashcardPayload.self, from: content)
        case .flashcardRevision:
            _ = try CanonicalJSON.decode(FlashcardRevisionPayload.self, from: content)
        case .flashcardReview:
            _ = try CanonicalJSON.decode(FlashcardReviewPayload.self, from: content)
        case .topicScopeSnapshot:
            _ = try CanonicalJSON.decode(TopicScopeSnapshotPayload.self, from: content)
        case .testBlueprint: _ = try CanonicalJSON.decode(TestBlueprintPayload.self, from: content)
        case .practiceTest: _ = try CanonicalJSON.decode(PracticeTestPayload.self, from: content)
        case .testQuestion: _ = try CanonicalJSON.decode(TestQuestionPayload.self, from: content)
        case .testAttempt: _ = try CanonicalJSON.decode(TestAttemptPayload.self, from: content)
        case .testResponse: _ = try CanonicalJSON.decode(TestResponsePayload.self, from: content)
        case .studyRecommendation:
            _ = try CanonicalJSON.decode(StudyRecommendationPayload.self, from: content)
        case .recommendationResponse:
            _ = try CanonicalJSON.decode(RecommendationResponsePayload.self, from: content)
        case .automationGrant:
            _ = try CanonicalJSON.decode(AutomationGrantPayload.self, from: content)
        case .tutorSession:
            _ = try CanonicalJSON.decode(TutorSessionPayload.self, from: content)
        case .tutorTurn:
            _ = try CanonicalJSON.decode(TutorTurnPayload.self, from: content)
        case .learningSignal:
            _ = try CanonicalJSON.decode(LearningSignalPayload.self, from: content)
        }
    }

    public enum ValidationError: Error, Equatable {
        case typeMismatch
        case unsupportedSchemaVersion
    }

    private static func acceptedSchemaVersions(for entityType: EntityType) -> Set<String> {
        switch entityType {
        case .area: ["area/v1"]
        case .topicArea: ["topic-area/v1"]
        case .collection: ["collection/v1", "collection/v2"]
        case .collectionItem: ["collection-item/v1"]
        case .sessionNote: ["session-note/v1"]
        case .sessionResource: ["session-resource/v1"]
        case .institution: ["institution/v1"]
        case .academicTerm: ["academic-term/v1"]
        case .course: ["course/v1", "topic/v1"]
        case .studySession: ["study-session/v1"]
        case .note: ["note/v1", "note/v2", "note/v3"]
        case .noteBlock: ["note-block/v1", "note-block/v2", "note-block/v3", "note-block/v4", "note-block/v5"]
        case .resource: ["resource/v1", "source/v1"]
        case .asset: ["asset/v1"]
        case .annotation: ["annotation/v1"]
        case .aiArtifact: [
            "ai-artifact/session-digest/v1",
            "ai-artifact/note-query/v1",
            "ai-artifact/learning-generation/v1",
            "ai-artifact/learning-generation/v2",
            "ai-artifact/free-response-feedback/v1",
            "ai-artifact/media-transcription/v1",
            "media-transcription-chunk/v1",
            "ai-artifact/provider-configuration/v1",
            "ai-artifact/pdf-extraction/v1",
            "pdf-extraction-chunk/v1",
            "ai-artifact/source-analysis/v1",
            "ai-artifact/source-query/v1",
            "ai-artifact/tutor-turn/v1",
        ]
        case .transcriptCorrection: ["transcript-correction/v1"]
        case .sourceVersion: ["source-version/v1"]
        case .evidence: ["evidence/v1"]
        case .concept: ["concept/v1"]
        case .conceptEvidence: ["concept-evidence/v1"]
        case .conceptLink: ["concept-link/v1"]
        case .studyGoal: ["study-goal/v1"]
        case .unresolvedQuestion: ["unresolved-question/v1"]
        case .sessionActivity: ["session-activity/v1"]
        case .flashcardDeck: ["flashcard-deck/v1"]
        case .flashcard: ["flashcard/v1"]
        case .flashcardRevision: ["flashcard-revision/v1"]
        case .flashcardReview: ["flashcard-review/v1"]
        case .topicScopeSnapshot: ["topic-scope-snapshot/v1"]
        case .testBlueprint: ["test-blueprint/v1", "test-blueprint/v2"]
        case .practiceTest: ["practice-test/v1"]
        case .testQuestion: ["test-question/v1"]
        case .testAttempt: ["test-attempt/v1"]
        case .testResponse: ["test-response/v1", "test-response/v2"]
        case .studyRecommendation: ["study-recommendation/v1"]
        case .recommendationResponse: ["recommendation-response/v1", "recommendation-response/v2"]
        case .automationGrant: ["automation-grant/v1", "automation-grant/v2"]
        case .tutorSession: ["tutor-session/v1"]
        case .tutorTurn: ["tutor-turn/v1"]
        case .learningSignal: ["learning-signal/v1"]
        }
    }
}
