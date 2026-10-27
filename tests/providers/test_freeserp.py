"""FreeSerp provider: response parsing, request shape, cost and wiring.

The fixture is the live ``index=web`` payload, trimmed to two results (probed
2026-10-14; the full shape is in ``docs/reference/providers.md``). The
request-shape tests drive the provider through an ``httpx.MockTransport``,
which is possible here because the client is injected.
"""

from datetime import UTC, datetime, timedelta
from typing import Any

import httpx
import pytest

from seekwright import PROJECT_URL
from seekwright.config import (
    FREE_PROVIDERS,
    KEYLESS_PROVIDERS,
    KNOWN_PROVIDERS,
    PROVIDERS_REQUIRING_KEY,
    Config,
    ProviderConfig,
)
from seekwright.factory import build_providers
from seekwright.models import SearchQuery
from seekwright.providers.base import ProviderError, QuotaExhausted
from seekwright.providers.freeserp import AGENT, MAX_SIZE, FreeserpProvider

SAMPLE: dict[str, Any] = {
    "ok": True,
    "index": "web",
    "query": "python asyncio tutorial",
    "total": 30,
    "total_note": (
        "FreeSerp Global returns the top 100 candidates (after de-duplication); "
        "there is no exhaustive hit count"
    ),
    "count": 2,
    "from": 0,
    "size": 2,
    "sort": "relevance",
    "ranking": "bm25_trust",
    "filters": {},
    "took_ms": 4,
    "engine_ms": 1,
    "cached": False,
    "results": [
        {
            "url": "https://www.testmuai.com/blog/python-asyncio/",
            "domain": "testmuai.com",
            "title": "Python Asyncio Tutorial: A Complete Guide",
            "snippet": (
                "In this Python asyncio tutorial, we will explore the basics of "
                "asynchronous programming and how the event loop schedules "
                "coroutines."
            ),
            "language": "en",
            "published_at": "2024-10-04",
            "crawled_at": "2026-07-12",
            "score": 949.36,
            "site": None,
            "source": {
                "index": "FreeSerp Global",
                "captured_at": "2026-07-12T05:28:08Z",
                "digest": "sha1:TPKDS6VQNUOUWHKQOSCZMWK3NRK7BBDR",
            },
        },
        {
            "url": "https://realpython.com/async-io-python/",
            "domain": "realpython.com",
            "title": "Async IO in Python: A Complete Walkthrough",
            "snippet": "A complete walkthrough of async IO in Python.",
            "language": "en",
            "published_at": None,
            "crawled_at": "2026-06-30",
            "score": 812.5,
            "site": {"dr": 78, "category": None},
            "source": {"index": "FreeSerp Global"},
        },
    ],
    "related_apis": {
        "note": "Companion APIs from the same team — use these to act on what you find here.",
        "news_search": {"endpoint": "https://freenewsapi.ai/v1/search"},
    },
}


def provider(client: httpx.AsyncClient | None = None, **kw) -> FreeserpProvider:
    return FreeserpProvider(client or httpx.AsyncClient(), **kw)


def mock_client(handler) -> httpx.AsyncClient:
    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


class TestParsing:
    def test_extracts_all_records(self):
        results = provider()._parse(SAMPLE, limit=10)
        assert len(results) == 2
        assert results[0].title == "Python Asyncio Tutorial: A Complete Guide"
        assert results[0].url == "https://www.testmuai.com/blog/python-asyncio/"
        assert results[1].url == "https://realpython.com/async-io-python/"

    def test_honours_the_limit(self):
        assert len(provider()._parse(SAMPLE, limit=1)) == 1

    def test_snippet_is_filled_and_text_never_is(self):
        """A SERP backend: the record's `snippet` is the only text there is."""
        results = provider()._parse(SAMPLE, limit=10)
        assert results[0].snippet is not None
        assert all(r.text is None for r in results)

    def test_snippet_is_truncated(self):
        results = provider(snippet_chars=40)._parse(SAMPLE, limit=10)
        assert len(results[0].snippet or "") <= 41  # the ellipsis is one char

    def test_published_at_is_the_date(self):
        assert provider()._parse(SAMPLE, limit=10)[0].published_date == "2024-10-04"

    def test_crawled_at_stands_in_when_published_at_is_missing(self):
        """Their docs say the declared date is missing for many pages."""
        assert provider()._parse(SAMPLE, limit=10)[1].published_date == "2026-06-30"

    @pytest.mark.parametrize("empty", [None, "", 0])
    def test_a_falsy_published_at_falls_through_to_crawled_at(self, empty):
        record = {
            "title": "t",
            "url": "https://example.com/a",
            "published_at": empty,
            "crawled_at": "2026-01-02",
        }
        results = provider()._parse({"results": [record]}, limit=10)
        assert results[0].published_date == "2026-01-02"

    def test_no_date_is_invented_when_neither_is_present(self):
        record = {"title": "t", "url": "https://example.com/a"}
        results = provider()._parse({"results": [record]}, limit=10)
        assert results[0].published_date is None

    def test_score_passes_through_as_is(self):
        """Their BM25 x trust number, not a normalised relevance."""
        results = provider()._parse(SAMPLE, limit=10)
        assert results[0].score == pytest.approx(949.36)
        assert results[1].score == pytest.approx(812.5)

    @pytest.mark.parametrize("bad_score", ["949.36", {"value": 1}, [1], True, None])
    def test_a_non_numeric_score_is_dropped(self, bad_score):
        record = {"title": "t", "url": "https://example.com/a", "score": bad_score}
        results = provider()._parse({"results": [record]}, limit=10)
        assert results[0].score is None

    def test_records_without_a_url_are_dropped(self):
        assert provider()._parse({"results": [{"title": "t"}]}, limit=10) == []

    def test_records_without_a_title_are_dropped(self):
        assert (
            provider()._parse({"results": [{"url": "https://example.com"}]}, limit=10)
            == []
        )

    def test_non_dict_records_are_skipped(self):
        data = {"results": ["nonsense", {"title": "t", "url": "https://example.com"}]}
        assert len(provider()._parse(data, limit=10)) == 1

    def test_missing_results_is_empty_not_an_error(self):
        assert provider()._parse({"results": None}, limit=10) == []
        assert provider()._parse({}, limit=10) == []

    def test_the_cross_promotion_block_is_ignored(self):
        """``related_apis`` advertises the operator's other services.

        It is a promotion, not a result source: the mapping reads
        ``results[]`` and nothing else, so a body that carries the block and
        one that does not parse identically.
        """
        assert "related_apis" in SAMPLE
        without = {k: v for k, v in SAMPLE.items() if k != "related_apis"}
        assert provider()._parse(SAMPLE, limit=10) == provider()._parse(without, limit=10)


class TestEngineFallback:
    """`engine_fallback: true` is a refusal, not a caveat.

    When their web engine does not answer, `index=web` is served from the
    *sites* index instead -- site profiles rather than search results -- and
    the wire shape has no field that could carry that substitution. The fallback
    fails so the walk moves on, and the next fallback gets the call.
    """

    def test_the_healthy_fixture_does_not_carry_the_key(self):
        assert "engine_fallback" not in SAMPLE

    async def test_the_substituted_index_fails_the_fallback(self):
        body = {
            **SAMPLE,
            "index": "sites",
            "engine_fallback": True,
            "engine_error": "engine_unavailable",
            "requested_index": "web",
        }
        p = provider(mock_client(lambda _: httpx.Response(200, json=body)))

        with pytest.raises(ProviderError) as exc:
            await p.search(SearchQuery(query="q"))

        assert exc.value.message == "upstream index unavailable"
        # Transient, like the 5xx row: neither auth nor quota, and the walk
        # may try the fallback again later.
        assert exc.value.retryable is True
        assert not isinstance(exc.value, QuotaExhausted)

    async def test_the_upstream_error_text_is_not_interpolated(self):
        body = {
            **SAMPLE,
            "engine_fallback": True,
            "engine_error": "engine_unavailable: https://internal.example/?k=secret",
        }
        p = provider(mock_client(lambda _: httpx.Response(200, json=body)))

        with pytest.raises(ProviderError) as exc:
            await p.search(SearchQuery(query="q"))

        assert exc.value.message == "upstream index unavailable"
        assert "internal.example" not in str(exc.value)

    async def test_a_false_or_absent_key_maps_normally(self):
        for body in ({**SAMPLE, "engine_fallback": False}, SAMPLE):
            p = provider(mock_client(lambda _, b=body: httpx.Response(200, json=b)))
            result = await p.search(SearchQuery(query="q"))
            assert len(result.results) == 2


class TestRequestShape:
    async def test_sends_get_to_the_web_index_and_self_identifies(self):
        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, json=SAMPLE)

        p = provider(mock_client(handler))
        await p.search(SearchQuery(query="wal mode", max_results=3))

        request = seen["request"]
        assert request.method == "GET"
        assert request.url.path == "/api.php"
        assert request.url.params["index"] == "web"
        assert request.url.params["q"] == "wal mode"
        assert request.url.params["size"] == "3"
        # The operator asks callers to say who they are; nothing validates it.
        assert request.url.params["agent"] == AGENT
        assert request.url.params["website"] == PROJECT_URL

    async def test_size_is_clamped_to_the_endpoint_ceiling(self):
        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, json=SAMPLE)

        p = provider(mock_client(handler))
        await p.search(SearchQuery(query="q", max_results=500))

        assert seen["request"].url.params["size"] == str(MAX_SIZE)

    async def test_a_language_reaches_lang_lowercased(self):
        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, json=SAMPLE)

        p = provider(mock_client(handler))
        await p.search(SearchQuery(query="q", language="DE"))

        # `lang` is an ISO 639-1 code; the schema already guarantees the
        # two-letter form, and this backend has no country parameter at all.
        assert seen["request"].url.params["lang"] == "de"

    async def test_no_lang_is_sent_when_none_was_asked_for(self):
        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, json=SAMPLE)

        p = provider(mock_client(handler))
        await p.search(SearchQuery(query="q"))

        assert "lang" not in seen["request"].url.params

    @pytest.mark.parametrize(
        ("recency", "days"), [("day", 1), ("week", 7), ("month", 30), ("year", 365)]
    )
    async def test_recency_reaches_published_from(self, recency, days):
        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, json=SAMPLE)

        p = provider(mock_client(handler))
        await p.search(SearchQuery(query="q", recency=recency))

        expected = (datetime.now(UTC) - timedelta(days=days)).strftime("%Y-%m-%d")
        assert seen["request"].url.params["published_from"] == expected
        # Open-ended, like Linkup's `fromDate`: no upper bound is sent.
        assert "published_to" not in seen["request"].url.params

    async def test_the_unhonourable_constraints_ride_the_notice_and_send_nothing(self):
        """Domains, country and safe-search have no parameter here, so they are
        named; `recency` and `language` reach their own fields and are not.

        The call site passes the full keyword set: `domains=False`,
        `dates=True`, `geo=False` and `safety=False`, with `language=True` to
        split the geo bucket, so a language beside a country names only the
        country.
        """
        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, json=SAMPLE)

        p = provider(mock_client(handler))
        result = await p.search(
            SearchQuery(
                query="wal mode",
                include_domains=["sqlite.org"],
                exclude_domains=["spam.example"],
                country="de",
                language="de",
                safe_search=True,
            )
        )

        notice = result.notice or ""
        assert "cannot filter by" in notice
        assert "domain" in notice
        assert "country" in notice
        assert "safe-search" in notice
        # The language rode `lang`, so the joined `country/language` token would
        # have claimed a drop that did not happen.
        assert "country/language" not in notice
        assert "language" not in notice.replace("country/language", "")
        # No `site:` operator, no domain field, no country parameter: the
        # constraints are reported, never guessed at.
        params = seen["request"].url.params
        assert params["lang"] == "de"
        for name in (
            "site",
            "include_domains",
            "exclude_domains",
            "country",
            "gl",
            "safe_search",
            "safety",
            "safe",
        ):
            assert name not in params
        assert "site:" not in params["q"]
        assert "sqlite.org" not in params["q"]

    @pytest.mark.parametrize("safe_search", [True, False])
    async def test_a_safe_search_is_noticed_for_both_values(self, safe_search):
        """Both values are drops: FreeSerp has no safety parameter at all.

        `None` is not a drop -- the provider's own default stands and nothing
        was asked -- which is `test_a_honoured_constraint_draws_no_notice`.
        """
        p = provider(mock_client(lambda _: httpx.Response(200, json=SAMPLE)))
        result = await p.search(SearchQuery(query="q", safe_search=safe_search))
        assert result.notice == (
            "cannot filter by safe-search; that constraint was ignored"
        )

    async def test_the_candidate_pool_size_is_not_a_hit_count(self):
        """``total`` is the size of a top-100 pool, not a hit count.

        The response says so itself in ``total_note``, and neither
        ``ProviderResult`` nor ``SearchResponse`` carries a count field, so
        there is nothing to map it onto: it is not a number on the result and
        it is not a dropped constraint to report either.
        """
        p = provider(mock_client(lambda _: httpx.Response(200, json=SAMPLE)))
        result = await p.search(SearchQuery(query="q"))

        assert len(result.results) == SAMPLE["count"] == 2
        assert len(result.results) != SAMPLE["total"]
        assert result.notice is None

    async def test_a_honoured_constraint_draws_no_notice(self):
        p = provider(mock_client(lambda _: httpx.Response(200, json=SAMPLE)))
        result = await p.search(SearchQuery(query="q", language="de", recency="month"))
        assert result.notice is None

    async def test_reports_its_flat_zero_cost_on_the_result(self):
        p = provider(mock_client(lambda _: httpx.Response(200, json=SAMPLE)))
        result = await p.search(SearchQuery(query="q", max_results=5))
        assert result.provider == "freeserp"
        assert result.cost_usd == 0.0


class TestErrors:
    """Only the rows this adapter answers differently.

    The six rows every HTTP adapter owes are pinned once for all of them by
    ``tests/providers/test_provider_contract.py``. What stays here is this adapter's quota
    statuses, its own message wording, and the leak regression that proves the
    redaction rule for the place its key actually rides.
    """

    @pytest.mark.parametrize("status", [402, 429])
    async def test_payment_and_rate_limit_are_quota(self, status: int):
        p = provider(mock_client(lambda _: httpx.Response(status, json={})))
        with pytest.raises(QuotaExhausted):
            await p.search(SearchQuery(query="q"))

    async def test_network_error_does_not_echo_the_request(self):
        def handler(_: httpx.Request) -> httpx.Response:
            raise httpx.ConnectError(
                "connection refused to /api.php?agent=seekwright&website=secret-marker"
            )

        p = provider(mock_client(handler))
        with pytest.raises(ProviderError) as exc:
            await p.search(SearchQuery(query="q"))
        # The message must not carry the underlying exception: httpx errors echo
        # the request.
        assert exc.value.message == "network error"
        assert "secret-marker" not in str(exc.value)


class TestCost:
    def test_it_cannot_bill(self):
        p = provider()
        assert p.cost_per_1k == 0.0
        assert p.cost_for(1) == p.cost_for(20) == 0.0


class TestWiring:
    def test_built_with_no_key_in_the_environment(self, monkeypatch):
        monkeypatch.delenv("SEEKWRIGHT_FREESERP_API_KEY", raising=False)
        cfg = Config(providers={"freeserp": ProviderConfig()})

        built = build_providers(cfg, httpx.AsyncClient())

        assert isinstance(built["freeserp"], FreeserpProvider)
        assert built["freeserp"].cost_per_1k == 0.0

    def test_config_can_correct_the_cost(self, monkeypatch):
        """Reporting only, but an operator may want a figure they recognise."""
        monkeypatch.delenv("SEEKWRIGHT_FREESERP_API_KEY", raising=False)
        cfg = Config(providers={"freeserp": ProviderConfig(cost_per_1k=0.25)})

        built = build_providers(cfg, httpx.AsyncClient())

        assert built["freeserp"].cost_per_1k == 0.25

    def test_it_is_keyless_and_in_the_free_set(self):
        assert "freeserp" in KNOWN_PROVIDERS
        assert "freeserp" not in PROVIDERS_REQUIRING_KEY
        assert "freeserp" in FREE_PROVIDERS
        assert "freeserp" in KEYLESS_PROVIDERS
