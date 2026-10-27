"""Tavily provider: response parsing, request shape, cost and wiring.

The fixture is the documented payload (see ``docs/reference/providers.md``).
The request-shape tests drive the provider through an ``httpx.MockTransport``,
which is possible here and not for the MCP adapter because the client is
injected.
"""

import json
from typing import Any

import httpx
import pytest

from seekwright.config import Config, ProviderConfig
from seekwright.factory import build_providers
from seekwright.models import SearchQuery
from seekwright.providers.base import ProviderError, QuotaExhausted
from seekwright.providers.tavily import TavilyProvider

SAMPLE: dict[str, Any] = {
    "answer": "WAL lets readers proceed while one writer commits.",
    "results": [
        {
            "title": "Write-Ahead Logging",
            "url": "https://www.sqlite.org/wal.html",
            "content": "The default method by which SQLite implements atomic "
            "commit is a rollback journal. Beginning with version 3.7.0 the "
            "WAL option is available.",
            "score": 0.94,
            "published_date": "2024-11-03",
        },
        {
            "title": "SQLite WAL mode explained",
            "url": "https://example.com/wal-explained",
            "content": "WAL allows readers and one writer to proceed concurrently.",
            "score": 0.81,
        },
    ],
    "response_time": 1.2,
}


def provider(client: httpx.AsyncClient | None = None, **kw) -> TavilyProvider:
    return TavilyProvider(client or httpx.AsyncClient(), "test-key", **kw)


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

    def test_content_becomes_text_never_snippet(self):
        """Filling both would ship the same prose twice -- the snippet would
        be a prefix of the extract."""
        results = provider()._parse(SAMPLE, limit=10)
        assert results[0].text
        assert results[0].snippet is None

    def test_text_is_capped_and_the_cut_is_flagged(self):
        results = provider(text_chars=40)._parse(SAMPLE, limit=10)
        assert len(results[0].text or "") <= 41  # the ellipsis is one char
        assert results[0].text_truncated is True

    def test_a_short_page_is_not_flagged_as_cut(self):
        data = {"results": [{"title": "t", "url": "u", "content": "short."}]}
        results = provider(text_chars=40)._parse(data, limit=10)
        assert results[0].text_truncated is None

    def test_score_and_published_date_are_kept_when_present(self):
        results = provider()._parse(SAMPLE, limit=10)
        assert results[0].score == pytest.approx(0.94)
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
    """A non-string ``content`` is dropped, not handed to ``truncate_text``.

    ``content`` becomes ``Result.text`` through ``base.truncate_text``, which
    called ``text.split()`` on whatever upstream sent. A nested object, list or
    number there raised ``AttributeError`` -- not a ``ProviderError`` -- so it
    escaped the engine's provider-error handling and surfaced as an internal
    error instead of a field the adapter dropped. ``answer`` has its own guard
    in ``TestRequestShape``.
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
        result = await p.search(SearchQuery(query="q"))
        assert len(result.results) == 1
        assert result.results[0].text is None
        assert result.results[0].text_truncated is None, "nothing was cut"

    async def test_a_string_content_still_reaches_the_model(self):
        """The guard must not change behaviour for a well-formed payload."""
        p = provider(mock_client(lambda _: httpx.Response(200, json=SAMPLE)))
        result = await p.search(SearchQuery(query="q"))
        assert result.results[0].text == (
            "The default method by which SQLite implements atomic commit is a "
            "rollback journal. Beginning with version 3.7.0 the WAL option is "
            "available."
        )
        assert result.results[0].text_truncated is None


class TestRequestShape:
    async def test_sends_post_with_bearer_and_documented_body(self):
        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, json=SAMPLE)

        p = provider(mock_client(handler))
        await p.search(SearchQuery(query="wal mode", max_results=3))

        request = seen["request"]
        assert request.method == "POST"
        assert request.headers["Authorization"] == "Bearer test-key"
        body = json.loads(request.read().decode())
        assert body["query"] == "wal mode"
        assert body["search_depth"] == "basic"
        assert body["max_results"] == 3
        assert body["include_answer"] == "basic"
        assert body["include_raw_content"] is False

    async def test_query_is_sent_verbatim_without_site_folding(self):
        """Native domain fields exist; folding `site:` would only degrade
        Tavily's own matching."""
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
        body = json.loads(seen["request"].read().decode())
        assert body["query"] == "wal mode", "no site: operators in the query"
        assert body["include_domains"] == ["sqlite.org"]
        assert body["exclude_domains"] == ["spam.example"]

    async def test_recency_maps_onto_time_range(self):
        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, json=SAMPLE)

        p = provider(mock_client(handler))
        await p.search(SearchQuery(query="wal", recency="month"))
        body = json.loads(seen["request"].read().decode())
        assert body["time_range"] == "month"

    async def test_time_range_absent_without_recency(self):
        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, json=SAMPLE)

        p = provider(mock_client(handler))
        await p.search(SearchQuery(query="wal"))
        body = json.loads(seen["request"].read().decode())
        assert "time_range" not in body

    async def test_answer_passes_through(self):
        p = provider(mock_client(lambda _: httpx.Response(200, json=SAMPLE)))
        result = await p.search(SearchQuery(query="q"))
        assert result.answer == "WAL lets readers proceed while one writer commits."

    @pytest.mark.parametrize("bad_answer", [{"nested": "object"}, ["a", "b"], 7])
    async def test_a_non_string_answer_is_dropped_and_the_call_succeeds(self, bad_answer):
        """`answer` is documented as a string, but nothing upstream enforces it:
        a nested object, list or number used to reach `ProviderResult.answer`
        unguarded and raise `pydantic.ValidationError` out of the provider
        layer. It is dropped instead -- the same rule the sibling adapters
        apply to `published_date` and `score`."""
        p = provider(
            mock_client(lambda _: httpx.Response(200, json={**SAMPLE, "answer": bad_answer}))
        )
        result = await p.search(SearchQuery(query="q"))
        assert result.answer is None
        assert result.results, "the results still parse"

    async def test_reports_a_flat_cost_on_the_result(self):
        p = provider(mock_client(lambda _: httpx.Response(200, json=SAMPLE)))
        result = await p.search(SearchQuery(query="q", max_results=5))
        assert result.provider == "tavily"
        assert result.cost_usd == pytest.approx(8.00 / 1000.0)

    async def test_a_mappable_country_is_no_longer_noticed(self):
        """`country="de"` is honoured, not noticed: Tavily has a closed
        `country` enum, and a code that maps onto it is sent natively.
        Only a value that maps to nothing is noticed, and that case is
        covered in `TestGeo`, which is where the mapping itself is
        asserted."""
        p = provider(mock_client(lambda _: httpx.Response(200, json=SAMPLE)))
        result = await p.search(SearchQuery(query="q", country="de"))
        assert result.notice is None

    async def test_no_notice_for_what_it_honours(self):
        p = provider(mock_client(lambda _: httpx.Response(200, json=SAMPLE)))
        result = await p.search(
            SearchQuery(
                query="q", include_domains=["sqlite.org"], recency="week"
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

    @pytest.mark.parametrize("status", [429, 432])
    async def test_rate_limit_and_quota_are_quota(self, status: int):
        # 432 is Tavily's monthly-credit-exhausted code; 429 is rate limiting.
        # Both are the same month's quota question, so both are non-retryable.
        p = provider(mock_client(lambda _: httpx.Response(status, json={})))
        with pytest.raises(QuotaExhausted):
            await p.search(SearchQuery(query="q"))

    async def test_network_error_does_not_echo_the_request(self):
        def handler(_: httpx.Request) -> httpx.Response:
            raise httpx.ConnectError("connection refused to bearer test-key")

        p = provider(mock_client(handler))
        with pytest.raises(ProviderError) as exc:
            await p.search(SearchQuery(query="q"))
        # The message must not carry the underlying exception: httpx errors can
        # echo the request headers, and those hold the key.
        assert exc.value.message == "network error"
        assert "test-key" not in str(exc.value)


class TestCost:
    def test_cost_does_not_scale_with_result_count(self):
        """Basic search is one credit per request, whatever max_results says."""
        p = provider()
        assert p.cost_for(1) == p.cost_for(20) == pytest.approx(8.00 / 1000.0)


class TestWiring:
    def test_built_only_when_a_key_is_present(self, monkeypatch):
        cfg = Config(providers={"tavily": ProviderConfig()})

        monkeypatch.delenv("SEEKWRIGHT_TAVILY_API_KEY", raising=False)
        assert "tavily" not in build_providers(cfg, httpx.AsyncClient())

        monkeypatch.setenv("SEEKWRIGHT_TAVILY_API_KEY", "k")
        built = build_providers(cfg, httpx.AsyncClient())
        assert isinstance(built["tavily"], TavilyProvider)

    def test_text_cap_follows_policy(self, monkeypatch):
        monkeypatch.setenv("SEEKWRIGHT_TAVILY_API_KEY", "k")
        from seekwright.config import PolicyConfig

        cfg = Config(
            providers={"tavily": ProviderConfig()},
            policy=PolicyConfig(max_result_text_chars=123),
        )
        built = build_providers(cfg, httpx.AsyncClient())
        assert isinstance(built["tavily"], TavilyProvider)
        assert built["tavily"]._text_chars == 123

    def test_an_unset_cost_falls_back_to_the_adapter_default(self, monkeypatch):
        monkeypatch.setenv("SEEKWRIGHT_TAVILY_API_KEY", "k")
        cfg = Config(providers={"tavily": ProviderConfig()})
        built = build_providers(cfg, httpx.AsyncClient())
        assert built["tavily"].cost_per_1k == 8.00

    def test_config_can_correct_the_cost(self, monkeypatch):
        monkeypatch.setenv("SEEKWRIGHT_TAVILY_API_KEY", "k")
        cfg = Config(providers={"tavily": ProviderConfig(cost_per_1k=5.00)})
        built = build_providers(cfg, httpx.AsyncClient())
        assert built["tavily"].cost_per_1k == 5.00


class TestGeo:
    """`country` and `language` are ranking boosts upstream, mapped natively
    (the mapping came from the mcp-omnisearch eval). Tavily's
    `country` is a closed enum, validated before sending: a value that maps
    to nothing is omitted and noticed, not sent to be rejected."""

    async def _search(self, **kw):
        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, json=SAMPLE)

        result = await provider(mock_client(handler)).search(
            SearchQuery(query="wal", **kw)
        )
        return json.loads(seen["request"].content), result

    async def test_a_country_name_passes_through(self):
        body, result = await self._search(country="Switzerland")
        assert body["country"] == "switzerland"
        assert result.notice is None

    async def test_a_country_code_maps_onto_the_enum_name(self):
        body, result = await self._search(country="DE")
        assert body["country"] == "germany"
        assert result.notice is None

    async def test_an_unmappable_country_is_omitted_and_noticed(self):
        body, result = await self._search(country="atlantis")
        assert "country" not in body
        assert result.notice == "cannot filter by country; that constraint was ignored"

    async def test_a_language_beside_a_mappable_country_gets_no_notice(self):
        body, result = await self._search(country="DE", language="de")
        assert body["country"] == "germany"
        assert body["language"] == "de"
        assert result.notice is None

    async def test_a_language_beside_an_unmappable_country_is_not_claimed_as_dropped(self):
        """Both halves set: only the country was dropped, so only it is named.

        `language` carries the language on the very same request; the joined
        `country/language` token this used to emit said otherwise.
        """
        body, result = await self._search(country="atlantis", language="de")
        assert "country" not in body
        assert body["language"] == "de"
        assert result.notice == "cannot filter by country; that constraint was ignored"

    async def test_a_language_maps_onto_the_language_parameter(self):
        body, result = await self._search(language="DE")
        assert body["language"] == "de"
        assert result.notice is None

    async def test_language_is_absent_without_one(self):
        body, _ = await self._search()
        assert "language" not in body


class TestSafeSearch:
    """Tavily's `safe_search` is a boolean, so both values are honoured exactly.

    That is the design property the whole parameter rests on: there is no
    partially-honoured case to word, because every capable backend maps `True`
    and `False` onto a state of its own without a level scale in between.
    Tavily's own caveat ("not supported for `fast` or `ultra-fast` depths") does
    not bite, because this adapter pins `search_depth` to `basic` server-side.
    """

    async def _search(self, **kw):
        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, json=SAMPLE)

        result = await provider(mock_client(handler)).search(
            SearchQuery(query="wal", **kw)
        )
        return json.loads(seen["request"].content), result

    @pytest.mark.parametrize("safe_search", [True, False])
    async def test_both_values_reach_the_wire_and_neither_is_noticed(
        self, safe_search
    ):
        body, result = await self._search(safe_search=safe_search)
        assert body["safe_search"] is safe_search
        assert body["search_depth"] == "basic", "the depth the caveat depends on"
        assert result.notice is None

    async def test_safe_search_is_omitted_when_none(self):
        """`None` sends nothing, so Tavily's own default stands.

        Not the same as `false`: an unasked-for `safe_search: false` would
        override a default the caller never asked about.
        """
        body, _ = await self._search()
        assert "safe_search" not in body


class TestReportedUsage:
    async def test_credits_become_reported_cost_off_the_wire(self):
        def handler(_: httpx.Request) -> httpx.Response:
            return httpx.Response(200, json={**SAMPLE, "usage": {"credits": 1}})

        result = await provider(mock_client(handler)).search(SearchQuery(query="wal"))
        assert result._reported_cost_usd == pytest.approx(0.008)
        # Log-only, the same rule as `cost_usd`: the caller is not the party
        # paying.
        assert "reported_cost_usd" not in result.model_dump()

    async def test_no_usage_leaves_it_unset(self):
        def handler(_: httpx.Request) -> httpx.Response:
            return httpx.Response(200, json=SAMPLE)

        result = await provider(mock_client(handler)).search(SearchQuery(query="wal"))
        assert result._reported_cost_usd is None
