"""FreeSerp -- a keyless, whole-web SERP index: the first free name backed by one.

Cost note: FreeSerp cannot bill ("no key, no signup"), so ``cost_per_1k`` is 0.0
and ``cost_for`` is flat -- which is why it is in ``FREE_PROVIDERS`` and the
install default: nothing to configure. Both other keyless names are the
anonymous halves of *paid* endpoints; this index is the operator's own.

Endpoint: ``GET https://freeserp.ai/api.php?index=web``, a JSON API over a
whole-web crawl. The default index (``index=sites``) is a site-discovery index,
never requested here.

``engine_fallback: true`` is a refusal, not a caveat: when their web engine does
not answer, ``index=web`` is served site profiles the wire shape cannot carry, so
the fallback fails and the walk moves on. The key is **absent** on a healthy
response, so only its present-and-true form fails.

Constraints: no domain parameter, no ``site:`` operator, no country and no
safe-search, so those are named in ``notice``. ``language`` reaches ``lang`` and
``recency`` ``published_from``; ``published_to`` stays unexposed for the reason
``linkup`` leaves its ``toDate`` alone.

``total`` is not mapped: it is the size of a top-100 candidate pool (the
response says so in ``total_note``), not a hit count.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import Any

import httpx

from .. import PROJECT_URL
from ..models import ProviderResult, Result, SearchQuery
from .base import (
    ProviderError,
    QuotaExhausted,
    ignored_constraints,
    truncate_snippet,
)

ENDPOINT = "https://freeserp.ai/api.php"

# What the operator asks a caller to send so its traffic is attributable. Not config:
# nothing upstream validates either value, so there is nothing for an operator to set.
AGENT = "seekwright"

# `size` is 1-100 and `from + size <= 100`. The tool schema caps `max_results` at 20, but
# the adapter is callable directly, so the clamp lives here rather than being assumed.
MAX_SIZE = 100

# Coarse freshness -> how far back `published_from` reaches, with fixed day multipliers
# like Linkup's `fromDate`: recency is "published within the last ...", not calendar math.
_AGE_DAYS = {"day": 1, "week": 7, "month": 30, "year": 365}


def _date(item: dict[str, Any]) -> str | None:
    """``published_at``, falling back to ``crawled_at``.

    The declared date is missing for many pages, and the crawl date is the honest
    stand-in: when the index last saw the page, not when it was written. Neither
    is invented when both are absent.
    """
    for key in ("published_at", "crawled_at"):
        value = item.get(key)
        if isinstance(value, str) and value:
            return value
    return None


def _score(value: Any) -> float | None:
    """The operator's BM25 x trust number, passed through as-is.

    Nothing downstream compares scores across providers, so there is nothing to
    rescale. A non-number is dropped rather than coerced: ``Result.score`` is a
    float, and a string pydantic cannot coerce would raise out of the model.
    """
    if isinstance(value, bool) or not isinstance(value, int | float):
        return None
    return float(value)


class FreeserpProvider:
    name = "freeserp"
    # Class level, not just `__init__`: the protocol is structural (docs/reference/provider-contract.md).
    cost_per_1k: float

    def __init__(
        self,
        client: httpx.AsyncClient,
        *,
        cost_per_1k: float = 0.0,
        snippet_chars: int = 500,
        timeout: float = 10.0,
    ) -> None:
        self._client = client
        self.cost_per_1k = cost_per_1k
        self._snippet_chars = snippet_chars
        self._timeout = timeout

    def cost_for(self, _max_results: int) -> float:
        """Per-query cost in USD. Flat zero: there is nothing to bill.

        The argument is ignored rather than absent because callers treat
        ``cost_for`` as a duck-typed method (``cli._live_probe``) and other
        adapters do scale with it.
        """
        return self.cost_per_1k / 1000.0

    async def search(self, q: SearchQuery) -> ProviderResult:
        params: dict[str, Any] = {
            "index": "web",
            "q": q.query,
            "size": min(max(q.max_results, 1), MAX_SIZE),
            "agent": AGENT,
            "website": PROJECT_URL,
        }
        if q.language:
            # Lowercased, not split: `lang` is an ISO 639-1 code, and the region belongs
            # to a `country` parameter this backend does not have.
            params["lang"] = q.language.lower()
        if q.recency:
            params["published_from"] = (
                datetime.now(UTC) - timedelta(days=_AGE_DAYS[q.recency])
            ).strftime("%Y-%m-%d")

        try:
            resp = await self._client.get(
                ENDPOINT, params=params, timeout=self._timeout
            )
        except httpx.TimeoutException as exc:
            raise ProviderError(self.name, "request timed out") from exc
        except httpx.HTTPError as exc:
            # Redaction rule (provider-contract.md, "Failures"): no key here, but it
            # names this deployment.
            raise ProviderError(self.name, "network error") from exc

        # Keyless today; the mapping is the contract's table, ready for a future key.
        if resp.status_code in (401, 403):
            raise ProviderError(
                self.name, "authentication rejected (check API key)", retryable=False
            )
        if resp.status_code in (402, 429):
            raise QuotaExhausted(self.name)
        if resp.status_code >= 400:
            # 502 is the documented upstream failure and the transient one of the pair.
            raise ProviderError(self.name, f"HTTP {resp.status_code}")

        try:
            data = resp.json()
        except ValueError as exc:
            raise ProviderError(self.name, "malformed JSON response") from exc
        if not isinstance(data, dict):
            # A non-object JSON body is the same contracted error (provider-contract.md, "Failures").
            raise ProviderError(self.name, "malformed JSON response")

        if data.get("engine_fallback") is True:
            # Their web engine did not answer and the sites index replied: site profiles are
            # not search results, and the wire shape cannot carry the substitution.
            raise ProviderError(self.name, "upstream index unavailable")

        return ProviderResult(
            provider=self.name,
            results=self._parse(data, q.max_results),
            cost_usd=self.cost_for(q.max_results),
            # No domain field, no `site:` operator, no country parameter and no safe-search
            # parameter; `published_from` and `lang` are honoured, so geo splits in the notice.
            notice=ignored_constraints(
                q, domains=False, dates=True, geo=False, language=True, safety=False
            ),
        )

    def _parse(self, data: dict[str, Any], limit: int) -> list[Result]:
        """``results[]``: {url, domain, title, snippet, published_at, ...}.

        A SERP backend, so `snippet` is filled and `text` never is. Records
        missing a title or URL are dropped, and a field of the wrong type counts
        as absent rather than failing the hit.
        """
        out: list[Result] = []
        for item in (data.get("results") or [])[:limit]:
            if not isinstance(item, dict):
                continue
            url = item.get("url")
            title = item.get("title")
            if not isinstance(url, str) or not url:
                continue
            if not isinstance(title, str) or not title:
                continue
            snippet, uncapped = truncate_snippet(
                item.get("snippet"), self._snippet_chars
            )
            result = Result(
                title=title,
                url=url,
                snippet=snippet,
                published_date=_date(item),
                score=_score(item.get("score")),
            )
            # Log-only, and private so it cannot reach the wire (`search.cap`).
            result._uncapped_chars = uncapped
            out.append(result)
        return out

    async def aclose(self) -> None:
        # The lifespan owns the shared client (docs/reference/provider-contract.md).
        return None
