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
ProviderAdapter = Literal[
    "OPENAI_RESPONSES",
    "OPENAI_COMPATIBLE",
    "ANTHROPIC_MESSAGES",
    "GEMINI_GENERATE_CONTENT",
]
ProviderCapability = Literal["TEXT", "VISION", "TRANSCRIPTION", "STRUCTURED_OUTPUT"]


class ContractModel(BaseModel):
    model_config = ConfigDict(
        alias_generator=to_camel,
        populate_by_name=True,
        extra="forbid",
        str_strip_whitespace=True,
    )


class ProviderRouteSnapshotV1(ContractModel):
    schema_version: Literal["provider-route/v1"] = "provider-route/v1"
    profile_id: UUID
    configuration_revision_id: UUID
    display_name: ShortText
    adapter: ProviderAdapter
    base_url: str = Field(min_length=1, max_length=2048)
    text_model: ShortText
    transcription_model: ShortText | None = None
    capabilities: list[ProviderCapability] = Field(min_length=1, max_length=4)
    structured_output: bool

    @model_validator(mode="after")
    def validate_capabilities_unique(self) -> ProviderRouteSnapshotV1:
        if len(self.capabilities) != len(set(self.capabilities)):
            raise ValueError("provider route capabilities must be unique")
        return self


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
    provider_route: ProviderRouteSnapshotV1 | None = None

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


class SourceRectangleV1(ContractModel):
    """A normalized, top-left-origin rectangle within one source page."""

    x: float = Field(ge=0, le=1)
    y: float = Field(ge=0, le=1)
    width: float = Field(gt=0, le=1)
    height: float = Field(gt=0, le=1)

    @model_validator(mode="after")
    def validate_bounds(self) -> SourceRectangleV1:
        if self.x + self.width > 1.000_001 or self.y + self.height > 1.000_001:
            raise ValueError("source rectangle exceeds page bounds")
        return self


SourceMaterialKind = Literal["TEXT", "IMAGE"]


class SourceMaterialV1(ContractModel):
    source_id: UUID
    kind: SourceMaterialKind
    page_number: int = Field(ge=1)
    rectangles: list[SourceRectangleV1] = Field(min_length=1, max_length=8)
    excerpt: Annotated[
        str, StringConstraints(strip_whitespace=True, min_length=1, max_length=4_000)
    ]
    image_content: Annotated[
        str | None, StringConstraints(strip_whitespace=True, min_length=4, max_length=2_800_000)
    ] = None

    @model_validator(mode="after")
    def validate_material(self) -> SourceMaterialV1:
        if self.kind == "IMAGE" and self.image_content is None:
            raise ValueError("image material requires imageContent")
        if self.kind == "TEXT" and self.image_content is not None:
            raise ValueError("text material cannot contain imageContent")
        return self


class SourceCitationV1(ContractModel):
    source_id: UUID
    kind: SourceMaterialKind
    page_number: int = Field(ge=1)
    rectangles: list[SourceRectangleV1] = Field(min_length=1, max_length=8)
    excerpt: Annotated[
        str, StringConstraints(strip_whitespace=True, min_length=1, max_length=4_000)
    ]


class SourceAnalysisRequestV1(ContractModel):
    schema_version: Literal["source-analysis-request/v1"] = "source-analysis-request/v1"
    account_id: UUID
    job_id: UUID
    source_id: UUID
    source_version_id: UUID
    title: ShortText
    output_language: Annotated[
        str, StringConstraints(strip_whitespace=True, min_length=2, max_length=64)
    ]
    asset_id: UUID
    asset_key: str = Field(min_length=43, max_length=43, pattern=r"^[A-Za-z0-9_-]+$")
    expected_dedupe_tag: str = Field(min_length=64, max_length=64, pattern=r"^[0-9a-f]{64}$")
    include_images: bool
    disclosure_acknowledged: Literal[True]
    provider_route: ProviderRouteSnapshotV1 | None = None


class SourceQueryRequestV1(ContractModel):
    schema_version: Literal["source-query-request/v1"] = "source-query-request/v1"
    account_id: UUID
    job_id: UUID
    source_id: UUID
    source_version_id: UUID
    title: ShortText
    output_language: Annotated[
        str, StringConstraints(strip_whitespace=True, min_length=2, max_length=64)
    ]
    asset_id: UUID
    asset_key: str = Field(min_length=43, max_length=43, pattern=r"^[A-Za-z0-9_-]+$")
    expected_dedupe_tag: str = Field(min_length=64, max_length=64, pattern=r"^[0-9a-f]{64}$")
    include_images: bool
    disclosure_acknowledged: Literal[True]
    question: Annotated[
        str, StringConstraints(strip_whitespace=True, min_length=1, max_length=2_000)
    ]
    provider_route: ProviderRouteSnapshotV1 | None = None


class SourceGuidePromptV1(ContractModel):
    schema_version: Literal["source-guide-prompt/v1"] = "source-guide-prompt/v1"
    title: ShortText
    output_language: Annotated[
        str, StringConstraints(strip_whitespace=True, min_length=2, max_length=64)
    ]
    materials: list[SourceMaterialV1] = Field(min_length=1, max_length=240)
    provider_route: ProviderRouteSnapshotV1 | None = None


class SourceQueryPromptV1(ContractModel):
    schema_version: Literal["source-query-prompt/v1"] = "source-query-prompt/v1"
    title: ShortText
    output_language: Annotated[
        str, StringConstraints(strip_whitespace=True, min_length=2, max_length=64)
    ]
    materials: list[SourceMaterialV1] = Field(min_length=1, max_length=240)
    provider_route: ProviderRouteSnapshotV1 | None = None
    question: Annotated[
        str, StringConstraints(strip_whitespace=True, min_length=1, max_length=2_000)
    ]


class SourceGuideStatementV1(ContractModel):
    text: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=2_000)]
    source_ids: list[UUID] = Field(min_length=1, max_length=16)


class SourceGuideTopicV1(ContractModel):
    title: ShortText
    explanation: Annotated[
        str, StringConstraints(strip_whitespace=True, min_length=1, max_length=2_000)
    ]
    source_ids: list[UUID] = Field(min_length=1, max_length=16)


class SuggestedSourceQuestionV1(ContractModel):
    question: ShortText
    source_ids: list[UUID] = Field(min_length=1, max_length=16)


class SourceGuideResponseV1(ContractModel):
    schema_version: Literal["source-guide-response/v1"] = "source-guide-response/v1"
    source_language: ShortText
    output_language: ShortText
    summary: list[SourceGuideStatementV1] = Field(min_length=1, max_length=12)
    translated_summary: list[SourceGuideStatementV1] = Field(default_factory=list, max_length=12)
    key_topics: list[SourceGuideTopicV1] = Field(default_factory=list, max_length=16)
    suggested_questions: list[SuggestedSourceQuestionV1] = Field(
        default_factory=list, max_length=12
    )
    image_insights: list[SourceGuideStatementV1] = Field(default_factory=list, max_length=12)
    coverage_gaps: list[ShortText] = Field(default_factory=list, max_length=20)


class SourceQueryResponseV1(ContractModel):
    schema_version: Literal["source-query-response/v1"] = "source-query-response/v1"
    answer: list[SourceGuideStatementV1] = Field(min_length=1, max_length=20)
    insufficient_evidence: bool
    follow_up_questions: list[ShortText] = Field(default_factory=list, max_length=5)


class SourceAnalysisArtifactV1(ContractModel):
    schema_version: Literal["ai-artifact/source-analysis/v1"] = "ai-artifact/source-analysis/v1"
    job_id: UUID
    source_id: UUID
    source_version_id: UUID
    generated_at: AwareDatetime
    page_count: int = Field(ge=1)
    analyzed_page_count: int = Field(ge=1)
    references: list[SourceCitationV1] = Field(min_length=1, max_length=240)
    trace: ProviderTraceV1
    guide: SourceGuideResponseV1


class SourceQueryArtifactV1(ContractModel):
    schema_version: Literal["ai-artifact/source-query/v1"] = "ai-artifact/source-query/v1"
    job_id: UUID
    source_id: UUID
    source_version_id: UUID
    question: Annotated[
        str, StringConstraints(strip_whitespace=True, min_length=1, max_length=2_000)
    ]
    generated_at: AwareDatetime
    references: list[SourceCitationV1] = Field(min_length=1, max_length=80)
    trace: ProviderTraceV1
    response: SourceQueryResponseV1


class MediaTranscriptionRequestV1(ContractModel):
    schema_version: Literal["media-transcription-request/v1"] = "media-transcription-request/v1"
    account_id: UUID
    job_id: UUID
    source_id: UUID
    source_version_id: UUID
    source_type: Literal["AUDIO", "VIDEO"]
    asset_id: UUID
    asset_key: str = Field(min_length=43, max_length=43, pattern=r"^[A-Za-z0-9_-]+$")
    expected_dedupe_tag: str = Field(min_length=64, max_length=64, pattern=r"^[0-9a-f]{64}$")
    expected_plaintext_bytes: int = Field(ge=1, le=25 * 1024 * 1024)
    filename: ShortText
    mime_type: ShortText
    language: Annotated[
        str | None, StringConstraints(strip_whitespace=True, min_length=2, max_length=16)
    ] = None
    disclosure_acknowledged: Literal[True]
    provider_route: ProviderRouteSnapshotV1 | None = None

    @model_validator(mode="after")
    def validate_media_metadata(self) -> MediaTranscriptionRequestV1:
        if "/" in self.filename or "\\" in self.filename or "\x00" in self.filename:
            raise ValueError("transcription filename must be a basename")
        extension = self.filename.rpartition(".")[2].lower()
        allowed: dict[tuple[str, str], set[str]] = {
            ("AUDIO", "mp3"): {"audio/mpeg", "audio/mp3"},
            ("AUDIO", "m4a"): {"audio/mp4", "audio/x-m4a"},
            ("AUDIO", "wav"): {"audio/wav", "audio/x-wav", "audio/vnd.wave"},
            ("VIDEO", "mp4"): {"video/mp4"},
        }
        mime_types = allowed.get((self.source_type, extension))
        if mime_types is None or self.mime_type.lower() not in mime_types:
            raise ValueError("transcription media metadata is unsupported")
        return self


class TranscriptSegmentV1(ContractModel):
    index: int = Field(ge=0)
    start_seconds: float = Field(ge=0)
    end_seconds: float = Field(ge=0)
    text: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=12_000)]

    @model_validator(mode="after")
    def validate_time_range(self) -> TranscriptSegmentV1:
        if self.end_seconds < self.start_seconds:
            raise ValueError("transcript segment end cannot precede its start")
        return self


class MediaTranscriptionResponseV1(ContractModel):
    language: Annotated[
        str | None, StringConstraints(strip_whitespace=True, min_length=2, max_length=32)
    ] = None
    duration_seconds: float = Field(gt=0, le=604_800)
    segments: list[TranscriptSegmentV1] = Field(min_length=1, max_length=100_000)

    @model_validator(mode="after")
    def validate_segments(self) -> MediaTranscriptionResponseV1:
        for expected, segment in enumerate(self.segments):
            if segment.index != expected:
                raise ValueError("transcript segment indexes must be contiguous")
            if segment.end_seconds > self.duration_seconds + 1:
                raise ValueError("transcript segment exceeds media duration")
            if expected and segment.start_seconds < self.segments[expected - 1].start_seconds:
                raise ValueError("transcript segments must be ordered")
        return self


class MediaTranscriptionChunkV1(ContractModel):
    schema_version: Literal["media-transcription-chunk/v1"] = "media-transcription-chunk/v1"
    job_id: UUID
    source_id: UUID
    source_version_id: UUID
    chunk_index: int = Field(ge=0)
    segments: list[TranscriptSegmentV1] = Field(min_length=1, max_length=500)


class MediaTranscriptionManifestV1(ContractModel):
    schema_version: Literal["ai-artifact/media-transcription/v1"] = (
        "ai-artifact/media-transcription/v1"
    )
    job_id: UUID
    source_id: UUID
    source_version_id: UUID
    generated_at: AwareDatetime
    language: Annotated[
        str | None, StringConstraints(strip_whitespace=True, min_length=2, max_length=32)
    ] = None
    duration_seconds: float = Field(gt=0, le=604_800)
    character_count: int = Field(ge=1, le=5_000_000)
    segment_count: int = Field(ge=1, le=100_000)
    trace: ProviderTraceV1
    chunk_entity_ids: list[UUID] = Field(min_length=1, max_length=64)


# 2 MiB base64 max length = ceil(2_097_152 / 3) * 4 = 2_796_204 chars
_MAX_IMAGE_B64_LEN = 2_796_204


class NoteQuerySourceV1(ContractModel):
    source_id: UUID
    source_kind: NoteQuerySourceKind
    title: ShortText
    locator: ShortText
    excerpt: BodyText | None = None
    image_content: Annotated[str | None, StringConstraints(max_length=_MAX_IMAGE_B64_LEN)] = None

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
    provider_route: ProviderRouteSnapshotV1 | None = None

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


FeedbackEvidenceKind = Literal["QUESTION_SNAPSHOT", "NOTE_BLOCK", "EVIDENCE"]


class FeedbackEvidenceExcerptV1(ContractModel):
    source_id: UUID
    source_kind: FeedbackEvidenceKind
    title: ShortText
    locator: ShortText
    excerpt: BodyText


class FreeResponseFeedbackRequestV1(ContractModel):
    schema_version: Literal["free-response-feedback-request/v1"] = (
        "free-response-feedback-request/v1"
    )
    account_id: UUID
    job_id: UUID
    attempt_id: UUID
    response_id: UUID
    question_id: UUID
    topic_id: UUID
    question_kind: ShortText
    prompt: BodyText
    rubric: BodyText
    reference_answer: BodyText
    user_response: BodyText
    confidence: int | None = Field(default=None, ge=1, le=5)
    evidence: list[FeedbackEvidenceExcerptV1] = Field(min_length=1, max_length=50)
    disclosure_acknowledged: Literal[True]
    provider_route: ProviderRouteSnapshotV1 | None = None

    @model_validator(mode="after")
    def validate_evidence_ids_unique(self) -> FreeResponseFeedbackRequestV1:
        ids = [item.source_id for item in self.evidence]
        if len(ids) != len(set(ids)):
            raise ValueError("feedback evidence IDs must be unique")
        return self


class FreeResponseFeedbackResponseV1(ContractModel):
    schema_version: Literal["free-response-feedback-response/v1"] = (
        "free-response-feedback-response/v1"
    )
    feedback: BodyText
    strengths: list[ShortText] = Field(default_factory=list, max_length=10)
    improvements: list[ShortText] = Field(default_factory=list, max_length=10)
    proposed_score: float = Field(ge=0, le=1)
    uncertainty: ShortText
    cited_source_ids: list[UUID] = Field(min_length=1, max_length=32)


class FreeResponseFeedbackArtifactV1(ContractModel):
    schema_version: Literal["ai-artifact/free-response-feedback/v1"] = (
        "ai-artifact/free-response-feedback/v1"
    )
    job_id: UUID
    attempt_id: UUID
    response_id: UUID
    question_id: UUID
    topic_id: UUID
    generated_at: AwareDatetime
    source_ids: list[UUID] = Field(min_length=1, max_length=50)
    trace: ProviderTraceV1
    response: FreeResponseFeedbackResponseV1


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

TestMode = Literal["COMPREHENSIVE", "QUICK_CHECK", "CUSTOM"]
TestCoverageDimension = Literal[
    "PREREQUISITE",
    "CONCEPTUAL",
    "METHOD_SELECTION",
    "PROCEDURAL",
    "VERIFICATION",
    "ERROR_ANALYSIS",
    "INTEGRATED",
]


class TestGenerationPlanV1(ContractModel):
    schema_version: Literal["test-generation-plan/v1"] = "test-generation-plan/v1"
    mode: TestMode
    question_count: int = Field(ge=1, le=100)
    time_limit_minutes: int | None = Field(default=None, ge=1, le=600)
    coverage_dimensions: list[TestCoverageDimension] = Field(min_length=1, max_length=7)
    objective_titles: list[ShortText] = Field(min_length=1, max_length=100)

    @model_validator(mode="after")
    def validate_unique_plan_values(self) -> TestGenerationPlanV1:
        if len(self.coverage_dimensions) != len(set(self.coverage_dimensions)):
            raise ValueError("coverage dimensions must be unique")
        normalized = [title.casefold() for title in self.objective_titles]
        if len(normalized) != len(set(normalized)):
            raise ValueError("objective titles must be unique")
        return self


class AutomationAuthorizationV1(ContractModel):
    schema_version: Literal["automation-authorization/v1"] = "automation-authorization/v1"
    grant_id: UUID
    topic_ids: list[UUID] = Field(min_length=1, max_length=100)
    job_types: list[LearningJobType] = Field(min_length=1, max_length=10)
    minimum_interval_hours: int = Field(ge=1, le=8_760)
    expires_at: AwareDatetime
    spending_limit_minor_units: int = Field(gt=0, le=10_000_000)
    currency_code: Literal["USD"]
    authorized_at: AwareDatetime
    scope_key: Annotated[
        str, StringConstraints(strip_whitespace=True, min_length=1, max_length=200)
    ]
    input_fingerprint: Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{64}$")]

    @model_validator(mode="after")
    def validate_unique_scope(self) -> AutomationAuthorizationV1:
        if len(self.topic_ids) != len(set(self.topic_ids)):
            raise ValueError("automation Topic IDs must be unique")
        if len(self.job_types) != len(set(self.job_types)):
            raise ValueError("automation job types must be unique")
        return self


class KnownConceptReferenceV1(ContractModel):
    id: UUID
    name: ShortText
    aliases: list[ShortText] = Field(default_factory=list, max_length=50)


class LearningGenerationRequestV1(ContractModel):
    schema_version: Literal[
        "learning-generation-request/v1",
        "learning-generation-request/v2",
        "learning-generation-request/v3",
        "learning-generation-request/v4",
    ] = "learning-generation-request/v4"
    account_id: UUID
    job_id: UUID
    job_type: LearningJobType
    topic_id: UUID
    include_connected_knowledge: bool = False
    user_instructions: Annotated[
        str | None, StringConstraints(strip_whitespace=True, max_length=2_000)
    ] = None
    sources: list[SourceExcerptV1] = Field(min_length=1, max_length=200)
    known_concepts: list[KnownConceptReferenceV1] = Field(default_factory=list, max_length=200)
    objective_titles: list[ShortText] = Field(default_factory=list, max_length=100)
    test_plan: TestGenerationPlanV1 | None = None
    automation_authorization: AutomationAuthorizationV1 | None = None
    disclosure_acknowledged: Literal[True]
    provider_route: ProviderRouteSnapshotV1 | None = None

    @model_validator(mode="after")
    def validate_source_ids_unique(self) -> LearningGenerationRequestV1:
        ids = [source.source_id for source in self.sources]
        if len(ids) != len(set(ids)):
            raise ValueError("source IDs must be unique")
        concept_ids = [concept.id for concept in self.known_concepts]
        if len(concept_ids) != len(set(concept_ids)):
            raise ValueError("known Concept IDs must be unique")
        if self.job_type in {"TEST_BLUEPRINT", "TEST_GENERATION"} and self.test_plan is not None:
            if self.objective_titles != self.test_plan.objective_titles:
                raise ValueError("objectiveTitles must match testPlan.objectiveTitles")
        if self.automation_authorization is not None:
            authorization = self.automation_authorization
            if self.topic_id not in authorization.topic_ids:
                raise ValueError("automation does not allow this Topic")
            if self.job_type not in authorization.job_types:
                raise ValueError("automation does not allow this job type")
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


ConceptLinkKind = Literal["PREREQUISITE", "PART_OF", "RELATED", "CONTRASTS", "APPLIES"]


class ConceptLinkDraftV1(ContractModel):
    id: UUID
    source_concept_id: UUID | None = None
    source_concept_name: ShortText
    target_concept_id: UUID | None = None
    target_concept_name: ShortText
    relation: ConceptLinkKind
    rationale: BodyText
    cited_source_ids: list[UUID] = Field(min_length=1, max_length=32)


class LearningGenerationResponseV1(ContractModel):
    schema_version: Literal[
        "learning-generation-response/v1", "learning-generation-response/v2"
    ] = "learning-generation-response/v2"
    summary: BodyText
    items: list[LearningDraftItemV1] = Field(min_length=1, max_length=100)
    concept_links: list[ConceptLinkDraftV1] = Field(default_factory=list, max_length=100)
    coverage_gaps: list[ShortText] = Field(default_factory=list, max_length=100)


class LearningGenerationArtifactV1(ContractModel):
    schema_version: Literal[
        "ai-artifact/learning-generation/v1", "ai-artifact/learning-generation/v2"
    ] = "ai-artifact/learning-generation/v2"
    job_id: UUID
    job_type: LearningJobType
    topic_id: UUID
    include_connected_knowledge: bool
    generated_at: AwareDatetime
    source_ids: list[UUID] = Field(min_length=1, max_length=200)
    trace: ProviderTraceV1
    response: LearningGenerationResponseV1
    test_plan: TestGenerationPlanV1 | None = None
    known_concept_ids: list[UUID] = Field(default_factory=list, max_length=200)


ProviderConfigurationOperation = Literal["UPSERT", "ACTIVATE", "DELETE"]


class ProviderConfigurationRequestV1(ContractModel):
    schema_version: Literal["provider-configuration-request/v1"] = (
        "provider-configuration-request/v1"
    )
    account_id: UUID
    job_id: UUID
    operation: ProviderConfigurationOperation
    profile_id: UUID
    configuration_revision_id: UUID | None = None
    display_name: ShortText | None = None
    adapter: ProviderAdapter | None = None
    base_url: str | None = Field(default=None, max_length=2048)
    api_key: str | None = Field(default=None, min_length=1, max_length=8192, repr=False)
    text_model: ShortText | None = None
    transcription_model: ShortText | None = None
    capabilities: list[ProviderCapability] = Field(default_factory=list, max_length=4)
    structured_output: bool = True
    input_usd_per_million: float | None = Field(default=None, ge=0)
    output_usd_per_million: float | None = Field(default=None, ge=0)
    transcription_usd_per_minute: float | None = Field(default=None, ge=0)
    make_active: bool = False
    disclosure_acknowledged: bool


class ProviderConfigurationArtifactV1(ContractModel):
    schema_version: Literal["ai-artifact/provider-configuration/v1"] = (
        "ai-artifact/provider-configuration/v1"
    )
    job_id: UUID
    profile_id: UUID
    configuration_revision_id: UUID | None = None
    operation: ProviderConfigurationOperation
    display_name: ShortText | None = None
    adapter: ProviderAdapter | None = None
    base_url: str | None = None
    text_model: ShortText | None = None
    transcription_model: ShortText | None = None
    capabilities: list[ProviderCapability] = Field(default_factory=list, max_length=4)
    is_active: bool
    secret_stored: bool
    configured_at: AwareDatetime


class AIJobLease(ContractModel):
    id: UUID
    job_type: Literal[
        "SESSION_DIGEST",
        "PDF_EXTRACTION",
        "NOTE_QUERY",
        "SOURCE_ANALYSIS",
        "SOURCE_QUERY",
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
        "PROVIDER_CONFIGURATION",
    ]
    crypto_version: int = Field(ge=1, le=255)
    content_version: int = Field(ge=1, le=65_535)
    sealed_dek: str
    sealed_payload: str
    payload_size: int = Field(ge=1, le=1_048_576)
    attempts: int = Field(ge=1)
    lease_expires_at: datetime
