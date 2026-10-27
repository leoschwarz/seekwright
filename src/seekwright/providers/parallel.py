"""Parallel Web Systems' Search API, as two names: ``parallel`` and
``parallel:free``.

The REST Search API is keyed and billed **per request by mode**; the hosted
Search MCP answers the same query **free anonymously**. So, as with Exa, the
credential decides the price and gets a name: :class:`ParallelProvider` is the
billed REST fallback, :class:`ParallelMcpProvider` the anonymous MCP one. There
is no free-first ladder across them -- ``[search] fallback`` already gives the
default route its failover, and a name the caller picks stays terminal.

``/v1`` rather than ``/v1beta``: beta was the pre-release spelling.

A **content** backend -- page excerpts arrive inline -- so :func:`parse_results`
fills ``Result.text`` and never ``snippet``; both would ship the same prose
twice. Both fallbacks share it, because both return the same JSON shape
(verified live: the MCP tool returns the REST payload both as
``structuredContent`` and as pretty-printed JSON in a ``TextContent`` block).
"""

from __future__ import annotations

import json
from datetime import UTC, datetime, timedelta
from typing import Any, override

import httpx

from ..models import ProviderResult, Result, SearchQuery
from .base import ProviderError, QuotaExhausted, truncate_text
from .exa_mcp import ExaMcpProvider

ENDPOINT = "https://api.parallel.ai/v1/search"
DEFAULT_MCP_URL = "https://search.parallel.ai/mcp"

# recency -> how far back `source_policy.after_date` reaches, with fixed 30-day months
# and 365-day years: coarse freshness, not calendar arithmetic.
_RECENCY_DAYS = {"day": 1, "week": 7, "month": 30, "year": 365}


def parse_results(data: Any, limit: int, text_chars: int) -> list[Result]:
    """Map Parallel's ``results[]`` onto :class:`Result`, for either fallback.

    ``data`` is whatever the wire held -- ``resp.json()`` on REST, ``json.loads``
    of the MCP text on the free half -- so the type is ``Any`` and the shape is
    checked rather than assumed.

    Reads only ``url``, ``title``, ``publish_date`` and ``excerpts``. A record
    with no URL is dropped; a null ``title`` falls back to the URL. Dates pass
    through verbatim or stay empty -- silence is not an invitation to guess. The
    excerpts join into ``text``, capped by ``text_chars``.
    """
    if not isinstance(data, dict):
        return []  # a JSON array or scalar is not a result set
    out: list[Result] = []
    for item in (data.get("results") or [])[:limit]:
        if not isinstance(item, dict):
            continue
        url = item.get("url")
        if not url:
            continue
        excerpts = [
            e for e in (item.get("excerpts") or []) if isinstance(e, str) and e
        ]
        text, truncated, uncapped = truncate_text("\n\n".join(excerpts), text_chars)
        result = Result(
            title=str(item.get("title") or url),
            url=str(url),
            text=text,
            text_truncated=truncated or None,
            published_date=item.get("publish_date") or None,
        )
        # Log-only, and private so it cannot reach the wire (`search.cap`).
        result._uncapped_chars = uncapped
        out.append(result)
    return out


class ParallelProvider:
    """Parallel's billed REST Search API, on one key."""

    name = "parallel"
    # Class level too, not just `__init__`: the protocol is structural (provider-contract.md).
    cost_per_1k: float

    def __init__(
        self,
        client: httpx.AsyncClient,
        api_key: str,
        *,
        cost_per_1k: float = 1.00,
        text_chars: int,
        mode: str = "fast",
        timeout: float,
    ) -> None:
        self._client = client
        self._api_key = api_key
        self.cost_per_1k = cost_per_1k
        # A content backend: page text arrives inline, so the text cap bounds the cost.
        self._text_chars = text_chars
        self._mode = mode
        self._timeout = timeout

    def cost_for(self, _max_results: int) -> float:
        """Per-query cost in USD. Flat: billed per request by ``mode``.

        ``cost_per_1k`` tracks ``mode`` -- 1.00 for ``turbo``/``fast``, 5.00 for
        ``basic``/``advanced`` -- so pinning a dearer mode wants the matching
        ``[providers.parallel] cost_per_1k``. The argument is ignored rather than
        absent because callers treat ``cost_for`` as duck-typed.
        """
        return self.cost_per_1k / 1000.0

    async def search(self, q: SearchQuery) -> ProviderResult:
        # Domain filters have a native field, so the query goes verbatim.
        advanced: dict[str, Any] = {"max_results": q.max_results}
        source_policy: dict[str, Any] = {}
        if q.include_domains:
            source_policy["include_domains"] = q.include_domains
        if q.exclude_domains:
            # Sent even alongside include_domains, where Parallel ignores it: the
            # notice says so, and the request stays an honest description.
            source_policy["exclude_domains"] = q.exclude_domains
        if q.recency:
            source_policy["after_date"] = (
                datetime.now(UTC) - timedelta(days=_RECENCY_DAYS[q.recency])
            ).date().isoformat()
        if source_policy:
            advanced["source_policy"] = source_policy
        if q.country:
            # ISO 3166-1 alpha-2, and it lives under advanced_settings.
            advanced["location"] = q.country

        body: dict[str, Any] = {
            "search_queries": [q.query],
            "mode": self._mode,
            "advanced_settings": advanced,
        }

        try:
            resp = await self._client.post(
                ENDPOINT,
                json=body,
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
        if resp.status_code in (402, 429):
            raise QuotaExhausted(self.name, "rate limited or out of credits")
        if resp.status_code >= 400:
            raise ProviderError(self.name, f"HTTP {resp.status_code}")

        try:
            data = resp.json()
        except ValueError as exc:
            raise ProviderError(self.name, "malformed JSON response") from exc

        # Hand-composed rather than `ignored_constraints`: the exclude-while-include
        # rule is finer than any bucket. Country rides `location`, so no `geo` token.
        parts: list[str] = []
        if q.include_domains and q.exclude_domains:
            parts.append(
                "parallel ignores exclude_domains while include_domains is set; "
                "that constraint was ignored"
            )
        if q.language:
            parts.append("cannot filter by language; that constraint was ignored")
        if q.safe_search is not None:
            parts.append("cannot filter by safe-search; that constraint was ignored")
        warnings = data.get("warnings") if isinstance(data, dict) else None
        if warnings:
            messages = [
                str(w.get("message"))
                for w in warnings
                if isinstance(w, dict) and w.get("message")
            ]
            if messages:
                parts.append("upstream warnings: " + "; ".join(messages))

        return ProviderResult(
            provider=self.name,
            results=parse_results(data, q.max_results, self._text_chars),
            cost_usd=self.cost_for(q.max_results),
            notice="; ".join(parts) or None,
        )

    async def aclose(self) -> None:
        # The lifespan owns the shared client (docs/reference/provider-contract.md).
        return None


class ParallelMcpProvider(ExaMcpProvider):
    """Parallel's hosted Search MCP, reached anonymously and priced at zero.

    The same endpoint answers a keyed session too, but a key here would only bill
    what the anonymous call does for free; ``parallel`` is the REST adapter, where
    the filter surface lives. Its tool surface takes no filter arguments at all,
    so it honours no constraint and says so in ``notice`` via the inherited
    ``ignored_constraints`` call.

    The session lifecycle (owner-task handshake, retry-once, ``warmup``,
    ``aclose``) is inherited whole from :class:`ExaMcpProvider`; only the tool
    name, its arguments and the response parser differ.
    """

    def __init__(
        self,
        url: str = DEFAULT_MCP_URL,
        *,
        name: str = "parallel:free",
        cost_per_1k: float = 0.0,
        text_chars: int = 2000,
        timeout: float = 30.0,
    ) -> None:
        super().__init__(
            url=url,
            api_key=None,
            name=name,
            cost_per_1k=cost_per_1k,
            text_chars=text_chars,
            timeout=timeout,
            tool_name="web_search",
        )

    @override
    def _tool_args(self, q: SearchQuery) -> dict[str, Any]:
        """``web_search`` requires both an objective and at least one query.

        The caller gives one string and there is no second to derive, so it
        serves as both.
        """
        return {"objective": q.query, "search_queries": [q.query]}

    @override
    def _parse(self, text: str, limit: int) -> list[Result]:
        """Parse the JSON payload Parallel's MCP tool returns as text.

        The tool puts the same JSON in both ``structuredContent`` and a
        ``TextContent`` block; this parser trusts the text channel, which is what
        the inherited call path hands it. A ``structuredContent`` fallback would
        need the tool result, so it belongs in an overridden ``_search_once``.
        """
        try:
            data = json.loads(text)
        except ValueError as exc:
            raise ProviderError(self.name, "malformed JSON response") from exc
        return parse_results(data, limit, self._text_chars)
