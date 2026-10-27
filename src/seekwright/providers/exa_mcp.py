"""Exa, reached as an MCP client rather than over HTTP.

The one adapter where we are an MCP *client*, which is why it exists in v1: it
exercises the riskiest integration path. Two things verified against the live
endpoint (``https://mcp.exa.ai/mcp``) shape this code:

* ``streamable_http_client`` yields a **2-tuple** ``(read, write)``, like every
  other transport since mcp 2; the third element (a ``get_session_id`` callable)
  is gone.
* The server returns **plain formatted text**, not ``structuredContent`` (which
  comes back empty), so results are parsed out of a ``Title:``/``URL:``/
  ``Published:``/``Highlights:`` block format.

The session is opened once and held for the process lifetime; per-request it
would re-handshake on every search.
"""

from __future__ import annotations

import asyncio
import contextlib
import re
from typing import Any

# Not `httpx`: mcp 2 speaks httpx2, and a client of the wrong type is accepted
# by `streamable_http_client(http_client=...)` but silently stops delivering the
# server-to-client messages this session needs. Our own HTTP adapters stay on
# `httpx`; the two libraries coexist in the same process.
import httpx2
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client
from mcp.types import TextContent

from ..logs import bind
from ..models import ProviderResult, Result, SearchQuery
from .base import ProviderError, QuotaExhausted, ignored_constraints, truncate_text

DEFAULT_URL = "https://mcp.exa.ai/mcp"

_FIELD = re.compile(
    r"^(Title|URL|Published|Author|Highlights|Text|ID|Score):\s*(.*)$", re.IGNORECASE
)


class ExaMcpProvider:
    """Exa via its hosted MCP endpoint, on one credential.

    Anonymous when ``api_key`` is None and billed when it is not -- the endpoint
    is the same either way. :class:`TieredExaProvider` pairs two of these.
    """

    name: str
    cost_per_1k: float

    def __init__(
        self,
        url: str = DEFAULT_URL,
        api_key: str | None = None,
        *,
        name: str = "exa",
        cost_per_1k: float = 7.00,
        text_chars: int = 2000,
        timeout: float = 30.0,
        tool_name: str = "web_search_exa",
    ) -> None:
        self._url = url
        self._api_key = api_key
        # One class at different prices, so name and cost are instance attributes.
        self.name = name
        self.cost_per_1k = cost_per_1k
        # A content backend fills `text` and nothing else; `_parse` is where that shows.
        self._text_chars = text_chars
        self._timeout = timeout
        self._tool_name = tool_name

        self._session: ClientSession | None = None
        self._owner: asyncio.Task[None] | None = None
        self._ready: asyncio.Future[ClientSession] | None = None
        self._shutdown: asyncio.Event | None = None
        self._lock = asyncio.Lock()

    def cost_for(self, max_results: int) -> float:
        # A free fallback costs nothing, whatever the result count returns.
        if not self.cost_per_1k:
            return 0.0
        # Exa bills ~$7/1k up to 10 results, then ~$1/1k per extra result.
        extra = max(0, max_results - 10)
        return (self.cost_per_1k + extra * 1.0) / 1000.0

    # The transport's cancel scopes belong to the task that enters them: one owner
    # task enters and exits the session, and request tasks only borrow it.

    async def _own_session(self) -> None:
        """Hold the MCP session open until shutdown is requested."""
        assert self._ready is not None and self._shutdown is not None
        try:
            async with contextlib.AsyncExitStack() as stack:
                # Auth goes through a pre-configured client, not a `headers` kwarg --
                # and it has to be an `httpx2` one: that is the type the transport
                # was written against, and httpx is API-identical but is a different
                # class, so passing one degrades the session quietly rather than
                # raising.
                http_client = None
                if self._api_key:
                    http_client = await stack.enter_async_context(
                        httpx2.AsyncClient(
                            headers={"Authorization": f"Bearer {self._api_key}"},
                            timeout=self._timeout,
                        )
                    )
                read, write = await stack.enter_async_context(
                    streamable_http_client(self._url, http_client=http_client)
                )
                session = await stack.enter_async_context(ClientSession(read, write))
                await session.initialize()

                self._session = session
                if not self._ready.done():
                    self._ready.set_result(session)
                await self._shutdown.wait()
        except Exception as exc:  # noqa: BLE001 - surfaced to the waiter below
            if not self._ready.done():
                self._ready.set_exception(exc)
        finally:
            self._session = None

    async def _ensure_session(self) -> ClientSession:
        async with self._lock:
            if self._session is not None:
                return self._session

            loop = asyncio.get_running_loop()
            self._ready = loop.create_future()
            self._shutdown = asyncio.Event()
            owner = loop.create_task(self._own_session())
            self._owner = owner
            try:
                return await asyncio.wait_for(self._ready, timeout=self._timeout)
            except TimeoutError as exc:
                # Awaited under the lock: releasing first would let a concurrent caller
                # build a fresh owner that this teardown would then cancel.
                owner.cancel()
                await asyncio.wait({owner}, timeout=10)
                self._owner = None
                self._shutdown = None
                self._ready = None
                self._session = None
                raise ProviderError(self.name, "MCP handshake timed out") from exc

    async def _reset(self) -> None:
        """Signal the owner task to tear down, so the next call reconnects."""
        async with self._lock:
            owner, self._owner = self._owner, None
            shutdown, self._shutdown = self._shutdown, None
            self._session = None
            self._ready = None
        if shutdown is not None:
            shutdown.set()
        if owner is not None:
            with contextlib.suppress(Exception):
                await asyncio.wait_for(owner, timeout=10)

    async def warmup(self) -> bool:
        """Open the session ahead of the first request. Never raises."""
        try:
            await self._ensure_session()
            return True
        except Exception:  # noqa: BLE001 - a cold start is not a startup failure
            return False

    async def search(self, q: SearchQuery) -> ProviderResult:
        # A long-lived session can die between calls: one retry after a reconnect is normal.
        try:
            return await self._search_once(q)
        except ProviderError:
            raise
        except Exception as exc:  # noqa: BLE001 - a dead session is worth one retry
            # DEBUG, not WARNING: a reconnect is expected on a long-lived session. Only the
            # exception type is logged: the object could be an httpx error carrying headers.
            bind(provider=self.name, exc_type=type(exc).__name__).debug("exa.retry")
            await self._reset()
            try:
                return await self._search_once(q)
            except ProviderError:
                raise
            except Exception as exc:
                raise ProviderError(self.name, "MCP session unavailable") from exc

    def _tool_args(self, q: SearchQuery) -> dict[str, Any]:
        """The argument dict for one tool call.

        Exa's ``web_search_exa`` advertises exactly ``query`` and ``numResults``
        (``"additionalProperties": false``), so there is no filter argument a
        caller's constraints could reach. A subclass reaching a different MCP
        tool overrides this.
        """
        return {"query": q.query, "numResults": q.max_results}

    async def _search_once(self, q: SearchQuery) -> ProviderResult:
        session = await self._ensure_session()
        result = await session.call_tool(
            self._tool_name,
            self._tool_args(q),
            # Seconds, as a float: mcp 2 dropped the timedelta form, and the
            # TypeError it would raise lands after the request is on the wire.
            read_timeout_seconds=self._timeout,
        )

        text = "\n".join(
            block.text for block in result.content if isinstance(block, TextContent)
        )

        if result.is_error:
            lowered = text.lower()
            if "rate" in lowered or "quota" in lowered or "429" in lowered:
                raise QuotaExhausted(self.name, "rate limited")
            raise ProviderError(self.name, "upstream MCP tool reported an error")

        return ProviderResult(
            provider=self.name,
            results=self._parse(text, q.max_results),
            cost_usd=self.cost_for(q.max_results),
            # The tool surface takes no filter args (see `_tool_args`), so no caller
            # constraint can reach it; the parsed `Published:` dates are the freshness signal.
            notice=ignored_constraints(
                q, domains=False, dates=False, geo=False, safety=False
            ),
        )

    def _parse(self, text: str, limit: int) -> list[Result]:
        """Parse Exa's ``Title:``/``URL:``/``Highlights:`` block format."""
        results: list[Result] = []
        current: dict[str, str] = {}
        body: list[str] = []
        field: str | None = None

        def flush() -> None:
            url = current.get("url")
            if url:
                text, truncated, uncapped = truncate_text(
                    " ".join(body), self._text_chars
                )
                result = Result(
                    # Exa sends `Title: N/A` for a page it could not name: the URL is a worse
                    # title but a true one, and dropping the record would lose a real result.
                    title=current.get("title") or url,
                    url=url,
                    text=text,
                    text_truncated=truncated or None,
                    published_date=current.get("published"),
                )
                # Log-only, and private so it cannot reach the wire (`search.cap`).
                result._uncapped_chars = uncapped
                results.append(result)
            current.clear()
            body.clear()

        for line in text.splitlines():
            match = _FIELD.match(line.strip())
            if match:
                name, value = match.group(1).lower(), match.group(2).strip()
                if name == "title":
                    flush()  # a new Title starts the next record
                    if len(results) >= limit:
                        return results
                field = name
                if name == "title":
                    # `N/A` is Exa saying it could not name the page; flush() falls back to the URL.
                    if value and value != "N/A":
                        current[name] = value
                elif name == "url":
                    current[name] = value
                elif name == "published" and value and value != "N/A":
                    current["published"] = value[:10]
                elif name in ("highlights", "text") and value:
                    body.append(value)
                continue
            if (
                line.strip()
                and line.strip() != "..."
                and field in ("highlights", "text")
            ):
                body.append(line.strip())

        flush()
        return results[:limit]

    async def aclose(self) -> None:
        await self._reset()


class TieredExaProvider:
    """Exa's free tier first, its billed one only when the free tier can't serve.

    The same endpoint answers anonymously on a rate-limited free plan and
    authenticated on a paid one, so a key is not a capability upgrade -- it is
    the difference between $0 and ~$7/1k for identical results.

    Two fallbacks, free-then-paid, bounded the way :class:`~seekwright.engine.FetchEngine`'s
    ladder is. Not cheapest-provider routing: both are the same backend under the
    name the caller asked for, so the ladder can only undercharge it.

    ``exa:free`` is a bare :class:`ExaMcpProvider` rather than this class, so a
    deployment that must never spend can say so by name.
    """

    name = "exa"
    cost_per_1k: float

    def __init__(
        self,
        api_key: str,
        *,
        url: str = DEFAULT_URL,
        cost_per_1k: float = 7.00,
        text_chars: int = 2000,
        timeout: float = 30.0,
        cooldown_seconds: float = 60.0,
    ) -> None:
        self.cost_per_1k = cost_per_1k
        self._cooldown = cooldown_seconds
        # Both fallbacks report `exa`: which credential served a search is a fact about cost,
        # not a different provider.
        self._free = ExaMcpProvider(
            url, None, name=self.name, cost_per_1k=0.0, text_chars=text_chars,
            timeout=timeout,
        )
        self._keyed = ExaMcpProvider(
            url, api_key, name=self.name, cost_per_1k=cost_per_1k,
            text_chars=text_chars, timeout=timeout,
        )
        # Monotonic, not wall clock: a clock adjustment must not extend the cooldown.
        self._free_blocked_until = 0.0

    def cost_for(self, max_results: int) -> float:
        # The billed fallback's price: what a caller should assume it might pay.
        return self._keyed.cost_for(max_results)

    async def search(self, q: SearchQuery) -> ProviderResult:
        now = asyncio.get_running_loop().time()
        if now < self._free_blocked_until:
            # One line per call the cooldown bills for: `exa.escalated` said the free tier
            # broke; this says the search was billed for it.
            bind(
                remaining_s=round(self._free_blocked_until - now, 1),
                cost_usd=self.cost_for(q.max_results),
            ).info("exa.cooldown")
            # Not "was rate-limited": the cooldown is set by any free-fallback failure.
            return await self._on_key(
                q, "free tier failed recently, so this call used the API key"
            )
        try:
            return await self._free.search(q)
        except ProviderError as exc:
            # Any failure, not a classified `QuotaExhausted`: Exa's wording for exhaustion has
            # never been observed, so a misclassification costs one paid search, not the tier.
            self._free_blocked_until = (
                asyncio.get_running_loop().time() + self._cooldown
            )
            # WARNING because this is the moment the deployment stopped being free.
            bind(
                reason=exc.message,
                cooldown_s=self._cooldown,
                cost_usd=self.cost_for(q.max_results),
            ).warning("exa.escalated")
            return await self._on_key(
                q, f"free tier unavailable ({exc.message}), so this call used the "
                "API key",
                original=exc,
            )

    async def _on_key(
        self, q: SearchQuery, reason: str, original: ProviderError | None = None
    ) -> ProviderResult:
        """Run the billed fallback, and say in `notice` that it cost something.

        Silence here is the expensive kind: a deployment whose free tier quietly
        stopped working would keep answering, evidenced only by the invoice.
        """
        try:
            result = await self._keyed.search(q)
        except ProviderError as exc:
            if original is None:
                raise
            # The free fallback's failure is the message; the keyed one is appended, never
            # substituted, and the class is kept for the engine's retry advice.
            message = f"{original.message}; the API key also failed ({exc.message})"
            bind(reason=exc.message, original_reason=original.message).error(
                "exa.both_failed"
            )
            if isinstance(original, QuotaExhausted):
                raise QuotaExhausted(self.name, message) from original
            raise ProviderError(
                self.name, message, retryable=original.retryable
            ) from original

        notices = [n for n in (result.notice, reason) if n]
        return result.model_copy(update={"notice": "; ".join(notices)})

    async def warmup(self) -> bool:
        """Open the free session ahead of the first request. Never raises.

        Only the free fallback: the keyed one opens lazily on first escalation,
        and warming it would buy nothing anyway -- a rejected key still completes
        the MCP handshake and only fails at the tool call.
        """
        return await self._free.warmup()

    async def aclose(self) -> None:
        await self._free.aclose()
        await self._keyed.aclose()
