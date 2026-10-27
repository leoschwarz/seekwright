"""TinyFish -- a keyed aggregator whose search API is free at any balance.

TinyFish bills agent/browser work, not search: a Search API request is free
whatever the balance, so ``cost_per_1k`` is 0.0 and ``cost_for`` is flat. The
account does need Search API *access* -- a key without it answers 402, which
lands in the quota class like Scrappa's x402.

The one HTTP adapter that honours every constraint natively -- domain lists, a
freshness window and geo all have request parameters -- so a fully-constrained
query draws no `notice` at all.
"""

from __future__ import annotations

from typing import Any

import httpx

from ..models import ProviderResult, Result, SearchQuery
from .base import ProviderError, QuotaExhausted, ignored_constraints, truncate_snippet

ENDPOINT = "https://api.search.tinyfish.ai"

# recency -> `recency_minutes` (documented 1 to 5256000), with fixed 30-day months
# and 365-day years: coarse freshness, not calendar arithmetic.
_RECENCY_MINUTES = {"day": 1440, "week": 10080, "month": 43200, "year": 525600}


class TinyfishProvider:
    name = "tinyfish"
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

    def cost_for(self, _max_results: int) -> float:
        """Per-query cost in USD. Flat zero: search never draws from the wallet.

        The argument is ignored rather than absent because callers treat
        ``cost_for`` as duck-typed; another provider scales with it.
        """
        return self.cost_per_1k / 1000.0

    async def search(self, q: SearchQuery) -> ProviderResult:
        # The query goes verbatim: the docs prefer the dedicated domain parameters.
        params: dict[str, Any] = {"query": q.query}
        if q.include_domains:
            params["include_domains"] = ",".join(q.include_domains)
        if q.exclude_domains:
            params["exclude_domains"] = ",".join(q.exclude_domains)
        if q.recency:
            params["recency_minutes"] = _RECENCY_MINUTES[q.recency]
        if q.country:
            # Documented examples are uppercase country codes (`US`, `DE`).
            params["location"] = q.country.upper()
        if q.language:
            # Lowercased: the schema already guarantees the two-letter form.
            params["language"] = q.language.lower()

        try:
            resp = await self._client.get(
                ENDPOINT,
                params=params,
                headers={"X-API-Key": self._api_key},
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
        # 402 reads "Search API access is required for your account" -- an account
        # question, not a malformed request; 429 is the rate limit.
        if resp.status_code in (402, 429):
            raise QuotaExhausted(
                self.name, "rate limited or no Search API access on this account"
            )
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

        return ProviderResult(
            provider=self.name,
            results=self._parse(data, q.max_results),
            cost_usd=self.cost_for(q.max_results),
            # Native domains, freshness, geo and language parameters; there is no
            # safe-search parameter, so that drop is the whole of the notice.
            notice=ignored_constraints(
                q, domains=True, dates=True, geo=True, safety=False
            ),
        )

    def _parse(self, data: dict[str, Any], limit: int) -> list[Result]:
        """``results[]``: {position, site_name, title, snippet, url, date}.

        No result-count parameter upstream, so the slice here is the only place
        `max_results` takes effect.
        """
        out: list[Result] = []
        for item in (data.get("results") or [])[:limit]:
            if not isinstance(item, dict):
                continue
            url = item.get("url")
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
