"""AnySearch — keyless whole-web SERP over a documented JSON API, explicit-only.

Cost note: the anonymous mode serves 1,000 requests/day with no account, key or
card (pricing page; ToS v1.1 §5.1.1), so ``cost_per_1k`` is 0.0 and ``cost_for``
is flat. The keyed plans exist, but this adapter implements the keyless mode
only: no ``Authorization`` header is ever sent.

Endpoint: ``POST https://api.anysearch.com/v1/search``, the operator's
documented search API -- a response document, not a scraped results page.

Explicit-only: ``anysearch`` is in neither the free set nor the install default
on purpose, though a keyless name that cannot bill would qualify the way
``freeserp`` does. It is reached only by naming it, never auto-routed or
defaulted (providers.md); the config tests pin its absence from
``FREE_PROVIDERS``, ``FREE_PROVIDER_ORDER`` and ``KEYLESS_PROVIDERS``.

Request: ``max_results`` is documented 1–10, so the adapter clamps rather than
sending a documented-invalid request. ``language`` is the only half of the geo
bucket reaching the wire (``zone`` takes ``cn``/``intl``, which a country code
cannot map into); there is no domain, date or safe-search field, so those drop
with a notice.

Response: ``{code, message, request_id, data}``, success ``code: 0``, hits in
``data.results[]`` as ``{title, url, snippet, content}``. An empty ``title``
drops the record, ``content`` is page text this adapter never reads, and
``metadata.total_results`` counts this response rather than a hit pool.

The 402 is the body the redaction rule exists for: an anonymous caller over the
daily quota is auto-registered, and ``message`` can carry the generated
username, password and API key -- so ``QuotaExhausted``'s message is a constant
and the body never reaches a log line. A 200 whose business ``code`` is not 0
is the same channel, and its error text is not echoed either.
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

ENDPOINT = "https://api.anysearch.com/v1/search"

# `max_results` is documented 1-10, and above 10 the request is a documented invalid
# one (400). The tool schema caps at 20, but the adapter is callable directly.
MAX_RESULTS = 10


class AnysearchProvider:
    name = "anysearch"
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
        """Per-query cost in USD. Flat zero: the keyless mode cannot bill.

        The argument is ignored rather than absent for the reason
        ``freeserp.cost_for`` gives: callers treat it as a duck-typed method.
        """
        return self.cost_per_1k / 1000.0

    async def search(self, q: SearchQuery) -> ProviderResult:
        body: dict[str, Any] = {
            "query": q.query,
            # Documented range 1-10; see MAX_RESULTS for why the clamp lives here.
            "max_results": min(max(q.max_results, 1), MAX_RESULTS),
        }
        if q.language:
            # Lowercased, not split: the docs' own examples are ISO codes ("en", "zh-CN").
            body["language"] = q.language.lower()

        try:
            resp = await self._client.post(
                ENDPOINT, json=body, timeout=self._timeout
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
            # 402 is the documented anonymous-quota exhaustion and its body may carry the
            # auto-generated credentials: the constant message is the redaction rule.
            raise QuotaExhausted(self.name, "out of credits or rate limited")
        if resp.status_code >= 400:
            raise ProviderError(self.name, f"HTTP {resp.status_code}")

        try:
            data = resp.json()
        except ValueError as exc:
            raise ProviderError(self.name, "malformed JSON response") from exc
        if not isinstance(data, dict):
            # A non-object JSON body is the same contracted error (provider-contract.md, "Failures").
            raise ProviderError(self.name, "malformed JSON response")

        if data.get("code") != 0:
            # Success is `code: 0`; the error channel's `message` can hold credentials, so a
            # fallback failure carries a constant and nothing else.
            raise ProviderError(self.name, "search failed (business error)")

        return ProviderResult(
            provider=self.name,
            results=self._parse(data.get("data"), q.max_results),
            cost_usd=self.cost_for(q.max_results),
            # Only `language` rides the wire: no domain, date, zone or safe-search field,
            # and the bucket is split so the notice names only what really dropped.
            notice=ignored_constraints(
                q, domains=False, dates=False, geo=False, language=True, safety=False
            ),
        )

    def _parse(self, data: Any, limit: int) -> list[Result]:
        """``data.results[]``: {title, url, snippet, content}.

        A SERP backend, so `snippet` is filled and `text` never is: `content` is
        the extract and is not read. Records missing a URL are dropped, and a
        `title` — documented as always present but possibly empty — drops the
        record when empty, and a field of the wrong type counts as absent.

        The argument is whatever the envelope's `data` field carried: shape drift
        becomes an empty result set rather than an error.
        """
        out: list[Result] = []
        if not isinstance(data, dict):
            return out
        for item in (data.get("results") or [])[:limit]:
            if not isinstance(item, dict):
                continue
            url = item.get("url")
            if not isinstance(url, str) or not url:
                continue
            title = item.get("title")
            if not isinstance(title, str) or not title:
                continue
            snippet, uncapped = truncate_snippet(
                item.get("snippet"), self._snippet_chars
            )
            result = Result(
                title=title,
                url=url,
                snippet=snippet,
            )
            # Log-only, and private so it cannot reach the wire (`search.cap`).
            result._uncapped_chars = uncapped
            out.append(result)
        return out

    async def aclose(self) -> None:
        # The lifespan owns the shared client (docs/reference/provider-contract.md).
        return None
