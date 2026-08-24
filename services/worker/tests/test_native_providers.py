from __future__ import annotations

import json
from uuid import uuid4

import httpx
import pytest

from epistoria_worker.models import (
    SessionDigestRequestV1,
    SourceExcerptV1,
    SourceGuidePromptV1,
    SourceMaterialV1,
    SourceRectangleV1,
)
from epistoria_worker.providers.base import ProviderError
from epistoria_worker.providers.native_provider import (
    AnthropicMessagesDigestProvider,
    GeminiGenerateContentDigestProvider,
)


def digest_request() -> tuple[SessionDigestRequestV1, str]:
    source_id = uuid4()
    return (
        SessionDigestRequestV1(
            account_id=uuid4(),
            job_id=uuid4(),
            session_id=uuid4(),
            session_title="Synthetic session",
            started_at="2026-08-24T12:00:00Z",
            ended_at="2026-08-24T13:00:00Z",
            sources=[
                SourceExcerptV1(
                    source_id=source_id,
                    source_kind="NOTE_BLOCK",
                    title="Synthetic note",
                    locator="block 1",
                    excerpt="A bounded claim.",
                )
            ],
            disclosure_acknowledged=True,
        ),
        str(source_id),
    )


def digest_json(source_id: str) -> dict[str, object]:
    return {
        "schemaVersion": "session-digest/v1",
        "title": "Synthetic digest",
        "summary": "A bounded summary.",
        "keyPoints": [{"text": "A bounded claim.", "sourceIds": [source_id]}],
        "possibleMisconceptions": [],
        "followUpQuestions": [],
    }


def test_anthropic_messages_uses_fixed_protocol_and_validates_structured_output() -> None:
    request, source_id = digest_request()
    captured: dict[str, object] = {}

    def handler(http_request: httpx.Request) -> httpx.Response:
        captured["request"] = http_request
        captured["body"] = json.loads(http_request.content)
        return httpx.Response(
            200,
            json={
                "id": "msg_synthetic",
                "type": "message",
                "role": "assistant",
                "content": [{"type": "text", "text": json.dumps(digest_json(source_id))}],
                "stop_reason": "end_turn",
                "usage": {"input_tokens": 100, "output_tokens": 40},
            },
        )

    provider = AnthropicMessagesDigestProvider(
        api_key="anthropic-secret",
        provider_name="profile:test",
        model="claude-test",
        input_usd_per_million=3,
        output_usd_per_million=15,
        client=httpx.Client(transport=httpx.MockTransport(handler)),
    )

    output, trace = provider.generate(request)

    sent = captured["request"]
    assert isinstance(sent, httpx.Request)
    assert sent.url == "https://api.anthropic.com/v1/messages"
    assert sent.headers["x-api-key"] == "anthropic-secret"
    assert sent.headers["anthropic-version"] == "2023-06-01"
    body = captured["body"]
    assert isinstance(body, dict)
    assert body["model"] == "claude-test"
    assert body["output_config"]["format"]["type"] == "json_schema"
    serialized = json.dumps(body)
    assert "anthropic-secret" not in serialized
    assert "const" not in serialized
    assert output.title == "Synthetic digest"
    assert trace.provider_request_id == "msg_synthetic"
    assert trace.input_tokens == 100
    assert trace.output_tokens == 40
    assert trace.estimated_cost_usd == pytest.approx(0.0009)


def test_gemini_generate_content_sends_inline_image_and_json_schema() -> None:
    source_id = uuid4()
    prompt = SourceGuidePromptV1(
        title="Synthetic source",
        output_language="English",
        materials=[
            SourceMaterialV1(
                source_id=source_id,
                kind="IMAGE",
                page_number=3,
                rectangles=[SourceRectangleV1(x=0.1, y=0.2, width=0.3, height=0.4)],
                excerpt="A synthetic chart.",
                image_content="cG5n",
            )
        ],
    )
    captured: dict[str, object] = {}
    guide = {
        "schemaVersion": "source-guide-response/v1",
        "sourceLanguage": "English",
        "outputLanguage": "English",
        "summary": [{"text": "A synthetic chart.", "sourceIds": [str(source_id)]}],
        "translatedSummary": [],
        "keyTopics": [],
        "suggestedQuestions": [],
        "imageInsights": [{"text": "The chart is present.", "sourceIds": [str(source_id)]}],
        "coverageGaps": [],
    }

    def handler(http_request: httpx.Request) -> httpx.Response:
        captured["request"] = http_request
        captured["body"] = json.loads(http_request.content)
        return httpx.Response(
            200,
            headers={"x-request-id": "gemini-synthetic"},
            json={
                "candidates": [
                    {
                        "content": {
                            "role": "model",
                            "parts": [{"text": json.dumps(guide)}],
                        },
                        "finishReason": "STOP",
                    }
                ],
                "usageMetadata": {"promptTokenCount": 80, "candidatesTokenCount": 20},
            },
        )

    provider = GeminiGenerateContentDigestProvider(
        api_key="gemini-secret",
        provider_name="profile:test",
        model="models/gemini-test",
        input_usd_per_million=1,
        output_usd_per_million=2,
        client=httpx.Client(transport=httpx.MockTransport(handler)),
    )

    output, trace = provider.generate_source_guide(prompt)

    sent = captured["request"]
    assert isinstance(sent, httpx.Request)
    assert sent.url == (
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-test:generateContent"
    )
    assert sent.headers["x-goog-api-key"] == "gemini-secret"
    body = captured["body"]
    assert isinstance(body, dict)
    generation_config = body["generationConfig"]
    assert generation_config["responseMimeType"] == "application/json"
    assert generation_config["responseJsonSchema"]["type"] == "object"
    parts = body["contents"][0]["parts"]
    assert {"inlineData": {"mimeType": "image/png", "data": "cG5n"}} in parts
    assert "gemini-secret" not in json.dumps(body)
    assert output.image_insights[0].source_ids == [source_id]
    assert trace.provider_request_id == "gemini-synthetic"
    assert trace.estimated_cost_usd == pytest.approx(0.00012)


@pytest.mark.parametrize(
    ("status", "code", "retryable"),
    [
        (401, "PROVIDER_REQUEST_FAILED", False),
        (429, "PROVIDER_RATE_LIMIT", True),
        (503, "PROVIDER_REQUEST_FAILED", True),
    ],
)
def test_native_provider_status_errors_do_not_expose_response_body(
    status: int, code: str, retryable: bool
) -> None:
    request, _ = digest_request()

    def handler(http_request: httpx.Request) -> httpx.Response:
        return httpx.Response(status, json={"error": "private-provider-detail"})

    provider = AnthropicMessagesDigestProvider(
        api_key="anthropic-secret",
        provider_name="profile:test",
        model="claude-test",
        input_usd_per_million=None,
        output_usd_per_million=None,
        client=httpx.Client(transport=httpx.MockTransport(handler)),
    )

    with pytest.raises(ProviderError) as failure:
        provider.generate(request)

    assert failure.value.code == code
    assert failure.value.retryable is retryable
    assert "private-provider-detail" not in str(failure.value)


def test_native_provider_rejects_schema_invalid_success() -> None:
    request, _ = digest_request()

    def handler(http_request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            json={
                "id": "msg_synthetic",
                "content": [{"type": "text", "text": '{"title":"incomplete"}'}],
                "stop_reason": "end_turn",
                "usage": {"input_tokens": 1, "output_tokens": 1},
            },
        )

    provider = AnthropicMessagesDigestProvider(
        api_key="anthropic-secret",
        provider_name="profile:test",
        model="claude-test",
        input_usd_per_million=None,
        output_usd_per_million=None,
        client=httpx.Client(transport=httpx.MockTransport(handler)),
    )

    with pytest.raises(ProviderError) as failure:
        provider.generate(request)

    assert failure.value.code == "PROVIDER_SCHEMA_INVALID"


def test_native_provider_does_not_claim_timestamped_transcription() -> None:
    provider = GeminiGenerateContentDigestProvider(
        api_key="gemini-secret",
        provider_name="profile:test",
        model="gemini-test",
        input_usd_per_million=None,
        output_usd_per_million=None,
    )

    with pytest.raises(ProviderError) as failure:
        provider.transcribe_media(
            filename="lecture.mp3",
            mime_type="audio/mpeg",
            media=b"not-sent",
            language=None,
        )

    assert failure.value.code == "PROVIDER_CAPABILITY_UNAVAILABLE"
