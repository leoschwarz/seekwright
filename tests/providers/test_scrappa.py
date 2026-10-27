"""Scrappa provider: response parsing, request shape, cost and wiring.

The fixture is the documented ``/api/search-light`` payload (see
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
from seekwright.providers.base import (
    ProviderError,
    QuotaExhausted,
    site_filtered_query,
)
from seekwright.providers.scrappa import MAX_NUM, ScrappaProvider

SAMPLE: dict[str, Any] = {
    "search_information": {"total_results": 41800000},
    "organic_results": [
        {
            "position": 1,
            "title": "Write-Ahead Logging",
            "link": "https://www.sqlite.org/wal.html",
            "snippet": "The default method by which SQLite implements atomic "
            "commit is a rollback journal. Beginning with version 3.7.0 the "
            "WAL option is available.",
        },
        {
            "position": 2,
            "title": "SQLite WAL mode explained",
            "link": "https://example.com/wal-explained",
            "snippet": "WAL allows readers and one writer to proceed concurrently.",
        },
    ],
    "pagination": {"current": 1},
}


def provider(client: httpx.AsyncClient | None = None, **kw) -> ScrappaProvider:
    return ScrappaProvider(client or httpx.AsyncClient(), "test-key", **kw)


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

    def test_snippet_is_truncated(self):
        results = provider(snippet_chars=40)._parse(SAMPLE, limit=10)
        assert len(results[0].snippet or "") <= 41  # the ellipsis is one char

    def test_the_length_the_cap_discarded_is_recorded(self):
        """`search.cap` reads this: the pre-cap length, log-only and off the wire."""
        hit = provider(snippet_chars=40)._parse(SAMPLE, limit=10)[0]
        uncapped = hit._uncapped_chars
        assert uncapped is not None
        assert uncapped == len(
            " ".join(SAMPLE["organic_results"][0]["snippet"].split())
        )
        assert uncapped > len(hit.snippet or "")
        # Private, so a caller can never see it: the response carries the
        # clipped snippet, never a measurement of the clip.
        assert "_uncapped_chars" not in hit.model_dump()

    def test_a_short_snippet_reports_its_own_length(self):
        """The denominator: a hit the cap did not bite is still measured."""
        hit = provider()._parse(SAMPLE, limit=10)[1]
        assert hit.snippet is not None
        assert hit._uncapped_chars == len(hit.snippet)

    def test_no_published_date_is_invented(self):
        # search-light does not report one, so the field stays empty rather
        # than being guessed out of the snippet.
        assert provider()._parse(SAMPLE, limit=10)[0].published_date is None

    def test_records_without_a_link_are_dropped(self):
        data = {"organic_results": [{"title": "No link here", "position": 1}]}
        assert provider()._parse(data, limit=10) == []

    def test_records_without_a_title_are_dropped(self):
        data = {"organic_results": [{"link": "https://example.com", "position": 1}]}
        assert provider()._parse(data, limit=10) == []

    def test_non_dict_records_are_skipped(self):
        data = {"organic_results": ["nonsense", {"title": "t", "link": "u"}]}
        assert len(provider()._parse(data, limit=10)) == 1

    def test_missing_organic_results_is_empty_not_an_error(self):
        assert provider()._parse({"organic_results": None}, limit=10) == []
        assert provider()._parse({}, limit=10) == []


class TestUpstreamFieldGuards:
    """A non-string ``snippet`` is dropped, not handed to ``truncate_snippet``.

    Scrappa's ``organic_results[].snippet`` becomes ``Result.snippet`` through
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
            "organic_results": [
                {"title": "t", "link": "https://example.com/a", "snippet": bad_snippet}
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
            "rollback journal. Beginning with version 3.7.0 the WAL option is "
            "available."
        )


class TestRequestShape:
    async def test_sends_get_with_key_header_and_params(self):
        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, json=SAMPLE)

        p = provider(mock_client(handler))
        await p.search(
            SearchQuery(query="wal mode", max_results=3)
        )

        request = seen["request"]
        assert request.method == "GET"
        assert request.headers["x-api-key"] == "test-key"
        assert request.url.params["query"] == "wal mode"
        assert request.url.params["num"] == "3"
        # Absent rather than empty: Scrappa reads an empty gl/hl as a value.
        assert "gl" not in request.url.params
        assert "hl" not in request.url.params

    async def test_num_is_clamped_to_the_endpoint_ceiling(self):
        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, json=SAMPLE)

        p = provider(mock_client(handler))
        await p.search(
            SearchQuery(
                query="wal mode", max_results=50
            )
        )
        assert seen["request"].url.params["num"] == str(MAX_NUM)

    async def test_country_and_language_map_to_gl_and_hl(self):
        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, json=SAMPLE)

        p = provider(mock_client(handler))
        await p.search(
            SearchQuery(
                query="wal mode",
                country="de",
                language="de",
            )
        )
        assert seen["request"].url.params["gl"] == "de"
        # Sent as given, lowercased -- there is no region half to narrow away.
        assert seen["request"].url.params["hl"] == "de"

    async def test_a_language_is_lowercased_on_the_wire(self):
        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, json=SAMPLE)

        p = provider(mock_client(handler))
        await p.search(SearchQuery(query="wal mode", language="DE"))
        assert seen["request"].url.params["hl"] == "de"

    @pytest.mark.parametrize(
        ("safe_search", "wire"), [(True, "active"), (False, "off")]
    )
    async def test_safe_search_maps_onto_safe(self, safe_search, wire):
        """Both values are honoured exactly: `active` is the strongest on-state.

        There is no partially-honoured case to word -- every capable backend in
        the tree honours `True` and `False` exactly -- and that is why the
        parameter is a boolean rather than a level scale.
        """
        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, json=SAMPLE)

        p = provider(mock_client(handler))
        result = await p.search(SearchQuery(query="q", safe_search=safe_search))
        assert seen["request"].url.params["safe"] == wire
        assert result.notice is None

    async def test_safe_is_omitted_when_none(self):
        """`None` sends nothing at all, so the backend's own default stands.

        This is not the same as `false`: sending `safe=off` unasked would
        override a default the caller never asked about.
        """
        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, json=SAMPLE)

        p = provider(mock_client(handler))
        await p.search(SearchQuery(query="q"))
        assert "safe" not in seen["request"].url.params

    async def test_domain_filters_ride_in_the_query(self):
        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, json=SAMPLE)

        p = provider(mock_client(handler))
        await p.search(
            SearchQuery(
                query="wal mode",
                include_domains=["sqlite.org"],
                exclude_domains=["spam.example"],
            )
        )
        query = seen["request"].url.params["query"]
        assert "site:sqlite.org" in query
        assert "-site:spam.example" in query

    async def test_reports_its_flat_cost_on_the_result(self):
        p = provider(mock_client(lambda _: httpx.Response(200, json=SAMPLE)))
        result = await p.search(SearchQuery(query="q", max_results=5))
        assert result.provider == "scrappa"
        assert result.cost_usd == pytest.approx(0.30 / 1000.0)

    async def test_no_constraint_notice_because_it_honours_them_all(self):
        """The one adapter that honours every bucket, so no helper call at all."""
        p = provider(mock_client(lambda _: httpx.Response(200, json=SAMPLE)))
        result = await p.search(
            SearchQuery(
                query="q",
                include_domains=["sqlite.org"],
                recency="week",
                country="de",
                language="de",
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

    @pytest.mark.parametrize("status", [402, 429])
    async def test_payment_and_rate_limit_are_quota(self, status: int):
        # 402 is Scrappa's x402 payment challenge; for a keyed client that
        # means the credits are gone, not that the request was malformed.
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
    def test_cost_does_not_scale_with_result_count(self):
        p = provider()
        assert p.cost_for(1) == p.cost_for(20) == pytest.approx(0.30 / 1000.0)

    def test_is_cheaper_than_serper(self):
        # The reason for adopting it: same Google index, a third of the price.
        assert provider().cost_per_1k < 1.00


class TestWiring:
    def test_built_only_when_a_key_is_present(self, monkeypatch):
        cfg = Config(providers={"scrappa": ProviderConfig()})

        monkeypatch.delenv("SEEKWRIGHT_SCRAPPA_API_KEY", raising=False)
        assert "scrappa" not in build_providers(cfg, httpx.AsyncClient())

        monkeypatch.setenv("SEEKWRIGHT_SCRAPPA_API_KEY", "k")
        built = build_providers(cfg, httpx.AsyncClient())
        assert isinstance(built["scrappa"], ScrappaProvider)

    def test_config_can_correct_the_cost(self, monkeypatch):
        """An operator on a different price tier can fix what `--check` reports."""
        monkeypatch.setenv("SEEKWRIGHT_SCRAPPA_API_KEY", "k")
        cfg = Config(providers={"scrappa": ProviderConfig(cost_per_1k=0.15)})
        built = build_providers(cfg, httpx.AsyncClient())
        assert built["scrappa"].cost_per_1k == 0.15

    def test_an_unset_cost_falls_back_to_the_adapter_default(self, monkeypatch):
        monkeypatch.setenv("SEEKWRIGHT_SCRAPPA_API_KEY", "k")
        cfg = Config(providers={"scrappa": ProviderConfig()})
        built = build_providers(cfg, httpx.AsyncClient())
        assert built["scrappa"].cost_per_1k == 0.30


class TestSiteFilteredQuery:
    """The shared helper, extracted from Serper so Scrappa could reuse it."""

    def test_bare_query_is_unchanged(self):
        assert site_filtered_query(SearchQuery(query="wal mode")) == "wal mode"

    def test_single_include_needs_no_parentheses(self):
        q = SearchQuery(query="wal", include_domains=["sqlite.org"])
        assert site_filtered_query(q) == "wal site:sqlite.org"

    def test_multiple_includes_are_grouped(self):
        q = SearchQuery(query="wal", include_domains=["a.com", "b.com"])
        assert site_filtered_query(q) == "wal (site:a.com OR site:b.com)"

    def test_excludes_are_negated(self):
        q = SearchQuery(query="wal", exclude_domains=["a.com", "b.com"])
        assert site_filtered_query(q) == "wal -site:a.com -site:b.com"
