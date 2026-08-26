from __future__ import annotations

import base64
import binascii
from typing import Any, TypeVar
from urllib.parse import quote

import httpx
from pydantic import BaseModel, ValidationError

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
    TutorTurnRequestV1,
    TutorTurnResponseV1,
)
from .base import ProviderError
from .openai_provider import (
    _DIGEST_SYSTEM_PROMPT,
    _FEEDBACK_SYSTEM_PROMPT,
    _LEARNING_SYSTEM_PROMPT,
    _MAX_IMAGE_BYTES,
    _NOTE_QUERY_SYSTEM_PROMPT,
    _SOURCE_GUIDE_SYSTEM_PROMPT,
    _SOURCE_QUERY_SYSTEM_PROMPT,
    _TUTOR_SYSTEM_PROMPT,
    _provider_request_json,
)

_StructuredResponse = TypeVar("_StructuredResponse", bound=BaseModel)
_ContentPart = dict[str, Any]


def _optional_token_count(value: Any) -> int | None:
    return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else None


def _optional_request_id(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    normalized = value.strip()
    return normalized if 0 < len(normalized) <= 200 else None


def _provider_json_schema(response_type: type[BaseModel]) -> dict[str, Any]:
    """Return the portable JSON Schema subset accepted by both native providers."""

    unsupported = {
        "default",
        "examples",
        "exclusiveMaximum",
        "exclusiveMinimum",
        "maxLength",
        "minLength",
        "multipleOf",
        "pattern",
    }

    def normalize(value: Any) -> Any:
        if isinstance(value, list):
            return [normalize(item) for item in value]
        if not isinstance(value, dict):
            return value
        result: dict[str, Any] = {}
        for key, item in value.items():
            if key in unsupported:
                continue
            if key == "const":
                result["enum"] = [normalize(item)]
            else:
                result[key] = normalize(item)
        properties = result.get("properties")
        if isinstance(properties, dict):
            result["required"] = list(properties)
            result["additionalProperties"] = False
        return result

    schema = normalize(response_type.model_json_schema(by_alias=True))
    if not isinstance(schema, dict):  # pragma: no cover - Pydantic always returns an object.
        raise TypeError("provider response schema must be an object")
    return schema


def _image_part(image_content: str, *, label: str) -> _ContentPart:
    try:
        raw = base64.b64decode(image_content, validate=True)
    except (ValueError, binascii.Error) as error:
        raise ProviderError(
            f"{label} is not valid base64",
            code="PROVIDER_IMAGE_INVALID",
            retryable=False,
        ) from error
    if len(raw) > _MAX_IMAGE_BYTES:
        raise ProviderError(
            f"{label} exceeds 2 MiB limit",
            code="PROVIDER_IMAGE_TOO_LARGE",
            retryable=False,
        )
    return {"type": "image", "mime_type": "image/png", "data": image_content}


def _note_query_content(request: NoteQueryRequestV1) -> list[_ContentPart]:
    content: list[_ContentPart] = [
        {"type": "text", "text": f"Question: {request.question}\n\n=== SELECTED SOURCES ===\n"}
    ]
    for source in request.selection_sources:
        content.append(
            {
                "type": "text",
                "text": (
                    f"[sourceId={source.source_id} kind={source.source_kind} "
                    f"locator={source.locator!r}]\n"
                ),
            }
        )
        if source.image_content is not None:
            content.append(_image_part(source.image_content, label="Image source"))
        elif source.excerpt is not None:
            content.append({"type": "text", "text": source.excerpt + "\n"})
    if request.context_sources:
        content.append(
            {"type": "text", "text": "\n=== CONTEXT SOURCES (background only) ===\n"}
        )
        for source in request.context_sources:
            if source.excerpt:
                content.append(
                    {
                        "type": "text",
                        "text": (
                            f"[sourceId={source.source_id} locator={source.locator!r}]\n"
                            f"{source.excerpt}\n"
                        ),
                    }
                )
    return content


def _source_content(
    request: SourceGuidePromptV1 | SourceQueryPromptV1,
) -> list[_ContentPart]:
    heading = (
        f"Question: {request.question}\n\n" if isinstance(request, SourceQueryPromptV1) else ""
    )
    content: list[_ContentPart] = [
        {
            "type": "text",
            "text": (
                f"{heading}Title: {request.title}\nRequested output language: "
                f"{request.output_language}\n\n=== SOURCE MATERIAL ===\n"
            ),
        }
    ]
    for item in request.materials:
        content.append(
            {
                "type": "text",
                "text": (
                    f"[sourceId={item.source_id} kind={item.kind} page={item.page_number} "
                    f"rectangles={item.rectangles!r}]\n{item.excerpt}\n"
                ),
            }
        )
        if item.image_content is not None:
            content.append(_image_part(item.image_content, label="PDF image"))
    return content


class _NativeStructuredDigestProvider:
    def __init__(
        self,
        *,
        api_key: str,
        provider_name: str,
        model: str,
        input_usd_per_million: float | None,
        output_usd_per_million: float | None,
        client: httpx.Client | None,
    ) -> None:
        self._api_key = api_key
        self._provider_name = provider_name
        self._model = model
        self._input_rate = input_usd_per_million
        self._output_rate = output_usd_per_million
        self._client = client or httpx.Client(timeout=90)

    def generate(self, request: SessionDigestRequestV1) -> tuple[SessionDigestV1, ProviderTraceV1]:
        return self._generate(
            response_type=SessionDigestV1,
            system_prompt=_DIGEST_SYSTEM_PROMPT,
            user_content=[{"type": "text", "text": _provider_request_json(request)}],
            prompt_version="session-digest/v1",
        )

    def generate_learning(
        self, request: LearningGenerationRequestV1
    ) -> tuple[LearningGenerationResponseV1, ProviderTraceV1]:
        return self._generate(
            response_type=LearningGenerationResponseV1,
            system_prompt=_LEARNING_SYSTEM_PROMPT,
            user_content=[
                {
                    "type": "text",
                    "text": _provider_request_json(
                        request, exclude={"automation_authorization"}
                    ),
                }
            ],
            prompt_version="learning-generation/v1",
        )

    def generate_tutor_turn(
        self, request: TutorTurnRequestV1
    ) -> tuple[TutorTurnResponseV1, ProviderTraceV1]:
        return self._generate(
            response_type=TutorTurnResponseV1,
            system_prompt=_TUTOR_SYSTEM_PROMPT,
            user_content=[{"type": "text", "text": _provider_request_json(request)}],
            prompt_version="adaptive-tutor/v1",
        )

    def generate_note_query(
        self, request: NoteQueryRequestV1
    ) -> tuple[NoteQueryResponseV1, ProviderTraceV1]:
        return self._generate(
            response_type=NoteQueryResponseV1,
            system_prompt=_NOTE_QUERY_SYSTEM_PROMPT,
            user_content=_note_query_content(request),
            prompt_version="note-query/v1",
        )

    def generate_free_response_feedback(
        self, request: FreeResponseFeedbackRequestV1
    ) -> tuple[FreeResponseFeedbackResponseV1, ProviderTraceV1]:
        return self._generate(
            response_type=FreeResponseFeedbackResponseV1,
            system_prompt=_FEEDBACK_SYSTEM_PROMPT,
            user_content=[{"type": "text", "text": _provider_request_json(request)}],
            prompt_version="free-response-feedback/v1",
        )

    def generate_source_guide(
        self, request: SourceGuidePromptV1
    ) -> tuple[SourceGuideResponseV1, ProviderTraceV1]:
        return self._generate(
            response_type=SourceGuideResponseV1,
            system_prompt=_SOURCE_GUIDE_SYSTEM_PROMPT,
            user_content=_source_content(request),
            prompt_version="source-guide/v1",
        )

    def generate_source_query(
        self, request: SourceQueryPromptV1
    ) -> tuple[SourceQueryResponseV1, ProviderTraceV1]:
        return self._generate(
            response_type=SourceQueryResponseV1,
            system_prompt=_SOURCE_QUERY_SYSTEM_PROMPT,
            user_content=_source_content(request),
            prompt_version="source-query/v1",
        )

    def transcribe_media(
        self,
        *,
        filename: str,
        mime_type: str,
        media: bytes,
        language: str | None,
        provider_route: ProviderRouteSnapshotV1 | None = None,
    ) -> tuple[MediaTranscriptionResponseV1, ProviderTraceV1]:
        raise ProviderError(
            "This native provider adapter does not support timestamped transcription",
            code="PROVIDER_CAPABILITY_UNAVAILABLE",
            retryable=False,
        )

    def _generate(
        self,
        *,
        response_type: type[_StructuredResponse],
        system_prompt: str,
        user_content: list[_ContentPart],
        prompt_version: str,
    ) -> tuple[_StructuredResponse, ProviderTraceV1]:
        response_json, request_id, input_tokens, output_tokens = self._request_json(
            system_prompt=system_prompt,
            user_content=user_content,
            schema=_provider_json_schema(response_type),
        )
        try:
            output = response_type.model_validate_json(response_json)
        except ValidationError as error:
            raise ProviderError(
                "Provider returned an invalid structured response",
                code="PROVIDER_SCHEMA_INVALID",
                retryable=True,
            ) from error
        estimated_cost: float | None = None
        if (
            input_tokens is not None
            and output_tokens is not None
            and self._input_rate is not None
            and self._output_rate is not None
        ):
            estimated_cost = (
                input_tokens * self._input_rate + output_tokens * self._output_rate
            ) / 1_000_000
        return output, ProviderTraceV1(
            provider=self._provider_name,
            model=self._model,
            prompt_version=prompt_version,
            input_tokens=input_tokens,
            output_tokens=output_tokens,
            estimated_cost_usd=estimated_cost,
            provider_request_id=request_id,
        )

    def _request_json(
        self,
        *,
        system_prompt: str,
        user_content: list[_ContentPart],
        schema: dict[str, Any],
    ) -> tuple[str, str | None, int | None, int | None]:
        raise NotImplementedError

    def _post(
        self, url: str, *, headers: dict[str, str], payload: dict[str, Any]
    ) -> httpx.Response:
        try:
            response = self._client.post(url, headers=headers, json=payload)
            response.raise_for_status()
            return response
        except httpx.RequestError as error:
            raise ProviderError(
                "Provider is unreachable", code="PROVIDER_UNAVAILABLE", retryable=True
            ) from error
        except httpx.HTTPStatusError as error:
            status = error.response.status_code
            if status == 429:
                raise ProviderError(
                    "Provider rate limit reached", code="PROVIDER_RATE_LIMIT", retryable=True
                ) from error
            raise ProviderError(
                "Provider rejected the request",
                code="PROVIDER_REQUEST_FAILED",
                retryable=status in {408, 425} or status >= 500,
            ) from error


class AnthropicMessagesDigestProvider(_NativeStructuredDigestProvider):
    def __init__(
        self,
        *,
        api_key: str,
        provider_name: str,
        model: str,
        input_usd_per_million: float | None,
        output_usd_per_million: float | None,
        client: httpx.Client | None = None,
    ) -> None:
        super().__init__(
            api_key=api_key,
            provider_name=provider_name,
            model=model,
            input_usd_per_million=input_usd_per_million,
            output_usd_per_million=output_usd_per_million,
            client=client,
        )

    def _request_json(
        self,
        *,
        system_prompt: str,
        user_content: list[_ContentPart],
        schema: dict[str, Any],
    ) -> tuple[str, str | None, int | None, int | None]:
        content: list[dict[str, Any]] = []
        for part in user_content:
            if part["type"] == "image":
                content.append(
                    {
                        "type": "image",
                        "source": {
                            "type": "base64",
                            "media_type": part["mime_type"],
                            "data": part["data"],
                        },
                    }
                )
            else:
                content.append({"type": "text", "text": part["text"]})
        response = self._post(
            "https://api.anthropic.com/v1/messages",
            headers={
                "content-type": "application/json",
                "anthropic-version": "2023-06-01",
                "x-api-key": self._api_key,
            },
            payload={
                "model": self._model,
                "max_tokens": 16_384,
                "system": system_prompt,
                "messages": [{"role": "user", "content": content}],
                "output_config": {"format": {"type": "json_schema", "schema": schema}},
            },
        )
        try:
            body = response.json()
            if not isinstance(body, dict):
                raise ValueError("response body is not an object")
            if body.get("stop_reason") in {"refusal", "max_tokens"}:
                raise ValueError("response did not complete")
            text_blocks = [
                block.get("text", "")
                for block in body["content"]
                if block.get("type") == "text"
            ]
            response_json = "".join(text_blocks).strip()
            usage = body.get("usage", {})
            if not isinstance(usage, dict):
                usage = {}
            input_tokens = _optional_token_count(usage.get("input_tokens"))
            output_tokens = _optional_token_count(usage.get("output_tokens"))
            request_id = _optional_request_id(
                body.get("id") or response.headers.get("request-id")
            )
            if not response_json:
                raise ValueError("empty response")
            return response_json, request_id, input_tokens, output_tokens
        except (KeyError, TypeError, ValueError) as error:
            raise ProviderError(
                "Anthropic returned an invalid response envelope",
                code="PROVIDER_SCHEMA_INVALID",
                retryable=True,
            ) from error


class GeminiGenerateContentDigestProvider(_NativeStructuredDigestProvider):
    def __init__(
        self,
        *,
        api_key: str,
        provider_name: str,
        model: str,
        input_usd_per_million: float | None,
        output_usd_per_million: float | None,
        client: httpx.Client | None = None,
    ) -> None:
        super().__init__(
            api_key=api_key,
            provider_name=provider_name,
            model=model,
            input_usd_per_million=input_usd_per_million,
            output_usd_per_million=output_usd_per_million,
            client=client,
        )

    def _request_json(
        self,
        *,
        system_prompt: str,
        user_content: list[_ContentPart],
        schema: dict[str, Any],
    ) -> tuple[str, str | None, int | None, int | None]:
        parts: list[dict[str, Any]] = []
        for part in user_content:
            if part["type"] == "image":
                parts.append(
                    {
                        "inlineData": {
                            "mimeType": part["mime_type"],
                            "data": part["data"],
                        }
                    }
                )
            else:
                parts.append({"text": part["text"]})
        model = self._model.removeprefix("models/")
        response = self._post(
            "https://generativelanguage.googleapis.com/v1beta/models/"
            f"{quote(model, safe='')}:generateContent",
            headers={"content-type": "application/json", "x-goog-api-key": self._api_key},
            payload={
                "systemInstruction": {"parts": [{"text": system_prompt}]},
                "contents": [{"role": "user", "parts": parts}],
                "generationConfig": {
                    "temperature": 0,
                    "responseMimeType": "application/json",
                    "responseJsonSchema": schema,
                },
            },
        )
        try:
            body = response.json()
            if not isinstance(body, dict):
                raise ValueError("response body is not an object")
            candidate = body["candidates"][0]
            text_parts = [part.get("text", "") for part in candidate["content"]["parts"]]
            response_json = "".join(text_parts).strip()
            usage = body.get("usageMetadata", {})
            if not isinstance(usage, dict):
                usage = {}
            input_tokens = _optional_token_count(usage.get("promptTokenCount"))
            output_tokens = _optional_token_count(usage.get("candidatesTokenCount"))
            request_id = _optional_request_id(
                body.get("responseId") or response.headers.get("x-request-id")
            )
            if not response_json:
                raise ValueError("empty response")
            return response_json, request_id, input_tokens, output_tokens
        except (IndexError, KeyError, TypeError, ValueError) as error:
            raise ProviderError(
                "Gemini returned an invalid response envelope",
                code="PROVIDER_SCHEMA_INVALID",
                retryable=True,
            ) from error
