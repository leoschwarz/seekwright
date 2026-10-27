"""Configuration loading.

Secrets come from the environment only -- never a config file, because files get
committed. Non-secret policy lives in TOML, too structured for env vars and
readable with stdlib ``tomllib``.

Providers are opt-in: an install that searches a provider the operator never
asked for cannot bill them by surprise. The empty set is the install default
rather than an error, resolving to the keyless set (`exa:free`,
`parallel:free`, `freeserp`).
"""

from __future__ import annotations

import os
import tomllib
from pathlib import Path
from typing import Any, Literal

from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
    PrivateAttr,
    ValidationError,
    model_validator,
)

from . import DEFAULT_USER_AGENT
from .extractors.base import KNOWN_EXTRACTORS

DEFAULT_CONFIG_PATH = Path("~/.config/seekwright/config.toml")


class Section(BaseModel):
    """Base for every config model: an unknown key is an error, not a shrug.

    pydantic would silently ignore a typo like ``max_snipet_chars`` -- a setting
    that parses, loads and does nothing. ``extra="forbid"`` names it at startup,
    and ``load_config`` turns the ValidationError into a SystemExit naming the
    file, so the failure reads as a config problem rather than a crash.
    """

    model_config = ConfigDict(extra="forbid")


# A name is a bare backend (`exa`) or `backend:flavour`: its config table has to be
# quoted in TOML, and the API key comes from the backend segment alone, since `:`
# is not legal in a POSIX variable name (`api_key_env_var`).
KNOWN_PROVIDERS = frozenset(
    {
        "scrappa",
        "serper",
        "linkup",
        "exa",
        "exa:free",
        "parallel",
        "parallel:free",
        "searxng",
        "tavily",
        "tinyfish",
        "algolia",
        "freeserp",
        "search1api",
        "anysearch",
        "serpapi",
        "querit",
        "deepseek",
    }
)

# The only non-provider names ``permitted_providers`` holds: fetch fallbacks a
# declared set must be able to vouch for. ``jina`` is the keyless third party
# (allow-list.md, site 7).
PERMITTED_FETCH_NAMES = frozenset({"jina"})

# Not a lookup -- nothing resolves a provider through this.
# It exists so the startup error can name the replacement for a retired name.
RENAMED_PROVIDERS = {
    "exa_free": "exa:free",
    "parallel_free": "parallel:free",
}

# Keyless by nature: `exa:free`, `parallel:free`, `freeserp`; `searxng` is gated on
# a config `url` rather than a key. Why each other name is keyed is on its
# providers.md entry.
PROVIDERS_REQUIRING_KEY = frozenset(
    {
        "scrappa",
        "serper",
        "linkup",
        "exa",
        "parallel",
        "tavily",
        "tinyfish",
        "algolia",
        "search1api",
        "serpapi",
        "querit",
        "deepseek",
    }
)

# The names `search(mode="free")` may dispatch to: the ones that cannot bill
# whatever the caller holds. A metered free tier can bill, so it is out;
# `anysearch` is out by its explicit-only stance.
FREE_PROVIDERS = frozenset(
    {"exa:free", "parallel:free", "freeserp", "searxng", "tinyfish"}
)

# What a config that enables nothing resolves to: the free names an install can
# enable knowing nothing.
KEYLESS_PROVIDERS = ("exa:free", "parallel:free", "freeserp")

# Walk order for `mode="free"` and for an unnamed `search` on an all-free
# deployment -- the two routes use one walk. `search.free_fallback` narrows it.
FREE_PROVIDER_ORDER = (*KEYLESS_PROVIDERS, "searxng", "tinyfish")

# Shipped, but its live test has not run in-repo. A name leaves once it has and its
# docs/reference/providers.md entry says so; never a config key.
UNTESTED_PROVIDERS = frozenset({"search1api", "serpapi", "querit", "deepseek"})


def api_key_env_var(provider: str) -> str:
    """The environment variable holding ``provider``'s key.

    Named for the *backend* -- the segment before the first ``:`` -- because a
    key names the *account* and a flavour names the *route* through it. The whole
    name would ask for ``SEEKWRIGHT_EXA:FREE_API_KEY``, which cannot be exported:
    ``:`` is not legal in a POSIX variable name.

    Every site that names a variable goes through here, so the rule has one home.
    """
    return f"SEEKWRIGHT_{provider.split(':', 1)[0].upper()}_API_KEY"


def _renamed_hint(unknown: list[str]) -> str:
    """``; it is now "exa:free"`` for every name an earlier build shipped.

    Appended to the unknown-name errors below: a hard rename has no alias, so the
    replacement is the whole diagnostic. Empty when nothing was renamed.
    """
    hints = [
        f'it is now "{RENAMED_PROVIDERS[name]}"'
        for name in unknown
        if name in RENAMED_PROVIDERS
    ]
    return "; " + "; ".join(hints) if hints else ""


class ProviderConfig(Section):
    enabled: bool = True
    # Corrects the figure ``--check --live`` reports; nothing routes on it.
    cost_per_1k: float | None = None
    # Linkup only: `deep` is a ~10x cost cliff, so it stays operator policy.
    depth: str = "standard"
    # Linkup only: `sourcedAnswer` returns prose, `searchResults` a list.
    # `parallel` only: the preset decides the price, so a dearer mode needs `cost_per_1k` re-pinned with it.
    output_type: Literal["sourcedAnswer", "searchResults"] = "sourcedAnswer"
    # `parallel` only: the preset decides the price, so a dearer mode needs `cost_per_1k` re-pinned with it.
    mode: str = "fast"
    # Exa's endpoint override; for searxng, the required instance URL.
    url: str | None = None
    # `exa` only: how long to skip the free tier after it fails once. A guess --
    # Exa's real window has never been observed -- so an operator can correct it.
    free_cooldown_seconds: float = 60.0
    # Algolia only: `app_id` is a public identifier -- it names the {app_id}-dsn host -- not a credential;
    # the secret half is the search API key in the environment.
    app_id: str | None = None
    index: str | None = None
    # Algolia only: records are schemaless, so None falls back to a chain of common attribute names (docs/reference/providers.md).
    title_attr: str | None = None
    url_attr: str | None = None
    snippet_attr: str | None = None


class PolicyConfig(Section):
    """Per-deployment limits applied to every provider call."""

    # A proxy forwarding raw provider bodies is a tax on the caller's context.
    max_snippet_chars: int = 500
    # Content-tier extracts multiply by max_results, which the *model* picks --
    # uncapped, one Exa call measured 133k characters.
    max_result_text_chars: int = 2000
    provider_timeout_seconds: float = 10.0


class FetchConfig(Section):
    """Settings for the ``fetch`` tool.

    Top-level rather than an entry in ``[providers]`` on purpose. A fetcher has
    no API key, no cost per 1k and no name a caller can pin -- it is not one of
    the interchangeable things ``[providers]`` lists.
    """

    enabled: bool = True
    # One name per module in `extractors/`;
    # the supported set is KNOWN_EXTRACTORS, so a typo is a startup error rather than a silently ignored key.
    extractor: str = "trafilatura"
    # Its own knob: arbitrary sites are slower and flakier than paid APIs.
    timeout_seconds: float = 15.0
    # Memory guardrail against a hostile or runaway response, not a content
    # policy -- what bounds context is max_text_chars, and what bounds the
    # rendering of a JSON body is jsondoc's own ratio beside this cap.
    max_download_bytes: int = 8_388_608
    # ~10k tokens: a whole article, nowhere near a context window.
    max_text_chars: int = 40_000
    # Not zero: a JS-rendered page extracts to a nav stub, not the empty string (the incident is in
    # docs/reference/configuration.md). Raising it bills every page under the bar.
    min_text_chars: int = 200
    # Total budget of the passages a query-targeted `fetch` returns.
    max_match_chars: int = 6000
    # A page needing four hops is not a page worth reading.
    max_redirects: int = 3
    # Escape hatch for intranet fetches; off because the URL is model-supplied.
    allow_private_addresses: bool = False
    # Off on the same ground, and here on purpose: whether a stranger's pixels ever
    # reach a model is the operator's call, and a tool parameter cannot make it one.
    allow_images: bool = False
    user_agent: str = DEFAULT_USER_AGENT
    # Walk order, validated against `fetcher.KNOWN_FALLBACKS` by the validator below: at-most-once, and the billable fallback last.
    # Widened from a `Literal` of three names, which is why the value set is a registry read rather than a type written here.
    fallback: list[str] | None = None
    # Whether a failed or nearly-empty local read walks `fallback` by itself. Off: the
    # caller gets the sentence naming the providers to pass as `provider`, and the
    # `answer` plan is the one caller that asks for the walk per call. The tier rule
    # below still holds with it on.
    auto_fallback: bool = False
    # The route an unnamed fetch leads with. `http` is this server's own reader; a
    # fallback name drops the local read from the unnamed route entirely, so this
    # server's IP is not the one a page sees. Billable ones are admissible -- the same
    # choice `search.default_provider` allows -- and one this deployment cannot build
    # is startup-fatal rather than silently local.
    primary: str = "http"
    # Reporting only, like `ProviderConfig.cost_per_1k`, and on the same declared basis; the
    # builder hands it to the priced fallback, and `engine._fallback_cost_usd` reads the page's price off it.
    cost_per_1k: float | None = None
    # Absent means the crawl4ai fallback does not exist, whatever the ladder says.
    crawl4ai_url: str | None = None
    # The one credential allowed in the config file: it authenticates this
    # server to the internal service this same file names. Never logged.
    crawl4ai_token: str | None = None
    # A browser render waits longer than a static fetch; not a multiple of
    # timeout_seconds.
    crawl4ai_timeout_seconds: float = 60.0

    @model_validator(mode="after")
    def _validate_extractor(self) -> FetchConfig:
        if self.extractor not in KNOWN_EXTRACTORS:
            raise ValueError(
                f"fetch.extractor names unknown extractor {self.extractor!r}; "
                f"supported: {', '.join(sorted(KNOWN_EXTRACTORS))}"
            )
        return self

    @model_validator(mode="after")
    def _validate_fallback(self) -> FetchConfig:
        """The ladder's shape, read off the fallback registry rather than off a name.

        The last rule is the tier rule ``SearchConfig._validate_free_fallback``
        runs: it asks each row whether the fallback can bill, so "every free
        fallback before a credit is spent" holds for a name this build has never
        heard of, and a second priced fallback is refused here rather than
        reordering the ladder at fetch time.

        ``KNOWN_FALLBACKS`` is imported here and not at the top of the module: it
        lives in ``fetcher.py``, which reaches this one through ``providers/`` and
        ``logs.py``, so a module-level import would be a cycle.
        """
        from .fetcher import KNOWN_FALLBACKS

        fallbacks = self.fallback
        if not fallbacks:
            return self
        if len(set(fallbacks)) != len(fallbacks):
            raise ValueError(
                "fetch.fallback names a fallback more than once; each fallback gets "
                "one attempt per fetch"
            )
        unknown = sorted(set(fallbacks) - set(KNOWN_FALLBACKS))
        if unknown:
            raise ValueError(
                f"fetch.fallback names unknown fallback(s) {', '.join(unknown)}; "
                f"supported: {', '.join(sorted(KNOWN_FALLBACKS))}"
            )
        priced = sorted(name for name in fallbacks if KNOWN_FALLBACKS[name].billable)
        if priced and (len(priced) > 1 or fallbacks[-1] != priced[0]):
            raise ValueError(
                f"fetch.fallback: {', '.join(priced)} can bill and belongs "
                f"last, so a page reaches every free fallback before a credit is "
                "spent"
            )
        return self

    @model_validator(mode="after")
    def _validate_primary(self) -> FetchConfig:
        """The primary route's shape: a name, and no tier rule.

        The tier rule above governs the walk, not the route it leads, and the
        ladder behind a billable primary still keeps the billable fallback last.
        ``KNOWN_FALLBACKS`` plus the one ``"http"`` constant is the whole value
        set, so membership is all there is to check; it is imported here for the
        cycle reason the validator above gives.
        """
        from .fetcher import KNOWN_FALLBACKS

        if self.primary == "http" or self.primary in KNOWN_FALLBACKS:
            return self
        raise ValueError(
            f"fetch.primary names unknown route {self.primary!r}; supported: "
            f"http, {', '.join(sorted(KNOWN_FALLBACKS))}"
        )


class AgentConfig(Section):
    """Settings for the ``answer`` tool: one model call over a fixed plan.

    Off by default, and that default is the decision rather than a placeholder:
    turning it on is what creates this deployment's third-party egress point --
    the caller's query and the fetched page text leave for a model endpoint that
    is not a search provider -- so the state that sends nothing is the one an
    operator has to leave alone.

    ``base_url`` and ``model`` are required once ``enabled`` is true, and the key
    is ``SEEKWRIGHT_AGENT_API_KEY`` from the environment only, like every
    provider key. Which of the three is missing is reported by
    :meth:`Config.missing_agent_settings` rather than raised here, because
    ``--check`` has to print the same fact without dying.
    """

    enabled: bool = False
    # An OpenAI-compatible base; `/chat/completions` is appended to it.
    base_url: str | None = None
    # The one model. Operator config, never a tool parameter: it is the
    # operator's account and the operator's bill.
    model: str | None = None
    # The whole call, retrieval and pages included.
    timeout_seconds: float = 90.0
    # The model request alone, inside the whole-call budget.
    model_timeout_seconds: float = 30.0
    max_material_chars: int = 24000
    # The output ceiling per depth, sent as the endpoint's own output cap. The
    # spec's estimate is ~4 characters per token, so `brief` is ~2k characters.
    max_output_tokens_brief: int = 500
    max_output_tokens_report: int = 2500
    # Per-call abort. `None` leaves the structural bound -- the retrieval counts -- as the only ceiling;
    # this is the early exit for a mispriced provider.
    max_cost_usd: float | None = 0.25
    # Reporting only, in dollars per 1k *tokens* (a model's unit, not a call's);
    # unset records the model cost as unknown, never as 0.0.
    cost_per_1k_in: float | None = None
    cost_per_1k_out: float | None = None


class SearchConfig(Section):
    """Settings for the ``search`` tool's default route and provider health.

    The route that substitutes here is the *default* one only: a caller that
    names a provider keeps the terminal error, because a price named is a
    price paid.
    """

    # Walk order. Unlike fetch's fallbacks, a fallback that cannot run is a startup error here,
    # because the whole point is serving through an outage. `default_provider` may appear and is skipped as already tried.
    fallback: list[str] | None = None
    # Walk order, same shape as `fallback`, plus the rule that makes the mode honest: every name must be in `FREE_PROVIDERS`,
    # so a paid fallback is a startup error rather than a fallback the walk quietly declines.
    free_fallback: list[str] | None = None
    # 0.0 disables the periodic ping task; the breaker still works passively.
    health_interval_seconds: float = 60.0
    health_failure_threshold: int = 3
    health_cooldown_seconds: float = 120.0

    @model_validator(mode="after")
    def _validate_fallback(self) -> SearchConfig:
        fallbacks = self.fallback
        if not fallbacks:
            return self
        if len(set(fallbacks)) != len(fallbacks):
            raise ValueError(
                "search.fallback names a provider more than once; each fallback "
                "gets one attempt per search"
            )
        unknown = sorted(set(fallbacks) - KNOWN_PROVIDERS)
        if unknown:
            raise ValueError(
                f"search.fallback names unknown provider(s) "
                f"{', '.join(unknown)}{_renamed_hint(unknown)}; "
                f"supported: {', '.join(sorted(KNOWN_PROVIDERS))}"
            )
        return self

    @model_validator(mode="after")
    def _validate_free_fallback(self) -> SearchConfig:
        """The free ladder's extra rule: no fallback that can bill.

        A paid name here is not a fallback the walk would skip -- it is the
        mode's whole promise (a ceiling of zero) contradicted by config, so
        it fails at startup naming the offender rather than at the first
        search that needed a fallback.
        """
        fallbacks = self.free_fallback
        if not fallbacks:
            return self
        if len(set(fallbacks)) != len(fallbacks):
            raise ValueError(
                "search.free_fallback names a provider more than once; each "
                "fallback gets one attempt per free search"
            )
        unknown = sorted(set(fallbacks) - KNOWN_PROVIDERS)
        if unknown:
            raise ValueError(
                f"search.free_fallback names unknown provider(s) "
                f"{', '.join(unknown)}{_renamed_hint(unknown)}; supported: "
                f"{', '.join(sorted(KNOWN_PROVIDERS))}"
            )
        paid = sorted(set(fallbacks) - FREE_PROVIDERS)
        if paid:
            raise ValueError(
                f"search.free_fallback names {', '.join(paid)}, which can "
                f"bill; a free-only search walks only "
                f"{', '.join(sorted(FREE_PROVIDERS))}"
            )
        return self


LogLevel = Literal[
    "TRACE", "DEBUG", "INFO", "SUCCESS", "WARNING", "ERROR", "CRITICAL"
]


class LoggingConfig(Section):
    """What the operator sees. Everything goes to stderr -- see ``logs.py``."""

    level: LogLevel = "INFO"
    # Text serves stdio's human reader; a cluster sets json (container.md).
    format: Literal["text", "json"] = "text"
    # Holds the MCP SDK, uvicorn and httpx down separately from `level`.
    library_level: LogLevel = "WARNING"
    # Off: a health probe every ten seconds is 8,640 identical lines a day.
    access_log: bool = False
    # Opt-in: query text is the caller's. `qlen`/`qhash` answer the operational
    # questions without it. Covers fetched URLs too -- same sensitivity class.
    log_queries: bool = False
    # Separate from log_queries by volume, not sensitivity; with no cache this is the only chance to see what came back.
    log_content: bool = False


class DashboardConfig(Section):
    """The browser usage dashboard served under ``--http`` (see ``dashboard.py``).

    Reports aggregates only -- counts, money, timing and provider names -- never
    query text, URLs or content. It is a journal, not a spend ledger: a spend
    ceiling is declined, and one built later would read this journal.
    """

    # Rides the same no-auth listener as /mcp -- the bind address is the access
    # control, and the Host allowlist gates the page (server._guard).
    enabled: bool = True
    # Opt-in append-only usage journal (JSONL): full history across restarts.
    # Volume-mount it; nothing on the serving path ever reads it.
    history_path: str | None = None


class Config(Section):
    providers: dict[str, ProviderConfig] = Field(default_factory=dict)
    # With several enabled providers this stays unset: picking for the caller is cost-guessing.
    # A deployment where every enabled name is free walks the free set instead.
    default_provider: str | None = None
    # Unset is permissive; once declared it is deny-by-default: the effective set is `enabled ∩ permitted`. It bounds, never picks.
    # Not the Host allowlist (`--allowed-host`): docs/reference/allow-list.md.
    permitted_providers: list[str] | None = None
    policy: PolicyConfig = Field(default_factory=PolicyConfig)
    fetch: FetchConfig = Field(default_factory=FetchConfig)
    search: SearchConfig = Field(default_factory=SearchConfig)
    agent: AgentConfig = Field(default_factory=AgentConfig)
    logging: LoggingConfig = Field(default_factory=LoggingConfig)
    dashboard: DashboardConfig = Field(default_factory=DashboardConfig)
    # Set by `_validate_providers` when the config enabled nothing.
    # Private so that `providers_defaulted = true` in TOML cannot be a key that parses, loads and does nothing.
    _providers_defaulted: bool = PrivateAttr(default=False)

    @property
    def providers_defaulted(self) -> bool:
        """Whether ``providers`` is the implicit keyless set.

        True when the config enabled nothing and ``KEYLESS_PROVIDERS`` was put
        there in its place. The startup line and ``--check`` read it so the set
        is *said* rather than assumed: an empty set is the install default and
        not a fatal error, but that default is allowed to exist, never allowed
        to be silent.
        """
        return self._providers_defaulted

    @model_validator(mode="after")
    def _validate_providers(self) -> Config:
        unknown = sorted(set(self.providers) - KNOWN_PROVIDERS)
        if unknown:
            raise ValueError(
                f"unknown provider(s) {', '.join(unknown)}"
                f"{_renamed_hint(unknown)}; "
                f"supported: {', '.join(sorted(KNOWN_PROVIDERS))}"
            )
        if not self.enabled_providers():
            # Nothing enabled is the install default,
            # not an error: the keyless set asks the operator for nothing and has no credential to spend.
            self.providers = {
                name: ProviderConfig() for name in KEYLESS_PROVIDERS
            }
            self._providers_defaulted = True
        enabled = self.enabled_providers()
        searxng = self.providers.get("searxng")
        if searxng is not None and searxng.enabled and not searxng.url:
            raise ValueError(
                "provider 'searxng' is enabled but no url is configured; it "
                "has no public default"
            )
        algolia = self.providers.get("algolia")
        if (
            algolia is not None
            and algolia.enabled
            and not (algolia.app_id and algolia.index)
        ):
            raise ValueError(
                "provider 'algolia' is enabled but app_id and index are "
                "required; it searches one operator-named index"
            )
        if self.default_provider is not None and self.default_provider not in enabled:
            raise ValueError(
                f"default_provider {self.default_provider!r} is not an enabled "
                f"provider (enabled: {', '.join(enabled) or 'none'})"
            )
        if self.default_provider is None and len(enabled) == 1:
            self.default_provider = enabled[0]
        # The deliberate difference from fetch's fallbacks: there, a fallback without its prerequisite stays silently
        # absent and --check reports it; a dead-on-arrival fallback here would make the ladder theatre.
        for fallback in self.search.fallback or []:
            if fallback not in enabled:
                raise ValueError(
                    f"search.fallback names {fallback!r}, which is not an enabled "
                    f"provider (enabled: {', '.join(enabled) or 'none'})"
                )
        for fallback in self.search.free_fallback or []:
            if fallback not in enabled:
                raise ValueError(
                    f"search.free_fallback names {fallback!r}, which is not an "
                    f"enabled provider (enabled: {', '.join(enabled) or 'none'})"
                )
        return self

    def enabled_providers(self) -> list[str]:
        return sorted(name for name, pc in self.providers.items() if pc.enabled)

    def default_route_is_free_only(self) -> bool:
        """Whether an unnamed ``search`` may walk the free set instead of refusing.

        True only while every enabled provider is in ``FREE_PROVIDERS``, which is
        what makes the substitution unable to spend: the walk's ceiling is zero.
        One enabled name that can bill and this is False, and the refusal stands
        verbatim.

        Read by ``SearchEngine.resolve`` and by ``--check``'s `default` line, so
        the route the server takes and the one it reports cannot disagree. It
        reads :meth:`effective_providers`, so a permission set that removes every
        free name leaves this False -- nothing to walk.
        """
        effective = self.effective_providers()
        return bool(effective) and all(name in FREE_PROVIDERS for name in effective)

    @model_validator(mode="after")
    def _validate_permitted_providers(self) -> Config:
        """The allow-list's two errors, and its two silent readings.

        Unlike ``search.free_fallback``, a known but *not enabled* name is not an
        error: the effective set is the intersection, so one permission set can
        outlive turning providers on and off under it.
        ``PERMITTED_FETCH_NAMES`` is the fetch-only name it admits.

        A list containing ``"*"`` reads as unset, and nothing else in it is
        validated: "*" is not a provider name and "everything" is the same list
        as no list. Normalising to ``None`` here gives "unset is permissive" one
        home -- every site below reads the field.
        """
        declared = self.permitted_providers
        if declared is None or "*" in declared:
            self.permitted_providers = None
            return self
        # An explicitly empty list is a *declared* set with no members, so it refuses everything: `[]` is not the absent key.
        if len(set(declared)) != len(declared):
            raise ValueError(
                "permitted_providers names a provider more than once; each "
                "name gets one entry"
            )
        unknown = sorted(set(declared) - KNOWN_PROVIDERS - PERMITTED_FETCH_NAMES)
        if unknown:
            raise ValueError(
                f"permitted_providers names unknown provider(s) "
                f"{', '.join(unknown)}{_renamed_hint(unknown)}; supported: "
                f"{', '.join(sorted(KNOWN_PROVIDERS | PERMITTED_FETCH_NAMES))}"
            )
        return self

    def effective_providers(self) -> list[str]:
        """The names this deployment may actually dispatch to: ``enabled ∩ permitted``.

        Membership in the allow-list never enables anything, so a permitted
        name with no ``[providers.<name>]`` table is not here. Unset is the
        whole enabled set -- this is the one home for "unset is permissive",
        and no dispatch site re-derives it.
        """
        enabled = self.enabled_providers()
        if self.permitted_providers is None:
            return enabled
        return [name for name in enabled if name in self.permitted_providers]

    def is_permitted(self, name: str) -> bool:
        """Whether ``name`` may be dispatched to at all. Unset is permissive.

        Asked *after* the enabled question, never instead of it: a name outside
        the set is refused before dispatch, while a name inside it that is not
        enabled still fails the startup check it fails today.
        """
        return self.permitted_providers is None or name in self.permitted_providers

    def api_key(self, provider: str) -> str | None:
        """The key for ``provider``, read from its backend's variable.

        The variable is named by :func:`api_key_env_var`, which holds the rule
        and the reason for it: a key names the *account*, a flavour names the
        *route* through it, and ``:`` is not legal in a POSIX variable name, so
        the variable is derived from the backend segment alone.
        """
        return os.environ.get(api_key_env_var(provider)) or None

    def missing_api_keys(self) -> list[str]:
        """Enabled providers whose API key is absent from the environment.

        Reported rather than raised, so ``server.main`` refuses to start while
        ``--check`` prints the same fact and keeps going.
        """
        return [
            name
            for name in self.enabled_providers()
            if name in PROVIDERS_REQUIRING_KEY and not self.api_key(name)
        ]

    def agent_api_key(self) -> str | None:
        """The model endpoint's key, from the environment only, like every key.

        Not ``SEEKWRIGHT_<provider>_API_KEY`` because the model is not a
        provider: not searchable, not pinnable, not one of the interchangeable
        things ``[providers]`` lists.
        """
        return os.environ.get("SEEKWRIGHT_AGENT_API_KEY") or None

    def missing_agent_settings(self) -> list[str]:
        """What ``[agent] enabled = true`` needs and does not have, by name.

        Reported rather than raised for the reason ``missing_api_keys`` is, and
        read by both entry points so they cannot disagree about "configured".
        """
        if not self.agent.enabled:
            return []
        return [
            name
            for name, value in (
                ("agent.base_url", self.agent.base_url),
                ("agent.model", self.agent.model),
                ("SEEKWRIGHT_AGENT_API_KEY", self.agent_api_key()),
            )
            if not value
        ]


def config_path(path: str | Path | None = None) -> Path:
    return Path(
        path or os.environ.get("SEEKWRIGHT_CONFIG") or DEFAULT_CONFIG_PATH
    ).expanduser()


# Shown to an operator whose file named something this build could not build: keyless,
# so it needs no export line, and written in the quoted form a flavoured table requires.
EXAMPLE_CONFIG = """\
[providers."exa:free"]
enabled = true

[providers."parallel:free"]
enabled = true
"""


def load_config(path: str | Path | None = None) -> Config:
    """Load configuration, failing loudly on a malformed one.

    A stdio server that dies silently is miserable to debug, so a bad config
    raises with the offending path named rather than falling back to defaults.
    A config that enables *nothing* is not bad: it resolves to the keyless set,
    which is what makes the first tier reachable without writing config first,
    and the startup line names that set so the default is never silent.
    """
    candidate = config_path(path)

    raw: dict[str, Any] = {}
    if candidate.is_file():
        try:
            raw = tomllib.loads(candidate.read_text())
        except tomllib.TOMLDecodeError as exc:
            raise SystemExit(f"seekwright: invalid TOML in {candidate}: {exc}")

    try:
        cfg = Config.model_validate(raw)
    except (ValidationError, ValueError) as exc:
        # The message names the file and the fault; it never claims the config was empty, because an empty one is no longer a fault.
        hint = (
            f"\n\nA config that needs no API key:\n\n{EXAMPLE_CONFIG}"
            if raw.get("providers")
            else ""
        )
        raise SystemExit(f"seekwright: invalid config in {candidate}: {exc}{hint}")
    return cfg
