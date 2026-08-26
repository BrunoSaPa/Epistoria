from __future__ import annotations

import ipaddress
from datetime import UTC, datetime
from urllib.parse import urlsplit, urlunsplit
from uuid import UUID

from ..keychain import ProviderProfileStore, StoredProviderProfile
from ..models import (
    FreeResponseFeedbackRequestV1,
    FreeResponseFeedbackResponseV1,
    LearningGenerationRequestV1,
    LearningGenerationResponseV1,
    MediaTranscriptionResponseV1,
    NoteQueryRequestV1,
    NoteQueryResponseV1,
    ProviderAdapter,
    ProviderCapability,
    ProviderConfigurationArtifactV1,
    ProviderConfigurationRequestV1,
    ProviderRouteSnapshotV1,
    ProviderTraceV1,
    SessionDigestRequestV1,
    SessionDigestV1,
    SourceGuidePromptV1,
    SourceGuideResponseV1,
    SourceQueryPromptV1,
    SourceQueryResponseV1,
    TutorTurnRequestV1,
    TutorTurnResponseV1,
)
from .base import DigestProvider, ProviderError
from .native_provider import (
    AnthropicMessagesDigestProvider,
    GeminiGenerateContentDigestProvider,
)
from .openai_provider import OpenAICompatibleDigestProvider, OpenAIDigestProvider


class ProviderConfigurationError(ValueError):
    pass


class ProviderManager:
    def __init__(
        self,
        *,
        account_id: UUID,
        store: ProviderProfileStore,
        fallback: DigestProvider | None,
    ) -> None:
        self._account_id = account_id
        self._store = store
        self._fallback = fallback

    @property
    def is_ready(self) -> bool:
        try:
            return self._active_profile() is not None or (
                not self._store.managed(self._account_id) and self._fallback is not None
            )
        except ProviderConfigurationError:
            return False

    def apply_configuration(
        self, request: ProviderConfigurationRequestV1
    ) -> ProviderConfigurationArtifactV1:
        if request.account_id != self._account_id or not request.disclosure_acknowledged:
            raise ProviderConfigurationError("provider configuration identity is invalid")
        if request.operation == "UPSERT":
            profile = self._upsert(request)
            if request.make_active or self._store.active(self._account_id) is None:
                self._store.set_active(self._account_id, profile.profile_id)
            return self._artifact(request, profile)
        if request.operation == "ACTIVATE":
            activated_profile = self._store.get(self._account_id, request.profile_id)
            if activated_profile is None:
                raise ProviderConfigurationError("provider profile is not stored on this Mac")
            self._store.set_active(self._account_id, request.profile_id)
            return self._artifact(request, activated_profile)
        if request.operation == "DELETE":
            existing = self._store.get(self._account_id, request.profile_id)
            self._store.delete(self._account_id, request.profile_id)
            return ProviderConfigurationArtifactV1(
                job_id=request.job_id,
                profile_id=request.profile_id,
                operation=request.operation,
                display_name=existing.display_name if existing else None,
                adapter=(_provider_adapter(existing.adapter) if existing is not None else None),
                base_url=existing.base_url if existing else None,
                text_model=existing.text_model if existing else None,
                transcription_model=existing.transcription_model if existing else None,
                capabilities=(
                    [_provider_capability(value) for value in existing.capabilities]
                    if existing is not None
                    else []
                ),
                is_active=False,
                secret_stored=False,
                configured_at=datetime.now(UTC),
            )
        raise ProviderConfigurationError("unsupported provider configuration operation")

    def generate(self, request: SessionDigestRequestV1) -> tuple[SessionDigestV1, ProviderTraceV1]:
        return self._required_provider("TEXT", request.provider_route).generate(request)

    def generate_learning(
        self, request: LearningGenerationRequestV1
    ) -> tuple[LearningGenerationResponseV1, ProviderTraceV1]:
        return self._required_provider("TEXT", request.provider_route).generate_learning(request)

    def generate_note_query(
        self, request: NoteQueryRequestV1
    ) -> tuple[NoteQueryResponseV1, ProviderTraceV1]:
        capability: ProviderCapability = (
            "VISION"
            if any(source.image_content for source in request.selection_sources)
            else "TEXT"
        )
        return self._required_provider(capability, request.provider_route).generate_note_query(
            request
        )

    def generate_free_response_feedback(
        self, request: FreeResponseFeedbackRequestV1
    ) -> tuple[FreeResponseFeedbackResponseV1, ProviderTraceV1]:
        return self._required_provider(
            "TEXT", request.provider_route
        ).generate_free_response_feedback(request)

    def generate_source_guide(
        self, request: SourceGuidePromptV1
    ) -> tuple[SourceGuideResponseV1, ProviderTraceV1]:
        capability: ProviderCapability = (
            "VISION" if any(item.image_content for item in request.materials) else "TEXT"
        )
        return self._required_provider(capability, request.provider_route).generate_source_guide(
            request
        )

    def generate_source_query(
        self, request: SourceQueryPromptV1
    ) -> tuple[SourceQueryResponseV1, ProviderTraceV1]:
        capability: ProviderCapability = (
            "VISION" if any(item.image_content for item in request.materials) else "TEXT"
        )
        return self._required_provider(capability, request.provider_route).generate_source_query(
            request
        )

    def generate_tutor_turn(
        self, request: TutorTurnRequestV1
    ) -> tuple[TutorTurnResponseV1, ProviderTraceV1]:
        return self._required_provider("TEXT", request.provider_route).generate_tutor_turn(request)

    def transcribe_media(
        self,
        *,
        filename: str,
        mime_type: str,
        media: bytes,
        language: str | None,
        provider_route: ProviderRouteSnapshotV1 | None = None,
    ) -> tuple[MediaTranscriptionResponseV1, ProviderTraceV1]:
        return self._required_provider("TRANSCRIPTION", provider_route).transcribe_media(
            filename=filename,
            mime_type=mime_type,
            media=media,
            language=language,
        )

    def _upsert(self, request: ProviderConfigurationRequestV1) -> StoredProviderProfile:
        if request.display_name is None or request.adapter is None or request.text_model is None:
            raise ProviderConfigurationError("provider name, adapter, and text model are required")
        base_url = safe_provider_base_url(request.base_url, adapter=request.adapter)
        existing = self._store.get(self._account_id, request.profile_id)
        api_key = request.api_key
        if api_key is None and existing is not None and existing.adapter == request.adapter:
            api_key = existing.api_key
        hosted_adapters = {
            "OPENAI_RESPONSES": "OpenAI",
            "ANTHROPIC_MESSAGES": "Anthropic",
            "GEMINI_GENERATE_CONTENT": "Gemini",
        }
        if request.adapter in hosted_adapters and not api_key:
            provider_name = hosted_adapters[request.adapter]
            raise ProviderConfigurationError(f"{provider_name} requires an API key")
        capabilities = tuple(dict.fromkeys(request.capabilities))
        if "TEXT" not in capabilities:
            raise ProviderConfigurationError("the provider must support text generation")
        if request.adapter in {"ANTHROPIC_MESSAGES", "GEMINI_GENERATE_CONTENT"}:
            if "TRANSCRIPTION" in capabilities or request.transcription_model is not None:
                raise ProviderConfigurationError(
                    "this native provider adapter does not support timestamped transcription"
                )
            if not request.structured_output:
                raise ProviderConfigurationError(
                    "this native provider adapter requires structured output"
                )
        profile = StoredProviderProfile(
            profile_id=request.profile_id,
            configuration_revision_id=request.configuration_revision_id or request.profile_id,
            display_name=request.display_name.strip(),
            adapter=request.adapter,
            base_url=base_url,
            api_key=api_key,
            text_model=request.text_model.strip(),
            transcription_model=(
                request.transcription_model.strip() if request.transcription_model else None
            ),
            capabilities=capabilities,
            structured_output=request.structured_output,
            input_usd_per_million=request.input_usd_per_million,
            output_usd_per_million=request.output_usd_per_million,
            transcription_usd_per_minute=request.transcription_usd_per_minute,
        )
        if not profile.display_name or not profile.text_model:
            raise ProviderConfigurationError("provider name and text model cannot be empty")
        self._store.set(self._account_id, profile)
        self._store.mark_managed(self._account_id)
        return profile

    def _required_provider(
        self,
        capability: ProviderCapability,
        route: ProviderRouteSnapshotV1 | None = None,
    ) -> DigestProvider:
        profile = self._profile_for_route(route) if route is not None else self._active_profile()
        if profile is None:
            if self._fallback is None or self._store.managed(self._account_id):
                raise ProviderError(
                    "No AI provider is configured",
                    code="AI_NOT_CONFIGURED",
                    retryable=False,
                )
            return self._fallback
        if capability not in profile.capabilities:
            raise ProviderError(
                f"The active provider does not declare {capability.lower()} support",
                code="PROVIDER_CAPABILITY_UNAVAILABLE",
                retryable=False,
            )
        name = f"profile:{profile.profile_id}"
        if profile.adapter == "OPENAI_RESPONSES":
            return OpenAIDigestProvider(
                api_key=profile.api_key or "",
                base_url=profile.base_url,
                provider_name=name,
                model=profile.text_model,
                prompt_version="session-digest/v1",
                input_usd_per_million=profile.input_usd_per_million,
                output_usd_per_million=profile.output_usd_per_million,
                transcription_model=profile.transcription_model or "whisper-1",
                transcription_usd_per_minute=profile.transcription_usd_per_minute,
            )
        if profile.adapter == "OPENAI_COMPATIBLE":
            return OpenAICompatibleDigestProvider(
                api_key=profile.api_key or "",
                base_url=profile.base_url,
                provider_name=name,
                model=profile.text_model,
                prompt_version="session-digest/v1",
                input_usd_per_million=profile.input_usd_per_million,
                output_usd_per_million=profile.output_usd_per_million,
                transcription_model=profile.transcription_model or "whisper-1",
                transcription_usd_per_minute=profile.transcription_usd_per_minute,
                structured_output=profile.structured_output,
            )
        if profile.adapter == "ANTHROPIC_MESSAGES":
            return AnthropicMessagesDigestProvider(
                api_key=profile.api_key or "",
                provider_name=name,
                model=profile.text_model,
                input_usd_per_million=profile.input_usd_per_million,
                output_usd_per_million=profile.output_usd_per_million,
            )
        if profile.adapter == "GEMINI_GENERATE_CONTENT":
            return GeminiGenerateContentDigestProvider(
                api_key=profile.api_key or "",
                provider_name=name,
                model=profile.text_model,
                input_usd_per_million=profile.input_usd_per_million,
                output_usd_per_million=profile.output_usd_per_million,
            )
        raise ProviderError(
            "The active provider adapter is unsupported",
            code="PROVIDER_ADAPTER_UNSUPPORTED",
            retryable=False,
        )

    def _profile_for_route(self, route: ProviderRouteSnapshotV1) -> StoredProviderProfile:
        profile = self._store.get(self._account_id, route.profile_id)
        if profile is None:
            raise ProviderError(
                "The approved provider connection was deleted",
                code="PROVIDER_ROUTE_REVOKED",
                retryable=False,
            )
        expected = (
            profile.configuration_revision_id,
            profile.display_name,
            profile.adapter,
            profile.base_url,
            profile.text_model,
            profile.transcription_model,
            tuple(sorted(profile.capabilities)),
            profile.structured_output,
        )
        try:
            reviewed_base_url = safe_provider_base_url(route.base_url, adapter=route.adapter)
        except ProviderConfigurationError as error:
            raise ProviderError(
                "The approved provider route is invalid",
                code="PROVIDER_ROUTE_INVALID",
                retryable=False,
            ) from error
        reviewed = (
            route.configuration_revision_id,
            route.display_name,
            route.adapter,
            reviewed_base_url,
            route.text_model,
            route.transcription_model,
            tuple(sorted(route.capabilities)),
            route.structured_output,
        )
        if expected != reviewed:
            raise ProviderError(
                "The approved provider connection changed after this job was queued",
                code="PROVIDER_ROUTE_CHANGED",
                retryable=False,
            )
        return profile

    def _active_profile(self) -> StoredProviderProfile | None:
        profile_id = self._store.active(self._account_id)
        if profile_id is None:
            return None
        profile = self._store.get(self._account_id, profile_id)
        if profile is None:
            raise ProviderConfigurationError("active provider profile is missing from Keychain")
        return profile

    def _artifact(
        self,
        request: ProviderConfigurationRequestV1,
        profile: StoredProviderProfile,
    ) -> ProviderConfigurationArtifactV1:
        return ProviderConfigurationArtifactV1(
            job_id=request.job_id,
            profile_id=profile.profile_id,
            configuration_revision_id=profile.configuration_revision_id,
            operation=request.operation,
            display_name=profile.display_name,
            adapter=_provider_adapter(profile.adapter),
            base_url=profile.base_url,
            text_model=profile.text_model,
            transcription_model=profile.transcription_model,
            capabilities=[_provider_capability(value) for value in profile.capabilities],
            is_active=self._store.active(self._account_id) == profile.profile_id,
            secret_stored=profile.api_key is not None,
            configured_at=datetime.now(UTC),
        )


def safe_provider_base_url(value: str | None, *, adapter: str) -> str:
    fixed_endpoints = {
        "OPENAI_RESPONSES": ("OpenAI", "https://api.openai.com/v1"),
        "ANTHROPIC_MESSAGES": ("Anthropic", "https://api.anthropic.com/v1"),
        "GEMINI_GENERATE_CONTENT": (
            "Gemini",
            "https://generativelanguage.googleapis.com/v1beta",
        ),
    }
    if adapter in fixed_endpoints:
        name, endpoint = fixed_endpoints[adapter]
        if value not in {None, "", endpoint}:
            raise ProviderConfigurationError(f"{name} uses its fixed HTTPS endpoint")
        return endpoint
    if value is None:
        raise ProviderConfigurationError("a provider server URL is required")
    parsed = urlsplit(value.strip())
    if (
        parsed.scheme not in {"http", "https"}
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
    ):
        raise ProviderConfigurationError("provider server URL is invalid")
    if parsed.scheme == "http" and not _is_local_host(parsed.hostname):
        raise ProviderConfigurationError("unencrypted HTTP is allowed only for a local provider")
    path = parsed.path.rstrip("/") or "/v1"
    return urlunsplit((parsed.scheme, parsed.netloc, path, "", ""))


def _is_local_host(host: str) -> bool:
    lowered = host.lower().rstrip(".")
    if lowered == "localhost" or lowered.endswith(".local"):
        return True
    try:
        address = ipaddress.ip_address(lowered)
    except ValueError:
        return False
    return (
        (address.is_loopback or address.is_private or address.is_link_local)
        and not address.is_unspecified
        and not address.is_multicast
        and not address.is_reserved
    )


def _provider_adapter(value: str) -> ProviderAdapter:
    if value not in {
        "OPENAI_RESPONSES",
        "OPENAI_COMPATIBLE",
        "ANTHROPIC_MESSAGES",
        "GEMINI_GENERATE_CONTENT",
    }:
        raise ProviderConfigurationError("provider profile has an unsupported adapter")
    return value  # type: ignore[return-value]


def _provider_capability(value: str) -> ProviderCapability:
    if value not in {"TEXT", "VISION", "TRANSCRIPTION", "STRUCTURED_OUTPUT"}:
        raise ProviderConfigurationError("provider profile has an unsupported capability")
    return value  # type: ignore[return-value]
