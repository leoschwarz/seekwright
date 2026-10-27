"""Algolia -- a keyed, index-scoped SERP-shaped backend over records you own.

Billed **per search request**, whatever it returns. Free is 10K requests a
month; Grow includes 10K then $0.50/1K, Grow Plus $1.75/1K. ``cost_per_1k``
therefore defaults to 0.50 (the cheapest paid rate) and ``cost_for`` ignores its
argument. It is reporting-only anyway; an operator on Grow Plus sets it to 1.75.

The Search API at ``{app_id}-dsn.algolia.net`` is the only surface that returns
the operator's own records, and the provider is index-scoped by nature -- one
index, not the web. ``app_id`` and ``index`` are config (the host is
per-deployment, the ``searxng`` precedent); the search API key is the credential.

One name, not an ``algolia_free``/``algolia`` split: the key is mandatory on
**every** tier, so the credential never decides the price -- the plan does.
That is the opposite of ``exa``/``exa:free`` and ``parallel``/``parallel:free``.
"""

from __future__ import annotations

from typing import Any
from urllib.parse import quote

import httpx

from ..models import ProviderResult, Result, SearchQuery
from .base import (
    ProviderError,
    QuotaExhausted,
    ignored_constraints,
    truncate_snippet,
)


def _first_str(record: dict[str, Any], attrs: tuple[str, ...]) -> str | None:
    """First attribute holding a plain scalar, coerced to str.

    Records are schemaless JSON, so a wrong type counts as absent and the chain
    continues instead of failing the whole hit.
    """
    for attr in attrs:
        value = record.get(attr)
        if isinstance(value, str | int | float) and not isinstance(value, bool):
            return str(value)
    return None


def _hierarchy_title(record: dict[str, Any]) -> str | None:
    """DocSearch-shaped records keep their title in `hierarchy.lvl0`..`lvl6`.

    The most specific non-empty level is the displayed title, as DocSearch's own
    frontend renders these records.
    """
    hierarchy = record.get("hierarchy")
    if not isinstance(hierarchy, dict):
        return None
    for level in range(6, -1, -1):
        value = hierarchy.get(f"lvl{level}")
        if isinstance(value, str) and value:
            return value
    return None


class AlgoliaProvider:
    name = "algolia"
    # Class level too, not just `__init__`: the protocol is structural (provider-contract.md).
    cost_per_1k: float

    def __init__(
        self,
        client: httpx.AsyncClient,
        api_key: str,
        *,
        app_id: str,
        index: str,
        cost_per_1k: float = 0.50,
        snippet_chars: int = 500,
        timeout: float = 10.0,
        title_attr: str | None = None,
        url_attr: str | None = None,
        snippet_attr: str | None = None,
    ) -> None:
        self._client = client
        self._api_key = api_key
        self._app_id = app_id
        # The index name rides the path, so it is percent-encoded; the app ID is host config.
        self._endpoint = (
            f"https://{app_id}-dsn.algolia.net"
            f"/1/indexes/{quote(index, safe='')}/query"
        )
        self.cost_per_1k = cost_per_1k
        self._snippet_chars = snippet_chars
        self._timeout = timeout
        self._title_attr = title_attr
        self._url_attr = url_attr
        self._snippet_attr = snippet_attr

    def cost_for(self, _max_results: int) -> float:
        """Flat: Algolia bills per search request whatever it returns.

        The argument is ignored rather than absent because callers treat
        ``cost_for`` as duck-typed; another provider scales with it.
        """
        return self.cost_per_1k / 1000.0

    async def search(self, q: SearchQuery) -> ProviderResult:
        body: dict[str, Any] = {"query": q.query, "hitsPerPage": q.max_results}
        try:
            resp = await self._client.post(
                self._endpoint,
                json=body,
                headers={
                    "x-algolia-application-id": self._app_id,
                    "x-algolia-api-key": self._api_key,
                    "Content-Type": "application/json",
                },
                timeout=self._timeout,
            )
        except httpx.TimeoutException as exc:
            raise ProviderError(self.name, "request timed out") from exc
        except httpx.HTTPError as exc:
            # Redaction rule: docs/reference/provider-contract.md, "Failures".
            raise ProviderError(self.name, "network error") from exc

        # 403, not 401, is Algolia's answer for an invalid Application-ID or key.
        if resp.status_code in (401, 403):
            raise ProviderError(
                self.name, "authentication rejected (check API key)", retryable=False
            )
        # 402 is Algolia's `FeatureNotEnabled`: a plan question, like the 429 rate limit.
        if resp.status_code in (402, 429):
            raise QuotaExhausted(self.name)
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
            # No filter field in this API; the record schema is the operator's.
            notice=ignored_constraints(
                q, domains=False, dates=False, geo=False, safety=False
            ),
        )

    def _parse(self, data: dict[str, Any], limit: int) -> list[Result]:
        """``hits[]``: schemaless records mapped onto title/url/snippet.

        An explicitly configured ``*_attr`` is used alone (no chain, no
        hierarchy fallback); otherwise the common-name chains below apply.
        """
        out: list[Result] = []
        for record in (data.get("hits") or [])[:limit]:
            if not isinstance(record, dict):
                continue
            if self._title_attr is not None:
                title = _first_str(record, (self._title_attr,))
            else:
                title = _first_str(record, ("title", "name", "question"))
                if title is None:
                    title = _hierarchy_title(record)
            if self._url_attr is not None:
                url = _first_str(record, (self._url_attr,))
            else:
                url = _first_str(record, ("url", "link"))
            if not title or not url:
                continue
            if self._snippet_attr is not None:
                snippet = _first_str(record, (self._snippet_attr,))
            else:
                snippet = _first_str(
                    record,
                    ("description", "summary", "excerpt", "content", "answer"),
                )
            snippet, uncapped = truncate_snippet(snippet, self._snippet_chars)
            result = Result(title=title, url=url, snippet=snippet)
            # Log-only, and private so it cannot reach the wire (`search.cap`).
            result._uncapped_chars = uncapped
            out.append(result)
        return out

    async def aclose(self) -> None:
        # The lifespan owns the shared client (docs/reference/provider-contract.md).
        return None
