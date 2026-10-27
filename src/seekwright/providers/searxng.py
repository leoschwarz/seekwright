"""SearXNG -- a self-hosted metasearch instance, reached over its JSON API.

Cost note: free, because it is the operator's own hardware aggregating other
engines' results. There is no public endpoint to default to, so the instance
URL is config (`[providers.searxng] url`) and enabling the provider without one
is a startup error rather than a silently absent backend.

The instance must serve `format=json` (`settings.yml`: `search.formats`
including `json`); an instance without it answers HTML to every request, which
surfaces here as the standard "malformed JSON response" error. No SSRF guard
sits in front of the URL: it is operator-fixed config and no caller input
reaches it -- the same trust level as Exa's `url`.
"""

from __future__ import annotations

from typing import Any

import httpx

from ..models import ProviderResult, Result, SearchQuery
from .base import (
    ProviderError,
    QuotaExhausted,
    ignored_constraints,
    site_filtered_query,
    truncate_snippet,
)

_MAX_PAGES = 3
"""Worst-case pages per search.

Each page is another request to the operator's instance, which fans it out to
its engines behind the scenes -- the bound is what keeps one caller's
`max_results` from turning into an unbounded number of upstream scrapes.
Three pages cover any `max_results` the tool schema allows (it caps at 20)
at the default page size, and more when an instance is configured smaller.
"""


class SearxngProvider:
    name = "searxng"
    # Class level, not just `__init__`: the protocol is structural (docs/reference/provider-contract.md).
    cost_per_1k: float

    def __init__(
        self,
        client: httpx.AsyncClient,
        *,
        url: str,
        cost_per_1k: float = 0.0,
        snippet_chars: int = 500,
        timeout: float = 15.0,
    ) -> None:
        self._client = client
        # One trailing slash, however the operator wrote it.
        self._url = url.rstrip("/") + "/search"
        self.cost_per_1k = cost_per_1k
        self._snippet_chars = snippet_chars
        self._timeout = timeout

    def cost_for(self, _max_results: int) -> float:
        """Per-query cost in USD. Flat zero: a self-hosted instance bills no one.

        The argument is ignored rather than absent for the reason
        ``freeserp.cost_for`` gives: callers treat it as a duck-typed method.
        """
        return self.cost_per_1k / 1000.0

    async def search(self, q: SearchQuery) -> ProviderResult:
        base: dict[str, Any] = {
            "q": site_filtered_query(q),
            "format": "json",
        }
        if q.recency:
            # SearXNG's own enum is day/week/month/year, so this mapping is the identity.
            base["time_range"] = q.recency
        if q.language:
            # Passed as given: the schema's two-letter code is the form SearXNG documents.
            base["language"] = q.language
        if q.safe_search is not None:
            # `safesearch` is 0|1|2 and its `1` (moderate) is deliberately unreachable:
            # `True` is the strongest on-state a backend has, and `None` sends nothing.
            base["safesearch"] = 2 if q.safe_search else 0

        # Page size is the instance's to choose, so more hits are only learned by asking.
        collected: list[Result] = []
        for pageno in range(1, _MAX_PAGES + 1):
            data = await self._get({**base, "pageno": pageno}, required=pageno == 1)
            if data is None:
                break
            page = self._parse(data, q.max_results)
            collected.extend(page)
            if len(collected) >= q.max_results or not page:
                break

        return ProviderResult(
            provider=self.name,
            results=collected[: q.max_results],
            cost_usd=self.cost_for(q.max_results),
            # Domains ride `site:` operators, recency maps onto `time_range`, language and
            # safe-search are native; no country parameter exists, so only that half falls.
            notice=ignored_constraints(
                q, domains=True, dates=True, geo=False, language=True, safety=True
            ),
        )

    async def _get(
        self, params: dict[str, Any], *, required: bool
    ) -> dict[str, Any] | None:
        """Fetch one result page, or ``None`` when a continuation page fails.

        The first page is ``required``, so its failures raise. A later page fails
        soft: the caller already holds good results, and a flaky or rate-limited
        continuation must not destroy a search that succeeded. Fewer results than
        asked needs no ``notice`` -- the field is for unhonoured constraints,
        not availability.
        """
        try:
            return await self._get_strict(params)
        except ProviderError:
            if required:
                raise
            return None

    async def _get_strict(self, params: dict[str, Any]) -> dict[str, Any]:
        try:
            resp = await self._client.get(self._url, params=params, timeout=self._timeout)
        except httpx.TimeoutException as exc:
            raise ProviderError(self.name, "request timed out") from exc
        except httpx.HTTPError as exc:
            raise ProviderError(self.name, "network error") from exc

        # A locked-down instance can answer 401/403 to the JSON format specifically.
        if resp.status_code in (401, 403):
            raise ProviderError(
                self.name,
                "authentication rejected (enable `format=json` for this client)",
                retryable=False,
            )
        # 429 is the whole quota row: nothing bills this transport, and a 402 in front of an
        # instance URL is the reverse proxy sitting there, not quota.
        if resp.status_code == 429:
            raise QuotaExhausted(self.name, "rate limited by the instance")
        if resp.status_code >= 400:
            raise ProviderError(self.name, f"HTTP {resp.status_code}")

        try:
            data = resp.json()
        except ValueError as exc:
            # Almost always `search.formats` missing `json`: the HTML page answered instead.
            raise ProviderError(self.name, "malformed JSON response") from exc
        if not isinstance(data, dict):
            # A JSON body that is not an object is the same contracted error as an
            # unparseable one: docs/reference/provider-contract.md, "Failures".
            raise ProviderError(self.name, "malformed JSON response")
        return data

    def _parse(self, data: dict[str, Any], limit: int) -> list[Result]:
        """Extract hits from the JSON API's ``results[]``.

        Records missing a title or URL are dropped rather than invented around.
        ``engines`` and ``infobox`` metadata is left where it came from.
        """
        out: list[Result] = []
        for item in (data.get("results") or [])[:limit]:
            if not isinstance(item, dict):
                continue
            url = item.get("url")
            title = item.get("title")
            if not url or not title:
                continue
            published = item.get("publishedDate")
            score = item.get("score")
            snippet, uncapped = truncate_snippet(
                item.get("content"), self._snippet_chars
            )
            result = Result(
                title=str(title),
                url=str(url),
                snippet=snippet,
                # The JSON API serialises this as a string; anything else is ignored.
                published_date=published if isinstance(published, str) else None,
                score=float(score) if isinstance(score, int | float) else None,
            )
            # Log-only, and private so it cannot reach the wire (`search.cap`).
            result._uncapped_chars = uncapped
            out.append(result)
        return out

    async def aclose(self) -> None:
        # The lifespan owns the shared client (docs/reference/provider-contract.md).
        return None
