"""The routing decisions: which provider answers, in what order, and what is said.

This module decides; `engine.py` executes. A caller hands it a routing *table*
-- the deployment's routing facts as plain strings and tuples -- plus the
request, and it answers with a name, an ordered plan of rungs, or the sentence
that refuses. Same inputs, same outputs: no I/O, no clock, no state, and it
imports **nothing** from `seekwright`, which is the seam a rewrite in another
language implements 1:1 with the engines as its clients. The table fields are
that future wire contract; serialising one is deliberately not defined yet.

What belongs here is *which*, *in what order*, and the routing-facing sentences
that explain an outcome: refusals, substitution notices, exhaustion notes, retry
menus. Dispatch, the health board, usage and logging stay in the engine, and so
does any notice that is about a result rather than a route -- the zero-results
diagnostic in `SearchEngine._compose_notice` is the example. The free-name
constants stay in `config.py`, the frozen vocabulary the validators read; they
arrive here as table fields rather than as an import.
"""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass
from enum import Enum
from typing import Literal


class RouteRefused(Exception):
    """A routing refusal decided before any dispatch; str(exc) is the model-facing sentence.

    The engine translates it into its own refused exception -- `SearchRefused` /
    `FetchRefused` -- because the REST projection reports those as 400: nothing
    was billed, and the caller can act on the sentence.
    """


class RungStatus(Enum):
    """Why a ladder entry is or is not a candidate, decided before any dispatch."""

    SKIP = "skip"  # tried already, or enabled-but-unbuilt: silent
    UNPERMITTED = "unpermitted"
    OPEN = "open"  # health breaker open
    CANDIDATE = "candidate"


@dataclass(frozen=True, slots=True)
class Rung:
    """One ladder entry with its status, in ladder order."""

    name: str
    status: RungStatus


@dataclass(frozen=True, slots=True)
class SearchTable:
    """The search routing facts of one deployment, read off live engine state.

    ``providers`` is what was *built*, ``effective`` is what may be *dispatched*
    (enabled ∩ permitted), and the two are not the same: a deployment can enable
    a name it could not build. The free-set questions read ``effective``, so a
    permission set that removes every free name empties the free walk rather
    than leaving it something to serve.
    """

    providers: tuple[str, ...]  # built adapters, dispatch order (dict order)
    default: str | None  # config default_provider
    permitted: tuple[str, ...] | None  # None = permissive
    fallback: tuple[str, ...]  # [search] fallback
    free_fallback: tuple[str, ...]  # [search] free_fallback; empty reads as unset
    free: frozenset[str]  # config.FREE_PROVIDERS: names that cannot bill
    free_order: tuple[str, ...]  # config.FREE_PROVIDER_ORDER
    effective: tuple[str, ...]  # enabled ∩ permitted (config.effective_providers)

    def is_permitted(self, name: str) -> bool:
        """Whether ``name`` may be dispatched to at all. Unset is permissive."""
        return self.permitted is None or name in self.permitted


@dataclass(frozen=True, slots=True)
class FetchTable:
    """The fetch routing facts: what was built, and which name leads.

    ``primary`` is ``None`` when the local reader leads, which is the shape the
    sentences need: "read the page locally" and "local fetch" are what a caller
    is offered when nothing remote leads the route.
    """

    built: tuple[str, ...]  # built fallback names, ladder order
    primary: str | None  # None = the local http reader leads


def unnamed_walks_free(table: SearchTable) -> bool:
    """Whether an unnamed search is served by the free walk, not the default.

    True only where the substitution cannot spend: no default configured
    *and* every reachable name free. A single enabled provider never
    reaches it -- config gives that one the default.

    Both halves read ``effective``, never ``providers``: "every *enabled*
    provider is free" is the rule, so a deployment that enabled a name it
    could not build still refuses.
    """
    return (
        table.default is None
        and bool(table.effective)
        and all(name in table.free for name in table.effective)
    )


def free_candidates(table: SearchTable) -> tuple[str, ...]:
    """The names a free walk considers, before any filter.

    ``search.free_fallback`` when the operator set one -- their order --
    else ``FREE_PROVIDER_ORDER``. An empty ``free_fallback`` reads as unset.
    """
    return table.free_fallback if table.free_fallback else table.free_order


def free_walk(table: SearchTable) -> tuple[str, ...]:
    """The fallbacks the free routes walk, in order, every one of them free.

    Serves both ``mode="free"`` and an unnamed all-free search: one walk, so
    the two routes cannot drift apart.

    Drops a fallback that is unbuilt or unpermitted. The free-set check is
    redundant with config validation on purpose: "never dispatch outside the
    free set" is this mode's whole promise, so it is a condition in the code.
    """
    return tuple(
        fallback
        for fallback in free_candidates(table)
        if fallback in table.providers
        and fallback in table.free
        and table.is_permitted(fallback)
    )


def _not_permitted(table: SearchTable, requested: str) -> str:
    """The refusal for a caller-named provider the allow-list excludes.

    The recovery clause offers the default only when one exists *and* is
    itself permitted: advice to omit ``provider`` when that retry would be
    refused for the same reason fails on the second call.
    """
    default = table.default
    recovery = (
        "Retry with one of those, or omit `provider` to use the default."
        if default is not None and table.is_permitted(default)
        else "Retry with one of those."
    )
    return (
        f"Provider {requested!r} is not permitted on this server. "
        f"Permitted: {', '.join(table.permitted or ())}. "
        f"{recovery}"
    )


def _default_not_permitted(table: SearchTable, default: str) -> str:
    """The refusal for a default the allow-list excludes.

    Never a reroute: raised in ``resolve_search``, before any ladder exists.
    """
    return (
        f"The default provider {default!r} is not permitted on this "
        f"server. Permitted: "
        f"{', '.join(table.permitted or ())}. "
        "Pass `provider` with one of those."
    )


def _resolve_free(table: SearchTable) -> str:
    """The free walk's first fallback, or a :class:`RouteRefused` naming the free set.

    A clean error rather than a disappearing tool, because the schema is
    frozen at import and cannot advertise what this deployment enabled.

    Two reasons empty the walk, and they must not read alike: nothing free
    is enabled, or the allow-list removes every free name that is. The
    second names the permission set, the key the operator has to fix.
    """
    walk = free_walk(table)
    if walk:
        return walk[0]
    enabled_free = [
        fallback
        for fallback in free_candidates(table)
        if fallback in table.providers and fallback in table.free
    ]
    if enabled_free:
        raise RouteRefused(
            "No permitted free provider is enabled on this server, so a "
            'mode="free" search has nothing to try. Permitted: '
            f"{', '.join(table.permitted or ())}. The "
            f"free providers are: {', '.join(sorted(table.free))}."
        )
    raise RouteRefused(
        "No free provider is enabled on this server, so a "
        'mode="free" search has nothing to try. The free providers '
        f"are: {', '.join(sorted(table.free))}."
    )


def resolve_search(
    table: SearchTable,
    requested: str | None,
    mode: Literal["free"] | None = None,
) -> str:
    """Pick the provider to call, or explain why the request can't be served.

    Nothing is inferred from the query. A named provider is terminal; an
    unnamed search takes ``default`` and may be walked by the free route.
    ``mode="free"`` resolves to the first fallback of the free walk and never
    consults ``default``: a paid default must not leak into a mode
    whose promise is a ceiling of zero.

    The allow-list is enforced after the enabled check and before the name is
    returned, so an unpermitted ``default`` is refused rather than silently
    served by the ladder configured behind it.
    """
    if mode is not None:
        return _resolve_free(table)
    enabled = ", ".join(table.providers) or "none"
    if requested is None:
        default = table.default
        if default is None:
            if unnamed_walks_free(table):
                # Same fallbacks, same order, same ending as `mode="free"` --
                # the mode's own walk, reached from the other direction.
                return _resolve_free(table)
            raise RouteRefused(
                "No default provider is configured; pass `provider`. "
                f"Available: {enabled}."
            )
        if not table.is_permitted(default):
            raise RouteRefused(_default_not_permitted(table, default))
        return default
    if requested not in table.providers:
        # Offer the default only when there is one; the other error is the recovery.
        recovery = (
            "Retry with one of those, or omit `provider` to use the default."
            if table.default is not None
            else "Retry with one of those."
        )
        raise RouteRefused(
            f"Provider {requested!r} is not enabled on this server. "
            f"Available: {enabled}. {recovery}"
        )
    if not table.is_permitted(requested):
        raise RouteRefused(_not_permitted(table, requested))
    return requested


def fallback_rungs(
    table: SearchTable,
    ladder: Sequence[str],
    tried: str,
    gated: frozenset[str],
) -> tuple[Rung, ...]:
    """One :class:`Rung` per ladder entry, in ladder order, before any dispatch.

    ``ladder`` is the caller's argument, not the table's field, because the two
    free routes pass their own: ``mode="free"`` and an unnamed all-free search
    walk ``free_walk``, which cannot contain a paid name. Statuses fall out in
    one order on purpose: tried/unbuilt before unpermitted before open, so the
    silent skip cannot steal the log line a permitted-but-gated name deserves.

    ``gated`` is the set whose breaker is open at walk time rather than a live
    board: a walk only writes the board for names it has attempted, and each
    name appears at most once, so nothing ahead of the walk can change under it.
    """
    rungs: list[Rung] = []
    for name in ladder:
        if name == tried or name not in table.providers:
            # Already tried, or enabled-but-unbuilt: skipped silently, like fetch's inert fallbacks.
            status = RungStatus.SKIP
        elif not table.is_permitted(name):
            # Dead config the operator should fix, unlike a gated name's ordinary skip.
            status = RungStatus.UNPERMITTED
        elif name in gated:
            status = RungStatus.OPEN
        else:
            status = RungStatus.CANDIDATE
        rungs.append(Rung(name=name, status=status))
    return tuple(rungs)


def fallback_served_notice(
    tried: str, original_reason: str, fallback: str, notice: str | None
) -> str:
    """The substitution sentence, with the fallback's own notice beside it."""
    served = f"{tried} failed ({original_reason}); served by {fallback} instead"
    return f"{served}; {notice}" if notice else served


def fallback_exhausted_note(failed: Sequence[str], mode: str | None) -> str:
    """What the failure sentence adds when every fallback lost.

    The failed names are what the caller could not see being tried; ``mode``
    adds the sentence saying why nothing paid was tried, because the model
    cannot see the walk.
    """
    fallbacks_note = f" Fallbacks also failed: {', '.join(failed)}." if failed else ""
    mode_note = (
        " The server was asked for a free-only search, so no paid "
        "provider was tried."
        if mode is not None
        else ""
    )
    return fallbacks_note + mode_note


def retry_advice(quota: bool) -> str:
    """Quota means retrying now is pointless; anything else may pass with time."""
    return (
        " Do not retry immediately."
        if quota
        else " Retry shortly or try a different phrasing."
    )


def fetch_walk(table: FetchTable) -> tuple[str, ...]:
    """The ladder the unnamed route walks: the built names minus the primary.

    The primary is out because the route already tried it; walking it twice
    would bill the same name twice.
    """
    return tuple(name for name in table.built if name != table.primary)


def origin(table: FetchTable) -> str:
    """The unnamed route's first attempt, as a sentence names it."""
    return "local fetch" if table.primary is None else table.primary


def provider_names(table: FetchTable) -> str:
    """The providers this server built, in ladder order.

    Built names, not configured ones: a caller can only be told to name
    something this server can serve. The `--check` rows are the other read --
    they come from ``fetch.fallback``, because that is where *why a configured
    name was not built* is reported.
    """
    return ", ".join(table.built)


def choose_names(table: FetchTable) -> str:
    """The names the withheld walk leaves over: the walk, never the primary."""
    return ", ".join(fetch_walk(table))


def choose_instead(table: FetchTable) -> str:
    """The failed read's recovery: the names to name, and one retry on one of them.

    The half of the deal the withheld walk pays for: the caller is handed the
    choice rather than having it taken. Its wording follows ``search``'s
    zero-results recovery, and it says nothing about *why* a name is missing
    -- that stays ``--check``'s report.

    With nothing left to walk there is no list, so this returns the empty
    string: a choice with no names in it is not a choice. The menu is the
    walk, never the primary -- the route that just failed is not to offer.
    """
    if not fetch_walk(table):
        return ""
    return (
        f" Other configured fetch providers: {choose_names(table)}. "
        "Retry once with `provider` set to one of those before concluding "
        "the page cannot be read."
    )


def not_enabled(table: FetchTable, requested: str) -> str:
    """The refusal sentence: the name it cannot serve, and the names it can.

    It states what *is* available, never *why* the named one is not:
    ``seekwright --check`` prints one row per configured name with what it is
    missing, and deployment inventory has no place in a model-facing sentence.
    The closing clause offers what omitting ``provider`` means -- the local
    read while the primary is ``http``, else the operator's chosen route. With
    nothing configured the middle clause says so rather than print an empty list.
    """
    listed = (
        f"Available: {provider_names(table)}."
        if table.built
        else "No other fetch provider is configured on this server."
    )
    omit = (
        "read the page locally"
        if table.primary is None
        else "use this server's default route"
    )
    return (
        f"Fetch provider {requested!r} is not enabled on this server. "
        f"{listed} Retry with one of those, or omit `provider` to {omit}."
    )


def empty_notice(table: FetchTable, walked: bool) -> str:
    """What a nearly-empty page reports, and what it offers in place of the walk.

    With the walk off the caller gets the choice and the diagnosis: a page
    that extracts to nothing needs a browser, not a second read by the same
    reader -- model-facing text over MCP, not only a JSON key. With the walk
    on the ladder already ran and said which name served, and with nothing
    configured there is no name to hand over; both keep the shorter sentence.
    """
    if walked or not fetch_walk(table):
        return (
            "almost no readable text could be extracted (the page may be "
            "JavaScript-rendered); try `search` for its content instead"
        )
    source = (
        "the local fetcher"
        if table.primary is None
        else f"`{table.primary}`"
    )
    return (
        f"Almost no readable text came back from {source}. Other "
        f"configured fetch providers: {choose_names(table)}. A page that "
        "extracts to nothing usually needs a browser, not a second try at "
        "the same reader: retry once with `provider` set to one of those "
        "before concluding the page has no text."
    )


def refetched_notice(table: FetchTable, reason: str, fallback_name: str) -> str:
    """The served-by-a-fallback sentence for a page, naming what failed first."""
    return f"{origin(table)} failed ({reason}); refetched via {fallback_name}"


def resolve_fetch(table: FetchTable, requested: str | None) -> str | None:
    """Route this page: ``None`` is the local read, a name is that provider.

    Three cases collapse into one refusal, the way ``resolve_search`` collapses
    its own: a name unknown to the fetch registry, one the registry has but
    this deployment never built for want of a key or URL, and one the
    permission set excluded. All three are refused before anything is
    dispatched, so nothing is billed and the sentence names what this server
    did build. A search-set name like ``serper`` is the first case.
    """
    if requested is None:
        return None
    if requested in table.built:
        return requested
    raise RouteRefused(not_enabled(table, requested))
