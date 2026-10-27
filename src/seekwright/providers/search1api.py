"""Search1API — multi-engine SERP, 1 credit per basic search.

A basic search is 1 credit whatever ``max_results`` says; Deep Search
(``crawl_results > 0``) adds a credit per crawled page. This adapter never sends
``crawl_results`` — deep search is a cost policy, not a caller choice, as Tavily
pins ``search_depth``. So a call here bills one credit, and ``cost_per_1k``
defaults to ``0.76``, the entry Basic plan's rate (plans run $0.49–0.76/1k; a
cheaper plan corrects it in config).
"""

from __future__ import annotations

from typing import Any

import httpx

from ..models import ProviderResult, Result, SearchQuery
from .base import (
    ProviderError,
    QuotaExhausted,
    ignored_constraints,
    truncate_snippet,
)

ENDPOINT = "https://api.search1api.com/search"


class Search1ApiProvider:
    name = "search1api"
    # Class level too, not just `__init__`: the protocol is structural (provider-contract.md).
    cost_per_1k: float

    def __init__(
        self,
        client: httpx.AsyncClient,
        api_key: str,
        *,
        cost_per_1k: float = 0.76,
        snippet_chars: int = 500,
        timeout: float = 10.0,
    ) -> None:
        self._client = client
        self._api_key = api_key
        self.cost_per_1k = cost_per_1k
        self._snippet_chars = snippet_chars
        self._timeout = timeout

    def cost_for(self, max_results: int) -> float:
        """Per-query cost in USD: one credit per basic search, flat."""
        return self.cost_per_1k / 1000.0

    async def search(self, q: SearchQuery) -> ProviderResult:
        body: dict[str, Any] = {"query": q.query, "max_results": q.max_results}
        if q.include_domains:
            body["include_sites"] = q.include_domains
        if q.exclude_domains:
            body["exclude_sites"] = q.exclude_domains
        if q.language:
            # Lowercased, not split: the schema guarantees two letters.
            body["language"] = q.language.lower()
        if q.recency:
            # The enum matches SearchQuery's exactly: day/week/month/year.
            body["time_range"] = q.recency

        try:
            resp = await self._client.post(
                ENDPOINT,
                json=body,
                headers={"Authorization": f"Bearer {self._api_key}"},
                timeout=self._timeout,
            )
        except httpx.TimeoutException as exc:
            raise ProviderError(self.name, "request timed out") from exc
        except httpx.HTTPError as exc:
            # Redaction rule: docs/reference/provider-contract.md, "Failures".
            raise ProviderError(self.name, "network error") from exc

        if resp.status_code in (401, 403):
            raise ProviderError(
                self.name, "authentication rejected (check API key)", retryable=False
            )
        if resp.status_code in (402, 429):
            # 402 is documented (application/problem+json): a keyed client is out of credits.
            raise QuotaExhausted(self.name, "out of credits or rate limited")
        if resp.status_code >= 400:
            raise ProviderError(self.name, f"HTTP {resp.status_code}")

        try:
            data = resp.json()
        except ValueError as exc:
            raise ProviderError(self.name, "malformed JSON response") from exc
        if not isinstance(data, dict):
            # Non-object JSON is the same contracted error as unparseable:
            # provider-contract.md, "Failures".
            raise ProviderError(self.name, "malformed JSON response")

        # Domains, dates and language ride native parameters; with no country and no
        # safe-search field, the notice names `country` alone.
        return ProviderResult(
            provider=self.name,
            results=self._parse(data, q.max_results),
            cost_usd=self.cost_for(q.max_results),
            notice=ignored_constraints(
                q, domains=True, dates=True, geo=False, language=True, safety=False
            ),
        )

    def _parse(self, data: dict[str, Any], limit: int) -> list[Result]:
        """Extract ranked hits, tolerating shape drift in the records.

        A SERP backend: ``snippet`` filled, never ``text``. ``content`` exists
        upstream only when ``crawl_results > 0``, which this adapter never sends,
        so it is never read.
        """
        out: list[Result] = []
        for item in (data.get("results") or [])[:limit]:
            if not isinstance(item, dict):
                continue
            url = item.get("link")
            title = item.get("title")
            if not url or not title:
                continue
            date = item.get("published_date")
            snippet, uncapped = truncate_snippet(
                item.get("snippet"), self._snippet_chars
            )
            result = Result(
                title=str(title),
                url=str(url),
                snippet=snippet,
                published_date=date if isinstance(date, str) else None,
            )
            # Log-only, and private so it cannot reach the wire (`search.cap`).
            result._uncapped_chars = uncapped
            out.append(result)
        return out

    async def aclose(self) -> None:
        # The lifespan owns the shared client (docs/reference/provider-contract.md).
        return None
