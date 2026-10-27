"""Exa's two credential tiers, and the ladder between them.

Exa answers the same endpoint anonymously for free and authenticated for
~$7/1k, so which credential served a search *is* the cost of that search. These
tests are mostly about billing: how many times the paid fallback was called, and
whether the caller was told it happened.

The fallbacks are swapped on the instance with `monkeypatch` rather than injected
through the constructor -- a constructor parameter no production caller passes
would be test scaffolding shipped in `src/`.
"""

import asyncio
from typing import Any

import httpx
import pytest
from mcp.types import CallToolResult, TextContent

from seekwright.config import Config, ProviderConfig
from seekwright.factory import build_providers
from seekwright.models import ProviderResult, Result, SearchQuery
from seekwright.providers.base import ProviderError, QuotaExhausted
from seekwright.providers.exa_mcp import ExaMcpProvider, TieredExaProvider

QUERY = SearchQuery(query="write-ahead logging")


class StubFallback:
    """One credential's worth of Exa, standing in for an MCP session."""

    def __init__(self, *, fail=None, notice=None, cost=0.0):
        self.name = "exa"
        self.cost_per_1k = cost * 1000
        self.calls = 0
        self.closed = False
        self._fail = fail
        self._notice = notice
        self._cost = cost

    async def search(self, _q: SearchQuery) -> ProviderResult:
        self.calls += 1
        if self._fail:
            raise self._fail
        return ProviderResult(
            provider=self.name,
            results=[Result(title="WAL", url="https://sqlite.org/wal.html")],
            cost_usd=self._cost,
            notice=self._notice,
        )

    def cost_for(self, _max_results: int) -> float:
        return self._cost

    async def warmup(self) -> bool:
        return True

    async def aclose(self) -> None:
        self.closed = True


@pytest.fixture
def tiered(monkeypatch):
    def _make(*, free=None, keyed=None, cooldown=60.0):
        provider = TieredExaProvider("key-abc", cooldown_seconds=cooldown)
        monkeypatch.setattr(provider, "_free", free or StubFallback())
        monkeypatch.setattr(provider, "_keyed", keyed or StubFallback(cost=0.007))
        return provider

    return _make


class TestFreeFirst:
    async def test_a_healthy_free_tier_is_never_billed(self, tiered):
        keyed = StubFallback(cost=0.007)
        provider = tiered(keyed=keyed)

        result = await provider.search(QUERY)

        assert keyed.calls == 0, "a working free tier must not reach the API key"
        assert result.cost_usd == 0.0
        assert result.notice is None, "nothing happened worth warning about"

    async def test_the_free_tier_reports_the_provider_the_caller_named(self, tiered):
        """Which fallback ran is a cost detail, not a different backend."""
        result = await tiered().search(QUERY)
        assert result.provider == "exa"


class TestEscalation:
    async def test_a_failed_free_tier_is_retried_on_the_key(self, tiered):
        keyed = StubFallback(cost=0.007)
        provider = tiered(
            free=StubFallback(fail=QuotaExhausted("exa", "rate limited")), keyed=keyed
        )

        result = await provider.search(QUERY)

        assert keyed.calls == 1
        assert result.results, "the escalation is pointless if it returns nothing"
        assert result.cost_usd == 0.007

    async def test_escalation_says_so_and_says_why(self, tiered):
        """An invoice is a bad way to find out the free tier stopped working."""
        provider = tiered(free=StubFallback(fail=ProviderError("exa", "HTTP 503")))

        result = await provider.search(QUERY)

        assert result.notice is not None
        assert "HTTP 503" in result.notice
        assert "API key" in result.notice

    async def test_any_failure_escalates_not_just_a_classified_quota(self, tiered):
        """The rate-limit sniff in `_search_once` has never seen the real
        wording, so the ladder must not depend on it being right."""
        keyed = StubFallback(cost=0.007)
        provider = tiered(
            free=StubFallback(fail=ProviderError("exa", "upstream MCP tool error")),
            keyed=keyed,
        )

        await provider.search(QUERY)

        assert keyed.calls == 1

    async def test_a_dropped_filter_warning_survives_the_escalation(self, tiered):
        """`ignored_constraints` owns this field too, so overwriting it would
        leave a caller unwarned that its domain filter was never applied."""
        provider = tiered(
            free=StubFallback(fail=ProviderError("exa", "HTTP 503")),
            keyed=StubFallback(cost=0.007, notice="cannot filter by domain"),
        )

        result = await provider.search(QUERY)

        assert result.notice is not None
        assert "cannot filter by domain" in result.notice
        assert "API key" in result.notice

    async def test_the_key_is_billed_at_most_once_per_search(self, tiered):
        keyed = StubFallback(cost=0.007)
        provider = tiered(free=StubFallback(fail=ProviderError("exa", "x")), keyed=keyed)

        await provider.search(QUERY)

        assert keyed.calls == 1, "one search must never buy two"


class TestBothFallbacksFail:
    async def test_the_free_failure_is_the_one_reported(self, tiered):
        """"exa: authentication rejected" explains nothing about the rate limit
        the caller actually hit first."""
        provider = tiered(
            free=StubFallback(fail=ProviderError("exa", "HTTP 503")),
            keyed=StubFallback(fail=ProviderError("exa", "authentication rejected")),
        )

        with pytest.raises(ProviderError) as exc:
            await provider.search(QUERY)

        assert "HTTP 503" in str(exc.value)
        # Appended, not substituted: an operator debugging this needs to know the
        # key was tried and what it said.
        assert "authentication rejected" in str(exc.value)

    async def test_the_retry_advice_of_the_original_failure_is_preserved(self, tiered):
        """`QuotaExhausted` is what makes the engine say "do not retry
        immediately"; degrading it to a plain error would invite a retry loop."""
        provider = tiered(
            free=StubFallback(fail=QuotaExhausted("exa", "rate limited")),
            keyed=StubFallback(fail=ProviderError("exa", "network error")),
        )

        with pytest.raises(QuotaExhausted):
            await provider.search(QUERY)


class TestCooldown:
    async def test_a_burned_free_tier_is_not_retried_on_every_call(self, tiered):
        """While a rate limit lasts, trying free first buys a doomed round trip
        per search and nothing else."""
        free = StubFallback(fail=ProviderError("exa", "rate limited"))
        provider = tiered(free=free, cooldown=1000.0)

        await provider.search(QUERY)
        await provider.search(QUERY)

        assert free.calls == 1, "the second call must not re-probe the free tier"

    async def test_the_cooldown_expires_and_free_is_tried_again(
        self, tiered, monkeypatch
    ):
        """Otherwise one blip converts a free deployment into a billed one until
        the process restarts."""
        free = StubFallback(fail=ProviderError("exa", "rate limited"))
        provider = tiered(free=free, cooldown=1000.0)
        await provider.search(QUERY)

        # The deadline is a monotonic loop time, so zero is always in the past.
        monkeypatch.setattr(provider, "_free_blocked_until", 0.0)

        await provider.search(QUERY)
        assert free.calls == 2

    async def test_a_zero_cooldown_always_tries_free_first(self, tiered):
        free = StubFallback(fail=ProviderError("exa", "rate limited"))
        provider = tiered(free=free, cooldown=0.0)

        await provider.search(QUERY)
        await provider.search(QUERY)

        assert free.calls == 2

    async def test_a_call_served_on_the_key_during_cooldown_says_so(self, tiered):
        provider = tiered(
            free=StubFallback(fail=ProviderError("exa", "rate limited")), cooldown=1000.0
        )
        await provider.search(QUERY)

        result = await provider.search(QUERY)

        assert result.notice is not None and "API key" in result.notice
        assert result.cost_usd == 0.007


class TestLifecycle:
    async def test_warmup_opens_only_the_free_fallback(self, monkeypatch):
        """The keyed session is opened on first escalation instead. Warming it
        would not even validate the key: a rejected key still completes the MCP
        handshake and only fails at the tool call."""
        provider = TieredExaProvider(
            "key-abc", url="http://127.0.0.1:1/mcp", timeout=1.0
        )
        keyed = StubFallback()
        monkeypatch.setattr(provider, "_keyed", keyed)

        await provider.warmup()

        assert keyed.calls == 0
        await provider.aclose()

    async def test_aclose_closes_both_fallbacks(self, tiered):
        free, keyed = StubFallback(), StubFallback()
        provider = tiered(free=free, keyed=keyed)

        await provider.aclose()

        assert free.closed and keyed.closed, "a leaked MCP session outlives the server"


class TestCost:
    def test_the_quoted_price_is_the_billed_fallbacks(self, tiered):
        """What a caller might pay, not what a lucky free hit costs."""
        assert tiered().cost_for(5) == pytest.approx(0.007)

    def test_a_free_adapter_costs_nothing_at_any_result_count(self):
        """The per-result surcharge must not invent a price for an unbilled
        tier."""
        free = ExaMcpProvider(name="exa:free", cost_per_1k=0.0)
        assert free.cost_for(20) == 0.0

    def test_the_billed_adapter_still_charges_the_surcharge(self):
        assert ExaMcpProvider(cost_per_1k=7.00).cost_for(20) == pytest.approx(0.017)


class TestUpstreamErrors:
    """`_search_once`'s isError branch: the only place an upstream tool failure
    becomes an exception, and previously untested."""

    def _provider_returning(self, text: str, monkeypatch) -> ExaMcpProvider:
        provider = ExaMcpProvider()

        class StubSession:
            async def call_tool(self, *_args: Any, **_kw: Any) -> CallToolResult:
                return CallToolResult(
                    content=[TextContent(type="text", text=text)], isError=True
                )

        async def _ensure_session() -> Any:
            return StubSession()

        monkeypatch.setattr(provider, "_ensure_session", _ensure_session)
        return provider

    async def test_a_rate_limit_is_classified_as_quota_exhausted(self, monkeypatch):
        provider = self._provider_returning(
            "web_search_exa error (429): rate limited", monkeypatch
        )
        with pytest.raises(QuotaExhausted):
            await provider.search(QUERY)

    async def test_a_rejected_key_is_an_error_not_a_result(self, monkeypatch):
        """Verified live: an invalid key comes back as isError inside a
        successful MCP call, not as a transport failure."""
        provider = self._provider_returning(
            "web_search_exa error (401): Invalid API key", monkeypatch
        )
        with pytest.raises(ProviderError):
            await provider.search(QUERY)

    async def test_the_upstream_error_text_is_not_echoed_to_the_caller(
        self, monkeypatch
    ):
        """It is third-party text on a path that has carried an API key."""
        provider = self._provider_returning(
            "boom: Bearer sk-secret-value", monkeypatch
        )
        with pytest.raises(ProviderError) as exc:
            await provider.search(QUERY)
        assert "sk-secret-value" not in str(exc.value)


class TestWiring:
    def _built(self, names, monkeypatch, key=None):
        if key:
            monkeypatch.setenv("SEEKWRIGHT_EXA_API_KEY", key)
        else:
            monkeypatch.delenv("SEEKWRIGHT_EXA_API_KEY", raising=False)
        cfg = Config(providers={n: ProviderConfig() for n in names})
        return build_providers(cfg, httpx.AsyncClient())

    def test_exa_free_is_built_without_a_key_even_when_one_is_present(
        self, monkeypatch
    ):
        """The point of the name: a deployment that must not spend can say so,
        and an unrelated key in the environment cannot override it."""
        provider = self._built(["exa:free"], monkeypatch, key="key-abc")["exa:free"]

        assert isinstance(provider, ExaMcpProvider)
        assert provider._api_key is None
        assert provider.cost_per_1k == 0.0

    def test_exa_is_tiered_when_a_key_is_present(self, monkeypatch):
        built = self._built(["exa"], monkeypatch, key="key-abc")
        assert isinstance(built["exa"], TieredExaProvider)

    def test_exa_without_a_key_is_not_built(self, monkeypatch):
        """It would be `exa:free` wearing a name that promises a paid fallback."""
        assert self._built(["exa"], monkeypatch) == {}

    def test_exa_without_a_key_is_a_startup_error(self, monkeypatch):
        monkeypatch.delenv("SEEKWRIGHT_EXA_API_KEY", raising=False)
        cfg = Config(providers={"exa": ProviderConfig()})
        assert cfg.missing_api_keys() == ["exa"]

    def test_exa_free_never_needs_a_key(self, monkeypatch):
        monkeypatch.delenv("SEEKWRIGHT_EXA_API_KEY", raising=False)
        cfg = Config(providers={"exa:free": ProviderConfig()})
        assert cfg.missing_api_keys() == []

    def test_the_cooldown_is_configurable(self, monkeypatch):
        monkeypatch.setenv("SEEKWRIGHT_EXA_API_KEY", "key-abc")
        cfg = Config(providers={"exa": ProviderConfig(free_cooldown_seconds=5.0)})

        provider = build_providers(cfg, httpx.AsyncClient())["exa"]

        assert isinstance(provider, TieredExaProvider)
        assert provider._cooldown == 5.0

    def test_both_names_can_be_enabled_together(self, monkeypatch):
        """A deployment can offer the free tier and the billed ladder side by
        side; with two enabled there is no default and callers must choose."""
        monkeypatch.setenv("SEEKWRIGHT_EXA_API_KEY", "key-abc")
        cfg = Config(providers={"exa": ProviderConfig(), "exa:free": ProviderConfig()})

        assert cfg.default_provider is None
        assert set(build_providers(cfg, httpx.AsyncClient())) == {"exa", "exa:free"}


async def test_the_ladder_is_reentrant_across_concurrent_searches(tiered):
    """Two searches in flight while the free tier is down must not turn into
    four paid calls."""
    keyed = StubFallback(cost=0.007)
    provider = tiered(
        free=StubFallback(fail=ProviderError("exa", "rate limited")), keyed=keyed
    )

    await asyncio.gather(provider.search(QUERY), provider.search(QUERY))

    assert keyed.calls == 2, "one paid call per search, no more"


class TestEscalationIsVisibleToTheOperator:
    """The ladder tells the *model* in `notice`. This tells the operator.

    `_on_key` already says silence would be "the expensive kind: a deployment
    whose free tier quietly stopped working would keep answering, and the only
    evidence would be the invoice". The notice goes to the caller, who is not
    the party billed -- so the same fact has to reach the log.
    """

    @staticmethod
    def _events(records, name):
        return [r.record["extra"] for r in records if r.record["message"] == name]

    async def test_the_moment_it_stops_being_free_is_a_warning(
        self, tiered, log_records
    ):
        provider = tiered(
            free=StubFallback(fail=ProviderError("exa", "rate limited")), cooldown=1000.0
        )
        await provider.search(QUERY)

        (fields,) = self._events(log_records, "exa.escalated")
        assert fields["reason"] == "rate limited"
        assert fields["cooldown_s"] == 1000.0
        assert fields["cost_usd"] > 0

    async def test_every_subsequent_billed_call_is_recorded(self, tiered, log_records):
        """One line per call the cooldown costs money for.

        Without this, a burned free tier logs once and then bills in silence for
        as long as the cooldown lasts.
        """
        provider = tiered(
            free=StubFallback(fail=ProviderError("exa", "rate limited")), cooldown=1000.0
        )
        await provider.search(QUERY)
        await provider.search(QUERY)
        await provider.search(QUERY)

        cooldowns = self._events(log_records, "exa.cooldown")
        assert len(cooldowns) == 2
        assert all(c["cost_usd"] > 0 for c in cooldowns)
        assert all(0 < c["remaining_s"] <= 1000.0 for c in cooldowns)

    async def test_a_healthy_free_tier_logs_nothing(self, tiered, log_records):
        await tiered().search(QUERY)

        assert self._events(log_records, "exa.escalated") == []
        assert self._events(log_records, "exa.cooldown") == []

    async def test_both_fallbacks_failing_is_an_error(self, tiered, log_records):
        provider = tiered(
            free=StubFallback(fail=ProviderError("exa", "rate limited")),
            keyed=StubFallback(fail=ProviderError("exa", "HTTP 500")),
        )
        with pytest.raises(ProviderError):
            await provider.search(QUERY)

        (fields,) = self._events(log_records, "exa.both_failed")
        assert fields["reason"] == "HTTP 500"
        assert fields["original_reason"] == "rate limited"

    async def test_upstream_error_text_never_reaches_the_log(
        self, monkeypatch, log_records
    ):
        """Companion to the caller-facing redaction test above.

        Same third-party text, same path that has carried an API key -- the log
        store is just a second place it must not land.
        """
        provider = TestUpstreamErrors()._provider_returning(
            "boom: Bearer sk-secret-value", monkeypatch
        )
        with pytest.raises(ProviderError):
            await provider.search(QUERY)

        assert "sk-secret-value" not in str([r.record for r in log_records])
