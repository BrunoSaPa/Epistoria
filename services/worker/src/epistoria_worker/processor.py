from __future__ import annotations

import base64
import hashlib
import hmac
import json
import logging
import re
from datetime import UTC, datetime, timedelta
from typing import Any
from uuid import UUID, uuid5

from pydantic import ValidationError

from . import base64url
from .api import APIError, EpistoriaAPI
from .asset_crypto import AssetCryptoError, decrypt_bytes, plaintext_dedupe_tag
from .canonical import json_bytes
from .cost_ledger import CostLedger
from .crypto import EncryptedEnvelope, EnvelopeError, decrypt_job, encrypt_entity
from .local_models import (
    PP_FORMULANET_PLUS_S,
    LocalModelError,
    LocalModelManager,
    LocalModelPaused,
)
from .local_ocr import LocalOCRError, OCREngine
from .models import (
    AIJobLease,
    AutomationAuthorizationV1,
    FreeResponseFeedbackArtifactV1,
    FreeResponseFeedbackRequestV1,
    LearningGenerationArtifactV1,
    LearningGenerationRequestV1,
    LocalModelControlRequestV1,
    LocalModelStatusArtifactV1,
    LocalOCRRequestV1,
    MathAssistanceArtifactV1,
    MathAssistanceRequestV1,
    MediaTranscriptionChunkV1,
    MediaTranscriptionManifestV1,
    MediaTranscriptionRequestV1,
    NoteQueryArtifactV1,
    NoteQueryRequestV1,
    OCRArtifactV1,
    PDFExtractionChunkV1,
    PDFExtractionManifestV1,
    PDFExtractionRequestV1,
    PDFExtractionRequestV2,
    ProviderConfigurationRequestV1,
    SessionDigestArtifactV1,
    SessionDigestRequestV1,
    SessionDigestV1,
    SourceAnalysisArtifactV1,
    SourceAnalysisRequestV1,
    SourceCitationV1,
    SourceGuidePromptV1,
    SourceGuideResponseV1,
    SourceQueryArtifactV1,
    SourceQueryPromptV1,
    SourceQueryRequestV1,
    SourceQueryResponseV1,
    TranscriptSegmentV1,
    TutorTurnArtifactV1,
    TutorTurnRequestV1,
)
from .outbox import CachedCompletion, EncryptedOutbox
from .pdf_extract import (
    ExtractedSourceMaterial,
    PDFExtractionError,
    chunk_pages,
    extract_pdf_materials,
    extract_pdf_pages,
    render_pdf_page_png,
)
from .providers.base import DigestProvider, ProviderError
from .providers.manager import ProviderConfigurationError, ProviderManager

LOGGER = logging.getLogger("epistoria.worker")
_MAX_PUSH_CIPHER_BYTES = 6_250_000
_MAX_TRANSCRIPTION_BYTES = 25 * 1024 * 1024


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
        provider_configuration_manager: ProviderManager | None = None,
        cost_ledger: CostLedger | None = None,
        local_ocr_engine: OCREngine | None = None,
        local_model_manager: LocalModelManager | None = None,
    ) -> None:
        if len(account_key) != 32:
            raise ValueError("account key must be 32 bytes")
        self._account_id = account_id
        self._account_key = account_key
        self._api = api
        self._outbox = outbox
        self._digest_provider = digest_provider
        self._provider_configuration_manager = provider_configuration_manager
        self._maximum_asset_bytes = maximum_asset_bytes
        self._cost_ledger = cost_ledger
        self._local_ocr_engine = local_ocr_engine
        self._local_model_manager = local_model_manager

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
        except LocalModelPaused:
            LOGGER.info("local model download paused job=%s", lease.id)
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
        if lease.job_type == "MATH_ASSISTANCE":
            return self._math_assistance(lease, plaintext)
        if lease.job_type == "SOURCE_ANALYSIS":
            return self._source_analysis(lease, plaintext)
        if lease.job_type == "SOURCE_QUERY":
            return self._source_query(lease, plaintext)
        if lease.job_type == "TRANSCRIPTION":
            try:
                schema_version = json.loads(plaintext).get("schemaVersion")
            except (json.JSONDecodeError, UnicodeDecodeError, AttributeError) as error:
                raise ProcessingFailure(code="INVALID_JOB_PAYLOAD", retryable=False) from error
            if schema_version == "media-transcription-request/v1":
                return self._media_transcription(lease, plaintext)
            # Generic TRANSCRIPTION drafts from the earlier learning contract remain readable.
            return self._learning_generation(lease, plaintext)
        if lease.job_type == "FREE_RESPONSE_FEEDBACK":
            return self._free_response_feedback(lease, plaintext)
        if lease.job_type == "PROVIDER_CONFIGURATION":
            return self._provider_configuration(lease, plaintext)
        if lease.job_type == "TUTOR_TURN":
            return self._tutor_turn(lease, plaintext)
        if lease.job_type == "LOCAL_OCR":
            return self._local_ocr(lease, plaintext)
        if lease.job_type == "LOCAL_MODEL_CONTROL":
            return self._local_model_control(lease, plaintext)
        if lease.job_type in {
            "SOURCE_EXTRACTION",
            "TOPIC_SYNTHESIS",
            "FLASHCARD_DRAFTS",
            "TEST_BLUEPRINT",
            "TEST_GENERATION",
            "CONCEPT_SUGGESTIONS",
            "SOURCE_DISCOVERY",
            "SESSION_REVIEW",
            "WEEKLY_REVIEW",
        }:
            return self._learning_generation(lease, plaintext)
        raise ProcessingFailure(code="UNSUPPORTED_JOB_TYPE", retryable=False)

    def _local_ocr(self, lease: AIJobLease, plaintext: bytes) -> CachedCompletion:
        if self._local_ocr_engine is None:
            raise ProcessingFailure(code="LOCAL_OCR_UNAVAILABLE", retryable=False)
        try:
            request = LocalOCRRequestV1.model_validate_json(plaintext)
        except ValidationError as error:
            raise ProcessingFailure(code="INVALID_JOB_PAYLOAD", retryable=False) from error
        if request.account_id != self._account_id or request.job_id != lease.id:
            raise ProcessingFailure(code="JOB_IDENTITY_MISMATCH", retryable=False)
        try:
            response = self._local_ocr_engine.recognize(request)
        except LocalOCRError as error:
            raise ProcessingFailure(code=error.code, retryable=error.retryable) from error

        artifact_id = uuid5(lease.id, "ocr-artifact/v1")
        artifact = OCRArtifactV1(
            job_id=lease.id,
            target_kind=request.target_kind,
            target_id=request.target_id,
            parent_id=request.parent_id,
            note_id=request.note_id,
            source_version_id=request.source_version_id,
            input_revision=request.input_revision,
            input_fingerprint=hashlib.sha256(request.image_content.encode("utf-8")).hexdigest(),
            page_number=request.page_number,
            locator=request.locator,
            input_preview=(
                request.image_content if len(request.image_content) <= 900_000 else None
            ),
            generated_at=datetime.now(UTC),
            response=response,
        )
        relation_ids = [
            request.target_id,
            *(value for value in (request.note_id, request.source_version_id) if value is not None),
        ]
        mutation = self._encrypted_mutation(
            entity_id=artifact_id,
            parent_id=request.parent_id,
            relation_ids=list(dict.fromkeys(relation_ids)),
            plaintext=json_bytes(artifact),
            entity_type="RECOGNITION_ARTIFACT",
        )
        return CachedCompletion(
            job_id=lease.id,
            artifact_entity_id=artifact_id,
            mutations=[mutation],
        )

    def _local_model_control(self, lease: AIJobLease, plaintext: bytes) -> CachedCompletion:
        if self._local_model_manager is None:
            raise ProcessingFailure(code="LOCAL_MODEL_MANAGER_UNAVAILABLE", retryable=False)
        try:
            request = LocalModelControlRequestV1.model_validate_json(plaintext)
        except ValidationError as error:
            raise ProcessingFailure(code="INVALID_JOB_PAYLOAD", retryable=False) from error
        if request.account_id != self._account_id or request.job_id != lease.id:
            raise ProcessingFailure(code="JOB_IDENTITY_MISMATCH", retryable=False)
        try:
            if request.operation == "INSTALL":
                status = self._local_model_manager.install(
                    PP_FORMULANET_PLUS_S,
                    should_pause=lambda: self._api.job_status(lease.id) == "CANCELLED",
                )
            elif request.operation == "REMOVE":
                status = self._local_model_manager.remove(PP_FORMULANET_PLUS_S)
            else:
                status = self._local_model_manager.status(PP_FORMULANET_PLUS_S)
        except LocalModelError as error:
            raise ProcessingFailure(code=error.code, retryable=error.retryable) from error

        artifact_id = uuid5(lease.id, "local-model-status/v1")
        artifact = LocalModelStatusArtifactV1(
            job_id=lease.id,
            model_id="PP-FormulaNet_plus-S",
            model_version=PP_FORMULANET_PLUS_S.revision,
            operation=request.operation,
            state=status.state,
            expected_bytes=status.expected_bytes,
            verified_bytes=status.verified_bytes,
            license="Apache-2.0",
            checked_at=datetime.now(UTC),
        )
        mutation = self._encrypted_mutation(
            entity_id=artifact_id,
            parent_id=None,
            relation_ids=[],
            plaintext=json_bytes(artifact),
        )
        return CachedCompletion(
            job_id=lease.id,
            artifact_entity_id=artifact_id,
            mutations=[mutation],
        )

    def _tutor_turn(self, lease: AIJobLease, plaintext: bytes) -> CachedCompletion:
        if self._digest_provider is None:
            raise ProcessingFailure(code="AI_NOT_CONFIGURED", retryable=False)
        try:
            request = TutorTurnRequestV1.model_validate_json(plaintext)
        except ValidationError as error:
            raise ProcessingFailure(code="INVALID_JOB_PAYLOAD", retryable=False) from error
        if (
            request.account_id != self._account_id
            or request.job_id != lease.id
            or request.tutor_session_id != request.authorization.tutor_session_id
            or request.topic_id != request.authorization.topic_id
        ):
            raise ProcessingFailure(code="JOB_IDENTITY_MISMATCH", retryable=False)
        now = datetime.now(UTC)
        authorization = request.authorization
        if (
            authorization.approved_at > now + timedelta(minutes=5)
            or authorization.expires_at <= now
            or authorization.approved_turn_count >= authorization.maximum_turns
            or authorization.estimated_spent_minor_units
            >= authorization.spending_limit_minor_units
        ):
            raise ProcessingFailure(code="TUTOR_AUTHORIZATION_INVALID", retryable=False)

        response, trace = self._digest_provider.generate_tutor_turn(request)
        allowed = {source.excerpt_id for source in request.sources}
        if any(excerpt_id not in allowed for excerpt_id in response.cited_excerpt_ids):
            raise ProcessingFailure(code="PROVIDER_CITATION_INVALID", retryable=True)
        for signal in response.proposed_signals:
            if signal.objective.casefold() != request.objective.casefold():
                raise ProcessingFailure(code="PROVIDER_SIGNAL_INVALID", retryable=True)
            if any(excerpt_id not in allowed for excerpt_id in signal.cited_excerpt_ids):
                raise ProcessingFailure(code="PROVIDER_CITATION_INVALID", retryable=True)
        estimated_minor_units = round((trace.estimated_cost_usd or 0) * 100)
        if (
            authorization.estimated_spent_minor_units + estimated_minor_units
            > authorization.spending_limit_minor_units
        ):
            raise ProcessingFailure(code="TUTOR_SPENDING_LIMIT", retryable=False)
        self._record_cost(lease.id, trace)

        source_ids = list(dict.fromkeys(source.source_id for source in request.sources))
        source_version_ids = list(
            dict.fromkeys(source.source_version_id for source in request.sources)
        )
        artifact_id = uuid5(lease.id, "ai-artifact/v1")
        artifact = TutorTurnArtifactV1(
            job_id=lease.id,
            tutor_session_id=request.tutor_session_id,
            topic_id=request.topic_id,
            sequence=request.sequence,
            generated_at=now,
            sources=request.sources,
            source_excerpt_ids=[source.excerpt_id for source in request.sources],
            source_ids=source_ids,
            source_version_ids=source_version_ids,
            trace=trace,
            response=response,
        )
        relation_ids = [
            request.tutor_session_id,
            request.topic_id,
            *source_ids,
            *source_version_ids,
        ]
        mutation = self._encrypted_mutation(
            entity_id=artifact_id,
            parent_id=request.tutor_session_id,
            relation_ids=list(dict.fromkeys(relation_ids))[:64],
            plaintext=json_bytes(artifact),
        )
        return CachedCompletion(
            job_id=lease.id,
            artifact_entity_id=artifact_id,
            mutations=[mutation],
        )

    def _source_analysis(self, lease: AIJobLease, plaintext: bytes) -> CachedCompletion:
        if self._digest_provider is None:
            raise ProcessingFailure(code="AI_NOT_CONFIGURED", retryable=False)
        try:
            request = SourceAnalysisRequestV1.model_validate_json(plaintext)
        except ValidationError as error:
            raise ProcessingFailure(code="INVALID_JOB_PAYLOAD", retryable=False) from error
        extracted = self._extract_source_material(request, lease)
        prompt = SourceGuidePromptV1(
            title=request.title,
            output_language=request.output_language,
            materials=extracted.materials,
            provider_route=request.provider_route,
        )
        guide, trace = self._digest_provider.generate_source_guide(prompt)
        allowed = {item.source_id for item in extracted.materials}
        cited = self._guide_citations(guide, allowed)
        for gap in extracted.coverage_gaps:
            if gap not in guide.coverage_gaps:
                guide.coverage_gaps.append(gap)
        references = self._citation_snapshots(extracted, cited)
        self._record_cost(lease.id, trace)
        artifact_id = uuid5(lease.id, "ai-artifact/v1")
        artifact = SourceAnalysisArtifactV1(
            job_id=lease.id,
            source_id=request.source_id,
            source_version_id=request.source_version_id,
            generated_at=datetime.now(UTC),
            page_count=extracted.page_count,
            analyzed_page_count=extracted.analyzed_page_count,
            references=references,
            trace=trace,
            guide=guide,
        )
        mutation = self._encrypted_mutation(
            entity_id=artifact_id,
            parent_id=request.source_id,
            relation_ids=[request.source_id, request.source_version_id, *cited][:64],
            plaintext=json_bytes(artifact),
        )
        return CachedCompletion(
            job_id=lease.id, artifact_entity_id=artifact_id, mutations=[mutation]
        )

    def _source_query(self, lease: AIJobLease, plaintext: bytes) -> CachedCompletion:
        if self._digest_provider is None:
            raise ProcessingFailure(code="AI_NOT_CONFIGURED", retryable=False)
        try:
            request = SourceQueryRequestV1.model_validate_json(plaintext)
        except ValidationError as error:
            raise ProcessingFailure(code="INVALID_JOB_PAYLOAD", retryable=False) from error
        extracted = self._extract_source_material(request, lease, question=request.question)
        prompt = SourceQueryPromptV1(
            title=request.title,
            output_language=request.output_language,
            materials=extracted.materials,
            question=request.question,
            provider_route=request.provider_route,
        )
        response, trace = self._digest_provider.generate_source_query(prompt)
        allowed = {item.source_id for item in extracted.materials}
        cited = self._query_citations(response, allowed)
        references = self._citation_snapshots(extracted, cited)
        self._record_cost(lease.id, trace)
        artifact_id = uuid5(lease.id, "ai-artifact/v1")
        artifact = SourceQueryArtifactV1(
            job_id=lease.id,
            source_id=request.source_id,
            source_version_id=request.source_version_id,
            question=request.question,
            generated_at=datetime.now(UTC),
            references=references,
            trace=trace,
            response=response,
        )
        mutation = self._encrypted_mutation(
            entity_id=artifact_id,
            parent_id=request.source_id,
            relation_ids=[request.source_id, request.source_version_id, *cited][:64],
            plaintext=json_bytes(artifact),
        )
        return CachedCompletion(
            job_id=lease.id, artifact_entity_id=artifact_id, mutations=[mutation]
        )

    def _extract_source_material(
        self,
        request: SourceAnalysisRequestV1 | SourceQueryRequestV1,
        lease: AIJobLease,
        *,
        question: str | None = None,
    ) -> ExtractedSourceMaterial:
        if request.account_id != self._account_id or request.job_id != lease.id:
            raise ProcessingFailure(code="JOB_IDENTITY_MISMATCH", retryable=False)
        try:
            asset_key = base64url.decode(request.asset_key, field="assetKey")
            if len(asset_key) != 32:
                raise ValueError("asset key has the wrong length")
        except ValueError as error:
            raise ProcessingFailure(code="INVALID_JOB_PAYLOAD", retryable=False) from error
        encrypted = self._api.download_encrypted_asset(
            request.asset_id, maximum_bytes=self._maximum_asset_bytes
        )
        try:
            pdf_bytes = decrypt_bytes(encrypted, key=asset_key)
        except AssetCryptoError as error:
            raise ProcessingFailure(code="ASSET_DECRYPTION_FAILED", retryable=False) from error
        try:
            actual_tag = plaintext_dedupe_tag(
                pdf_bytes, account_key=self._account_key, account_id=self._account_id
            )
            if not hmac.compare_digest(actual_tag, request.expected_dedupe_tag):
                raise ProcessingFailure(code="ASSET_DEDUPE_MISMATCH", retryable=False)
            return extract_pdf_materials(
                pdf_bytes,
                source_version_id=request.source_version_id,
                question=question,
                include_images=request.include_images,
            )
        except PDFExtractionError as error:
            raise ProcessingFailure(
                code="SOURCE_ANALYSIS_EXTRACTION_FAILED", retryable=False
            ) from error
        finally:
            pdf_bytes = b""

    @staticmethod
    def _guide_citations(response: SourceGuideResponseV1, allowed: set[UUID]) -> list[UUID]:
        values: list[UUID] = []
        for statement in [
            *response.summary,
            *response.translated_summary,
            *response.image_insights,
        ]:
            values.extend(statement.source_ids)
        for topic in response.key_topics:
            values.extend(topic.source_ids)
        for question in response.suggested_questions:
            values.extend(question.source_ids)
        return WorkerProcessor._validated_citation_ids(values, allowed)

    @staticmethod
    def _query_citations(response: SourceQueryResponseV1, allowed: set[UUID]) -> list[UUID]:
        return WorkerProcessor._validated_citation_ids(
            [source_id for statement in response.answer for source_id in statement.source_ids],
            allowed,
        )

    @staticmethod
    def _validated_citation_ids(values: list[UUID], allowed: set[UUID]) -> list[UUID]:
        result: list[UUID] = []
        for source_id in values:
            if source_id not in allowed:
                raise ProcessingFailure(code="PROVIDER_CITATION_INVALID", retryable=True)
            if source_id not in result:
                result.append(source_id)
        if not result:
            raise ProcessingFailure(code="PROVIDER_CITATION_INVALID", retryable=True)
        return result

    @staticmethod
    def _citation_snapshots(
        extracted: ExtractedSourceMaterial, cited: list[UUID]
    ) -> list[SourceCitationV1]:
        by_id = {item.source_id: item for item in extracted.materials}
        return [
            SourceCitationV1(
                source_id=source_id,
                kind=by_id[source_id].kind,
                page_number=by_id[source_id].page_number,
                rectangles=by_id[source_id].rectangles,
                excerpt=by_id[source_id].excerpt,
            )
            for source_id in cited
        ]

    def _record_cost(self, job_id: UUID, trace: Any) -> None:
        if self._cost_ledger is None:
            return
        self._cost_ledger.record(
            job_id=job_id,
            provider=trace.provider,
            model=trace.model,
            prompt_version=trace.prompt_version,
            input_tokens=trace.input_tokens,
            output_tokens=trace.output_tokens,
            estimated_cost_usd=trace.estimated_cost_usd,
            provider_request_id=trace.provider_request_id,
        )

    def _provider_configuration(self, lease: AIJobLease, plaintext: bytes) -> CachedCompletion:
        if self._provider_configuration_manager is None:
            raise ProcessingFailure(code="PROVIDER_CONFIGURATION_UNAVAILABLE", retryable=False)
        try:
            request = ProviderConfigurationRequestV1.model_validate_json(plaintext)
        except ValidationError as error:
            raise ProcessingFailure(code="INVALID_JOB_PAYLOAD", retryable=False) from error
        if request.account_id != self._account_id or request.job_id != lease.id:
            raise ProcessingFailure(code="JOB_IDENTITY_MISMATCH", retryable=False)
        try:
            artifact = self._provider_configuration_manager.apply_configuration(request)
        except ProviderConfigurationError as error:
            raise ProcessingFailure(
                code="PROVIDER_CONFIGURATION_INVALID", retryable=False
            ) from error
        artifact_id = uuid5(lease.id, "provider-configuration-artifact/v1")
        mutation = self._encrypted_mutation(
            entity_id=artifact_id,
            parent_id=None,
            relation_ids=[],
            plaintext=json_bytes(artifact),
        )
        return CachedCompletion(
            job_id=lease.id,
            artifact_entity_id=artifact_id,
            mutations=[mutation],
        )

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

    def _math_assistance(self, lease: AIJobLease, plaintext: bytes) -> CachedCompletion:
        if self._digest_provider is None:
            raise ProcessingFailure(code="AI_NOT_CONFIGURED", retryable=False)
        try:
            request = MathAssistanceRequestV1.model_validate_json(plaintext)
        except ValidationError as error:
            raise ProcessingFailure(code="INVALID_JOB_PAYLOAD", retryable=False) from error
        if request.account_id != self._account_id or request.job_id != lease.id:
            raise ProcessingFailure(code="JOB_IDENTITY_MISMATCH", retryable=False)

        response, trace = self._digest_provider.generate_math_assistance(request)
        allowed_ids = {
            source.source_id for source in request.selection_sources + request.context_sources
        }
        selected_ids = {source.source_id for source in request.selection_sources}
        cited_ids = set(response.cited_source_ids)
        if not cited_ids.issubset(allowed_ids) or not cited_ids.intersection(selected_ids):
            raise ProcessingFailure(code="PROVIDER_CITATION_INVALID", retryable=True)
        if response.graph_expression is not None:
            if not re.fullmatch(r"[0-9A-Za-z+*/^().\-\s]+", response.graph_expression):
                raise ProcessingFailure(code="PROVIDER_GRAPH_INVALID", retryable=True)
            identifiers = set(re.findall(r"[A-Za-z]+", response.graph_expression.lower()))
            if not identifiers.issubset(
                {"x", "pi", "e", "sin", "cos", "tan", "sqrt", "abs", "ln", "log", "exp"}
            ):
                raise ProcessingFailure(code="PROVIDER_GRAPH_INVALID", retryable=True)

        if self._cost_ledger is not None:
            self._cost_ledger.record(
                job_id=lease.id,
                provider=trace.provider,
                model=trace.model,
                prompt_version=trace.prompt_version,
                input_tokens=trace.input_tokens,
                output_tokens=trace.output_tokens,
                estimated_cost_usd=trace.estimated_cost_usd,
                provider_request_id=trace.provider_request_id,
            )

        artifact_id = uuid5(lease.id, "ai-artifact/math-assistance/v1")
        artifact = MathAssistanceArtifactV1(
            job_id=lease.id,
            note_id=request.note_id,
            mode=request.mode,
            learner_instructions=request.learner_instructions,
            generated_at=datetime.now(UTC),
            source_ids=list(response.cited_source_ids),
            trace=trace,
            response=response,
        )
        mutation = self._encrypted_mutation(
            entity_id=artifact_id,
            parent_id=request.note_id,
            relation_ids=list(response.cited_source_ids)[:48],
            plaintext=json_bytes(artifact),
        )
        return CachedCompletion(
            job_id=lease.id,
            artifact_entity_id=artifact_id,
            mutations=[mutation],
        )

    def _learning_generation(self, lease: AIJobLease, plaintext: bytes) -> CachedCompletion:
        if self._digest_provider is None:
            raise ProcessingFailure(code="AI_NOT_CONFIGURED", retryable=False)
        try:
            request = LearningGenerationRequestV1.model_validate_json(plaintext)
        except ValidationError as error:
            raise ProcessingFailure(code="INVALID_JOB_PAYLOAD", retryable=False) from error
        if (
            request.account_id != self._account_id
            or request.job_id != lease.id
            or request.job_type != lease.job_type
        ):
            raise ProcessingFailure(code="JOB_IDENTITY_MISMATCH", retryable=False)
        authorization = self._validate_automation(request)
        response, trace = self._digest_provider.generate_learning(request)
        if response.concept_links and request.job_type != "CONCEPT_SUGGESTIONS":
            raise ProcessingFailure(code="PROVIDER_CONCEPT_INVALID", retryable=True)
        allowed_ids = {source.source_id for source in request.sources}
        cited: list[UUID] = []
        seen: set[UUID] = set()
        for item in response.items:
            for source_id in item.cited_source_ids:
                if source_id not in allowed_ids:
                    raise ProcessingFailure(code="PROVIDER_CITATION_INVALID", retryable=True)
                if source_id not in seen:
                    cited.append(source_id)
                    seen.add(source_id)
        allowed_concept_ids = {concept.id for concept in request.known_concepts}
        for link in response.concept_links:
            for concept_id in (link.source_concept_id, link.target_concept_id):
                if concept_id is not None and concept_id not in allowed_concept_ids:
                    raise ProcessingFailure(code="PROVIDER_CONCEPT_INVALID", retryable=True)
            for source_id in link.cited_source_ids:
                if source_id not in allowed_ids:
                    raise ProcessingFailure(code="PROVIDER_CITATION_INVALID", retryable=True)
                if source_id not in seen:
                    cited.append(source_id)
                    seen.add(source_id)
        if not cited:
            raise ProcessingFailure(code="PROVIDER_CITATION_INVALID", retryable=True)
        if self._cost_ledger is not None:
            self._cost_ledger.record(
                job_id=lease.id,
                provider=trace.provider,
                model=trace.model,
                prompt_version=trace.prompt_version,
                input_tokens=trace.input_tokens,
                output_tokens=trace.output_tokens,
                estimated_cost_usd=trace.estimated_cost_usd,
                provider_request_id=trace.provider_request_id,
                automation_grant_id=(authorization.grant_id if authorization else None),
                automation_scope_key=(authorization.scope_key if authorization else None),
            )
        artifact_id = uuid5(lease.id, "ai-artifact/v1")
        artifact = LearningGenerationArtifactV1(
            job_id=lease.id,
            job_type=request.job_type,
            topic_id=request.topic_id,
            include_connected_knowledge=request.include_connected_knowledge,
            generated_at=datetime.now(UTC),
            source_ids=cited,
            trace=trace,
            response=response,
            test_plan=request.test_plan,
            known_concept_ids=[concept.id for concept in request.known_concepts],
        )
        mutation = self._encrypted_mutation(
            entity_id=artifact_id,
            parent_id=request.topic_id,
            relation_ids=[request.topic_id, *cited[:63]],
            plaintext=json_bytes(artifact),
        )
        return CachedCompletion(
            job_id=lease.id,
            artifact_entity_id=artifact_id,
            mutations=[mutation],
        )

    def _validate_automation(
        self, request: LearningGenerationRequestV1
    ) -> AutomationAuthorizationV1 | None:
        authorization = request.automation_authorization
        if authorization is None:
            return None
        now = datetime.now(UTC)
        expected_scope = f"{request.topic_id}:{request.job_type}"
        if (
            authorization.scope_key != expected_scope
            or authorization.authorized_at > now + timedelta(minutes=5)
            or authorization.expires_at <= now
        ):
            raise ProcessingFailure(code="AUTOMATION_GRANT_INVALID", retryable=False)
        if self._cost_ledger is None:
            raise ProcessingFailure(code="AUTOMATION_LEDGER_REQUIRED", retryable=False)
        status = self._cost_ledger.automation_status(
            grant_id=authorization.grant_id,
            scope_key=authorization.scope_key,
        )
        if round(status.estimated_usd * 100) >= authorization.spending_limit_minor_units:
            raise ProcessingFailure(code="AUTOMATION_SPENDING_LIMIT", retryable=False)
        if status.last_recorded_at is not None and (
            now - status.last_recorded_at < timedelta(hours=authorization.minimum_interval_hours)
        ):
            raise ProcessingFailure(code="AUTOMATION_FREQUENCY_LIMIT", retryable=False)
        return authorization

    def _free_response_feedback(self, lease: AIJobLease, plaintext: bytes) -> CachedCompletion:
        if self._digest_provider is None:
            raise ProcessingFailure(code="AI_NOT_CONFIGURED", retryable=False)
        try:
            request = FreeResponseFeedbackRequestV1.model_validate_json(plaintext)
        except ValidationError as error:
            raise ProcessingFailure(code="INVALID_JOB_PAYLOAD", retryable=False) from error
        if request.account_id != self._account_id or request.job_id != lease.id:
            raise ProcessingFailure(code="JOB_IDENTITY_MISMATCH", retryable=False)

        response, trace = self._digest_provider.generate_free_response_feedback(request)
        allowed_ids = {item.source_id for item in request.evidence}
        if not set(response.cited_source_ids).issubset(allowed_ids):
            raise ProcessingFailure(code="PROVIDER_CITATION_INVALID", retryable=True)
        if self._cost_ledger is not None:
            self._cost_ledger.record(
                job_id=lease.id,
                provider=trace.provider,
                model=trace.model,
                prompt_version=trace.prompt_version,
                input_tokens=trace.input_tokens,
                output_tokens=trace.output_tokens,
                estimated_cost_usd=trace.estimated_cost_usd,
                provider_request_id=trace.provider_request_id,
            )
        cited_ids = list(dict.fromkeys(response.cited_source_ids))
        artifact_id = uuid5(lease.id, "ai-artifact/v1")
        artifact = FreeResponseFeedbackArtifactV1(
            job_id=lease.id,
            attempt_id=request.attempt_id,
            response_id=request.response_id,
            question_id=request.question_id,
            topic_id=request.topic_id,
            generated_at=datetime.now(UTC),
            source_ids=cited_ids,
            trace=trace,
            response=response,
        )
        mutation = self._encrypted_mutation(
            entity_id=artifact_id,
            parent_id=request.attempt_id,
            relation_ids=[
                request.attempt_id,
                request.response_id,
                request.question_id,
                request.topic_id,
                *cited_ids,
            ][:64],
            plaintext=json_bytes(artifact),
        )
        return CachedCompletion(
            job_id=lease.id,
            artifact_entity_id=artifact_id,
            mutations=[mutation],
        )

    def _pdf_extraction(self, lease: AIJobLease, plaintext: bytes) -> CachedCompletion:
        try:
            raw = json.loads(plaintext)
            request: PDFExtractionRequestV1 | PDFExtractionRequestV2
            if raw.get("schemaVersion") == "pdf-extraction-request/v2":
                request = PDFExtractionRequestV2.model_validate(raw)
            else:
                request = PDFExtractionRequestV1.model_validate(raw)
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
            ocr_mutations = self._source_ocr_mutations(
                lease=lease,
                request=request,
                pages=pages,
                pdf_bytes=pdf_bytes,
            )
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

        mutations.extend(ocr_mutations)

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

    def _source_ocr_mutations(
        self,
        *,
        lease: AIJobLease,
        request: PDFExtractionRequestV1 | PDFExtractionRequestV2,
        pages: list[Any],
        pdf_bytes: bytes,
    ) -> list[dict[str, Any]]:
        if (
            not isinstance(request, PDFExtractionRequestV2)
            or not request.automatic_ocr
            or self._local_ocr_engine is None
        ):
            return []
        mutations: list[dict[str, Any]] = []
        for page in pages:
            if not page.needs_ocr:
                continue
            png = render_pdf_page_png(pdf_bytes, page.page_number)
            encoded = base64.b64encode(png).decode("ascii")
            locator = {
                "schemaVersion": "source-locator/v1",
                "kind": "PDF",
                "page": page.page_number,
                "rectangles": [{"x": 0, "y": 0, "width": 1, "height": 1}],
            }
            text_request = LocalOCRRequestV1(
                account_id=request.account_id,
                job_id=lease.id,
                target_kind="SOURCE_PAGE",
                target_id=request.source_version_id,
                parent_id=request.resource_id,
                source_version_id=request.source_version_id,
                input_revision=0,
                page_number=page.page_number,
                locator=locator,
                image_content=encoded,
                preferred_languages=request.preferred_ocr_languages,
                mode="TEXT",
                disclosure_acknowledged=True,
            )
            try:
                response = self._local_ocr_engine.recognize(text_request)
            except LocalOCRError as error:
                LOGGER.warning(
                    "local Source OCR unavailable job=%s page=%d code=%s",
                    lease.id,
                    page.page_number,
                    error.code,
                )
                continue
            mutations.append(
                self._ocr_artifact_mutation(
                    lease=lease,
                    request=text_request,
                    response=response,
                    suffix=f"source-page/{page.page_number}/text",
                )
            )
            if request.automatic_formula_ocr and self._response_looks_mathematical(response):
                formula_request = text_request.model_copy(update={"mode": "FORMULA"})
                try:
                    formula_response = self._local_ocr_engine.recognize(formula_request)
                except LocalOCRError as error:
                    LOGGER.warning(
                        "local Source formula OCR unavailable job=%s page=%d code=%s",
                        lease.id,
                        page.page_number,
                        error.code,
                    )
                else:
                    mutations.append(
                        self._ocr_artifact_mutation(
                            lease=lease,
                            request=formula_request,
                            response=formula_response,
                            suffix=f"source-page/{page.page_number}/formula",
                        )
                    )
        return mutations

    @staticmethod
    def _response_looks_mathematical(response: Any) -> bool:
        text = " ".join(region.text for region in response.regions)
        return bool(re.search(r"[=+\-*/^√∫∑]|\b\d*[A-Za-z]\s*\d*\b", text))

    def _ocr_artifact_mutation(
        self,
        *,
        lease: AIJobLease,
        request: LocalOCRRequestV1,
        response: Any,
        suffix: str,
    ) -> dict[str, Any]:
        artifact = OCRArtifactV1(
            job_id=lease.id,
            target_kind=request.target_kind,
            target_id=request.target_id,
            parent_id=request.parent_id,
            note_id=request.note_id,
            source_version_id=request.source_version_id,
            input_revision=request.input_revision,
            input_fingerprint=hashlib.sha256(request.image_content.encode("utf-8")).hexdigest(),
            page_number=request.page_number,
            locator=request.locator,
            input_preview=(
                request.image_content if len(request.image_content) <= 900_000 else None
            ),
            generated_at=datetime.now(UTC),
            response=response,
        )
        return self._encrypted_mutation(
            entity_id=uuid5(lease.id, f"ocr-artifact/{suffix}"),
            parent_id=request.parent_id,
            relation_ids=[
                value
                for value in (request.target_id, request.source_version_id)
                if value is not None
            ],
            plaintext=json_bytes(artifact),
            entity_type="RECOGNITION_ARTIFACT",
        )

    def _media_transcription(self, lease: AIJobLease, plaintext: bytes) -> CachedCompletion:
        if self._digest_provider is None:
            raise ProcessingFailure(code="AI_NOT_CONFIGURED", retryable=False)
        try:
            request = MediaTranscriptionRequestV1.model_validate_json(plaintext)
            asset_key = base64url.decode(request.asset_key, field="assetKey")
            if len(asset_key) != 32:
                raise ValueError("asset key has the wrong length")
        except (ValidationError, ValueError) as error:
            raise ProcessingFailure(code="INVALID_JOB_PAYLOAD", retryable=False) from error
        if request.account_id != self._account_id or request.job_id != lease.id:
            raise ProcessingFailure(code="JOB_IDENTITY_MISMATCH", retryable=False)
        if request.expected_plaintext_bytes > _MAX_TRANSCRIPTION_BYTES:
            raise ProcessingFailure(code="TRANSCRIPTION_MEDIA_TOO_LARGE", retryable=False)

        encrypted = self._api.download_encrypted_asset(
            request.asset_id, maximum_bytes=self._maximum_asset_bytes
        )
        try:
            media = decrypt_bytes(encrypted, key=asset_key)
        except AssetCryptoError as error:
            raise ProcessingFailure(code="ASSET_DECRYPTION_FAILED", retryable=False) from error
        if len(media) != request.expected_plaintext_bytes or len(media) > _MAX_TRANSCRIPTION_BYTES:
            raise ProcessingFailure(code="TRANSCRIPTION_MEDIA_SIZE_MISMATCH", retryable=False)
        actual_tag = plaintext_dedupe_tag(
            media, account_key=self._account_key, account_id=self._account_id
        )
        if not hmac.compare_digest(actual_tag, request.expected_dedupe_tag):
            raise ProcessingFailure(code="ASSET_DEDUPE_MISMATCH", retryable=False)
        self._validate_transcription_media_identity(request, media)
        try:
            response, trace = self._digest_provider.transcribe_media(
                filename=request.filename,
                mime_type=request.mime_type,
                media=media,
                language=request.language,
                provider_route=request.provider_route,
            )
        finally:
            media = b""

        chunks = self._chunk_transcript(response.segments)
        chunk_ids = [
            uuid5(lease.id, f"media-transcription-chunk/{index}") for index in range(len(chunks))
        ]
        mutations: list[dict[str, Any]] = []
        for index, (entity_id, selected_segments) in enumerate(zip(chunk_ids, chunks, strict=True)):
            chunk = MediaTranscriptionChunkV1(
                job_id=lease.id,
                source_id=request.source_id,
                source_version_id=request.source_version_id,
                chunk_index=index,
                segments=selected_segments,
            )
            mutations.append(
                self._encrypted_mutation(
                    entity_id=entity_id,
                    parent_id=request.source_id,
                    relation_ids=[request.source_id, request.source_version_id],
                    plaintext=json_bytes(chunk),
                )
            )

        if self._cost_ledger is not None:
            self._cost_ledger.record(
                job_id=lease.id,
                provider=trace.provider,
                model=trace.model,
                prompt_version=trace.prompt_version,
                input_tokens=trace.input_tokens,
                output_tokens=trace.output_tokens,
                estimated_cost_usd=trace.estimated_cost_usd,
                provider_request_id=trace.provider_request_id,
            )
        character_count = sum(len(segment.text) for segment in response.segments)
        if character_count > 5_000_000:
            raise ProcessingFailure(code="TRANSCRIPTION_TOO_LARGE", retryable=False)
        artifact_id = uuid5(lease.id, "ai-artifact/v1")
        manifest = MediaTranscriptionManifestV1(
            job_id=lease.id,
            source_id=request.source_id,
            source_version_id=request.source_version_id,
            generated_at=datetime.now(UTC),
            language=response.language,
            duration_seconds=response.duration_seconds,
            character_count=character_count,
            segment_count=len(response.segments),
            trace=trace,
            chunk_entity_ids=chunk_ids,
        )
        mutations.append(
            self._encrypted_mutation(
                entity_id=artifact_id,
                parent_id=request.source_id,
                relation_ids=[request.source_id, request.source_version_id, *chunk_ids[:62]],
                plaintext=json_bytes(manifest),
            )
        )
        return CachedCompletion(
            job_id=lease.id,
            artifact_entity_id=artifact_id,
            mutations=mutations,
        )

    @staticmethod
    def _validate_transcription_media_identity(
        request: MediaTranscriptionRequestV1, media: bytes
    ) -> None:
        extension = request.filename.rpartition(".")[2].lower()
        valid = False
        if extension == "wav":
            valid = len(media) >= 12 and media[:4] == b"RIFF" and media[8:12] == b"WAVE"
        elif extension == "mp3":
            valid = media.startswith(b"ID3") or (
                len(media) >= 2 and media[0] == 0xFF and media[1] & 0xE0 == 0xE0
            )
        elif extension in {"m4a", "mp4"}:
            valid = len(media) >= 12 and media[4:8] == b"ftyp"
        if not valid:
            raise ProcessingFailure(code="TRANSCRIPTION_MEDIA_IDENTITY_MISMATCH", retryable=False)

    @staticmethod
    def _chunk_transcript(segments: list[TranscriptSegmentV1]) -> list[list[TranscriptSegmentV1]]:
        chunks: list[list[TranscriptSegmentV1]] = []
        current: list[TranscriptSegmentV1] = []
        current_characters = 0
        for segment in segments:
            if current and (
                len(current) >= 500 or current_characters + len(segment.text) > 250_000
            ):
                chunks.append(current)
                current = []
                current_characters = 0
            current.append(segment)
            current_characters += len(segment.text)
        if current:
            chunks.append(current)
        if not chunks or len(chunks) > 64:
            raise ProcessingFailure(code="TRANSCRIPTION_TOO_LARGE", retryable=False)
        return chunks

    def _encrypted_mutation(
        self,
        *,
        entity_id: UUID,
        parent_id: UUID | None,
        relation_ids: list[UUID],
        plaintext: bytes,
        entity_type: str = "AI_ARTIFACT",
    ) -> dict[str, Any]:
        if len(plaintext) > 2_097_152:
            raise ProcessingFailure(code="ARTIFACT_TOO_LARGE", retryable=False)
        envelope = encrypt_entity(
            plaintext,
            account_key=self._account_key,
            account_id=self._account_id,
            entity_type=entity_type,
            entity_id=entity_id,
            content_version=1,
        )
        timestamp = datetime.now(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")
        return {
            "mutationId": str(uuid5(entity_id, "epistoria-sync-mutation/v1")),
            "entityId": str(entity_id),
            "entityType": entity_type,
            "operation": "UPSERT",
            "baseRevision": 0,
            "parentId": str(parent_id) if parent_id is not None else None,
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
