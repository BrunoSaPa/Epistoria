from __future__ import annotations

import base64
import io
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any, Literal
from uuid import UUID, uuid4

import pytest
from reportlab.pdfgen.canvas import Canvas

from epistoria_worker import base64url
from epistoria_worker.api import APIError
from epistoria_worker.asset_crypto import encrypt_bytes, plaintext_dedupe_tag
from epistoria_worker.canonical import json_bytes
from epistoria_worker.cost_ledger import CostLedger
from epistoria_worker.crypto import (
    EncryptedEnvelope,
    decrypt_payload,
    encrypt_payload,
    entity_aad,
    job_aad,
)
from epistoria_worker.keychain import MemoryProviderProfileStore
from epistoria_worker.local_ocr import DeterministicLocalOCREngine
from epistoria_worker.models import (
    AIJobLease,
    AutomationAuthorizationV1,
    FeedbackEvidenceExcerptV1,
    FreeResponseFeedbackArtifactV1,
    FreeResponseFeedbackRequestV1,
    KnownConceptReferenceV1,
    LearningGenerationArtifactV1,
    LearningGenerationRequestV1,
    LocalOCRRequestV1,
    MathAssistanceArtifactV1,
    MathAssistanceRequestV1,
    MediaTranscriptionChunkV1,
    MediaTranscriptionManifestV1,
    MediaTranscriptionRequestV1,
    OCRArtifactV1,
    PDFExtractionManifestV1,
    PDFExtractionRequestV1,
    PDFExtractionRequestV2,
    ProviderConfigurationArtifactV1,
    ProviderConfigurationRequestV1,
    SessionDigestArtifactV1,
    SessionDigestRequestV1,
    SourceAnalysisArtifactV1,
    SourceAnalysisRequestV1,
    SourceExcerptV1,
    SourceKind,
    SourceQueryArtifactV1,
    SourceQueryRequestV1,
    TutorSessionAuthorizationV1,
    TutorSourceExcerptV1,
    TutorSourceLocatorV1,
    TutorTurnArtifactV1,
    TutorTurnRequestV1,
)
from epistoria_worker.models import TestGenerationPlanV1 as GenerationPlanV1
from epistoria_worker.outbox import EncryptedOutbox
from epistoria_worker.processor import WorkerProcessor
from epistoria_worker.providers.fake import DeterministicDigestProvider
from epistoria_worker.providers.manager import ProviderManager

ACCOUNT_ID = UUID("11111111-1111-4111-8111-111111111111")
ACCOUNT_KEY = bytes(range(32))
TRANSCRIPTION_WAVE = b"RIFF\x04\x00\x00\x00WAVE"


def lease_for(
    job_type: Literal[
        "SESSION_DIGEST",
        "PDF_EXTRACTION",
        "SOURCE_ANALYSIS",
        "SOURCE_QUERY",
        "TRANSCRIPTION",
        "FLASHCARD_DRAFTS",
        "TEST_GENERATION",
        "FREE_RESPONSE_FEEDBACK",
        "PROVIDER_CONFIGURATION",
        "TUTOR_TURN",
        "MATH_ASSISTANCE",
        "LOCAL_OCR",
        "LOCAL_MODEL_CONTROL",
    ],
    payload: bytes,
    job_id: UUID | None = None,
) -> AIJobLease:
    actual_id = job_id or uuid4()
    envelope = encrypt_payload(
        payload,
        account_key=ACCOUNT_KEY,
        account_id=ACCOUNT_ID,
        aad=job_aad(ACCOUNT_ID, job_type, actual_id, 1),
    )
    return AIJobLease(
        id=actual_id,
        job_type=job_type,
        crypto_version=1,
        content_version=1,
        sealed_dek=base64url.encode(envelope.sealed_dek),
        sealed_payload=base64url.encode(envelope.sealed_content),
        payload_size=envelope.payload_size,
        attempts=1,
        lease_expires_at=datetime.now(UTC) + timedelta(minutes=5),
    )


class FakeAPI:
    def __init__(self, leases: list[AIJobLease], *, encrypted_asset: bytes | None = None) -> None:
        self.leases = leases
        self.encrypted_asset = encrypted_asset
        self.pushed: list[dict[str, Any]] = []
        self.completed: list[tuple[UUID, UUID]] = []
        self.failed: list[tuple[UUID, str, bool]] = []
        self.fail_next_push = False

    def claim_job(self) -> AIJobLease | None:
        return self.leases.pop(0) if self.leases else None

    def push_mutations(self, mutations: list[dict[str, Any]]) -> None:
        if self.fail_next_push:
            self.fail_next_push = False
            raise APIError("synthetic outage", retryable=True)
        self.pushed.extend(mutations)

    def complete_job(self, job_id: UUID, *, artifact_entity_id: UUID) -> None:
        self.completed.append((job_id, artifact_entity_id))

    def fail_job(self, job_id: UUID, *, error_code: str, retryable: bool) -> None:
        self.failed.append((job_id, error_code, retryable))

    def download_encrypted_asset(self, _asset_id: UUID, *, maximum_bytes: int) -> bytes:
        assert self.encrypted_asset is not None
        assert len(self.encrypted_asset) <= maximum_bytes
        return self.encrypted_asset


class CountingProvider(DeterministicDigestProvider):
    def __init__(self) -> None:
        self.calls = 0

    def generate(self, request: SessionDigestRequestV1):
        self.calls += 1
        return super().generate(request)


class TranscriptionCountingProvider(DeterministicDigestProvider):
    def __init__(self) -> None:
        self.calls = 0

    def transcribe_media(self, **kwargs):
        self.calls += 1
        return super().transcribe_media(**kwargs)


class LearningCountingProvider(DeterministicDigestProvider):
    def __init__(self) -> None:
        self.calls = 0

    def generate_learning(self, request: LearningGenerationRequestV1):
        self.calls += 1
        return super().generate_learning(request)


class UnknownConceptLinkProvider(DeterministicDigestProvider):
    def generate_learning(self, request: LearningGenerationRequestV1):
        response, trace = super().generate_learning(request)
        response.concept_links[0].source_concept_id = uuid4()
        return response, trace


class UnknownTutorCitationProvider(DeterministicDigestProvider):
    def generate_tutor_turn(self, request: TutorTurnRequestV1):
        response, trace = super().generate_tutor_turn(request)
        response.cited_excerpt_ids = [uuid4()]
        return response, trace


class UnknownMathCitationProvider(DeterministicDigestProvider):
    def generate_math_assistance(self, request: MathAssistanceRequestV1):
        response, trace = super().generate_math_assistance(request)
        response.cited_source_ids = [uuid4()]
        return response, trace


class UnsafeMathGraphProvider(DeterministicDigestProvider):
    def generate_math_assistance(self, request: MathAssistanceRequestV1):
        response, trace = super().generate_math_assistance(request)
        response.graph_expression = "system(x)"
        return response, trace


def decrypt_artifact(mutation: dict[str, Any]) -> bytes:
    wire = mutation["envelope"]
    envelope = EncryptedEnvelope(
        crypto_version=wire["cryptoVersion"],
        content_version=wire["contentVersion"],
        sealed_dek=base64url.decode(wire["sealedDek"]),
        sealed_content=base64url.decode(wire["sealedContent"]),
        payload_size=wire["payloadSize"],
    )
    entity_id = UUID(mutation["entityId"])
    return decrypt_payload(
        envelope,
        account_key=ACCOUNT_KEY,
        account_id=ACCOUNT_ID,
        aad=entity_aad(ACCOUNT_ID, mutation["entityType"], entity_id, 1),
    )


def session_request(job_id: UUID) -> SessionDigestRequestV1:
    return SessionDigestRequestV1(
        account_id=ACCOUNT_ID,
        job_id=job_id,
        session_id=uuid4(),
        course_id=uuid4(),
        session_title="Synthetic thermodynamics",
        started_at=datetime.now(UTC) - timedelta(hours=1),
        ended_at=datetime.now(UTC),
        sources=[
            SourceExcerptV1(
                source_id=uuid4(),
                source_kind=SourceKind.NOTE_BLOCK,
                title="Notebook",
                locator="block 1",
                excerpt="Entropy is a state function used to describe dispersal.",
            )
        ],
        disclosure_acknowledged=True,
    )


def processor(api: FakeAPI, outbox_path: Path, provider=None) -> WorkerProcessor:
    return WorkerProcessor(
        account_id=ACCOUNT_ID,
        account_key=ACCOUNT_KEY,
        api=api,  # type: ignore[arg-type]
        outbox=EncryptedOutbox(outbox_path),
        digest_provider=provider,
        maximum_asset_bytes=10_000_000,
    )


def test_local_ocr_produces_an_encrypted_unreviewed_artifact(tmp_path: Path) -> None:
    job_id = uuid4()
    note_id = uuid4()
    block_id = uuid4()
    png = base64.b64decode(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )
    request = LocalOCRRequestV1(
        account_id=ACCOUNT_ID,
        job_id=job_id,
        target_kind="NOTEBOOK_REGION",
        target_id=block_id,
        parent_id=note_id,
        note_id=note_id,
        input_revision=7,
        image_content=base64.b64encode(png).decode("ascii"),
        preferred_languages=["en-US", "es-MX"],
        mode="MIXED",
        disclosure_acknowledged=True,
    )
    api = FakeAPI([lease_for("LOCAL_OCR", json_bytes(request), job_id)])
    worker = WorkerProcessor(
        account_id=ACCOUNT_ID,
        account_key=ACCOUNT_KEY,
        api=api,  # type: ignore[arg-type]
        outbox=EncryptedOutbox(tmp_path / "local-ocr-outbox"),
        digest_provider=None,
        maximum_asset_bytes=10_000_000,
        local_ocr_engine=DeterministicLocalOCREngine(),
    )

    assert worker.process_once() is True
    assert not api.failed
    assert len(api.pushed) == 1
    artifact = OCRArtifactV1.model_validate_json(decrypt_artifact(api.pushed[0]))
    assert artifact.target_id == block_id
    assert artifact.input_revision == 7
    assert artifact.review_state is None
    assert artifact.response.regions[0].confidence is None
    assert artifact.response.regions[0].latex == "x^2 - 4 = 0"


def tutor_request(job_id: UUID, *, expires_at: datetime | None = None) -> TutorTurnRequestV1:
    session_id = uuid4()
    topic_id = uuid4()
    source_version_id = uuid4()
    source = TutorSourceExcerptV1(
        excerpt_id=uuid4(),
        source_id=uuid4(),
        source_version_id=source_version_id,
        title="Factoring notes",
        locator=TutorSourceLocatorV1(kind="PDF", page=3),
        excerpt="Factor the greatest common factor before applying another method.",
    )
    now = datetime.now(UTC)
    return TutorTurnRequestV1(
        account_id=ACCOUNT_ID,
        job_id=job_id,
        tutor_session_id=session_id,
        topic_id=topic_id,
        sequence=0,
        action="BEGIN",
        objective="Factor quadratics",
        guidance_style="ADAPTIVE",
        recommended_turn_kind="DIAGNOSTIC",
        recommendation_reason="No accepted assessment is available.",
        sources=[source],
        authorization=TutorSessionAuthorizationV1(
            tutor_session_id=session_id,
            topic_id=topic_id,
            source_version_ids=[source_version_id],
            maximum_turns=12,
            approved_turn_count=0,
            spending_limit_minor_units=100,
            estimated_spent_minor_units=0,
            currency_code="USD",
            approved_at=now - timedelta(minutes=1),
            expires_at=expires_at or now + timedelta(hours=2),
        ),
        disclosure_acknowledged=True,
    )


def test_tutor_turn_is_grounded_and_synced_as_an_encrypted_artifact(tmp_path) -> None:
    job_id = uuid4()
    request = tutor_request(job_id)
    api = FakeAPI([lease_for("TUTOR_TURN", json_bytes(request), job_id)])
    worker = processor(api, tmp_path / "tutor-outbox", DeterministicDigestProvider())

    assert worker.process_once()
    assert len(api.pushed) == 1
    artifact = TutorTurnArtifactV1.model_validate_json(decrypt_artifact(api.pushed[0]))
    assert artifact.tutor_session_id == request.tutor_session_id
    assert artifact.topic_id == request.topic_id
    assert artifact.response.cited_excerpt_ids == [request.sources[0].excerpt_id]
    assert artifact.sources[0].locator.page == 3
    assert b"Factor quadratics" not in json_bytes(api.pushed)
    assert api.completed == [(job_id, artifact_id(api.pushed[0]))]


def test_tutor_turn_rejects_provider_citation_outside_approved_excerpts(tmp_path) -> None:
    job_id = uuid4()
    request = tutor_request(job_id)
    api = FakeAPI([lease_for("TUTOR_TURN", json_bytes(request), job_id)])
    worker = processor(api, tmp_path / "invalid-tutor-outbox", UnknownTutorCitationProvider())

    assert worker.process_once()
    assert api.pushed == []
    assert api.failed == [(job_id, "PROVIDER_CITATION_INVALID", True)]


def test_tutor_turn_rejects_expired_session_authorization(tmp_path) -> None:
    job_id = uuid4()
    request = tutor_request(job_id)
    request.authorization.expires_at = datetime.now(UTC) - timedelta(seconds=1)
    # Build the now-invalid payload without asking Pydantic to validate it again.
    api = FakeAPI([lease_for("TUTOR_TURN", json_bytes(request), job_id)])
    worker = processor(api, tmp_path / "expired-tutor-outbox", DeterministicDigestProvider())

    assert worker.process_once()
    assert api.pushed == []
    assert api.failed == [(job_id, "TUTOR_AUTHORIZATION_INVALID", False)]


def math_request(job_id: UUID, *, mode: str = "GRAPH") -> MathAssistanceRequestV1:
    source_id = uuid4()
    return MathAssistanceRequestV1(
        account_id=ACCOUNT_ID,
        job_id=job_id,
        note_id=uuid4(),
        note_title="Algebra scratch work",
        mode=mode,
        output_language="English",
        selection_sources=[
            {
                "sourceId": source_id,
                "sourceKind": "LASSO_SELECTION",
                "title": "Algebra scratch work",
                "locator": "selected math on canvas item 1",
                "imageContent": "aW1hZ2U",
            }
        ],
        context_sources=[],
        disclosure_acknowledged=True,
    )


def test_math_assistance_is_synced_as_reviewable_encrypted_artifact(tmp_path) -> None:
    job_id = uuid4()
    request = math_request(job_id)
    api = FakeAPI([lease_for("MATH_ASSISTANCE", json_bytes(request), job_id)])
    worker = processor(api, tmp_path / "math-outbox", DeterministicDigestProvider())

    assert worker.process_once()
    assert len(api.pushed) == 1
    artifact = MathAssistanceArtifactV1.model_validate_json(decrypt_artifact(api.pushed[0]))
    assert artifact.note_id == request.note_id
    assert artifact.response.graph_expression == "x^2 - 4"
    assert artifact.response.cited_source_ids == [request.selection_sources[0].source_id]
    assert b"Algebra scratch work" not in json_bytes(api.pushed)
    assert api.completed == [(job_id, artifact_id(api.pushed[0]))]


def test_math_assistance_rejects_citation_outside_selection(tmp_path) -> None:
    job_id = uuid4()
    request = math_request(job_id)
    api = FakeAPI([lease_for("MATH_ASSISTANCE", json_bytes(request), job_id)])
    worker = processor(api, tmp_path / "math-citation-outbox", UnknownMathCitationProvider())

    assert worker.process_once()
    assert api.pushed == []
    assert api.failed == [(job_id, "PROVIDER_CITATION_INVALID", True)]


def test_math_assistance_rejects_non_evaluable_graph_identifiers(tmp_path) -> None:
    job_id = uuid4()
    request = math_request(job_id)
    api = FakeAPI([lease_for("MATH_ASSISTANCE", json_bytes(request), job_id)])
    worker = processor(api, tmp_path / "math-graph-outbox", UnsafeMathGraphProvider())

    assert worker.process_once()
    assert api.pushed == []
    assert api.failed == [(job_id, "PROVIDER_GRAPH_INVALID", True)]


def automated_learning_request(
    job_id: UUID,
    *,
    grant_id: UUID,
    topic_id: UUID,
    expires_at: datetime,
    spending_limit_minor_units: int = 500,
) -> LearningGenerationRequestV1:
    return LearningGenerationRequestV1(
        account_id=ACCOUNT_ID,
        job_id=job_id,
        job_type="FLASHCARD_DRAFTS",
        topic_id=topic_id,
        sources=[
            SourceExcerptV1(
                source_id=uuid4(),
                source_kind=SourceKind.NOTE_BLOCK,
                title="Synthetic algebra",
                locator="block 1",
                excerpt="A difference of squares uses conjugate factors.",
            )
        ],
        automation_authorization=AutomationAuthorizationV1(
            grant_id=grant_id,
            topic_ids=[topic_id],
            job_types=["FLASHCARD_DRAFTS"],
            minimum_interval_hours=24,
            expires_at=expires_at,
            spending_limit_minor_units=spending_limit_minor_units,
            currency_code="USD",
            authorized_at=datetime.now(UTC),
            scope_key=f"{topic_id}:FLASHCARD_DRAFTS",
            input_fingerprint="a" * 64,
        ),
        disclosure_acknowledged=True,
    )


def test_session_digest_is_cited_encrypted_and_completed(tmp_path) -> None:
    job_id = uuid4()
    request = session_request(job_id)
    lease = lease_for("SESSION_DIGEST", json_bytes(request), job_id)
    api = FakeAPI([lease])
    worker = processor(api, tmp_path / "outbox", DeterministicDigestProvider())

    assert worker.process_once()
    assert len(api.pushed) == 1
    artifact = SessionDigestArtifactV1.model_validate_json(decrypt_artifact(api.pushed[0]))
    assert artifact.job_id == job_id
    assert artifact.digest.key_points[0].source_ids == [request.sources[0].source_id]
    assert api.completed == [(job_id, artifact_id(api.pushed[0]))]
    assert not api.failed


def test_learning_draft_is_cited_encrypted_and_reviewable(tmp_path) -> None:
    job_id = uuid4()
    source_id = uuid4()
    topic_id = uuid4()
    request = LearningGenerationRequestV1(
        account_id=ACCOUNT_ID,
        job_id=job_id,
        job_type="FLASHCARD_DRAFTS",
        topic_id=topic_id,
        include_connected_knowledge=False,
        sources=[
            SourceExcerptV1(
                source_id=source_id,
                source_kind=SourceKind.NOTE_BLOCK,
                title="Synthetic algebra",
                locator="block 1",
                excerpt="A difference of squares factors as (a-b)(a+b).",
            )
        ],
        objective_titles=["Difference of squares"],
        disclosure_acknowledged=True,
    )
    api = FakeAPI([lease_for("FLASHCARD_DRAFTS", json_bytes(request), job_id)])
    worker = processor(api, tmp_path / "outbox", DeterministicDigestProvider())

    assert worker.process_once()
    artifact = LearningGenerationArtifactV1.model_validate_json(decrypt_artifact(api.pushed[0]))
    assert artifact.topic_id == topic_id
    assert artifact.job_type == "FLASHCARD_DRAFTS"
    assert artifact.source_ids == [source_id]
    assert artifact.response.items
    assert artifact.response.items[0].cited_source_ids == [source_id]
    assert api.completed == [(job_id, artifact_id(api.pushed[0]))]


def test_legacy_generic_transcription_draft_remains_readable(tmp_path) -> None:
    job_id = uuid4()
    source_id = uuid4()
    topic_id = uuid4()
    request = LearningGenerationRequestV1(
        account_id=ACCOUNT_ID,
        job_id=job_id,
        job_type="TRANSCRIPTION",
        topic_id=topic_id,
        sources=[
            SourceExcerptV1(
                source_id=source_id,
                source_kind=SourceKind.NOTE_BLOCK,
                title="Legacy recording notes",
                locator="block 1",
                excerpt="An older queued transcript draft remains recoverable.",
            )
        ],
        disclosure_acknowledged=True,
    )
    api = FakeAPI([lease_for("TRANSCRIPTION", json_bytes(request), job_id)])
    worker = processor(api, tmp_path / "outbox", DeterministicDigestProvider())

    assert worker.process_once()
    artifact = LearningGenerationArtifactV1.model_validate_json(decrypt_artifact(api.pushed[0]))
    assert artifact.job_type == "TRANSCRIPTION"
    assert artifact.source_ids == [source_id]
    assert api.completed == [(job_id, artifact_id(api.pushed[0]))]


def test_automatic_learning_requires_ledger_and_honors_frequency(tmp_path) -> None:
    grant_id = uuid4()
    topic_id = uuid4()
    first_job = uuid4()
    first_request = automated_learning_request(
        first_job,
        grant_id=grant_id,
        topic_id=topic_id,
        expires_at=datetime.now(UTC) + timedelta(days=2),
    )
    missing_ledger_api = FakeAPI(
        [lease_for("FLASHCARD_DRAFTS", json_bytes(first_request), first_job)]
    )
    missing_ledger_provider = LearningCountingProvider()
    without_ledger = processor(
        missing_ledger_api,
        tmp_path / "missing-ledger-outbox",
        missing_ledger_provider,
    )
    assert without_ledger.process_once()
    assert missing_ledger_provider.calls == 0
    assert missing_ledger_api.failed == [(first_job, "AUTOMATION_LEDGER_REQUIRED", False)]

    ledger = CostLedger(tmp_path / "costs.json", soft_budget_usd=100)
    valid_api = FakeAPI([lease_for("FLASHCARD_DRAFTS", json_bytes(first_request), first_job)])
    provider = LearningCountingProvider()
    valid_worker = WorkerProcessor(
        account_id=ACCOUNT_ID,
        account_key=ACCOUNT_KEY,
        api=valid_api,  # type: ignore[arg-type]
        outbox=EncryptedOutbox(tmp_path / "valid-outbox"),
        digest_provider=provider,
        maximum_asset_bytes=10_000_000,
        cost_ledger=ledger,
    )
    assert valid_worker.process_once()
    assert provider.calls == 1
    assert valid_api.completed

    second_job = uuid4()
    second_request = automated_learning_request(
        second_job,
        grant_id=grant_id,
        topic_id=topic_id,
        expires_at=datetime.now(UTC) + timedelta(days=2),
    )
    frequency_api = FakeAPI([lease_for("FLASHCARD_DRAFTS", json_bytes(second_request), second_job)])
    frequency_worker = WorkerProcessor(
        account_id=ACCOUNT_ID,
        account_key=ACCOUNT_KEY,
        api=frequency_api,  # type: ignore[arg-type]
        outbox=EncryptedOutbox(tmp_path / "frequency-outbox"),
        digest_provider=provider,
        maximum_asset_bytes=10_000_000,
        cost_ledger=ledger,
    )
    assert frequency_worker.process_once()
    assert provider.calls == 1
    assert frequency_api.failed == [(second_job, "AUTOMATION_FREQUENCY_LIMIT", False)]


def test_automatic_learning_honors_expiration_and_recorded_spending(tmp_path) -> None:
    topic_id = uuid4()
    grant_id = uuid4()
    provider = LearningCountingProvider()
    ledger = CostLedger(tmp_path / "costs.json", soft_budget_usd=100)

    expired_job = uuid4()
    expired = automated_learning_request(
        expired_job,
        grant_id=grant_id,
        topic_id=topic_id,
        expires_at=datetime.now(UTC) - timedelta(seconds=1),
    )
    expired_api = FakeAPI([lease_for("FLASHCARD_DRAFTS", json_bytes(expired), expired_job)])
    expired_worker = WorkerProcessor(
        account_id=ACCOUNT_ID,
        account_key=ACCOUNT_KEY,
        api=expired_api,  # type: ignore[arg-type]
        outbox=EncryptedOutbox(tmp_path / "expired-outbox"),
        digest_provider=provider,
        maximum_asset_bytes=10_000_000,
        cost_ledger=ledger,
    )
    assert expired_worker.process_once()
    assert provider.calls == 0
    assert expired_api.failed == [(expired_job, "AUTOMATION_GRANT_INVALID", False)]

    scope_key = f"{topic_id}:FLASHCARD_DRAFTS"
    ledger.record(
        job_id=uuid4(),
        provider="synthetic",
        model="fixture-v1",
        prompt_version="learning-generation/v1",
        input_tokens=1,
        output_tokens=1,
        estimated_cost_usd=5,
        provider_request_id="spent-limit-event",
        automation_grant_id=grant_id,
        automation_scope_key=scope_key,
        recorded_at=datetime.now(UTC) - timedelta(days=2),
    )
    spending_job = uuid4()
    spending = automated_learning_request(
        spending_job,
        grant_id=grant_id,
        topic_id=topic_id,
        expires_at=datetime.now(UTC) + timedelta(days=2),
        spending_limit_minor_units=500,
    )
    spending_api = FakeAPI([lease_for("FLASHCARD_DRAFTS", json_bytes(spending), spending_job)])
    spending_worker = WorkerProcessor(
        account_id=ACCOUNT_ID,
        account_key=ACCOUNT_KEY,
        api=spending_api,  # type: ignore[arg-type]
        outbox=EncryptedOutbox(tmp_path / "spending-outbox"),
        digest_provider=provider,
        maximum_asset_bytes=10_000_000,
        cost_ledger=ledger,
    )
    assert spending_worker.process_once()
    assert provider.calls == 0
    assert spending_api.failed == [(spending_job, "AUTOMATION_SPENDING_LIMIT", False)]


def test_test_plan_survives_worker_and_reports_objective_gaps(tmp_path) -> None:
    job_id = uuid4()
    source_id = uuid4()
    topic_id = uuid4()
    plan = GenerationPlanV1(
        mode="COMPREHENSIVE",
        question_count=1,
        time_limit_minutes=10,
        coverage_dimensions=["CONCEPTUAL", "INTEGRATED"],
        objective_titles=["Difference of squares", "Factoring by grouping"],
    )
    request = LearningGenerationRequestV1(
        account_id=ACCOUNT_ID,
        job_id=job_id,
        job_type="TEST_GENERATION",
        topic_id=topic_id,
        sources=[
            SourceExcerptV1(
                source_id=source_id,
                source_kind=SourceKind.NOTE_BLOCK,
                title="Synthetic algebra",
                locator="block 1",
                excerpt="Difference of squares and grouping are factoring methods.",
            )
        ],
        objective_titles=plan.objective_titles,
        test_plan=plan,
        disclosure_acknowledged=True,
    )
    api = FakeAPI([lease_for("TEST_GENERATION", json_bytes(request), job_id)])
    worker = processor(api, tmp_path / "outbox", DeterministicDigestProvider())

    assert worker.process_once()
    artifact = LearningGenerationArtifactV1.model_validate_json(decrypt_artifact(api.pushed[0]))
    assert artifact.schema_version == "ai-artifact/learning-generation/v2"
    assert artifact.test_plan == plan
    assert len(artifact.response.items) == 1
    assert artifact.response.items[0].objective_titles == ["Difference of squares"]
    assert artifact.response.coverage_gaps == [
        "No generated question covers objective: Factoring by grouping",
        "No generated question covers dimension: Integrated",
    ]


def test_concept_suggestions_return_cited_reviewable_links(tmp_path) -> None:
    job_id = uuid4()
    source_id = uuid4()
    topic_id = uuid4()
    known_concept_id = uuid4()
    request = LearningGenerationRequestV1(
        account_id=ACCOUNT_ID,
        job_id=job_id,
        job_type="CONCEPT_SUGGESTIONS",
        topic_id=topic_id,
        sources=[
            SourceExcerptV1(
                source_id=source_id,
                source_kind=SourceKind.NOTE_BLOCK,
                title="Synthetic algebra",
                locator="block 1",
                excerpt="Factoring exposes the roots of a polynomial.",
            )
        ],
        known_concepts=[
            KnownConceptReferenceV1(
                id=known_concept_id,
                name="Factorization",
            )
        ],
        disclosure_acknowledged=True,
    )
    api = FakeAPI([lease_for("CONCEPT_SUGGESTIONS", json_bytes(request), job_id)])
    worker = processor(api, tmp_path / "concept-outbox", DeterministicDigestProvider())

    assert worker.process_once()
    artifact = LearningGenerationArtifactV1.model_validate_json(decrypt_artifact(api.pushed[0]))
    assert artifact.known_concept_ids == [known_concept_id]
    assert len(artifact.response.concept_links) == 1
    link = artifact.response.concept_links[0]
    assert link.source_concept_id == known_concept_id
    assert link.target_concept_id is None
    assert link.relation == "RELATED"
    assert link.cited_source_ids == [source_id]


def test_concept_suggestions_reject_unknown_concept_ids(tmp_path) -> None:
    job_id = uuid4()
    source_id = uuid4()
    topic_id = uuid4()
    request = LearningGenerationRequestV1(
        account_id=ACCOUNT_ID,
        job_id=job_id,
        job_type="CONCEPT_SUGGESTIONS",
        topic_id=topic_id,
        sources=[
            SourceExcerptV1(
                source_id=source_id,
                source_kind=SourceKind.NOTE_BLOCK,
                title="Synthetic algebra",
                locator="block 1",
                excerpt="Factoring exposes the roots of a polynomial.",
            )
        ],
        known_concepts=[KnownConceptReferenceV1(id=uuid4(), name="Factorization")],
        disclosure_acknowledged=True,
    )
    api = FakeAPI([lease_for("CONCEPT_SUGGESTIONS", json_bytes(request), job_id)])
    worker = processor(api, tmp_path / "invalid-concept-outbox", UnknownConceptLinkProvider())

    assert worker.process_once()
    assert api.pushed == []
    assert api.failed == [(job_id, "PROVIDER_CONCEPT_INVALID", True)]


def test_free_response_feedback_is_cited_encrypted_and_linked(tmp_path) -> None:
    job_id = uuid4()
    attempt_id = uuid4()
    response_id = uuid4()
    question_id = uuid4()
    topic_id = uuid4()
    request = FreeResponseFeedbackRequestV1(
        account_id=ACCOUNT_ID,
        job_id=job_id,
        attempt_id=attempt_id,
        response_id=response_id,
        question_id=question_id,
        topic_id=topic_id,
        question_kind="EXPLANATION",
        prompt="Explain why a difference of squares factors.",
        rubric="Identify the conjugate factors and verify by expansion.",
        reference_answer="The middle terms cancel when the conjugates are expanded.",
        user_response="The middle terms cancel when the conjugates are expanded.",
        confidence=4,
        evidence=[
            FeedbackEvidenceExcerptV1(
                source_id=question_id,
                source_kind="QUESTION_SNAPSHOT",
                title="Frozen question and grading guide",
                locator=f"attempt {attempt_id}, question {question_id}",
                excerpt="The frozen grading guide requires a cancellation explanation.",
            )
        ],
        disclosure_acknowledged=True,
    )
    api = FakeAPI([lease_for("FREE_RESPONSE_FEEDBACK", json_bytes(request), job_id)])
    worker = processor(api, tmp_path / "outbox", DeterministicDigestProvider())

    assert worker.process_once()
    artifact = FreeResponseFeedbackArtifactV1.model_validate_json(decrypt_artifact(api.pushed[0]))
    assert artifact.attempt_id == attempt_id
    assert artifact.response_id == response_id
    assert artifact.question_id == question_id
    assert artifact.topic_id == topic_id
    assert artifact.response.proposed_score == 1
    assert artifact.response.cited_source_ids == [question_id]
    assert artifact.source_ids == [question_id]
    assert api.pushed[0]["parentId"] == str(attempt_id)
    assert set(api.pushed[0]["relationIds"]) == {
        str(attempt_id),
        str(response_id),
        str(question_id),
        str(topic_id),
    }
    assert api.completed == [(job_id, artifact_id(api.pushed[0]))]
    assert not api.failed


def artifact_id(mutation: dict[str, Any]) -> UUID:
    return UUID(mutation["entityId"])


def test_encrypted_outbox_prevents_duplicate_provider_cost(tmp_path) -> None:
    job_id = uuid4()
    lease = lease_for("SESSION_DIGEST", json_bytes(session_request(job_id)), job_id)
    api = FakeAPI([lease, lease.model_copy(update={"attempts": 2})])
    api.fail_next_push = True
    provider = CountingProvider()
    worker = processor(api, tmp_path / "outbox", provider)

    with pytest.raises(APIError):
        worker.process_once()
    assert provider.calls == 1
    assert worker.process_once()
    assert provider.calls == 1
    assert len(api.completed) == 1


def make_pdf() -> bytes:
    output = io.BytesIO()
    canvas = Canvas(output)
    canvas.drawString(72, 720, "A source-grounded PDF sentence.")
    canvas.save()
    return output.getvalue()


def make_scanned_pdf() -> bytes:
    output = io.BytesIO()
    canvas = Canvas(output)
    canvas.showPage()
    canvas.save()
    return output.getvalue()


def test_pdf_job_decrypts_in_memory_and_syncs_manifest(tmp_path) -> None:
    job_id = uuid4()
    asset_key = bytes(reversed(range(32)))
    pdf = make_pdf()
    encrypted_asset = encrypt_bytes(pdf, key=asset_key)
    request = PDFExtractionRequestV1(
        account_id=ACCOUNT_ID,
        job_id=job_id,
        resource_id=uuid4(),
        asset_id=uuid4(),
        asset_key=base64url.encode(asset_key),
        expected_dedupe_tag=plaintext_dedupe_tag(
            pdf, account_key=ACCOUNT_KEY, account_id=ACCOUNT_ID
        ),
        title="Synthetic PDF",
    )
    api = FakeAPI(
        [lease_for("PDF_EXTRACTION", json_bytes(request), job_id)],
        encrypted_asset=encrypted_asset,
    )
    worker = processor(api, tmp_path / "outbox", DeterministicDigestProvider())

    assert worker.process_once()
    assert len(api.pushed) == 2
    manifest = PDFExtractionManifestV1.model_validate_json(decrypt_artifact(api.pushed[-1]))
    assert manifest.page_count == 1
    assert manifest.character_count > 0
    assert manifest.chunk_entity_ids == [artifact_id(api.pushed[0])]
    assert api.completed == [(job_id, artifact_id(api.pushed[-1]))]


def test_pdf_v2_runs_local_ocr_only_for_pages_without_text(tmp_path: Path) -> None:
    job_id = uuid4()
    resource_id = uuid4()
    source_version_id = uuid4()
    asset_key = bytes(reversed(range(32)))
    pdf = make_scanned_pdf()
    request = PDFExtractionRequestV2(
        account_id=ACCOUNT_ID,
        job_id=job_id,
        resource_id=resource_id,
        asset_id=uuid4(),
        asset_key=base64url.encode(asset_key),
        expected_dedupe_tag=plaintext_dedupe_tag(
            pdf, account_key=ACCOUNT_KEY, account_id=ACCOUNT_ID
        ),
        title="Scanned PDF",
        source_version_id=source_version_id,
        automatic_ocr=True,
        automatic_formula_ocr=False,
        preferred_ocr_languages=["en-US"],
    )
    api = FakeAPI(
        [lease_for("PDF_EXTRACTION", json_bytes(request), job_id)],
        encrypted_asset=encrypt_bytes(pdf, key=asset_key),
    )
    worker = WorkerProcessor(
        account_id=ACCOUNT_ID,
        account_key=ACCOUNT_KEY,
        api=api,  # type: ignore[arg-type]
        outbox=EncryptedOutbox(tmp_path / "source-ocr-outbox"),
        digest_provider=None,
        maximum_asset_bytes=10_000_000,
        local_ocr_engine=DeterministicLocalOCREngine(),
    )

    assert worker.process_once()
    assert len(api.pushed) == 3
    ocr = OCRArtifactV1.model_validate_json(decrypt_artifact(api.pushed[1]))
    assert ocr.target_kind == "SOURCE_PAGE"
    assert ocr.source_version_id == source_version_id
    assert ocr.page_number == 1
    assert ocr.review_state is None


def source_analysis_request(
    job_id: UUID, *, asset_key: bytes, pdf: bytes
) -> SourceAnalysisRequestV1:
    return SourceAnalysisRequestV1(
        account_id=ACCOUNT_ID,
        job_id=job_id,
        source_id=uuid4(),
        source_version_id=uuid4(),
        title="Synthetic PDF",
        output_language="Spanish",
        asset_id=uuid4(),
        asset_key=base64url.encode(asset_key),
        expected_dedupe_tag=plaintext_dedupe_tag(
            pdf, account_key=ACCOUNT_KEY, account_id=ACCOUNT_ID
        ),
        include_images=True,
        disclosure_acknowledged=True,
    )


def test_source_analysis_stores_version_bound_exact_citations(tmp_path) -> None:
    job_id = uuid4()
    asset_key = bytes(reversed(range(32)))
    pdf = make_pdf()
    request = source_analysis_request(job_id, asset_key=asset_key, pdf=pdf)
    api = FakeAPI(
        [lease_for("SOURCE_ANALYSIS", json_bytes(request), job_id)],
        encrypted_asset=encrypt_bytes(pdf, key=asset_key),
    )
    worker = processor(api, tmp_path / "outbox", DeterministicDigestProvider())

    assert worker.process_once()
    artifact = SourceAnalysisArtifactV1.model_validate_json(decrypt_artifact(api.pushed[-1]))
    assert artifact.source_id == request.source_id
    assert artifact.source_version_id == request.source_version_id
    assert artifact.guide.translated_summary
    assert artifact.references[0].page_number == 1
    assert artifact.references[0].rectangles
    assert artifact.guide.summary[0].source_ids == [artifact.references[0].source_id]


def test_source_query_stores_answer_with_frozen_pdf_locator(tmp_path) -> None:
    job_id = uuid4()
    asset_key = bytes(reversed(range(32)))
    pdf = make_pdf()
    analysis = source_analysis_request(job_id, asset_key=asset_key, pdf=pdf)
    request = SourceQueryRequestV1(
        **analysis.model_dump(exclude={"schema_version"}),
        question="What does the source say?",
    )
    api = FakeAPI(
        [lease_for("SOURCE_QUERY", json_bytes(request), job_id)],
        encrypted_asset=encrypt_bytes(pdf, key=asset_key),
    )
    worker = processor(api, tmp_path / "outbox", DeterministicDigestProvider())

    assert worker.process_once()
    artifact = SourceQueryArtifactV1.model_validate_json(decrypt_artifact(api.pushed[-1]))
    assert artifact.question == request.question
    assert artifact.references[0].page_number == 1
    assert artifact.response.answer[0].source_ids == [artifact.references[0].source_id]


def transcription_request(
    job_id: UUID,
    *,
    asset_key: bytes,
    media: bytes,
    expected_size: int | None = None,
    expected_tag: str | None = None,
) -> MediaTranscriptionRequestV1:
    return MediaTranscriptionRequestV1(
        account_id=ACCOUNT_ID,
        job_id=job_id,
        source_id=uuid4(),
        source_version_id=uuid4(),
        source_type="AUDIO",
        asset_id=uuid4(),
        asset_key=base64url.encode(asset_key),
        expected_dedupe_tag=expected_tag
        or plaintext_dedupe_tag(media, account_key=ACCOUNT_KEY, account_id=ACCOUNT_ID),
        expected_plaintext_bytes=expected_size or len(media),
        filename="lecture.wav",
        mime_type="audio/wav",
        language="en",
        disclosure_acknowledged=True,
    )


def test_transcription_job_decrypts_media_and_syncs_timestamped_chunks(tmp_path) -> None:
    job_id = uuid4()
    asset_key = bytes(reversed(range(32)))
    media = TRANSCRIPTION_WAVE
    request = transcription_request(job_id, asset_key=asset_key, media=media)
    api = FakeAPI(
        [lease_for("TRANSCRIPTION", json_bytes(request), job_id)],
        encrypted_asset=encrypt_bytes(media, key=asset_key),
    )
    provider = TranscriptionCountingProvider()
    worker = processor(api, tmp_path / "outbox", provider)

    assert worker.process_once()
    assert provider.calls == 1
    assert len(api.pushed) == 2
    chunk = MediaTranscriptionChunkV1.model_validate_json(decrypt_artifact(api.pushed[0]))
    manifest = MediaTranscriptionManifestV1.model_validate_json(decrypt_artifact(api.pushed[-1]))
    assert chunk.source_id == request.source_id
    assert chunk.source_version_id == request.source_version_id
    assert chunk.segments[0].start_seconds == 0
    assert chunk.segments[0].end_seconds == 1
    assert manifest.source_id == request.source_id
    assert manifest.source_version_id == request.source_version_id
    assert manifest.segment_count == 1
    assert manifest.chunk_entity_ids == [artifact_id(api.pushed[0])]
    assert manifest.trace.estimated_cost_usd == 0
    assert b"Synthetic transcript" not in json_bytes(api.pushed)
    assert api.completed == [(job_id, artifact_id(api.pushed[-1]))]


@pytest.mark.parametrize("failure", ["size", "dedupe"])
def test_transcription_rejects_asset_mismatch_before_provider(tmp_path, failure: str) -> None:
    job_id = uuid4()
    asset_key = bytes(reversed(range(32)))
    media = TRANSCRIPTION_WAVE
    request = transcription_request(
        job_id,
        asset_key=asset_key,
        media=media,
        expected_size=len(media) - 1 if failure == "size" else None,
        expected_tag="0" * 64 if failure == "dedupe" else None,
    )
    api = FakeAPI(
        [lease_for("TRANSCRIPTION", json_bytes(request), job_id)],
        encrypted_asset=encrypt_bytes(media, key=asset_key),
    )
    provider = TranscriptionCountingProvider()
    worker = processor(api, tmp_path / "outbox", provider)

    assert worker.process_once()
    assert provider.calls == 0
    assert api.pushed == []
    expected = "TRANSCRIPTION_MEDIA_SIZE_MISMATCH" if failure == "size" else "ASSET_DEDUPE_MISMATCH"
    assert api.failed == [(job_id, expected, False)]


def test_transcription_rejects_spoofed_media_before_provider(tmp_path) -> None:
    job_id = uuid4()
    asset_key = bytes(reversed(range(32)))
    media = b"not-a-wave-file"
    request = transcription_request(job_id, asset_key=asset_key, media=media)
    api = FakeAPI(
        [lease_for("TRANSCRIPTION", json_bytes(request), job_id)],
        encrypted_asset=encrypt_bytes(media, key=asset_key),
    )
    provider = TranscriptionCountingProvider()
    worker = processor(api, tmp_path / "outbox", provider)

    assert worker.process_once()
    assert provider.calls == 0
    assert api.pushed == []
    assert api.failed == [(job_id, "TRANSCRIPTION_MEDIA_IDENTITY_MISMATCH", False)]


def test_provider_configuration_job_stores_secret_and_syncs_sanitized_ack(tmp_path) -> None:
    job_id = uuid4()
    profile_id = uuid4()
    request = ProviderConfigurationRequestV1(
        account_id=ACCOUNT_ID,
        job_id=job_id,
        operation="UPSERT",
        profile_id=profile_id,
        display_name="Local model",
        adapter="OPENAI_COMPATIBLE",
        base_url="http://127.0.0.1:11434/v1",
        api_key="provider-secret",
        text_model="qwen3:8b",
        capabilities=["TEXT"],
        structured_output=True,
        make_active=True,
        disclosure_acknowledged=True,
    )
    api = FakeAPI([lease_for("PROVIDER_CONFIGURATION", json_bytes(request), job_id)])
    profile_store = MemoryProviderProfileStore()
    manager = ProviderManager(
        account_id=ACCOUNT_ID,
        store=profile_store,
        fallback=None,
    )
    worker = WorkerProcessor(
        account_id=ACCOUNT_ID,
        account_key=ACCOUNT_KEY,
        api=api,  # type: ignore[arg-type]
        outbox=EncryptedOutbox(tmp_path / "outbox"),
        digest_provider=manager,
        maximum_asset_bytes=10_000_000,
        provider_configuration_manager=manager,
    )

    assert worker.process_once()
    stored = profile_store.get(ACCOUNT_ID, profile_id)
    assert stored is not None
    assert stored.api_key == "provider-secret"
    assert len(api.pushed) == 1
    artifact_bytes = decrypt_artifact(api.pushed[0])
    artifact = ProviderConfigurationArtifactV1.model_validate_json(artifact_bytes)
    assert artifact.profile_id == profile_id
    assert artifact.secret_stored is True
    assert b"provider-secret" not in artifact_bytes
    assert b"provider-secret" not in json_bytes(api.pushed)
