"""End-to-end fetch behaviour with a stub fetcher.

The network is stubbed; what is under test is how the engine reports a page and
how it fails. The paid second fallback has its own suite in tests/fetch/test_fetch_fallback.py.
"""

import base64
from typing import cast

import pytest

from seekwright.config import Config, FetchConfig, PolicyConfig, ProviderConfig
from seekwright.engine import FetchEngine, FetchFailed, FetchRefused
from seekwright.fetcher import (
    UNCAPPED,
    ContentFetcher,
    FetchBlocked,
    FetchedImage,
    FetchedPage,
)
from seekwright.jsondoc import render_json
from seekwright.providers.base import ProviderError
from seekwright.sanitize import ZWSP
from seekwright.usage import UsageRecorder

URL = "https://example.com/article"

# Long enough to clear FetchConfig.min_text_chars: a good page has to look like one.
PAGE_TEXT = (
    "The page body. Every fetch test that means to exercise a successful "
    "extraction uses this string, so it has to be long enough that the engine "
    "does not mistake it for the nav stub a JavaScript-rendered page leaves "
    "behind. Anything shorter is the empty case, which has its own tests."
)


class StubFetcher:
    name = "fetch"
    cost_per_1k: float | None = None

    def __init__(
        self,
        *,
        name: str = "fetch",
        fail: Exception | None = None,
        text: str = PAGE_TEXT,
        landed: str | None = None,
        title: str | None = "A Page",
        content_type: str | None = "text/html",
        path_addressable: bool = False,
        image: FetchedImage | None = None,
    ):
        self.name = name
        self.calls = 0
        self.kwargs: list[dict[str, object]] = []
        self._fail = fail
        self._text = text
        self._landed = landed
        self._title = title
        self._content_type = content_type
        self._path_addressable = path_addressable
        self._image = image

    async def fetch(
        self, url: str, *, offset: int = 0, max_chars: int | None = None
    ) -> FetchedPage:
        self.calls += 1
        self.kwargs.append({"offset": offset, "max_chars": max_chars})
        if self._fail:
            raise self._fail
        if self._image is not None:
            return FetchedPage(
                url=self._landed or url,
                title=None,
                text="",
                content_type=self._image.media_type,
                status_code=200,
                truncated=False,
                total_chars=0,
                image=self._image,
            )
        return FetchedPage(
            url=self._landed or url,
            title=self._title,
            text=self._text,
            content_type=self._content_type,
            status_code=200,
            truncated=False,
            total_chars=len(self._text),
            path_addressable=self._path_addressable,
        )

    async def aclose(self) -> None:
        return None


@pytest.fixture
def make_engine():
    def _make(
        fetcher: StubFetcher | None = None,
        usage: UsageRecorder | None = None,
        fetch: FetchConfig | None = None,
        fallbacks: list[StubFetcher] | None = None,
    ):
        cfg = Config(
            providers={"serper": ProviderConfig()},
            policy=PolicyConfig(),
            fetch=fetch or FetchConfig(),
        )
        ladder: list[ContentFetcher] = list(fallbacks) if fallbacks else []
        return FetchEngine(cfg, fetcher or StubFetcher(), ladder, usage=usage)

    return _make


class TestSuccess:
    async def test_page_text_is_returned(self, make_engine):
        r = await make_engine().fetch(URL)
        assert r.text == PAGE_TEXT
        assert r.title == "A Page"
        assert r.status_code == 200
        assert r.retrieved_at is not None
        assert r.notice is None

    async def test_requested_url_is_always_reported(self, make_engine):
        """A caller that cannot see a redirect happened cannot judge the content."""
        engine = make_engine(StubFetcher(landed="https://example.com/article-final"))
        r = await engine.fetch(URL)
        assert r.requested_url == URL
        assert r.url == "https://example.com/article-final"

    async def test_every_call_fetches(self, make_engine):
        f = StubFetcher()
        engine = make_engine(f)
        await engine.fetch(URL)
        await engine.fetch(URL)
        assert f.calls == 2, "there is no cache; each call goes out"


class TestFailure:
    async def test_failure_raises(self, make_engine):
        engine = make_engine(StubFetcher(fail=ProviderError("fetch", "503")))
        with pytest.raises(FetchFailed, match="Retry shortly"):
            await engine.fetch(URL)

    @pytest.mark.parametrize(
        "fallbacks",
        [[], [StubFetcher(name="scrappa")]],
        ids=["no-ladder-configured", "a-ladder-configured"],
    )
    async def test_blocked_url_does_not_advise_a_retry(self, make_engine, fallbacks):
        """A guardrail refusal will refuse again; saying "retry" invites a loop.

        The configured ladder is the case that let the loop back in: with the walk
        withheld the failure appends the configured names as something to retry on,
        and every remote fallback runs the same SSRF check -- ``fetcher``'s
        ``_validated_remote_target`` refuses a private address unconditionally --
        so the retry that sentence names is refused by construction. A guardrail
        refusal leaves no choice to hand back: its reason already says what was
        refused, and the message ends there whether or not a ladder is configured.
        """
        engine = make_engine(
            StubFetcher(fail=FetchBlocked("private address")),
            fetch=FetchConfig(fallback=["scrappa"] if fallbacks else None),
            fallbacks=fallbacks,
        )
        with pytest.raises(FetchFailed) as exc:
            await engine.fetch(URL)
        message = str(exc.value)
        assert "Retry" not in message
        assert "Other configured fetch providers" not in message
        assert message == "Fetch failed - fetch: private address."


class TestEmptyExtraction:
    async def test_empty_text_is_reported_not_raised(self, make_engine):
        r = await make_engine(StubFetcher(text="")).fetch(URL)
        assert r.text == ""
        assert "JavaScript-rendered" in r.notice


class TestQueryTargeting:
    async def test_query_fetches_uncapped(self, make_engine):
        f = StubFetcher()
        await make_engine(f).fetch(URL, query="walrus")
        assert f.kwargs == [{"offset": 0, "max_chars": UNCAPPED}]

    async def test_query_returns_matches_with_absolute_offsets(self, make_engine):
        # The pads push each matching paragraph into its own chunk, and the
        # zero-score filler chunks between the matches keep them separate.
        first = "The walrus lives in the arctic. " + "x" * 1600
        second = "The walrus eats clams. " + "y" * 1600
        text = f"{first}\n\n{second}"

        r = await make_engine(StubFetcher(text=text)).fetch(URL, query="walrus")

        assert r.text is None, "a matches response never also carries the page"
        assert r.total_chars == len(text)
        assert [m.offset for m in r.matches] == [0, len(first) + 2]
        for m in r.matches:
            assert "walrus" in m.text
            assert m.text == text[m.offset : m.offset + len(m.text)], (
                "a match's offset must locate its own text"
            )

    async def test_query_with_no_hits_says_so_and_leaves_text_unset(self, make_engine):
        r = await make_engine().fetch(URL, query="zzzqqq")

        assert r.matches == []
        assert r.text is None
        assert "none of the query terms appear" in (r.notice or "")
        assert "fetch without `query`" in (r.notice or "")

    async def test_query_over_budget_reports_dropped_sections(self):
        paras = [f"Walrus {i}. " + "x" * 1600 for i in range(3)]
        f = StubFetcher(text="\n\n".join(paras))
        cfg = Config(
            providers={"serper": ProviderConfig()},
            policy=PolicyConfig(),
            fetch=FetchConfig(max_match_chars=2000),
        )

        r = await FetchEngine(cfg, f).fetch(URL, query="walrus")

        assert r.text is None
        assert r.matches is not None
        assert len(r.matches) == 1
        assert (
            "passage budget (2000 chars) reached; 2 more matching section(s) "
            "not returned" in (r.notice or "")
        )

    async def test_query_on_an_unreadable_page_keeps_the_shell_diagnosis(
        self, make_engine
    ):
        r = await make_engine(StubFetcher(text="")).fetch(URL, query="walrus")

        assert r.matches is None
        assert "JavaScript-rendered" in (r.notice or "")
        assert "none of the query terms" not in (r.notice or "")


def _rendered(doc: str) -> str:
    """The engine selects over a rendering, so these fixtures are documents by construction."""
    text = render_json(doc)
    assert text is not None
    return text


class TestJsonPathTargeting:
    """`path` reads one part of a JSON document instead of the document.

    The grammar and the selection arithmetic are pinned in
    ``tests/fetch/test_jsondoc.py``; what is pinned here is the engine's half: that a
    selection is uncapped at the fetcher and bounded in the response, that the
    offsets a caller gets index the whole rendering, and which sentence a
    request that cannot be honoured comes back with.
    """

    # Long enough that its rendering clears `fetch.min_text_chars`: a small
    # document here would be tested as the empty-page case.
    DOC = (
        '{"total": 2, "query": "json path expressions", "items": ['
        '{"id": 1, "name": "alpha", "language": "Python", "url": "https://example.test/alpha"},'
        '{"id": 2, "name": "beta", "language": "Rust", "url": "https://example.test/beta"}]}'
    )

    def _json(self) -> StubFetcher:
        # `path_addressable` is what the real fetcher carries out of an
        # extraction that rendered a structure; a stub that left it out would be
        # testing the notice for a page with no structure.
        return StubFetcher(
            text=_rendered(self.DOC),
            title=None,
            content_type="application/json",
            path_addressable=True,
        )

    async def test_a_path_fetches_uncapped(self, make_engine):
        """The budget bounds the response, not the document read to select from it."""
        f = self._json()
        await make_engine(f).fetch(URL, path="$.total")
        assert f.kwargs == [{"offset": 0, "max_chars": UNCAPPED}]

    async def test_a_path_returns_the_subtree_at_an_offset_into_the_rendering(self, make_engine):
        text = _rendered(self.DOC)
        r = await make_engine(self._json()).fetch(URL, path="$.items[1]")
        assert r.text is None, "a matches response never also carries the page"
        assert r.total_chars == len(text)
        assert r.matches is not None
        assert len(r.matches) == 1
        span = r.matches[0]
        assert span.text.startswith("$.items[1]  object(4)")
        assert text[span.offset : span.offset + len(span.text)] == span.text
        assert "$.items[0]" not in span.text

    async def test_a_wildcard_path_returns_one_match_per_element(self, make_engine):
        r = await make_engine(self._json()).fetch(URL, path="$.items[*].name")
        assert r.matches is not None
        assert [m.text for m in r.matches] == [
            '$.items[0].name  "alpha"',
            '$.items[1].name  "beta"',
        ]

    async def test_a_path_that_matches_nothing_says_the_structure_is_one_away(self, make_engine):
        r = await make_engine(self._json()).fetch(URL, path="$.nope")
        assert r.text is None
        assert r.matches == []
        assert "without `path`" in r.notice

    async def test_a_path_on_a_page_with_no_structure_returns_the_page(self, make_engine):
        """The request only means something about JSON; the page is still the answer."""
        r = await make_engine(StubFetcher()).fetch(URL, path="$.items")
        assert r.text == PAGE_TEXT
        assert r.matches is None
        assert "not one this server could read" in r.notice

    async def test_a_page_whose_text_happens_to_start_with_a_dollar_is_still_a_page(
        self, make_engine
    ):
        """A Makefile is a routine fetch target on a code host, and its text begins `$ make all`.

        Reading "is this a document" off the first character answered that page
        with `matches: []` and a sentence asserting it was a JSON document with
        nothing at that path -- which withheld a page the caller had already
        been billed for.
        """
        page = StubFetcher(
            text="$ make all\n" + "# build every target in the directory\n" * 20,
            title=None,
            content_type="text/plain",
        )
        r = await make_engine(page).fetch(URL, path="$.src")
        assert r.text is not None and r.text.startswith("$ make all")
        assert r.matches is None
        assert "not one this server could read" in r.notice

    async def test_a_json_claim_on_a_body_that_is_not_a_document_says_which(self, make_engine):
        stub = StubFetcher(
            # A malformed body long enough not to read as the empty-page case.
            text='{"total": 2,, "items": [' + '"a very long record that goes on and on", ' * 8 + ']}',
            title=None,
            content_type="application/json",
        )
        r = await make_engine(stub).fetch(URL, path="$.total")
        assert r.text is not None, "the body is what a caller can act on"
        assert "not one this server could read" in r.notice

    async def test_a_selection_cut_before_its_first_span_says_so(self, make_engine):
        """A budget too small for the smallest match is a cut answer, not a no-match."""
        engine = make_engine(self._json(), fetch=FetchConfig(max_match_chars=20))
        r = await engine.fetch(URL, path="$.items[0]")
        assert r.matches == []
        assert "larger than the selection budget" in r.notice
        assert "nothing in this JSON document matches" not in r.notice

    async def test_a_path_over_budget_reports_what_was_cut_and_how_to_narrow_it(self, make_engine):
        engine = make_engine(
            self._json(), fetch=FetchConfig(max_match_chars=60)
        )
        r = await engine.fetch(URL, path="$.items")
        assert r.matches and all(len(m.text) <= 60 for m in r.matches)
        assert "selection budget (60 chars) reached" in r.notice
        assert "narrower `path`" in r.notice

    async def test_a_path_selects_nothing_on_an_unreadable_page(self, make_engine):
        """The empty-shell diagnosis outranks a structural no-match, as with `query`."""
        r = await make_engine(StubFetcher(text="")).fetch(URL, path="$.items")
        assert "JavaScript-rendered" in r.notice

    async def test_a_path_with_a_query_is_refused(self, make_engine):
        with pytest.raises(FetchRefused, match="one at a time"):
            await make_engine(self._json()).fetch(URL, query="alpha", path="$.items")

    async def test_a_path_with_an_offset_is_refused(self, make_engine):
        with pytest.raises(FetchRefused, match="one at a time"):
            await make_engine(self._json()).fetch(URL, offset=40, path="$.items")

    async def test_an_unreadable_path_is_refused_before_anything_is_fetched(self, make_engine):
        """A selector nobody can read must not cost a fetch, let alone a fallback credit."""
        f = self._json()
        with pytest.raises(FetchRefused, match="`path` is not readable"):
            await make_engine(f).fetch(URL, path="$.items[?(@.id)]")
        assert f.calls == 0


class TestOffsetPaging:
    async def test_offset_is_forwarded_to_the_fallback(self, make_engine):
        f = StubFetcher()
        r = await make_engine(f).fetch(URL, offset=100)
        assert f.kwargs == [{"offset": 100, "max_chars": None}]
        assert r.offset == 100

    async def test_past_end_returns_a_notice_and_no_ladder(
        self, make_engine, log_records
    ):
        usage = UsageRecorder()
        f = StubFetcher()
        r = await make_engine(f, usage=usage).fetch(URL, offset=len(PAGE_TEXT) + 5)

        assert r.text == ""
        assert "past the end" in (r.notice or "")
        assert r.total_chars == len(PAGE_TEXT)
        assert r.offset == len(PAGE_TEXT) + 5
        assert f.calls == 1, "a refetch of a known-readable page must not bill a fallback"

        # A served call on both surfaces: the operator's line and the journal the
        # dashboard counts from.
        oks = [
            rec.record["extra"]
            for rec in log_records
            if rec.record["message"] == "fetch.ok"
        ]
        assert len(oks) == 1
        assert oks[0]["chars"] == len(PAGE_TEXT)
        assert oks[0]["fell_back"] is False
        (entry,) = cast("list[dict[str, object]]", usage.snapshot()["recent"])
        assert entry["tool"] == "fetch"
        assert entry["chars"] == len(PAGE_TEXT)
        assert entry["fallback"] is None

    async def test_query_and_offset_together_are_refused(self, make_engine):
        with pytest.raises(FetchFailed, match="not both"):
            await make_engine().fetch(URL, offset=10, query="some terms")

    async def test_offset_zero_stays_unset_on_the_response(self, make_engine):
        r = await make_engine().fetch(URL)
        assert r.offset is None

    async def test_a_short_tail_window_gets_no_empty_diagnosis(self, make_engine):
        """A few characters at the end of a page are a tail, not a JS shell."""
        f = StubFetcher()
        r = await make_engine(f).fetch(URL, offset=len(PAGE_TEXT) - 3)
        assert r.notice is None
        assert f.calls == 1


class TestSpecialTokenEscaping:
    """The page leaves escaped, counted on fetch.ok.

    The escape lands where every fallback's output converges -- after the ladder,
    in the engine -- so no fallback has to remember it, and the coordinates
    downstream (empty check, passage selection, past-end, the journal's chars)
    all read the same escaped text.
    """

    @staticmethod
    def _ok(records) -> dict[str, object]:
        (rec,) = [r for r in records if r.record["message"] == "fetch.ok"]
        return rec.record["extra"]

    async def test_page_text_is_escaped_and_counted(
        self, make_engine, log_records
    ):
        f = StubFetcher(text="the page says <|endoftext|> and nothing else")
        r = await make_engine(f).fetch(URL)
        assert r.text == f"the page says <{ZWSP}|endoftext|> and nothing else"
        assert self._ok(log_records)["sanitized"] == 1

    async def test_the_title_is_escaped_too(self, make_engine, log_records):
        f = StubFetcher(text=PAGE_TEXT, title="a title with [INST] in it")
        r = await make_engine(f).fetch(URL)
        assert r.title == f"a title with [{ZWSP}INST] in it"
        assert self._ok(log_records)["sanitized"] == 1

    async def test_a_clean_page_counts_zero(self, make_engine, log_records):
        await make_engine().fetch(URL)
        assert self._ok(log_records)["sanitized"] == 0

    async def test_a_past_end_response_escapes_the_title_and_counts(
        self, make_engine, log_records
    ):
        f = StubFetcher(title="a title with [INST] in it")
        r = await make_engine(f).fetch(URL, offset=len(PAGE_TEXT) + 5)
        assert r.text == ""
        assert r.title == f"a title with [{ZWSP}INST] in it"
        assert "past the end" in (r.notice or "")
        assert self._ok(log_records)["sanitized"] == 1

    async def test_query_matches_are_escaped_in_escaped_space(
        self, make_engine, log_records
    ):
        """A token in a matching passage does not move the coordinate system:
        offsets still locate their own text, measured in the escaped page."""
        first = "The walrus lives in <|arctic|>. " + "x" * 1600
        second = "The walrus eats clams. " + "y" * 1600
        text = f"{first}\n\n{second}"
        r = await make_engine(StubFetcher(text=text)).fetch(URL, query="walrus")

        assert r.text is None
        assert r.total_chars == len(text)
        escaped_first = f"The walrus lives in <{ZWSP}|arctic|>. " + "x" * 1600
        assert [m.offset for m in r.matches] == [0, len(escaped_first) + 2]
        assert r.matches[0].text.startswith(f"The walrus lives in <{ZWSP}|arctic|>.")
        assert "<|arctic|>" not in r.matches[0].text
        # The offset locates its own text, in the same escaped space.
        escaped_page = (
            f"The walrus lives in <{ZWSP}|arctic|>. "
            + "x" * 1600
            + "\n\n"
            + "The walrus eats clams. "
            + "y" * 1600
        )
        for m in r.matches:
            assert m.text == escaped_page[m.offset : m.offset + len(m.text)]
        assert self._ok(log_records)["sanitized"] == 1


class TestObservability:
    """What the fetch path records for the operator, event by event."""

    @staticmethod
    def _events(records, name):
        return [r.record["extra"] for r in records if r.record["message"] == name]

    async def test_a_url_is_logged_when_queries_are_opted_in(
        self, make_engine, log_records
    ):
        engine = make_engine(StubFetcher())
        engine.config.logging.log_queries = True
        await engine.fetch(URL)

        (fields,) = self._events(log_records, "fetch.ok")
        assert fields["url"] == repr(URL)

    async def test_an_empty_page_logs_the_empty_event(self, make_engine, log_records):
        await make_engine(StubFetcher(text="")).fetch(URL)

        (fields,) = self._events(log_records, "fetch.empty")
        assert fields["chars"] == 0

    async def test_a_readable_page_does_not_log_the_empty_event(
        self, make_engine, log_records
    ):
        await make_engine().fetch(URL)

        assert self._events(log_records, "fetch.empty") == []

    async def test_a_failure_logs_its_reason_and_retryability(
        self, make_engine, log_records
    ):
        engine = make_engine(StubFetcher(fail=ProviderError("fetch", "503")))
        with pytest.raises(FetchFailed):
            await engine.fetch(URL)

        (fields,) = self._events(log_records, "fetch.failed")
        assert fields["reason"] == "503"
        assert fields["retryable"] is True
        assert isinstance(fields["ms"], int) and fields["ms"] >= 0

    async def test_matches_replace_the_page_in_the_content_log(
        self, make_engine, log_records
    ):
        # Same two-paragraph walrus page as the offsets test above.
        first = "The walrus lives in the arctic. " + "x" * 1600
        second = "The walrus eats clams. " + "y" * 1600
        engine = make_engine(StubFetcher(text=f"{first}\n\n{second}"))
        engine.config.logging.log_content = True

        r = await engine.fetch(URL, query="walrus")

        (fields,) = self._events(log_records, "fetch.content")
        # The join is what the caller got; `safe` reprs it onto the line.
        assert fields["text"] == repr("\n\n".join(m.text for m in r.matches))


class TestUsageRecording:
    """The dashboard's fetch half: chars and the fallback that served them."""

    @staticmethod
    def _recent(usage: UsageRecorder) -> list[dict[str, object]]:
        return cast("list[dict[str, object]]", usage.snapshot()["recent"])

    async def test_a_success_records_chars_and_no_fallback(self, make_engine):
        usage = UsageRecorder()
        await make_engine(usage=usage).fetch(URL)

        (entry,) = self._recent(usage)
        assert entry["tool"] == "fetch"
        assert entry["chars"] == len(PAGE_TEXT)
        assert entry["fallback"] is None
        assert entry["error"] is None

    async def test_a_failure_records_the_class_and_no_chars(self, make_engine):
        usage = UsageRecorder()
        engine = make_engine(
            StubFetcher(fail=ProviderError("fetch", "503")), usage=usage
        )
        with pytest.raises(FetchFailed):
            await engine.fetch(URL)

        (entry,) = self._recent(usage)
        assert entry["error"] == "ProviderError"
        assert entry["chars"] == 0
        assert entry["fallback"] is None

    async def test_a_blocked_fetch_records_the_block_class(self, make_engine):
        usage = UsageRecorder()
        engine = make_engine(
            StubFetcher(fail=FetchBlocked("private address")), usage=usage
        )
        with pytest.raises(FetchFailed):
            await engine.fetch(URL)

        (entry,) = self._recent(usage)
        assert entry["error"] == "FetchBlocked"

    async def test_a_past_end_offset_records_the_call_it_billed(self, make_engine):
        """A past-end offset is served: the page was fetched to learn its length."""
        usage = UsageRecorder()
        await make_engine(usage=usage).fetch(URL, offset=len(PAGE_TEXT) + 5)

        (entry,) = self._recent(usage)
        assert entry["tool"] == "fetch"
        assert entry["chars"] == len(PAGE_TEXT)
        assert entry["fallback"] is None
        assert entry["error"] is None


_IMAGE_URL = "https://img.test/a.png"
_IMAGE_BODY = b"\x89PNG\r\n\x1a\n" + b"a png body"
_IMAGE = FetchedImage(media_type="image/png", body=_IMAGE_BODY)


class TestImagePages:
    """The engine's half of an image fetch: carried, journaled, left alone.

    The bytes themselves are `HttpFetcher`'s business; what is pinned here is the
    shape of the decision around them -- the base64 and the size reach the caller,
    no text field is filled, the ladder is never asked, and the operator's line
    says how many bytes left the process.
    """

    @staticmethod
    def _ok(log_records) -> dict[str, object]:
        return next(
            rec.record["extra"]
            for rec in log_records
            if rec.record["message"] == "fetch.ok"
        )

    async def test_the_image_is_carried_and_the_text_fields_stay_unset(
        self, make_engine
    ):
        r = await make_engine(StubFetcher(image=_IMAGE)).fetch(_IMAGE_URL)
        assert r.image is not None
        assert r.image.byte_count == len(_IMAGE_BODY)
        assert base64.b64decode(r.image.base64) == _IMAGE_BODY
        assert r.content_type == "image/png"
        assert r.text is None
        assert r.matches is None
        assert r.total_chars is None
        assert r.truncated is False

    async def test_the_notice_names_the_type_and_the_size(self, make_engine):
        r = await make_engine(StubFetcher(image=_IMAGE)).fetch(_IMAGE_URL)
        assert r.notice is not None
        assert "image/png image of 18 bytes returned as image bytes" in r.notice

    async def test_the_ladder_is_never_asked_for_an_image(self, make_engine):
        """A renderer and a scraper billed to find prose in a photograph: the failure mode.

        The emptiness gate that escalates reads an image's empty text as the
        JavaScript-shell symptom unless the image is checked for first.
        """
        fallback = StubFetcher()
        engine = FetchEngine(
            Config(
                providers={"serper": ProviderConfig()},
                policy=PolicyConfig(),
                fetch=FetchConfig(),
            ),
            StubFetcher(image=_IMAGE),
            fallbacks=[fallback],
        )
        r = await engine.fetch(_IMAGE_URL)
        assert fallback.calls == 0, "an image page has nothing for a fallback to fix"
        assert r.image is not None

    async def test_an_offset_past_the_end_of_nothing_addresses_nothing(self, make_engine):
        """Paging has no coordinate system here, and the image still arrives."""
        r = await make_engine(StubFetcher(image=_IMAGE)).fetch(_IMAGE_URL, offset=4000)
        assert r.image is not None
        assert r.offset is None
        assert r.matches is None

    async def test_the_call_is_journaled_as_a_call_with_no_text_chars(self, make_engine):
        usage = UsageRecorder()
        await make_engine(StubFetcher(image=_IMAGE), usage=usage).fetch(_IMAGE_URL)
        (entry,) = cast("list[dict[str, object]]", usage.snapshot()["recent"])
        assert entry["tool"] == "fetch"
        assert entry["chars"] == 0
        assert entry["fallback"] is None
        assert entry["error"] is None

    async def test_the_size_that_left_the_process_rides_fetch_ok(
        self, make_engine, log_records
    ):
        await make_engine(StubFetcher(image=_IMAGE)).fetch(_IMAGE_URL)
        assert self._ok(log_records)["bytes"] == len(_IMAGE_BODY)

    async def test_a_text_page_binds_no_image_field_at_all(self, make_engine, log_records):
        await make_engine().fetch(URL)
        assert "bytes" not in self._ok(log_records)


class TestImagesInAgentMode:
    """An `answer` walk reads text, so an image it meets is named, not carried."""

    async def test_the_bytes_are_left_out_and_the_notice_says_why(self, make_engine):
        r = await make_engine(StubFetcher(image=_IMAGE)).fetch(
            _IMAGE_URL, run="run-1", step=1
        )
        assert r.image is None
        assert r.notice is not None
        assert "`answer` builds its material from text" in r.notice

    async def test_the_fetch_is_still_journaled(self, make_engine):
        """The request went out, so the journal sees it, whether or not the bytes travel."""
        usage = UsageRecorder()
        await make_engine(StubFetcher(image=_IMAGE), usage=usage).fetch(
            _IMAGE_URL, run="run-1", step=1
        )
        (entry,) = cast("list[dict[str, object]]", usage.snapshot()["recent"])
        assert entry["tool"] == "fetch"
        assert entry["chars"] == 0

class TestTheRouteAsksForTheWalk:
    """The per-call argument the key cannot supply.

    ``fetch.auto_fallback`` is off, so an interactive read stops and reports. The
    `answer` plan has no caller between its steps to act on a list of names, so it
    asks for the walk on the call it makes: flipping the default must not quietly
    make ``answer`` read less on JavaScript-heavy sites. The ask is an argument on
    ``fetch``, not a reading of the ``run``/``step`` journal fields, which are
    observability and must not become load-bearing.
    """

    RENDERED = "The text a browser sees, served by the fallback the plan walked to. " * 4

    async def test_a_call_can_ask_for_the_walk_the_key_withholds(self, make_engine):
        local = StubFetcher(fail=ProviderError("fetch", "HTTP 403"))
        fallback = StubFetcher(name="crawl4ai", text=self.RENDERED)
        engine = make_engine(local, fallbacks=[fallback])

        response = await engine.fetch(URL, auto_fallback=True)

        assert response.text == self.RENDERED
        assert (local.calls, fallback.calls) == (1, 1)

    async def test_the_journal_fields_alone_never_open_the_walk(self, make_engine):
        """An `answer` line on the journal is not itself the ask for the walk."""
        local = StubFetcher(fail=ProviderError("fetch", "HTTP 403"))
        fallback = StubFetcher(name="crawl4ai", text=self.RENDERED)
        engine = make_engine(local, fallbacks=[fallback])

        with pytest.raises(FetchFailed):
            await engine.fetch(URL, run="run-1", step=1)

        assert fallback.calls == 0, "`run`/`step` stay observability"

    async def test_the_key_still_walks_everything_that_does_not_override(
        self, make_engine
    ):
        """On is the operator half of the switch, and it needs no per-call ask."""
        local = StubFetcher(fail=ProviderError("fetch", "HTTP 403"))
        fallback = StubFetcher(name="crawl4ai", text=self.RENDERED)
        engine = make_engine(
            local, fetch=FetchConfig(auto_fallback=True), fallbacks=[fallback]
        )

        response = await engine.fetch(URL)

        assert response.text == self.RENDERED
        assert (local.calls, fallback.calls) == (1, 1)


class TestNamedProvider:
    """``fetch(provider=...)``: one named route, and one refusal sentence.

    The shape is ``docs/reference/fetch-provider-selection.md`` §1: a name may
    come from anywhere, the three ways a name cannot serve collapse into a
    single refusal raised before anything is dispatched, and the sentence names
    what *is* available.
    """

    FALLBACK_TEXT = "Served by the named provider, not by the local reader. " * 8

    async def test_a_named_provider_serves_the_page_and_nothing_else_is_tried(
        self, make_engine
    ):
        """No local read first and no walk behind it: one attempt, as named.

        This is ``search``'s *a price named is a price paid*, and it is what
        makes ``provider`` a cost knob rather than only a retry knob.
        """
        local = StubFetcher()
        fallback = StubFetcher(name="crawl4ai", text=self.FALLBACK_TEXT)
        engine = make_engine(local, fallbacks=[fallback])
        response = await engine.fetch(URL, provider="crawl4ai")
        assert response.text == self.FALLBACK_TEXT
        assert (local.calls, fallback.calls) == (0, 1)

    async def test_the_named_fallback_is_the_fallback_the_call_is_journalled_to(
        self, make_engine
    ):
        """The journal prices the page against the name the caller chose."""
        usage = UsageRecorder()
        fallback = StubFetcher(name="crawl4ai", text=self.FALLBACK_TEXT)
        engine = make_engine(StubFetcher(), usage=usage, fallbacks=[fallback])
        await engine.fetch(URL, provider="crawl4ai")
        (entry,) = cast("list[dict[str, object]]", usage.snapshot()["recent"])
        assert entry["fallback"] == "crawl4ai"
        assert entry["error"] is None

    async def test_a_named_provider_that_fails_does_not_walk_the_others(
        self, make_engine
    ):
        """The failure stays the named provider's own.

        Walking behind a named route would bill a second name the caller never
        chose, and would hide which one failed.
        """
        local = StubFetcher()
        named = StubFetcher(
            name="scrappa", fail=ProviderError("scrappa", "rate limited")
        )
        other = StubFetcher(name="crawl4ai")
        engine = make_engine(local, fallbacks=[other, named])
        with pytest.raises(FetchFailed) as excinfo:
            await engine.fetch(URL, provider="scrappa")
        assert (local.calls, named.calls, other.calls) == (0, 1, 0)
        assert "scrappa: rate limited" in str(excinfo.value)

    async def test_an_unknown_name_is_refused_before_anything_is_dispatched(
        self, make_engine
    ):
        local = StubFetcher()
        fallback = StubFetcher(name="crawl4ai")
        engine = make_engine(local, fallbacks=[fallback])
        with pytest.raises(FetchRefused) as excinfo:
            await engine.fetch(URL, provider="scraper")
        assert (local.calls, fallback.calls) == (0, 0)
        message = str(excinfo.value)
        assert "Fetch provider 'scraper' is not enabled on this server." in message
        assert "Available: crawl4ai." in message
        assert "omit `provider` to read the page locally" in message

    async def test_a_search_name_is_refused_with_the_fetch_list(self, make_engine):
        """``serper`` is a provider name and not a fetch name.

        The two sets have different membership, and the list handed to a caller
        that named one of the wrong set is the fetch list.
        """
        engine = make_engine(StubFetcher(), fallbacks=[StubFetcher(name="scrappa")])
        with pytest.raises(FetchRefused) as excinfo:
            await engine.fetch(URL, provider="serper")
        assert "Available: scrappa." in str(excinfo.value)

    async def test_no_configured_provider_says_so_rather_than_listing_nothing(
        self, make_engine
    ):
        with pytest.raises(FetchRefused) as excinfo:
            await make_engine().fetch(URL, provider="crawl4ai")
        message = str(excinfo.value)
        assert "No other fetch provider is configured on this server." in message
        assert "Available:" not in message

    async def test_the_three_ways_a_name_cannot_serve_refuse_alike(self, make_engine):
        """Unknown to the registry, never built for want of a key or a URL, and
        excluded by the permission set: the engine sees the built names and
        nothing else, so one sentence answers all three.
        """
        engine = make_engine(StubFetcher(), fallbacks=[StubFetcher(name="crawl4ai")])
        unknown = self._refusal(engine, "scraper")
        unbuilt = self._refusal(engine, "scrappa")
        assert unknown.replace("scraper", "scrappa") == unbuilt

    @staticmethod
    def _refusal(engine: FetchEngine, name: str) -> str:
        with pytest.raises(FetchRefused) as excinfo:
            engine.resolve(name)
        return str(excinfo.value)


class TestPrimaryRoute:
    """``fetch.primary``: the operator choosing which route an unnamed fetch leads with.

    The key exists because the local read leaves this server's own IP and a plain
    HTTP client, which more bot walls recognise than a provider's network. With a
    fallback as primary, the local read is not a last resort hiding behind the
    walk: it is gone from the unnamed route, and the walk behind the primary is
    the ladder minus the primary, so no name is tried twice.
    """

    PRIMARY_TEXT = "Served by the configured primary route, not by this server. " * 8
    RENDERED = "Rendered by the fallback behind the primary route. " * 8

    async def test_the_named_primary_serves_and_the_local_reader_is_never_dialed(
        self, make_engine
    ):
        """The whole point of the key: the page never leaves this server's own IP."""
        local = StubFetcher()
        primary = StubFetcher(name="jina", text=self.PRIMARY_TEXT)
        engine = make_engine(local, fetch=FetchConfig(primary="jina"), fallbacks=[primary])

        response = await engine.fetch(URL)

        assert response.text == self.PRIMARY_TEXT
        assert (local.calls, primary.calls) == (0, 1)
        assert response.notice is None, "a primary that works is not a fallback event"

    async def test_the_primary_is_the_route_the_call_is_journalled_to(self, make_engine):
        """A page the primary served is attributed to it, so its price can land.

        Same rule as a named route and a walked one: the journal names the route
        that made the call, and only the local reader journals nothing.
        """
        usage = UsageRecorder()
        primary = StubFetcher(name="jina", text=self.PRIMARY_TEXT)
        engine = make_engine(
            StubFetcher(), usage=usage, fetch=FetchConfig(primary="jina"), fallbacks=[primary]
        )
        await engine.fetch(URL)

        (entry,) = cast("list[dict[str, object]]", usage.snapshot()["recent"])
        assert entry["fallback"] == "jina"
        assert entry["error"] is None

    async def test_a_failing_primary_walks_the_ladder_behind_it_once(self, make_engine):
        """The walk is the ladder minus the primary: `jina` is tried once, not twice."""
        local = StubFetcher()
        primary = StubFetcher(name="jina", fail=ProviderError("jina", "HTTP 403"))
        behind = StubFetcher(name="scrappa", text=self.RENDERED)
        engine = make_engine(
            local,
            fetch=FetchConfig(
                primary="jina", fallback=["jina", "scrappa"], auto_fallback=True
            ),
            fallbacks=[primary, behind],
        )

        response = await engine.fetch(URL)

        assert response.text == self.RENDERED
        assert (local.calls, primary.calls, behind.calls) == (0, 1, 1)
        assert response.notice == "jina failed (HTTP 403); refetched via scrappa"

    async def test_a_failing_primary_with_the_walk_off_offers_the_ladder_only(
        self, make_engine
    ):
        """The withheld walk hands over the names, and the primary is not among them.

        Offering the route that just failed would send the caller back to the
        provider the operator already watched fail.
        """
        primary = StubFetcher(name="jina", fail=ProviderError("jina", "HTTP 403"))
        behind = StubFetcher(name="scrappa", text=self.RENDERED)
        engine = make_engine(
            StubFetcher(),
            fetch=FetchConfig(primary="jina", fallback=["jina", "scrappa"]),
            fallbacks=[primary, behind],
        )

        with pytest.raises(FetchFailed) as excinfo:
            await engine.fetch(URL)

        message = str(excinfo.value)
        assert " Other configured fetch providers: scrappa." in message
        assert "jina" not in message.split("Other configured")[1]
        assert behind.calls == 0

    async def test_a_nearly_empty_primary_names_itself_and_offers_the_ladder(
        self, make_engine
    ):
        """The emptiness sentence names the route that ran, not "the local fetcher"."""
        primary = StubFetcher(name="jina", text="nav only")
        behind = StubFetcher(name="crawl4ai", text=self.RENDERED)
        engine = make_engine(
            StubFetcher(),
            fetch=FetchConfig(primary="jina", fallback=["jina", "crawl4ai"]),
            fallbacks=[primary, behind],
        )

        response = await engine.fetch(URL)

        assert "Almost no readable text came back from `jina`." in (
            response.notice or ""
        )
        assert "Other configured fetch providers: crawl4ai." in (response.notice or "")

    async def test_the_primary_can_still_be_named_by_a_caller(self, make_engine):
        """Naming the route a server already leads with is not a refusal.

        The built fallbacks are what `resolve` offers, primary included: a caller
        asking for it gets the one attempt it asked for.
        """
        primary = StubFetcher(name="jina", text=self.PRIMARY_TEXT)
        engine = make_engine(
            StubFetcher(), fetch=FetchConfig(primary="jina"), fallbacks=[primary]
        )
        response = await engine.fetch(URL, provider="jina")
        assert response.text == self.PRIMARY_TEXT
        assert primary.calls == 1

    async def test_the_refusal_names_the_default_route_not_a_local_read(
        self, make_engine
    ):
        """With a provider leading, omitting `provider` is not a local read.

        The local reader has no name a caller can ask for, so the sentence has to
        describe the route rather than promise a page read no parameter reaches.
        """
        engine = make_engine(
            StubFetcher(),
            fetch=FetchConfig(primary="jina", fallback=["jina"]),
            fallbacks=[StubFetcher(name="jina")],
        )
        with pytest.raises(FetchRefused) as excinfo:
            await engine.fetch(URL, provider="scraper")
        assert "or omit `provider` to use this server's default route." in str(
            excinfo.value
        )

    def test_a_primary_this_engine_was_not_handed_refuses_construction(
        self, make_engine
    ):
        """The defensive twin of `server.main`'s refusal.

        Silently reading locally instead would dial from this server's own IP
        against a config that said not to.
        """
        with pytest.raises(ValueError, match="which this deployment did not build"):
            make_engine(StubFetcher(), fetch=FetchConfig(primary="jina"), fallbacks=[])
