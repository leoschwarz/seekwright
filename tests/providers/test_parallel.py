"""Parallel provider: response parsing, request shape, cost and wiring.

The REST fallback is driven through an ``httpx.MockTransport`` (the client is
injected). The free fallback shares :func:`parse_results`, so the MCP-specific
surface -- the tool arguments and the text-to-JSON parser -- is tested without a
session; the session lifecycle itself belongs to ``exa_mcp`` and is covered
there.
"""

import json
from datetime import UTC, datetime, timedelta
from typing import Any, cast

import httpx
import pytest

from seekwright.config import Config, ProviderConfig
from seekwright.factory import build_providers
from seekwright.models import SearchQuery
from seekwright.providers.base import ProviderError, QuotaExhausted
from seekwright.providers.parallel import (
    ENDPOINT,
    ParallelMcpProvider,
    ParallelProvider,
    parse_results,
)

SAMPLE: dict[str, Any] = {
    "search_id": "search_cad0a6d2dec046bd95ae900527d880e7",
    "results": [
        {
            "url": "https://docs.python.org/3/whatsnew/3.14.html",
            "title": "What's New In Python 3.14",
            "publish_date": "2025-10-07",
            "excerpts": [
                (
                    "Python 3.14 is the newest major release of the Python "
                    "programming language."
                ),
                "It contains many new features and optimizations.",
            ],
        },
        {
            "url": "https://example.com/untitled",
            "title": None,
            "publish_date": None,
            "excerpts": ["A page Parallel could not name."],
        },
    ],
    "warnings": None,
    "session_id": "session_8a911eb27c7a4afaa20d0d9dc98d07c0",
}


def provider(client: httpx.AsyncClient | None = None, **kw) -> ParallelProvider:
    kw.setdefault("text_chars", 2000)
    kw.setdefault("timeout", 15.0)
    return ParallelProvider(client or httpx.AsyncClient(), "test-key", **kw)


def mock_client(handler) -> httpx.AsyncClient:
    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


def _body(request: httpx.Request) -> dict[str, Any]:
    return json.loads(request.content)


class TestParsing:
    def test_extracts_all_records(self):
        results = parse_results(SAMPLE, limit=10, text_chars=2000)
        assert len(results) == 2
        assert results[0].title == "What's New In Python 3.14"
        assert results[0].url == "https://docs.python.org/3/whatsnew/3.14.html"

    def test_excerpts_are_joined_into_text(self):
        results = parse_results(SAMPLE, limit=10, text_chars=2000)
        text = results[0].text or ""
        assert "newest major release" in text
        assert "new features and optimizations" in text

    def test_honours_the_limit(self):
        assert len(parse_results(SAMPLE, limit=1, text_chars=2000)) == 1

    def test_text_is_truncated_and_flagged(self):
        results = parse_results(SAMPLE, limit=10, text_chars=40)
        assert len(results[0].text or "") <= 41  # the ellipsis is one char
        assert results[0].text_truncated is True

    def test_short_text_is_not_flagged(self):
        assert parse_results(SAMPLE, limit=10, text_chars=2000)[0].text_truncated is None

    def test_published_date_passes_through_and_is_never_invented(self):
        results = parse_results(SAMPLE, limit=10, text_chars=2000)
        assert results[0].published_date == "2025-10-07"
        assert results[1].published_date is None

    def test_a_null_title_falls_back_to_the_url(self):
        results = parse_results(SAMPLE, limit=10, text_chars=2000)
        assert results[1].title == "https://example.com/untitled"

    def test_snippet_is_never_filled(self):
        # A content backend fills `text`; a snippet would duplicate its prefix.
        assert all(r.snippet is None for r in parse_results(SAMPLE, 10, 2000))

    def test_records_without_a_url_are_dropped(self):
        data = {"results": [{"title": "No url", "excerpts": ["x"]}]}
        assert parse_results(data, limit=10, text_chars=2000) == []

    def test_non_dict_records_are_skipped(self):
        data = {"results": ["nonsense", {"url": "https://a.example", "excerpts": []}]}
        assert len(parse_results(data, limit=10, text_chars=2000)) == 1

    def test_missing_results_is_empty_not_an_error(self):
        assert parse_results({"results": None}, limit=10, text_chars=2000) == []
        assert parse_results({}, limit=10, text_chars=2000) == []

    def test_a_non_dict_payload_is_empty_not_an_error(self):
        assert parse_results([1, 2, 3], limit=10, text_chars=2000) == []


class TestRequestShape:
    async def test_sends_post_with_key_header_and_body(self):
        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, json=SAMPLE)

        p = provider(mock_client(handler))
        await p.search(SearchQuery(query="python 3.14", max_results=3))

        request = seen["request"]
        assert request.method == "POST"
        assert str(request.url) == ENDPOINT
        assert request.headers["x-api-key"] == "test-key"
        body = _body(request)
        assert body["search_queries"] == ["python 3.14"]
        assert body["mode"] == "fast"
        assert body["advanced_settings"]["max_results"] == 3

    async def test_mode_is_configurable(self):
        seen: dict[str, Any] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen.update(_body(request))
            return httpx.Response(200, json=SAMPLE)

        p = provider(mock_client(handler), mode="advanced")
        await p.search(SearchQuery(query="q"))
        assert seen["mode"] == "advanced"

    async def test_domains_go_to_source_policy_and_the_query_is_verbatim(self):
        seen: dict[str, Any] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen.update(_body(request))
            return httpx.Response(200, json=SAMPLE)

        p = provider(mock_client(handler))
        await p.search(
            SearchQuery(
                query="wal mode",
                include_domains=["sqlite.org"],
                exclude_domains=["spam.example"],
            )
        )

        policy = seen["advanced_settings"]["source_policy"]
        assert policy["include_domains"] == ["sqlite.org"]
        assert policy["exclude_domains"] == ["spam.example"]
        # Native filters: the query is not folded into `site:` operators.
        assert seen["search_queries"] == ["wal mode"]

    async def test_recency_sets_after_date(self):
        seen: dict[str, Any] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen.update(_body(request))
            return httpx.Response(200, json=SAMPLE)

        p = provider(mock_client(handler))
        await p.search(SearchQuery(query="q", recency="month"))

        expected = (datetime.now(UTC) - timedelta(days=30)).date().isoformat()
        policy = seen["advanced_settings"]["source_policy"]
        assert policy["after_date"] == expected

    async def test_country_sets_location(self):
        seen: dict[str, Any] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen.update(_body(request))
            return httpx.Response(200, json=SAMPLE)

        p = provider(mock_client(handler))
        await p.search(SearchQuery(query="q", country="de"))
        assert seen["advanced_settings"]["location"] == "de"

    async def test_unset_filters_are_absent(self):
        seen: dict[str, Any] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen.update(_body(request))
            return httpx.Response(200, json=SAMPLE)

        p = provider(mock_client(handler))
        await p.search(SearchQuery(query="q"))

        advanced = seen["advanced_settings"]
        assert "source_policy" not in advanced
        assert "location" not in advanced

    async def test_exclude_is_still_sent_and_the_drop_is_noticed(self):
        seen: dict[str, Any] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen.update(_body(request))
            return httpx.Response(200, json=SAMPLE)

        p = provider(mock_client(handler))
        result = await p.search(
            SearchQuery(
                query="q",
                include_domains=["python.org"],
                exclude_domains=["spam.example"],
            )
        )

        # Sent verbatim even though Parallel ignores it while include is set...
        policy = seen["advanced_settings"]["source_policy"]
        assert policy["exclude_domains"] == ["spam.example"]
        # ...and the caller is told, rather than believing it applied.
        assert "exclude_domains" in (result.notice or "")

    async def test_language_is_noticed_while_country_is_honoured(self):
        seen: dict[str, Any] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen.update(_body(request))
            return httpx.Response(200, json=SAMPLE)

        p = provider(mock_client(handler))
        result = await p.search(SearchQuery(query="q", country="de", language="de"))

        assert seen["advanced_settings"]["location"] == "de"
        assert "language" in (result.notice or "")
        assert "country" not in (result.notice or "").lower()

    async def test_safe_search_is_noticed(self):
        """Parallel has no safety parameter on either fallback.

        Both values are drops; `None` is not, which is the
        `test_a_fully_honoured_query_carries_no_notice` case below.
        """
        p = provider(mock_client(lambda _: httpx.Response(200, json=SAMPLE)))
        for value in (True, False):
            result = await p.search(SearchQuery(query="q", safe_search=value))
            assert result.notice == (
                "cannot filter by safe-search; that constraint was ignored"
            )

    async def test_a_fully_honoured_query_carries_no_notice(self):
        p = provider(mock_client(lambda _: httpx.Response(200, json=SAMPLE)))
        result = await p.search(
            SearchQuery(
                query="q",
                include_domains=["python.org"],
                country="de",
                recency="week",
            )
        )
        assert result.notice is None

    async def test_upstream_warnings_are_surfaced(self):
        warned = dict(SAMPLE, warnings=[{"type": "quality", "message": "thin index"}])
        p = provider(mock_client(lambda _: httpx.Response(200, json=warned)))
        result = await p.search(SearchQuery(query="q"))
        assert "thin index" in (result.notice or "")

    async def test_reports_its_flat_cost_on_the_result(self):
        p = provider(mock_client(lambda _: httpx.Response(200, json=SAMPLE)))
        result = await p.search(SearchQuery(query="q", max_results=5))
        assert result.provider == "parallel"
        assert result.cost_usd == pytest.approx(1.00 / 1000.0)


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
            raise httpx.ConnectError("connection refused to x-api-key: test-key")

        with pytest.raises(ProviderError) as exc:
            await provider(mock_client(handler)).search(SearchQuery(query="q"))
        # The message must not carry the underlying exception: httpx errors can
        # echo the request headers, and those hold the key.
        assert exc.value.message == "network error"
        assert "test-key" not in str(exc.value)


class TestCost:
    def test_cost_does_not_scale_with_result_count(self):
        p = provider()
        assert p.cost_for(1) == p.cost_for(20) == pytest.approx(0.001)

    def test_a_pinned_mode_price_is_reflected(self):
        assert provider(cost_per_1k=5.00).cost_for(5) == pytest.approx(0.005)

    def test_the_free_fallback_costs_nothing(self):
        # Inherited `cost_for`: a zero `cost_per_1k` returns zero whatever the
        # result count.
        assert ParallelMcpProvider().cost_for(20) == 0.0


class TestMcpSurface:
    def test_parse_reads_the_json_text_channel(self):
        results = ParallelMcpProvider()._parse(json.dumps(SAMPLE), limit=10)
        assert len(results) == 2
        assert results[0].url == "https://docs.python.org/3/whatsnew/3.14.html"
        assert results[1].title == "https://example.com/untitled"

    def test_parse_of_non_json_is_a_provider_error(self):
        with pytest.raises(ProviderError, match="malformed JSON"):
            ParallelMcpProvider()._parse("not json", limit=10)

    def test_tool_args_carry_the_query_twice(self):
        args = ParallelMcpProvider()._tool_args(SearchQuery(query="rust async"))
        assert args == {"objective": "rust async", "search_queries": ["rust async"]}


class TestWiring:
    def test_built_only_when_a_key_is_present(self, monkeypatch):
        cfg = Config(providers={"parallel": ProviderConfig()})

        monkeypatch.delenv("SEEKWRIGHT_PARALLEL_API_KEY", raising=False)
        assert "parallel" not in build_providers(cfg, httpx.AsyncClient())

        monkeypatch.setenv("SEEKWRIGHT_PARALLEL_API_KEY", "k")
        built = build_providers(cfg, httpx.AsyncClient())
        assert isinstance(built["parallel"], ParallelProvider)

    def test_config_can_correct_the_cost(self, monkeypatch):
        monkeypatch.setenv("SEEKWRIGHT_PARALLEL_API_KEY", "k")
        cfg = Config(providers={"parallel": ProviderConfig(cost_per_1k=5.00)})
        built = build_providers(cfg, httpx.AsyncClient())
        assert built["parallel"].cost_per_1k == 5.00

    def test_an_unset_cost_falls_back_to_the_adapter_default(self, monkeypatch):
        monkeypatch.setenv("SEEKWRIGHT_PARALLEL_API_KEY", "k")
        cfg = Config(providers={"parallel": ProviderConfig()})
        built = build_providers(cfg, httpx.AsyncClient())
        assert built["parallel"].cost_per_1k == 1.00

    def test_mode_reaches_the_instance(self, monkeypatch):
        monkeypatch.setenv("SEEKWRIGHT_PARALLEL_API_KEY", "k")
        cfg = Config(providers={"parallel": ProviderConfig(mode="advanced")})
        built = build_providers(cfg, httpx.AsyncClient())
        parallel = cast(ParallelProvider, built["parallel"])
        assert parallel._mode == "advanced"

    def test_parallel_free_builds_keyless(self, monkeypatch):
        monkeypatch.delenv("SEEKWRIGHT_PARALLEL_API_KEY", raising=False)
        cfg = Config(providers={"parallel:free": ProviderConfig()})
        built = build_providers(cfg, httpx.AsyncClient())

        free = built["parallel:free"]
        assert isinstance(free, ParallelMcpProvider)
        assert free.name == "parallel:free"
        assert free.cost_per_1k == 0.0
