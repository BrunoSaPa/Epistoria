from uuid import uuid4

from epistoria_worker.models import (
    SourceGuidePromptV1,
    SourceMaterialV1,
    SourceRectangleV1,
)
from epistoria_worker.providers.openai_provider import _build_source_input


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
