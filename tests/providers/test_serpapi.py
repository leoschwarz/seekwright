"""SerpAPI provider: response parsing, request shape, redaction, cost and wiring.

The fixture is the documented ``/search`` payload from the operator's API docs
(``serpapi.com/search`` parameters page, read 2026-10-16): ``organic_results[]``
with ``position``, ``title``, ``link``, ``snippet`` and an optional display
``date`` ("5 days ago"), beside ``search_metadata`` and the other element
families that are dropped. A parsed result fills ``snippet`` and never
``text`` -- SerpAPI is a SERP backend.

Two facts shape the tests here. The API key rides **in the query string** --
the operator's documented shape, which diverges from this tree's header
convention -- so the request URL is a secret surface, and ``TestKeyRedaction``
asserts no failure path can echo it. And the adapter is shipped **untested**
(no live verification against the real endpoint in-repo;
``config.UNTESTED_PROVIDERS`` and the ``--check`` line say so while it stays in
that set), so these hermetic tests are the whole coverage that exists -- the
live test in ``tests/live/test_live.py`` is the follow-up that clears the status.
"""

from typing import Any

import httpx
import pytest

from seekwright.config import Config, ProviderConfig
from seekwright.factory import build_providers
from seekwright.models import SearchQuery
from seekwright.providers.base import ProviderError, QuotaExhausted
from seekwright.providers.serpapi import SerpApiProvider

SAMPLE: dict[str, Any] = {
    "search_metadata": {
        "id": "61afb3ace7d08a685b3bcbb1",
        "status": "Success",
        "json_endpoint": (
            "https://serpapi.com/searches/c292c1c1fe17fc58/61afb3ace7d08a685b.json"
        ),
        "created_at": "2021-12-07 19:19:08 UTC",
        "processed_at": "2021-12-07 19:19:08 UTC",
        "google_url": "https://www.google.com/search?q=coffee",
    },
    "search_information": {
        "organic_results_state": "Results for exact spelling",
        "query_displayed": "coffee",
        "total_results": 1340000000,
        "time_taken_displayed": 0.99,
    },
    "answer_box": {
        "title": "Coffee",
        "answer": "Coffee is a brewed drink prepared from roasted coffee beans.",
    },
    "organic_results": [
        {
            "position": 1,
            "title": "Coffee - Wikipedia",
            "link": "https://en.wikipedia.org/wiki/Coffee",
            "displayed_link": "https://en.wikipedia.org › wiki › Coffee",
            "snippet": (
                "Coffee is a brewed drink prepared from roasted coffee beans, "
                "the seeds of berries of certain flowering plants."
            ),
            "date": "Sep 20, 2018",
        },
        {
            "position": 2,
            "title": "Is coffee good for you?",
            "link": "https://time.com/4768860/is-coffee-good-for-you/",
            "displayed_link": "https://time.com › is-coffee-good-for-you",
            "snippet": "Coffee is one of the world's most popular beverages.",
        },
    ],
}


def provider(client: httpx.AsyncClient | None = None, **kw) -> SerpApiProvider:
    return SerpApiProvider(client or httpx.AsyncClient(), "test-key", **kw)


def mock_client(handler) -> httpx.AsyncClient:
    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


class TestParsing:
    def test_extracts_all_records(self):
        results = provider()._parse(SAMPLE, limit=10)
        assert len(results) == 2
        assert results[0].title == "Coffee - Wikipedia"
        assert results[0].url == "https://en.wikipedia.org/wiki/Coffee"
        assert results[1].url == "https://time.com/4768860/is-coffee-good-for-you/"

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
        assert uncapped == len(" ".join(SAMPLE["organic_results"][0]["snippet"].split()))
        assert uncapped > len(hit.snippet or "")
        # Private, so a caller can never see it: the response carries the
        # clipped snippet, never a measurement of the clip.
        assert "_uncapped_chars" not in hit.model_dump()

    def test_a_short_snippet_reports_its_own_length(self):
        """The denominator: a hit the cap did not bite is still measured."""
        hit = provider()._parse(SAMPLE, limit=10)[1]
        assert hit.snippet is not None
        assert hit._uncapped_chars == len(hit.snippet)

    def test_display_date_is_kept_only_when_a_string(self):
        # The documented `date` is a display string, omitted per record, so nothing
        # is invented.
        results = provider()._parse(SAMPLE, limit=10)
        assert results[0].published_date == "Sep 20, 2018"
        assert results[1].published_date is None

    def test_records_without_a_link_are_dropped(self):
        data = {"organic_results": [{"title": "No link here"}]}
        assert provider()._parse(data, limit=10) == []

    def test_records_without_a_title_are_dropped(self):
        data = {"organic_results": [{"link": "https://example.com"}]}
        assert provider()._parse(data, limit=10) == []

    def test_non_dict_records_are_skipped(self):
        data = {
            "organic_results": ["nonsense", {"title": "t", "link": "https://x"}]
        }
        assert len(provider()._parse(data, limit=10)) == 1

    def test_missing_organic_results_is_empty_not_an_error(self):
        assert provider()._parse({"organic_results": None}, limit=10) == []
        assert provider()._parse({}, limit=10) == []

    def test_other_element_families_are_dropped(self):
        """`answer_box` and the like are the documented payload's siblings of
        `organic_results`; the adapter reads the ranked list and nothing else."""
        results = provider()._parse(SAMPLE, limit=10)
        assert len(results) == 2
        assert all("answer_box" not in r.model_dump() for r in results)


class TestUpstreamFieldGuards:
    """A non-string ``snippet`` or ``date`` is dropped, not raised.

    The upstream payload is untrusted: the docs describe both fields as
    strings, but nothing enforces that. A shape drift must not turn into a
    ``ValidationError`` (pydantic) or an ``AttributeError`` (out of
    ``truncate_snippet``'s ``text.split()``) that escapes the engine's
    provider-error handling as an internal error -- the call has to succeed
    with the field dropped, exactly as the sibling adapters do.
    """

    @pytest.mark.parametrize(
        "bad_date", [{"nested": "object"}, ["a", "b"], 20210920]
    )
    async def test_a_non_string_date_is_dropped_and_the_call_succeeds(self, bad_date):
        data = {
            "organic_results": [
                {"title": "t", "link": "https://example.com/a", "date": bad_date}
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
            "Coffee is a brewed drink prepared from roasted coffee beans, the "
            "seeds of berries of certain flowering plants."
        )


class TestRequestShape:
    """The query string SerpAPI is sent.

    Every constraint rides a documented parameter -- `site:` operators in the
    query, `gl`, `hl`, `tbs` and `safe` -- so all five buckets are honoured and
    the notice stays `None` whatever the caller asked for. What the tests pin
    is what is *never* sent: fields that would change the billing or the
    response shape of a call this deployment has already priced.
    """

    async def _search(self, **kw):
        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, json=SAMPLE)

        result = await provider(mock_client(handler)).search(
            SearchQuery(query="coffee", **kw)
        )
        return seen["request"].url.params, seen["request"], result

    async def test_gets_to_the_documented_endpoint(self):
        _, request, _ = await self._search()
        assert request.method == "GET"
        assert request.url.host == "serpapi.com"
        assert request.url.path == "/search"
        assert "Authorization" not in request.headers

    async def test_the_key_rides_in_the_query_string(self):
        """The operator's documented shape -- and the reason the redaction rule
        is a standing gotcha, not a one-off: the URL itself is the secret."""
        params, _, _ = await self._search()
        assert params["api_key"] == "test-key"

    async def test_the_query_and_engine_are_sent(self):
        params, _, _ = await self._search()
        assert params["q"] == "coffee"
        assert params["engine"] == "google"

    async def test_domain_filters_fold_into_the_query(self):
        params, _, _ = await self._search(
            include_domains=["sqlite.org"], exclude_domains=["spam.example"]
        )
        assert params["q"] == "coffee site:sqlite.org -site:spam.example"

    async def test_country_ride_gl(self):
        params, _, _ = await self._search(country="de")
        assert params["gl"] == "de"

    async def test_country_is_absent_without_a_country(self):
        params, _, _ = await self._search()
        assert "gl" not in params

    async def test_language_is_lowercased_on_the_wire(self):
        params, _, result = await self._search(language="DE")
        assert params["hl"] == "de"
        # Language is honoured, so a language-only constraint carries no notice.
        assert result.notice is None

    async def test_language_is_absent_without_a_language(self):
        params, _, _ = await self._search()
        assert "hl" not in params

    @pytest.mark.parametrize(
        ("recency", "tbs"),
        [("day", "qdr:d"), ("week", "qdr:w"), ("month", "qdr:m"), ("year", "qdr:y")],
    )
    async def test_recency_maps_onto_tbs(self, recency, tbs):
        params, _, _ = await self._search(recency=recency)
        assert params["tbs"] == tbs

    async def test_tbs_is_absent_without_a_recency(self):
        params, _, _ = await self._search()
        assert "tbs" not in params

    @pytest.mark.parametrize(
        ("safe_search", "safe"),
        [(True, "active"), (False, "off")],
    )
    async def test_safe_search_maps_onto_safe(self, safe_search, safe):
        params, _, _ = await self._search(safe_search=safe_search)
        assert params["safe"] == safe

    async def test_safe_is_absent_when_safe_search_is_unset(self):
        params, _, _ = await self._search()
        assert "safe" not in params

    @pytest.mark.parametrize(
        "field", ["output", "json_restrictor", "device", "start", "num", "timeout"]
    )
    async def test_never_sends_a_shape_or_billing_field(self, field):
        """`output` would change the body to HTML or markdown and break the
        parse; `json_restrictor` would trim the fields the parse reads;
        `device`/`start`/`timeout` are choices this deployment makes for its
        operators, not the caller's, and `num` is not in the documented
        parameter set. None of them may appear in a query string at all."""
        params, _, _ = await self._search(
            include_domains=["sqlite.org"],
            exclude_domains=["spam.example"],
            language="en",
            recency="day",
            country="de",
            safe_search=True,
            max_results=20,
        )
        assert field not in params

    async def test_an_unconstrained_query_carries_no_notice(self):
        _, _, result = await self._search()
        assert result.notice is None

    async def test_a_fully_constrained_query_carries_no_notice(self):
        """Every bucket is honoured, so the notice stays `None` even when the
        caller asked for everything -- the contrast with the sibling adapters,
        whose dropped halves name themselves here."""
        _, _, result = await self._search(
            include_domains=["sqlite.org"],
            exclude_domains=["spam.example"],
            language="de",
            country="fr",
            recency="week",
            safe_search=True,
        )
        assert result.notice is None


class TestKeyRedaction:
    """The key rides in the query string, so every failure path must stay silent.

    The provider-contract redaction rule: never interpolate an httpx exception
    or a raw response body into a message, because httpx errors can echo the
    request they were built from -- and this request's URL carries the API key.
    Each failure mode below is triggered with a message that *does* carry the
    key, and the assertion is that the surfaced error does not.
    """

    def _failures(self):
        def timeout(request: httpx.Request) -> httpx.Response:
            raise httpx.ConnectTimeout(
                f"timed out connecting to {request.url}"
            )

        def connect(request: httpx.Request) -> httpx.Response:
            raise httpx.ConnectError(
                f"connection refused from {request.url}"
            )

        return {
            "timeout": timeout,
            "connect": connect,
            "malformed_json": lambda _: httpx.Response(200, content=b"<html>"),
        }

    async def test_the_key_does_reach_the_endpoint(self):
        """The documented shape, asserted directly, so the redaction tests
        below are not passing vacuously on a URL that never carried the key."""
        from urllib.parse import urlencode

        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, json=SAMPLE)

        await provider(mock_client(handler)).search(SearchQuery(query="q"))
        expected = "https://serpapi.com/search?" + urlencode(
            {"api_key": "test-key", "q": "q", "engine": "google"}
        )
        assert str(seen["request"].url) == expected

    @pytest.mark.parametrize("mode", ["timeout", "connect", "malformed_json"])
    async def test_no_failure_path_echoes_the_key(self, mode):
        handler = self._failures()[mode]
        p = provider(mock_client(handler))
        with pytest.raises(ProviderError) as exc:
            await p.search(SearchQuery(query="q"))
        surfaced = str(exc.value)
        assert "test-key" not in surfaced
        assert "api_key=" not in surfaced
        assert "serpapi.com" not in surfaced

    async def test_the_failure_messages_stay_constant(self):
        p = provider(mock_client(self._failures()["timeout"]))
        with pytest.raises(ProviderError) as exc:
            await p.search(SearchQuery(query="q"))
        # A log message is a constant; values go through `bind()`. The adapter's
        # half of that is: the message never carries the request.
        assert exc.value.message == "request timed out"


class TestErrors:
    """Only the rows this adapter answers differently.

    The six rows every HTTP adapter owes are pinned once for all of them by
    ``tests/providers/test_provider_contract.py``. What stays here is this adapter's quota
    statuses and the wording ``QuotaExhausted`` carries; its leak regression lives
    in ``TestKeyRedaction``, because this key rides in the request URL.
    """

    @pytest.mark.parametrize("status", [402, 429])
    async def test_payment_and_rate_limit_are_quota(self, status: int):
        # 429 is this API's throughput or allowance limit; 402 rides the contracted
        # table.
        p = provider(mock_client(lambda _: httpx.Response(status, json={})))
        with pytest.raises(QuotaExhausted):
            await p.search(SearchQuery(query="q"))


class TestCost:
    def test_cost_does_not_scale_with_result_count(self):
        p = provider()
        assert p.cost_for(1) == p.cost_for(20) == pytest.approx(0.0)

    async def test_reports_its_cost_on_the_result(self):
        p = provider(mock_client(lambda _: httpx.Response(200, json=SAMPLE)))
        result = await p.search(SearchQuery(query="q", max_results=5))
        assert result.provider == "serpapi"
        assert result.cost_usd == pytest.approx(0.0)

    async def test_a_paid_plan_corrects_the_cost(self):
        p = provider(
            client=mock_client(lambda _: httpx.Response(200, json=SAMPLE)),
            cost_per_1k=1.0,
        )
        result = await p.search(SearchQuery(query="q", max_results=5))
        assert result.cost_usd == pytest.approx(1.0 / 1000.0)


class TestWiring:
    def test_built_only_when_a_key_is_present(self, monkeypatch):
        cfg = Config(providers={"serpapi": ProviderConfig()})

        monkeypatch.delenv("SEEKWRIGHT_SERPAPI_API_KEY", raising=False)
        assert "serpapi" not in build_providers(cfg, httpx.AsyncClient())

        monkeypatch.setenv("SEEKWRIGHT_SERPAPI_API_KEY", "k")
        built = build_providers(cfg, httpx.AsyncClient())
        assert isinstance(built["serpapi"], SerpApiProvider)

    def test_config_can_correct_the_cost(self, monkeypatch):
        """An operator on a paid plan can fix what `--check` reports."""
        monkeypatch.setenv("SEEKWRIGHT_SERPAPI_API_KEY", "k")
        cfg = Config(providers={"serpapi": ProviderConfig(cost_per_1k=1.0)})
        built = build_providers(cfg, httpx.AsyncClient())
        assert built["serpapi"].cost_per_1k == 1.0

    def test_an_unset_cost_falls_back_to_the_adapter_default(self, monkeypatch):
        monkeypatch.setenv("SEEKWRIGHT_SERPAPI_API_KEY", "k")
        cfg = Config(providers={"serpapi": ProviderConfig()})
        built = build_providers(cfg, httpx.AsyncClient())
        assert built["serpapi"].cost_per_1k == 0.0
