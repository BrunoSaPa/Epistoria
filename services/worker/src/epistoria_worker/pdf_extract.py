from __future__ import annotations

import base64
import io
import logging
import re
import unicodedata
from collections.abc import Iterable
from dataclasses import dataclass
from typing import Any
from uuid import UUID, uuid5

import pdfplumber
from pypdf import PdfReader

from .models import PDFPageV1, SourceMaterialV1, SourceRectangleV1

_INLINE_SPACE = re.compile(r"[\t\f\v ]+")
_EXCESS_BLANKS = re.compile(r"\n{3,}")
_QUERY_TOKEN = re.compile(r"[\wÀ-ÖØ-öø-ÿ]{3,}", re.UNICODE)
_MAX_PROVIDER_TEXT_CHARACTERS = 180_000
_MAX_PROVIDER_MATERIALS = 220
_MAX_PROVIDER_IMAGES = 8
LOGGER = logging.getLogger("epistoria.worker.pdf")


class PDFExtractionError(ValueError):
    """Raised when a PDF cannot be safely parsed or chunked."""


@dataclass(frozen=True)
class ExtractedSourceMaterial:
    materials: list[SourceMaterialV1]
    page_count: int
    analyzed_page_count: int
    coverage_gaps: list[str]


def normalize_extracted_text(value: str) -> str:
    value = unicodedata.normalize("NFKC", value).replace("\x00", "")
    lines = [_INLINE_SPACE.sub(" ", line).strip() for line in value.splitlines()]
    return _EXCESS_BLANKS.sub("\n\n", "\n".join(lines)).strip()


def extract_pdf_pages(pdf_bytes: bytes) -> list[PDFPageV1]:
    try:
        reader = PdfReader(io.BytesIO(pdf_bytes), strict=False)
    except Exception as error:
        raise PDFExtractionError("PDF parser rejected the document") from error
    if reader.is_encrypted:
        try:
            unlocked = reader.decrypt("")
        except Exception as error:
            raise PDFExtractionError("password-protected PDFs are not supported in v0.1") from error
        if not unlocked:
            raise PDFExtractionError("password-protected PDFs are not supported in v0.1")
    if not reader.pages:
        raise PDFExtractionError("PDF contains no pages")

    pages: list[PDFPageV1] = []
    for index, page in enumerate(reader.pages, start=1):
        try:
            text = normalize_extracted_text(page.extract_text() or "")
        except Exception as error:
            raise PDFExtractionError(f"failed to extract PDF page {index}") from error
        pages.append(
            PDFPageV1(
                page_number=index,
                text=text,
                character_count=len(text),
                needs_ocr=not bool(text),
            )
        )
    return pages


def chunk_pages(
    pages: Iterable[PDFPageV1], *, max_utf8_bytes: int = 1_250_000
) -> list[list[PDFPageV1]]:
    if max_utf8_bytes < 1_024:
        raise ValueError("max_utf8_bytes is unreasonably small")
    result: list[list[PDFPageV1]] = []
    current: list[PDFPageV1] = []
    current_size = 0
    for page in pages:
        page_size = len(page.text.encode("utf-8")) + 512
        if page_size > max_utf8_bytes:
            raise PDFExtractionError(
                f"page {page.page_number} exceeds the encrypted entity limit after extraction"
            )
        if current and current_size + page_size > max_utf8_bytes:
            result.append(current)
            current = []
            current_size = 0
        current.append(page)
        current_size += page_size
    if current:
        result.append(current)
    if not result:
        raise PDFExtractionError("PDF produced no extractable page records")
    if len(result) > 64:
        raise PDFExtractionError("PDF extraction requires more than 64 encrypted chunks")
    return result


def extract_pdf_materials(
    pdf_bytes: bytes,
    *,
    source_version_id: UUID,
    question: str | None = None,
    include_images: bool = True,
) -> ExtractedSourceMaterial:
    """Create bounded provider inputs with stable, exact PDF page locators.

    Text rectangles use normalized coordinates with a top-left origin. Embedded figures are
    rendered only in memory and are never written to disk. The returned selection is bounded so a
    large PDF cannot silently exceed the encrypted job or provider context limits.
    """

    try:
        document = pdfplumber.open(io.BytesIO(pdf_bytes), password="")
    except Exception as error:
        raise PDFExtractionError("PDF geometry parser rejected the document") from error
    try:
        if not document.pages:
            raise PDFExtractionError("PDF contains no pages")
        text_materials: list[SourceMaterialV1] = []
        image_candidates: list[tuple[float, int, int, Any, tuple[float, float, float, float]]] = []
        for page_number, page in enumerate(document.pages, start=1):
            try:
                words = page.extract_words(use_text_flow=True, keep_blank_chars=False)
            except Exception as error:
                raise PDFExtractionError(
                    f"failed to extract positioned text from PDF page {page_number}"
                ) from error
            text_materials.extend(
                _word_materials(
                    words,
                    page_number=page_number,
                    page_width=float(page.width),
                    page_height=float(page.height),
                    source_version_id=source_version_id,
                )
            )
            if include_images:
                image_candidates.extend(_image_candidates(page, page_number))
            if include_images and not words and not page.images:
                image_candidates.append(
                    (1.0, page_number, 0, page, (0.0, 0.0, float(page.width), float(page.height)))
                )

        selected_text = _select_text_materials(text_materials, question=question)
        preferred_pages = {item.page_number for item in selected_text}
        selected_images = (
            _render_selected_images(
                image_candidates,
                source_version_id=source_version_id,
                preferred_pages=preferred_pages if question else set(),
            )
            if include_images
            else []
        )
        materials = [*selected_text, *selected_images][:_MAX_PROVIDER_MATERIALS]
        analyzed_pages = {item.page_number for item in materials}
        gaps: list[str] = []
        if len(selected_text) < len(text_materials):
            gaps.append(
                "The source exceeded the current analysis context. Epistoria selected cited "
                "passages across the document and did not analyze every extracted passage."
            )
        omitted_pages = len(document.pages) - len(analyzed_pages)
        if omitted_pages > 0:
            gaps.append(f"{omitted_pages} PDF pages were outside this analysis pass.")
        return ExtractedSourceMaterial(
            materials=materials,
            page_count=len(document.pages),
            analyzed_page_count=len(analyzed_pages),
            coverage_gaps=gaps,
        )
    finally:
        document.close()


def _word_materials(
    words: list[dict[str, Any]],
    *,
    page_number: int,
    page_width: float,
    page_height: float,
    source_version_id: UUID,
) -> list[SourceMaterialV1]:
    if page_width <= 0 or page_height <= 0:
        return []
    result: list[SourceMaterialV1] = []
    current: list[dict[str, Any]] = []
    current_characters = 0
    for word in words:
        text = normalize_extracted_text(str(word.get("text", "")))
        if not text:
            continue
        if current and (len(current) >= 90 or current_characters + len(text) + 1 > 1_800):
            result.append(
                _text_material(
                    current,
                    page_number=page_number,
                    segment_index=len(result),
                    page_width=page_width,
                    page_height=page_height,
                    source_version_id=source_version_id,
                )
            )
            current = []
            current_characters = 0
        current.append({**word, "text": text})
        current_characters += len(text) + 1
    if current:
        result.append(
            _text_material(
                current,
                page_number=page_number,
                segment_index=len(result),
                page_width=page_width,
                page_height=page_height,
                source_version_id=source_version_id,
            )
        )
    return result


def _text_material(
    words: list[dict[str, Any]],
    *,
    page_number: int,
    segment_index: int,
    page_width: float,
    page_height: float,
    source_version_id: UUID,
) -> SourceMaterialV1:
    x0 = min(float(word["x0"]) for word in words)
    top = min(float(word["top"]) for word in words)
    x1 = max(float(word["x1"]) for word in words)
    bottom = max(float(word["bottom"]) for word in words)
    return SourceMaterialV1(
        source_id=uuid5(source_version_id, f"pdf:text:{page_number}:{segment_index}"),
        kind="TEXT",
        page_number=page_number,
        rectangles=[_normalized_rectangle(x0, top, x1, bottom, page_width, page_height)],
        excerpt=" ".join(str(word["text"]) for word in words),
    )


def _image_candidates(
    page: Any, page_number: int
) -> list[tuple[float, int, int, Any, tuple[float, float, float, float]]]:
    result: list[tuple[float, int, int, Any, tuple[float, float, float, float]]] = []
    page_area = max(float(page.width) * float(page.height), 1)
    seen: set[tuple[int, int, int, int]] = set()
    for index, image in enumerate(page.images):
        bbox = (
            max(float(image["x0"]), 0),
            max(float(image["top"]), 0),
            min(float(image["x1"]), float(page.width)),
            min(float(image["bottom"]), float(page.height)),
        )
        width = bbox[2] - bbox[0]
        height = bbox[3] - bbox[1]
        area_fraction = width * height / page_area
        signature = (
            round(bbox[0]),
            round(bbox[1]),
            round(bbox[2]),
            round(bbox[3]),
        )
        if width < 36 or height < 36 or area_fraction < 0.015 or signature in seen:
            continue
        seen.add(signature)
        result.append((area_fraction, page_number, index, page, bbox))
    return result


def _render_selected_images(
    candidates: list[tuple[float, int, int, Any, tuple[float, float, float, float]]],
    *,
    source_version_id: UUID,
    preferred_pages: set[int],
) -> list[SourceMaterialV1]:
    ranked = sorted(
        candidates,
        key=lambda item: (item[1] in preferred_pages, item[0], -item[1]),
        reverse=True,
    )
    result: list[SourceMaterialV1] = []
    for _, page_number, image_index, page, bbox in ranked:
        if len(result) >= _MAX_PROVIDER_IMAGES:
            break
        try:
            rendered = page.crop(bbox).to_image(width=768, antialias=True).original
            encoded = _png_base64(rendered)
        except Exception:
            LOGGER.debug("skipped unrenderable PDF image page=%d", page_number)
            continue
        if encoded is None:
            continue
        result.append(
            SourceMaterialV1(
                source_id=uuid5(
                    source_version_id, f"pdf:image:{page_number}:{image_index}:{bbox!r}"
                ),
                kind="IMAGE",
                page_number=page_number,
                rectangles=[
                    _normalized_rectangle(
                        bbox[0], bbox[1], bbox[2], bbox[3], float(page.width), float(page.height)
                    )
                ],
                excerpt=f"Image region on PDF page {page_number}",
                image_content=encoded,
            )
        )
    return result


def _png_base64(image: Any) -> str | None:
    working = image.convert("RGB")
    for maximum in (768, 640, 512, 384):
        if max(working.size) > maximum:
            resized = working.copy()
            resized.thumbnail((maximum, maximum))
        else:
            resized = working
        output = io.BytesIO()
        resized.save(output, format="PNG", optimize=True)
        raw = output.getvalue()
        if len(raw) <= 1_800_000:
            return base64.b64encode(raw).decode("ascii")
    return None


def _normalized_rectangle(
    x0: float, top: float, x1: float, bottom: float, width: float, height: float
) -> SourceRectangleV1:
    left = min(max(x0 / width, 0), 1)
    upper = min(max(top / height, 0), 1)
    right = min(max(x1 / width, left + 0.000_001), 1)
    lower = min(max(bottom / height, upper + 0.000_001), 1)
    return SourceRectangleV1(x=left, y=upper, width=right - left, height=lower - upper)


def _select_text_materials(
    materials: list[SourceMaterialV1], *, question: str | None
) -> list[SourceMaterialV1]:
    if not materials:
        return []
    if question:
        terms = {token.casefold() for token in _QUERY_TOKEN.findall(question)}
        scored = sorted(
            enumerate(materials),
            key=lambda pair: (
                len(
                    terms.intersection(
                        token.casefold() for token in _QUERY_TOKEN.findall(pair[1].excerpt)
                    )
                ),
                -pair[0],
            ),
            reverse=True,
        )
        selected_indexes = sorted(index for index, _ in scored[:60])
        selected = [materials[index] for index in selected_indexes]
    else:
        selected = materials
    if sum(len(item.excerpt) for item in selected) <= _MAX_PROVIDER_TEXT_CHARACTERS:
        return selected[: _MAX_PROVIDER_MATERIALS - _MAX_PROVIDER_IMAGES]
    budget_count = max(1, _MAX_PROVIDER_MATERIALS - _MAX_PROVIDER_IMAGES)
    longest = max(len(item.excerpt) for item in selected)
    sample_count = min(
        len(selected),
        budget_count,
        max(_MAX_PROVIDER_TEXT_CHARACTERS // max(longest, 1), 1),
    )
    if sample_count == 1:
        return [selected[0]]
    indexes = [
        round(index * (len(selected) - 1) / (sample_count - 1))
        for index in range(sample_count)
    ]
    return [selected[index] for index in indexes]
