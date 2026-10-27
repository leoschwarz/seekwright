"""The fallbacks of the fetch ladder.

Two questions: does the engine reach for the fallbacks in the cases that justify
them (a failed fetch, and an empty extraction -- the JavaScript-rendered
page), and does `ScrappaFetcher` stay inside the SSRF guard even though the
egress happens on someone else's machine. `Crawl4aiFetcher` has its own module;
this is the ladder's behaviour, exercised through stubs.
"""

from typing import Any, cast

import httpx
import pytest
from pydantic import ValidationError

from seekwright.config import Config, FetchConfig, PolicyConfig, ProviderConfig
from seekwright.engine import FetchEngine, FetchFailed
from seekwright.fetcher import (
    KNOWN_FALLBACKS,
    UNCAPPED,
    FetchBlocked,
    FetchedPage,
    JinaFetcher,
    ScrappaFetcher,
)
from seekwright.providers.base import ProviderError, QuotaExhausted
from seekwright.usage import UsageRecorder

URL = "https://example.com/article"

# Both must clear FetchConfig.min_text_chars, or the engine escalates to the paid
# fallback.
PAGE_TEXT = (
    "The page body. Long enough to be a real extraction rather than the nav "
    "stub a JavaScript-rendered page leaves behind, because that distinction "
    "is exactly what decides whether the paid fallback fires. Comfortably "
    "clear of the threshold rather than a character over it, so that retuning "
    "the default does not quietly turn these tests into the empty case."
)
RENDERED_TEXT = (
    "The text a browser sees. This is what the paid fallback returns once the page "
    "has been rendered, and it is long enough that the engine treats it as a "
    "real page rather than escalating a second time. Also comfortably clear of "
    "the threshold, for the same reason as PAGE_TEXT above."
)

SCRAPED_DATA: dict[str, Any] = {
    "title": "A Rendered Page",
    "description": "…",
    "body_text": "The text a browser sees.",
    "links": [],
    "html": None,
}

SCRAPED: dict[str, Any] = {
    "success": True,
    "site_status_code": 200,
    "url": URL,
    "final_url": "https://example.com/article?utm=1",
    "data": SCRAPED_DATA,
}


class StubFetcher:
    # A fallback that declares no price unless a test hands it one: the local
    # fallback's shape, so nothing lands on the journal line for a page it serves.
    cost_per_1k: float | None = None

    def __init__(self, name="fetch", *, fail=None, text=PAGE_TEXT, cost_per_1k=None):
        self.name = name
        self.cost_per_1k = cost_per_1k
        self.calls = 0
        self.kwargs: list[dict[str, object]] = []
        self._fail = fail
        self._text = text

    async def fetch(
        self, url: str, *, offset: int = 0, max_chars: int | None = None
    ) -> FetchedPage:
        self.calls += 1
        self.kwargs.append({"offset": offset, "max_chars": max_chars})
        if self._fail:
            raise self._fail
        return FetchedPage(
            url=url,
            title="A Page",
            text=self._text,
            content_type="text/html",
            status_code=200,
            truncated=False,
            total_chars=len(self._text),
        )

    async def aclose(self) -> None:
        return None


@pytest.fixture
def make_engine():
    def _make(fetcher, fallbacks=None, usage: UsageRecorder | None = None, **fetch_kw):
        # Everything above the opt-in classes below is the walk's behaviour, and
        # the walk is a key now: `fetch.auto_fallback` is off by default, so a
        # class that studies the ladder asks for it here rather than each test
        # re-adding the switch. The opt-in class passes it back off and leaves
        # the shipped default alone.
        fetch_kw.setdefault("auto_fallback", True)
        cfg = Config(
            providers={"serper": ProviderConfig()},
            policy=PolicyConfig(),
            fetch=FetchConfig(**fetch_kw),
        )
        return FetchEngine(cfg, fetcher, fallbacks or [], usage=usage)

    return _make


class TestEngineFallback:
    async def test_failed_primary_is_retried_on_the_fallback(self, make_engine):
        fallback = StubFetcher("scrappa", text=RENDERED_TEXT)
        engine = make_engine(
            StubFetcher(fail=ProviderError("fetch", "HTTP 403")), [fallback]
        )

        r = await engine.fetch(URL)

        assert r.text == RENDERED_TEXT
        assert fallback.calls == 1
        assert "refetched via scrappa" in (r.notice or "")

    async def test_empty_extraction_is_retried_on_the_fallback(self, make_engine):
        # The case the fallback exists for: the primary succeeded, but a
        # client-rendered shell has no text in it.
        fallback = StubFetcher("scrappa", text=RENDERED_TEXT)
        engine = make_engine(StubFetcher(text="   "), [fallback])

        r = await engine.fetch(URL)

        assert r.text == RENDERED_TEXT
        assert fallback.calls == 1
        assert "no readable text" in (r.notice or "")

    async def test_a_good_page_never_pays_for_the_fallback(self, make_engine):
        fallback = StubFetcher("scrappa")
        r = await make_engine(StubFetcher(), [fallback]).fetch(URL)

        assert r.text == PAGE_TEXT
        assert fallback.calls == 0, "a successful fetch must not be billed twice"

    async def test_the_fallback_is_billed_at_most_once(self, make_engine):
        # The fallback ran because the primary failed, and came back empty
        # too. Asking it again would buy the same empty page a second time.
        fallback = StubFetcher("scrappa", text="")
        engine = make_engine(
            StubFetcher(fail=ProviderError("fetch", "HTTP 403")), [fallback]
        )

        r = await engine.fetch(URL)

        assert fallback.calls == 1
        assert "no readable text could be extracted" in (r.notice or "")

    async def test_a_failing_fallback_reports_the_original_failure(self, make_engine):
        engine = make_engine(
            StubFetcher(fail=ProviderError("fetch", "HTTP 403")),
            [StubFetcher("scrappa", fail=QuotaExhausted("scrappa"))],
        )

        with pytest.raises(FetchFailed) as exc:
            await engine.fetch(URL)
        # "scrappa: quota exhausted" says nothing about the page that was asked
        # for; the original failure is the one worth surfacing.
        assert "403" in str(exc.value)
        assert "quota" not in str(exc.value)

    async def test_without_a_fallback_the_old_advice_stands(self, make_engine):
        r = await make_engine(StubFetcher(text="   ")).fetch(URL)
        assert "no readable text could be extracted" in (r.notice or "")

    async def test_a_failed_fetch_at_a_nonzero_offset_still_reaches_the_ladder(
        self, make_engine
    ):
        fallback = StubFetcher("scrappa", text=RENDERED_TEXT)
        engine = make_engine(
            StubFetcher(fail=ProviderError("fetch", "HTTP 403")), [fallback]
        )

        r = await engine.fetch(URL, offset=100)

        assert fallback.kwargs == [{"offset": 100, "max_chars": None}]
        assert r.offset == 100
        assert "refetched via scrappa" in (r.notice or "")
        assert fallback.calls == 1

    async def test_a_query_failure_hands_the_fallback_an_uncapped_read(
        self, make_engine
    ):
        text = "The walrus lives on the ice. " + "x" * 300
        fallback = StubFetcher("scrappa", text=text)
        engine = make_engine(
            StubFetcher(fail=ProviderError("fetch", "HTTP 403")), [fallback]
        )

        r = await engine.fetch(URL, query="walrus")

        assert fallback.kwargs == [{"offset": 0, "max_chars": UNCAPPED}]
        assert r.matches, "the fallback's page had a matching passage"
        assert r.text is None


class TestLadder:
    """Two fallbacks: the renderer (free, self-hosted) in front of the paid one.

    The order is the policy. crawl4ai costs nothing but a browser round trip,
    Scrappa costs a credit, so the walk descends only while the current page
    is still empty, and each fallback gets at most one attempt.
    """

    async def test_a_failed_primary_reaches_the_free_fallback_first(self, make_engine):
        renderer = StubFetcher("crawl4ai", text=RENDERED_TEXT)
        paid = StubFetcher("scrappa", text=RENDERED_TEXT)
        engine = make_engine(
            StubFetcher(fail=ProviderError("fetch", "HTTP 403")), [renderer, paid]
        )

        r = await engine.fetch(URL)

        assert r.text == RENDERED_TEXT
        assert renderer.calls == 1
        assert paid.calls == 0, "a page the free fallback read must not be paid for"
        assert "refetched via crawl4ai" in (r.notice or "")

    async def test_an_empty_renderer_page_still_reaches_the_paid_fallback(
        self, make_engine
    ):
        # The emptiness gate is not one-shot: an empty crawl4ai render still
        # escalates.
        renderer = StubFetcher("crawl4ai", text="   ")
        paid = StubFetcher("scrappa", text=RENDERED_TEXT)
        engine = make_engine(StubFetcher(text="   "), [renderer, paid])

        r = await engine.fetch(URL)

        assert r.text == RENDERED_TEXT
        assert paid.calls == 1
        assert "refetched via scrappa" in (r.notice or "")

    async def test_a_page_empty_at_the_bottom_of_the_ladder_stops(
        self, make_engine
    ):
        # Scrappa is last: a page it also returned empty is not worth another
        # call, because there is nothing left to call.
        renderer = StubFetcher("crawl4ai", text="   ")
        paid = StubFetcher("scrappa", text="   ")
        engine = make_engine(StubFetcher(text="   "), [renderer, paid])

        r = await engine.fetch(URL)

        assert renderer.calls == 1 and paid.calls == 1
        assert "no readable text could be extracted" in (r.notice or "")

    async def test_a_failing_fallback_does_not_stop_the_walk(self, make_engine):
        renderer = StubFetcher("crawl4ai", fail=ProviderError("crawl4ai", "HTTP 502"))
        paid = StubFetcher("scrappa", text=RENDERED_TEXT)
        engine = make_engine(
            StubFetcher(fail=ProviderError("fetch", "HTTP 403")), [renderer, paid]
        )

        r = await engine.fetch(URL)

        assert r.text == RENDERED_TEXT
        assert paid.calls == 1
        assert "refetched via scrappa" in (r.notice or "")

    async def test_when_everything_fails_the_first_failure_is_reported(
        self, make_engine, log_records
    ):
        renderer = StubFetcher("crawl4ai", fail=ProviderError("crawl4ai", "HTTP 502"))
        paid = StubFetcher("scrappa", fail=QuotaExhausted("scrappa"))
        engine = make_engine(
            StubFetcher(fail=ProviderError("fetch", "HTTP 403")), [renderer, paid]
        )

        with pytest.raises(FetchFailed) as exc:
            await engine.fetch(URL)
        assert "403" in str(exc.value)
        assert "quota" not in str(exc.value)
        # The walk ran, so the caller has already had the choice it is owed: what
        # it needs is the list of who was asked and lost.
        assert "Fallbacks also failed: crawl4ai, scrappa." in str(exc.value)
        assert renderer.calls == 1 and paid.calls == 1

        # Each fallback's own failure is logged, with the reason that fallback was reached.
        failures = [
            r.record["extra"]
            for r in log_records
            if r.record["message"] == "fetch.fallback_failed"
        ]
        assert [(f["fallback"], f["reason"]) for f in failures] == [
            ("crawl4ai", "HTTP 502"),
            ("scrappa", "quota exhausted"),
        ]
        assert failures[0]["original_reason"] == "HTTP 403"
        assert failures[1]["original_reason"] == "HTTP 502"

    async def test_an_empty_fallback_page_survives_a_later_failure(self, make_engine):
        # A page in hand is kept: the response stays crawl4ai's, not an error
        # naming the primary.
        renderer = StubFetcher("crawl4ai", text="   ")
        paid = StubFetcher("scrappa", fail=QuotaExhausted("scrappa"))
        engine = make_engine(
            StubFetcher(fail=ProviderError("fetch", "HTTP 403")), [renderer, paid]
        )

        r = await engine.fetch(URL)

        assert r.text == "   "
        assert "refetched via crawl4ai" in (r.notice or "")
        assert "no readable text could be extracted" in (r.notice or "")

    async def test_an_empty_renderer_page_reaches_the_keyless_fallback_before_the_paid_one(
        self, make_engine
    ):
        """The keyless fallback is the middle one, and the order is the policy.

        A page the renderer could not read goes to the free hosted fallback before
        anything is billed -- the same argument that puts the renderer first,
        applied one fallback down.
        """
        renderer = StubFetcher("crawl4ai", text="   ")
        keyless = StubFetcher("jina", text=RENDERED_TEXT)
        paid = StubFetcher("scrappa", text=RENDERED_TEXT)
        engine = make_engine(StubFetcher(text="   "), [renderer, keyless, paid])

        r = await engine.fetch(URL)

        assert r.text == RENDERED_TEXT
        assert keyless.calls == 1
        assert paid.calls == 0, "a page the keyless fallback read must not be paid for"
        assert "refetched via jina" in (r.notice or "")

    async def test_a_failing_keyless_fallback_does_not_stop_the_walk(self, make_engine):
        """Its rate limit is a fallback failure like any other: the walk moves on."""
        renderer = StubFetcher("crawl4ai", text="   ")
        keyless = StubFetcher("jina", fail=QuotaExhausted("jina", "rate limited"))
        paid = StubFetcher("scrappa", text=RENDERED_TEXT)
        engine = make_engine(StubFetcher(text="   "), [renderer, keyless, paid])

        r = await engine.fetch(URL)

        assert r.text == RENDERED_TEXT
        assert keyless.calls == 1 and paid.calls == 1
        assert "refetched via scrappa" in (r.notice or "")

    async def test_a_good_page_never_reaches_any_fallback(self, make_engine):
        renderer = StubFetcher("crawl4ai")
        paid = StubFetcher("scrappa")
        engine = make_engine(StubFetcher(), [renderer, paid])

        r = await engine.fetch(URL)

        assert r.text == PAGE_TEXT
        assert renderer.calls == 0 and paid.calls == 0
        assert r.notice is None


class TestAlmostEmptyIsEmpty:
    """A page that extracts to a nav stub has to count as having no content.

    Measured on the real thing: an ikea.com product page came back as the 20
    characters "Skip to product list". Under a `not text.strip()` test that is a
    successful fetch, so the paid fallback never fired and the caller was told
    nothing was wrong -- it just received a page with no page in it.
    """

    # What IKEA actually returned.
    NAV_STUB = "Skip to product list"

    async def test_a_nav_stub_is_retried_on_the_fallback(self, make_engine):
        fallback = StubFetcher("scrappa", text=RENDERED_TEXT)
        engine = make_engine(StubFetcher(text=self.NAV_STUB), [fallback])

        r = await engine.fetch(URL)

        assert r.text == RENDERED_TEXT
        assert fallback.calls == 1

    async def test_a_page_over_the_threshold_is_left_alone(self, make_engine):
        fallback = StubFetcher("scrappa")
        engine = make_engine(StubFetcher(text="x" * 200), [fallback], min_text_chars=200)

        r = await engine.fetch(URL)

        assert r.text == "x" * 200
        assert fallback.calls == 0, "the threshold is a floor, not a target"
        assert r.notice is None

    async def test_one_character_under_is_empty(self, make_engine):
        fallback = StubFetcher("scrappa", text=RENDERED_TEXT)
        engine = make_engine(StubFetcher(text="x" * 199), [fallback], min_text_chars=200)

        assert (await engine.fetch(URL)).text == RENDERED_TEXT
        assert fallback.calls == 1

    async def test_the_stub_still_warns_without_a_fallback(self, make_engine):
        # The notice is not conditional on there being somewhere to escalate to.
        r = await make_engine(StubFetcher(text=self.NAV_STUB)).fetch(URL)

        assert r.text == self.NAV_STUB
        assert "almost no readable text" in (r.notice or "")

    async def test_zero_restores_the_old_boundary(self, make_engine):
        # The escape hatch has to mean "how it behaved before", which is only
        # true if a literally blank page stays empty at every setting.
        fallback = StubFetcher("scrappa", text=RENDERED_TEXT)
        engine = make_engine(StubFetcher(text=self.NAV_STUB), [fallback], min_text_chars=0)

        r = await engine.fetch(URL)

        assert r.text == self.NAV_STUB
        assert fallback.calls == 0
        assert r.notice is None

    async def test_a_blank_page_is_empty_even_at_zero(self, make_engine):
        fallback = StubFetcher("scrappa", text=RENDERED_TEXT)
        engine = make_engine(StubFetcher(text="   "), [fallback], min_text_chars=0)

        assert (await engine.fetch(URL)).text == RENDERED_TEXT
        assert fallback.calls == 1


class TestTheWalkIsOptIn:
    """`fetch.auto_fallback` is off: the caller is handed the choice, not the walk.

    The two moves a caller can make with a list of names -- name one of them, or
    conclude the page has nothing -- are the two a walk that already happened
    leaves it no way to make. So the default hands back the choice, and these
    tests pass the key off so that what they read is the shipped default rather
    than an override.
    """

    NAV_STUB = "Skip to product list"

    async def test_a_failed_read_never_reaches_a_fallback(self, make_engine):
        fallback = StubFetcher("scrappa", text=RENDERED_TEXT)
        engine = make_engine(
            StubFetcher(fail=ProviderError("fetch", "HTTP 403")),
            [fallback],
            auto_fallback=False,
        )

        with pytest.raises(FetchFailed):
            await engine.fetch(URL)

        assert fallback.calls == 0, "the walk is the caller's to ask for, not the read's"

    async def test_the_failure_names_the_configured_providers(self, make_engine):
        engine = make_engine(
            StubFetcher(fail=ProviderError("fetch", "HTTP 403")),
            [StubFetcher("crawl4ai"), StubFetcher("scrappa")],
            auto_fallback=False,
        )

        with pytest.raises(FetchFailed) as raised:
            await engine.fetch(URL)

        message = str(raised.value)
        assert "Fetch failed - fetch: HTTP 403." in message
        assert "Other configured fetch providers: crawl4ai, scrappa." in message
        assert (
            "Retry once with `provider` set to one of those before concluding "
            "the page cannot be read." in message
        )
        # One retry instruction, not two: the sentence naming a provider to retry
        # on replaces the one that says to wait and try the same read again.
        assert "Retry shortly" not in message

    async def test_a_near_empty_read_comes_back_with_its_page(self, make_engine):
        fallback = StubFetcher("scrappa", text=RENDERED_TEXT)
        engine = make_engine(
            StubFetcher(text=self.NAV_STUB), [fallback], auto_fallback=False
        )

        r = await engine.fetch(URL)

        assert r.text == self.NAV_STUB, "the page is the answer, not a walk around it"
        assert fallback.calls == 0
        notice = r.notice or ""
        assert "Almost no readable text came back from the local fetcher." in notice
        assert "Other configured fetch providers: scrappa." in notice
        assert "needs a browser, not a second try at the same reader" in notice

    async def test_nothing_configured_offers_no_choice_it_could_not_have_made(
        self, make_engine
    ):
        """No ladder, so no list: the wording this tree already had is the advice.

        The recovery sentence *is* a list. With no provider configured there is
        nothing to name, so a caller told to set `provider` "to one of those" has
        been handed an instruction it cannot follow -- and the failure keeps the
        advice it has carried since before the walk had a switch.
        """
        engine = make_engine(
            StubFetcher(fail=ProviderError("fetch", "HTTP 403")), auto_fallback=False
        )

        with pytest.raises(FetchFailed) as raised:
            await engine.fetch(URL)

        message = str(raised.value)
        assert "Other configured fetch providers" not in message
        assert "Retry shortly, or search for the content." in message


class TestConfig:
    def test_no_fallback_by_default(self):
        assert FetchConfig().fallback is None

    def test_the_walk_is_opt_in_by_default(self):
        # The default is the decision, not a placeholder.
        assert FetchConfig().auto_fallback is False

    def test_the_empty_threshold_has_a_default(self):
        # Pinned because raising it above 0 is a change in what gets billed:
        # every page under the bar now spends a fallback credit.
        assert FetchConfig().min_text_chars == 200

    def test_a_misspelled_fallback_is_a_startup_error(self):
        # A fallback the registry does not know is refused, and the error prints the registry:
        # the `Literal` this replaced could only widen, and named nothing in the message.
        # Validated the way TOML reaches it, from a dict.
        with pytest.raises(ValidationError) as exc:
            FetchConfig.model_validate({"fallback": ["scrapa"]})

        # The message prints the registry, so it names every fallback the tree ships rather than
        # the three this assertion was written against.
        assert f"supported: {', '.join(sorted(KNOWN_FALLBACKS))}" in str(exc.value)

    def test_a_bare_string_fallback_is_a_startup_error(self):
        # A bare-string `fallback` predates the list ladder, and stays a startup
        # error.
        with pytest.raises(ValidationError):
            FetchConfig.model_validate({"fallback": "scrappa"})

    def test_the_ladder_is_accepted_in_order(self):
        cfg = FetchConfig.model_validate({"fallback": ["crawl4ai", "scrappa"]})
        assert cfg.fallback == ["crawl4ai", "scrappa"]

    def test_the_keyless_fallback_is_accepted_in_the_ladder(self):
        """The shape the decision names: free renderer, keyless hosted fallback,
        paid last."""
        cfg = FetchConfig.model_validate(
            {"fallback": ["crawl4ai", "jina", "scrappa"]}
        )
        assert cfg.fallback == ["crawl4ai", "jina", "scrappa"]

    def test_a_late_paid_fallback_is_still_an_error_with_the_keyless_one_in(self):
        # `jina` is free, so it buys no exemption for `scrappa`: paid is last,
        # whatever else the ladder names.
        with pytest.raises(ValidationError):
            FetchConfig.model_validate({"fallback": ["crawl4ai", "scrappa", "jina"]})

    def test_the_keyless_fallback_may_be_the_whole_ladder(self):
        # No prerequisite, so there is nothing to leave it inert -- the one
        # ladder that needs no other config key at all.
        cfg = FetchConfig.model_validate({"fallback": ["jina"]})
        assert cfg.fallback == ["jina"]


class TestTheAllowList:
    """The third-party fallbacks are gated by the permission set.

    `scrappa` is a provider name, so the allow-list reaches the paid fallback
    through a name the operator already writes. The keyless `jina` fallback is a
    third party too and is gated the same way -- a fallback outside the permission
    set is **not built**, so there is no object left that could fire and nothing
    can be billed (docs/reference/allow-list.md, site 7).

    `jina` is not a provider name, so `PERMITTED_FETCH_NAMES` is what lets a
    declared set name it: a set that lists `jina` builds the keyless fallback, a
    set that does not still drops it, and an unset set still builds it. Naming
    it admits the fallback and enables nothing on the search side.
    """

    @staticmethod
    def _config(permitted: list[str] | None) -> Config:
        return Config(
            providers={"scrappa": ProviderConfig(), "serper": ProviderConfig()},
            permitted_providers=permitted,
            fetch=FetchConfig(enabled=True, fallback=["scrappa"]),
        )

    @staticmethod
    def _keyless_config(permitted: list[str] | None) -> Config:
        return Config(
            providers={"serper": ProviderConfig()},
            permitted_providers=permitted,
            fetch=FetchConfig(enabled=True, fallback=["jina"]),
        )

    async def test_an_unpermitted_fallback_is_not_built_and_never_fires(
        self, monkeypatch
    ):
        from seekwright import factory

        built: list[str] = []

        def recording(*args, **kwargs):
            built.append("scrappa")
            return ScrappaFetcher(*args, **kwargs)

        monkeypatch.setenv("SEEKWRIGHT_SCRAPPA_API_KEY", "k")
        # Patched in `fetcher`, not in `engine`: the fallback's builder in the registry
        # resolves the class from its own module globals when it runs.
        monkeypatch.setattr("seekwright.fetcher.ScrappaFetcher", recording)
        cfg = self._config(["serper"])

        fetcher, fallbacks = await factory.build_fetch_stack(cfg)
        try:
            assert fallbacks == [], "the fallback is not built, so it cannot fire"
            assert built == [], "the paid adapter is never even constructed"

            # And a fetch that fails locally reaches no fallback at all: the ladder
            # is empty, so no request can reach Scrappa's endpoint.
            engine = FetchEngine(
                cfg,
                StubFetcher(fail=ProviderError("fetch", "HTTP 403")),
                fallbacks,
            )
            with pytest.raises(FetchFailed):
                await engine.fetch(URL)
            assert built == []
        finally:
            assert fetcher is not None
            await fetcher.aclose()

    async def test_a_permitted_fallback_is_still_built(self, monkeypatch):
        """The control for the assertion above: the same config with `scrappa`
        permitted builds it, so the absence there is the allow-list at work
        rather than a config typo or a missing key."""
        from seekwright import factory

        monkeypatch.setenv("SEEKWRIGHT_SCRAPPA_API_KEY", "k")
        cfg = self._config(["serper", "scrappa"])

        fetcher, fallbacks = await factory.build_fetch_stack(cfg)
        try:
            assert [fallback.name for fallback in fallbacks] == ["scrappa"]
        finally:
            assert fetcher is not None
            await fetcher.aclose()
            for fallback in fallbacks:
                await fallback.aclose()

    async def test_an_unpermitted_keyless_fallback_is_not_built(self, monkeypatch):
        """The keyless fallback gets `scrappa`'s treatment, not an exemption.

        It is a third party, so it is the second fallback that needs an entry in
        the permission set -- and because it is not a provider name, a declared
        set excludes it unless it names `jina`. Reported in `--check` (site 9),
        silent in the ladder, and absent from the stack either way.
        """
        from seekwright import factory

        built: list[str] = []

        def recording(*args, **kwargs):
            built.append("jina")
            return JinaFetcher(*args, **kwargs)

        # Patched in `fetcher`, not in `engine`: the fallback's builder in the registry
        # resolves the class from its own module globals when it runs.
        monkeypatch.setattr("seekwright.fetcher.JinaFetcher", recording)
        cfg = self._keyless_config(["serper"])

        fetcher, fallbacks = await factory.build_fetch_stack(cfg)
        try:
            assert fallbacks == [], "the fallback is not built, so it cannot fire"
            assert built == [], "the fallback is never even constructed"

            engine = FetchEngine(
                cfg,
                StubFetcher(fail=ProviderError("fetch", "HTTP 403")),
                fallbacks,
            )
            with pytest.raises(FetchFailed):
                await engine.fetch(URL)
            assert built == [], "an empty ladder reaches no third party at all"
        finally:
            assert fetcher is not None
            await fetcher.aclose()

    async def test_a_declared_set_that_lists_jina_builds_the_keyless_fallback(self):
        """The gap the asymmetry left: a declared set that wants the keyless
        fallback names it, and `PERMITTED_FETCH_NAMES` admits that name."""
        from seekwright import factory

        cfg = self._keyless_config(["serper", "jina"])

        fetcher, fallbacks = await factory.build_fetch_stack(cfg)
        try:
            assert [fallback.name for fallback in fallbacks] == ["jina"]
        finally:
            assert fetcher is not None
            await fetcher.aclose()
            for fallback in fallbacks:
                await fallback.aclose()

    async def test_an_unset_permission_set_still_builds_the_keyless_fallback(self):
        """The control: unset is permissive, so the absence above is the
        allow-list at work rather than a typo or a missing prerequisite."""
        from seekwright import factory

        cfg = self._keyless_config(None)

        fetcher, fallbacks = await factory.build_fetch_stack(cfg)
        try:
            assert [fallback.name for fallback in fallbacks] == ["jina"]
        finally:
            assert fetcher is not None
            await fetcher.aclose()
            for fallback in fallbacks:
                await fallback.aclose()

    async def test_the_built_paid_fallback_carries_the_declared_price(self, monkeypatch):
        """The fallback declares its own price, and `fetch.cost_per_1k` corrects it.

        The price is resolved once, at construction, on the same idiom every
        provider's is: the fallback object the engine prices a page from is the one
        that carries the figure, so config cannot disagree with what was spent.
        The default comes off the fallback's class rather than off a figure in the
        factory, which is what lets a second priced fallback price its own pages.
        """
        from seekwright import factory

        monkeypatch.setenv("SEEKWRIGHT_SCRAPPA_API_KEY", "k")

        async def build(fetch: FetchConfig) -> list[Any]:
            cfg = Config(
                providers={"scrappa": ProviderConfig(), "serper": ProviderConfig()},
                fetch=fetch,
            )
            fetcher, fallbacks = await factory.build_fetch_stack(cfg)
            assert fetcher is not None
            await fetcher.aclose()
            for fallback in fallbacks:
                await fallback.aclose()
            return list(fallbacks)

        (default,) = await build(FetchConfig(enabled=True, fallback=["scrappa"]))
        # The figure is the fallback's own declaration: the factory carries no price.
        assert ScrappaFetcher.cost_per_1k == pytest.approx(0.30)
        assert default.cost_per_1k == pytest.approx(0.30)

        (overridden,) = await build(
            FetchConfig(enabled=True, fallback=["scrappa"], cost_per_1k=0.20)
        )
        assert overridden.cost_per_1k == pytest.approx(0.20)

    async def test_the_free_fallbacks_declare_no_price(self):
        """Nothing to record for a page the renderer or the reader served.

        Both are free by construction -- one is the operator's own service, the
        other is keyless -- so neither declares a price and a page either served
        carries no `cost_usd` at all, rather than a `0.0`.
        """
        from seekwright import factory

        cfg = Config(
            providers={"serper": ProviderConfig()},
            fetch=FetchConfig(
                enabled=True,
                fallback=["crawl4ai", "jina"],
                crawl4ai_url="http://crawl4ai:11235",
                # Set on purpose: the ladder-wide key is a correction to a price a fallback
                # already declares, so it cannot put a figure on a fallback that declares none.
                cost_per_1k=0.20,
            ),
        )

        fetcher, fallbacks = await factory.build_fetch_stack(cfg)
        try:
            assert [fallback.name for fallback in fallbacks] == ["crawl4ai", "jina"]
            assert [fallback.cost_per_1k for fallback in fallbacks] == [None, None]
        finally:
            assert fetcher is not None
            await fetcher.aclose()
            for fallback in fallbacks:
                await fallback.aclose()


class TestScrappaFetcher:
    def fetcher(self, handler, **kw) -> ScrappaFetcher:
        f = ScrappaFetcher("test-key", **kw)
        f._client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
        return f

    async def test_the_fallback_declares_its_own_price(self):
        """The figure a page this fallback served is billed at lives on the fallback.

        `0.30`/1k as read on 2026-10-23 (providers.md), so the journal line for a
        page this fallback served carries one call's share: `0.0003`.
        """
        fallback = ScrappaFetcher("test-key")
        try:
            assert fallback.cost_per_1k == pytest.approx(0.30)
            assert fallback.cost_per_1k / 1000.0 == pytest.approx(0.0003)
        finally:
            await fallback.aclose()

    async def test_the_configured_price_replaces_the_declared_one(self):
        """A deployment on another pack sets its own figure; the fallback keeps nothing."""
        fallback = ScrappaFetcher("test-key", cost_per_1k=0.20)
        try:
            assert fallback.cost_per_1k == pytest.approx(0.20)
        finally:
            await fallback.aclose()

    async def test_maps_the_payload_onto_a_page(self):
        f = self.fetcher(lambda _: httpx.Response(200, json=SCRAPED))
        page = await f.fetch(URL)

        assert page.title == "A Rendered Page"
        assert page.text == "The text a browser sees."
        assert page.status_code == 200
        # Where it landed, not where we asked.
        assert page.url == "https://example.com/article?utm=1"
        assert page.content_type is None

    async def test_requests_javascript_rendering(self):
        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, json=SCRAPED)

        await self.fetcher(handler).fetch(URL)

        request = seen["request"]
        assert request.headers["x-api-key"] == "test-key"
        assert request.url.params["url"] == URL
        # The whole reason to pay for this fallback.
        assert request.url.params["javascript"] == "1"

    async def test_text_is_capped(self):
        payload = {**SCRAPED, "data": {**SCRAPED_DATA, "body_text": "x" * 500}}
        f = self.fetcher(
            lambda _: httpx.Response(200, json=payload), max_text_chars=100
        )
        page = await f.fetch(URL)

        # Windowed like every other fallback: paragraph cut, marker after the slice.
        # total_chars is the full payload either way.
        assert page.text == "x" * 100 + "\n\n[...]"
        assert page.truncated is True
        assert page.total_chars == 500

    async def test_an_origin_error_page_is_not_content(self):
        # Scrappa answers 200 with the 404 body; that is a successful API call
        # and a failed fetch.
        payload = {**SCRAPED, "site_status_code": 404}
        f = self.fetcher(lambda _: httpx.Response(200, json=payload))
        with pytest.raises(ProviderError, match="404"):
            await f.fetch(URL)

    async def test_reported_failure_is_an_error(self):
        payload = {"success": False, "message": "could not scrape"}
        f = self.fetcher(lambda _: httpx.Response(200, json=payload))
        with pytest.raises(ProviderError):
            await f.fetch(URL)

    async def test_quota_exhaustion_is_typed(self):
        f = self.fetcher(lambda _: httpx.Response(402, json={}))
        with pytest.raises(QuotaExhausted):
            await f.fetch(URL)

    async def test_private_addresses_are_refused_before_delegating(self):
        called = False

        def handler(_: httpx.Request) -> httpx.Response:
            nonlocal called
            called = True
            return httpx.Response(200, json=SCRAPED)

        f = self.fetcher(handler)
        with pytest.raises(FetchBlocked):
            await f.fetch("http://127.0.0.1:8080/admin")
        # The hostname never reaches Scrappa at all: handing internal names away is
        # the leak.
        assert called is False

    async def test_non_http_schemes_are_refused(self):
        f = self.fetcher(lambda _: httpx.Response(200, json=SCRAPED))
        with pytest.raises(FetchBlocked):
            await f.fetch("file:///etc/passwd")


class TestFallbackObservability:
    """The paid fallback is the one that must never fire unrecorded."""

    @staticmethod
    def _events(records, name):
        return [r.record["extra"] for r in records if r.record["message"] == name]

    async def test_a_failed_paid_retry_is_no_longer_silent(
        self, make_engine, log_records
    ):
        """The regression guard for the swallowed billed call.

        `_try_fallback` returns None so the caller keeps the *original* failure,
        which is right. But Scrappa bills per page, so before this event a paid
        call could fail leaving no trace for the only party that pays for it.
        """
        fallback = StubFetcher("scrappa", fail=ProviderError("scrappa", "HTTP 502"))
        engine = make_engine(
            StubFetcher(fail=ProviderError("fetch", "HTTP 403")), [fallback]
        )

        with pytest.raises(FetchFailed) as exc:
            await engine.fetch(URL)

        # Behaviour is unchanged: the original failure is what surfaces.
        assert "HTTP 403" in str(exc.value)
        assert fallback.calls == 1

        (fields,) = self._events(log_records, "fetch.fallback_failed")
        assert fields["fallback"] == "scrappa"
        assert fields["reason"] == "HTTP 502"
        assert fields["original_reason"] == "HTTP 403"

    async def test_a_successful_paid_retry_is_recorded(self, make_engine, log_records):
        engine = make_engine(
            StubFetcher(fail=ProviderError("fetch", "HTTP 403")),
            [StubFetcher("scrappa", text=RENDERED_TEXT)],
        )
        await engine.fetch(URL)

        (fields,) = self._events(log_records, "fetch.fallback")
        assert fields["fallback"] == "scrappa"
        assert fields["reason"] == "HTTP 403"
        assert self._events(log_records, "fetch.ok")[0]["fell_back"] is True

    async def test_a_guardrail_refusal_is_not_logged_as_a_failure(
        self, make_engine, log_records
    ):
        """An SSRF refusal is the policy working, so it is levelled apart.

        This one branch in `FetchEngine.fetch` covers every `FetchBlocked` raise
        site in `fetcher.py`, which is why none of them logs for itself.
        """
        engine = make_engine(StubFetcher(fail=FetchBlocked("not a public address")))

        with pytest.raises(FetchFailed):
            await engine.fetch("http://127.0.0.1/admin")

        (blocked,) = self._events(log_records, "fetch.blocked")
        assert blocked["reason"] == "not a public address"
        assert blocked["host"] == "127.0.0.1"
        assert self._events(log_records, "fetch.failed") == []

    async def test_the_url_is_reduced_to_a_host_by_default(
        self, make_engine, log_records
    ):
        engine = make_engine(StubFetcher())
        await engine.fetch("https://example.com/secret-path?token=abc")

        (fields,) = self._events(log_records, "fetch.ok")
        assert fields["host"] == "example.com"
        assert "url" not in fields
        assert "secret-path" not in str(fields)

    async def test_page_text_is_withheld_by_default(self, make_engine, log_records):
        engine = make_engine(StubFetcher(text="The body of the page."))
        await engine.fetch(URL)

        assert self._events(log_records, "fetch.content") == []
        # `chars` is what `fetch.ok` says about the body, and all it says.
        (fields,) = self._events(log_records, "fetch.ok")
        assert fields["chars"] == len("The body of the page.")
        assert "The body" not in str(fields)

    async def test_page_text_is_recorded_when_opted_in(self, make_engine, log_records):
        engine = make_engine(StubFetcher(text="The body of the page."))
        engine.config.logging.log_content = True
        await engine.fetch(URL)

        (fields,) = self._events(log_records, "fetch.content")
        assert "The body of the page." in fields["text"]
        # Still its own event: `fetch.ok` is the aggregatable line either way.
        (ok,) = self._events(log_records, "fetch.ok")
        assert "text" not in ok


class TestUsageRecording:
    """Which fallback a page is attributed to, so a price can land later."""

    async def test_a_fallback_served_fetch_records_the_fallback_name(self, make_engine):
        usage = UsageRecorder()
        fallback = StubFetcher("scrappa", text=RENDERED_TEXT)
        engine = make_engine(
            StubFetcher(fail=ProviderError("fetch", "HTTP 403")),
            [fallback],
            usage=usage,
        )

        await engine.fetch(URL)

        recent = cast("list[dict[str, Any]]", usage.snapshot()["recent"])
        (entry,) = recent
        assert entry["fallback"] == "scrappa"
        assert entry["chars"] == len(RENDERED_TEXT)
        assert cast("dict[str, Any]", usage.snapshot()["totals"])[
            "fetch_pages_via_fallback"
        ] == 1

    async def test_a_local_fetch_records_no_fallback(self, make_engine):
        usage = UsageRecorder()
        await make_engine(StubFetcher(), [], usage=usage).fetch(URL)

        recent = cast("list[dict[str, Any]]", usage.snapshot()["recent"])
        assert recent[0]["fallback"] is None

    async def test_a_past_end_page_still_names_the_fallback_that_served_it(
        self, make_engine
    ):
        """The fallback was billed for the page whose length put the offset past its end."""
        usage = UsageRecorder()
        engine = make_engine(
            StubFetcher(fail=ProviderError("fetch", "HTTP 403")),
            [StubFetcher("scrappa", text=RENDERED_TEXT)],
            usage=usage,
        )

        r = await engine.fetch(URL, offset=len(RENDERED_TEXT) + 5)

        assert r.text == ""
        assert "past the end" in (r.notice or "")
        recent = cast("list[dict[str, Any]]", usage.snapshot()["recent"])
        (entry,) = recent
        assert entry["fallback"] == "scrappa"
        assert entry["chars"] == len(RENDERED_TEXT)
        assert cast("dict[str, Any]", usage.snapshot()["totals"])[
            "fetch_pages_via_fallback"
        ] == 1

    async def test_a_priced_fallback_records_its_declared_price(self, make_engine):
        """The fallback's own `cost_per_1k` becomes the line's `cost_usd`, per call."""
        usage = UsageRecorder()
        engine = make_engine(
            StubFetcher(fail=ProviderError("fetch", "HTTP 403")),
            [StubFetcher("scrappa", text=RENDERED_TEXT, cost_per_1k=0.30)],
            usage=usage,
        )

        await engine.fetch(URL)

        (entry,) = cast("list[dict[str, Any]]", usage.snapshot()["recent"])
        assert entry["cost_usd"] == pytest.approx(0.0003)
        totals = cast("dict[str, Any]", usage.snapshot()["totals"])
        assert totals["fetch_cost_usd"] == pytest.approx(0.0003)
        assert totals["priced_fetches"] == 1

    async def test_a_past_end_page_is_priced_like_any_other(self, make_engine):
        """The call is what the fallback bills, whatever the window delivered."""
        usage = UsageRecorder()
        engine = make_engine(
            StubFetcher(fail=ProviderError("fetch", "HTTP 403")),
            [StubFetcher("scrappa", text=RENDERED_TEXT, cost_per_1k=0.30)],
            usage=usage,
        )

        await engine.fetch(URL, offset=len(RENDERED_TEXT) + 5)

        (entry,) = cast("list[dict[str, Any]]", usage.snapshot()["recent"])
        assert entry["chars"] == len(RENDERED_TEXT)
        assert entry["cost_usd"] == pytest.approx(0.0003)

    async def test_a_free_fallback_records_no_price(self, make_engine):
        """`jina` declares no price, so its page carries no money at all."""
        usage = UsageRecorder()
        engine = make_engine(
            StubFetcher(fail=ProviderError("fetch", "HTTP 403")),
            [StubFetcher("jina", text=RENDERED_TEXT)],
            usage=usage,
        )

        await engine.fetch(URL)

        (entry,) = cast("list[dict[str, Any]]", usage.snapshot()["recent"])
        assert entry["fallback"] == "jina"
        assert "cost_usd" not in entry
        assert (
            cast("dict[str, Any]", usage.snapshot()["totals"])["fetch_cost_usd"]
            is None
        )

    async def test_a_local_page_records_no_price(self, make_engine):
        usage = UsageRecorder()
        await make_engine(StubFetcher(), [], usage=usage).fetch(URL)

        (entry,) = cast("list[dict[str, Any]]", usage.snapshot()["recent"])
        assert entry["fallback"] is None
        assert "cost_usd" not in entry

    async def test_a_failed_fetch_records_no_price(self, make_engine):
        usage = UsageRecorder()
        engine = make_engine(
            StubFetcher(fail=ProviderError("fetch", "HTTP 500")), [], usage=usage
        )

        with pytest.raises(FetchFailed):
            await engine.fetch(URL)

        (entry,) = cast("list[dict[str, Any]]", usage.snapshot()["recent"])
        assert entry["fallback"] is None
        assert "cost_usd" not in entry
        assert (
            cast("dict[str, Any]", usage.snapshot()["totals"])["fetch_cost_usd"]
            is None
        )
