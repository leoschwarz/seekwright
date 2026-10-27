"""Search1API provider: response parsing, request shape, cost and wiring.

The fixture is the documented ``/search`` payload from the operator's OpenAPI
schema (``https://api.search1api.com/openapi.json``, read 2026-10-16; the same
shape the docs page renders). Search1API is a multi-engine aggregator, so a
result carries what an engine reports: ``title``, ``link``, ``snippet``, and an
optional ``published_date``. ``content`` exists upstream only for Deep Search
(``crawl_results > 0``), which this adapter never requests, so a parsed result
fills ``snippet`` and never ``text``.

The adapter is shipped **untested** (no live verification against the real
endpoint in-repo; ``config.UNTESTED_PROVIDERS`` and the ``--check`` line say so
while it stays in that set), so these hermetic tests are the whole coverage
that exists -- the live test in ``tests/live/test_live.py`` is the follow-up that
clears the untested status.
"""

import json
from typing import Any

import httpx
import pytest

from seekwright.config import Config, ProviderConfig
from seekwright.factory import build_providers
from seekwright.models import SearchQuery
from seekwright.providers.base import ProviderError, QuotaExhausted
from seekwright.providers.search1api import Search1ApiProvider

SAMPLE: dict[str, Any] = {
    "searchParameters": {
        "query": "write-ahead logging",
        "search_service": "google",
        "max_results": 5,
        "crawl_results": 0,
        "image": False,
        "include_sites": [],
        "exclude_sites": [],
        "language": "",
        "time_range": "",
    },
    "results": [
        {
            "title": "Write-Ahead Logging",
            "link": "https://www.sqlite.org/wal.html",
            "snippet": "The default method by which SQLite implements atomic "
            "commit is a rollback journal.",
            "published_date": "2024-11-03",
        },
        {
            "title": "SQLite WAL mode explained",
            "link": "https://example.com/wal-explained",
            "snippet": "WAL allows readers and one writer to proceed concurrently.",
        },
    ],
}


def provider(client: httpx.AsyncClient | None = None, **kw) -> Search1ApiProvider:
    return Search1ApiProvider(client or httpx.AsyncClient(), "test-key", **kw)


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

    def test_the_length_the_cap_discarded_is_recorded(self):
        """`search.cap` reads this: the pre-cap length, log-only and off the wire."""
        hit = provider(snippet_chars=40)._parse(SAMPLE, limit=10)[0]
        uncapped = hit._uncapped_chars
        assert uncapped is not None
        assert uncapped == len(" ".join(SAMPLE["results"][0]["snippet"].split()))
        assert uncapped > len(hit.snippet or "")
        # Private, so a caller can never see it: the response carries the
        # clipped snippet, never a measurement of the clip.
        assert "_uncapped_chars" not in hit.model_dump()

    def test_a_short_snippet_reports_its_own_length(self):
        """The denominator: a hit the cap did not bite is still measured."""
        hit = provider()._parse(SAMPLE, limit=10)[1]
        assert hit.snippet is not None
        assert hit._uncapped_chars == len(hit.snippet)

    def test_published_date_is_kept_only_when_a_string(self):
        # The schema omits the date per result when the source exposes none, so
        # nothing is invented.
        results = provider()._parse(SAMPLE, limit=10)
        assert results[0].published_date == "2024-11-03"
        assert results[1].published_date is None

    def test_records_without_a_link_are_dropped(self):
        data = {"results": [{"title": "No link here"}]}
        assert provider()._parse(data, limit=10) == []

    def test_records_without_a_title_are_dropped(self):
        data = {"results": [{"link": "https://example.com"}]}
        assert provider()._parse(data, limit=10) == []

    def test_non_dict_records_are_skipped(self):
        data = {"results": ["nonsense", {"title": "t", "link": "https://x"}]}
        assert len(provider()._parse(data, limit=10)) == 1

    def test_missing_results_is_empty_not_an_error(self):
        assert provider()._parse({"results": None}, limit=10) == []
        assert provider()._parse({}, limit=10) == []


class TestUpstreamFieldGuards:
    """A non-string ``snippet`` or ``published_date`` is dropped, not raised.

    The upstream payload is untrusted: the schema documents both fields as
    strings, but nothing enforces that. A shape drift must not turn into a
    ``ValidationError`` (pydantic) or an ``AttributeError`` (out of
    ``truncate_snippet``'s ``text.split()``) that escapes the engine's
    provider-error handling as an internal error -- the call has to succeed
    with the field dropped, exactly as the sibling adapters do.
    """

    @pytest.mark.parametrize(
        "bad_date", [{"nested": "object"}, ["a", "b"], 20241103]
    )
    async def test_a_non_string_date_is_dropped_and_the_call_succeeds(self, bad_date):
        data = {
            "results": [
                {"title": "t", "link": "https://example.com/a", "published_date": bad_date}
            ]
        }
        p = provider(mock_client(lambda _: httpx.Response(200, json=data)))
        result = await p.search(SearchQuery(query="q"))
        assert len(result.results) == 1
        assert result.results[0].published_date is None

    @pytest.mark.parametrize("bad_snippet", [{"nested": "object"}, ["a", "b"], 7])
    async def test_a_non_string_snippet_is_dropped_and_the_call_succeeds(
        self, bad_snippet
    ):
        data = {
            "results": [
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
            "rollback journal."
        )


class TestRequestShape:
    """The body Search1API is sent, and the two constraints it cannot honour.

    Domains, dates and language ride native parameters (``include_sites`` /
    ``exclude_sites``, ``time_range`` and ``language``), so three buckets are
    honoured. There is no country parameter and no safe-search parameter in
    the documented schema, so those halves drop -- and the ``notice`` is the
    only thing standing between a caller that asked for them and the belief
    that it got them.
    """

    async def _search(self, **kw):
        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, json=SAMPLE)

        result = await provider(mock_client(handler)).search(
            SearchQuery(query="wal mode", **kw)
        )
        return json.loads(seen["request"].content), seen["request"], result

    async def test_posts_json_with_a_bearer_key(self):
        _, request, _ = await self._search()
        assert request.method == "POST"
        assert request.url.host == "api.search1api.com"
        assert request.url.path == "/search"
        assert request.headers["Authorization"] == "Bearer test-key"

    async def test_the_query_and_max_results_are_sent(self):
        body, _, _ = await self._search(max_results=3)
        assert body["query"] == "wal mode"
        assert body["max_results"] == 3

    async def test_domain_filters_ride_their_native_fields(self):
        body, _, _ = await self._search(
            include_domains=["sqlite.org"], exclude_domains=["spam.example"]
        )
        assert body["include_sites"] == ["sqlite.org"]
        assert body["exclude_sites"] == ["spam.example"]

    async def test_domain_fields_are_absent_without_filters(self):
        body, _, _ = await self._search()
        assert "include_sites" not in body
        assert "exclude_sites" not in body

    async def test_recency_maps_onto_time_range(self):
        body, _, _ = await self._search(recency="week")
        assert body["time_range"] == "week"

    async def test_time_range_is_absent_without_a_recency(self):
        body, _, _ = await self._search()
        assert "time_range" not in body

    async def test_language_is_lowercased_on_the_wire(self):
        body, _, result = await self._search(language="DE")
        assert body["language"] == "de"
        # Language is honoured, so a language-only constraint carries no notice.
        assert result.notice is None

    async def test_language_is_absent_without_a_language(self):
        body, _, _ = await self._search()
        assert "language" not in body

    @pytest.mark.parametrize("field", ["crawl_results", "image", "search_service", "page"])
    async def test_never_sends_a_billing_or_engine_field(self, field):
        """`crawl_results` would add a credit per crawled page; `image` and
        `search_service` are choices this deployment makes for its operators,
        not the caller's. None of them may appear in a body at all."""
        body, _, _ = await self._search(
            include_domains=["sqlite.org"],
            exclude_domains=["spam.example"],
            language="en",
            recency="day",
            country="de",
            safe_search=True,
        )
        assert field not in body

    async def test_an_unconstrained_query_carries_no_notice(self):
        _, _, result = await self._search()
        assert result.notice is None

    async def test_a_country_constraint_is_noticed(self):
        _, _, result = await self._search(country="de")
        assert result.notice == (
            "cannot filter by country; that constraint was ignored"
        )

    @pytest.mark.parametrize("safe_search", [True, False])
    async def test_a_safe_search_is_noticed_for_both_values(self, safe_search):
        _, _, result = await self._search(safe_search=safe_search)
        assert result.notice == (
            "cannot filter by safe-search; that constraint was ignored"
        )

    async def test_a_country_and_safe_search_name_both_halves(self):
        _, _, result = await self._search(country="de", safe_search=True)
        assert result.notice == (
            "cannot filter by country or safe-search; that constraint was "
            "ignored"
        )

    async def test_the_honoured_buckets_stay_silent(self):
        """Domains, dates and language are honoured, so only the dropped halves
        may appear in the notice."""
        _, _, result = await self._search(
            include_domains=["sqlite.org"],
            recency="month",
            language="en",
            country="de",
        )
        assert result.notice == (
            "cannot filter by country; that constraint was ignored"
        )


class TestErrors:
    """Only the rows this adapter answers differently.

    The six rows every HTTP adapter owes are pinned once for all of them by
    ``tests/providers/test_provider_contract.py``. What stays here is this adapter's quota
    statuses, its own message wording, and the leak regression that proves the
    redaction rule for the place its key actually rides.
    """

    @pytest.mark.parametrize("status", [402, 429])
    async def test_payment_and_rate_limit_are_quota(self, status: int):
        # 402 is documented by this API as "payment required": for a keyed
        # client that means the credits are gone, not a malformed request.
        p = provider(mock_client(lambda _: httpx.Response(status, json={})))
        with pytest.raises(QuotaExhausted):
            await p.search(SearchQuery(query="q"))

    async def test_network_error_does_not_echo_the_request(self):
        def handler(_: httpx.Request) -> httpx.Response:
            raise httpx.ConnectError("connection refused to Authorization: test-key")

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
        assert p.cost_for(1) == p.cost_for(20) == pytest.approx(0.76 / 1000.0)

    async def test_reports_its_flat_cost_on_the_result(self):
        p = provider(mock_client(lambda _: httpx.Response(200, json=SAMPLE)))
        result = await p.search(SearchQuery(query="q", max_results=5))
        assert result.provider == "search1api"
        assert result.cost_usd == pytest.approx(0.76 / 1000.0)


class TestWiring:
    def test_built_only_when_a_key_is_present(self, monkeypatch):
        cfg = Config(providers={"search1api": ProviderConfig()})

        monkeypatch.delenv("SEEKWRIGHT_SEARCH1API_API_KEY", raising=False)
        assert "search1api" not in build_providers(cfg, httpx.AsyncClient())

        monkeypatch.setenv("SEEKWRIGHT_SEARCH1API_API_KEY", "k")
        built = build_providers(cfg, httpx.AsyncClient())
        assert isinstance(built["search1api"], Search1ApiProvider)

    def test_config_can_correct_the_cost(self, monkeypatch):
        """An operator on a different price tier can fix what `--check` reports."""
        monkeypatch.setenv("SEEKWRIGHT_SEARCH1API_API_KEY", "k")
        cfg = Config(providers={"search1api": ProviderConfig(cost_per_1k=0.49)})
        built = build_providers(cfg, httpx.AsyncClient())
        assert built["search1api"].cost_per_1k == 0.49

    def test_an_unset_cost_falls_back_to_the_adapter_default(self, monkeypatch):
        monkeypatch.setenv("SEEKWRIGHT_SEARCH1API_API_KEY", "k")
        cfg = Config(providers={"search1api": ProviderConfig()})
        built = build_providers(cfg, httpx.AsyncClient())
        assert built["search1api"].cost_per_1k == 0.76
