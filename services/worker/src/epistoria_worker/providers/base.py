from __future__ import annotations

from typing import Protocol

from ..models import (
    LearningGenerationRequestV1,
    LearningGenerationResponseV1,
    NoteQueryRequestV1,
    NoteQueryResponseV1,
    ProviderTraceV1,
    SessionDigestRequestV1,
    SessionDigestV1,
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
