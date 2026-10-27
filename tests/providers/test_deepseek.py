"""DeepSeek Search provider: response parsing, request shape, cost and wiring.

The fixture is the documented ``/v1/tools/search`` payload from the operator's
own guide (``https://api-docs.deepseek.com/guides/search``, read 2026-10-21).
Each hit carries ``rerank_score``, ``title``, ``url``, ``snippet``, ``summary``,
``content``, ``site_name``, ``site_icon``, ``date`` and ``authority``;
``snippet`` is documented as the short UI preview and ``summary`` as the longer
one "intended to be read by a model", so a parsed result fills ``snippet`` and
``text`` while ``content`` -- the page body, filled only behind
``need_content``, which this adapter never sends -- never appears in one.

The adapter is shipped **untested** (no live verification against the real
endpoint in-repo; ``config.UNTESTED_PROVIDERS`` and the ``--check`` line say so
while it stays in that set), so these hermetic tests are the whole coverage that
exists -- the live test in ``tests/live/test_live.py`` is the follow-up that clears
the untested status.
"""

import json
from datetime import date
from typing import Any, Literal

import httpx
import pytest

from seekwright.config import Config, ProviderConfig
from seekwright.factory import build_providers
from seekwright.models import SearchQuery
from seekwright.providers.base import ProviderError, QuotaExhausted
from seekwright.providers.deepseek import (
    MAX_QUERY_CHARS,
    MAX_RESULTS,
    DeepSeekProvider,
    fold_operators,
)

SUMMARY_TEXT = (
    "DeepSeek has released the V4 model. The release adds improved tool "
    "calling and long-context support for agent workflows."
)

SAMPLE: dict[str, Any] = {
    "results": [
        {
            "rerank_score": 2.4,
            "title": "DeepSeek V4 model released",
            "url": "https://example.com/deepseek-v4",
            "snippet": "DeepSeek V4 is now available, with tool calling.",
            "summary": SUMMARY_TEXT,
            "content": "",
            "site_name": "Example News",
            "site_icon": "https://example.com/favicon.ico",
            "date": "2026-06-01T00:00:00+00:00",
            "authority": 3,
        },
        {
            "rerank_score": 1.1,
            "title": "Model card",
            "url": "https://example.org/v4-card",
            "snippet": "Weights, benchmarks and licence.",
            "summary": "The model card lists benchmarks.",
            "content": "",
            "site_name": None,
            "site_icon": None,
            "date": None,
            "authority": -1,
        },
    ]
}


def provider(client: httpx.AsyncClient | None = None, **kw) -> DeepSeekProvider:
    return DeepSeekProvider(client or httpx.AsyncClient(), "test-key", **kw)


def mock_client(handler) -> httpx.AsyncClient:
    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


# Typed so the parametrize keeps the recency literals instead of widening them to
# str.
_FALLBACKS: list[tuple[Literal["day", "week", "month", "year"], int]] = [
    ("day", 1),
    ("week", 7),
    ("month", 31),
    ("year", 366),
]


class TestParsing:
    def test_extracts_all_records(self):
        parsed = provider()._parse(SAMPLE, limit=10)
        assert [r.url for r in parsed] == [
            "https://example.com/deepseek-v4",
            "https://example.org/v4-card",
        ]

    def test_honours_the_limit(self):
        assert len(provider()._parse(SAMPLE, limit=1)) == 1

    def test_snippet_and_the_model_facing_summary_both_survive(self):
        first = provider()._parse(SAMPLE, limit=2)[0]
        assert first.snippet == "DeepSeek V4 is now available, with tool calling."
        assert first.text == SUMMARY_TEXT
        # Nothing was cut, so nothing is claimed to have been cut.
        assert first.text_truncated is None

    def test_a_long_summary_is_cut_at_the_text_cap(self):
        long_summary = "word " * 600
        payload = {
            "results": [
                {
                    "title": "Long",
                    "url": "https://example.com/long",
                    "summary": long_summary,
                }
            ]
        }
        first = provider(text_chars=50)._parse(payload, limit=1)[0]
        assert len(first.text or "") <= 50
        assert first.text_truncated is True
        # The cap happened inside the adapter, so the length it discarded only
        # reaches an operator through this log-only field (`search.cap`).
        assert first._uncapped_chars == len(" ".join(long_summary.split()))

    def test_a_record_with_no_summary_reports_no_length(self):
        """No text field at all, so the cap never ran and there is no length
        for `search.cap` to report."""
        payload = {"results": [{"title": "No summary", "url": "https://e.com"}]}
        assert provider()._parse(payload, limit=1)[0]._uncapped_chars is None

    def test_the_rerank_score_is_the_score(self):
        parsed = provider()._parse(SAMPLE, limit=2)
        assert parsed[0].score == 2.4
        assert parsed[1].score == 1.1

    def test_the_date_is_kept_only_when_a_string(self):
        parsed = provider()._parse(SAMPLE, limit=2)
        assert parsed[0].published_date == "2026-06-01T00:00:00+00:00"
        assert parsed[1].published_date is None

    def test_page_content_never_reaches_a_result(self):
        """``content`` is a page body, and ``fetch`` is where bodies belong."""
        payload = {
            "results": [
                {
                    "title": "With body",
                    "url": "https://example.com/body",
                    "content": "the full page text",
                }
            ]
        }
        first = provider()._parse(payload, limit=1)[0]
        assert first.text is None

    def test_records_without_a_url_are_dropped(self):
        payload = {"results": [{"title": "No url", "snippet": "x"}]}
        assert provider()._parse(payload, limit=5) == []

    def test_records_without_a_title_are_dropped(self):
        payload = {"results": [{"url": "https://example.com/x", "snippet": "x"}]}
        assert provider()._parse(payload, limit=5) == []

    def test_non_dict_records_are_skipped(self):
        payload = {"results": ["not-a-record", {"title": "T", "url": "https://e.com"}]}
        assert len(provider()._parse(payload, limit=5)) == 1

    def test_missing_results_is_empty_not_an_error(self):
        assert provider()._parse({}, limit=5) == []

    def test_a_non_list_results_container_is_empty_not_an_error(self):
        assert provider()._parse({"results": {"nope": 1}}, limit=5) == []


class TestUpstreamFieldGuards:
    """Shape drift in an untrusted payload drops the field, never the call.

    The three fields below are documented as a string and a number, and nothing
    on the wire enforces it: an ``AttributeError`` out of the parse would escape
    the engine's provider-error handling instead of reading as a missing field.
    """

    @pytest.mark.parametrize(
        ("field", "value"),
        [
            ("date", 1780000000),
            ("summary", {"parts": ["x"]}),
            ("snippet", ["a", "b"]),
            ("rerank_score", "2.4"),
        ],
    )
    async def test_a_field_of_the_wrong_shape_is_dropped_and_the_call_succeeds(
        self, field: str, value: Any
    ):
        record: dict[str, Any] = {"title": "T", "url": "https://example.com/x"}
        record[field] = value
        client = mock_client(
            lambda _: httpx.Response(200, json={"results": [record]})
        )
        result = await provider(client).search(SearchQuery(query="q"))
        assert len(result.results) == 1
        assert getattr(result.results[0], {
            "date": "published_date",
            "summary": "text",
            "snippet": "snippet",
            "rerank_score": "score",
        }[field]) is None


class TestRequestShape:
    """The body DeepSeek is sent, and the constraints it cannot honour.

    This backend has no filter fields on the request body at all: what it
    documents is a set of query operators, so domains, dates and language ride
    *inside* ``query`` -- in the order and the shape its own example uses. The
    whole request is bounded by a 128-character query, which the fold can push
    past, and ``country`` has no wire form (``localization`` takes an IP
    address) while ``safe_search`` has no parameter.
    """

    async def _search(self, **kw):
        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, json=SAMPLE)

        result = await provider(mock_client(handler)).search(
            SearchQuery(query=kw.pop("query", "deepseek v4"), **kw)
        )
        return json.loads(seen["request"].content), seen["request"], result

    async def test_posts_json_with_a_bearer_key(self):
        _, request, _ = await self._search()
        assert request.method == "POST"
        assert request.url.host == "api.deepseek.com"
        assert request.url.path == "/v1/tools/search"
        assert request.headers["Authorization"] == "Bearer test-key"

    async def test_the_query_and_count_are_sent(self):
        body, _, _ = await self._search(max_results=3)
        assert body["query"] == "deepseek v4"
        assert body["count"] == 3

    @pytest.mark.parametrize("max_results", [51, 100])
    async def test_count_is_clamped_to_the_documented_range(self, max_results: int):
        """``count`` is documented as 1..50, so the request never asks for
        more: the response simply carries fewer hits than asked, which is a
        shorter answer rather than a dropped constraint."""
        body, _, result = await self._search(max_results=max_results)
        assert body["count"] == MAX_RESULTS == 50
        assert result.notice is None

    def test_the_fold_is_the_operators_own_example(self):
        folded = fold_operators(
            SearchQuery(
                query="DeepSeek",
                include_domains=["github.com", "huggingface.co"],
                exclude_domains=["example.com"],
                language="EN",
                recency="week",
            ),
            today=date(2026, 10, 21),
        )
        assert folded == (
            "DeepSeek site:github.com OR site:huggingface.co -site:example.com "
            "lang:en after:2026-10-14"
        )

    def test_the_fold_adds_nothing_to_an_unconstrained_query(self):
        assert fold_operators(SearchQuery(query="q"), today=date(2026, 1, 1)) == "q"

    @pytest.mark.parametrize("recency,days", _FALLBACKS)
    def test_each_fallback_opens_the_window_that_many_days_back(
        self, recency: Literal["day", "week", "month", "year"], days: int
    ):
        folded = fold_operators(
            SearchQuery(query="q", recency=recency), today=date(2026, 10, 21)
        )
        start = date.fromisoformat(folded.split("after:")[1])
        assert (date(2026, 10, 21) - start).days == days

    async def test_a_domain_filter_folds_into_the_query(self):
        body, _, result = await self._search(
            include_domains=["example.com"], exclude_domains=["spam.example"]
        )
        assert body["query"] == (
            "deepseek v4 site:example.com -site:spam.example"
        )
        assert result.notice is None

    async def test_a_multi_site_include_is_the_documented_or_form(self):
        """No parentheses: the operator's example joins ``site:`` clauses with
        ``OR``, and this adapter sends the shape it documents."""
        body, _, _ = await self._search(
            include_domains=["github.com", "huggingface.co"]
        )
        assert body["query"] == "deepseek v4 site:github.com OR site:huggingface.co"

    async def test_language_folds_as_the_lang_operator(self):
        body, _, result = await self._search(language="EN")
        assert body["query"] == "deepseek v4 lang:en"
        assert result.notice is None

    async def test_recency_folds_as_an_after_operator_relative_to_today(self):
        body, _, result = await self._search(recency="day")
        assert body["query"].startswith("deepseek v4 after:2026-")
        assert result.notice is None

    async def test_country_is_never_sent_and_is_named_as_dropped(self):
        """``localization`` takes an IP address, and a two-letter country code
        is not one, so the ask goes to ``notice`` rather than to the wire."""
        body, _, result = await self._search(country="de")
        assert body["query"] == "deepseek v4"
        assert result.notice == (
            "cannot filter by country; that constraint was ignored"
        )

    @pytest.mark.parametrize("safe_search", [True, False])
    async def test_a_safe_search_is_noticed_for_both_values(self, safe_search: bool):
        _, _, result = await self._search(safe_search=safe_search)
        assert result.notice == (
            "cannot filter by safe-search; that constraint was ignored"
        )

    async def test_an_unconstrained_query_carries_no_notice(self):
        _, _, result = await self._search()
        assert result.notice is None

    @pytest.mark.parametrize("field", ["need_content", "ori_question", "localization"])
    async def test_never_sends_a_content_or_localization_field(self, field: str):
        """``need_content`` would ask for page bodies, ``ori_question`` is the
        question behind the search (unknown here), and ``localization`` takes an
        IP this proxy does not have. None of them may appear in a body."""
        body, _, _ = await self._search(include_domains=["example.com"], country="us")
        assert field not in body

    async def test_a_query_past_the_documented_limit_is_refused_before_sending(self):
        """The tool surface allows 400 characters, this backend allows 128: the
        adapter names the limit rather than forwarding a 400, and the request is
        not retryable -- it would have to change to succeed."""
        seen: dict[str, httpx.Request] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["request"] = request
            return httpx.Response(200, json=SAMPLE)

        p = provider(mock_client(handler))
        with pytest.raises(ProviderError) as exc:
            await p.search(SearchQuery(query="x" * (MAX_QUERY_CHARS + 1)))
        assert exc.value.retryable is False
        assert "128-character" in exc.value.message
        assert "request" not in seen

    async def test_operators_come_off_when_the_folded_query_would_not_fit(self):
        """The filters live inside the query, so a fold past 128 characters is a
        request the backend refuses. The bare query goes out and every bucket
        that came off is named: an unfiltered search the caller can see is
        better than a confident failure."""
        domains = ["example.com", "example.org", "example.net", "example.io"]
        body, _, result = await self._search(
            query="a" * 100, include_domains=domains, recency="year", language="en"
        )
        assert body["query"] == "a" * 100
        assert len(body["query"]) <= MAX_QUERY_CHARS
        assert result.notice == (
            "cannot filter by domain or dates or language; that constraint "
            "was ignored"
        )

    async def test_the_fold_stays_when_it_fits(self):
        body, _, result = await self._search(
            query="a" * 60, include_domains=["example.com"], recency="year"
        )
        assert body["query"].startswith("a" * 60 + " site:example.com after:")
        assert result.notice is None


class TestErrors:
    """Only the rows this adapter answers differently.

    The rows every HTTP adapter owes are pinned once for all of them by
    ``tests/providers/test_provider_contract.py``. What stays here is this adapter's quota
    statuses, its retryable upstream timeout, and the leak regression that
    proves the no-echo rule for the place its key actually rides.
    """

    @pytest.mark.parametrize("status", [402, 429])
    async def test_balance_and_rate_limit_are_quota(self, status: int):
        # 402 is this API's documented "insufficient balance" and 429 its
        # documented account-level QPS breach.
        p = provider(mock_client(lambda _: httpx.Response(status, json={})))
        with pytest.raises(QuotaExhausted):
            await p.search(SearchQuery(query="q"))

    async def test_the_upstream_timeout_row_is_retryable(self):
        """408 is documented as "reading the request body timed out", and the
        operator says to retry it."""
        p = provider(mock_client(lambda _: httpx.Response(408, json={})))
        with pytest.raises(ProviderError) as exc:
            await p.search(SearchQuery(query="q"))
        assert exc.value.retryable is True

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
    """Search bills per successful request, whatever ``count`` says."""

    def test_cost_does_not_scale_with_result_count(self):
        p = provider(cost_per_1k=0.75)
        assert p.cost_for(1) == p.cost_for(50) == pytest.approx(0.75 / 1000.0)

    async def test_reports_its_flat_cost_on_the_result(self):
        p = provider(mock_client(lambda _: httpx.Response(200, json=SAMPLE)))
        result = await p.search(SearchQuery(query="q", max_results=5))
        assert result.provider == "deepseek"
        assert result.cost_usd == pytest.approx(0.75 / 1000.0)

    async def test_a_search_with_no_results_is_not_billed(self):
        """The operator bills "per successful request" and states that an empty
        ``results`` array is not billed at all, so the call reports no cost."""
        p = provider(mock_client(lambda _: httpx.Response(200, json={"results": []})))
        result = await p.search(SearchQuery(query="q"))
        assert result.results == []
        assert result.cost_usd == 0.0


class TestWiring:
    def test_built_only_when_a_key_is_present(self, monkeypatch):
        cfg = Config(providers={"deepseek": ProviderConfig()})

        monkeypatch.delenv("SEEKWRIGHT_DEEPSEEK_API_KEY", raising=False)
        assert "deepseek" not in build_providers(cfg, httpx.AsyncClient())

        monkeypatch.setenv("SEEKWRIGHT_DEEPSEEK_API_KEY", "k")
        built = build_providers(cfg, httpx.AsyncClient())
        assert isinstance(built["deepseek"], DeepSeekProvider)

    def test_config_can_correct_the_cost(self, monkeypatch):
        """The published rate is an "as of" figure like every other row here, so
        an operator on different terms corrects it in config."""
        monkeypatch.setenv("SEEKWRIGHT_DEEPSEEK_API_KEY", "k")
        cfg = Config(providers={"deepseek": ProviderConfig(cost_per_1k=1.0)})
        built = build_providers(cfg, httpx.AsyncClient())
        assert built["deepseek"].cost_per_1k == 1.0

    def test_an_unset_cost_falls_back_to_the_published_rate(self, monkeypatch):
        """No free tier is documented, so the default is the price itself."""
        monkeypatch.setenv("SEEKWRIGHT_DEEPSEEK_API_KEY", "k")
        cfg = Config(providers={"deepseek": ProviderConfig()})
        built = build_providers(cfg, httpx.AsyncClient())
        assert built["deepseek"].cost_per_1k == 0.75
