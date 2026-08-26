import base64
import io
from uuid import uuid4

from PIL import Image
from reportlab.lib.utils import ImageReader
from reportlab.pdfgen.canvas import Canvas

from epistoria_worker.models import SourceMaterialV1, SourceRectangleV1
from epistoria_worker.pdf_extract import (
    _select_text_materials,
    chunk_pages,
    extract_pdf_materials,
    extract_pdf_pages,
    render_pdf_page_png,
)


def synthetic_pdf() -> bytes:
    output = io.BytesIO()
    canvas = Canvas(output)
    canvas.drawString(72, 720, "Entropy   measures uncertainty.")
    canvas.showPage()
    canvas.showPage()
    canvas.save()
    return output.getvalue()


def synthetic_pdf_with_image() -> bytes:
    pixels = Image.new("RGB", (160, 100), color=(40, 40, 40))
    image_bytes = io.BytesIO()
    pixels.save(image_bytes, format="PNG")
    image_bytes.seek(0)
    output = io.BytesIO()
    canvas = Canvas(output)
    canvas.drawString(72, 720, "The diagram supports the explanation.")
    canvas.drawImage(ImageReader(image_bytes), 72, 500, width=320, height=200)
    canvas.save()
    return output.getvalue()


def test_extracts_text_with_page_provenance_and_marks_ocr_pages() -> None:
    pages = extract_pdf_pages(synthetic_pdf())
    assert len(pages) == 2
    assert pages[0].page_number == 1
    assert pages[0].text == "Entropy measures uncertainty."
    assert not pages[0].needs_ocr
    assert pages[1].needs_ocr
    assert sum(len(chunk) for chunk in chunk_pages(pages)) == 2


def test_renders_an_ocr_page_to_a_bounded_in_memory_png() -> None:
    value = render_pdf_page_png(synthetic_pdf(), 2)

    assert value.startswith(b"\x89PNG")
    assert len(value) <= 825_000


def test_extracts_stable_normalized_regions_for_grounded_citations() -> None:
    source_version_id = uuid4()
    first = extract_pdf_materials(synthetic_pdf(), source_version_id=source_version_id)
    second = extract_pdf_materials(synthetic_pdf(), source_version_id=source_version_id)

    text = next(item for item in first.materials if item.kind == "TEXT")
    repeated = next(item for item in second.materials if item.kind == "TEXT")
    assert text.source_id == repeated.source_id
    assert text.page_number == 1
    assert "Entropy" in text.excerpt
    rectangle = text.rectangles[0]
    assert 0 <= rectangle.x < 1
    assert 0 <= rectangle.y < 1
    assert 0 < rectangle.width <= 1
    assert 0 < rectangle.height <= 1
    assert first.page_count == 2


def test_extracts_bounded_image_region_without_persisting_a_file() -> None:
    extracted = extract_pdf_materials(synthetic_pdf_with_image(), source_version_id=uuid4())

    image = next(item for item in extracted.materials if item.kind == "IMAGE")
    assert image.page_number == 1
    assert image.image_content is not None
    assert base64.b64decode(image.image_content).startswith(b"\x89PNG")
    rectangle = image.rectangles[0]
    assert 0 < rectangle.width < 1
    assert 0 < rectangle.height < 1

    text_only = extract_pdf_materials(
        synthetic_pdf_with_image(),
        source_version_id=uuid4(),
        include_images=False,
    )
    assert text_only.materials
    assert all(item.kind == "TEXT" for item in text_only.materials)


def test_large_guide_sampling_keeps_document_start_and_end() -> None:
    materials = [
        SourceMaterialV1(
            source_id=uuid4(),
            kind="TEXT",
            page_number=index + 1,
            rectangles=[SourceRectangleV1(x=0, y=0, width=1, height=0.1)],
            excerpt=f"page-{index + 1} " + "x" * 1_780,
        )
        for index in range(200)
    ]

    selected = _select_text_materials(materials, question=None)

    assert selected[0].page_number == 1
    assert selected[-1].page_number == 200
    assert sum(len(item.excerpt) for item in selected) <= 180_000
