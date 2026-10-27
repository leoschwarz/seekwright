"""Serper.dev -- cheap raw SERP (links + snippets), ~$1/1k.

**2 credits** for more than 10 results, so ``max_results > 10`` costs double.
:meth:`cost_for` reflects that, so the figure ``--check --live`` reports is the
one actually billed.
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

ENDPOINT = "https://google.serper.dev/search"

# Google's standard time-restriction codes, applied through `tbs`; verified on the
# first live call (docs/reference/providers.md).
_TBS = {"day": "qdr:d", "week": "qdr:w", "month": "qdr:m", "year": "qdr:y"}


class SerperProvider:
    name = "serper"
    # Class level too, not just `__init__`: the protocol is structural (provider-contract.md).
    cost_per_1k: float

    def __init__(
        self,
        client: httpx.AsyncClient,
        api_key: str,
        *,
        cost_per_1k: float = 1.00,
        snippet_chars: int = 500,
        timeout: float = 10.0,
    ) -> None:
        self._client = client
        self._api_key = api_key
        self.cost_per_1k = cost_per_1k
        self._snippet_chars = snippet_chars
        self._timeout = timeout

    def cost_for(self, max_results: int) -> float:
        """Per-query cost in USD, accounting for the >10-results credit doubling."""
        credits = 2 if max_results > 10 else 1
        return (self.cost_per_1k / 1000.0) * credits

    async def search(self, q: SearchQuery) -> ProviderResult:
        body: dict[str, Any] = {"q": site_filtered_query(q), "num": q.max_results}
        if q.country:
            body["gl"] = q.country
        if q.language:
            # Lowercased, not split: the schema guarantees two letters.
            body["hl"] = q.language.lower()
        if q.recency:
            body["tbs"] = _TBS[q.recency]

        try:
            resp = await self._client.post(
                ENDPOINT,
                json=body,
                headers={
                    "X-API-KEY": self._api_key,
                    "Content-Type": "application/json",
                },
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
        # Serper bills by credit pack, so a spent balance must reach the quota fallback:
        # 402 joins 429, though no vendor page says which status a spent key gives.
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

        # `site:` emulation plus native gl/hl honour three buckets; the missing
        # safe-search parameter is the only drop this adapter can report.
        return ProviderResult(
            provider=self.name,
            results=self._parse(data, q.max_results),
            cost_usd=self.cost_for(q.max_results),
            notice=ignored_constraints(q, domains=True, dates=True, geo=True, safety=False),
        )

    def _parse(self, data: dict[str, Any], limit: int) -> list[Result]:
        """Extract organic hits, tolerating shape drift in the rich elements.

        Only ``organic`` is read; knowledge panels, "people also ask" and the
        other element families are dropped rather than modelled.
        """
        out: list[Result] = []
        for item in (data.get("organic") or [])[:limit]:
            if not isinstance(item, dict):
                continue
            url = item.get("link")
            title = item.get("title")
            if not url or not title:
                continue
            date = item.get("date")
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
