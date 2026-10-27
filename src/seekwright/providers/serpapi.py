"""SerpAPI — Google SERP behind one account key, 1 search per call.

The free plan is **250 searches/month at $0** (50/hour, no card), so
``cost_per_1k`` defaults to ``0.0`` — the plan an install most often runs on. A
paid plan bills per search (pricing page, in ``docs/reference/providers.md``);
an operator on one corrects the figure in config, and nothing routes on it. Only
successful searches count, so the parameter-less connectivity probe is free.

Redaction: the API key rides **in the query string** — the operator's documented
shape, diverging from this tree's header convention. That makes the request URL
a secret surface: httpx errors can echo the URL they were built from, so no
exception or body is interpolated into a message here.
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

ENDPOINT = "https://serpapi.com/search"

# Google's standard time-restriction codes, applied via the `tbs` parameter SerpAPI
# forwards to the index -- the same shape `serper` uses.
_TBS = {"day": "qdr:d", "week": "qdr:w", "month": "qdr:m", "year": "qdr:y"}


class SerpApiProvider:
    name = "serpapi"
    # Class level too, not just `__init__`: the protocol is structural (provider-contract.md).
    cost_per_1k: float

    def __init__(
        self,
        client: httpx.AsyncClient,
        api_key: str,
        *,
        cost_per_1k: float = 0.0,
        snippet_chars: int = 500,
        timeout: float = 10.0,
    ) -> None:
        self._client = client
        self._api_key = api_key
        self.cost_per_1k = cost_per_1k
        self._snippet_chars = snippet_chars
        self._timeout = timeout

    def cost_for(self, max_results: int) -> float:
        """Per-query cost in USD: one search per call, flat."""
        return self.cost_per_1k / 1000.0

    async def search(self, q: SearchQuery) -> ProviderResult:
        params: dict[str, Any] = {
            # The documented shape: the key rides in the query string (see the
            # redaction note above).
            "api_key": self._api_key,
            "q": site_filtered_query(q),
            "engine": "google",
        }
        if q.country:
            params["gl"] = q.country
        if q.language:
            # Lowercased, not split: the schema guarantees two letters.
            params["hl"] = q.language.lower()
        if q.recency:
            params["tbs"] = _TBS[q.recency]
        if q.safe_search is not None:
            params["safe"] = "active" if q.safe_search else "off"

        try:
            resp = await self._client.get(
                ENDPOINT, params=params, timeout=self._timeout
            )
        except httpx.TimeoutException as exc:
            raise ProviderError(self.name, "request timed out") from exc
        except httpx.HTTPError as exc:
            # Redaction rule: docs/reference/provider-contract.md, "Failures" --
            # here the key rides in the request URL, not a header.
            raise ProviderError(self.name, "network error") from exc

        if resp.status_code in (401, 403):
            raise ProviderError(
                self.name, "authentication rejected (check API key)", retryable=False
            )
        if resp.status_code in (402, 429):
            # 429 is documented as the hourly throughput limit, or an exhausted account.
            raise QuotaExhausted(self.name, "rate limited or out of searches")
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

        # Every bucket rides a documented parameter -- `site:` operators, `gl`, `hl`,
        # `tbs`, `safe` -- so nothing is dropped and the notice stays `None`.
        return ProviderResult(
            provider=self.name,
            results=self._parse(data, q.max_results),
            cost_usd=self.cost_for(q.max_results),
            notice=ignored_constraints(
                q, domains=True, dates=True, geo=True, language=True, safety=True
            ),
        )

    def _parse(self, data: dict[str, Any], limit: int) -> list[Result]:
        """Extract ranked organic hits, tolerating shape drift in the records.

        A SERP backend: ``snippet`` filled, never ``text``. The other element
        families (``answer_box``, ``knowledge_graph``, ``related_questions``,
        ...) are dropped rather than modelled, as ``serper`` reads only
        ``organic``. ``date`` is a display string ("5 days ago"), kept when it is
        a string and dropped otherwise.
        """
        out: list[Result] = []
        for item in (data.get("organic_results") or [])[:limit]:
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
