"""Provider health: a passive circuit breaker fed by real traffic, plus a
best-effort periodic ping.

Two signals land on one board. Real searches are the primary one: every
dispatch records its outcome, and a provider that fails repeatedly is gated out
of the *default route's fallbacks* for a cooldown. The periodic ping
re-verifies providers with the same bodyless GET ``--check`` uses, which cannot
produce results -- so it is never billed -- but proves the network path and,
when a key is sent, that the key still authenticates.

The board gates ladder fallbacks only. The first attempt of any search -- the
resolved default, or the provider the caller named -- is never skipped: a
breaker saves the second attempt, it does not pre-empt the first.

Clock discipline mirrors ``TieredExaProvider``: ``asyncio.get_running_loop()``
time, monotonic per loop, so plain attributes need no locks.
"""

from __future__ import annotations

import asyncio
import enum
import time
from dataclasses import dataclass
from typing import TYPE_CHECKING
from urllib.parse import quote, urlencode

import httpx

from .config import PROVIDERS_REQUIRING_KEY, Config
from .logs import bind, elapsed_ms
from .providers.anysearch import ENDPOINT as ANYSEARCH_ENDPOINT
from .providers.deepseek import ENDPOINT as DEEPSEEK_ENDPOINT
from .providers.freeserp import ENDPOINT as FREESERP_ENDPOINT
from .providers.linkup import ENDPOINT as LINKUP_ENDPOINT
from .providers.parallel import ENDPOINT as PARALLEL_ENDPOINT
from .providers.querit import ENDPOINT as QUERIT_ENDPOINT
from .providers.scrappa import ENDPOINT as SCRAPPA_ENDPOINT
from .providers.search1api import ENDPOINT as SEARCH1API_ENDPOINT
from .providers.serpapi import ENDPOINT as SERPAPI_ENDPOINT
from .providers.serper import ENDPOINT as SERPER_ENDPOINT
from .providers.tavily import ENDPOINT as TAVILY_ENDPOINT
from .providers.tinyfish import ENDPOINT as TINYFISH_ENDPOINT

if TYPE_CHECKING:
    from collections.abc import Callable

    from .providers.base import SearchProvider


class ProbeOutcome(enum.StrEnum):
    """What one connectivity probe concluded.

    ``UNSUPPORTED`` names a provider with no cheap probe -- the MCP-backed ones
    are verified by session handshake instead (``warmup``). ``KEY_REQUIRED`` is
    the neighbouring case: the probe exists, but its mandatory key is absent, so
    there is nothing left to ask and nothing to reach.
    """

    REACHABLE = "reachable"
    REACHABLE_NO_KEY = "reachable_no_key"
    KEY_REJECTED = "key_rejected"
    KEY_REQUIRED = "key_required"
    UNREACHABLE = "unreachable"
    UNSUPPORTED = "unsupported"


def _endpoint(url: str) -> Callable[[Config, str | None], str | None]:
    """The builder for a name whose probe asks the adapter's own endpoint.

    The name is ignored: a module constant is the whole fact, and the key's
    placement is the header builder's business.
    """
    return lambda _config, _key: url


def _no_headers(_config: Config, _key: str | None) -> dict[str, str]:
    """The builder for a keyless probe: the GET carries nothing."""
    return {}


def _header(
    header: str, prefix: str = ""
) -> Callable[[Config, str | None], dict[str, str]]:
    """The builder for a name whose key rides in ``header``.

    ``prefix`` is what the endpoint spells ahead of the key. No key, no header:
    the probe still goes out, since for an optional key a keyless GET is exactly
    what ``--check`` proves.
    """
    return lambda _config, key: {header: f"{prefix}{key}"} if key else {}


def _serpapi_endpoint(_config: Config, key: str | None) -> str | None:
    return f"{SERPAPI_ENDPOINT}?{urlencode({'api_key': key})}"


def _searxng_endpoint(config: Config, _key: str | None) -> str | None:
    base_url = config.providers["searxng"].url
    if not base_url:
        return None
    return f"{base_url.rstrip('/')}/search?q=probe&format=json"


def _algolia_deployment(config: Config) -> tuple[str, str] | None:
    """The ``(app_id, index)`` to probe, or ``None`` if the config named
    neither: an indexless probe would address nothing."""
    pc = config.providers.get("algolia")
    if pc is None or not pc.app_id or not pc.index:
        return None
    return pc.app_id, pc.index


def _algolia_endpoint(config: Config, _key: str | None) -> str | None:
    deployment = _algolia_deployment(config)
    if deployment is None:
        return None
    app_id, index = deployment
    return (
        f"https://{app_id}-dsn.algolia.net"
        f"/1/indexes/{quote(index, safe='')}/query"
        "?query=probe&hitsPerPage=notanumber"
    )


def _algolia_headers(config: Config, key: str | None) -> dict[str, str]:
    deployment = _algolia_deployment(config)
    if deployment is None:
        return {}
    app_id, _index = deployment
    headers = {"x-algolia-application-id": app_id}
    if key:
        headers["x-algolia-api-key"] = key
    return headers


@dataclass(frozen=True)
class _ProbeSpec:
    """One name's probe shape: where the bodyless GET goes and what it carries.

    An endpoint builder that returns ``None`` says the deployment never named
    what that probe would need -- searxng's instance, algolia's index -- so it
    answers ``UNSUPPORTED`` like a name with no probe at all.
    """

    endpoint: Callable[[Config, str | None], str | None]
    headers: Callable[[Config, str | None], dict[str, str]] = _no_headers


# One row per provider name: the builders, beside why the probe has its shape -- the path and credential this adapter dispatches on.
# No row, no cheap probe: the MCP-backed ones answer UNSUPPORTED and prove by `warmup`.
_PROBES: dict[str, _ProbeSpec] = {
    # The adapter's own endpoint, key in the header it authenticates with: a bodyless GET cannot produce results,
    # so it cannot spend a credit, and a 200 says the key `search` would send is accepted.
    "scrappa": _ProbeSpec(
        _endpoint(SCRAPPA_ENDPOINT), _header("x-api-key")
    ),
    "serper": _ProbeSpec(_endpoint(SERPER_ENDPOINT), _header("X-API-KEY")),
    "linkup": _ProbeSpec(
        _endpoint(LINKUP_ENDPOINT), _header("Authorization", "Bearer ")
    ),
    "tavily": _ProbeSpec(
        _endpoint(TAVILY_ENDPOINT), _header("Authorization", "Bearer ")
    ),
    "tinyfish": _ProbeSpec(_endpoint(TINYFISH_ENDPOINT), _header("X-API-Key")),
    # Keyless, and the one endpoint whose default index is *not* the one this adapter calls, so `index=web&q=probe`
    # names it explicitly -- a real free search, the shape searxng's probe has.
    "freeserp": _ProbeSpec(
        _endpoint(f"{FREESERP_ENDPOINT}?index=web&q=probe")
    ),
    # A bodyless GET hits the endpoint's auth check, so it proves the path and the key without a search.
    # `parallel:free` gets no row: it is proven by its MCP `warmup`.
    "parallel": _ProbeSpec(
        _endpoint(PARALLEL_ENDPOINT), _header("x-api-key")
    ),
    # The one endpoint that comes from config rather than a module constant,
    # and whose probe is a real (free) search: the JSON format is what needs proving.
    "searxng": _ProbeSpec(_searxng_endpoint),
    # The malformed `hitsPerPage` is deliberate: a bodyless GET with valid parameters *executes a search*,
    # and every search request is billed against the monthly quota; a request rejected at parameter validation never runs one.
    "algolia": _ProbeSpec(_algolia_endpoint, _algolia_headers),
    # Auth check answered without a search; the key is mandatory, so `probe` answers KEY_REQUIRED before any request.
    "search1api": _ProbeSpec(
        _endpoint(SEARCH1API_ENDPOINT), _header("Authorization", "Bearer ")
    ),
    # Keyless, so no key is ever sent, and the endpoint is POST-only,
    # so a bodyless GET answers 404: the probe proves the network path and the live test proves the POST contract.
    "anysearch": _ProbeSpec(_endpoint(ANYSEARCH_ENDPOINT)),
    # The key rides in the query string -- the operator's documented shape, not a header.
    # Without `q` or `engine` the request is rejected before any search runs, and only successful searches are billed.
    "serpapi": _ProbeSpec(_serpapi_endpoint),
    # Auth check answered without a search; the key is mandatory, so `probe` answers KEY_REQUIRED before any request.
    "querit": _ProbeSpec(
        _endpoint(QUERIT_ENDPOINT), _header("Authorization", "Bearer ")
    ),
    # POST-only, so the bodyless GET answers an error rather than the auth check the way `querit`'s does: like `anysearch`,
    # the probe proves the network path and the live test proves the POST contract.
    "deepseek": _ProbeSpec(
        _endpoint(DEEPSEEK_ENDPOINT), _header("Authorization", "Bearer ")
    ),
}

# A name missing from `_PROBES` behaves like a name whose probe cannot be
# built: no request, `UNSUPPORTED`.
_NO_PROBE = _ProbeSpec(lambda _config, _key: None)


async def probe(
    name: str, *, client: httpx.AsyncClient, config: Config
) -> ProbeOutcome:
    """One bodyless GET at ``name``'s endpoint; every failure is an outcome.

    A provider whose key is mandatory (``config.PROVIDERS_REQUIRING_KEY``) is
    answered before any request when that key is absent. Which endpoint and
    headers a name probes is data -- see ``_PROBES`` -- and a name the table has
    no row for, or whose row cannot build a URL from this deployment's config,
    is answered UNSUPPORTED. Never raises.
    """
    key = config.api_key(name)
    # A mandatory key that is absent ends the probe ahead of the table lookup: the shared tail's
    # `REACHABLE_NO_KEY` is a true readiness for a keyless adapter and a false one for a name whose key is never optional.
    if not key and name in PROVIDERS_REQUIRING_KEY:
        return ProbeOutcome.KEY_REQUIRED
    spec = _PROBES.get(name, _NO_PROBE)
    url = spec.endpoint(config, key)
    if url is None:
        return ProbeOutcome.UNSUPPORTED
    try:
        resp = await client.get(
            url,
            headers=spec.headers(config, key),
            timeout=config.policy.provider_timeout_seconds,
        )
    except httpx.HTTPError:
        return ProbeOutcome.UNREACHABLE
    if not key:
        # Only the keyless adapters reach here now (`searxng`, `freeserp`,
        # `anysearch`); every mandatory-key name was answered above.
        return ProbeOutcome.REACHABLE_NO_KEY
    if resp.status_code in (401, 403):
        return ProbeOutcome.KEY_REJECTED
    return ProbeOutcome.REACHABLE


@dataclass
class _Health:
    """One provider's breaker state; lives only on the single event loop."""

    consecutive: int = 0
    # 0.0 = never opened / closed. A past deadline is a half-open gate.
    open_until: float = 0.0


class HealthBoard:
    """Per-provider failure counts and open gates, fed by real traffic.

    Half-open is implicit: an expired gate reads closed, one more failure
    re-opens it without waiting for the threshold again, and any success
    closes it outright.
    """

    def __init__(
        self, *, failure_threshold: int = 3, cooldown_seconds: float = 120.0
    ) -> None:
        self._failure_threshold = failure_threshold
        self._cooldown_seconds = cooldown_seconds
        self._states: dict[str, _Health] = {}

    def record_failure(
        self, name: str, *, reason: str = "failed", force_open: bool = False
    ) -> None:
        """Count one failure, opening the gate when the state machine says so.

        ``force_open`` is for failures that will not heal by accumulation -- a
        probe that found the API key rejected opens immediately. Closed or
        half-open to open is the state change worth a log line; extending an
        already-open gate is not, so a sustained outage says "open" once.
        """
        now = asyncio.get_running_loop().time()
        state = self._states.setdefault(name, _Health())
        state.consecutive += 1
        was_open = state.open_until > now
        half_open = state.open_until != 0.0 and not was_open
        if force_open or half_open or state.consecutive >= self._failure_threshold:
            state.open_until = now + self._cooldown_seconds
            if not was_open:
                bind(
                    provider=name, reason=reason, consecutive=state.consecutive
                ).info("health.open")

    def record_success(self, name: str, *, reason: str = "succeeded") -> None:
        """Reset the count, and close the gate if one was armed.

        Never raises for a name the board has not seen: lazy state creation,
        like the tiered Exa provider's.
        """
        state = self._states.get(name)
        if state is None or not (state.consecutive or state.open_until):
            return
        was_armed = state.open_until != 0.0
        state.consecutive = 0
        state.open_until = 0.0
        if was_armed:
            bind(provider=name, reason=reason).info("health.closed")

    def is_open(self, name: str) -> bool:
        """Whether ``name``'s gate is up right now. Unknown names read closed."""
        state = self._states.get(name)
        return (
            state is not None
            and state.open_until > asyncio.get_running_loop().time()
        )

    def open_for_s(self, name: str) -> float:
        """Seconds left on ``name``'s gate; callers round for the log."""
        state = self._states.get(name)
        if state is None:
            return 0.0
        return max(0.0, state.open_until - asyncio.get_running_loop().time())


class HealthMonitor:
    """The periodic half: re-probe every enabled provider on one shared client.

    Best-effort by construction -- ``warmup`` returns False rather than
    raising, and ``probe`` maps every failure to an outcome -- so the loop
    carries no guard. ``UNSUPPORTED`` and ``KEY_REQUIRED`` touch the board not
    at all: neither is a provider the board could gate.
    """

    def __init__(
        self,
        *,
        config: Config,
        providers: dict[str, SearchProvider],
        client: httpx.AsyncClient,
        board: HealthBoard,
    ) -> None:
        self._config = config
        self._providers = providers
        self._client = client
        self._board = board

    async def run(self) -> None:
        """Probe forever on the configured interval. Cancellation is the stop."""
        interval = self._config.search.health_interval_seconds
        while True:
            await asyncio.sleep(interval)
            for name in self._config.enabled_providers():
                provider = self._providers.get(name)
                if provider is None:
                    continue
                started = time.monotonic()
                # Duck-typed like the server's warm-up: MCP-backed providers
                # expose warmup(), HTTP ones do not.
                warmup = getattr(provider, "warmup", None)
                if warmup is not None:
                    ok = await warmup()
                    bind(
                        provider=name,
                        outcome="warmup ok" if ok else "warmup failed",
                        ms=elapsed_ms(started),
                    ).debug("health.probe")
                    if ok:
                        self._board.record_success(name, reason="warmup ok")
                    else:
                        self._board.record_failure(name, reason="warmup failed")
                    continue
                outcome = await probe(name, client=self._client, config=self._config)
                bind(
                    provider=name, outcome=outcome.value, ms=elapsed_ms(started)
                ).debug("health.probe")
                if outcome in (ProbeOutcome.REACHABLE, ProbeOutcome.REACHABLE_NO_KEY):
                    self._board.record_success(name, reason="probe reachable")
                elif outcome is ProbeOutcome.UNREACHABLE:
                    self._board.record_failure(name, reason="probe unreachable")
                elif outcome is ProbeOutcome.KEY_REJECTED:
                    # Not going to heal between ticks: open now, not at the
                    # threshold.
                    self._board.record_failure(
                        name, reason="probe key rejected", force_open=True
                    )
