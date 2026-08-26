from __future__ import annotations

from uuid import uuid5

from ..models import (
    CitedStatementV1,
    ConceptLinkDraftV1,
    FreeResponseFeedbackRequestV1,
    FreeResponseFeedbackResponseV1,
    LearningDraftItemV1,
    LearningGenerationRequestV1,
    LearningGenerationResponseV1,
    MediaTranscriptionResponseV1,
    NoteQueryRequestV1,
    NoteQueryResponseV1,
    ProviderRouteSnapshotV1,
    ProviderTraceV1,
    SessionDigestRequestV1,
    SessionDigestV1,
    SourceGuidePromptV1,
    SourceGuideResponseV1,
    SourceGuideStatementV1,
    SourceGuideTopicV1,
    SourceQueryPromptV1,
    SourceQueryResponseV1,
    SuggestedSourceQuestionV1,
    TranscriptSegmentV1,
    TutorSignalDraftV1,
    TutorTurnRequestV1,
    TutorTurnResponseV1,
)


class DeterministicDigestProvider:
    """Synthetic provider used only by tests and explicit local development."""

    def generate(self, request: SessionDigestRequestV1) -> tuple[SessionDigestV1, ProviderTraceV1]:
        selected = request.sources[:3]
        points = [
            CitedStatementV1(text=source.excerpt[:1_000], source_ids=[source.source_id])
            for source in selected
        ]
        digest = SessionDigestV1(
            title=f"Digest: {request.session_title}",
            summary=selected[0].excerpt[:2_000],
            key_points=points,
            possible_misconceptions=[],
            follow_up_questions=["What should I revisit before the next session?"],
        )
        return digest, ProviderTraceV1(
            provider="deterministic-test",
            model="fixture-v1",
            prompt_version="session-digest/v1",
            input_tokens=None,
            output_tokens=None,
            estimated_cost_usd=0,
        )

    def generate_note_query(
        self, request: NoteQueryRequestV1
    ) -> tuple[NoteQueryResponseV1, ProviderTraceV1]:
        first = request.selection_sources[0]
        excerpt = first.excerpt or "[drawing block]"
        cited_ids = [s.source_id for s in request.selection_sources]
        response = NoteQueryResponseV1(
            answer=f"[Test answer for: {request.question!r}] Based on: {excerpt[:200]}",
            cited_source_ids=cited_ids,
            follow_up_questions=["What aspect would you like to explore further?"],
        )
        return response, ProviderTraceV1(
            provider="deterministic-test",
            model="fixture-v1",
            prompt_version="note-query/v1",
            input_tokens=None,
            output_tokens=None,
            estimated_cost_usd=0,
        )

    def generate_learning(
        self, request: LearningGenerationRequestV1
    ) -> tuple[LearningGenerationResponseV1, ProviderTraceV1]:
        source = request.sources[0]
        if request.job_type == "TEST_GENERATION" and request.test_plan is not None:
            plan = request.test_plan
            items = []
            dimensions = plan.coverage_dimensions
            for index in range(plan.question_count):
                objective = plan.objective_titles[index % len(plan.objective_titles)]
                dimension = dimensions[index % len(dimensions)]
                items.append(
                    LearningDraftItemV1(
                        id=uuid5(request.job_id, f"test-question:{index}"),
                        kind="MULTI_STEP_APPLICATION"
                        if dimension == "INTEGRATED"
                        else "EXPLANATION",
                        title=f"{objective}: {dimension.replace('_', ' ').title()}",
                        body=(
                            f"Evaluate {objective} for the "
                            f"{dimension.replace('_', ' ').lower()} dimension."
                        ),
                        answer=source.excerpt[:500],
                        objective_titles=[objective],
                        cited_source_ids=[source.source_id],
                    )
                )
            covered = set(item.objective_titles[0] for item in items)
            gaps = [
                f"No generated question covers objective: {objective}"
                for objective in plan.objective_titles
                if objective not in covered
            ]
            covered_dimensions = {
                dimensions[index % len(dimensions)] for index in range(len(items))
            }
            gaps.extend(
                f"No generated question covers dimension: {dimension.replace('_', ' ').title()}"
                for dimension in dimensions
                if dimension not in covered_dimensions
            )
            if (
                plan.time_limit_minutes is not None
                and plan.time_limit_minutes < plan.question_count * 2
            ):
                gaps.append("The requested time limit allows under two minutes per question.")
            response = LearningGenerationResponseV1(
                summary=f"{plan.mode.replace('_', ' ').title()} test",
                items=items,
                coverage_gaps=gaps,
            )
        elif request.job_type == "CONCEPT_SUGGESTIONS":
            first_name = (
                request.known_concepts[0].name if request.known_concepts else "Existing concept"
            )
            first_id = request.known_concepts[0].id if request.known_concepts else None
            proposed_name = f"Concept from {source.title}"
            items = [
                LearningDraftItemV1(
                    id=request.job_id,
                    kind="CONCEPT",
                    title=proposed_name,
                    body=source.excerpt[:1_000],
                    cited_source_ids=[source.source_id],
                )
            ]
            if first_id is None:
                items.insert(
                    0,
                    LearningDraftItemV1(
                        id=uuid5(request.job_id, "existing-concept-fixture"),
                        kind="CONCEPT",
                        title=first_name,
                        body="A deterministic concept used to exercise reviewed links.",
                        cited_source_ids=[source.source_id],
                    ),
                )
            response = LearningGenerationResponseV1(
                summary="Deterministic Concept suggestions",
                items=items,
                concept_links=[
                    ConceptLinkDraftV1(
                        id=uuid5(request.job_id, "concept-link:0"),
                        source_concept_id=first_id,
                        source_concept_name=first_name,
                        target_concept_name=proposed_name,
                        relation="RELATED",
                        rationale="The supplied evidence discusses both ideas together.",
                        cited_source_ids=[source.source_id],
                    )
                ],
                coverage_gaps=[],
            )
        else:
            response = LearningGenerationResponseV1(
                summary=f"Deterministic draft for {request.job_type}",
                items=[
                    LearningDraftItemV1(
                        id=request.job_id,
                        kind=request.job_type,
                        title=f"Draft from {source.title}",
                        body=source.excerpt[:1_000],
                        answer=source.excerpt[:500],
                        objective_titles=request.objective_titles,
                        cited_source_ids=[source.source_id],
                    )
                ],
                coverage_gaps=[],
            )
        return response, ProviderTraceV1(
            provider="deterministic-test",
            model="fixture-v1",
            prompt_version="learning-generation/v1",
            input_tokens=None,
            output_tokens=None,
            estimated_cost_usd=0,
        )

    def generate_tutor_turn(
        self, request: TutorTurnRequestV1
    ) -> tuple[TutorTurnResponseV1, ProviderTraceV1]:
        source = request.sources[0]
        signals = []
        if request.action == "ANSWER":
            signals = [TutorSignalDraftV1(
                id=uuid5(request.job_id, "signal:0"),
                objective=request.objective,
                assessment_kind="RETRIEVAL",
                outcome="PARTIAL",
                confidence=request.learner_confidence,
                rationale="The learner attempted the requested retrieval step.",
                cited_excerpt_ids=[source.excerpt_id],
            )]
        ending = request.action == "END"
        response = TutorTurnResponseV1(
            message=(
                f"Review this cited idea, then explain it in your own words: {source.excerpt[:500]}"
                if not ending
                else "This session reviewed the objective using the selected source."
            ),
            kind="REFLECTION" if ending else request.recommended_turn_kind,
            cited_excerpt_ids=[source.excerpt_id],
            proposed_signals=signals,
            follow_up_actions=[] if ending else ["HINT", "EXPLAIN_DIRECTLY", "WHY_NEXT"],
            unresolved_questions=[],
            suggested_topics=[],
            session_summary=("The learner reviewed the selected objective." if ending else None),
            source_gap=False,
        )
        return response, ProviderTraceV1(
            provider="deterministic-test",
            model="fixture-v1",
            prompt_version="adaptive-tutor/v1",
            input_tokens=None,
            output_tokens=None,
            estimated_cost_usd=0,
        )

    def generate_free_response_feedback(
        self, request: FreeResponseFeedbackRequestV1
    ) -> tuple[FreeResponseFeedbackResponseV1, ProviderTraceV1]:
        matches = (
            request.user_response.strip().casefold() == request.reference_answer.strip().casefold()
        )
        response = FreeResponseFeedbackResponseV1(
            feedback=(
                "The saved response matches the frozen reference answer."
                if matches
                else "The saved response needs review against the frozen grading guide."
            ),
            strengths=["The response addresses the requested question."],
            improvements=[] if matches else ["Compare each claim with the grading guide."],
            proposed_score=1 if matches else 0.5,
            uncertainty="Low uncertainty in this deterministic development fixture.",
            cited_source_ids=[request.evidence[0].source_id],
        )
        return response, ProviderTraceV1(
            provider="deterministic-test",
            model="fixture-v1",
            prompt_version="free-response-feedback/v1",
            input_tokens=None,
            output_tokens=None,
            estimated_cost_usd=0,
        )

    def generate_source_guide(
        self, request: SourceGuidePromptV1
    ) -> tuple[SourceGuideResponseV1, ProviderTraceV1]:
        first = request.materials[0]
        image = next((item for item in request.materials if item.kind == "IMAGE"), None)
        response = SourceGuideResponseV1(
            source_language="English",
            output_language=request.output_language,
            summary=[
                SourceGuideStatementV1(
                    text=f"Deterministic source summary: {first.excerpt[:500]}",
                    source_ids=[first.source_id],
                )
            ],
            translated_summary=(
                [
                    SourceGuideStatementV1(
                        text=f"Deterministic translation to {request.output_language}.",
                        source_ids=[first.source_id],
                    )
                ]
                if request.output_language.casefold() != "english"
                else []
            ),
            key_topics=[
                SourceGuideTopicV1(
                    title="Primary source topic",
                    explanation=first.excerpt[:500],
                    source_ids=[first.source_id],
                )
            ],
            suggested_questions=[
                SuggestedSourceQuestionV1(
                    question="What is the main claim in this source?",
                    source_ids=[first.source_id],
                )
            ],
            image_insights=(
                [
                    SourceGuideStatementV1(
                        text="The source contains a cited image region.",
                        source_ids=[image.source_id],
                    )
                ]
                if image is not None
                else []
            ),
        )
        return response, self._source_trace("source-guide/v1")

    def generate_source_query(
        self, request: SourceQueryPromptV1
    ) -> tuple[SourceQueryResponseV1, ProviderTraceV1]:
        first = request.materials[0]
        response = SourceQueryResponseV1(
            answer=[
                SourceGuideStatementV1(
                    text=f"Deterministic answer for {request.question}: {first.excerpt[:500]}",
                    source_ids=[first.source_id],
                )
            ],
            insufficient_evidence=False,
            follow_up_questions=["Which cited passage should we inspect next?"],
        )
        return response, self._source_trace("source-query/v1")

    @staticmethod
    def _source_trace(prompt_version: str) -> ProviderTraceV1:
        return ProviderTraceV1(
            provider="deterministic-test",
            model="fixture-v1",
            prompt_version=prompt_version,
            input_tokens=None,
            output_tokens=None,
            estimated_cost_usd=0,
        )

    def transcribe_media(
        self,
        *,
        filename: str,
        mime_type: str,
        media: bytes,
        language: str | None,
        provider_route: ProviderRouteSnapshotV1 | None = None,
    ) -> tuple[MediaTranscriptionResponseV1, ProviderTraceV1]:
        del mime_type
        if not media:
            raise ValueError("media cannot be empty")
        response = MediaTranscriptionResponseV1(
            language=language or "en",
            duration_seconds=1,
            segments=[
                TranscriptSegmentV1(
                    index=0,
                    start_seconds=0,
                    end_seconds=1,
                    text=f"Synthetic transcript for {filename}.",
                )
            ],
        )
        return response, ProviderTraceV1(
            provider="deterministic-test",
            model="fixture-transcription-v1",
            prompt_version="media-transcription/v1",
            input_tokens=None,
            output_tokens=None,
            estimated_cost_usd=0,
        )
