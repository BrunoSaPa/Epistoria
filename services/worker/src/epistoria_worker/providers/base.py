from __future__ import annotations

from typing import Protocol

from ..models import (
    FreeResponseFeedbackRequestV1,
    FreeResponseFeedbackResponseV1,
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
    SourceQueryPromptV1,
    SourceQueryResponseV1,
)


class ProviderError(RuntimeError):
    def __init__(self, message: str, *, code: str, retryable: bool):
        super().__init__(message)
        self.code = code
        self.retryable = retryable


class DigestProvider(Protocol):
    def generate(self, request: SessionDigestRequestV1) -> tuple[SessionDigestV1, ProviderTraceV1]:
        """Generate a schema-valid, cited session digest without mutating source content."""
        ...

    def generate_learning(
        self, request: LearningGenerationRequestV1
    ) -> tuple[LearningGenerationResponseV1, ProviderTraceV1]:
        """Return cited drafts. The caller stores them as reviewable artifacts only."""
        ...

    def generate_note_query(
        self, request: NoteQueryRequestV1
    ) -> tuple[NoteQueryResponseV1, ProviderTraceV1]:
        """Answer a focused question about a lasso-selected note region."""
        ...

    def generate_free_response_feedback(
        self, request: FreeResponseFeedbackRequestV1
    ) -> tuple[FreeResponseFeedbackResponseV1, ProviderTraceV1]:
        """Return source-cited proposed feedback without changing a saved response or score."""
        ...

    def generate_source_guide(
        self, request: SourceGuidePromptV1
    ) -> tuple[SourceGuideResponseV1, ProviderTraceV1]:
        """Create a translated, source-cited guide from bounded immutable material."""
        ...

    def generate_source_query(
        self, request: SourceQueryPromptV1
    ) -> tuple[SourceQueryResponseV1, ProviderTraceV1]:
        """Answer from supplied source material and cite exact material IDs."""
        ...

    def transcribe_media(
        self,
        *,
        filename: str,
        mime_type: str,
        media: bytes,
        language: str | None,
        provider_route: ProviderRouteSnapshotV1 | None = None,
    ) -> tuple[MediaTranscriptionResponseV1, ProviderTraceV1]:
        """Transcribe one approved local media asset and return ordered timestamped segments."""
        ...
