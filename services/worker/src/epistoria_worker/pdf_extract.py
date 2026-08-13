from __future__ import annotations

import io
import re
import unicodedata
from collections.abc import Iterable

from pypdf import PdfReader

from .models import PDFPageV1

_INLINE_SPACE = re.compile(r"[\t\f\v ]+")
_EXCESS_BLANKS = re.compile(r"\n{3,}")


class PDFExtractionError(ValueError):
    """Raised when a PDF cannot be safely parsed or chunked."""


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
