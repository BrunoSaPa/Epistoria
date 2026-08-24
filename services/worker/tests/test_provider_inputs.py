from uuid import uuid4

from epistoria_worker.models import (
    ProviderRouteSnapshotV1,
    SessionDigestRequestV1,
    SourceExcerptV1,
    SourceGuidePromptV1,
    SourceMaterialV1,
    SourceRectangleV1,
)
from epistoria_worker.providers.openai_provider import _build_source_input, _provider_request_json


def test_responses_source_images_use_data_url_input_contract() -> None:
    prompt = SourceGuidePromptV1(
        title="Synthetic source",
        output_language="English",
        materials=[
            SourceMaterialV1(
                source_id=uuid4(),
                kind="IMAGE",
                page_number=2,
                rectangles=[SourceRectangleV1(x=0.1, y=0.2, width=0.3, height=0.4)],
                excerpt="Synthetic image region",
                image_content="cG5n",
            )
        ],
    )

    content = _build_source_input(prompt)[0]["content"]
    assert isinstance(content, list)
    image = next(part for part in content if part.get("type") == "input_image")
    assert image == {"type": "input_image", "image_url": "data:image/png;base64,cG5n"}


def test_provider_route_is_used_for_routing_but_not_sent_in_prompt_content() -> None:
    request = SessionDigestRequestV1(
        account_id=uuid4(),
        job_id=uuid4(),
        session_id=uuid4(),
        session_title="Synthetic session",
        started_at="2026-08-24T12:00:00Z",
        ended_at="2026-08-24T13:00:00Z",
        sources=[
            SourceExcerptV1(
                source_id=uuid4(),
                source_kind="NOTE_BLOCK",
                title="Synthetic note",
                locator="block 1",
                excerpt="Bounded synthetic content",
            )
        ],
        disclosure_acknowledged=True,
        provider_route=ProviderRouteSnapshotV1(
            profile_id=uuid4(),
            configuration_revision_id=uuid4(),
            display_name="Private route name",
            adapter="OPENAI_COMPATIBLE",
            base_url="http://127.0.0.1:11434/v1",
            text_model="private-route-model",
            capabilities=["TEXT"],
            structured_output=True,
        ),
    )

    provider_input = _provider_request_json(request)

    assert "providerRoute" not in provider_input
    assert "Private route name" not in provider_input
    assert "private-route-model" not in provider_input
