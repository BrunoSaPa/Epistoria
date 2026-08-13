import io

from reportlab.pdfgen.canvas import Canvas

from epistoria_worker.pdf_extract import chunk_pages, extract_pdf_pages


def synthetic_pdf() -> bytes:
    output = io.BytesIO()
    canvas = Canvas(output)
    canvas.drawString(72, 720, "Entropy   measures uncertainty.")
    canvas.showPage()
    canvas.showPage()
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
