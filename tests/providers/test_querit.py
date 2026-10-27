"""Querit provider: response parsing, request shape, cost and wiring.

The fixture is the documented ``/v1/search`` payload from the operator's API
reference (``https://www.querit.ai/en/docs/reference/post-for-coding-agents``,
re-read 2026-10-17; the same shape the docs' quickstart renders). Each hit
carries ``url``, ``title``, ``snippet``, ``page_age`` and ``site_name``; every
result field is documented optional. ``sentence`` (body text) exists upstream
only behind ``needContent: true`` and ``highlights`` only behind the
``highlights`` request field, which this adapter never sends — so a parsed
result fills ``snippet`` and never ``text``.

The adapter is shipped **untested** (no live verification against the real
endpoint in-repo; ``config.UNTESTED_PROVIDERS`` and the ``--check`` line say so
while it stays in that set), so these hermetic tests are the whole coverage
that exists — the live test in ``tests/live/test_live.py`` is the follow-up that
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
from seekwright.providers.querit import MAX_RESULTS, QueritProvider

SAMPLE: dict[str, Any] = {
    "took": "312ms",
    "error_code": 200,
    "error_msg": "",
    "search_id": 8842013,
    "query_context": {"query": "how vector databases handle hybrid search"},
    "results": {
        "result": [
            {
                "url": "https://example.com/post",
                "title": "Hybrid search explained",
                "snippet": "Hybrid search combines a vector index with BM25 for "
                "recall and precision.",
                "page_age": "2026-07-14T09:00:00Z",
                "site_name": "example.com",
            },
            {
                "url": "https://example.org/vector-databases",
                "title": "Vector databases in practice",
                "snippet": "Choosing an embedding dimension is a budget "
                "decision.",
            },
        ]
    },
}


def provider(client: httpx.AsyncClient | None = None, **kw) -> QueritProvider:
    return QueritProvider(client or httpx.AsyncClient(), "test-key", **kw)


def mock_client(handler) -> httpx.AsyncClient:
    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


class TestParsing:
    def test_extracts_all_records(self):
        results = provider()._parse(SAMPLE, limit=10)
        assert len(results) == 2
        assert results[0].title == "Hybrid search explained"
        assert results[0].url == "https://example.com/post"
        assert results[1].url == "https://example.org/vector-databases"

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
        assert uncapped == len(
            " ".join(SAMPLE["results"]["result"][0]["snippet"].split())
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

    def test_page_age_is_kept_only_when_a_string(self):
        # The schema marks every result field optional, so the second record stays
        # empty.
        results = provider()._parse(SAMPLE, limit=10)
        assert results[0].published_date == "2026-07-14T09:00:00Z"
        assert results[1].published_date is None

    def test_records_without_a_url_are_dropped(self):
        data = {"results": {"result": [{"title": "No url here"}]}}
        assert provider()._parse(data, limit=10) == []

    def test_records_without_a_title_are_dropped(self):
        data = {"results": {"result": [{"url": "https://example.com"}]}}
        assert provider()._parse(data, limit=10) == []

    def test_non_dict_records_are_skipped(self):
        data = {
            "results": {
                "result": [
                    "nonsense",
                    {"title": "t", "url": "https://x"},
                ]
            }
        }
        assert len(provider()._parse(data, limit=10)) == 1

    def test_missing_results_is_empty_not_an_error(self):
        assert provider()._parse({"results": None}, limit=10) == []
        assert provider()._parse({}, limit=10) == []

    def test_a_non_object_results_container_is_empty_not_an_error(self):
        # `results` is an object on the wire; a shape drift to a list (the
        # intuitive reading of the name) is a missing container, not a failure.
        data = {"results": [{"title": "t", "url": "https://x"}]}
        assert provider()._parse(data, limit=10) == []
        assert provider()._parse({"results": {"result": None}}, limit=10) == []


class TestUpstreamFieldGuards:
    """A non-string ``snippet`` or ``page_age`` is dropped, not raised.

    The upstream payload is untrusted: the schema marks every result field
    optional but nothing enforces the type. A shape drift must not turn into a
    ``ValidationError`` (pydantic) or an ``AttributeError`` (out of
    ``truncate_snippet``'s ``text.split()``) that escapes the engine's
    provider-error handling as an internal error -- the call has to succeed
    with the field dropped, exactly as the sibling adapters do.
    """

    @pytest.mark.parametrize("bad_date", [{"nested": "object"}, ["a", "b"], 20260714])
    async def test_a_non_string_date_is_dropped_and_the_call_succeeds(self, bad_date):
        data = {
            "results": {
                "result": [
                    {"title": "t", "url": "https://example.com/a", "page_age": bad_date}
                ]
            }
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
            "results": {
                "result": [
                    {"title": "t", "url": "https://example.com/a", "snippet": bad_snippet}
                ]
            }
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
            "Hybrid search combines a vector index with BM25 for recall and "
            "precision."
        )


class TestRequestShape:
    """The body Querit is sent, and the constraints it cannot honour.

    Domains, dates and the mappable halves of country/language ride native
    filter fields (``filters.sites``, ``filters.timeRange.date`` and
    ``filters.geo.countries.include`` / ``filters.languages.include``), so four
    buckets are honoured where the value has a wire form. A country or language
    the backend's strict enums cannot express is dropped and named in
    ``notice``; there is no safe-search parameter at all. ``count`` is clamped
    to the free plan's 10-result cap, whatever ``max_results`` asks.
    """

    async def _search(self, **kw):
        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, json=SAMPLE)

        result = await provider(mock_client(handler)).search(
            SearchQuery(query="hybrid search", **kw)
        )
        return json.loads(seen["request"].content), seen["request"], result

    async def test_posts_json_with_a_bearer_key(self):
        _, request, _ = await self._search()
        assert request.method == "POST"
        assert request.url.host == "api.querit.ai"
        assert request.url.path == "/v1/search"
        assert request.headers["Authorization"] == "Bearer test-key"

    async def test_the_query_and_count_are_sent(self):
        body, _, _ = await self._search(max_results=3)
        assert body["query"] == "hybrid search"
        assert body["count"] == 3

    @pytest.mark.parametrize("max_results", [11, 20, 100])
    async def test_count_is_clamped_to_the_free_plan_cap(self, max_results):
        """The free plan answers at most 10 results, so the request never
        asks it for more: clamped, documented, and the response simply
        carries fewer hits than asked (a shorter answer, not a notice)."""
        body, _, result = await self._search(max_results=max_results)
        assert body["count"] == MAX_RESULTS == 10
        # No notice over the clamp: a shorter answer is not a dropped
        # constraint.
        assert result.notice is None

    async def test_domain_filters_ride_their_native_fields(self):
        body, _, _ = await self._search(
            include_domains=["example.com"], exclude_domains=["spam.example"]
        )
        assert body["filters"]["sites"]["include"] == ["example.com"]
        assert body["filters"]["sites"]["exclude"] == ["spam.example"]

    async def test_domain_fields_are_absent_without_filters(self):
        body, _, _ = await self._search()
        assert "filters" not in body

    async def test_include_only_sends_include(self):
        body, _, _ = await self._search(include_domains=["example.com"])
        assert "exclude" not in body["filters"]["sites"]

    @pytest.mark.parametrize(
        "recency,date",
        [("day", "d1"), ("week", "w1"), ("month", "m1"), ("year", "y1")],
    )
    async def test_recency_maps_onto_time_range(self, recency, date):
        body, _, _ = await self._search(recency=recency)
        assert body["filters"]["timeRange"]["date"] == date

    async def test_time_range_is_absent_without_a_recency(self):
        body, _, _ = await self._search()
        assert "filters" not in body

    @pytest.mark.parametrize(
        "language,wire",
        [
            ("en", "english"),
            ("EN", "english"),
            ("ja", "japanese"),
            ("ko", "korean"),
            ("de", "german"),
            ("fr", "french"),
            ("es", "spanish"),
            ("pt", "portuguese"),
            ("ru", "russian"),
        ],
    )
    async def test_language_maps_onto_the_enums_name(self, language, wire):
        body, _, result = await self._search(language=language)
        assert body["filters"]["languages"]["include"] == [wire]
        # The language is honoured, so a language-only constraint carries no
        # notice.
        assert result.notice is None

    async def test_an_unmappable_language_is_dropped_and_noticed(self):
        """The enum is strict: an ISO code with no entry is not sent (it would
        be a 400, not a filter) and the drop is named instead."""
        body, _, result = await self._search(language="zh")
        assert "filters" not in body
        assert result.notice == (
            "cannot filter by language; that constraint was ignored"
        )

    @pytest.mark.parametrize(
        "country,wire",
        [
            ("us", "united states"),
            ("gb", "united kingdom"),
            ("kr", "south korea"),
            ("jp", "japan"),
            ("de", "germany"),
        ],
    )
    async def test_country_maps_onto_the_enums_name(self, country, wire):
        body, _, result = await self._search(country=country)
        assert body["filters"]["geo"]["countries"]["include"] == [wire]
        assert result.notice is None

    async def test_an_unmappable_country_is_dropped_and_noticed(self):
        body, _, result = await self._search(country="no")
        assert "filters" not in body
        assert result.notice == (
            "cannot filter by country; that constraint was ignored"
        )

    async def test_an_unconstrained_query_carries_no_notice(self):
        _, _, result = await self._search()
        assert result.notice is None

    @pytest.mark.parametrize("safe_search", [True, False])
    async def test_a_safe_search_is_noticed_for_both_values(self, safe_search):
        """There is no safe-search parameter, and `False` is a request too."""
        _, _, result = await self._search(safe_search=safe_search)
        assert result.notice == (
            "cannot filter by safe-search; that constraint was ignored"
        )

    async def test_dropped_halves_name_themselves_individually(self):
        _, _, result = await self._search(country="no", language="zh")
        assert result.notice == (
            "cannot filter by country or language; that constraint was "
            "ignored"
        )

    async def test_a_country_only_drop_names_country_not_the_joined_bucket(self):
        """The language half is a surface this adapter has, so an honoured
        language keeps the country half named on its own."""
        _, _, result = await self._search(country="no", language="en")
        assert result.notice == (
            "cannot filter by country; that constraint was ignored"
        )

    @pytest.mark.parametrize(
        "field", ["needContent", "highlights", "chunksPerDoc", "vertical"]
    )
    async def test_never_sends_a_content_or_vertical_field(self, field):
        """`needContent` would move the call to the content tier (body text in
        `sentence`, a `text` fill this adapter must not make), `highlights`
        and the deprecated `chunksPerDoc` bill against the same page-text
        budget, and `vertical` is a deployment choice, not a caller's. None of
        them may appear in a body at all."""
        body, _, _ = await self._search(
            include_domains=["example.com"],
            exclude_domains=["spam.example"],
            language="en",
            recency="day",
            country="us",
            safe_search=True,
        )
        assert field not in body

    async def test_the_honoured_buckets_stay_silent(self):
        """Domains, dates, a mappable country and a mappable language are
        honoured, so only the dropped safe-search half may appear."""
        _, _, result = await self._search(
            include_domains=["example.com"],
            recency="month",
            language="en",
            country="us",
            safe_search=True,
        )
        assert result.notice == (
            "cannot filter by safe-search; that constraint was ignored"
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
        # 429 is documented by this API as the rate limit (1 QPS on the free
        # plan); the exhausted monthly allowance answers the same code.
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
        assert p.cost_for(1) == p.cost_for(20) == pytest.approx(0.0)

    def test_cost_tracks_the_declared_rate(self):
        p = provider(cost_per_1k=4.0)
        assert p.cost_for(1) == p.cost_for(10) == pytest.approx(4.0 / 1000.0)

    async def test_reports_its_flat_cost_on_the_result(self):
        p = provider(mock_client(lambda _: httpx.Response(200, json=SAMPLE)))
        result = await p.search(SearchQuery(query="q", max_results=5))
        assert result.provider == "querit"
        assert result.cost_usd == pytest.approx(0.0)


class TestWiring:
    def test_built_only_when_a_key_is_present(self, monkeypatch):
        cfg = Config(providers={"querit": ProviderConfig()})

        monkeypatch.delenv("SEEKWRIGHT_QUERIT_API_KEY", raising=False)
        assert "querit" not in build_providers(cfg, httpx.AsyncClient())

        monkeypatch.setenv("SEEKWRIGHT_QUERIT_API_KEY", "k")
        built = build_providers(cfg, httpx.AsyncClient())
        assert isinstance(built["querit"], QueritProvider)

    def test_config_can_correct_the_cost(self, monkeypatch):
        """An operator on the $4/1k PAYG tier fixes what `--check` reports."""
        monkeypatch.setenv("SEEKWRIGHT_QUERIT_API_KEY", "k")
        cfg = Config(providers={"querit": ProviderConfig(cost_per_1k=4.0)})
        built = build_providers(cfg, httpx.AsyncClient())
        assert built["querit"].cost_per_1k == 4.0

    def test_an_unset_cost_falls_back_to_the_adapter_default(self, monkeypatch):
        """The default is the documented free plan: a call cannot bill."""
        monkeypatch.setenv("SEEKWRIGHT_QUERIT_API_KEY", "k")
        cfg = Config(providers={"querit": ProviderConfig()})
        built = build_providers(cfg, httpx.AsyncClient())
        assert built["querit"].cost_per_1k == 0.0
