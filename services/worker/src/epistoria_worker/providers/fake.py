from __future__ import annotations

from ..models import (
    CitedStatementV1,
    LearningDraftItemV1,
    LearningGenerationRequestV1,
    LearningGenerationResponseV1,
    NoteQueryRequestV1,
    NoteQueryResponseV1,
    ProviderTraceV1,
    SessionDigestRequestV1,
    SessionDigestV1,
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
