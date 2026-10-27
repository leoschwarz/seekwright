"""The extraction backend every install can build: the standard library, nothing else.

`fetch.enabled` is true by default, and `server.build_app_context` turns
`ExtractorUnavailable` into `SystemExit`. Without a backend whose imports are all
in the standard library, a wheel installed without the `[trafilatura]` extra would
lose the process, not a tool. `TestStackOnABareInstall` is the probe.

No parity with trafilatura is claimed: it was measured against a hand-written
`html.parser` extractor on a 264k-character article, and the hand-written one
leaked site furniture (`extractors/trafilatura.py`). This is the same kind of
renderer -- it drops the elements `_SKIP_TAGS` names and keeps the rest -- so the
chrome that survives is the chrome outside those elements, and a page whose
answer sits inside a `<form>` loses it with the element. A JS-rendered shell
returns its chrome, so `fetch.min_text_chars` turns such a page into a refusal.
Which backend a default install names stays measured (docs/ROADMAP.md section 3).

PDF is absent from the type set by rule, not by gap: there is no PDF reader in
the standard library, and `base.py` requires a backend to claim only what it can
read. The fetcher therefore refuses a PDF by name before downloading it.
"""

from __future__ import annotations

from html.parser import HTMLParser
from typing import override

from ..jsondoc import JSON_TYPES, is_json_media, sniffs_json
from .base import (
    HTML_TYPES,
    TEXT_TYPES,
    ExtractionFailed,
    ExtractResult,
    decode,
    json_extraction,
    media_type,
    normalise,
    sniffs_html,
)

# Never the answer: what a browser executes or draws, and the sectioning elements
# whose job is the furniture around the content.
_SKIP_TAGS = frozenset(
    {
        "script",
        "style",
        "noscript",
        "template",
        "svg",
        "math",
        "canvas",
        "nav",
        "header",
        "footer",
        "aside",
        "form",
        "fieldset",
        "select",
        "option",
        "button",
    }
)

# A graphic names itself with the same element a document uses, and that name is
# never the page's. Its own counter, not a read of `_skipping`: a sprite nests
# `<svg>` inside `<svg>`, and the icon labels must stay graphic-internal.
_GRAPHIC_TAGS = frozenset({"svg", "math"})

# Elements that break a line the way a paragraph does, so adjacent blocks never
# merge into one sentence. `pre` rides with them: `normalise` collapses space runs
# anyway, so preserving its layout here would promise what the plumbing does not
# deliver.
_BLOCK_TAGS = frozenset(
    {
        "p",
        "div",
        "section",
        "article",
        "main",
        "figure",
        "figcaption",
        "blockquote",
        "pre",
        "h1",
        "h2",
        "h3",
        "h4",
        "h5",
        "h6",
        "ul",
        "ol",
        "dl",
        "table",
        "thead",
        "tbody",
        "tfoot",
        "tr",
        "caption",
        "details",
        "summary",
        "address",
        "hr",
        "body",
    }
)

# A table cell needs a word boundary between values; a row does not, since `tr`
# is already in the block set and a row break reads as a new line.
_CELL_TAGS = frozenset({"td", "th", "dt", "dd"})


class _VisibleTextParser(HTMLParser):
    """The visible text of a document, in document order, plus its title.

    `convert_charrefs` is the entity handling: `&amp;` arrives as data, so this
    backend agrees with the other one about a page written with entities. A
    comment never reaches `handle_data`.
    """

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.chunks: list[str] = []
        self.title: str | None = None
        self._skipping: list[str] = []
        self._graphics = 0
        self._title: list[str] = []
        self._in_title = False

    @override
    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag in _GRAPHIC_TAGS:
            self._graphics += 1
        if tag == "title":
            # A `<title>` inside skipped markup or a graphic is a tooltip, not the
            # document's name.
            self._in_title = not (self._skipping or self._graphics)
            if self._in_title:
                self._title = []
            return
        if tag in _SKIP_TAGS:
            self._skipping.append(tag)
            return
        if not self._skipping:
            self._separator(tag, closing=False)

    @override
    def handle_endtag(self, tag: str) -> None:
        if tag in _GRAPHIC_TAGS and self._graphics:
            self._graphics -= 1
        if tag == "title":
            if self._in_title and self._title and self.title is None:
                # A page repeats the element: the first is the document's name, the
                # ones an icon sprite adds are graphic labels.
                self.title = "".join(self._title).strip() or None
            self._in_title = False
            return
        if tag in _SKIP_TAGS and tag in self._skipping:
            # An end tag closes the innermost element of that name and everything
            # opened inside it: markup ends a `<nav>` without closing its `<div>`.
            # Innermost, because clearing from the outer `<svg>` of a sprite hands
            # every later icon title to the caller as page text.
            for depth in range(len(self._skipping) - 1, -1, -1):
                if self._skipping[depth] == tag:
                    del self._skipping[depth:]
                    break
            return
        if not self._skipping:
            self._separator(tag, closing=True)

    @override
    def handle_startendtag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        # `<br/>` asks for a line break with no end tag to follow, so the pair is
        # one call rather than two that a self-closing element never completes.
        self.handle_starttag(tag, attrs)
        self.handle_endtag(tag)

    @override
    def handle_data(self, data: str) -> None:
        if self._in_title:
            self._title.append(data)
        elif not self._skipping and data:
            self.chunks.append(data)

    def _separator(self, tag: str, *, closing: bool) -> None:
        if tag == "br":
            # One break for one `<br>`: the XML form arrives as an open and a
            # close in a single event, and two breaks read as a paragraph break.
            if not closing:
                self.chunks.append("\n")
        elif tag == "li":
            # The marker opens an item, and its end needs nothing: the next item
            # opens with a line break of its own, and the list closes with one.
            if not closing:
                self.chunks.append("\n- ")
        elif tag in _CELL_TAGS:
            # A word boundary *between* two values: the row's own break already
            # ends the line, so the cell that opens a row adds no leading space.
            if not closing and self.chunks and not self.chunks[-1].endswith("\n"):
                self.chunks.append(" ")
        elif tag in _BLOCK_TAGS:
            self.chunks.append("\n\n")


class StdlibExtractor:
    """HTML through `html.parser`, JSON through `jsondoc`, plain text passed through."""

    name = "stdlib"
    # No PDF, and `base.py` makes that claim in the type set rather than in prose:
    # a backend lists only what its `extract` can read, so the fetcher turns a PDF
    # into a named refusal instead of spending a download on it.
    supported_types = HTML_TYPES | TEXT_TYPES | JSON_TYPES

    def extract(self, body: bytes, content_type: str | None) -> ExtractResult:
        """Extract readable text from a fetched body, uncut.

        The media type decides the reader; a missing one is sniffed as HTML or
        JSON only when the bytes look like one of them, so an unknown binary is
        refused rather than fed to the parser to produce nothing.
        """
        kind = media_type(content_type)

        if is_json_media(kind) or (not kind and sniffs_json(body)):
            return json_extraction(decode(body, content_type))

        if kind in HTML_TYPES or (not kind and sniffs_html(body)):
            text, title = _from_html(decode(body, content_type))
        elif kind in TEXT_TYPES:
            text, title = decode(body, content_type), None
        else:
            # A PDF included: this backend claims no PDF type, so the fetcher
            # normally refuses one before the body is downloaded, and reaching
            # here means a caller built the backend by hand.
            raise ExtractionFailed(kind or "unknown content type")

        return normalise(text, title)


def _from_html(html: str) -> tuple[str, str | None]:
    """The document's visible text and its `<title>`, or `None` when it has none."""
    parser = _VisibleTextParser()
    parser.feed(html)
    parser.close()
    # Indented markup leaves lines holding nothing but spaces. `normalise` caps
    # blank-line runs but cannot see a line that *holds* whitespace, so those are
    # emptied here rather than reaching a caller as a paragraph break.
    chunks = "".join(parser.chunks).splitlines()
    # An empty `<li>` -- a spacer, an icon -- earns no bullet: it becomes a blank
    # line, and `normalise` collapses the run.
    lines = [
        line if line.strip() and line.strip() != "-" else "" for line in chunks
    ]
    return "\n".join(lines), parser.title
