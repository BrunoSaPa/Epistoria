from __future__ import annotations

import hmac
import logging
from datetime import UTC, datetime
from typing import Any
from uuid import UUID, uuid5

from pydantic import ValidationError

from . import base64url
from .api import APIError, EpistoriaAPI
from .asset_crypto import AssetCryptoError, decrypt_bytes, plaintext_dedupe_tag
from .canonical import json_bytes
from .cost_ledger import CostLedger
from .crypto import EncryptedEnvelope, EnvelopeError, decrypt_job, encrypt_entity
from .models import (
    AIJobLease,
    NoteQueryArtifactV1,
    NoteQueryRequestV1,
    PDFExtractionChunkV1,
    PDFExtractionManifestV1,
    PDFExtractionRequestV1,
    SessionDigestArtifactV1,
    SessionDigestRequestV1,
    SessionDigestV1,
)
from .outbox import CachedCompletion, EncryptedOutbox
from .pdf_extract import PDFExtractionError, chunk_pages, extract_pdf_pages
from .providers.base import DigestProvider, ProviderError

LOGGER = logging.getLogger("epistoria.worker")
_MAX_PUSH_CIPHER_BYTES = 6_250_000


class ProcessingFailure(RuntimeError):
    def __init__(self, *, code: str, retryable: bool):
        super().__init__(code)
        self.code = code
        self.retryable = retryable


class WorkerProcessor:
    def __init__(
        self,
        *,
        account_id: UUID,
        account_key: bytes,
        api: EpistoriaAPI,
        outbox: EncryptedOutbox,
        digest_provider: DigestProvider | None,
        maximum_asset_bytes: int,
        cost_ledger: CostLedger | None = None,
    ) -> None:
        if len(account_key) != 32:
            raise ValueError("account key must be 32 bytes")
        self._account_id = account_id
        self._account_key = account_key
        self._api = api
        self._outbox = outbox
        self._digest_provider = digest_provider
        self._maximum_asset_bytes = maximum_asset_bytes
        self._cost_ledger = cost_ledger

    def process_once(self) -> bool:
        lease = self._api.claim_job()
        if lease is None:
            return False
        LOGGER.info(
            "claimed job id=%s type=%s attempt=%d", lease.id, lease.job_type, lease.attempts
        )
        try:
            completion = self._outbox.load(lease.id)
            if completion is None:
                completion = self._build_completion(lease)
                self._outbox.save(completion)
            self._deliver(completion)
            LOGGER.info("completed job id=%s artifact=%s", lease.id, completion.artifact_entity_id)
        except ProcessingFailure as error:
            LOGGER.warning("job rejected id=%s code=%s", lease.id, error.code)
            self._api.fail_job(lease.id, error_code=error.code, retryable=error.retryable)
        except ProviderError as error:
            LOGGER.warning("provider failed job=%s code=%s", lease.id, error.code)
            self._api.fail_job(lease.id, error_code=error.code, retryable=error.retryable)
        except APIError as error:
            if error.retryable:
                # Keep any cached encrypted result and let the lease expire. This avoids
                # converting an outage into another paid provider request.
                LOGGER.warning("delivery deferred job=%s", lease.id)
                raise
            self._api.fail_job(lease.id, error_code="SYNC_REJECTED", retryable=False)
        except Exception:
            LOGGER.exception("unexpected worker failure job=%s", lease.id)
            self._api.fail_job(lease.id, error_code="WORKER_INTERNAL", retryable=True)
        return True

    def _build_completion(self, lease: AIJobLease) -> CachedCompletion:
        plaintext = self._decrypt_lease(lease)
        if lease.job_type == "SESSION_DIGEST":
            return self._session_digest(lease, plaintext)
        if lease.job_type == "PDF_EXTRACTION":
            return self._pdf_extraction(lease, plaintext)
        if lease.job_type == "NOTE_QUERY":
            return self._note_query(lease, plaintext)
        raise ProcessingFailure(code="UNSUPPORTED_JOB_TYPE", retryable=False)

    def _decrypt_lease(self, lease: AIJobLease) -> bytes:
        try:
            envelope = EncryptedEnvelope(
                crypto_version=lease.crypto_version,
                content_version=lease.content_version,
                sealed_dek=base64url.decode(lease.sealed_dek, field="sealedDek"),
                sealed_content=base64url.decode(lease.sealed_payload, field="sealedPayload"),
                payload_size=lease.payload_size,
            )
            return decrypt_job(
                envelope,
                account_key=self._account_key,
                account_id=self._account_id,
                job_type=lease.job_type,
                job_id=lease.id,
            )
        except (ValueError, EnvelopeError) as error:
            raise ProcessingFailure(code="DECRYPTION_FAILED", retryable=False) from error

    def _session_digest(self, lease: AIJobLease, plaintext: bytes) -> CachedCompletion:
        if self._digest_provider is None:
            raise ProcessingFailure(code="AI_NOT_CONFIGURED", retryable=False)
        try:
            request = SessionDigestRequestV1.model_validate_json(plaintext)
        except ValidationError as error:
            raise ProcessingFailure(code="INVALID_JOB_PAYLOAD", retryable=False) from error
        if request.account_id != self._account_id or request.job_id != lease.id:
            raise ProcessingFailure(code="JOB_IDENTITY_MISMATCH", retryable=False)

        digest, trace = self._digest_provider.generate(request)
        if self._cost_ledger is not None:
            status = self._cost_ledger.record(
                job_id=lease.id,
                provider=trace.provider,
                model=trace.model,
                prompt_version=trace.prompt_version,
                input_tokens=trace.input_tokens,
                output_tokens=trace.output_tokens,
                estimated_cost_usd=trace.estimated_cost_usd,
                provider_request_id=trace.provider_request_id,
            )
            threshold = 1.0 if status.fraction >= 1 else 0.9 if status.fraction >= 0.9 else 0.7
            if status.fraction >= threshold:
                LOGGER.warning(
                    "AI cost threshold reached month=%s estimated_usd=%.4f budget_usd=%.2f "
                    "quality_route_unchanged=true",
                    status.month,
                    status.estimated_usd,
                    status.soft_budget_usd,
                )
        source_ids = {source.source_id for source in request.sources}
        cited_ids = self._validate_citations(digest, source_ids)
        artifact_id = uuid5(lease.id, "ai-artifact/v1")
        artifact = SessionDigestArtifactV1(
            job_id=lease.id,
            session_id=request.session_id,
            generated_at=datetime.now(UTC),
            source_ids=cited_ids,
            trace=trace,
            digest=digest,
        )
        mutation = self._encrypted_mutation(
            entity_id=artifact_id,
            parent_id=request.session_id,
            relation_ids=cited_ids[:64],
            plaintext=json_bytes(artifact),
        )
        return CachedCompletion(
            job_id=lease.id,
            artifact_entity_id=artifact_id,
            mutations=[mutation],
        )

    @staticmethod
    def _validate_citations(digest: SessionDigestV1, allowed: set[UUID]) -> list[UUID]:
        cited: list[UUID] = []
        seen: set[UUID] = set()
        statements = [*digest.key_points, *digest.possible_misconceptions]
        for statement in statements:
            for source_id in statement.source_ids:
                if source_id not in allowed:
                    raise ProcessingFailure(code="PROVIDER_CITATION_INVALID", retryable=True)
                if source_id not in seen:
                    cited.append(source_id)
                    seen.add(source_id)
        if not cited:
            raise ProcessingFailure(code="PROVIDER_CITATION_INVALID", retryable=True)
        return cited

    def _note_query(self, lease: AIJobLease, plaintext: bytes) -> CachedCompletion:
        if self._digest_provider is None:
            raise ProcessingFailure(code="AI_NOT_CONFIGURED", retryable=False)
        try:
            request = NoteQueryRequestV1.model_validate_json(plaintext)
        except ValidationError as error:
            raise ProcessingFailure(code="INVALID_JOB_PAYLOAD", retryable=False) from error
        if request.account_id != self._account_id or request.job_id != lease.id:
            raise ProcessingFailure(code="JOB_IDENTITY_MISMATCH", retryable=False)

        query_response, trace = self._digest_provider.generate_note_query(request)

        if self._cost_ledger is not None:
            status = self._cost_ledger.record(
                job_id=lease.id,
                provider=trace.provider,
                model=trace.model,
                prompt_version=trace.prompt_version,
                input_tokens=trace.input_tokens,
                output_tokens=trace.output_tokens,
                estimated_cost_usd=trace.estimated_cost_usd,
                provider_request_id=trace.provider_request_id,
            )
            threshold = 1.0 if status.fraction >= 1 else 0.9 if status.fraction >= 0.9 else 0.7
            if status.fraction >= threshold:
                LOGGER.warning(
                    "AI cost threshold reached month=%s estimated_usd=%.4f budget_usd=%.2f "
                    "quality_route_unchanged=true",
                    status.month,
                    status.estimated_usd,
                    status.soft_budget_usd,
                )

        # Validate all cited source IDs are from known selection or context sources.
        allowed_ids = {s.source_id for s in request.selection_sources + request.context_sources}
        for cited_id in query_response.cited_source_ids:
            if cited_id not in allowed_ids:
                raise ProcessingFailure(code="PROVIDER_CITATION_INVALID", retryable=True)

        artifact_id = uuid5(lease.id, "ai-artifact/v1")
        artifact = NoteQueryArtifactV1(
            job_id=lease.id,
            note_id=request.note_id,
            question=request.question,
            generated_at=datetime.now(UTC),
            source_ids=list(query_response.cited_source_ids),
            trace=trace,
            response=query_response,
        )
        mutation = self._encrypted_mutation(
            entity_id=artifact_id,
            parent_id=request.note_id,
            relation_ids=list(query_response.cited_source_ids)[:64],
            plaintext=json_bytes(artifact),
        )
        return CachedCompletion(
            job_id=lease.id,
            artifact_entity_id=artifact_id,
            mutations=[mutation],
        )

    def _pdf_extraction(self, lease: AIJobLease, plaintext: bytes) -> CachedCompletion:
        try:
            request = PDFExtractionRequestV1.model_validate_json(plaintext)
            asset_key = base64url.decode(request.asset_key, field="assetKey")
            if len(asset_key) != 32:
                raise ValueError("asset key has the wrong length")
        except (ValidationError, ValueError) as error:
            raise ProcessingFailure(code="INVALID_JOB_PAYLOAD", retryable=False) from error
        if request.account_id != self._account_id or request.job_id != lease.id:
            raise ProcessingFailure(code="JOB_IDENTITY_MISMATCH", retryable=False)

        encrypted = self._api.download_encrypted_asset(
            request.asset_id, maximum_bytes=self._maximum_asset_bytes
        )
        try:
            pdf_bytes = decrypt_bytes(encrypted, key=asset_key)
        except AssetCryptoError as error:
            raise ProcessingFailure(code="ASSET_DECRYPTION_FAILED", retryable=False) from error
        actual_tag = plaintext_dedupe_tag(
            pdf_bytes, account_key=self._account_key, account_id=self._account_id
        )
        if not hmac.compare_digest(actual_tag, request.expected_dedupe_tag):
            raise ProcessingFailure(code="ASSET_DEDUPE_MISMATCH", retryable=False)
        try:
            pages = extract_pdf_pages(pdf_bytes)
            page_chunks = chunk_pages(pages)
        except PDFExtractionError as error:
            raise ProcessingFailure(code="PDF_EXTRACTION_FAILED", retryable=False) from error
        finally:
            # CPython cannot guarantee zeroization, but dropping the only large reference
            # promptly minimizes the plaintext lifetime and no temporary file is created.
            pdf_bytes = b""

        chunk_ids = [
            uuid5(lease.id, f"pdf-extraction-chunk/{index}") for index in range(len(page_chunks))
        ]
        mutations: list[dict[str, Any]] = []
        for index, (entity_id, selected_pages) in enumerate(
            zip(chunk_ids, page_chunks, strict=True)
        ):
            chunk = PDFExtractionChunkV1(
                job_id=lease.id,
                resource_id=request.resource_id,
                chunk_index=index,
                pages=selected_pages,
            )
            mutations.append(
                self._encrypted_mutation(
                    entity_id=entity_id,
                    parent_id=request.resource_id,
                    relation_ids=[request.resource_id],
                    plaintext=json_bytes(chunk),
                )
            )

        artifact_id = uuid5(lease.id, "ai-artifact/v1")
        manifest = PDFExtractionManifestV1(
            job_id=lease.id,
            resource_id=request.resource_id,
            generated_at=datetime.now(UTC),
            page_count=len(pages),
            character_count=sum(page.character_count for page in pages),
            pages_needing_ocr=[page.page_number for page in pages if page.needs_ocr],
            chunk_entity_ids=chunk_ids,
        )
        mutations.append(
            self._encrypted_mutation(
                entity_id=artifact_id,
                parent_id=request.resource_id,
                relation_ids=chunk_ids,
                plaintext=json_bytes(manifest),
            )
        )
        return CachedCompletion(
            job_id=lease.id,
            artifact_entity_id=artifact_id,
            mutations=mutations,
        )

    def _encrypted_mutation(
        self,
        *,
        entity_id: UUID,
        parent_id: UUID,
        relation_ids: list[UUID],
        plaintext: bytes,
    ) -> dict[str, Any]:
        if len(plaintext) > 2_097_152:
            raise ProcessingFailure(code="ARTIFACT_TOO_LARGE", retryable=False)
        envelope = encrypt_entity(
            plaintext,
            account_key=self._account_key,
            account_id=self._account_id,
            entity_type="AI_ARTIFACT",
            entity_id=entity_id,
            content_version=1,
        )
        timestamp = datetime.now(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")
        return {
            "mutationId": str(uuid5(entity_id, "epistoria-sync-mutation/v1")),
            "entityId": str(entity_id),
            "entityType": "AI_ARTIFACT",
            "operation": "UPSERT",
            "baseRevision": 0,
            "parentId": str(parent_id),
            "relationIds": [str(value) for value in relation_ids],
            "clientModifiedAt": timestamp,
            "envelope": envelope.to_wire(),
        }

    def _deliver(self, completion: CachedCompletion) -> None:
        batch: list[dict[str, Any]] = []
        batch_bytes = 0
        for mutation in completion.mutations:
            envelope = mutation["envelope"]
            approximate_bytes = (
                len(envelope["sealedDek"]) * 3 // 4 + len(envelope["sealedContent"]) * 3 // 4
            )
            if batch and batch_bytes + approximate_bytes > _MAX_PUSH_CIPHER_BYTES:
                self._api.push_mutations(batch)
                batch = []
                batch_bytes = 0
            batch.append(mutation)
            batch_bytes += approximate_bytes
        if batch:
            self._api.push_mutations(batch)
        self._api.complete_job(completion.job_id, artifact_entity_id=completion.artifact_entity_id)
        self._outbox.delete(completion.job_id)
