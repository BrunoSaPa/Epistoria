from __future__ import annotations

from datetime import datetime
from enum import StrEnum
from typing import Annotated, Literal
from uuid import UUID

from pydantic import (
    AwareDatetime,
    BaseModel,
    ConfigDict,
    Field,
    StringConstraints,
    model_validator,
)
from pydantic.alias_generators import to_camel

ShortText = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=500)]
BodyText = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=12_000)]


class ContractModel(BaseModel):
    model_config = ConfigDict(
        alias_generator=to_camel,
        populate_by_name=True,
        extra="forbid",
        str_strip_whitespace=True,
    )


class SourceKind(StrEnum):
    NOTE_BLOCK = "NOTE_BLOCK"
    ANNOTATION = "ANNOTATION"
    PDF_PAGE = "PDF_PAGE"


class NoteQuerySourceKind(StrEnum):
    NOTE_BLOCK = "NOTE_BLOCK"
    LASSO_SELECTION = "LASSO_SELECTION"


class SourceExcerptV1(ContractModel):
    source_id: UUID
    source_kind: SourceKind
    title: ShortText
    locator: ShortText
    excerpt: BodyText


class SessionDigestRequestV1(ContractModel):
    schema_version: Literal["session-digest-request/v1"] = "session-digest-request/v1"
    account_id: UUID
    job_id: UUID
    session_id: UUID
    course_id: UUID | None = None
    session_title: ShortText
    started_at: AwareDatetime
    ended_at: AwareDatetime
    sources: list[SourceExcerptV1] = Field(min_length=1, max_length=200)
    user_instructions: Annotated[
        str | None, StringConstraints(strip_whitespace=True, max_length=2_000)
    ] = None
    disclosure_acknowledged: Literal[True]

    @model_validator(mode="after")
    def validate_session(self) -> SessionDigestRequestV1:
        if self.ended_at < self.started_at:
            raise ValueError("endedAt cannot precede startedAt")
        ids = [source.source_id for source in self.sources]
        if len(ids) != len(set(ids)):
            raise ValueError("source IDs must be unique")
        return self


class CitedStatementV1(ContractModel):
    text: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=2_000)]
    source_ids: list[UUID] = Field(min_length=1, max_length=16)


class SessionDigestV1(ContractModel):
    schema_version: Literal["session-digest/v1"] = "session-digest/v1"
    title: ShortText
    summary: Annotated[
        str, StringConstraints(strip_whitespace=True, min_length=1, max_length=4_000)
    ]
    key_points: list[CitedStatementV1] = Field(min_length=1, max_length=20)
    possible_misconceptions: list[CitedStatementV1] = Field(default_factory=list, max_length=10)
    follow_up_questions: list[ShortText] = Field(default_factory=list, max_length=10)


class ProviderTraceV1(ContractModel):
    provider: ShortText
    model: ShortText
    prompt_version: ShortText
    input_tokens: int | None = Field(default=None, ge=0)
    output_tokens: int | None = Field(default=None, ge=0)
    estimated_cost_usd: float | None = Field(default=None, ge=0)
    provider_request_id: Annotated[
        str | None, StringConstraints(strip_whitespace=True, max_length=200)
    ] = None


class SessionDigestArtifactV1(ContractModel):
    schema_version: Literal["ai-artifact/session-digest/v1"] = "ai-artifact/session-digest/v1"
    job_id: UUID
    session_id: UUID
    generated_at: AwareDatetime
    source_ids: list[UUID] = Field(min_length=1, max_length=200)
    trace: ProviderTraceV1
    digest: SessionDigestV1


class PDFExtractionRequestV1(ContractModel):
    schema_version: Literal["pdf-extraction-request/v1"] = "pdf-extraction-request/v1"
    account_id: UUID
    job_id: UUID
    resource_id: UUID
    asset_id: UUID
    asset_key: str = Field(min_length=43, max_length=43, pattern=r"^[A-Za-z0-9_-]+$")
    expected_dedupe_tag: str = Field(min_length=64, max_length=64, pattern=r"^[0-9a-f]{64}$")
    title: ShortText


class PDFPageV1(ContractModel):
    page_number: int = Field(ge=1)
    text: str = Field(max_length=1_500_000)
    character_count: int = Field(ge=0)
    needs_ocr: bool


class PDFExtractionChunkV1(ContractModel):
    schema_version: Literal["pdf-extraction-chunk/v1"] = "pdf-extraction-chunk/v1"
    job_id: UUID
    resource_id: UUID
    chunk_index: int = Field(ge=0)
    pages: list[PDFPageV1] = Field(min_length=1)


class PDFExtractionManifestV1(ContractModel):
    schema_version: Literal["ai-artifact/pdf-extraction/v1"] = "ai-artifact/pdf-extraction/v1"
    job_id: UUID
    resource_id: UUID
    generated_at: AwareDatetime
    page_count: int = Field(ge=1)
    character_count: int = Field(ge=0)
    pages_needing_ocr: list[int]
    chunk_entity_ids: list[UUID] = Field(min_length=1, max_length=64)


# 2 MiB base64 max length = ceil(2_097_152 / 3) * 4 = 2_796_204 chars
_MAX_IMAGE_B64_LEN = 2_796_204


class NoteQuerySourceV1(ContractModel):
    source_id: UUID
    source_kind: NoteQuerySourceKind
    title: ShortText
    locator: ShortText
    excerpt: BodyText | None = None
    image_content: Annotated[
        str | None, StringConstraints(max_length=_MAX_IMAGE_B64_LEN)
    ] = None

    @model_validator(mode="after")
    def validate_content(self) -> NoteQuerySourceV1:
        if self.excerpt is None and self.image_content is None:
            raise ValueError("NoteQuerySource must have either excerpt or imageContent")
        return self


class NoteQueryRequestV1(ContractModel):
    schema_version: Literal["note-query-request/v1"] = "note-query-request/v1"
    account_id: UUID
    job_id: UUID
    note_id: UUID
    note_title: ShortText | None = None
    question: Annotated[
        str,
        StringConstraints(strip_whitespace=True, min_length=1, max_length=2_000),
    ]
    selection_sources: list[NoteQuerySourceV1] = Field(min_length=1, max_length=10)
    context_sources: list[NoteQuerySourceV1] = Field(default_factory=list, max_length=200)
    disclosure_acknowledged: Literal[True]

    @model_validator(mode="after")
    def validate_source_ids_unique(self) -> NoteQueryRequestV1:
        ids = [s.source_id for s in self.selection_sources + self.context_sources]
        if len(ids) != len(set(ids)):
            raise ValueError("source IDs must be unique across selection and context")
        return self


class NoteQueryResponseV1(ContractModel):
    schema_version: Literal["note-query-response/v1"] = "note-query-response/v1"
    answer: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=4_000)]
    cited_source_ids: list[UUID] = Field(min_length=1, max_length=20)
    follow_up_questions: list[ShortText] = Field(default_factory=list, max_length=5)


class NoteQueryArtifactV1(ContractModel):
    schema_version: Literal["ai-artifact/note-query/v1"] = "ai-artifact/note-query/v1"
    job_id: UUID
    note_id: UUID
    question: Annotated[
        str,
        StringConstraints(strip_whitespace=True, min_length=1, max_length=2_000),
    ]
    generated_at: AwareDatetime
    source_ids: list[UUID] = Field(min_length=1, max_length=220)
    trace: ProviderTraceV1
    response: NoteQueryResponseV1


LearningJobType = Literal[
    "SOURCE_EXTRACTION",
    "TRANSCRIPTION",
    "TOPIC_SYNTHESIS",
    "FLASHCARD_DRAFTS",
    "TEST_BLUEPRINT",
    "TEST_GENERATION",
    "FREE_RESPONSE_FEEDBACK",
    "CONCEPT_SUGGESTIONS",
    "SOURCE_DISCOVERY",
    "SESSION_REVIEW",
    "WEEKLY_REVIEW",
]


class LearningGenerationRequestV1(ContractModel):
    schema_version: Literal["learning-generation-request/v1"] = "learning-generation-request/v1"
    account_id: UUID
    job_id: UUID
    job_type: LearningJobType
    topic_id: UUID
    include_connected_knowledge: bool = False
    user_instructions: Annotated[
        str | None, StringConstraints(strip_whitespace=True, max_length=2_000)
    ] = None
    sources: list[SourceExcerptV1] = Field(min_length=1, max_length=200)
    objective_titles: list[ShortText] = Field(default_factory=list, max_length=100)
    disclosure_acknowledged: Literal[True]

    @model_validator(mode="after")
    def validate_source_ids_unique(self) -> LearningGenerationRequestV1:
        ids = [source.source_id for source in self.sources]
        if len(ids) != len(set(ids)):
            raise ValueError("source IDs must be unique")
        return self


class LearningDraftItemV1(ContractModel):
    id: UUID
    kind: ShortText
    title: ShortText
    body: BodyText
    answer: BodyText | None = None
    choices: list[ShortText] = Field(default_factory=list, max_length=20)
    objective_titles: list[ShortText] = Field(default_factory=list, max_length=20)
    cited_source_ids: list[UUID] = Field(min_length=1, max_length=32)


class LearningGenerationResponseV1(ContractModel):
    schema_version: Literal["learning-generation-response/v1"] = (
        "learning-generation-response/v1"
    )
    summary: BodyText
    items: list[LearningDraftItemV1] = Field(min_length=1, max_length=100)
    coverage_gaps: list[ShortText] = Field(default_factory=list, max_length=100)


class LearningGenerationArtifactV1(ContractModel):
    schema_version: Literal["ai-artifact/learning-generation/v1"] = (
        "ai-artifact/learning-generation/v1"
    )
    job_id: UUID
    job_type: LearningJobType
    topic_id: UUID
    include_connected_knowledge: bool
    generated_at: AwareDatetime
    source_ids: list[UUID] = Field(min_length=1, max_length=200)
    trace: ProviderTraceV1
    response: LearningGenerationResponseV1


class AIJobLease(ContractModel):
    id: UUID
    job_type: Literal[
        "SESSION_DIGEST",
        "PDF_EXTRACTION",
        "NOTE_QUERY",
        "SOURCE_EXTRACTION",
        "TRANSCRIPTION",
        "TOPIC_SYNTHESIS",
        "FLASHCARD_DRAFTS",
        "TEST_BLUEPRINT",
        "TEST_GENERATION",
        "FREE_RESPONSE_FEEDBACK",
        "CONCEPT_SUGGESTIONS",
        "SOURCE_DISCOVERY",
        "SESSION_REVIEW",
        "WEEKLY_REVIEW",
    ]
    crypto_version: int = Field(ge=1, le=255)
    content_version: int = Field(ge=1, le=65_535)
    sealed_dek: str
    sealed_payload: str
    payload_size: int = Field(ge=1, le=1_048_576)
    attempts: int = Field(ge=1)
    lease_expires_at: datetime
