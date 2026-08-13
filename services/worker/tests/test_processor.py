from __future__ import annotations

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
from epistoria_worker.crypto import (
    EncryptedEnvelope,
    decrypt_payload,
    encrypt_payload,
    entity_aad,
    job_aad,
)
from epistoria_worker.models import (
    AIJobLease,
    PDFExtractionManifestV1,
    PDFExtractionRequestV1,
    SessionDigestArtifactV1,
    SessionDigestRequestV1,
    SourceExcerptV1,
    SourceKind,
)
from epistoria_worker.outbox import EncryptedOutbox
from epistoria_worker.processor import WorkerProcessor
from epistoria_worker.providers.fake import DeterministicDigestProvider

ACCOUNT_ID = UUID("11111111-1111-4111-8111-111111111111")
ACCOUNT_KEY = bytes(range(32))


def lease_for(
    job_type: Literal["SESSION_DIGEST", "PDF_EXTRACTION"],
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
        aad=entity_aad(ACCOUNT_ID, "AI_ARTIFACT", entity_id, 1),
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
    worker = processor(api, tmp_path / "outbox")

    assert worker.process_once()
    assert len(api.pushed) == 2
    manifest = PDFExtractionManifestV1.model_validate_json(decrypt_artifact(api.pushed[-1]))
    assert manifest.page_count == 1
    assert manifest.character_count > 0
    assert manifest.chunk_entity_ids == [artifact_id(api.pushed[0])]
    assert api.completed == [(job_id, artifact_id(api.pushed[-1]))]
