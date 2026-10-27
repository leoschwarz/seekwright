"""The default fetch extraction backend: trafilatura for HTML, pypdf for PDF.

Libraries are imported at module import time, deliberately: only
``factory.build_extractor`` imports this module, and only when
``fetch.extractor`` names it, so a missing extra is named rather than surfacing
as an ``ImportError`` mid-request.

Two libraries, chosen against measured alternatives:

* **trafilatura** for HTML. Against a 264k-character Wikipedia article it was
  the only candidate that left *no* navigation chrome; a hand-rolled
  ``html.parser`` extractor and resiliparse both leaked site furniture.
  ``favor_precision`` is set because it skips the fallback algorithms and was
  ~8x faster (65ms vs 550ms).
* **pypdf** for PDF. PyMuPDF extracts comparably but is AGPL-3.0, a licence this
  project cannot push onto its installers; pymupdf4llm also pulls in onnxruntime
  and took six seconds on a fifteen-page paper.

pypdf is the one library here that walks a structure a stranger wrote, so it is
contained three ways: it rides in this backend's extra; its import is guarded
rather than fatal; and nothing it raises escapes :func:`_from_pdf`, where
:class:`ExtractionFailed` is the boundary the fetcher turns into a non-retryable
refusal.
"""

from __future__ import annotations

import io
from collections.abc import Callable
from typing import IO, Any

import trafilatura
from trafilatura.metadata import extract_metadata

from ..jsondoc import is_json_media, sniffs_json
from .base import (
    HTML_TYPES,
    PDF_TYPES,
    SUPPORTED_TYPES,
    TEXT_TYPES,
    ExtractionFailed,
    ExtractResult,
    decode,
    json_extraction,
    media_type,
    normalise,
    sniffs_html,
)


def _load_pdf_library() -> tuple[Callable[[IO[bytes]], Any] | None, str | None]:
    """The PDF parser this install carries, and why it may carry none.

    Called at import time, so `pypdf` is imported by the one backend that reads
    PDFs and never by ``import seekwright`` -- the rule ``base.py`` states. It
    never raises: a missing `pypdf` reaching ``factory.build_extractor`` as an
    ``ExtractorUnavailable`` would turn a PDF-only gap into no extraction at all.
    The second half is the import error in its own words, quoted into the refusal
    so a model reads "this install has no PDF parser" rather than a parse
    failure nobody caused.
    """
    try:
        import pypdf
    except ImportError as exc:
        return None, str(exc)
    return pypdf.PdfReader, None


PdfReader, PDF_IMPORT_ERROR = _load_pdf_library()
"""The parser, and the reason for its absence.

:attr:`TrafilaturaExtractor.supported_types` drops PDF when the first is
``None``: ``base.py`` says a backend's type set has to be honest, and an honest
set makes the fetcher refuse a PDF *before* downloading a body this install
cannot read. ``seekwright --check`` says the same thing on its `fetch` line,
because an install that quietly lost PDF reading is the surprise that command
exists to surface.
"""


class TrafilaturaExtractor:
    """HTML through trafilatura, PDF through pypdf, JSON as structure, plain text passed through."""

    name = "trafilatura"
    # Honest by construction: PDF drops out exactly when the guarded import failed,
    # so the fetcher's media-type gate refuses a PDF it cannot read.
    supported_types = (
        SUPPORTED_TYPES if PdfReader is not None else HTML_TYPES | TEXT_TYPES
    )

    def extract(self, body: bytes, content_type: str | None) -> ExtractResult:
        """Extract readable text from a fetched body, uncut.

        The media type decides the engine; a missing one is sniffed as HTML or
        JSON only when the bytes look like it, so an unknown binary is refused
        rather than fed to trafilatura to produce nothing.
        """
        kind = media_type(content_type)

        if is_json_media(kind) or (not kind and sniffs_json(body)):
            return json_extraction(decode(body, content_type))

        if kind in PDF_TYPES:
            text, title = _from_pdf(body)
        elif kind in HTML_TYPES or (not kind and sniffs_html(body)):
            text, title = _from_html(decode(body, content_type))
        elif kind in TEXT_TYPES:
            text, title = decode(body, content_type), None
        else:
            raise ExtractionFailed(kind or "unknown content type")

        return normalise(text, title)


def _from_html(html: str) -> tuple[str, str | None]:
    text = trafilatura.extract(
        html,
        favor_precision=True,
        include_comments=False,
        # Tables often *are* the content on reference pages.
        include_tables=True,
    )
    title = None
    try:
        meta = extract_metadata(html)
        title = meta.title if meta else None
    except Exception:  # noqa: BLE001 - a missing title must not fail the fetch
        title = None

    # None means no main content -- typically a JS-rendered shell. A real and
    # reportable outcome, not an error.
    return text or "", title


def _from_pdf(body: bytes) -> tuple[str, str | None]:
    if PdfReader is None:
        raise ExtractionFailed(
            "this install carries no PDF parser, so PDFs are not read "
            f"(install the 'trafilatura' extra; {PDF_IMPORT_ERROR})"
        )
    try:
        reader = PdfReader(io.BytesIO(body))
        pages = [page.extract_text() or "" for page in reader.pages]
    except Exception as exc:
        # A tuple of exception types would be a guess at what `pypdf` raises on a
        # hostile file; everything out of this call crosses as ExtractionFailed.
        raise ExtractionFailed(
            f"unreadable PDF: {type(exc).__name__}: {exc}"[:200]
        ) from exc

    title = None
    try:
        title = (reader.metadata.title or None) if reader.metadata else None
    except Exception:  # noqa: BLE001 - malformed metadata is not a fetch failure
        title = None
    return "\n\n".join(p for p in pages if p.strip()), title
