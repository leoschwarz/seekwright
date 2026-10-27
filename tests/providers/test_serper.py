"""Serper provider: response parsing, the guard on upstream field shapes, and
the one constraint the adapter cannot honour.

Serper is a raw SERP backend -- ``organic[]`` records carry a ``snippet`` and a
``date``, both documented as strings -- but nothing upstream enforces that. A
nested object, list or number in ``date`` used to reach ``Result.published_date``
unguarded, raising ``pydantic.ValidationError``; the same shape in ``snippet``
raised ``AttributeError`` out of ``base.truncate_snippet``. Neither is a
``ProviderError``, so both escaped the engine's provider-error handling as an
internal error instead of being dropped the way every sibling adapter drops a
non-string. ``TestUpstreamFieldGuards`` pins both guards; the parsing tests pin
that a well-formed payload is unchanged.

``TestRequestShape`` covers the request body and the safe-search drop. Serper
has no such parameter, so this is the adapter whose ``notice`` is the only
thing standing between a caller that asked for filtered results and the belief
that it got them.
"""

import json
from typing import Any

import httpx
import pytest

from seekwright.models import SearchQuery
from seekwright.providers.base import QuotaExhausted
from seekwright.providers.serper import SerperProvider

SAMPLE: dict[str, Any] = {
    "organic": [
        {
            "title": "Write-Ahead Logging",
            "link": "https://www.sqlite.org/wal.html",
            "snippet": "The default method by which SQLite implements atomic "
            "commit is a rollback journal.",
            "date": "2024-11-03",
        },
        {
            "title": "SQLite WAL mode explained",
            "link": "https://example.com/wal-explained",
            "snippet": "WAL allows readers and one writer to proceed concurrently.",
        },
    ],
    "credits": 1,
}


def provider(client: httpx.AsyncClient | None = None, **kw) -> SerperProvider:
    return SerperProvider(client or httpx.AsyncClient(), "test-key", **kw)


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

    def test_date_is_kept_only_when_a_string(self):
        results = provider()._parse(SAMPLE, limit=10)
        assert results[0].published_date == "2024-11-03"
        assert results[1].published_date is None

    def test_records_without_a_url_are_dropped(self):
        data = {"organic": [{"title": "No url here"}]}
        assert provider()._parse(data, limit=10) == []

    def test_records_without_a_title_are_dropped(self):
        data = {"organic": [{"link": "https://example.com"}]}
        assert provider()._parse(data, limit=10) == []

    def test_non_dict_records_are_skipped(self):
        data = {"organic": ["nonsense", {"title": "t", "link": "u"}]}
        assert len(provider()._parse(data, limit=10)) == 1

    def test_missing_organic_is_empty_not_an_error(self):
        assert provider()._parse({"organic": None}, limit=10) == []
        assert provider()._parse({}, limit=10) == []


class TestUpstreamFieldGuards:
    """A non-string ``date`` or ``snippet`` is dropped, not handed to pydantic.

    The upstream payload is untrusted: the fields are documented as strings, and
    a shape drift must not turn into a ``ValidationError`` or an
    ``AttributeError`` that escapes the engine's provider-error handling as an
    internal error. The call has to succeed with the field dropped, exactly as
    the sibling adapters (``searxng``, ``tavily``, ``tinyfish``) already do.
    """

    @pytest.mark.parametrize("bad_date", [{"nested": "object"}, ["a", "b"], 20241103])
    async def test_a_non_string_date_is_dropped_and_the_call_succeeds(self, bad_date):
        data = {
            "organic": [
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
        """``snippet`` goes through ``base.truncate_snippet``, which called
        ``text.split()`` on whatever upstream sent. A non-string there raised
        ``AttributeError`` -- not a ``ProviderError`` -- so it escaped the
        engine's provider-error handling instead of being dropped."""
        data = {
            "organic": [
                {"title": "t", "link": "https://example.com/a", "snippet": bad_snippet}
            ]
        }
        p = provider(mock_client(lambda _: httpx.Response(200, json=data)))
        result = await p.search(SearchQuery(query="q"))
        assert len(result.results) == 1
        assert result.results[0].snippet is None

    async def test_a_string_date_still_reaches_the_model(self):
        """The guard must not change behaviour for a well-formed payload."""
        p = provider(mock_client(lambda _: httpx.Response(200, json=SAMPLE)))
        result = await p.search(SearchQuery(query="q"))
        assert result.results[0].published_date == "2024-11-03"

    async def test_a_string_snippet_still_reaches_the_model(self):
        """The guard must not change behaviour for a well-formed payload."""
        p = provider(mock_client(lambda _: httpx.Response(200, json=SAMPLE)))
        result = await p.search(SearchQuery(query="q"))
        assert result.results[0].snippet == (
            "The default method by which SQLite implements atomic commit is a "
            "rollback journal."
        )


class TestRequestShape:
    """The body Serper is sent, and the one constraint it cannot honour.

    Domains ride the query as `site:` operators and `gl`/`hl` are native, so
    three buckets are honoured. Serper has no safe-search parameter at all,
    which makes this adapter the first whose notice is the *only* thing it can
    say about a constraint it was handed.
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

    async def test_language_maps_onto_hl_lowercased(self):
        body, result = await self._search(language="DE")
        assert body["hl"] == "de"
        assert result.notice is None

    async def test_hl_is_absent_without_a_language(self):
        body, _ = await self._search()
        assert "hl" not in body

    async def test_no_safe_search_parameter_is_ever_sent(self):
        for value in (True, False):
            body, _ = await self._search(safe_search=value)
            assert "safe" not in body
            assert "safe_search" not in body

    @pytest.mark.parametrize("safe_search", [True, False])
    async def test_a_safe_search_is_noticed_for_both_values(self, safe_search):
        _, result = await self._search(safe_search=safe_search)
        assert result.notice == (
            "cannot filter by safe-search; that constraint was ignored"
        )

    async def test_an_unconstrained_query_carries_no_notice(self):
        _, result = await self._search()
        assert result.notice is None


class TestErrors:
    """The one row this adapter answers differently.

    Serper bills by credit pack ("50k credits ($1.00/1k)", "simply pay for the
    credits you need" -- https://serper.dev/, fetched 2026-10-20), so a spent
    balance is a payment question and both 402 and 429 ride ``QuotaExhausted``,
    which is the house row. No vendor page pins which status a spent key answers
    with, and the FAQ sentence an earlier revision of this docstring quoted could
    not be opened from the deployment host: ``dev.serper.dev`` does not resolve and
    ``https://serper.dev/faq`` answers 404 (probed 2026-10-20). This
    pin below is the classing itself, not a transcription of vendor prose. The
    adapter used to read only 429, and a spent
    account surfaced as the unclassified ``HTTP 402``, which the engine does not
    treat as quota (2026-10-20; it answers open question 3 of the 2026-10
    refactor survey for this adapter). The six rows shared with every other
    adapter are pinned for all of them by ``tests/providers/test_provider_contract.py``.
    """

    @pytest.mark.parametrize("status", [402, 429])
    async def test_spent_credits_and_rate_limit_are_quota(self, status):
        p = provider(mock_client(lambda _: httpx.Response(status, json={})))
        with pytest.raises(QuotaExhausted) as exc:
            await p.search(SearchQuery(query="q"))
        assert exc.value.message == "rate limited or out of credits"
