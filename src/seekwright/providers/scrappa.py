"""Scrappa -- Google-backed SERP at ~$0.30/1k, the cheapest provider in tree.

**One credit per request** on every endpoint, with no result-count multiplier,
so -- unlike Serper's doubling past 10 results -- :meth:`cost_for` is flat.

``/api/search-light`` rather than the fuller ``/api/search``: both cost one
credit, but search-light returns 20 results instead of 10, and everything
``/api/search`` adds (knowledge graph, related questions, local results) is what
:meth:`_parse` throws away anyway.
"""

from __future__ import annotations

from typing import Any

import httpx

from ..models import ProviderResult, Result, SearchQuery
from .base import (
    ProviderError,
    QuotaExhausted,
    site_filtered_query,
    truncate_snippet,
)

ENDPOINT = "https://scrappa.co/api/search-light"

# The endpoint's documented ceiling: a caller wanting more is clamped rather than
# paginated, because each page would be another credit.
MAX_NUM = 20

# Scrappa's date-restriction codes, unverified (providers.md says so): a live
# rejection means correcting this map and that entry.
_DATE_RESTRICT = {"day": "d1", "week": "w1", "month": "m1", "year": "y1"}


class ScrappaProvider:
    name = "scrappa"
    # Class level too, not just `__init__`: the protocol is structural (provider-contract.md).
    cost_per_1k: float

    def __init__(
        self,
        client: httpx.AsyncClient,
        api_key: str,
        *,
        cost_per_1k: float = 0.30,
        snippet_chars: int = 500,
        timeout: float = 15.0,
    ) -> None:
        self._client = client
        self._api_key = api_key
        self.cost_per_1k = cost_per_1k
        self._snippet_chars = snippet_chars
        self._timeout = timeout

    def cost_for(self, _max_results: int) -> float:
        """Per-query cost in USD. Flat: one credit, whatever ``num`` says.

        The argument is ignored rather than absent because callers treat
        ``cost_for`` as duck-typed; another provider scales with it.
        """
        return self.cost_per_1k / 1000.0

    async def search(self, q: SearchQuery) -> ProviderResult:
        params: dict[str, Any] = {
            "query": site_filtered_query(q),
            "num": min(q.max_results, MAX_NUM),
        }
        if q.country:
            params["gl"] = q.country
        if q.language:
            # Lowercased, not split: the schema guarantees two letters, so no region half.
            params["hl"] = q.language.lower()
        if q.recency:
            params["dateRestrict"] = _DATE_RESTRICT[q.recency]
        if q.safe_search is not None:
            # Sent only when the caller asked: `None` leaves the backend's default in
            # place, which is not the same thing as asking for no filter.
            params["safe"] = "active" if q.safe_search else "off"

        try:
            resp = await self._client.get(
                ENDPOINT,
                params=params,
                headers={"x-api-key": self._api_key},
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
        # 402 is Scrappa's x402 payment challenge -- for a keyed client, credits ran
        # out; 429 is presumed rate limiting, since the limits are undocumented.
        if resp.status_code in (402, 429):
            raise QuotaExhausted(self.name, "rate limited or out of credits")
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

        # No notice: Google's index behind it honours every bucket.
        return ProviderResult(
            provider=self.name,
            results=self._parse(data, q.max_results),
            cost_usd=self.cost_for(q.max_results),
        )

    def _parse(self, data: dict[str, Any], limit: int) -> list[Result]:
        """Extract organic hits, tolerating shape drift in the rich elements.

        Only ``organic_results`` is read. No ``published_date``: search-light does
        not report one, and inventing it from the snippet would be a guess.
        """
        out: list[Result] = []
        for item in (data.get("organic_results") or [])[:limit]:
            if not isinstance(item, dict):
                continue
            url = item.get("link")
            title = item.get("title")
            if not url or not title:
                continue
            snippet, uncapped = truncate_snippet(
                item.get("snippet"), self._snippet_chars
            )
            result = Result(title=str(title), url=str(url), snippet=snippet)
            # Log-only, and private so it cannot reach the wire (`search.cap`).
            result._uncapped_chars = uncapped
            out.append(result)
        return out

    async def aclose(self) -> None:
        # The lifespan owns the shared client (docs/reference/provider-contract.md).
        return None
