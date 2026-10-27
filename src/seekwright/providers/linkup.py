"""Linkup -- answer synthesis with citations, ~$6/1k for ``sourcedAnswer``.

Shapes verified against the API reference. ``POST /search`` takes ``q``,
``depth``, ``outputType``, ``includeDomains``, ``excludeDomains``,
``maxResults`` and ``fromDate`` (``recency`` maps onto it; ``toDate`` stays
unexposed because recency is open-ended). ``sourcedAnswer`` returns
``{answer, sources: [{name, url, favicon, snippet}]}``; ``searchResults``
returns ``{results: [{name, url, content, favicon, type}]}``.

``depth`` stays server-side: ``deep`` is a 10x cost cliff ($0.05 vs $0.006).
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import Any

import httpx

from ..models import ProviderResult, Result, SearchQuery
from .base import ProviderError, QuotaExhausted, ignored_constraints, truncate_snippet

ENDPOINT = "https://api.linkup.so/v1/search"

# Coarse freshness -> how far back `fromDate` reaches. Recency is open-ended by
# definition, so there is no `toDate`.
_AGE_DAYS = {"day": 1, "week": 7, "month": 30, "year": 365}


class LinkupProvider:
    name = "linkup"
    # Class level too, not just `__init__`: the protocol is structural (provider-contract.md).
    cost_per_1k: float

    def __init__(
        self,
        client: httpx.AsyncClient,
        api_key: str,
        *,
        output_type: str = "sourcedAnswer",
        depth: str = "standard",
        cost_per_1k: float = 6.00,
        snippet_chars: int = 500,
        timeout: float = 20.0,
    ) -> None:
        self._client = client
        self._api_key = api_key
        # Which output type this deployment wants is config: `sourcedAnswer` is what buys it.
        self._output_type = output_type
        self._depth = depth
        self.cost_per_1k = cost_per_1k
        self._snippet_chars = snippet_chars
        self._timeout = timeout

    def cost_for(self, max_results: int) -> float:
        # Linkup bills per request, so cost does not scale with result count.
        return self.cost_per_1k / 1000.0

    async def search(self, q: SearchQuery) -> ProviderResult:
        body: dict[str, Any] = {
            "q": q.query,
            "depth": self._depth,
            "outputType": self._output_type,
            "maxResults": q.max_results,
        }
        if q.include_domains:
            body["includeDomains"] = q.include_domains
        if q.exclude_domains:
            body["excludeDomains"] = q.exclude_domains
        if q.recency:
            body["fromDate"] = (
                datetime.now(UTC) - timedelta(days=_AGE_DAYS[q.recency])
            ).strftime("%Y-%m-%dT%H:%M:%SZ")

        try:
            resp = await self._client.post(
                ENDPOINT,
                json=body,
                headers={
                    "Authorization": f"Bearer {self._api_key}",
                    "Content-Type": "application/json",
                },
                timeout=self._timeout,
            )
        except httpx.TimeoutException as exc:
            raise ProviderError(self.name, "request timed out") from exc
        except httpx.HTTPError as exc:
            raise ProviderError(self.name, "network error") from exc

        if resp.status_code in (401, 403):
            raise ProviderError(
                self.name, "authentication rejected (check API key)", retryable=False
            )
        # LinkUp answers a spent account with 429 (error table and pricing page both
        # say so); its 402 belongs to the keyless x402 lane this adapter never enters.
        if resp.status_code == 429:
            raise QuotaExhausted(self.name, "rate limited (10 QPS org-wide)")
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

        if self._output_type == "sourcedAnswer":
            results = self._parse_sources(data.get("sources"), q.max_results)
            raw_answer = data.get("answer")
            answer = raw_answer if isinstance(raw_answer, str) else None
        else:
            results = self._parse_results(data.get("results"), q.max_results)
            answer = None

        return ProviderResult(
            provider=self.name,
            results=results,
            answer=answer,
            cost_usd=self.cost_for(q.max_results),
            # Native domains and `fromDate`; no geo or safe-search parameter at all.
            notice=ignored_constraints(
                q, domains=True, dates=True, geo=False, safety=False
            ),
        )

    def _parse_sources(self, sources: Any, limit: int) -> list[Result]:
        """``sourcedAnswer`` sources: {name, url, favicon, snippet}."""
        out: list[Result] = []
        for item in (sources or [])[:limit]:
            if not isinstance(item, dict) or not item.get("url"):
                continue
            snippet, uncapped = truncate_snippet(
                item.get("snippet"), self._snippet_chars
            )
            result = Result(
                title=str(item.get("name") or item["url"]),
                url=str(item["url"]),
                snippet=snippet,
            )
            # Log-only, and private so it cannot reach the wire (`search.cap`).
            result._uncapped_chars = uncapped
            out.append(result)
        return out

    def _parse_results(self, results: Any, limit: int) -> list[Result]:
        """``searchResults`` items: {name, url, content, favicon, type}."""
        out: list[Result] = []
        for item in results or []:
            if not isinstance(item, dict) or not item.get("url"):
                continue
            # Image results carry no usable text for a search response.
            if item.get("type") == "image":
                continue
            snippet, uncapped = truncate_snippet(
                item.get("content"), self._snippet_chars
            )
            result = Result(
                title=str(item.get("name") or item["url"]),
                url=str(item["url"]),
                snippet=snippet,
            )
            # Log-only, and private so it cannot reach the wire (`search.cap`).
            result._uncapped_chars = uncapped
            out.append(result)
            if len(out) >= limit:
                break
        return out

    async def aclose(self) -> None:
        return None
