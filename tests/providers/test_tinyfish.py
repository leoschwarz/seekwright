"""TinyFish provider: response parsing, request shape, cost and wiring.

The fixture is the documented payload (see ``docs/reference/providers.md``,
transcribed from the official reference page on 2026-09-29). The request-shape
tests drive the provider through an ``httpx.MockTransport``, which is possible
here and not for the MCP adapter because the client is injected.
"""

import json
from typing import Any

import httpx
import pytest

from seekwright.config import Config, ProviderConfig
from seekwright.factory import build_providers
from seekwright.models import SearchQuery
from seekwright.providers.base import ProviderError, QuotaExhausted
from seekwright.providers.tinyfish import TinyfishProvider

SAMPLE: dict[str, Any] = {
    "query": "wal mode",
    "results": [
        {
            "position": 1,
            "site_name": "sqlite.org",
            "title": "Write-Ahead Logging",
            "snippet": "The default method by which SQLite implements atomic "
            "commit is a rollback journal.",
            "url": "https://www.sqlite.org/wal.html",
            "date": "2024-11-03",
        },
        {
            "position": 2,
            "site_name": "example.com",
            "title": "SQLite WAL mode explained",
            "snippet": "WAL allows readers and one writer to proceed concurrently.",
            "url": "https://example.com/wal-explained",
        },
    ],
    "total_results": 10,
    "page": 0,
}


def provider(client: httpx.AsyncClient | None = None, **kw) -> TinyfishProvider:
    return TinyfishProvider(client or httpx.AsyncClient(), "test-key", **kw)


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

    def test_snippet_is_kept_and_never_text(self):
        results = provider()._parse(SAMPLE, limit=10)
        assert results[0].snippet
        assert results[0].text is None, "a SERP backend fills snippet, never text"

    def test_snippet_is_truncated(self):
        results = provider(snippet_chars=40)._parse(SAMPLE, limit=10)
        assert len(results[0].snippet or "") <= 41  # the ellipsis is one char

    def test_date_is_kept_only_when_a_string(self):
        results = provider()._parse(SAMPLE, limit=10)
        assert results[0].published_date == "2024-11-03"
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
    """A non-string ``snippet`` is dropped, not handed to ``truncate_snippet``.

    TinyFish's ``results[].snippet`` becomes ``Result.snippet`` through
    ``base.truncate_snippet``, which called ``text.split()`` on whatever
    upstream sent. A nested object, list or number there raised
    ``AttributeError`` -- not a ``ProviderError`` -- so it escaped the engine's
    provider-error handling and surfaced as an internal error instead of a field
    the adapter dropped.
    """

    @pytest.mark.parametrize("bad_snippet", [{"nested": "object"}, ["a", "b"], 7])
    async def test_a_non_string_snippet_is_dropped_and_the_call_succeeds(
        self, bad_snippet
    ):
        data = {
            "results": [
                {"title": "t", "url": "https://example.com/a", "snippet": bad_snippet}
            ]
        }
        p = provider(mock_client(lambda _: httpx.Response(200, json=data)))
        result = await p.search(SearchQuery(query="q"))
        assert len(result.results) == 1
        assert result.results[0].snippet is None

    async def test_a_string_snippet_still_reaches_the_model(self):
        """The guard must not change behaviour for a well-formed payload."""
        p = provider(mock_client(lambda _: httpx.Response(200, json=SAMPLE)))
        result = await p.search(SearchQuery(query="q"))
        assert result.results[0].snippet == (
            "The default method by which SQLite implements atomic commit is a "
            "rollback journal."
        )


class TestRequestShape:
    async def test_sends_get_with_api_key_header_and_query(self):
        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, json=SAMPLE)

        p = provider(mock_client(handler))
        await p.search(SearchQuery(query="wal mode", max_results=3))

        request = seen["request"]
        assert request.method == "GET"
        assert request.headers["X-API-Key"] == "test-key"
        assert request.url.params["query"] == "wal mode"

    async def test_query_is_sent_verbatim_without_site_folding(self):
        """Native domain params exist; the docs prefer them over operators."""
        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, json=SAMPLE)

        p = provider(mock_client(handler))
        await p.search(
            SearchQuery(
                query="wal mode",
                include_domains=["sqlite.org", "sqlite.com"],
                exclude_domains=["spam.example"],
            )
        )
        params = seen["request"].url.params
        assert params["query"] == "wal mode", "no site: operators in the query"
        assert params["include_domains"] == "sqlite.org,sqlite.com"
        assert params["exclude_domains"] == "spam.example"

    async def test_recency_maps_onto_recency_minutes(self):
        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, json=SAMPLE)

        p = provider(mock_client(handler))
        await p.search(SearchQuery(query="wal", recency="week"))
        assert seen["request"].url.params["recency_minutes"] == "10080"

    async def test_geo_maps_onto_location_and_language(self):
        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, json=SAMPLE)

        p = provider(mock_client(handler))
        await p.search(SearchQuery(query="wal", country="de", language="de"))
        params = seen["request"].url.params
        assert params["location"] == "DE", "documented examples are uppercase"
        assert params["language"] == "de"

    async def test_a_language_is_lowercased_on_the_wire(self):
        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, json=SAMPLE)

        p = provider(mock_client(handler))
        await p.search(SearchQuery(query="wal", language="DE"))
        assert seen["request"].url.params["language"] == "de"

    async def test_domain_params_absent_without_filters(self):
        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, json=SAMPLE)

        p = provider(mock_client(handler))
        await p.search(SearchQuery(query="wal"))
        params = dict(seen["request"].url.params)
        for absent in (
            "include_domains",
            "exclude_domains",
            "recency_minutes",
            "location",
            "language",
        ):
            assert absent not in params

    async def test_reports_a_flat_zero_cost(self):
        p = provider(mock_client(lambda _: httpx.Response(200, json=SAMPLE)))
        result = await p.search(SearchQuery(query="q", max_results=5))
        assert result.provider == "tinyfish"
        assert result.cost_usd == 0.0

    @pytest.mark.parametrize("safe_search", [True, False])
    async def test_safe_search_is_the_one_drop_it_notices(self, safe_search):
        """Native domain, date, geo and language parameters; no safety one.

        The helper finds exactly one bucket to report, and it reports it for
        both values of the boolean -- a caller asking for the filter *off* was
        ignored just as completely as one asking for it on.
        """
        p = provider(mock_client(lambda _: httpx.Response(200, json=SAMPLE)))
        result = await p.search(SearchQuery(query="q", safe_search=safe_search))
        assert result.notice == (
            "cannot filter by safe-search; that constraint was ignored"
        )

    async def test_no_notice_it_honours_every_other_constraint(self):
        """The one HTTP adapter with native domain, date, geo and language params."""
        p = provider(mock_client(lambda _: httpx.Response(200, json=SAMPLE)))
        result = await p.search(
            SearchQuery(
                query="q",
                include_domains=["sqlite.org"],
                recency="week",
                country="de",
                language="de",
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

    @pytest.mark.parametrize("status", [402, 429])
    async def test_no_search_access_and_rate_limit_are_quota(self, status: int):
        # 402 reads "Search API access is required": account-level access for a
        # keyed client.
        p = provider(mock_client(lambda _: httpx.Response(status, json={})))
        with pytest.raises(QuotaExhausted):
            await p.search(SearchQuery(query="q"))

    async def test_network_error_does_not_echo_the_request(self):
        def handler(_: httpx.Request) -> httpx.Response:
            raise httpx.ConnectError("connection refused to x-api-key: test-key")

        p = provider(mock_client(handler))
        with pytest.raises(ProviderError) as exc:
            await p.search(SearchQuery(query="q"))
        # The message must not carry the underlying exception: httpx errors can
        # echo the request headers, and those hold the key.
        assert exc.value.message == "network error"
        assert "test-key" not in str(exc.value)


class TestCost:
    def test_cost_is_flat_zero(self):
        """Search never draws from the wallet, whatever the balance."""
        p = provider()
        assert p.cost_for(1) == p.cost_for(20) == 0.0

    def test_config_can_correct_the_figure_but_zero_is_the_default(self):
        assert provider(cost_per_1k=5.0).cost_for(1) == 0.005


class TestWiring:
    def test_built_only_when_a_key_is_present(self, monkeypatch):
        cfg = Config(providers={"tinyfish": ProviderConfig()})

        monkeypatch.delenv("SEEKWRIGHT_TINYFISH_API_KEY", raising=False)
        assert "tinyfish" not in build_providers(cfg, httpx.AsyncClient())

        monkeypatch.setenv("SEEKWRIGHT_TINYFISH_API_KEY", "k")
        built = build_providers(cfg, httpx.AsyncClient())
        assert isinstance(built["tinyfish"], TinyfishProvider)

    def test_an_unset_cost_falls_back_to_zero(self, monkeypatch):
        monkeypatch.setenv("SEEKWRIGHT_TINYFISH_API_KEY", "k")
        cfg = Config(providers={"tinyfish": ProviderConfig()})
        built = build_providers(cfg, httpx.AsyncClient())
        assert built["tinyfish"].cost_per_1k == 0.0

    def test_config_can_correct_the_cost(self, monkeypatch):
        monkeypatch.setenv("SEEKWRIGHT_TINYFISH_API_KEY", "k")
        cfg = Config(providers={"tinyfish": ProviderConfig(cost_per_1k=1.0)})
        built = build_providers(cfg, httpx.AsyncClient())
        assert built["tinyfish"].cost_per_1k == 1.0


def test_the_documented_success_shape_parses():
    """The docs' "What Success Looks Like" body must survive _parse verbatim."""
    body = json.loads(
        """
    {
      "query": "web automation tools",
      "results": [
        {
          "position": 1,
          "site_name": "tinyfish.ai",
          "title": "TinyFish — AI Web Automation Platform",
          "snippet": "Automate any website with natural language instructions...",
          "url": "https://tinyfish.ai"
        }
      ],
      "total_results": 10,
      "page": 0
    }
    """
    )
    results = provider()._parse(body, limit=10)
    assert results[0].title == "TinyFish — AI Web Automation Platform"
    assert results[0].url == "https://tinyfish.ai"
