"""SearXNG provider: response parsing, request shape, cost and wiring.

The fixture is the documented JSON-API payload (see
``docs/reference/providers.md``). The request-shape tests drive the provider
through an ``httpx.MockTransport``, which is possible here and not for the MCP
adapter because the client is injected.
"""

from typing import Any

import httpx
import pytest

from seekwright.config import Config, ProviderConfig
from seekwright.factory import build_providers
from seekwright.models import SearchQuery
from seekwright.providers.base import ProviderError, QuotaExhausted
from seekwright.providers.searxng import SearxngProvider

SAMPLE: dict[str, Any] = {
    "query": "wal mode",
    "results": [
        {
            "title": "Write-Ahead Logging",
            "url": "https://www.sqlite.org/wal.html",
            "content": "The default method by which SQLite implements atomic "
            "commit is a rollback journal.",
            "engines": ["google", "bing"],
            "score": 12.5,
            "publishedDate": "2024-11-03T00:00:00Z",
        },
        {
            "title": "SQLite WAL mode explained",
            "url": "https://example.com/wal-explained",
            "content": "WAL allows readers and one writer to proceed concurrently.",
            "engines": ["startpage"],
            "score": 8,
        },
    ],
    "infoboxes": [],
    "unresponsive_engines": [],
}


def provider(client: httpx.AsyncClient | None = None, **kw) -> SearxngProvider:
    return SearxngProvider(
        client or httpx.AsyncClient(), url="http://searx.internal:8080", **kw
    )


def n_results(n: int) -> list[dict[str, Any]]:
    """`n` minimal well-formed results, distinct so slicing is observable."""
    return [
        {"title": f"hit {i}", "url": f"https://example.com/{i}", "content": f"content {i}"}
        for i in range(n)
    ]


def mock_client(handler) -> httpx.AsyncClient:
    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


class TestParsing:
    def test_extracts_all_records(self):
        results = provider()._parse(SAMPLE, limit=10)
        assert len(results) == 2
        assert results[0].title == "Write-Ahead Logging"
        assert results[0].url == "https://www.sqlite.org/wal.html"
        assert results[1].url == "https://example.com/wal-explained"

    def test_honours_the_limit(self):
        assert len(provider()._parse(SAMPLE, limit=1)) == 1

    def test_content_becomes_the_snippet(self):
        results = provider()._parse(SAMPLE, limit=10)
        assert results[0].snippet
        assert results[0].text is None, "a SERP backend fills snippet, never text"

    def test_snippet_is_truncated(self):
        results = provider(snippet_chars=40)._parse(SAMPLE, limit=10)
        assert len(results[0].snippet or "") <= 41  # the ellipsis is one char

    def test_engines_and_infobox_metadata_are_dropped(self):
        results = provider()._parse(SAMPLE, limit=10)
        dumped = results[0].model_dump()
        assert "engines" not in dumped
        assert all("infobox" not in str(v) for v in dumped.values())

    def test_score_is_kept_when_numeric(self):
        results = provider()._parse(SAMPLE, limit=10)
        assert results[0].score == pytest.approx(12.5)
        assert results[1].score == pytest.approx(8)

    def test_a_non_numeric_score_is_not_coerced(self):
        data = {"results": [{"title": "t", "url": "u", "score": {"weird": 1}}]}
        assert provider()._parse(data, limit=10)[0].score is None

    def test_published_date_kept_only_when_a_string(self):
        results = provider()._parse(SAMPLE, limit=10)
        assert results[0].published_date == "2024-11-03T00:00:00Z"
        assert results[1].published_date is None

    def test_records_without_a_url_are_dropped(self):
        data = {"results": [{"title": "No url here"}]}
        assert provider()._parse(data, limit=10) == []

    def test_records_without_a_title_are_dropped(self):
        data = {"results": [{"url": "https://example.com"}]}
        assert provider()._parse(data, limit=10) == []

    def test_non_dict_records_are_skipped(self):
        data = {"results": ["nonsense", {"title": "t", "url": "u"}]}
        assert len(provider()._parse(data, limit=10)) == 1

    def test_missing_results_is_empty_not_an_error(self):
        assert provider()._parse({"results": None}, limit=10) == []
        assert provider()._parse({}, limit=10) == []


class TestUpstreamFieldGuards:
    """A non-string ``content`` is dropped, not handed to ``truncate_snippet``.

    SearXNG's ``results[].content`` becomes ``Result.snippet`` through
    ``base.truncate_snippet``, which called ``text.split()`` on whatever
    upstream sent. A nested object, list or number there raised
    ``AttributeError`` -- not a ``ProviderError`` -- so it escaped the engine's
    provider-error handling and surfaced as an internal error instead of a field
    the adapter dropped.
    """

    @pytest.mark.parametrize("bad_content", [{"nested": "object"}, ["a", "b"], 7])
    async def test_a_non_string_content_is_dropped_and_the_call_succeeds(
        self, bad_content
    ):
        data = {
            "results": [
                {"title": "t", "url": "https://example.com/a", "content": bad_content}
            ]
        }
        p = provider(mock_client(lambda _: httpx.Response(200, json=data)))
        result = await p.search(SearchQuery(query="wal", max_results=1))
        assert len(result.results) == 1
        assert result.results[0].snippet is None

    async def test_a_string_content_still_reaches_the_model(self):
        """The guard must not change behaviour for a well-formed payload."""
        p = provider(mock_client(lambda _: httpx.Response(200, json=SAMPLE)))
        result = await p.search(SearchQuery(query="wal", max_results=1))
        assert result.results[0].snippet == (
            "The default method by which SQLite implements atomic commit is a "
            "rollback journal."
        )


class TestRequestShape:
    async def test_sends_get_with_json_format_and_no_auth(self):
        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, json=SAMPLE)

        p = provider(mock_client(handler))
        await p.search(SearchQuery(query="wal mode", max_results=2))

        request = seen["request"]
        assert request.method == "GET"
        assert str(request.url).startswith("http://searx.internal:8080/search")
        assert request.url.params["format"] == "json"
        assert request.url.params["pageno"] == "1"
        assert request.url.params["q"] == "wal mode"
        assert not request.headers.get("authorization")
        assert not request.headers.get("x-api-key")

    async def test_recency_maps_onto_time_range(self):
        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, json=SAMPLE)

        p = provider(mock_client(handler))
        await p.search(SearchQuery(query="wal", max_results=2, recency="week"))
        assert seen["request"].url.params["time_range"] == "week"

        await p.search(SearchQuery(query="wal", max_results=2, recency="day"))
        assert seen["request"].url.params["time_range"] == "day"

    async def test_time_range_absent_without_recency(self):
        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, json=SAMPLE)

        p = provider(mock_client(handler))
        await p.search(SearchQuery(query="wal", max_results=2))
        assert "time_range" not in seen["request"].url.params

    async def test_language_is_passed_verbatim(self):
        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, json=SAMPLE)

        p = provider(mock_client(handler))
        await p.search(SearchQuery(query="wal", max_results=2, language="de"))
        assert seen["request"].url.params["language"] == "de"

    async def test_domain_filters_ride_in_the_query(self):
        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, json=SAMPLE)

        p = provider(mock_client(handler))
        await p.search(
            SearchQuery(
                query="wal",
                max_results=2,
                include_domains=["sqlite.org"],
                exclude_domains=["spam.example"],
            )
        )
        query = seen["request"].url.params["q"]
        assert "site:sqlite.org" in query
        assert "-site:spam.example" in query

    async def test_a_small_ask_stays_a_single_request(self):
        """`max_results` within what page one delivered never pages: the
        common ask costs the instance one fan-out, not three."""
        seen: list[httpx.Request] = []

        def handler(request: httpx.Request) -> httpx.Response:
            seen.append(request)
            return httpx.Response(200, json=SAMPLE)

        p = provider(mock_client(handler))
        result = await p.search(SearchQuery(query="wal", max_results=1))
        assert len(seen) == 1
        assert seen[0].url.params["pageno"] == "1"
        assert len(result.results) == 1

    async def test_paginates_while_the_ask_exceeds_the_pages(self):
        seen: list[httpx.Request] = []

        def handler(request: httpx.Request) -> httpx.Response:
            seen.append(request)
            pageno = int(request.url.params["pageno"])
            return httpx.Response(200, json={"results": n_results(2 if pageno == 1 else 1)})

        p = provider(mock_client(handler))
        result = await p.search(SearchQuery(query="wal", max_results=3))
        assert [r.url.params["pageno"] for r in seen] == ["1", "2"]
        assert len(result.results) == 3

    async def test_pagination_stops_when_a_page_runs_dry(self):
        seen: list[httpx.Request] = []

        def handler(request: httpx.Request) -> httpx.Response:
            seen.append(request)
            pageno = int(request.url.params["pageno"])
            return httpx.Response(200, json={"results": n_results(2 if pageno == 1 else 0)})

        p = provider(mock_client(handler))
        result = await p.search(SearchQuery(query="wal", max_results=10))
        assert [r.url.params["pageno"] for r in seen] == ["1", "2"]
        assert len(result.results) == 2

    async def test_pagination_is_bounded_at_three_pages(self):
        """The bound caps how much instance fan-out one search can cause,
        even when the caller asks for more than three pages hold."""
        seen: list[httpx.Request] = []

        def handler(request: httpx.Request) -> httpx.Response:
            seen.append(request)
            return httpx.Response(200, json={"results": n_results(5)})

        p = provider(mock_client(handler))
        result = await p.search(SearchQuery(query="wal", max_results=20))
        assert len(seen) == 3
        assert len(result.results) == 15

    @pytest.mark.parametrize("status", [429, 500])
    async def test_a_failed_continuation_keeps_the_first_page(self, status: int):
        """A flaky or rate-limited second page must not destroy a search that
        already succeeded; returning fewer results than asked is normal SERP
        behaviour, not an error."""
        seen: list[httpx.Request] = []

        def handler(request: httpx.Request) -> httpx.Response:
            seen.append(request)
            if int(request.url.params["pageno"]) > 1:
                return httpx.Response(status, json={})
            return httpx.Response(200, json={"results": n_results(2)})

        p = provider(mock_client(handler))
        result = await p.search(SearchQuery(query="wal", max_results=10))
        assert [r.url.params["pageno"] for r in seen] == ["1", "2"]
        assert len(result.results) == 2

    async def test_reports_a_flat_zero_cost(self):
        p = provider(mock_client(lambda _: httpx.Response(200, json=SAMPLE)))
        result = await p.search(SearchQuery(query="q", max_results=2))
        assert result.provider == "searxng"
        assert result.cost_usd == 0.0

    async def test_notice_names_the_country_it_cannot_honour(self):
        p = provider(mock_client(lambda _: httpx.Response(200, json=SAMPLE)))
        result = await p.search(SearchQuery(query="q", max_results=2, country="de"))
        assert result.notice == "cannot filter by country; that constraint was ignored"

    async def test_a_language_beside_a_country_is_still_honoured(self):
        """Both halves set: only the country is dropped, and only it is named.

        The joined `country/language` token this used to emit claimed the
        language went too, while `language` was carrying it to the instance.
        """
        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, json=SAMPLE)

        p = provider(mock_client(handler))
        result = await p.search(
            SearchQuery(query="q", max_results=2, country="de", language="de")
        )
        assert seen["request"].url.params["language"] == "de"
        assert result.notice == "cannot filter by country; that constraint was ignored"

    async def test_a_language_alone_is_honoured_without_a_notice(self):
        p = provider(mock_client(lambda _: httpx.Response(200, json=SAMPLE)))
        result = await p.search(SearchQuery(query="q", max_results=2, language="de"))
        assert result.notice is None

    @pytest.mark.parametrize(("safe_search", "wire"), [(True, "2"), (False, "0")])
    async def test_safe_search_maps_onto_safesearch(self, safe_search, wire):
        """`True` is SearXNG's strict state; its `1` (moderate) is unreachable.

        Both values are honoured exactly, so there is no partially-honoured case
        to word -- the property the boolean rests on.
        """
        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, json=SAMPLE)

        p = provider(mock_client(handler))
        result = await p.search(SearchQuery(query="q", max_results=2, safe_search=safe_search))
        assert seen["request"].url.params["safesearch"] == wire
        assert result.notice is None

    async def test_safesearch_is_omitted_when_none(self):
        """`None` sends nothing, so the instance's own default stands."""
        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, json=SAMPLE)

        p = provider(mock_client(handler))
        await p.search(SearchQuery(query="q", max_results=2))
        assert "safesearch" not in seen["request"].url.params

    async def test_a_safe_search_is_not_claimed_as_dropped(self):
        """The country still goes, and only the country is named."""
        p = provider(mock_client(lambda _: httpx.Response(200, json=SAMPLE)))
        result = await p.search(
            SearchQuery(query="q", max_results=2, country="de", safe_search=True)
        )
        assert result.notice == "cannot filter by country; that constraint was ignored"

    async def test_no_notice_for_what_it_honours(self):
        p = provider(mock_client(lambda _: httpx.Response(200, json=SAMPLE)))
        result = await p.search(
            SearchQuery(
                query="q",
                max_results=2,
                include_domains=["sqlite.org"],
                language="de",
                recency="week",
                safe_search=True,
            )
        )
        assert result.notice is None


class TestErrors:
    """Only the rows this adapter answers differently.

    The six rows every HTTP adapter owes are pinned once for all of them by
    ``tests/providers/test_provider_contract.py``. What stays here is this adapter's quota
    statuses, its own message wording, and the leak regression that proves the
    redaction rule for the place its key actually rides.
    """

    async def test_rate_limit_is_quota(self):
        p = provider(mock_client(lambda _: httpx.Response(429, json={})))
        with pytest.raises(QuotaExhausted):
            await p.search(SearchQuery(query="q"))

    async def test_payment_status_falls_to_the_generic_row(self):
        # Nothing bills this transport, so a 402 is the reverse proxy, not quota.
        # 429 from the limiter is the whole quota row.
        p = provider(mock_client(lambda _: httpx.Response(402, json={})))
        with pytest.raises(ProviderError) as exc:
            await p.search(SearchQuery(query="q"))
        assert exc.value.message == "HTTP 402"

    async def test_network_error_does_not_echo_the_request(self):
        def handler(_: httpx.Request) -> httpx.Response:
            raise httpx.ConnectError("connection refused to http://searx.internal:8080")

        p = provider(mock_client(handler))
        with pytest.raises(ProviderError) as exc:
            await p.search(SearchQuery(query="q"))
        assert exc.value.message == "network error"
        assert "searx.internal" not in str(exc.value)


class TestCost:
    def test_cost_is_flat_zero(self):
        p = provider()
        assert p.cost_for(1) == p.cost_for(20) == 0.0

    def test_config_can_correct_the_figure_but_zero_is_the_default(self):
        assert provider(cost_per_1k=5.0).cost_for(1) == 0.005


class TestWiring:
    def test_built_when_a_url_is_configured(self):
        cfg = Config(
            providers={"searxng": ProviderConfig(url="http://searx.internal:8080")}
        )
        built = build_providers(cfg, httpx.AsyncClient())
        assert isinstance(built["searxng"], SearxngProvider)
        assert built["searxng"].cost_per_1k == 0.0

    def test_an_unset_cost_falls_back_to_zero(self):
        cfg = Config(
            providers={"searxng": ProviderConfig(url="http://searx.internal:8080")}
        )
        built = build_providers(cfg, httpx.AsyncClient())
        assert built["searxng"].cost_per_1k == 0.0

    def test_config_can_correct_the_cost(self):
        cfg = Config(
            providers={
                "searxng": ProviderConfig(
                    url="http://searx.internal:8080", cost_per_1k=1.0
                )
            }
        )
        built = build_providers(cfg, httpx.AsyncClient())
        assert built["searxng"].cost_per_1k == 1.0

    def test_enabled_without_a_url_is_a_config_error(self):
        with pytest.raises(ValueError, match="no url is configured"):
            Config(providers={"searxng": ProviderConfig()})

    def test_enabled_without_a_url_does_not_break_a_disabled_entry(self):
        # Explicitly disabled is not a misconfiguration: it raises nothing and
        # builds nothing.
        cfg = Config(providers={"searxng": ProviderConfig(enabled=False)})
        built = build_providers(cfg, httpx.AsyncClient())
        assert "searxng" not in built
        assert cfg.enabled_providers() == ["exa:free", "freeserp", "parallel:free"]
