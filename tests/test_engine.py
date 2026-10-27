"""End-to-end engine behaviour with a stub provider.

Two things are under test: how a provider is chosen from a name (or from the
absence of one), and how a provider failure is turned into something a model can
act on. There is no cache, so nothing else happens in between.
"""

from typing import Any, cast, override

import httpx
import pytest

from seekwright.config import (
    FREE_PROVIDERS,
    Config,
    PolicyConfig,
    ProviderConfig,
    SearchConfig,
)
from seekwright.engine import SearchEngine, SearchFailed, SearchRefused
from seekwright.health import HealthBoard
from seekwright.models import ProviderResult, Result, SearchQuery
from seekwright.providers.base import ProviderError, QuotaExhausted, SearchProvider
from seekwright.providers.serper import SerperProvider
from seekwright.sanitize import ZWSP
from seekwright.usage import UsageRecorder


def _usage_snapshot(rec: UsageRecorder) -> dict[str, Any]:
    """The snapshot, typed loosely so the tests read like JSON."""
    return cast("dict[str, Any]", rec.snapshot())


class StubProvider:
    """A provider that structurally satisfies ``SearchProvider`` for tests."""

    def __init__(
        self,
        name: str = "serper",
        cost: float = 0.001,
        fail: Exception | None = None,
        results: list[Result] | None = None,
    ) -> None:
        self.name = name
        self.cost_per_1k = cost
        self.calls = 0
        self._fail = fail
        self._results = results
        self.answer: str | None = None
        self.notice: str | None = None

    async def search(self, q: SearchQuery) -> ProviderResult:
        self.calls += 1
        if self._fail:
            raise self._fail
        results = (
            list(self._results)
            if self._results is not None
            else [
                Result(
                    title=f"Result for {q.query}",
                    url="https://example.com/a",
                    snippet="a snippet",
                )
            ]
        )
        return ProviderResult(
            provider=self.name,
            results=results,
            answer=self.answer,
            cost_usd=0.001,
            notice=self.notice,
        )

    async def aclose(self) -> None:
        return None


@pytest.fixture
def make_engine():
    def _make(
        *providers: SearchProvider,
        default: str | None = None,
        fallback: list[str] | None = None,
        free_fallback: list[str] | None = None,
        permitted: list[str] | None = None,
        health: HealthBoard | None = None,
        usage: UsageRecorder | None = None,
    ):
        if not providers:
            providers = (StubProvider(),)
        cfg = Config(
            providers={
                # `searxng` is the one provider whose config *is* its
                # prerequisite: enabled without a url is a startup error.
                p.name: (
                    ProviderConfig(url="http://searxng.test:8080")
                    if p.name == "searxng"
                    else ProviderConfig()
                )
                for p in providers
            },
            default_provider=default,
            permitted_providers=permitted,
            policy=PolicyConfig(),
            search=SearchConfig(fallback=fallback, free_fallback=free_fallback),
        )
        return SearchEngine(
            cfg, {p.name: p for p in providers}, health=health, usage=usage
        )

    return _make


class TestSearch:
    async def test_results_are_returned(self, make_engine):
        r = await make_engine().search(SearchQuery(query="sqlite wal mode"))
        assert r.provider == "serper"
        assert r.results[0].url == "https://example.com/a"
        assert r.retrieved_at is not None

    async def test_every_call_reaches_the_provider(self, make_engine):
        p = StubProvider()
        engine = make_engine(p)
        q = SearchQuery(query="sqlite wal mode")
        await engine.search(q)
        await engine.search(q)
        assert p.calls == 2, "there is no cache; each call is billed"

    async def test_a_provider_notice_reaches_the_caller(self, make_engine):
        """An unhonoured filter must be reported, not silently dropped."""
        p = StubProvider()
        p.notice = "cannot filter by domain; that constraint was ignored"
        r = await make_engine(p).search(
            SearchQuery(query="x y z", include_domains=["arxiv.org"])
        )
        assert "cannot filter by domain" in (r.notice or "")


class TestProviderSelection:
    async def test_named_provider_is_used(self, make_engine):
        a, b = StubProvider("serper"), StubProvider("linkup")
        r = await make_engine(a, b).search(SearchQuery(query="x y"), provider="linkup")
        assert r.provider == "linkup"
        assert a.calls == 0

    async def test_omitted_provider_uses_the_default(self, make_engine):
        a, b = StubProvider("serper"), StubProvider("linkup")
        engine = make_engine(a, b, default="linkup")
        r = await engine.search(SearchQuery(query="x y"))
        assert r.provider == "linkup"

    async def test_no_default_and_several_enabled_asks_the_caller_to_choose(
        self, make_engine
    ):
        """Picking one would spend at a price the caller never agreed to."""
        engine = make_engine(StubProvider("serper"), StubProvider("linkup"))
        with pytest.raises(SearchFailed) as exc:
            await engine.search(SearchQuery(query="x y"))
        assert "pass `provider`" in str(exc.value)
        # The error is the only place the enabled set can be reported, since the
        # tool schema is fixed at import time.
        assert "linkup" in str(exc.value) and "serper" in str(exc.value)

    async def test_unknown_provider_names_the_available_ones(self, make_engine):
        engine = make_engine(StubProvider("serper"))
        with pytest.raises(SearchFailed) as exc:
            await engine.search(SearchQuery(query="x y"), provider="linkup")
        assert "not enabled" in str(exc.value)
        assert "serper" in str(exc.value)
        assert "Retry with one of those" in str(exc.value)

    async def test_the_default_is_only_offered_when_there_is_one(self, make_engine):
        """Otherwise the suggested recovery produces the other error instead."""
        engine = make_engine(StubProvider("serper"), StubProvider("exa"))
        with pytest.raises(SearchFailed) as exc:
            await engine.search(SearchQuery(query="x y"), provider="linkup")
        assert "omit `provider`" not in str(exc.value)

        engine = make_engine(StubProvider("serper"), default="serper")
        with pytest.raises(SearchFailed) as exc:
            await engine.search(SearchQuery(query="x y"), provider="linkup")
        assert "omit `provider`" in str(exc.value)


class TestProviderFailure:
    async def test_failure_raises_with_retry_advice(self, make_engine):
        engine = make_engine(StubProvider(fail=ProviderError("serper", "503")))
        with pytest.raises(SearchFailed) as exc:
            await engine.search(SearchQuery(query="sqlite wal mode"))
        assert "Retry shortly" in str(exc.value)

    async def test_quota_exhausted_says_do_not_retry(self, make_engine):
        engine = make_engine(StubProvider(fail=QuotaExhausted("serper")))
        with pytest.raises(SearchFailed) as exc:
            await engine.search(SearchQuery(query="sqlite wal mode"))
        assert "Do not retry immediately" in str(exc.value)

    async def test_a_non_object_json_body_reaches_the_caller_as_advice(
        self, make_engine
    ):
        """A real adapter behind the engine, not a stub.

        The stub above raises the ``ProviderError`` already; what this pins is
        the other end of the same path -- that the adapter's body-shape guard
        raises a ``ProviderError`` rather than an ``AttributeError``, which the
        engine does not catch and which would surface as an internal error
        instead of the sentence a model can act on.
        """
        client = httpx.AsyncClient(
            transport=httpx.MockTransport(lambda _: httpx.Response(200, content=b"[]"))
        )
        engine = make_engine(SerperProvider(client, "test-key"), default="serper")
        with pytest.raises(SearchFailed) as exc:
            await engine.search(SearchQuery(query="sqlite wal mode"))
        assert str(exc.value) == (
            "Search failed - serper: malformed JSON response. "
            "Retry shortly or try a different phrasing."
        )


class TestDefaultRouteFailover:
    """The default route walks the ladder on failure; a named provider stays
    terminal. Every dispatch feeds the health board either way."""

    @staticmethod
    def _events(records, name):
        return [r.record["extra"] for r in records if r.record["message"] == name]

    async def test_a_failed_default_is_served_by_the_fallback(
        self, make_engine, log_records
    ):
        serper = StubProvider("serper", fail=ProviderError("serper", "upstream 503"))
        linkup = StubProvider("linkup")
        engine = make_engine(serper, linkup, default="serper", fallback=["linkup"])

        r = await engine.search(SearchQuery(query="x y"))

        assert r.provider == "linkup"
        assert r.notice == "serper failed (upstream 503); served by linkup instead"
        assert serper.calls == 1 and linkup.calls == 1
        (fallback,) = self._events(log_records, "search.fallback")
        assert fallback["fallback"] == "linkup"
        assert fallback["reason"] == "upstream 503"
        oks = [r for r in log_records if r.record["message"] == "search.ok"]
        assert oks[-1].record["extra"]["fell_back"] is True

    async def test_the_substitute_notice_joins_the_adapter_notice(self, make_engine):
        serper = StubProvider("serper", fail=ProviderError("serper", "upstream 503"))
        linkup = StubProvider("linkup")
        linkup.notice = "cannot filter by domain; that constraint was ignored"
        engine = make_engine(serper, linkup, default="serper", fallback=["linkup"])

        r = await engine.search(SearchQuery(query="x y"))

        assert r.notice == (
            "serper failed (upstream 503); served by linkup instead; "
            "cannot filter by domain; that constraint was ignored"
        )

    async def test_a_named_provider_failure_stays_terminal(
        self, make_engine, log_records
    ):
        serper = StubProvider("serper", fail=ProviderError("serper", "upstream 503"))
        linkup = StubProvider("linkup")
        engine = make_engine(serper, linkup, default="serper", fallback=["linkup"])

        with pytest.raises(SearchFailed, match="Retry shortly"):
            await engine.search(SearchQuery(query="x y"), provider="serper")

        assert linkup.calls == 0
        assert len(self._events(log_records, "search.failed")) == 1
        assert not [
            r for r in log_records if r.record["message"].startswith("search.fallback")
        ]

    async def test_an_open_circuit_fallback_is_skipped(self, make_engine, log_records):
        serper = StubProvider("serper", fail=ProviderError("serper", "upstream 503"))
        linkup = StubProvider("linkup")
        health = HealthBoard(failure_threshold=1, cooldown_seconds=60.0)
        health.record_failure("linkup", reason="probe unreachable")
        engine = make_engine(
            serper, linkup, default="serper", fallback=["linkup"], health=health
        )

        with pytest.raises(SearchFailed) as exc:
            await engine.search(SearchQuery(query="x y"))

        assert linkup.calls == 0
        (skip,) = self._events(log_records, "search.fallback_skipped")
        assert skip["fallback"] == "linkup"
        assert skip["until_s"] > 0
        # No fallback attempted, so the message is exactly today's terminal one.
        assert str(exc.value) == (
            "Search failed - serper: upstream 503. "
            "Retry shortly or try a different phrasing."
        )

    async def test_when_every_fallback_fails_the_original_error_leads(
        self, make_engine, log_records
    ):
        serper = StubProvider("serper", fail=ProviderError("serper", "upstream 503"))
        linkup = StubProvider("linkup", fail=ProviderError("linkup", "HTTP 502"))
        tavily = StubProvider("tavily", fail=ProviderError("tavily", "HTTP 500"))
        engine = make_engine(
            serper, linkup, tavily, default="serper", fallback=["linkup", "tavily"]
        )

        with pytest.raises(SearchFailed) as exc:
            await engine.search(SearchQuery(query="x y"))

        assert "upstream 503" in str(exc.value)
        assert " Fallbacks also failed: linkup, tavily." in str(exc.value)
        failures = self._events(log_records, "search.fallback_failed")
        assert [
            (f["fallback"], f["reason"], f["original_reason"]) for f in failures
        ] == [
            ("linkup", "HTTP 502", "upstream 503"),
            ("tavily", "HTTP 500", "upstream 503"),
        ]
        assert len(self._events(log_records, "search.failed")) == 1

    async def test_each_fallback_runs_once_and_the_default_is_not_retried(
        self, make_engine
    ):
        serper = StubProvider("serper", fail=ProviderError("serper", "upstream 503"))
        linkup = StubProvider("linkup")
        engine = make_engine(
            serper, linkup, default="serper", fallback=["serper", "linkup"]
        )

        r = await engine.search(SearchQuery(query="x y"))

        assert serper.calls == 1, "the tried default is skipped, not retried"
        assert r.provider == "linkup"
        assert linkup.calls == 1

    async def test_a_direct_success_says_so_and_named_failures_still_feed_the_board(
        self, make_engine, log_records
    ):
        engine = make_engine(StubProvider())
        await engine.search(SearchQuery(query="q"))
        oks = [r for r in log_records if r.record["message"] == "search.ok"]
        assert oks[-1].record["extra"]["fell_back"] is False

        # No ladder configured: a named failure stays terminal, but the board
        # still counts it -- that is what a later search's ladder will read.
        failing = StubProvider("serper", fail=ProviderError("serper", "503"))
        engine = make_engine(failing)
        for _ in range(3):
            with pytest.raises(SearchFailed):
                await engine.search(SearchQuery(query="q"), provider="serper")
        assert engine.health.is_open("serper") is True

    async def test_quota_exhausted_reroutes_and_all_quota_keeps_its_advice(
        self, make_engine
    ):
        quota = StubProvider("serper", fail=QuotaExhausted("serper"))
        linkup = StubProvider("linkup")
        engine = make_engine(quota, linkup, default="serper", fallback=["linkup"])

        r = await engine.search(SearchQuery(query="x y"))
        assert r.provider == "linkup", "quota is a failure like any other here"

        also_quota = StubProvider("serper", fail=QuotaExhausted("serper"))
        dead = StubProvider("linkup", fail=QuotaExhausted("linkup"))
        engine = make_engine(also_quota, dead, default="serper", fallback=["linkup"])
        with pytest.raises(SearchFailed) as exc:
            await engine.search(SearchQuery(query="x y"))
        assert " Fallbacks also failed: linkup." in str(exc.value)
        assert str(exc.value).endswith("Do not retry immediately.")


class TestFreeMode:
    """`mode="free"` is a caller-declared route served only from providers that
    cannot bill, and it fails rather than escalating.

    The mode's promise is a ceiling of zero, so the paid half of these asserts a
    *call count of zero* -- not merely that a paid provider did not serve the
    search.
    """

    @staticmethod
    def _events(records, name: str) -> list[dict[str, Any]]:
        return [r.record["extra"] for r in records if r.record["message"] == name]

    @staticmethod
    def _recording(order: list[str], name: str, *, fail: bool = False) -> StubProvider:
        """A stub that appends its name to `order` before it answers."""

        class Recording(StubProvider):
            @override
            async def search(self, q: SearchQuery) -> ProviderResult:
                order.append(self.name)
                return await super().search(q)

        return Recording(
            name, fail=ProviderError(name, "rate limited") if fail else None
        )

    async def test_the_walk_is_the_constant_order_keyless_first(self, make_engine):
        order: list[str] = []
        engine = make_engine(
            self._recording(order, "tinyfish", fail=True),
            self._recording(order, "searxng", fail=True),
            self._recording(order, "parallel:free", fail=True),
            self._recording(order, "exa:free", fail=True),
        )

        with pytest.raises(SearchFailed):
            await engine.search(SearchQuery(query="x y"), mode="free")

        assert order == [
            "exa:free",
            "parallel:free",
            "searxng",
            "tinyfish",
        ], "the declaration order, not the order they were handed to the engine"
        assert len(order) == len(set(order)), "each fallback at most once"

    async def test_the_configured_ladder_decides_the_order_and_narrows_the_walk(
        self, make_engine
    ):
        order: list[str] = []
        exa_free = self._recording(order, "exa:free")
        engine = make_engine(
            exa_free,
            self._recording(order, "tinyfish", fail=True),
            self._recording(order, "searxng"),
            free_fallback=["tinyfish", "searxng"],
        )

        r = await engine.search(SearchQuery(query="x y"), mode="free")

        assert order == ["tinyfish", "searxng"], "the operator's order, only"
        assert exa_free.calls == 0, "a ladder that does not name a fallback drops it"
        assert r.provider == "searxng"
        assert r.notice == "tinyfish failed (rate limited); served by searxng instead"

    async def test_the_default_provider_is_not_consulted(self, make_engine):
        """The caller asked for a class, not for the deployment's default."""
        serper = StubProvider("serper")
        engine = make_engine(serper, StubProvider("exa:free"), default="serper")

        r = await engine.search(SearchQuery(query="x y"), mode="free")

        assert r.provider == "exa:free"
        assert serper.calls == 0

    async def test_a_paid_provider_is_never_reached(self, make_engine):
        """Criterion 1: the paid counter stays at zero however the walk ends --
        here with every free fallback failing and a paid ladder configured beside
        the mode, which the free walk must not read."""
        serper = StubProvider("serper")
        engine = make_engine(
            serper,
            StubProvider("exa:free", fail=ProviderError("exa:free", "rate limited")),
            StubProvider("tinyfish", fail=ProviderError("tinyfish", "bot-walled")),
            default="serper",
            fallback=["serper"],
        )

        with pytest.raises(SearchFailed) as exc:
            await engine.search(SearchQuery(query="x y"), mode="free")

        assert serper.calls == 0
        text = str(exc.value)
        assert text.startswith("Search failed - exa:free: rate limited.")
        assert " Fallbacks also failed: tinyfish." in text
        assert "no paid provider was tried" in text

    async def test_one_free_fallback_alone_still_says_why_nothing_paid_was_tried(
        self, make_engine
    ):
        """No fallback left to append, and the sentence still has to be there: the
        model cannot see the walk, so the message is the only place it can be
        told the mode is why no paid provider answered."""
        engine = make_engine(
            StubProvider("exa:free", fail=ProviderError("exa:free", "rate limited")),
            StubProvider("serper"),
            default="serper",
        )

        with pytest.raises(SearchFailed) as exc:
            await engine.search(SearchQuery(query="x y"), mode="free")

        text = str(exc.value)
        assert "no paid provider was tried" in text
        assert "Fallbacks also failed" not in text

    async def test_an_open_circuit_fallback_is_skipped(self, make_engine, log_records):
        exa_free = StubProvider(
            "exa:free", fail=ProviderError("exa:free", "rate limited")
        )
        tinyfish = StubProvider("tinyfish")
        health = HealthBoard(failure_threshold=1, cooldown_seconds=60.0)
        health.record_failure("tinyfish", reason="probe unreachable")
        engine = make_engine(exa_free, tinyfish, health=health)

        with pytest.raises(SearchFailed) as exc:
            await engine.search(SearchQuery(query="x y"), mode="free")

        assert tinyfish.calls == 0
        (skip,) = self._events(log_records, "search.fallback_skipped")
        assert skip["fallback"] == "tinyfish"
        assert skip["until_s"] > 0
        assert "no paid provider was tried" in str(exc.value)

    async def test_a_failed_fallback_gates_on_the_health_board(self, make_engine):
        """A rate-limited fallback is an ordinary failure: recorded on the board,
        so the breaker gates it for the cooldown like any other."""
        exa_free = StubProvider(
            "exa:free", fail=ProviderError("exa:free", "rate limited")
        )
        health = HealthBoard(failure_threshold=1, cooldown_seconds=60.0)
        engine = make_engine(exa_free, StubProvider("tinyfish"), health=health)

        r = await engine.search(SearchQuery(query="x y"), mode="free")

        assert r.provider == "tinyfish"
        assert health.is_open("exa:free") is True
        assert health.is_open("tinyfish") is False

    async def test_no_free_provider_enabled_is_a_clean_refusal(self, make_engine):
        """The shape `[fetch] enabled = false` uses: a refusal naming the set,
        not a tool that disappears -- the schema is frozen at import, so the
        deployment's real set can only be reported here."""
        engine = make_engine(StubProvider("serper"), default="serper")

        with pytest.raises(SearchFailed) as exc:
            await engine.search(SearchQuery(query="x y"), mode="free")

        text = str(exc.value)
        assert "No free provider is enabled" in text
        for name in sorted(FREE_PROVIDERS):
            assert name in text

    async def test_naming_a_provider_and_a_mode_is_refused(self, make_engine):
        """Two ways to name a route is an ambiguity with a precedence rule
        hiding in it, so neither wins."""
        serper = StubProvider("serper")
        exa_free = StubProvider("exa:free")
        engine = make_engine(serper, exa_free, default="serper")

        with pytest.raises(SearchFailed) as exc:
            await engine.search(
                SearchQuery(query="x y"), provider="serper", mode="free"
            )

        assert "pass `provider` or `mode`, not both" in str(exc.value)
        assert serper.calls == 0 and exa_free.calls == 0

    async def test_mode_is_bound_on_search_ok_either_way(
        self, make_engine, log_records
    ):
        """Always bound -- None when the caller did not ask -- so the line
        keeps a fixed field set whatever the route."""
        engine = make_engine(
            StubProvider("exa:free"), StubProvider("serper"), default="serper"
        )

        await engine.search(SearchQuery(query="q"), mode="free")
        assert self._events(log_records, "search.ok")[-1]["mode"] == "free"

        await engine.search(SearchQuery(query="q"))
        assert self._events(log_records, "search.ok")[-1]["mode"] is None

    async def test_a_free_served_search_records_the_fallback_once(self, make_engine):
        """One terminal record naming the fallback that served it, like the default
        route's ladder -- the failed first fallback is not a terminal outcome."""
        usage = UsageRecorder()
        engine = make_engine(
            StubProvider("exa:free", fail=ProviderError("exa:free", "rate limited")),
            StubProvider("tinyfish"),
            usage=usage,
        )

        await engine.search(SearchQuery(query="q"), mode="free")

        (entry,) = _usage_snapshot(usage)["recent"]
        assert entry["provider"] == "tinyfish"
        assert entry["fell_back"] is True


class TestTheFreeOnlyDefaultRoute:
    """An unnamed `search` walks the free set when every enabled name is free.

    The default route exists so a caller never has to know the deployment's
    shape; the refusal on an unnamed price exists so a caller is never billed at
    a price it never named. Where every enabled provider cannot bill the two do
    not conflict, and the search is served instead of refused. The walk is the
    `mode="free"` one -- same fallbacks, same order, same ending -- reached from the
    other direction, and one enabled name that can bill brings the refusal back
    verbatim.
    """

    @staticmethod
    def _recording(order: list[str], name: str, *, fail: bool = False) -> StubProvider:
        """A stub that appends its name to `order` before it answers."""

        class Recording(StubProvider):
            @override
            async def search(self, q: SearchQuery) -> ProviderResult:
                order.append(self.name)
                return await super().search(q)

        return Recording(
            name, fail=ProviderError(name, "rate limited") if fail else None
        )

    async def test_an_unnamed_search_is_served_by_the_walk(self, make_engine):
        order: list[str] = []
        engine = make_engine(
            self._recording(order, "exa:free", fail=True),
            self._recording(order, "parallel:free"),
        )

        r = await engine.search(SearchQuery(query="x y"))

        assert order == ["exa:free", "parallel:free"]
        assert r.provider == "parallel:free"
        assert r.notice == (
            "exa:free failed (rate limited); served by parallel:free instead"
        )

    async def test_the_implicit_keyless_set_is_walked_whole(self):
        """A config that enables nothing resolves to the keyless *set*, and an
        unnamed search walks every name in it.

        The third fallback is the point: the install default is the keyless set,
        not the keyless pair, so a bare `search` on an unconfigured install
        reaches `freeserp` too.
        """
        order: list[str] = []
        cfg = Config()
        assert cfg.providers_defaulted is True
        assert cfg.enabled_providers() == ["exa:free", "freeserp", "parallel:free"]
        assert cfg.default_provider is None, "three enabled names: callers choose"

        engine = SearchEngine(
            cfg,
            {
                name: self._recording(order, name, fail=name != "freeserp")
                for name in ("exa:free", "parallel:free", "freeserp")
            },
        )

        r = await engine.search(SearchQuery(query="x y"))

        assert order == ["exa:free", "parallel:free", "freeserp"]
        assert r.provider == "freeserp", "the third fallback is reachable and serves"

    async def test_the_walk_is_the_free_order_and_only_free_names(self, make_engine):
        """The at-most-once rule and the order are the mode's own, and no fallback
        outside `FREE_PROVIDERS` can be reached on this route either."""
        order: list[str] = []
        engine = make_engine(
            self._recording(order, "tinyfish", fail=True),
            self._recording(order, "searxng", fail=True),
            self._recording(order, "parallel:free", fail=True),
            self._recording(order, "exa:free", fail=True),
        )

        with pytest.raises(SearchFailed):
            await engine.search(SearchQuery(query="x y"))

        assert order == ["exa:free", "parallel:free", "searxng", "tinyfish"]
        assert len(order) == len(set(order)), "each fallback at most once"
        assert set(order) <= FREE_PROVIDERS

    async def test_the_configured_free_ladder_orders_it(self, make_engine):
        """`search.free_fallback` is the order on this route too -- the same
        walk, so the operator's ladder cannot mean one thing in `mode="free"`
        and another here."""
        order: list[str] = []
        exa_free = self._recording(order, "exa:free")
        engine = make_engine(
            exa_free,
            self._recording(order, "tinyfish", fail=True),
            self._recording(order, "searxng"),
            free_fallback=["tinyfish", "searxng"],
        )

        r = await engine.search(SearchQuery(query="x y"))

        assert order == ["tinyfish", "searxng"]
        assert exa_free.calls == 0
        assert r.provider == "searxng"

    async def test_the_ending_is_the_walks_own(self, make_engine):
        """The first fallback's error leads, with the failed fallbacks appended."""
        engine = make_engine(
            StubProvider("exa:free", fail=ProviderError("exa:free", "rate limited")),
            StubProvider(
                "parallel:free", fail=ProviderError("parallel:free", "HTTP 503")
            ),
        )

        with pytest.raises(SearchFailed) as exc:
            await engine.search(SearchQuery(query="x y"))

        text = str(exc.value)
        assert text.startswith("Search failed - exa:free: rate limited.")
        assert " Fallbacks also failed: parallel:free." in text

    async def test_an_open_circuit_fallback_is_skipped(self, make_engine, log_records):
        exa_free = StubProvider(
            "exa:free", fail=ProviderError("exa:free", "rate limited")
        )
        parallel = StubProvider("parallel:free")
        health = HealthBoard(failure_threshold=1, cooldown_seconds=60.0)
        health.record_failure("parallel:free", reason="probe unreachable")
        engine = make_engine(exa_free, parallel, health=health)

        with pytest.raises(SearchFailed):
            await engine.search(SearchQuery(query="x y"))

        assert parallel.calls == 0
        skips = [
            r.record["extra"]
            for r in log_records
            if r.record["message"] == "search.fallback_skipped"
        ]
        assert [s["fallback"] for s in skips] == ["parallel:free"]

    async def test_one_billable_name_brings_the_refusal_back(self, make_engine):
        """The moment the deployment can spend, an unnamed search is the old
        error again -- verbatim, listing what is available."""
        exa_free = StubProvider("exa:free")
        serper = StubProvider("serper")
        engine = make_engine(exa_free, serper)

        with pytest.raises(SearchFailed) as exc:
            await engine.search(SearchQuery(query="x y"))

        text = str(exc.value)
        assert "No default provider is configured" in text
        assert "exa:free" in text and "serper" in text
        assert exa_free.calls == 0 and serper.calls == 0

    async def test_a_free_tier_is_not_a_free_name(self, make_engine):
        """`tinyfish` cannot bill and is in; `tavily` has a free tier and can,
        so one of it beside a keyless name is enough to restore the refusal."""
        engine = make_engine(StubProvider("exa:free"), StubProvider("tavily"))

        with pytest.raises(SearchFailed, match="No default provider is configured"):
            await engine.search(SearchQuery(query="x y"))

    async def test_a_named_provider_is_unaffected(self, make_engine):
        exa_free = StubProvider("exa:free")
        parallel = StubProvider("parallel:free")
        engine = make_engine(exa_free, parallel)

        r = await engine.search(SearchQuery(query="x y"), provider="parallel:free")

        assert r.provider == "parallel:free"
        assert exa_free.calls == 0

    async def test_a_single_free_provider_is_still_the_default(self, make_engine):
        """`_validate_providers` gives a lone provider the default; that rule is
        untouched, so the walk is not the route here."""
        engine = make_engine(StubProvider("exa:free"))

        assert engine.config.default_provider == "exa:free"
        r = await engine.search(SearchQuery(query="x y"))
        assert r.provider == "exa:free"
        assert r.notice is None

    async def test_mode_stays_none_on_the_unnamed_walk(self, make_engine, log_records):
        """The caller declared no mode, so the line says so -- and `notice` is
        where the substitution is reported, in the existing wording."""
        engine = make_engine(StubProvider("exa:free"), StubProvider("parallel:free"))

        await engine.search(SearchQuery(query="q"))

        ok = [
            r.record["extra"]
            for r in log_records
            if r.record["message"] == "search.ok"
        ][-1]
        assert ok["mode"] is None
        assert ok["fell_back"] is False


class TestTheAllowList:
    """`permitted_providers` at every dispatch site the search path owns.

    The claims the contract page lists: a name enabled but not permitted is
    refused *before* the adapter is called, unset is permissive, the
    intersection holds both ways, and a walk -- free or the default route's --
    never reaches a name the list removes (docs/reference/allow-list.md).
    """

    async def test_a_name_enabled_but_not_permitted_never_reaches_the_adapter(
        self, make_engine, log_records
    ):
        serper, linkup = StubProvider("serper"), StubProvider("linkup")
        engine = make_engine(serper, linkup, permitted=["linkup"])

        with pytest.raises(SearchRefused) as exc:
            await engine.search(SearchQuery(query="q"), provider="serper")

        assert serper.calls == 0, "the refusal is before dispatch, so nothing billed"
        message = str(exc.value)
        assert "'serper'" in message, "the refused name is named"
        assert "Permitted: linkup" in message, "and so is the list"
        assert "not enabled" not in message, "the other refusal must not be reused"
        assert not [
            r for r in log_records if r.record["message"] == "search.ok"
        ], "a refused call dispatches nothing to journal"

    async def test_unset_is_permissive(self, make_engine):
        """No key means every enabled provider is permitted: the same call that
        is refused above dispatches, which is what keeps every existing config
        behaving as it does today."""
        serper = StubProvider("serper")
        engine = make_engine(serper, StubProvider("linkup"))

        r = await engine.search(SearchQuery(query="q"), provider="serper")

        assert r.provider == "serper"
        assert serper.calls == 1

    async def test_the_intersection_holds_both_ways(self, make_engine):
        """The two refusals are asserted apart, not merely asserted: permitted
        is not enabled, and enabled is not permitted."""
        engine = make_engine(
            StubProvider("serper"), StubProvider("linkup"), permitted=["linkup"]
        )

        # Permitted but not enabled: the honest reason is "not enabled", and
        # `linkup` is here precisely so the wording cannot be the other one.
        with pytest.raises(SearchRefused) as enabled_exc:
            await engine.search(SearchQuery(query="q"), provider="tavily")
        assert "is not enabled on this server" in str(enabled_exc.value)
        assert "not permitted" not in str(enabled_exc.value)

        # Enabled but not permitted: the other sentence, and never the first.
        with pytest.raises(SearchRefused) as permitted_exc:
            await engine.search(SearchQuery(query="q"), provider="serper")
        assert "is not permitted on this server" in str(permitted_exc.value)
        assert "is not enabled" not in str(permitted_exc.value)

    async def test_the_default_route_skips_an_unpermitted_fallback(
        self, make_engine, log_records
    ):
        """`search.fallback` keeps its own semantics minus the names the list
        removes: the fallback is skipped with a line saying so, and never called."""
        serper = StubProvider("serper")
        linkup = StubProvider("linkup", fail=ProviderError("linkup", "503"))
        engine = make_engine(
            serper,
            linkup,
            default="linkup",
            fallback=["linkup", "serper"],
            permitted=["linkup"],
        )

        with pytest.raises(SearchFailed):
            await engine.search(SearchQuery(query="q"))

        assert linkup.calls == 1, "the default is still attempted first"
        assert serper.calls == 0, "the fallback the allow-list removes never fires"
        (skip,) = [
            r.record["extra"]
            for r in log_records
            if r.record["message"] == "search.fallback_unpermitted"
        ]
        assert skip["fallback"] == "serper"
        assert skip["permitted"] == "linkup"

    async def test_an_unpermitted_default_is_refused_not_rerouted(self, make_engine):
        """Never a silent reroute: the ladder behind the default is not walked,
        because the refusal is raised before the ladder exists to be walked."""
        serper = StubProvider("serper", fail=ProviderError("serper", "503"))
        linkup = StubProvider("linkup")
        engine = make_engine(
            serper,
            linkup,
            default="serper",
            fallback=["linkup"],
            permitted=["linkup"],
        )

        with pytest.raises(SearchRefused) as exc:
            await engine.search(SearchQuery(query="q"))

        assert "The default provider 'serper' is not permitted" in str(exc.value)
        assert "Pass `provider` with one of those." in str(exc.value)
        assert serper.calls == 0 and linkup.calls == 0, "nothing was dispatched"

    async def test_a_free_walk_never_reaches_an_unpermitted_fallback(self, make_engine):
        order: list[str] = []

        class Recording(StubProvider):
            @override
            async def search(self, q: SearchQuery) -> ProviderResult:
                order.append(self.name)
                return await super().search(q)

        exa_free, parallel_free = Recording("exa:free"), Recording("parallel:free")
        engine = make_engine(
            exa_free,
            parallel_free,
            free_fallback=["exa:free", "parallel:free"],
            permitted=["parallel:free"],
        )

        r = await engine.search(SearchQuery(query="q"), mode="free")

        assert r.provider == "parallel:free"
        assert order == ["parallel:free"]
        assert exa_free.calls == 0

    async def test_a_free_walk_emptied_by_the_list_says_permitted(self, make_engine):
        """The two reasons a free walk is empty must not read alike: the
        operator has to know which key to fix."""
        engine = make_engine(StubProvider("exa:free"), permitted=["serper"])

        with pytest.raises(SearchRefused) as exc:
            await engine.search(SearchQuery(query="q"), mode="free")

        message = str(exc.value)
        assert "No permitted free provider is enabled" in message
        assert "Permitted: serper" in message
        assert "The free providers are: " in message
        assert "No free provider is enabled" not in message

    async def test_a_rejection_binds_the_permitted_set(self, make_engine, log_records):
        """The operator's line tells the two refusals apart; `enabled` stays."""
        engine = make_engine(
            StubProvider("serper"), StubProvider("linkup"), permitted=["linkup"]
        )

        with pytest.raises(SearchRefused):
            await engine.search(SearchQuery(query="q"), provider="serper")

        fields = next(
            r.record["extra"]
            for r in log_records
            if r.record["message"] == "search.rejected"
        )
        assert fields["permitted"] == "linkup"
        assert "serper" in fields["enabled"]

    async def test_the_rejection_bind_is_none_when_unset(
        self, make_engine, log_records
    ):
        engine = make_engine(StubProvider("serper"))

        with pytest.raises(SearchRefused):
            await engine.search(SearchQuery(query="q"), provider="linkup")

        fields = next(
            r.record["extra"]
            for r in log_records
            if r.record["message"] == "search.rejected"
        )
        assert fields["permitted"] is None


class TestZeroResults:
    async def test_empty_results_are_not_an_error(self, make_engine):
        class Empty(StubProvider):
            @override
            async def search(self, q):
                self.calls += 1
                return ProviderResult(provider=self.name, results=[])

        r = await make_engine(Empty()).search(SearchQuery(query="asdkjhasdkjh"))
        assert r.results == []

    async def test_zero_results_notice_names_the_other_providers(self, make_engine):
        class Empty(StubProvider):
            @override
            async def search(self, q):
                return ProviderResult(provider=self.name, results=[])

        r = await make_engine(Empty("serper"), StubProvider("linkup")).search(
            SearchQuery(query="asdkjhasdkjh"), provider="serper"
        )

        assert "No results from serper." in (r.notice or "")
        assert "Other enabled providers: linkup." in (r.notice or "")
        assert "rephrase" in (r.notice or "")

    async def test_a_solo_provider_zero_results_says_it_is_alone(self, make_engine):
        class Empty(StubProvider):
            @override
            async def search(self, q):
                return ProviderResult(provider=self.name, results=[])

        r = await make_engine(Empty()).search(SearchQuery(query="asdkjhasdkjh"))

        assert "serper is the only enabled provider." in (r.notice or "")

    async def test_an_answered_zero_result_gets_no_notice(self, make_engine):
        """An answer with no hits is content; a nag would be noise on it."""

        class Answered(StubProvider):
            @override
            async def search(self, q):
                return ProviderResult(provider=self.name, results=[], answer="None.")

        r = await make_engine(Answered()).search(SearchQuery(query="asdkjhasdkjh"))

        assert r.notice is None

    async def test_an_adapter_notice_is_joined_with_the_zero_notice(self, make_engine):
        class Empty(StubProvider):
            @override
            async def search(self, q):
                return ProviderResult(
                    provider=self.name,
                    results=[],
                    notice="cannot filter by domain; that constraint was ignored",
                )

        r = await make_engine(Empty("serper"), StubProvider("linkup")).search(
            SearchQuery(query="asdkjhasdkjh"), provider="serper"
        )

        assert r.notice is not None
        assert r.notice.startswith("cannot filter by domain")
        assert "; No results from serper." in r.notice


class TestObservability:
    """What the operator gets out of a search. Nothing here changes a response.

    `cost_usd` is the point: every adapter computes it and, before this, the
    engine dropped it. It stays off `SearchResponse` -- the caller is not the
    party paying -- so the log line is the only place it exists.
    """

    @staticmethod
    def _event(records, name):
        return next(r for r in records if r.record["message"] == name)

    async def test_a_search_records_cost_and_latency(self, make_engine, log_records):
        await make_engine().search(SearchQuery(query="sqlite wal mode"))

        fields = self._event(log_records, "search.ok").record["extra"]
        assert fields["provider"] == "serper"
        assert fields["cost_usd"] == 0.001
        assert fields["results"] == 1
        assert isinstance(fields["ms"], int) and fields["ms"] >= 0

    async def test_reported_usage_rides_search_ok_when_a_provider_reports_it(
        self, make_engine, log_records
    ):
        """`_reported_cost_usd` is the actual-usage channel for the cost-drift
        check: bound only when the upstream reported credits, beside the
        estimate."""

        class Reporting(StubProvider):
            @override
            async def search(self, q):
                result = await super().search(q)
                result._reported_cost_usd = 0.008
                return result

        await make_engine(Reporting()).search(SearchQuery(query="sqlite wal mode"))

        fields = self._event(log_records, "search.ok").record["extra"]
        assert fields["cost_usd"] == 0.001
        assert fields["reported_cost_usd"] == pytest.approx(0.008)

    async def test_reported_usage_is_absent_when_the_upstream_says_nothing(
        self, make_engine, log_records
    ):
        await make_engine().search(SearchQuery(query="sqlite wal mode"))

        fields = self._event(log_records, "search.ok").record["extra"]
        assert "reported_cost_usd" not in fields

    async def test_query_text_is_withheld_by_default(self, make_engine, log_records):
        await make_engine().search(SearchQuery(query="sqlite wal mode"))

        fields = self._event(log_records, "search.ok").record["extra"]
        assert "query" not in fields
        assert fields["qlen"] == len("sqlite wal mode")
        assert fields["qhash"]

    async def test_query_text_is_recorded_when_opted_in(self, make_engine, log_records):
        engine = make_engine()
        engine.config.logging.log_queries = True
        await engine.search(SearchQuery(query="sqlite wal mode"))

        fields = self._event(log_records, "search.ok").record["extra"]
        assert fields["query"] == "sqlite wal mode"

    async def test_result_content_is_withheld_by_default(
        self, make_engine, log_records
    ):
        await make_engine().search(SearchQuery(query="sqlite wal mode"))

        assert not [r for r in log_records if r.record["message"] == "search.result"]
        # And `search.ok` keeps its shape: content never rides the line an
        # operator aggregates on, whatever the setting says.
        fields = self._event(log_records, "search.ok").record["extra"]
        assert "title" not in fields and "snippet" not in fields

    async def test_result_content_is_recorded_when_opted_in(
        self, make_engine, log_records
    ):
        engine = make_engine()
        engine.config.logging.log_content = True
        await engine.search(SearchQuery(query="sqlite wal mode"))

        (event,) = [r for r in log_records if r.record["message"] == "search.result"]
        fields = event.record["extra"]
        assert fields["rank"] == 1
        assert fields["title"] == "'Result for sqlite wal mode'"
        assert fields["snippet"] == "'a snippet'"
        # The correlation handle rides along from the base logger, which is what
        # ties this back to its `search.ok` without repeating the query.
        assert fields["qhash"] == self._event(log_records, "search.ok").record[
            "extra"
        ]["qhash"]

    async def test_ranks_are_one_based_and_ordered(self, make_engine, log_records):
        class ThreeHits(StubProvider):
            @override
            async def search(self, q: SearchQuery) -> ProviderResult:
                return ProviderResult(
                    provider=self.name,
                    results=[
                        Result(title=f"t{i}", url=f"https://x.test/{i}", snippet="s")
                        for i in range(3)
                    ],
                    cost_usd=0.001,
                )

        engine = make_engine(ThreeHits())
        engine.config.logging.log_content = True
        await engine.search(SearchQuery(query="q"))

        events = [r for r in log_records if r.record["message"] == "search.result"]
        assert [e.record["extra"]["rank"] for e in events] == [1, 2, 3]
        assert [e.record["extra"]["title"] for e in events] == ["'t0'", "'t1'", "'t2'"]

    async def test_the_answer_is_recorded_only_when_there_is_one(
        self, make_engine, log_records
    ):
        """`search.ok` reduces it to a bool; this is what recovers the prose."""
        p = StubProvider()
        engine = make_engine(p)
        engine.config.logging.log_content = True

        await engine.search(SearchQuery(query="q"))
        assert not [r for r in log_records if r.record["message"] == "search.answer"]

        p.answer = "WAL allows one writer and many readers."
        await engine.search(SearchQuery(query="q"))
        (event,) = [r for r in log_records if r.record["message"] == "search.answer"]
        assert "one writer" in event.record["extra"]["answer"]

    async def test_a_failure_records_the_sanitised_message_only(
        self, make_engine, log_records
    ):
        engine = make_engine(StubProvider(fail=QuotaExhausted("serper")))
        with pytest.raises(SearchFailed):
            await engine.search(SearchQuery(query="q"))

        fields = self._event(log_records, "search.failed").record["extra"]
        assert fields["kind"] == "QuotaExhausted"
        # `exc.message`, not `str(exc)`: the latter is what the adapters strip
        # the httpx exception to avoid, and it carries the provider prefix.
        assert fields["reason"] == "quota exhausted"
        assert fields["retryable"] is False

    async def test_an_unresolvable_provider_is_reported_before_dispatch(
        self, make_engine, log_records
    ):
        engine = make_engine(StubProvider(), StubProvider("linkup"))
        with pytest.raises(SearchFailed):
            await engine.search(SearchQuery(query="q"), provider="google")

        fields = self._event(log_records, "search.rejected").record["extra"]
        assert "serper" in fields["enabled"] and "linkup" in fields["enabled"]
        assert fields["requested"] == "'google'"

    async def test_a_forged_provider_name_cannot_break_the_line(
        self, make_engine, log_records
    ):
        engine = make_engine()
        with pytest.raises(SearchFailed):
            await engine.search(
                SearchQuery(query="q"), provider="x\nWARNING fake.event"
            )

        fields = self._event(log_records, "search.rejected").record["extra"]
        assert "\n" not in fields["requested"]

    async def test_the_composed_notice_rides_search_ok(
        self, make_engine, log_records
    ):
        class Empty(StubProvider):
            @override
            async def search(self, q):
                return ProviderResult(provider=self.name, results=[])

        engine = make_engine(Empty("serper"), StubProvider("linkup"))
        await engine.search(SearchQuery(query="q"), provider="serper")

        fields = self._event(log_records, "search.ok").record["extra"]
        assert "No results from serper." in fields["notice"]
        assert "linkup" in fields["notice"]

    async def test_the_answer_is_a_bool_on_search_ok(self, make_engine, log_records):
        p = StubProvider()
        engine = make_engine(p)

        await engine.search(SearchQuery(query="q"))
        first = self._event(log_records, "search.ok")
        assert first.record["extra"]["answer"] is False

        p.answer = "None."
        await engine.search(SearchQuery(query="q"))
        oks = [r for r in log_records if r.record["message"] == "search.ok"]
        assert oks[-1].record["extra"]["answer"] is True

    async def test_the_cap_lengths_ride_their_own_event(
        self, make_engine, log_records
    ):
        """`search.cap` is the measurement, and it carries counts only.

        The caps are applied inside the adapter, before any response is
        recorded, so the length one discarded exists nowhere else -- which is
        why it rides a dedicated event rather than a field on `search.ok`, and
        why it is emitted whatever `log_content` says: these are counts, not
        caller content, and a measurement that only ran with content logging on
        would not be measuring the default deployment.
        """

        class Clipping(StubProvider):
            @override
            async def search(self, q: SearchQuery) -> ProviderResult:
                result = await super().search(q)
                result.results[0]._uncapped_chars = 812
                return result

        engine = make_engine(Clipping())
        await engine.search(SearchQuery(query="sqlite wal mode"))

        assert engine.config.logging.log_content is False
        assert not [r for r in log_records if r.record["message"] == "search.result"]

        (event,) = [r for r in log_records if r.record["message"] == "search.cap"]
        fields = event.record["extra"]
        assert fields["rank"] == 1
        assert fields["field"] == "snippet"
        assert fields["cap"] == 500
        assert fields["chars"] == len("a snippet")
        assert fields["uncapped_chars"] == 812
        # The correlation handle rides along from the base logger, the way it
        # does on `search.result`.
        ok = self._event(log_records, "search.ok").record["extra"]
        assert fields["qhash"] == ok["qhash"]
        assert fields["provider"] == ok["provider"]
        # Counts only: nothing carrying a hit's title, URL or text reaches this
        # line.
        assert not {"title", "url", "snippet", "text"} & set(fields)

    async def test_a_result_with_no_capped_field_is_not_measured(
        self, make_engine, log_records
    ):
        """No snippet and no extract means no cap ran, so nothing was discarded.

        The population is the hits a cap actually saw, which is the
        denominator the "how often does it bite" question needs.
        """

        class Untexted(StubProvider):
            @override
            async def search(self, q: SearchQuery) -> ProviderResult:
                return ProviderResult(
                    provider=self.name,
                    results=[Result(title="t", url="https://x.test/a")],
                    cost_usd=0.001,
                )

        await make_engine(Untexted()).search(SearchQuery(query="q"))

        assert not [r for r in log_records if r.record["message"] == "search.cap"]

    async def test_an_extract_is_measured_against_the_other_cap(
        self, make_engine, log_records
    ):
        """`field` is which cap applied, and it decides which limit is named."""

        class Content(StubProvider):
            @override
            async def search(self, q: SearchQuery) -> ProviderResult:
                hit = Result(title="t", url="https://x.test/a", text="body")
                hit._uncapped_chars = 9000
                return ProviderResult(
                    provider=self.name, results=[hit], cost_usd=0.001
                )

        await make_engine(Content()).search(SearchQuery(query="q"))

        (event,) = [r for r in log_records if r.record["message"] == "search.cap"]
        fields = event.record["extra"]
        assert fields["field"] == "text"
        assert fields["cap"] == 2000
        assert fields["chars"] == len("body")
        assert fields["uncapped_chars"] == 9000

    async def test_the_cap_line_follows_search_oks_provider_rule(
        self, make_engine, log_records
    ):
        """The line names the first attempt of the call, as every event of that
        call does; a substitute is named by `search.fallback` and by the
        response's own `provider`."""

        class Measured(StubProvider):
            @override
            async def search(self, q: SearchQuery) -> ProviderResult:
                result = await super().search(q)
                result.results[0]._uncapped_chars = 812
                return result

        engine = make_engine(
            Measured("serper", fail=ProviderError("serper", "upstream 503")),
            Measured("linkup"),
            default="serper",
            fallback=["linkup"],
        )

        r = await engine.search(SearchQuery(query="x y"))

        assert r.provider == "linkup"
        (event,) = [r for r in log_records if r.record["message"] == "search.cap"]
        assert event.record["extra"]["provider"] == "serper"
        assert event.record["extra"]["uncapped_chars"] == 812


class TestUsageRecording:
    """The dashboard's search half: one terminal record per call, no more.

    A fallback-served search records the *fallback* and one row -- the intermediate
    default failure stays in the log stream and the health board, because the
    dashboard counts what was spent and returned, not every attempt.
    """

    async def test_a_success_records_provider_cost_and_results(self, make_engine):
        usage = UsageRecorder()
        await make_engine(usage=usage).search(SearchQuery(query="q"))

        (entry,) = _usage_snapshot(usage)["recent"]
        assert entry["tool"] == "search"
        assert entry["provider"] == "serper"
        assert entry["cost_usd"] == 0.001
        assert entry["results"] == 1
        assert entry["fell_back"] is False
        assert entry["error"] is None

    async def test_a_terminal_failure_records_the_class_and_attempted_provider(
        self, make_engine
    ):
        usage = UsageRecorder()
        engine = make_engine(StubProvider(fail=QuotaExhausted("serper")), usage=usage)
        with pytest.raises(SearchFailed):
            await engine.search(SearchQuery(query="q"))

        (entry,) = _usage_snapshot(usage)["recent"]
        assert entry["error"] == "QuotaExhausted"
        assert entry["provider"] == "serper"
        assert entry["cost_usd"] == 0.0
        assert entry["results"] == 0
        assert entry["fell_back"] is False

    async def test_a_fallback_served_call_records_only_the_fallback(self, make_engine):
        usage = UsageRecorder()
        serper = StubProvider("serper", fail=ProviderError("serper", "503"))
        linkup = StubProvider("linkup")
        engine = make_engine(
            serper, linkup, default="serper", fallback=["linkup"], usage=usage
        )
        await engine.search(SearchQuery(query="q"))

        recent = _usage_snapshot(usage)["recent"]
        assert len(recent) == 1, "the failed default is not a terminal outcome"
        assert recent[0]["provider"] == "linkup"
        assert recent[0]["fell_back"] is True
        assert _usage_snapshot(usage)["totals"]["fallbacks"] == 1

    async def test_an_exhausted_ladder_records_the_tried_default(self, make_engine):
        usage = UsageRecorder()
        serper = StubProvider("serper", fail=ProviderError("serper", "503"))
        linkup = StubProvider("linkup", fail=ProviderError("linkup", "502"))
        engine = make_engine(
            serper, linkup, default="serper", fallback=["linkup"], usage=usage
        )
        with pytest.raises(SearchFailed):
            await engine.search(SearchQuery(query="q"))

        (entry,) = _usage_snapshot(usage)["recent"]
        assert entry["provider"] == "serper"
        assert entry["fell_back"] is True
        assert entry["error"] == "ProviderError"

    async def test_a_pre_dispatch_reject_records_nothing(self, make_engine):
        """Nothing was billed; the error is model-facing, not usage."""
        usage = UsageRecorder()
        engine = make_engine(StubProvider("serper"), StubProvider("linkup"), usage=usage)
        with pytest.raises(SearchFailed):
            await engine.search(SearchQuery(query="q"), provider="google")

        assert _usage_snapshot(usage)["recent"] == []

    async def test_no_recorder_means_nothing_is_counted(self, make_engine):
        """The optional default keeps every existing two-argument call valid."""
        await make_engine().search(SearchQuery(query="q"))


class TestSpecialTokenEscaping:
    """Escaping on the search path: result text leaves escaped, counted on search.ok.

    The engine escapes the response object it returns -- before the decision
    line is emitted, so the count has a home, and before the agent's retrieval
    material is assembled from the same objects. The serialization boundary
    re-checks the same escape (tests/test_sanitize.py); together the two passes
    are one rule, because the escape is idempotent.
    """

    @staticmethod
    def _ok_fields(records) -> dict[str, Any]:
        (rec,) = (r for r in records if r.record["message"] == "search.ok")
        return rec.record["extra"]

    async def test_result_text_is_escaped_before_it_leaves(
        self, make_engine, log_records
    ):
        p = StubProvider(
            results=[
                Result(
                    title="a title with <start_of_turn>",
                    url="https://example.com/tokens",
                    text="the page says <|endoftext|> and [INST] hi",
                )
            ]
        )
        r = await make_engine(p).search(SearchQuery(query="special tokens"))
        assert r.results[0].title == f"a title with <{ZWSP}start_of_turn>"
        assert r.results[0].text == (
            f"the page says <{ZWSP}|endoftext|> and [{ZWSP}INST] hi"
        )
        assert r.results[0].url == "https://example.com/tokens"
        assert self._ok_fields(log_records)["sanitized"] == 3

    async def test_the_answer_tier_escapes_too(self, make_engine, log_records):
        p = StubProvider()
        p.answer = "an answer quoting <|im_end|>"
        r = await make_engine(p).search(SearchQuery(query="special tokens"))
        assert r.answer == f"an answer quoting <{ZWSP}|im_end|>"
        assert self._ok_fields(log_records)["sanitized"] == 1

    async def test_a_clean_result_counts_zero(self, make_engine, log_records):
        await make_engine().search(SearchQuery(query="sqlite wal mode"))
        assert self._ok_fields(log_records)["sanitized"] == 0

    async def test_a_reread_response_is_not_escaped_again(
        self, make_engine, log_records
    ):
        """The cache re-read, at the object level: the first serve escapes the
        text it is handed, and serving the same response object again escapes
        nothing -- once in total, and the counts say so."""
        shared = [
            Result(
                title="t",
                url="https://example.com/a",
                text="raw <|im_start|> raw",
            )
        ]
        p = StubProvider(results=shared)
        engine = make_engine(p)
        first = await engine.search(SearchQuery(query="special tokens"))
        second = await engine.search(SearchQuery(query="special tokens"))
        assert first.results[0].text == f"raw <{ZWSP}|im_start|> raw"
        assert second.results[0].text == first.results[0].text
        counts = [
            r.record["extra"]["sanitized"]
            for r in log_records
            if r.record["message"] == "search.ok"
        ]
        assert counts == [1, 0]
