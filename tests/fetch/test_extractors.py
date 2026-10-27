"""Extraction behaviour: what gets kept, what gets dropped, and that nothing
is cut -- windowing lives in ``fetcher.window_text``.

Two backends are exercised here: the default one, which reads a page with
libraries from the ``[trafilatura]`` extra, and the standard-library one
that needs no PDF reader and no extra at all. Where they are
expected to agree, the case is parametrized over both: the plumbing they share
lives in ``base.py`` precisely so that a config line cannot change what a page
means to a caller.

The PDF cases also hold the line the PDF split drew: the library that parses a
stranger's bytes is contained to PDF reading, and what it raises never reaches
a caller as anything but ``ExtractionFailed``.
"""

import asyncio
import importlib
import json
import sys
from contextlib import contextmanager

import pytest

from seekwright.config import Config
from seekwright.extractors import trafilatura as pdf_backend
from seekwright.extractors.base import (
    HTML_TYPES,
    PDF_TYPES,
    SUPPORTED_TYPES,
    TEXT_TYPES,
    ExtractionFailed,
    charset_of,
    decode,
    describe_types,
    is_supported,
    media_type,
    select_passages,
)
from seekwright.extractors.stdlib import StdlibExtractor
from seekwright.extractors.trafilatura import TrafilaturaExtractor
from seekwright.factory import (
    ExtractorUnavailable,
    build_extractor,
    build_fetch_stack,
)

_X = TrafilaturaExtractor()
"""The default backend, instantiated once: extraction is stateless."""

_S = StdlibExtractor()
"""The backend every install can build, instantiated the same way."""

ARTICLE = """<!DOCTYPE html>
<html><head><title>The Title</title></head>
<body>
  <nav>Home About Contact Login</nav>
  <script>var tracking = 1;</script>
  <style>body { color: red }</style>
  <article>
    <h1>A Heading</h1>
    <p>__BODY__</p>
    <p>A second paragraph with an &amp; entity in it.</p>
  </article>
  <footer>Copyright 2026 Some Company</footer>
</body></html>"""


def article(body: str = "This is the real content of the page. " * 10) -> bytes:
    # replace, not format: the inline CSS contains braces.
    return ARTICLE.replace("__BODY__", body).encode()


def minimal_pdf(text: str) -> bytes:
    """A one-page PDF with a real xref table, written out by hand.

    Not pypdf's own writer: the positive case exists to show the extractor
    still reads a PDF, so the fixture cannot come from the library under test.
    Objects go down in order and their byte offsets are recorded as they are
    written, which is all an xref table is.
    """
    stream = f"BT /F1 12 Tf 20 350 Td ({text}) Tj ET".encode()
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        (
            b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] "
            b"/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>"
        ),
        b"<< /Length %d >>\nstream\n%s\nendstream" % (len(stream), stream),
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]

    out = bytearray(b"%PDF-1.4\n")
    offsets: list[int] = []
    for number, body in enumerate(objects, start=1):
        offsets.append(len(out))
        out += b"%d 0 obj\n%s\nendobj\n" % (number, body)
    startxref = len(out)
    out += b"xref\n0 %d\n" % (len(objects) + 1)
    out += b"0000000000 65535 f \n"
    for offset in offsets:
        out += b"%010d 00000 n \n" % offset
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF" % (
        len(objects) + 1,
        startxref,
    )
    return bytes(out)


@contextmanager
def _backend_without_pypdf():
    """The backend module, re-imported with ``pypdf`` unreachable.

    A meta-path finder is what a missing wheel looks like to the import
    system: the name resolves to nothing and the failure is an
    ``ImportError``. Dropping the cached modules first is what makes the
    lookup happen at all. The assertions belong inside the ``with``: the
    backend reads its library out of the module's globals, so putting the
    library back on the way out is what ends the scenario.
    """

    class NoPypdf:
        def find_spec(self, name, path=None, target=None):
            if name == "pypdf" or name.startswith("pypdf."):
                raise ModuleNotFoundError(f"No module named {name!r}", name=name)

    saved = {
        name: module
        for name, module in sys.modules.items()
        if name == "pypdf" or name.startswith("pypdf.")
    }
    for name in saved:
        del sys.modules[name]
    blocker = NoPypdf()
    sys.meta_path.insert(0, blocker)
    try:
        yield importlib.reload(pdf_backend)
    finally:
        sys.meta_path.remove(blocker)
        sys.modules.update(saved)
        importlib.reload(pdf_backend)


class TestBackendContract:
    """The default backend, and the derived phrase the refusal is built from."""

    def test_the_default_backend_names_itself_and_its_types(self):
        assert _X.name == "trafilatura"
        assert _X.supported_types == SUPPORTED_TYPES

    def test_families_render_in_a_fixed_display_order(self):
        """Display order is HTML, plain text, JSON, PDF -- always, whatever the set."""
        assert describe_types(SUPPORTED_TYPES) == "HTML, plain text, JSON and PDF"
        assert describe_types(frozenset({"application/pdf"})) == "PDF"

    def test_a_type_no_family_claims_is_appended_verbatim(self):
        """A new backend's own types must appear rather than be dropped."""
        assert describe_types(frozenset({"text/html", "image/png"})) == (
            "HTML and image/png"
        )
        assert describe_types(frozenset()) == "nothing"


class TestJson:
    """A JSON body becomes structure, not a wall of braces.

    The rendering itself is pinned in ``tests/fetch/test_jsondoc.py``; what is pinned
    here is the backend's half: which bodies it sends to the renderer, and that
    a body the renderer refuses is still a fetch that answered.
    """

    def test_a_json_document_arrives_as_paths(self):
        r = _X.extract(b'{"total": 2, "items": [{"id": 1}, {"id": 2}]}\n', "application/json")
        assert r.text.split("\n")[:3] == [
            "$  object(2)",
            "$.total  2",
            "$.items  array(2)",
        ]
        assert '$.items[1].id  2' in r.text
        assert r.title is None
        assert r.total_chars == len(r.text)
        assert r.path_addressable, "the engine reads this flag, not the first character of the text"

    def test_a_suffixed_json_type_is_read_as_json(self):
        """The media type says whose document it is; the suffix says what it is written in."""
        r = _X.extract(b'{"type": "FeatureCollection", "features": []}', "application/geo+json")
        assert r.text.split("\n") == [
            "$  object(2)",
            '$.type  "FeatureCollection"',
            "$.features  array(0)",
        ]

    def test_the_spaces_inside_a_value_are_the_data(self):
        """`normalise` collapses whitespace runs in prose; a JSON value is not prose."""
        r = _X.extract(b'{"note": "a  b   c"}', "application/json")
        assert r.text == '$  object(1)\n$.note  "a  b   c"'

    def test_a_body_that_only_claims_to_be_json_is_returned_as_its_text(self):
        """An HTML error page under a JSON type has an answer; it is the body, not a refusal."""
        r = _X.extract(b"<html><body>502 Bad Gateway</body></html>", "application/json")
        assert "502 Bad Gateway" in r.text
        assert not r.path_addressable

    def test_a_json_lines_stream_is_returned_as_its_text(self):
        """Claimed so the body arrives; not one document, so nothing is rendered."""
        r = _X.extract(b'{"a": 1}\n{"a": 2}\n', "application/x-ndjson")
        assert r.text == '{"a": 1}\n{"a": 2}\n'
        assert not r.path_addressable

    def test_unlabelled_json_bytes_are_sniffed(self):
        """The mirror of `sniffs_html`: an absent Content-Type is answered by the bytes."""
        r = _X.extract(b'  {"a": 1}\n', None)
        assert r.text == '$  object(1)\n$.a  1'

    def test_a_json_suffix_the_type_gate_cannot_see_still_reaches_the_backend(self):
        """`is_supported` is the gate, and it reads the suffix rather than a registry."""
        assert is_supported(SUPPORTED_TYPES, "application/vnd.api+json")
        assert not is_supported(HTML_TYPES, "application/vnd.api+json")
        assert not is_supported(SUPPORTED_TYPES, "application/vnd.api+xml")


class TestHtml:
    def test_body_text_is_kept(self):
        r = _X.extract(article(), "text/html")
        assert "real content of the page" in r.text

    def test_title_comes_from_the_document(self):
        """trafilatura prefers the article heading over <title> when they differ.

        Either is a defensible answer to "what is this page called", so the
        contract asserted here is that *a* document-derived title comes back --
        not which of the two the library happens to favour.
        """
        r = _X.extract(article(), "text/html")
        assert r.title in ("The Title", "A Heading")

    def test_scripts_and_styles_are_dropped(self):
        r = _X.extract(article(), "text/html")
        assert "var tracking" not in r.text
        assert "color: red" not in r.text

    def test_entities_are_unescaped(self):
        r = _X.extract(article(), "text/html")
        assert "&amp;" not in r.text
        assert "&" in r.text

    def test_missing_content_type_is_sniffed(self):
        r = _X.extract(article(), None)
        assert "real content" in r.text

    def test_javascript_shell_yields_empty_text_not_an_error(self):
        """An empty result is a reportable outcome, not a failure.

        The engine turns it into a notice telling the model to search instead,
        which it can only do if extraction returns rather than raises.
        """
        shell = b"<!DOCTYPE html><html><body><div id='root'></div></body></html>"
        r = _X.extract(shell, "text/html")
        assert r.text == ""


class TestFullText:
    """Extraction is uncut; windowing to a caller-facing size is the fetcher's.

    Used to be ``TestTruncation``: extraction took a ``max_chars`` and cut at a
    paragraph break. The cap moved to ``fetcher.window_text`` because where to
    cut depends on who is asking -- the tool's default, an ``offset`` page, or
    the whole text for passage selection -- and one extraction has to serve all
    three; sizing is the fetcher's job, not the backend's.
    """

    def test_short_text_comes_back_whole(self):
        r = _X.extract(article(), "text/html")
        assert r.total_chars == len(r.text)

    def test_long_text_is_not_cut(self):
        r = _X.extract(article("word " * 5000), "text/html")
        assert r.total_chars == len(r.text)
        assert r.total_chars > 20_000, "the fixture must be long enough to matter"


class TestPlainText:
    def test_plain_text_passes_through(self):
        r = _X.extract(b"Just some words.", "text/plain")
        assert r.text == "Just some words."

    def test_whitespace_runs_are_collapsed(self):
        r = _X.extract(b"a    b\n\n\n\n\nc", "text/plain")
        assert r.text == "a b\n\nc"


class TestUnsupported:
    @pytest.mark.parametrize(
        "ctype", ["image/png", "application/zip", "video/mp4", "audio/mpeg"]
    )
    def test_unextractable_types_raise(self, ctype):
        with pytest.raises(ExtractionFailed):
            _X.extract(b"\x00\x01", ctype)


class TestPdf:
    """PDF reading, and the walls around the library that does it."""

    def test_a_real_pdf_still_extracts(self):
        result = _X.extract(minimal_pdf("The PDF body text"), "application/pdf")
        assert "The PDF body text" in result.text

    def test_a_body_that_is_not_a_pdf_is_a_refusal(self):
        """The bytes say PDF; they are not a PDF. The caller gets a notice."""
        with pytest.raises(ExtractionFailed, match="unreadable PDF"):
            _X.extract(b"%PDF-1.7\nnot a pdf at all \x00\x00", "application/pdf")

    def test_any_failure_inside_the_library_crosses_as_a_refusal(self, monkeypatch):
        """The boundary is the type the *fetcher* understands, not a list of the
        parser's error classes.

        A hostile file makes pypdf raise whatever its internals happen to
        raise -- the ``KeyError`` of a broken object table stands in for that
        here -- and none of it may reach the fetcher as anything the
        ``ExtractionFailed`` path does not already turn into a refusal.
        """

        class BrokenObjectTable:
            def __init__(self, _stream: object) -> None:
                raise KeyError("/Root")

        monkeypatch.setattr(pdf_backend, "PdfReader", BrokenObjectTable)
        with pytest.raises(ExtractionFailed, match="unreadable PDF: KeyError"):
            _X.extract(minimal_pdf("irrelevant"), "application/pdf")

    def test_a_missing_library_drops_pdf_from_the_types_it_claims(self):
        """Honest types: the fetcher refuses a PDF before downloading one, and
        the phrase in that refusal says what this install can actually read."""
        with _backend_without_pypdf() as module:
            claimed = module.TrafilaturaExtractor.supported_types
            assert claimed == HTML_TYPES | TEXT_TYPES
            assert module.PDF_IMPORT_ERROR, "the guard must name the reason"
        assert describe_types(claimed) == "HTML and plain text"

    def test_a_missing_library_costs_pdf_reading_not_the_backend(self):
        """A partial extra must not take HTML and plain text down with it."""
        with _backend_without_pypdf() as module:
            backend = module.TrafilaturaExtractor()
            page = backend.extract(article(), "text/html")
            assert "real content of the page" in page.text
            assert backend.extract(b"plain body", "text/plain").text == "plain body"
            with pytest.raises(ExtractionFailed, match="no PDF parser"):
                backend.extract(minimal_pdf("unreachable"), "application/pdf")


class TestStdlibBackend:
    """The backend a bare install names: same protocol, no library, no PDF.

    It renders the text a reader of the page would see rather than guessing
    which part of it is the article, so the chrome cases below are as much a
    description of what this backend does *not* do as the script cases are of
    the trafilatura backend's.
    """

    def test_it_names_itself_and_claims_no_pdf(self):
        assert _S.name == "stdlib"
        assert _S.supported_types & PDF_TYPES == frozenset()
        assert not is_supported(_S.supported_types, "application/pdf")
        assert describe_types(_S.supported_types) == "HTML, plain text and JSON"

    def test_the_article_survives_and_its_chrome_does_not(self):
        r = _S.extract(article(), "text/html")
        assert "real content of the page" in r.text
        assert "Home About Contact" not in r.text
        assert "Copyright 2026" not in r.text
        assert r.title == "The Title"

    def test_scripts_and_styles_are_dropped(self):
        r = _S.extract(article(), "text/html")
        assert "var tracking" not in r.text
        assert "color: red" not in r.text

    def test_entities_are_unescaped(self):
        r = _S.extract(article(), "text/html")
        assert "&amp;" not in r.text
        assert "&" in r.text

    def test_a_list_reads_as_items(self):
        body = b"<html><body><ul><li>One</li><li>Two</li></ul></body></html>"

        assert _S.extract(body, "text/html").text == "- One\n- Two"

    def test_an_empty_list_item_earns_no_bullet(self):
        """Spacers and icon-only items are markup, not items, in the output."""
        body = b"<html><body><ul><li><span></span></li><li>Real item</li></ul></body></html>"

        assert _S.extract(body, "text/html").text == "- Real item"

    def test_a_table_keeps_its_cells_apart(self):
        """Tables are often the answer on a reference page, so the cell boundary
        survives -- the reason `include_tables` is on in the other backend."""
        body = (
            b"<html><body><table><tr><td>one</td><td>two</td></tr></table></body></html>"
        )

        assert _S.extract(body, "text/html").text == "one two"

    def test_a_row_begins_at_its_first_cell(self):
        """The boundary is between values, so no line starts with a space."""
        body = (
            b"<html><body><table>"
            b"<tr><th>H1</th><th>H2</th></tr>"
            b"<tr><td>a</td><td>b</td></tr>"
            b"</table></body></html>"
        )

        assert _S.extract(body, "text/html").text == "H1 H2\n\na b"

    def test_an_icon_sprite_does_not_rename_the_page(self):
        """`<svg><title>` names a graphic, and a sprite repeats the element.

        mkdocs-material and other generators ship an inline sprite, so a backend
        that keeps the last `<title>` it saw reports an icon label as the name of
        the page -- and one that clears an outer skip on the first inner end tag
        reports it as page text. A sprite nests `<svg>` inside `<svg>`.
        """
        body = (
            b"<html><head><title>Real Page Title</title></head><body>"
            b"<svg><symbol id='a'><title>Icon A</title>"
            b"<svg><path/></svg></symbol>"
            b"<symbol id='b'><title>Icon B</title></svg>"
            b"<p>body text</p></body></html>"
        )

        r = _S.extract(body, "text/html")
        assert r.title == "Real Page Title"
        assert "Icon A" not in r.text
        assert "Icon B" not in r.text

    def test_a_title_inside_a_graphic_is_never_the_page_name(self):
        """The graphic rule stands on its own, not on the skip stack surviving."""
        body = (
            b"<html><body><svg><g><svg><title>Icon A</title></svg>"
            b"<title>Icon B</title></svg><p>body</p></body></html>"
        )

        assert _S.extract(body, "text/html").title is None

    def test_both_ways_of_writing_a_break_mean_one_line(self):
        """`<br/>` arrives as an open and a close; `<br>` as an open alone."""
        body = b"<html><body><p>one<br/>two<br>three</p></body></html>"

        assert _S.extract(body, "text/html").text == "one\ntwo\nthree"

    def test_the_text_inside_a_form_goes_with_the_form(self):
        """`form` is on the skip list, and a login page is not the answer.

        The cost of that list, pinned rather than promised: a page that puts its
        article inside a `<form>` returns nothing but a refusal to the caller,
        and the operator moves them onto the other backend.
        """
        body = b"<html><body><form><p>inside form text</p></form><p>outside</p></body></html>"

        assert _S.extract(body, "text/html").text == "outside"

    def test_a_block_left_open_does_not_swallow_the_rest_of_the_page(self):
        """Real markup ends a `<nav>` without closing the `<div>` it opened.

        A parser that keeps no tree can only recover on the end tag it was
        given, and that recovery is what keeps a stray `<div>` from turning the
        article into nothing.
        """
        body = b"<html><body><nav><div>Menu</nav><p>The article body.</p></body></html>"

        r = _S.extract(body, "text/html")
        assert "The article body." in r.text
        assert "Menu" not in r.text

    def test_missing_content_type_is_sniffed(self):
        assert "real content" in _S.extract(article(), None).text

    def test_javascript_shell_yields_empty_text_not_an_error(self):
        shell = b"<!DOCTYPE html><html><body><div id='root'></div></body></html>"
        assert _S.extract(shell, "text/html").text == ""

    def test_a_pdf_is_a_refusal_naming_the_type(self):
        """Not this backend's to read, and honest types make it a named refusal.

        The fetcher normally stops a PDF at its media type, so this is the case
        where a caller built the backend by hand and still gets a notice rather
        than a stack trace.
        """
        with pytest.raises(ExtractionFailed, match="application/pdf"):
            _S.extract(minimal_pdf("unreachable"), "application/pdf")

    def test_untagged_markup_is_read_as_text_not_as_a_failure(self):
        """`html.parser` is lenient, and a page with unbalanced tags is normal."""
        body = b"<html><body><p>An unclosed paragraph<p>And another"

        r = _S.extract(body, "text/html")
        assert "An unclosed paragraph" in r.text
        assert "And another" in r.text


class TestBackendsAgreeOnSharedPlumbing:
    """Where the two backends must give one answer, they are tested as one.

    `normalise`, `decode` and `json_extraction` live in `base.py` for this
    reason: swapping `fetch.extractor` is a config line, and a caller must not
    find a page meaning something different afterwards because the two backends
    each grew their own copy of a rule.
    """

    @pytest.mark.parametrize("backend", [_X, _S], ids=lambda b: b.name)
    def test_a_json_body_becomes_structure_a_path_can_address(self, backend):
        body = json.dumps({"title": "A page", "lines": ["one", "two"]}).encode()

        r = backend.extract(body, "application/json")

        assert r.path_addressable is True
        assert "$.lines[0]" in r.text

    @pytest.mark.parametrize("backend", [_X, _S], ids=lambda b: b.name)
    def test_a_body_that_is_not_one_json_document_comes_back_as_its_text(self, backend):
        r = backend.extract(b'{"a": 1}\n{"a": 2}\n', "application/jsonl")

        assert r.path_addressable is False
        assert r.text == '{"a": 1}\n{"a": 2}\n', "the bytes are the answer"

    @pytest.mark.parametrize("backend", [_X, _S], ids=lambda b: b.name)
    def test_plain_text_passes_through_the_same_wire_shape(self, backend):
        assert backend.extract(b"a    b\n\n\n\n\nc", "text/plain").text == "a b\n\nc"

    @pytest.mark.parametrize("backend", [_X, _S], ids=lambda b: b.name)
    def test_the_declared_charset_is_preferred(self, backend):
        body = "café".encode("iso-8859-1")
        assert backend.extract(body, "text/plain; charset=iso-8859-1").text == "café"

    @pytest.mark.parametrize("backend", [_X, _S], ids=lambda b: b.name)
    @pytest.mark.parametrize("ctype", ["image/png", "application/zip", "video/mp4"])
    def test_an_unreadable_type_is_a_refusal(self, backend, ctype):
        with pytest.raises(ExtractionFailed):
            backend.extract(b"\x00\x01", ctype)


@contextmanager
def _extra_uninstalled(monkeypatch):
    """An install that never carried the `[trafilatura]` extra.

    `None` in `sys.modules` is the same trick `test_factory` uses: the import
    halts before the missing wheel is looked for. Dropping the backend module is
    what makes the factory's lazy import run again instead of reading the copy
    this file imported at collection time.
    """
    monkeypatch.setitem(sys.modules, "trafilatura", None)
    monkeypatch.setitem(sys.modules, "pypdf", None)
    monkeypatch.delitem(sys.modules, "seekwright.extractors.trafilatura", raising=False)
    yield


class TestStackOnABareInstall:
    """The probe a bare install opens with, kept as a test rather than as a note.

    With the extra's modules unreachable, `factory.build_extractor(Config())`
    and `factory.build_fetch_stack(Config())` both raised `ExtractorUnavailable`,
    and `server.build_app_context` turns that into `SystemExit` while
    `fetch.enabled` is true -- a bare install lost the process, not a tool. What
    that install can now name is the backend that needs no library, so the two
    halves of the fact are pinned together: the default name still fails, and
    the whole fetch stack still builds.
    """

    def test_the_default_name_still_names_the_extra_it_needs(self, monkeypatch):
        with _extra_uninstalled(monkeypatch):
            with pytest.raises(ExtractorUnavailable) as exc:
                build_extractor(Config())
            assert "'trafilatura' extra" in str(exc.value)

    def test_the_fetch_stack_builds_with_the_extra_unreachable(self, monkeypatch):
        config = Config()
        config.fetch.extractor = "stdlib"

        with _extra_uninstalled(monkeypatch):
            backend = build_extractor(config)
            fetcher, fallbacks = asyncio.run(build_fetch_stack(config))

        if fetcher is None:
            pytest.fail("an install that carried no extra lost the tool")
        try:
            assert backend.name == "stdlib"
            assert fallbacks == []
            page = backend.extract(article(), "text/html")
        finally:
            asyncio.run(fetcher.aclose())
        assert "real content of the page" in page.text


class TestDecoding:
    def test_declared_charset_is_preferred(self):
        body = "café".encode("iso-8859-1")
        assert decode(body, "text/html; charset=iso-8859-1") == "café"

    def test_undecodable_bytes_do_not_raise(self):
        """One bad byte must not cost the whole page."""
        assert decode(b"ok \xff\xfe bad", "text/plain")

    def test_a_declared_charset_no_codec_names_falls_back(self):
        """A header naming a codec this install lacks is a header problem, not a lost page."""
        assert decode("café".encode(), "text/html; charset=not-a-codec") == "café"

    def test_media_type_strips_parameters(self):
        assert media_type("TEXT/HTML; charset=utf-8") == "text/html"
        assert media_type(None) == ""

    def test_charset_is_parsed(self):
        assert charset_of('text/html; charset="utf-8"') == "utf-8"
        assert charset_of("text/html") is None


def chunked_para(head: str) -> str:
    """A paragraph long enough to land alone in a selection chunk.

    Two of these joined exceed ``_CHUNK_CHARS``, so each becomes its own chunk
    and every test below knows exactly what the chunking did.
    """
    return f"{head} {'filler ' * 200}"


class TestSelectPassages:
    def test_prefers_chunks_hitting_more_terms(self):
        no_term = chunked_para("Sourdough starters need flour and water.")
        one_term = chunked_para("Volatility spiked after the announcement.")
        two_terms = chunked_para("Bitcoin volatility spiked after the announcement.")
        text = f"{no_term}\n\n{one_term}\n\n{two_terms}"

        spans, dropped = select_passages(text, "bitcoin volatility", max_chars=6000)

        assert dropped == 0
        # The zero-score chunk is never a candidate; the two matching chunks
        # are adjacent, so they merge into one contiguous document-order span.
        assert len(spans) == 1
        offset, body = spans[0]
        assert offset == len(no_term) + 2
        assert body == text[offset:], (
            "a span must be the text at its own absolute offset"
        )

    def test_budget_stops_selection_and_counts_dropped(self):
        a = chunked_para("Bitcoin volatility spiked after the announcement.")
        gap = chunked_para("Sourdough starters need flour and patience.")
        b = chunked_para("Bitcoin miners resumed operations.")
        c = chunked_para("Bitcoin exchanges raised their fees.")
        text = f"{a}\n\n{gap}\n\n{b}\n\n{c}"

        # Three equal-score chunks, room for two; the chunk between stops the two
        # spans merging.
        spans, dropped = select_passages(text, "bitcoin", max_chars=3000)

        assert dropped == 1
        assert len(spans) == 2
        assert sum(len(body) for _, body in spans) <= 3000

    def test_adjacent_selected_chunks_merge_into_one_span(self):
        a = chunked_para("Bitcoin volatility spiked.")
        b = chunked_para("Volatility spread to the altcoins.")
        text = f"{a}\n\n{b}"

        spans, dropped = select_passages(text, "volatility", max_chars=6000)

        assert dropped == 0
        assert spans == [(0, text)], "contiguous chunks come back as one span"

    def test_no_match_returns_nothing_and_no_drops(self):
        text = chunked_para("Sourdough starters need flour and patience.")

        assert select_passages(text, "bitcoin mining rig", max_chars=6000) == ([], 0)

    def test_short_query_tokens_are_ignored(self):
        text = chunked_para("Sourdough starters need flour and patience.")

        # "a" and "of" are under the two-character floor; nothing matches.
        assert select_passages(text, "a of", max_chars=6000) == ([], 0)
