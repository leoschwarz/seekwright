"""Provider, extractor and fetcher construction from config and environment.

Kept out of :mod:`server` so the CLI diagnostic path (``--check``) can build
providers -- and report the extraction backend -- without importing the FastMCP
app.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass

import httpx

from .config import Config, ProviderConfig
from .extractors.base import KNOWN_EXTRACTORS, Extractor
from .fetcher import KNOWN_FALLBACKS, ContentFetcher, HttpFetcher
from .providers.algolia import AlgoliaProvider
from .providers.anysearch import AnysearchProvider
from .providers.base import SearchProvider
from .providers.deepseek import DeepSeekProvider
from .providers.exa_mcp import DEFAULT_URL as EXA_DEFAULT_URL
from .providers.exa_mcp import ExaMcpProvider, TieredExaProvider
from .providers.freeserp import FreeserpProvider
from .providers.linkup import LinkupProvider
from .providers.parallel import DEFAULT_MCP_URL as PARALLEL_DEFAULT_MCP_URL
from .providers.parallel import ParallelMcpProvider, ParallelProvider
from .providers.querit import QueritProvider
from .providers.scrappa import ScrappaProvider
from .providers.search1api import Search1ApiProvider
from .providers.searxng import SearxngProvider
from .providers.serpapi import SerpApiProvider
from .providers.serper import SerperProvider
from .providers.tavily import TavilyProvider
from .providers.tinyfish import TinyfishProvider


def _cost(pc: ProviderConfig, default: float) -> float:
    """Config wins where it says something; otherwise the adapter's own figure.

    One idiom for both priced things: a provider's ``cost_per_1k`` and the fetch
    ladder's priced fallback share the field name and the ``None`` shape. A fetch
    fallback resolves the key in its own constructor, beside the price it
    declares on its class (``ScrappaFetcher``), so no builder here carries a
    figure.
    """
    return pc.cost_per_1k if pc.cost_per_1k is not None else default


class ExtractorUnavailable(Exception):
    """The configured extraction backend's library is not installed.

    Distinct from an unknown *name* (a config error, caught at validation):
    here the config is right and the install is incomplete, which is why the
    message names the extra rather than listing the supported backends.
    """


def build_extractor(config: Config) -> Extractor:
    """Instantiate the extraction backend ``fetch.extractor`` names.

    The backend module is imported here rather than at package import time, so
    an install carrying no extraction libraries still runs `search`, and a
    `fetch` that needs the missing one fails with the extra named rather than a
    bare ``ImportError`` out of the middle of a request. `stdlib` is the name
    such an install can write instead: it imports nothing outside the standard
    library, so it is buildable everywhere.
    """
    name = config.fetch.extractor
    if name == "trafilatura":
        try:
            from .extractors.trafilatura import TrafilaturaExtractor
        except ImportError as exc:
            raise ExtractorUnavailable(
                f"fetch extractor {name!r} is selected but its library is not "
                f"installed; install the {name!r} extra using the install block "
                "in docs/quickstart.md section 1 (index URL, pin and --python "
                "3.14), or set fetch.extractor to 'stdlib', which reads a page "
                "with the standard library alone"
            ) from exc
        return TrafilaturaExtractor()
    if name == "stdlib":
        # No import guard, because there is no library this backend can be missing:
        # every import it makes is in the standard library, and that is the whole
        # reason a bare install has a backend to name.
        from .extractors.stdlib import StdlibExtractor

        return StdlibExtractor()
    # Defensive: `FetchConfig` already rejects a name outside KNOWN_EXTRACTORS,
    # so reaching here means a Config built around validation rather than through it.
    raise ValueError(
        f"unknown fetch extractor {name!r}; "
        f"supported: {', '.join(sorted(KNOWN_EXTRACTORS))}"
    )


@dataclass(frozen=True)
class _BuildArgs:
    """What one name's builder is handed, resolved once per config entry.

    `cost` and `timeout` are the row's figures merged with the config entry and
    the policy timeout, so no builder re-derives either. `pc` rides along because
    which fields an adapter reads out of its own entry is that adapter's business.
    """

    client: httpx.AsyncClient
    key: str | None
    name: str
    pc: ProviderConfig
    snippet_chars: int
    text_chars: int
    cost: float
    timeout: float


@dataclass(frozen=True)
class _BuildSpec:
    """One row of `_PROVIDERS`: the constructor, the default price, the floor.

    `default_cost` is the figure `_cost` falls back to when the config entry says
    nothing, and the second of the two copies `provider-contract.md` warns about
    (the other is the adapter's own `__init__` signature) -- move both together.
    `None` means the name is priced at zero whatever the config says, which is
    `exa:free` alone. `timeout_floor` is the least time that name gets, with the
    reason it needs more than the policy default written beside its row.
    """

    build: Callable[[_BuildArgs], SearchProvider | None]
    default_cost: float | None = 0.0
    timeout_floor: float = 0.0

    def cost(self, pc: ProviderConfig) -> float:
        """What this name is built at: config wins, unless the row is fixed."""
        return 0.0 if self.default_cost is None else _cost(pc, self.default_cost)


def _build_scrappa(a: _BuildArgs) -> SearchProvider | None:
    if not a.key:
        return None
    return ScrappaProvider(
        a.client,
        a.key,
        cost_per_1k=a.cost,
        snippet_chars=a.snippet_chars,
        timeout=a.timeout,
    )


def _build_serper(a: _BuildArgs) -> SearchProvider | None:
    if not a.key:
        return None
    return SerperProvider(
        a.client,
        a.key,
        cost_per_1k=a.cost,
        snippet_chars=a.snippet_chars,
        timeout=a.timeout,
    )


def _build_linkup(a: _BuildArgs) -> SearchProvider | None:
    if not a.key:
        return None
    return LinkupProvider(
        a.client,
        a.key,
        output_type=a.pc.output_type,
        depth=a.pc.depth,
        cost_per_1k=a.cost,
        snippet_chars=a.snippet_chars,
        timeout=a.timeout,
    )


def _build_exa_free(a: _BuildArgs) -> SearchProvider:
    # A content backend: it returns page text inline, so what bounds its
    # context cost is the text cap, not the snippet one.
    return ExaMcpProvider(
        url=a.pc.url or EXA_DEFAULT_URL,
        api_key=None,
        name=a.name,
        cost_per_1k=a.cost,
        text_chars=a.text_chars,
        timeout=a.timeout,
    )


def _build_searxng(a: _BuildArgs) -> SearchProvider | None:
    # Keyless, so no key guard: the only prerequisite is the instance URL, and
    # config validation has already rejected an enabled searxng without one.
    if not a.pc.url:
        return None
    return SearxngProvider(
        a.client,
        url=a.pc.url,
        cost_per_1k=a.cost,
        snippet_chars=a.snippet_chars,
        timeout=a.timeout,
    )


def _build_tavily(a: _BuildArgs) -> SearchProvider | None:
    if not a.key:
        return None
    return TavilyProvider(
        a.client,
        a.key,
        cost_per_1k=a.cost,
        # A content backend: it returns page text inline, so what bounds its
        # context cost is the text cap, not the snippet one.
        text_chars=a.text_chars,
        timeout=a.timeout,
    )


def _build_tinyfish(a: _BuildArgs) -> SearchProvider | None:
    if not a.key:
        return None
    return TinyfishProvider(
        a.client,
        a.key,
        cost_per_1k=a.cost,
        snippet_chars=a.snippet_chars,
        timeout=a.timeout,
    )


def _build_freeserp(a: _BuildArgs) -> SearchProvider:
    return FreeserpProvider(
        a.client,
        cost_per_1k=a.cost,
        snippet_chars=a.snippet_chars,
        timeout=a.timeout,
    )


def _build_algolia(a: _BuildArgs) -> SearchProvider | None:
    # app_id and index are validated at config load, like searxng's url; the
    # guard is what narrows their types to str here.
    if not (a.key and a.pc.app_id and a.pc.index):
        return None
    return AlgoliaProvider(
        a.client,
        a.key,
        app_id=a.pc.app_id,
        index=a.pc.index,
        cost_per_1k=a.cost,
        snippet_chars=a.snippet_chars,
        timeout=a.timeout,
        title_attr=a.pc.title_attr,
        url_attr=a.pc.url_attr,
        snippet_attr=a.pc.snippet_attr,
    )


def _build_exa(a: _BuildArgs) -> SearchProvider | None:
    if not a.key:
        return None
    return TieredExaProvider(
        a.key,
        url=a.pc.url or EXA_DEFAULT_URL,
        cost_per_1k=a.cost,
        text_chars=a.text_chars,
        timeout=a.timeout,
        cooldown_seconds=a.pc.free_cooldown_seconds,
    )


def _build_parallel(a: _BuildArgs) -> SearchProvider | None:
    if not a.key:
        return None
    return ParallelProvider(
        a.client,
        a.key,
        cost_per_1k=a.cost,
        text_chars=a.text_chars,
        mode=a.pc.mode,
        timeout=a.timeout,
    )


def _build_parallel_free(a: _BuildArgs) -> SearchProvider:
    return ParallelMcpProvider(
        url=a.pc.url or PARALLEL_DEFAULT_MCP_URL,
        cost_per_1k=a.cost,
        text_chars=a.text_chars,
        timeout=a.timeout,
    )


def _build_search1api(a: _BuildArgs) -> SearchProvider | None:
    if not a.key:
        return None
    return Search1ApiProvider(
        a.client,
        a.key,
        cost_per_1k=a.cost,
        snippet_chars=a.snippet_chars,
        timeout=a.timeout,
    )


def _build_anysearch(a: _BuildArgs) -> SearchProvider:
    return AnysearchProvider(
        a.client,
        cost_per_1k=a.cost,
        snippet_chars=a.snippet_chars,
        timeout=a.timeout,
    )


def _build_serpapi(a: _BuildArgs) -> SearchProvider | None:
    if not a.key:
        return None
    return SerpApiProvider(
        a.client,
        a.key,
        cost_per_1k=a.cost,
        snippet_chars=a.snippet_chars,
        timeout=a.timeout,
    )


def _build_querit(a: _BuildArgs) -> SearchProvider | None:
    if not a.key:
        return None
    return QueritProvider(
        a.client,
        a.key,
        cost_per_1k=a.cost,
        snippet_chars=a.snippet_chars,
        timeout=a.timeout,
    )


def _build_deepseek(a: _BuildArgs) -> SearchProvider | None:
    if not a.key:
        return None
    return DeepSeekProvider(
        a.client,
        a.key,
        cost_per_1k=a.cost,
        snippet_chars=a.snippet_chars,
        text_chars=a.text_chars,
        timeout=a.timeout,
    )


# One row per name this module can build: the builder, the price a config does not correct, the least time the backend needs.
# Not the registry that page rules out (wiring point 3): private, read one row at a time; a builder returning `None` skips the name.
_PROVIDERS: dict[str, _BuildSpec] = {
    # A scraping backend, not a cached SERP index: slower than Serper on the
    # same query.
    "scrappa": _BuildSpec(_build_scrappa, default_cost=0.30, timeout_floor=15.0),
    "serper": _BuildSpec(_build_serper, default_cost=1.00),
    "linkup": _BuildSpec(_build_linkup, default_cost=6.00, timeout_floor=20.0),
    # Exa's MCP endpoint reached anonymously: the one provider that needs no key,
    # and the one row that fixes its price at zero rather than offering it as a default.
    "exa:free": _BuildSpec(
        _build_exa_free, default_cost=None, timeout_floor=30.0
    ),
    # A metasearch instance queries its upstream engines live, so it answers at
    # scraper speed, not SERP-API speed.
    "searxng": _BuildSpec(_build_searxng, default_cost=0.0, timeout_floor=15.0),
    # An API with its own SERP cache, not a scrape: normal timeout.
    "tavily": _BuildSpec(_build_tavily, default_cost=8.00),
    # An API, not a scrape: normal timeout.
    "tinyfish": _BuildSpec(_build_tinyfish, default_cost=0.0),
    # Keyless -- no account, no key, no card -- and priced at zero like `exa:free`: nothing about a call here can bill.
    "freeserp": _BuildSpec(_build_freeserp, default_cost=0.0),
    "algolia": _BuildSpec(_build_algolia, default_cost=0.50),
    # Billed Exa, which still spends the free tier first (TieredExaProvider): without a key there is no billed fallback.
    "exa": _BuildSpec(_build_exa, default_cost=7.00, timeout_floor=30.0),
    # Keyed despite the free tier -- it is an account quota, and the key names whose quota a search spends.
    # REST, not the authenticated MCP, is the surface that carries the filter fields.
    "parallel": _BuildSpec(_build_parallel, default_cost=1.00),
    # Keyless anonymous hosted MCP, priced at zero like `exa:free`. MCP
    # handshake headroom, mirroring `exa:free`.
    "parallel:free": _BuildSpec(
        _build_parallel_free, default_cost=0.0, timeout_floor=30.0
    ),
    # Keyed despite the 100 free credits: a metered allowance is a billable quota.
    # `default_cost` is the entry Basic plan's rate; a cheaper plan corrects it in config.
    "search1api": _BuildSpec(_build_search1api, default_cost=0.76),
    # Keyless and priced at zero, but built only because this config named it: the explicit-only stance
    # keeps it out of the keyless default and the free set, so this row is the only route to the adapter.
    "anysearch": _BuildSpec(_build_anysearch, default_cost=0.0),
    # Keyed despite the 250 searches/month free tier, on the metered-quota reasoning;
    # `default_cost` is that free plan and a paid plan corrects it in config.
    "serpapi": _BuildSpec(_build_serpapi, default_cost=0.0),
    # Keyed despite the 1,000 free calls/month for the same reason; `default_cost` is the free plan, the $4/1k PAYG tier corrects
    # it. `/v1/contents` is a fetch concern, so no builder here asks for it.
    "querit": _BuildSpec(_build_querit, default_cost=0.0),
    # Keyed, and the only name here with no free tier to be keyed *despite*: billed per successful request
    # against the account balance at the published $0.75/1k.
    "deepseek": _BuildSpec(_build_deepseek, default_cost=0.75),
}


def build_providers(
    config: Config, client: httpx.AsyncClient
) -> dict[str, SearchProvider]:
    """Instantiate every enabled provider that has the credentials it needs.

    A provider named in config but missing its key is skipped here rather than
    raised on, because this runs inside ``--check`` too. The caller decides what
    an incomplete set means: the server refuses to start, ``--check`` reports
    it. Use :meth:`Config.missing_api_keys` to detect the case.

    Which constructor a name has, what it costs when config says nothing, and
    the least time it gets are the row in ``_PROVIDERS``; how it is put
    together is the builder that row names.
    """
    providers: dict[str, SearchProvider] = {}
    snippet_chars = config.policy.max_snippet_chars
    text_chars = config.policy.max_result_text_chars
    policy_timeout = config.policy.provider_timeout_seconds

    for name, pc in config.providers.items():
        if not pc.enabled:
            continue
        spec = _PROVIDERS.get(name)
        if spec is None:
            continue
        built = spec.build(
            _BuildArgs(
                client=client,
                key=config.api_key(name),
                name=name,
                pc=pc,
                snippet_chars=snippet_chars,
                text_chars=text_chars,
                cost=spec.cost(pc),
                timeout=max(policy_timeout, spec.timeout_floor),
            )
        )
        if built is not None:
            providers[name] = built
    return providers


async def build_fetch_stack(
    config: Config,
) -> tuple[HttpFetcher | None, list[ContentFetcher]]:
    """Build the local fetcher and its fallback ladder, when fetch is enabled.

    The fetcher owns its own client rather than the shared one: it must not
    follow redirects automatically, and it must never carry a provider API key
    to an arbitrary third-party site. Built only when fetch is enabled -- an
    off key must not cost the connection pool it would have saved, and the
    tool body refuses the call regardless.

    The ladder follows the order config names it, plus the primary route when
    `fetch.fallback` does not name it. Each fallback comes out of
    `fetcher.KNOWN_FALLBACKS`, whose row answers what it needs to exist -- a URL,
    a key, the permission set's leave (`config.PERMITTED_FETCH_NAMES` admits
    `jina`) -- so a fallback the set excludes or lacks its key is **not built**:
    no object is left that could fire, so nothing can bill. `cli._report_fetch`
    says so for every configured fallback, reading the same rows. A primary whose
    row answers `None` is the exception: `server.main` refuses that config
    outright, because substituting the local reader would read from this server's
    own IP against an explicit choice.

    A coroutine, and all-or-nothing, because those are the same requirement: the
    fetcher is built before the fallbacks are appended, and each fetcher owns its
    own client, so a constructor that raises would strand a built fetcher with no
    owner. Either a complete stack comes back, or everything built on the way is
    closed and the exception goes on.
    """
    if not config.fetch.enabled:
        return None, []
    fetcher: HttpFetcher | None = None
    fallbacks: list[ContentFetcher] = []
    try:
        fetcher = HttpFetcher(
            extractor=build_extractor(config),
            timeout=config.fetch.timeout_seconds,
            max_download_bytes=config.fetch.max_download_bytes,
            max_text_chars=config.fetch.max_text_chars,
            max_redirects=config.fetch.max_redirects,
            allow_private_addresses=config.fetch.allow_private_addresses,
            allow_images=config.fetch.allow_images,
            user_agent=config.fetch.user_agent,
        )
        # The ladder, plus the primary route if `fetch.fallback` does not already name
        # it: naming a primary is naming a provider this deployment runs, so making
        # the operator write the same name in two keys would only add a way for the
        # two to disagree. `FetchEngine._walk` takes the primary out of the walk, so
        # this changes which name leads, never what the ladder behind it holds.
        names = list(config.fetch.fallback or [])
        if config.fetch.primary != "http" and config.fetch.primary not in names:
            names.append(config.fetch.primary)
        for name in names:
            spec = KNOWN_FALLBACKS.get(name)
            if spec is None:
                # Defensive: `FetchConfig` already rejects a name outside the registry,
                # so reaching here means a Config built around validation rather than through it.
                raise ValueError(
                    f"unknown fetch fallback {name!r}; "
                    f"supported: {', '.join(sorted(KNOWN_FALLBACKS))}"
                )
            # What each fallback needs to exist -- a URL, a key, the permission set's leave -- is the row's own answer,
            # and `None` is "this deployment cannot run it", which is the same absent fallback the ladder has always had.
            fallback = spec.build(config)
            if fallback is not None:
                fallbacks.append(fallback)
    except BaseException:
        # `BaseException`, not `Exception`: a cleanup that runs only for the failures we thought of is the same leak, triggered
        # less. Reverse build order, so the ladder unwinds the way it was stacked.
        closers: list[ContentFetcher] = list(fallbacks)
        if fetcher is not None:
            closers.append(fetcher)
        for owner in reversed(closers):
            await owner.aclose()
        raise
    return fetcher, fallbacks
