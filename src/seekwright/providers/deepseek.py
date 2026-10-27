"""DeepSeek Search -- in-house engine, $0.75 per 1,000 successful requests.

Billed **per successful request**: not by tokens, not by result count, and
`count` does not move the price. A request that answers 200 with an empty
`results` array is not billed at all, so `search` reports `0.0` for one -- the
figure tracks what the account paid. There is no free tier, so `cost_per_1k`
defaults to the published rate; `402` is this API's own "insufficient balance"
answer. <https://api-docs.deepseek.com/guides/search>

No filter fields exist on the request body (`query`, `count`, `ori_question`,
`localization`, `need_content` are the whole set); the documented interface is a
set of query operators -- `site:`, `-site:`, `lang:`, `after:` -- so those fold
into `query` here. `localization` takes an IP address, which is why `country` is
reported dropped rather than mapped onto something that is not a country.

`snippet` (100-200 characters, for display) and `summary` (600-800, for a model)
ride `Result.snippet` and `Result.text` under the two policy caps. `content` --
the page body, filled only when `need_content` is asked for -- is never
requested: page text is what `fetch` is for.

Untested: written against the documented API, never called live in-repo.
`config.UNTESTED_PROVIDERS` and the `--check` line say so (providers.md).
"""

from __future__ import annotations

from datetime import UTC, date, datetime, timedelta
from typing import Any

import httpx

from ..models import ProviderResult, Result, SearchQuery
from .base import (
    ProviderError,
    QuotaExhausted,
    ignored_constraints,
    truncate_snippet,
    truncate_text,
)

ENDPOINT = "https://api.deepseek.com/v1/tools/search"

# The documented `count` range is 1..50 (not a plan limit), so a hand-built
# `SearchQuery` stays inside it.
MAX_RESULTS = 50

# `query` is 1 to 128 Unicode characters, and every filter rides inside that
# string, so the limit bounds the folded query, not the typed one.
MAX_QUERY_CHARS = 128

# `after:<YYYY-MM-DD>` is the documented date form; 31/366 are the long month and
# year, so a window never misses a day.
_RECENCY_DAYS = {"day": 1, "week": 7, "month": 31, "year": 366}


def fold_operators(q: SearchQuery, today: date) -> str:
    """Compose the query with this API's operators folded in.

    Order is the operator's own example -- term, `site:`, `lang:`, `after:` --
    and a multi-site include is the `site:a OR site:b` form its docs spell out.
    Not `site_filtered_query`: that helper parenthesises a multi-site filter, and
    parentheses are not part of this backend's documented syntax.

    ``today`` is a parameter because the `after:` value is a date and the
    request-shape tests assert the whole query.
    """
    parts = [q.query]
    if q.include_domains:
        parts.append(" OR ".join(f"site:{d}" for d in q.include_domains))
    parts.extend(f"-site:{d}" for d in q.exclude_domains)
    if q.language:
        # Lowercased, not split: the schema guarantees two letters, the shape `lang:` takes.
        parts.append(f"lang:{q.language.lower()}")
    if q.recency:
        start = today - timedelta(days=_RECENCY_DAYS[q.recency])
        parts.append(f"after:{start.isoformat()}")
    return " ".join(parts)


class DeepSeekProvider:
    name = "deepseek"
    # Class level too, not just `__init__`: the protocol is structural (provider-contract.md).
    cost_per_1k: float

    def __init__(
        self,
        client: httpx.AsyncClient,
        api_key: str,
        *,
        cost_per_1k: float = 0.75,
        snippet_chars: int = 500,
        text_chars: int = 2000,
        timeout: float = 10.0,
    ) -> None:
        self._client = client
        self._api_key = api_key
        self.cost_per_1k = cost_per_1k
        self._snippet_chars = snippet_chars
        self._text_chars = text_chars
        self._timeout = timeout

    def cost_for(self, max_results: int) -> float:
        """Per-query cost in USD: one request, flat in result count.

        `count` does not affect the price; the argument is the protocol's.
        """
        return self.cost_per_1k / 1000.0

    async def search(self, q: SearchQuery) -> ProviderResult:
        if len(q.query) > MAX_QUERY_CHARS:
            # The tool surface allows 400 characters and this backend 128, so the
            # mismatch is the adapter's to name. Not retryable.
            raise ProviderError(
                self.name,
                f"query exceeds the backend's {MAX_QUERY_CHARS}-character limit",
                retryable=False,
            )

        folded = fold_operators(q, datetime.now(UTC).date())
        # Past 128 the backend refuses outright: filters come off, the bare query goes
        # out, and `notice` names each bucket dropped.
        folded_fits = len(folded) <= MAX_QUERY_CHARS
        body: dict[str, Any] = {
            "query": folded if folded_fits else q.query,
            "count": min(q.max_results, MAX_RESULTS),
        }
        # `ori_question` is unknown here, and `need_content` stays at its documented
        # default of false, so no page body is requested.

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
            # 402 is its "insufficient balance", 429 its account-level QPS breach; both
            # are terminal for one call.
            raise QuotaExhausted(self.name, "rate limited or out of account balance")
        if resp.status_code == 408:
            # Documented as the request-body read timing out, and the operator says retry.
            raise ProviderError(self.name, "upstream timed out reading the request")
        if resp.status_code >= 400:
            # The status is the whole message; the error body is never echoed.
            raise ProviderError(self.name, f"HTTP {resp.status_code}")

        try:
            data = resp.json()
        except ValueError as exc:
            raise ProviderError(self.name, "malformed JSON response") from exc
        if not isinstance(data, dict):
            # Non-object JSON is the same contracted error as unparseable:
            # provider-contract.md, "Failures".
            raise ProviderError(self.name, "malformed JSON response")

        results = self._parse(data, q.max_results)
        return ProviderResult(
            provider=self.name,
            results=results,
            # A 200 with an empty `results` array is documented as not billable.
            cost_usd=self.cost_for(q.max_results) if results else 0.0,
            # Domain, date and language ride the query operators while the folded query
            # fits; `country` and safe-search have no wire form at all.
            notice=ignored_constraints(
                q,
                domains=folded_fits,
                dates=folded_fits,
                geo=False,
                language=folded_fits or not q.language,
                safety=False,
            ),
        )

    def _parse(self, data: dict[str, Any], limit: int) -> list[Result]:
        """Extract the hits from ``results``, tolerating shape drift.

        `results` is documented as an array on every success, so a missing or
        non-list one is drift and answers empty rather than raising.
        `site_name`, `site_icon` and `authority` have no field on `Result`;
        `content` is never filled, because `need_content` is never sent.
        """
        out: list[Result] = []
        container = data.get("results")
        if not isinstance(container, list):
            return out
        for item in container[:limit]:
            if not isinstance(item, dict):
                continue
            url = item.get("url")
            title = item.get("title")
            if not url or not title:
                continue
            snippet, _ = truncate_snippet(item.get("snippet"), self._snippet_chars)
            text, truncated, uncapped = truncate_text(
                item.get("summary"), self._text_chars
            )
            date_ = item.get("date")
            score = item.get("rerank_score")
            result = Result(
                title=str(title),
                url=str(url),
                snippet=snippet,
                text=text,
                text_truncated=truncated or None,
                # RFC 3339 UTC as the operator formats it, or null.
                published_date=date_ if isinstance(date_, str) else None,
                # 0-3 rerank score, on the backend's own scale, as for every other adapter.
                score=float(score) if isinstance(score, int | float) else None,
            )
            # Log-only, and private so it cannot reach the wire (`search.cap`).
            result._uncapped_chars = uncapped
            out.append(result)
        return out

    async def aclose(self) -> None:
        # The lifespan owns the shared client (docs/reference/provider-contract.md).
        return None
