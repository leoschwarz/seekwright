"""Linkup provider: response parsing, and the guards on upstream field shapes.

``sourcedAnswer`` returns ``{answer, sources: [{name, url, favicon, snippet}]}``;
``searchResults`` returns ``{results: [{name, url, content, type}]}``. The prose
and the snippets are documented as strings, but nothing upstream enforces it: a
nested object, list or number in ``answer`` used to reach
``ProviderResult.answer`` unguarded, raising ``pydantic.ValidationError``, and
the same shape in ``snippet``/``content`` raised ``AttributeError`` out of
``base.truncate_snippet``. Neither is a ``ProviderError``, so both escaped the
engine's provider-error handling as an internal error instead of being dropped.
``TestUpstreamFieldGuards`` pins the guards; the parsing tests pin that a
well-formed payload is unchanged.
"""

import json
from typing import Any

import httpx
import pytest

from seekwright.models import SearchQuery
from seekwright.providers.base import ProviderError, QuotaExhausted
from seekwright.providers.linkup import LinkupProvider

SAMPLE: dict[str, Any] = {
    "answer": "WAL lets readers proceed while one writer commits.",
    "sources": [
        {
            "name": "Write-Ahead Logging",
            "url": "https://www.sqlite.org/wal.html",
            "favicon": "https://www.sqlite.org/favicon.ico",
            "snippet": "The default method by which SQLite implements atomic "
            "commit is a rollback journal.",
        },
        {
            "name": "SQLite WAL mode explained",
            "url": "https://example.com/wal-explained",
            "snippet": "WAL allows readers and one writer to proceed concurrently.",
        },
    ],
}


def provider(client: httpx.AsyncClient | None = None, **kw) -> LinkupProvider:
    return LinkupProvider(client or httpx.AsyncClient(), "test-key", **kw)


def mock_client(handler) -> httpx.AsyncClient:
    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


class TestParsing:
    def test_sources_become_results(self):
        results = provider()._parse_sources(SAMPLE["sources"], limit=10)
        assert len(results) == 2
        assert results[0].title == "Write-Ahead Logging"
        assert results[0].url == "https://www.sqlite.org/wal.html"
        assert results[1].url == "https://example.com/wal-explained"

    def test_sources_honour_the_limit(self):
        assert len(provider()._parse_sources(SAMPLE["sources"], limit=1)) == 1

    def test_a_source_without_a_name_falls_back_to_its_url(self):
        sources = [{"url": "https://example.com/a", "snippet": "s"}]
        assert provider()._parse_sources(sources, limit=10)[0].title == (
            "https://example.com/a"
        )

    def test_sources_without_a_url_are_dropped(self):
        assert provider()._parse_sources([{"name": "no url"}], limit=10) == []

    def test_non_dict_sources_are_skipped(self):
        sources = ["nonsense", {"url": "https://example.com/a"}]
        assert len(provider()._parse_sources(sources, limit=10)) == 1

    def test_missing_sources_is_empty_not_an_error(self):
        assert provider()._parse_sources(None, limit=10) == []


class TestUpstreamFieldGuards:
    """A non-string ``answer``/``snippet``/``content`` is dropped, not handed on.

    The upstream payload is untrusted: the fields are documented as strings, and
    a shape drift must not turn into a ``ValidationError`` or an
    ``AttributeError`` that escapes the engine's provider-error handling as an
    internal error. The call has to succeed with the field dropped.
    """

    @pytest.mark.parametrize("bad_answer", [{"nested": "object"}, ["a", "b"], 7])
    async def test_a_non_string_answer_is_dropped_and_the_call_succeeds(self, bad_answer):
        data = {**SAMPLE, "answer": bad_answer}
        p = provider(mock_client(lambda _: httpx.Response(200, json=data)))
        result = await p.search(SearchQuery(query="q"))
        assert result.answer is None
        assert result.results, "the sources still parse"

    @pytest.mark.parametrize("bad_snippet", [{"nested": "object"}, ["a", "b"], 7])
    async def test_a_non_string_source_snippet_is_dropped_and_the_call_succeeds(
        self, bad_snippet
    ):
        """``sourcedAnswer`` sources carry their prose in ``snippet``, which
        goes through ``base.truncate_snippet`` -- and that called
        ``text.split()`` on whatever upstream sent."""
        sources = [{**SAMPLE["sources"][0], "snippet": bad_snippet}]
        p = provider(
            mock_client(lambda _: httpx.Response(200, json={"sources": sources}))
        )
        result = await p.search(SearchQuery(query="q"))
        assert len(result.results) == 1
        assert result.results[0].snippet is None

    @pytest.mark.parametrize("bad_content", [{"nested": "object"}, ["a", "b"], 7])
    async def test_a_non_string_result_content_is_dropped_and_the_call_succeeds(
        self, bad_content
    ):
        """``searchResults`` items carry theirs in ``content``, the same
        ``truncate_snippet`` call one branch over."""
        data = {
            "results": [
                {
                    "name": "Write-Ahead Logging",
                    "url": "https://www.sqlite.org/wal.html",
                    "content": bad_content,
                    "type": "text",
                }
            ]
        }
        p = provider(
            mock_client(lambda _: httpx.Response(200, json=data)),
            output_type="searchResults",
        )
        result = await p.search(SearchQuery(query="q"))
        assert len(result.results) == 1
        assert result.results[0].snippet is None

    async def test_a_string_answer_still_reaches_the_model(self):
        """The guard must not change behaviour for a well-formed payload."""
        p = provider(mock_client(lambda _: httpx.Response(200, json=SAMPLE)))
        result = await p.search(SearchQuery(query="q"))
        assert result.answer == "WAL lets readers proceed while one writer commits."

    async def test_a_string_snippet_still_reaches_the_model(self):
        """The guard must not change behaviour for a well-formed payload."""
        p = provider(mock_client(lambda _: httpx.Response(200, json=SAMPLE)))
        result = await p.search(SearchQuery(query="q"))
        assert result.results[0].snippet == (
            "The default method by which SQLite implements atomic commit is a "
            "rollback journal."
        )


class TestUnsupportedConstraints:
    """Linkup has native domain and date fields, and nothing else.

    No geo parameter, no language parameter, no safety parameter -- so the geo
    bucket keeps its joined `country/language` token (this adapter has no geo
    surface at all, which is the case the default exists for) and safe-search
    is a bucket of its own.
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

    async def test_the_geo_bucket_is_reported_joined(self):
        body, result = await self._search(country="de", language="de")
        assert "gl" not in body and "language" not in body
        assert result.notice == (
            "cannot filter by country/language; that constraint was ignored"
        )

    async def test_a_language_alone_is_reported_joined(self):
        """No half of the bucket is honoured, so the token stays joined."""
        _, result = await self._search(language="de")
        assert result.notice == (
            "cannot filter by country/language; that constraint was ignored"
        )

    @pytest.mark.parametrize("safe_search", [True, False])
    async def test_a_safe_search_is_noticed_for_both_values(self, safe_search):
        body, result = await self._search(safe_search=safe_search)
        assert "safe_search" not in body
        assert result.notice == (
            "cannot filter by safe-search; that constraint was ignored"
        )

    async def test_an_unconstrained_query_carries_no_notice(self):
        _, result = await self._search()
        assert result.notice is None


class TestErrors:
    """The one row this adapter answers differently.

    Linkup answers a spent account with the rate-limit status itself: its error
    table (https://docs.linkup.so/pages/documentation/platform/errors, fetched
    2026-10-20) reads "429 - Too Many Requests: You have run out of credit or you
    are sending too many concurrent requests", and its pricing page says "If your
    account runs out, the API will respond with a 429 HTTP error." So the house
    row is widened for ten adapters and not for this one, and 429 here is not a
    guess -- it is the vendor's own spent-credit status. Its ``402`` row is the
    x402 payment lane ("x402 payment signature is missing, invalid, or settlement
    failed"; "Send a request without authentication"), a lane this adapter never
    enters because it sends the Bearer key and ``config.PROVIDERS_REQUIRING_KEY``
    names ``linkup``: that is why this fallback stays 429 where ``scrappa``,
    ``tinyfish`` and ``anysearch`` read 402 (2026-10-20). An earlier
    revision of this docstring cited a ``400`` + body code
    ``INSUFFICIENT_CREDIT`` row and a ``503`` row from docs.linkup.ai, a domain
    that is not Linkup's; neither status appears on the errors page that does
    resolve, and both claims are withdrawn. The statuses below are the documented
    ones this adapter must not class as quota; they fall to the generic row,
    because classification here is on status alone. The six rows this adapter
    shares with every other one are pinned for all of them by
    ``tests/providers/test_provider_contract.py``.
    """

    async def test_rate_limit_is_quota(self):
        p = provider(mock_client(lambda _: httpx.Response(429, json={})))
        with pytest.raises(QuotaExhausted) as exc:
            await p.search(SearchQuery(query="q"))
        assert exc.value.message == "rate limited (10 QPS org-wide)"

    @pytest.mark.parametrize("status", [400, 402, 504])
    async def test_documented_non_quota_statuses_are_ordinary_http_failures(
        self, status
    ):
        # 400, 402 (the x402 lane) and 504 are Linkup rows to not read as quota;
        # 429 is the spent one.
        p = provider(mock_client(lambda _: httpx.Response(status, json={})))
        with pytest.raises(ProviderError) as exc:
            await p.search(SearchQuery(query="q"))
        assert exc.value.message == f"HTTP {status}"
