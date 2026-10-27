"""Algolia provider: parsing chains, request shape, errors, cost and wiring.

The fixture is a captured-style ``/1/indexes/{index}/query`` payload: Algolia
records are schemaless, so the five hits deliberately exercise the title/url/
snippet mapping chains, the DocSearch ``hierarchy`` shape and the two drop
cases (no title, no URL). The request-shape tests drive the provider through an
``httpx.MockTransport``, possible because the client is injected.
"""

import json
from typing import Any

import httpx
import pytest

from seekwright.config import Config, ProviderConfig
from seekwright.factory import build_providers
from seekwright.models import SearchQuery
from seekwright.providers.algolia import AlgoliaProvider
from seekwright.providers.base import ProviderError, QuotaExhausted

SAMPLE: dict[str, Any] = {
    "hits": [
        {
            "objectID": "1",
            "title": "Write-Ahead Logging",
            "url": "https://www.sqlite.org/wal.html",
            "description": "The default method by which SQLite implements "
            "atomic commit is a rollback journal.",
        },
        {
            "objectID": "2",
            "name": "SQLite WAL mode explained",
            "link": "https://example.com/wal-explained",
            "summary": "WAL allows readers and one writer to proceed concurrently.",
        },
        {
            "objectID": "3",
            "hierarchy": {"lvl0": "Docs", "lvl1": "Search", "lvl2": None},
            "url": "https://docs.example.com/search",
            "content": "How full-text search works in this index.",
        },
        {
            "objectID": "4",
            "title": "A title with no URL",
            "description": "Dropped: no URL to send the caller to.",
        },
        {
            "objectID": "5",
            "url": "https://example.com/no-title",
            "content": "Dropped: no title.",
        },
    ],
    "nbHits": 5,
    "page": 0,
    "nbPages": 1,
    "hitsPerPage": 20,
    "processingTimeMS": 3,
    "query": "wal",
}


def provider(client: httpx.AsyncClient | None = None, **kw) -> AlgoliaProvider:
    kw.setdefault("app_id", "app123")
    kw.setdefault("index", "products")
    return AlgoliaProvider(client or httpx.AsyncClient(), "test-key", **kw)


def mock_client(handler) -> httpx.AsyncClient:
    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


class TestParsing:
    def test_default_chains_fill_all_three_fields(self):
        results = provider()._parse(SAMPLE, limit=10)
        assert len(results) == 3
        assert results[0].title == "Write-Ahead Logging"
        assert results[0].url == "https://www.sqlite.org/wal.html"
        assert results[0].snippet == (
            "The default method by which SQLite implements atomic commit is a "
            "rollback journal."
        )
        # Second hit: name/link/summary chain.
        assert results[1].title == "SQLite WAL mode explained"
        assert results[1].url == "https://example.com/wal-explained"
        assert results[1].snippet == (
            "WAL allows readers and one writer to proceed concurrently."
        )

    def test_docsearch_hierarchy_title_uses_the_deepest_level(self):
        results = provider()._parse(SAMPLE, limit=10)
        assert results[2].title == "Search"
        assert results[2].url == "https://docs.example.com/search"
        # `content` is part of the snippet chain.
        assert results[2].snippet == "How full-text search works in this index."

    def test_explicit_attrs_win_over_the_default_chain(self):
        # A configured title_attr is used alone, so only a hit with all three named
        # attrs survives.
        p = provider(title_attr="name", url_attr="link", snippet_attr="summary")
        results = p._parse(SAMPLE, limit=10)
        assert len(results) == 1
        assert results[0].title == "SQLite WAL mode explained"
        assert results[0].url == "https://example.com/wal-explained"
        assert results[0].snippet == (
            "WAL allows readers and one writer to proceed concurrently."
        )

    def test_hits_missing_a_title_or_url_are_dropped(self):
        # Hits 4 and 5 in the sample, plus the count above.
        assert len(provider()._parse(SAMPLE, limit=10)) == 3

    def test_non_dict_records_are_skipped(self):
        data = {"hits": ["nonsense", {"title": "t", "url": "https://x"}]}
        assert len(provider()._parse(data, limit=10)) == 1

    def test_missing_hits_container_is_empty_not_an_error(self):
        assert provider()._parse({}, limit=10) == []
        assert provider()._parse({"hits": None}, limit=10) == []

    def test_honours_the_limit(self):
        assert len(provider()._parse(SAMPLE, limit=1)) == 1

    def test_no_date_score_or_text_is_invented(self):
        first = provider()._parse(SAMPLE, limit=10)[0]
        assert first.published_date is None
        assert first.score is None
        assert first.text is None


class TestUpstreamFieldGuards:
    """A non-string snippet attribute is dropped, never handed to ``truncate_snippet``.

    Algolia records are schemaless, so ``_first_str`` already coerces the
    snippet attribute at the adapter boundary and a wrong type counts as absent
    -- this adapter was never exposed to the ``AttributeError`` the raw
    ``item.get("snippet")`` call sites raised. The tests pin that rule from both
    ends: the guard inside ``_first_str`` and the one ``base.truncate_snippet``
    now carries for every other adapter.
    """

    @pytest.mark.parametrize("bad_snippet", [{"nested": "object"}, ["a", "b"]])
    async def test_a_non_string_snippet_attribute_is_dropped_and_the_call_succeeds(
        self, bad_snippet
    ):
        """The object and list shapes. A number is the one non-string shape this
        adapter keeps -- ``_first_str`` stringifies a plain scalar -- so it has
        its own test below rather than a shared expectation."""
        data = {
            "hits": [
                {
                    "title": "t",
                    "url": "https://example.com/a",
                    "description": bad_snippet,
                }
            ]
        }
        p = provider(mock_client(lambda _: httpx.Response(200, json=data)))
        result = await p.search(SearchQuery(query="q"))
        assert len(result.results) == 1
        assert result.results[0].snippet is None

    async def test_a_numeric_snippet_attribute_is_still_coerced(self):
        """``_first_str`` takes a plain scalar and stringifies it, so a number
        is prose rather than a dropped field -- the pre-existing behaviour this
        guard must not change."""
        data = {
            "hits": [{"title": "t", "url": "https://example.com/a", "description": 7}]
        }
        p = provider(mock_client(lambda _: httpx.Response(200, json=data)))
        result = await p.search(SearchQuery(query="q"))
        assert result.results[0].snippet == "7"

    async def test_a_string_snippet_attribute_still_reaches_the_model(self):
        """The guard must not change behaviour for a well-formed payload."""
        p = provider(mock_client(lambda _: httpx.Response(200, json=SAMPLE)))
        result = await p.search(SearchQuery(query="q"))
        assert result.results[0].snippet == (
            "The default method by which SQLite implements atomic commit is a "
            "rollback journal."
        )


class TestRequestShape:
    async def test_sends_post_with_both_headers_and_body(self):
        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, json=SAMPLE)

        p = provider(mock_client(handler))
        await p.search(SearchQuery(query="wal mode", max_results=3))

        request = seen["request"]
        assert request.method == "POST"
        assert str(request.url) == (
            "https://app123-dsn.algolia.net/1/indexes/products/query"
        )
        assert request.headers["x-algolia-application-id"] == "app123"
        assert request.headers["x-algolia-api-key"] == "test-key"
        assert json.loads(request.content) == {
            "query": "wal mode",
            "hitsPerPage": 3,
        }

    async def test_the_index_is_percent_encoded_in_the_path(self):
        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, json=SAMPLE)

        p = provider(mock_client(handler), index="products/2026")
        await p.search(SearchQuery(query="q"))
        # The slash is encoded so it cannot escape the index segment; raw_path is
        # the on-the-wire form.
        assert seen["request"].url.raw_path == b"/1/indexes/products%2F2026/query"
        assert seen["request"].url.host == "app123-dsn.algolia.net"

    async def test_an_unconstrained_query_has_no_notice(self):
        p = provider(mock_client(lambda _: httpx.Response(200, json=SAMPLE)))
        result = await p.search(SearchQuery(query="wal"))
        assert result.notice is None
        assert result.provider == "algolia"
        assert result.cost_usd == pytest.approx(0.50 / 1000.0)

    async def test_dropped_constraints_are_noticed_and_not_sent(self):
        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, json=SAMPLE)

        p = provider(mock_client(handler))
        result = await p.search(
            SearchQuery(
                query="wal",
                include_domains=["sqlite.org"],
                recency="day",
                country="de",
                language="de",
                safe_search=True,
            )
        )
        notice = result.notice or ""
        assert "domain" in notice
        assert "dates" in notice
        assert "country/language" in notice
        assert "safe-search" in notice
        # The body carries no filter keys at all: there is no field to send.
        assert json.loads(seen["request"].content) == {
            "query": "wal",
            "hitsPerPage": 5,
        }

    async def test_safe_search_false_is_noticed_too(self):
        """Both values of the boolean are drops here, not just `true`.

        Algolia has no safety parameter, so a caller asking for the filter *off*
        is ignored exactly as completely as one asking for it on -- and the
        notice says so either way. There is no third state to test: `None` means
        nothing was asked, and `test_an_unconstrained_query_has_no_notice` above
        is that case.
        """
        p = provider(mock_client(lambda _: httpx.Response(200, json=SAMPLE)))
        result = await p.search(SearchQuery(query="wal", safe_search=False))
        assert (
            result.notice
            == "cannot filter by safe-search; that constraint was ignored"
        )


class TestErrors:
    """Only the rows this adapter answers differently.

    The six rows every HTTP adapter owes are pinned once for all of them by
    ``tests/providers/test_provider_contract.py``. What stays here is this adapter's quota
    statuses, its own message wording, and the leak regression that proves the
    redaction rule for the place its key actually rides.
    """

    @pytest.mark.parametrize("status", [402, 429])
    async def test_plan_and_rate_limit_are_quota(self, status: int):
        p = provider(mock_client(lambda _: httpx.Response(status, json={})))
        with pytest.raises(QuotaExhausted):
            await p.search(SearchQuery(query="q"))

    async def test_network_error_does_not_echo_the_request(self):
        def handler(_: httpx.Request) -> httpx.Response:
            raise httpx.ConnectError(
                "connection refused, x-algolia-api-key: test-key"
            )

        p = provider(mock_client(handler))
        with pytest.raises(ProviderError) as exc:
            await p.search(SearchQuery(query="q"))
        # The message must not carry the underlying exception: httpx errors can
        # echo the request headers, and those hold the key.
        assert exc.value.message == "network error"
        assert "test-key" not in str(exc.value)


class TestCost:
    def test_cost_does_not_scale_with_result_count(self):
        p = provider()
        assert p.cost_for(1) == p.cost_for(20) == pytest.approx(0.50 / 1000.0)

    def test_default_cost_per_1k_is_the_grow_overage_rate(self):
        assert provider().cost_per_1k == 0.50


class TestWiring:
    def test_built_only_when_a_key_is_present(self, monkeypatch):
        monkeypatch.delenv("SEEKWRIGHT_ALGOLIA_API_KEY", raising=False)
        cfg = Config(
            providers={"algolia": ProviderConfig(app_id="a", index="i")}
        )
        assert "algolia" not in build_providers(cfg, httpx.AsyncClient())

        monkeypatch.setenv("SEEKWRIGHT_ALGOLIA_API_KEY", "k")
        built = build_providers(cfg, httpx.AsyncClient())
        assert isinstance(built["algolia"], AlgoliaProvider)

    def test_config_can_correct_the_cost(self, monkeypatch):
        monkeypatch.setenv("SEEKWRIGHT_ALGOLIA_API_KEY", "k")
        cfg = Config(
            providers={
                "algolia": ProviderConfig(
                    app_id="a", index="i", cost_per_1k=1.75
                )
            }
        )
        built = build_providers(cfg, httpx.AsyncClient())
        assert built["algolia"].cost_per_1k == 1.75

    def test_an_unset_cost_falls_back_to_the_adapter_default(self, monkeypatch):
        monkeypatch.setenv("SEEKWRIGHT_ALGOLIA_API_KEY", "k")
        cfg = Config(
            providers={"algolia": ProviderConfig(app_id="a", index="i")}
        )
        built = build_providers(cfg, httpx.AsyncClient())
        assert built["algolia"].cost_per_1k == 0.50

    def test_enabled_without_app_id_and_index_is_a_config_error(self):
        with pytest.raises(ValueError, match="app_id"):
            Config(providers={"algolia": ProviderConfig()})
        with pytest.raises(ValueError, match="app_id"):
            Config(providers={"algolia": ProviderConfig(app_id="a")})

    def test_enabled_with_both_is_valid(self):
        cfg = Config(providers={"algolia": ProviderConfig(app_id="a", index="i")})
        assert cfg.enabled_providers() == ["algolia"]
