"""The fetcher's windowing: what a caller-sized slice of an extraction looks like.

Extraction is uncut (the extractor backend has no cap); this is the single
place the tool's default cap, an ``offset`` page, or an uncapped read for
passage selection get turned into the text a response actually carries.
"""

from collections.abc import AsyncIterator
from typing import override

import httpx
import pytest

from seekwright.extractors.base import SUPPORTED_TYPES, ExtractResult
from seekwright.fetcher import (
    JINA_READER_ENDPOINT,
    KNOWN_FALLBACKS,
    LINKUP_FETCH_ENDPOINT,
    SCRAPPA_SCRAPER_ENDPOINT,
    TAVILY_EXTRACT_ENDPOINT,
    UNCAPPED,
    FetchBlocked,
    HttpFetcher,
    window_text,
)


def paged(paragraph: str = "paragraph of body text", count: int = 40) -> str:
    return "\n\n".join(f"{paragraph} {i}" for i in range(count))


class TestWindowText:
    def test_a_short_text_is_returned_whole(self):
        text = paged(count=3)
        assert window_text(text, offset=0, max_chars=40_000) == (text, False)

    def test_a_long_text_is_cut_at_a_paragraph_break(self):
        text = paged()
        window, more = window_text(text, offset=0, max_chars=200)
        assert more is True
        assert window.endswith("\n\n[...]")
        # The cut preferred a paragraph break over filling the budget: what
        # precedes the marker is whole paragraphs, not a mid-word slice.
        core = window[: -len("\n\n[...]")]
        assert text.startswith(core)
        assert core[-1].isdigit(), "the cut landed on a paragraph boundary"

    def test_the_marker_is_not_counted_in_the_offsets(self):
        """Offsets index the un-marker'd extraction, or paging would drift."""
        text = paged()
        window, _ = window_text(text, offset=0, max_chars=200)
        core = window[: -len("\n\n[...]")]
        assert text[len(core) :] == "\n\n" + text[len(core) + 2 :], (
            "the cut must land on the paragraph break it found"
        )

    def test_an_offset_slices_mid_document(self):
        text = paged()
        window, more = window_text(text, offset=500, max_chars=100)
        core = window[: -len("\n\n[...]")]
        assert core, "a mid-document window is not empty"
        assert text[500:].startswith(core), "the slice starts at the offset"
        assert more is True

    def test_a_window_that_reaches_the_end_is_not_flagged(self):
        text = paged()
        tail, more = window_text(text, offset=len(text) - 50, max_chars=100)
        assert tail == text[-50:]
        assert more is False

    def test_an_offset_past_the_end_returns_empty_but_still_flags(self):
        """The page holds text and none of it is in this window."""
        text = paged()
        assert window_text(text, offset=len(text) + 10, max_chars=100) == ("", True)

    def test_an_uncapped_window_is_the_whole_text(self):
        text = paged()
        assert window_text(text, offset=0, max_chars=UNCAPPED) == (text, False)


class _HtmlOnly:
    """A backend that reads HTML and nothing else."""

    name = "html-only"
    supported_types = frozenset({"text/html"})

    def extract(self, body: bytes, content_type: str | None):
        raise AssertionError("a refused type must never reach the backend")


class _JsonReader:
    """A backend that reads what the default one claims, JSON included."""

    name = "json-reader"
    supported_types = SUPPORTED_TYPES

    def extract(self, body: bytes, content_type: str | None):
        return ExtractResult(body.decode(), None, len(body))


def _served(fetcher: HttpFetcher, content_type: str, body: bytes) -> None:
    fetcher._client = httpx.AsyncClient(
        transport=httpx.MockTransport(
            lambda _r: httpx.Response(
                200, content=body, headers={"content-type": content_type}
            )
        ),
        follow_redirects=False,
    )


class TestJsonIsFetchable:
    """A JSON body is content, not a refusal.

    Only the gate is under test here: which media types reach the backend.
    """

    async def test_a_suffixed_json_type_reaches_the_backend(self):
        """The `+json` suffix is the syntax claim, so no registry of vendor types is consulted."""
        fetcher = HttpFetcher(extractor=_JsonReader(), allow_private_addresses=True)
        _served(fetcher, "application/vnd.api+json", b'{"data": []}')
        page = await fetcher.fetch("https://api.test/things")
        assert page.content_type == "application/vnd.api+json"
        assert page.text == '{"data": []}'
        await fetcher.aclose()

    async def test_a_type_outside_the_family_is_still_refused(self):
        fetcher = HttpFetcher(extractor=_JsonReader(), allow_private_addresses=True)
        _served(fetcher, "application/vnd.api+xml", b"<root/>")
        with pytest.raises(FetchBlocked, match="JSON"):
            await fetcher.fetch("https://api.test/things")
        await fetcher.aclose()


class _UnreadStream(httpx.AsyncByteStream):
    """A body that records whether anything ever asked it for bytes."""

    def __init__(self, chunks: list[bytes]) -> None:
        self._chunks = chunks
        self.read = False

    @override
    async def __aiter__(self) -> AsyncIterator[bytes]:
        self.read = True
        for chunk in self._chunks:
            yield chunk

    @override
    async def aclose(self) -> None:
        # Not the base class's default, which would drain the iterator and so
        # erase the very evidence this stub exists to collect.
        return None


class TestTheBackendDecidesWhatIsReadable:
    """The supported-type set is the backend's, not a module constant.

    The refusal has to happen before the body is pulled down: a backend that
    cannot read a PDF should cost a rejected request, not an 8 MiB download.
    """

    async def test_an_unsupported_type_is_refused_before_the_download(self):
        stream = _UnreadStream([b"%PDF-1.4 content"])
        fetcher = HttpFetcher(extractor=_HtmlOnly(), allow_private_addresses=True)
        fetcher._client = httpx.AsyncClient(
            transport=httpx.MockTransport(
                lambda _r: httpx.Response(
                    200,
                    stream=stream,
                    headers={"content-type": "application/pdf"},
                )
            ),
            follow_redirects=False,
        )

        with pytest.raises(FetchBlocked, match="this tool reads HTML"):
            await fetcher.fetch("https://doc.test/")
        assert stream.read is False, "the body was downloaded for a refused type"
        await fetcher.aclose()


class TestFallbackRegistry:
    """The registry's shape: one row per fallback, declaring its own facts.

    `fetch.fallback` validates against this mapping, `factory.build_fetch_stack`
    builds from it, and `tools/egress_lists.py` renders a proxy host from the
    constant each row names. A row that misdeclares one of the four facts is a
    ladder that mislabels a served page, bills in the wrong order, or walks to a
    host the deployment's proxy refuses.
    """

    def test_the_registry_and_the_fallback_classes_agree_on_the_names(self):
        """A row whose name disagrees with the class it builds mislabels the journal line."""
        import seekwright.fetcher as fetcher_module

        named_classes = {
            cls.name
            for cls in vars(fetcher_module).values()
            if isinstance(cls, type)
            and cls.__module__ == fetcher_module.__name__
            and isinstance(getattr(cls, "name", None), str)
        }
        # `HttpFetcher` is not a fallback: it is this process reading a socket, and it is
        # never named in `fetch.fallback`.
        assert named_classes - {HttpFetcher.name} == set(KNOWN_FALLBACKS)
        for name, row in KNOWN_FALLBACKS.items():
            assert row.name == name, f"the row keyed {name!r} declares {row.name!r}"

    def test_the_tier_is_declared_by_the_fallback(self):
        """Every fallback that can bill says so here, and the ladder validator puts each last.

        Nothing else in the tree infers that: the validator asks this field instead of
        naming a vendor, and a fallback joining the registry with `billable=True` inherits
        the rule rather than a new clause -- which is how the two keyed fallbacks
        arrived with no clause written for them.
        """
        assert {name for name, row in KNOWN_FALLBACKS.items() if row.billable} == {
            "scrappa",
            "tavily",
            "linkup",
        }

    def test_the_host_a_fallback_dials_is_declared_or_named_as_the_operators(self):
        """`endpoint=None` is honest for one fallback only: the self-hosted renderer.

        Its host is `fetch.crawl4ai_url`, which this deployment writes and no reading of
        `src/` can name. Every other fallback dials a constant, and that constant is how its
        host reaches `deploy/compose/generated/fetch-allow-hosts.txt`'s rendered sibling.
        """
        assert {
            name for name, row in KNOWN_FALLBACKS.items() if row.endpoint is None
        } == {"crawl4ai"}
        assert KNOWN_FALLBACKS["scrappa"].endpoint == SCRAPPA_SCRAPER_ENDPOINT
        assert KNOWN_FALLBACKS["jina"].endpoint == JINA_READER_ENDPOINT
        # The keyed fallbacks dial the extraction endpoint of a name this tree already carries.
        assert KNOWN_FALLBACKS["tavily"].endpoint == TAVILY_EXTRACT_ENDPOINT
        assert KNOWN_FALLBACKS["linkup"].endpoint == LINKUP_FETCH_ENDPOINT
