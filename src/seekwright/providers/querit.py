"""Querit — real-time SERP, 1,000 free calls/month, then $4/1k PAYG.

Cost note: the free plan is **1,000 calls/month with no payment method
required**, so ``cost_per_1k`` defaults to ``0.0`` — the plan an install most
often runs on. The PAYG tier bills $4/1,000 requests (10 QPS) and an operator
on it corrects the figure in config; nothing routes on it. The
``/v1/contents`` endpoint (+$1/1,000 pages) is deliberately not part of this
adapter: a SERP backend fills ``snippet``, never ``text``, and ``fetch`` has its
own extraction backends.

The free plan answers at most **10 results**, so ``count`` is clamped whatever
``max_results`` asks; fewer hits than asked is a shorter answer, not a dropped
constraint — the reading ``serpapi`` gives its result count.

Untested status: no live verification against the real endpoint has happened
in-repo, so ``config.UNTESTED_PROVIDERS`` and the ``--check`` line say so while
it stays in that set (providers.md). The API is the operator's documented one
(docs.querit.ai).
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

ENDPOINT = "https://api.querit.ai/v1/search"

# The free plan's documented result cap: a `count` above it is asked of a plan that
# cannot give it, so the adapter clamps and the answer is simply a shorter one.
MAX_RESULTS = 10

# `filters.timeRange.date` takes d[n]/w[n]/m[n]/y[n]; each coarse fallback of `recency`
# maps onto its own unit's one-step form.
_RECENCY = {"day": "d1", "week": "w1", "month": "m1", "year": "y1"}

# `filters.languages.include` is a strict eight-name enum while `language` is an ISO
# 639-1 code: the map is the bridge, and a code with no entry is dropped, never sent.
_LANGUAGE_NAMES = {
    "en": "english",
    "ja": "japanese",
    "ko": "korean",
    "de": "german",
    "fr": "french",
    "es": "spanish",
    "pt": "portuguese",
    "ru": "russian",
}

# `filters.geo.countries.include` is a strict seventeen-name enum: the same bridge.
_COUNTRY_NAMES = {
    "ar": "argentina",
    "au": "australia",
    "br": "brazil",
    "ca": "canada",
    "co": "colombia",
    "de": "germany",
    "fr": "france",
    "in": "india",
    "id": "indonesia",
    "jp": "japan",
    "kr": "south korea",
    "mx": "mexico",
    "ng": "nigeria",
    "ph": "philippines",
    "es": "spain",
    "gb": "united kingdom",
    "us": "united states",
}


class QueritProvider:
    name = "querit"
    # Class level, not just `__init__`: the protocol is structural (docs/reference/provider-contract.md).
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
        """Per-query cost in USD: one call per search, flat."""
        return self.cost_per_1k / 1000.0

    async def search(self, q: SearchQuery) -> ProviderResult:
        # Clamped to the free plan's documented cap: the request never asks a plan for more.
        body: dict[str, Any] = {
            "query": q.query,
            "count": min(q.max_results, MAX_RESULTS),
        }
        filters: dict[str, Any] = {}
        sites: dict[str, list[str]] = {}
        if q.include_domains:
            sites["include"] = q.include_domains
        if q.exclude_domains:
            sites["exclude"] = q.exclude_domains
        if sites:
            filters["sites"] = sites
        if q.recency:
            filters["timeRange"] = {"date": _RECENCY[q.recency]}
        country = _COUNTRY_NAMES.get(q.country or "")
        if country:
            filters["geo"] = {"countries": {"include": [country]}}
        language = _LANGUAGE_NAMES.get((q.language or "").lower())
        if language:
            filters["languages"] = {"include": [language]}
        if filters:
            body["filters"] = filters

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
            # 429 is the documented 1 QPS free limit, and an exhausted monthly allowance
            # answers the same code for a keyed client.
            raise QuotaExhausted(self.name, "rate limited or out of monthly calls")
        if resp.status_code >= 400:
            raise ProviderError(self.name, f"HTTP {resp.status_code}")

        try:
            data = resp.json()
        except ValueError as exc:
            raise ProviderError(self.name, "malformed JSON response") from exc
        if not isinstance(data, dict):
            # A JSON body that is not an object is the same contracted error as an
            # unparseable one: docs/reference/provider-contract.md, "Failures".
            raise ProviderError(self.name, "malformed JSON response")

        # Domains, dates and the mappable halves of country and language ride native fields;
        # an enum value the backend cannot express is noticed, not sent. No safe-search.
        return ProviderResult(
            provider=self.name,
            results=self._parse(data, q.max_results),
            cost_usd=self.cost_for(q.max_results),
            notice=ignored_constraints(
                q,
                domains=True,
                dates=True,
                geo=country is not None or not q.country,
                language=language is not None or not q.language,
                safety=False,
            ),
        )

    def _parse(self, data: dict[str, Any], limit: int) -> list[Result]:
        """Extract ranked hits, tolerating shape drift in the records.

        A SERP backend: ``snippet`` filled, never ``text``. ``sentence`` (body
        text) arrives only behind ``needContent: true`` and ``highlights`` behind
        its request field; this adapter sends neither, so neither is read.
        """
        out: list[Result] = []
        # `results` is an object and the hits live under its `result` key: the wire's shape.
        results = data.get("results")
        if not isinstance(results, dict):
            return out
        for item in (results.get("result") or [])[:limit]:
            if not isinstance(item, dict):
                continue
            url = item.get("url")
            title = item.get("title")
            if not url or not title:
                continue
            date = item.get("page_age")
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
