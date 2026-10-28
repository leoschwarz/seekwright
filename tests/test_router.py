"""The routing core, tested as the pure functions it is.

No engine and no config object: a routing table is the whole input, which is the
point of the seam -- what a rewrite in another language has to reproduce is these
answers, not the machinery that reads TOML to build a table. The same sentences
are pinned from the caller's side in `tests/test_engine.py` and `tests/fetch/`,
through the engine wrappers; the two files agree because both copy one router.

The tables here carry `config.FREE_PROVIDERS` and `FREE_PROVIDER_ORDER`, the way
`SearchEngine._table` does, so the free-vocabulary half of a sentence is checked
as a composition rather than by pinning the frozen set a second time.
"""

from __future__ import annotations

import ast
from dataclasses import replace
from pathlib import Path

import pytest

from seekwright.config import FREE_PROVIDER_ORDER, FREE_PROVIDERS
from seekwright.router import (
    FetchTable,
    RouteRefused,
    Rung,
    RungStatus,
    SearchTable,
    choose_instead,
    choose_names,
    empty_notice,
    fallback_exhausted_note,
    fallback_rungs,
    fallback_served_notice,
    fetch_walk,
    free_candidates,
    free_walk,
    origin,
    provider_names,
    refetched_notice,
    resolve_fetch,
    resolve_search,
    retry_advice,
    unnamed_walks_free,
)

ROUTER_SOURCE = Path(__file__).resolve().parents[1] / "src" / "seekwright" / "router.py"

# Everything a portable routing core is allowed to stand on. A new entry here is
# a new dependency in the module a compiled rewrite implements 1:1.
STDLIB_ROOTS = {"__future__", "collections", "dataclasses", "enum", "typing"}


def _table(
    *,
    providers: tuple[str, ...] = ("serper", "linkup"),
    default: str | None = "serper",
    permitted: tuple[str, ...] | None = None,
    fallback: tuple[str, ...] = (),
    free_fallback: tuple[str, ...] = (),
) -> SearchTable:
    """A search table with the boring facts filled in."""
    return SearchTable(
        providers=providers,
        default=default,
        permitted=permitted,
        fallback=fallback,
        free_fallback=free_fallback,
        free=FREE_PROVIDERS,
        free_order=FREE_PROVIDER_ORDER,
        effective=providers,
    )


def _fetch_table(
    *, built: tuple[str, ...] = ("crawl4ai", "scrappa"), primary: str | None = None
) -> FetchTable:
    return FetchTable(built=built, primary=primary)


class TestTheSeam:
    def test_the_module_imports_nothing_of_seekwright(self):
        """The extractable part of the seam: no config, no models, no logging.

        A rewrite that keeps these answers has to reimplement no seekwright type,
        which is only true while nothing here imports one.
        """
        offenders: list[str] = []
        for node in ast.parse(ROUTER_SOURCE.read_text()).body:
            match node:
                case ast.ImportFrom(level=level, module=module):
                    if level > 0 or (module or "").startswith("seekwright"):
                        offenders.append(f"from {module or '.'} import …")
                    if (module or "").split(".")[0] not in STDLIB_ROOTS:
                        offenders.append(f"non-stdlib import of {module}")
                case ast.Import(names=names):
                    for alias in names:
                        if alias.name.startswith("seekwright"):
                            offenders.append(f"import {alias.name}")
                        if alias.name.split(".")[0] not in STDLIB_ROOTS:
                            offenders.append(f"non-stdlib import of {alias.name}")
        assert offenders == [], f"the router reached outside the standard library: {offenders}"

    def test_a_table_is_a_value_and_equal_tables_interchange(self):
        """Frozen dataclasses, so a caller can hand the same facts to two calls."""
        one = _table(fallback=("linkup",))
        two = _table(fallback=("linkup",))
        assert one == two
        assert resolve_search(one, None) == resolve_search(two, None)
        assert fallback_rungs(one, one.fallback, "serper", frozenset()) == fallback_rungs(
            two, two.fallback, "serper", frozenset()
        )


class TestResolveSearch:
    def test_a_named_provider_is_answered_verbatim(self):
        assert resolve_search(_table(), "linkup") == "linkup"

    def test_an_unnamed_search_takes_the_default(self):
        assert resolve_search(_table(), None) == "serper"

    def test_no_default_with_a_paid_name_enabled_is_the_no_default_refusal(self):
        """The refusal in full: it lists what is built and tells the caller to choose."""
        table = _table(providers=("exa:free", "serper"), default=None)
        with pytest.raises(RouteRefused) as exc:
            resolve_search(table, None)
        assert str(exc.value) == (
            "No default provider is configured; pass `provider`. "
            "Available: exa:free, serper."
        )

    def test_no_default_with_an_unbuilt_paid_name_effective_still_refuses(self):
        """"Every *enabled* name is free" is the rule, so an enabled-but-unbuilt paid
        name keeps the refusal: the walk is not a bet on what failed to build."""
        table = replace(
            _table(providers=("exa:free",), default=None), effective=("exa:free", "serper")
        )
        with pytest.raises(RouteRefused, match="No default provider is configured"):
            resolve_search(table, None)

    def test_the_unknown_name_refusal_offers_the_default_only_when_there_is_one(self):
        built = ("serper", "tavily")
        with pytest.raises(RouteRefused) as exc:
            resolve_search(_table(providers=built, default="serper"), "linkup")
        assert str(exc.value) == (
            "Provider 'linkup' is not enabled on this server. Available: serper, "
            "tavily. Retry with one of those, or omit `provider` to use the default."
        )
        with pytest.raises(RouteRefused) as exc:
            resolve_search(_table(providers=built, default=None), "linkup")
        assert str(exc.value) == (
            "Provider 'linkup' is not enabled on this server. Available: serper, "
            "tavily. Retry with one of those."
        )

    def test_an_unnamed_search_on_an_all_free_deployment_walks_the_free_set(self):
        """No default and nothing that can bill: the refusal is replaced by the free
        walk's head, the same ending `mode="free"` reaches from the other direction."""
        table = _table(providers=("freeserp", "exa:free"), default=None)
        assert resolve_search(table, None) == "exa:free"

    def test_an_unknown_name_on_an_empty_deployment_says_none(self):
        with pytest.raises(RouteRefused) as exc:
            resolve_search(_table(providers=(), default=None), "serper")
        assert "Available: none." in str(exc.value)

    def test_an_unpermitted_name_is_refused_with_the_permitted_set(self):
        table = _table(default="linkup", permitted=("linkup",))
        with pytest.raises(RouteRefused) as exc:
            resolve_search(table, "serper")
        assert str(exc.value) == (
            "Provider 'serper' is not permitted on this server. Permitted: linkup. "
            "Retry with one of those, or omit `provider` to use the default."
        )

    def test_an_unpermitted_name_does_not_offer_a_default_it_would_refuse_again(self):
        """The recovery clause is only worth saying when the retry would work."""
        table = _table(default="serper", permitted=("linkup",))
        with pytest.raises(RouteRefused) as exc:
            resolve_search(table, "serper")
        assert str(exc.value) == (
            "Provider 'serper' is not permitted on this server. Permitted: linkup. "
            "Retry with one of those."
        )

    def test_an_unpermitted_default_is_refused_rather_than_walked_behind(self):
        table = _table(default="serper", permitted=("linkup",), fallback=("linkup",))
        with pytest.raises(RouteRefused) as exc:
            resolve_search(table, None)
        assert str(exc.value) == (
            "The default provider 'serper' is not permitted on this server. "
            "Permitted: linkup. Pass `provider` with one of those."
        )

    def test_mode_free_never_consults_the_default(self):
        """A paid default must not leak into a mode whose ceiling is zero."""
        table = _table(
            providers=("serper", "exa:free", "parallel:free"), default="serper"
        )
        assert resolve_search(table, None, "free") == "exa:free"

    def test_the_two_reasons_a_free_walk_is_empty_do_not_read_alike(self):
        """The permission set is the key an operator has to fix; nothing free enabled
        is a different deployment entirely."""
        permitted_table = _table(
            providers=("exa:free", "serper"), default=None, permitted=("serper",)
        )
        with pytest.raises(RouteRefused) as exc:
            resolve_search(permitted_table, None, "free")
        assert str(exc.value) == (
            "No permitted free provider is enabled on this server, so a "
            'mode="free" search has nothing to try. Permitted: serper. The '
            f"free providers are: {', '.join(sorted(FREE_PROVIDERS))}."
        )
        enabled_table = _table(providers=("serper",), default=None)
        with pytest.raises(RouteRefused) as exc:
            resolve_search(enabled_table, None, "free")
        assert str(exc.value) == (
            "No free provider is enabled on this server, so a "
            'mode="free" search has nothing to try. The free providers '
            f"are: {', '.join(sorted(FREE_PROVIDERS))}."
        )
        assert "No permitted free provider" not in str(exc.value)


class TestFreeRoute:
    def test_the_operators_order_wins_when_they_set_one(self):
        table = _table(
            providers=("parallel:free", "exa:free"),
            default="parallel:free",
            free_fallback=("parallel:free", "exa:free"),
        )
        assert free_candidates(table) == ("parallel:free", "exa:free")
        assert free_walk(table) == ("parallel:free", "exa:free")

    def test_an_empty_free_fallback_reads_as_unset(self):
        assert free_candidates(_table(free_fallback=())) == FREE_PROVIDER_ORDER

    def test_the_walk_drops_the_unbuilt_the_paid_and_the_unpermitted(self):
        table = _table(
            providers=("exa:free", "serper", "freeserp"),
            permitted=("exa:free", "serper"),
        )
        assert free_walk(table) == ("exa:free",)

    def test_unnamed_walks_free_is_a_truth_table(self):
        all_free = ("exa:free", "parallel:free", "freeserp")
        assert unnamed_walks_free(_table(providers=all_free, default=None)) is True
        assert (
            unnamed_walks_free(_table(providers=all_free, default="exa:free")) is False
        )
        assert (
            unnamed_walks_free(_table(providers=("exa:free", "serper"), default=None))
            is False
        )
        assert unnamed_walks_free(_table(providers=(), default=None)) is False

    def test_the_permission_set_narrows_the_walk_it_feeds(self):
        """`effective` is enabled ∩ permitted, so a set that removes every free name
        leaves the free route nothing to serve rather than something to refuse."""
        table = replace(
            _table(providers=("exa:free", "serper"), default=None, permitted=("serper",)),
            effective=("serper",),
        )
        assert unnamed_walks_free(table) is False


class TestFallbackRungs:
    def test_one_rung_per_ladder_entry_in_ladder_order(self):
        table = _table(providers=("a", "b", "tried"))
        rungs = fallback_rungs(
            table, ["a", "tried", "ghost", "b"], "tried", frozenset({"b"})
        )
        assert rungs == (
            Rung(name="a", status=RungStatus.CANDIDATE),
            Rung(name="tried", status=RungStatus.SKIP),
            Rung(name="ghost", status=RungStatus.SKIP),
            Rung(name="b", status=RungStatus.OPEN),
        )

    def test_the_permission_check_outranks_the_open_breaker(self):
        """An unpermitted rung is dead config the engine logs as a warning; a gated
        one is an ordinary skip. Reporting the breaker instead hides the config bug."""
        table = _table(providers=("linkup",), permitted=())
        (rung,) = fallback_rungs(table, ["linkup"], "serper", frozenset({"linkup"}))
        assert rung.status is RungStatus.UNPERMITTED

    def test_a_route_may_hand_the_walk_its_own_ladder(self):
        """`mode="free"` passes its own list; the table's `fallback` is not consulted."""
        table = _table(providers=("exa:free",), fallback=("serper",))
        rungs = fallback_rungs(table, ["exa:free"], "parallel:free", frozenset())
        assert rungs == (Rung(name="exa:free", status=RungStatus.CANDIDATE),)


class TestFallbackSentences:
    def test_the_served_notice_carries_the_adapters_own_notice_beside_it(self):
        assert fallback_served_notice("serper", "503", "linkup", None) == (
            "serper failed (503); served by linkup instead"
        )
        assert (
            fallback_served_notice("serper", "503", "linkup", "site filters ignored")
            == "serper failed (503); served by linkup instead; site filters ignored"
        )

    def test_exhaustion_names_the_failed_names_and_the_mode_promise(self):
        assert fallback_exhausted_note(["linkup", "tavily"], None) == (
            " Fallbacks also failed: linkup, tavily."
        )
        assert fallback_exhausted_note([], "free") == (
            " The server was asked for a free-only search, so no paid "
            "provider was tried."
        )
        assert fallback_exhausted_note(["tinyfish"], "free") == (
            " Fallbacks also failed: tinyfish. The server was asked for a "
            "free-only search, so no paid provider was tried."
        )
        assert fallback_exhausted_note([], None) == ""

    def test_retry_advice_splits_on_quota(self):
        assert retry_advice(True) == " Do not retry immediately."
        assert retry_advice(False) == " Retry shortly or try a different phrasing."


class TestFetchRoute:
    def test_nothing_named_is_the_local_read(self):
        assert resolve_fetch(_fetch_table(), None) is None

    def test_a_built_name_is_answered(self):
        assert resolve_fetch(_fetch_table(), "scrappa") == "scrappa"

    def test_a_name_this_deployment_did_not_build_is_refused_with_the_names_it_has(self):
        with pytest.raises(RouteRefused) as exc:
            resolve_fetch(_fetch_table(built=("jina",)), "scrappa")
        assert str(exc.value) == (
            "Fetch provider 'scrappa' is not enabled on this server. Available: "
            "jina. Retry with one of those, or omit `provider` to read the page locally."
        )

    def test_the_refusal_names_the_operators_route_when_a_primary_leads(self):
        table = _fetch_table(built=("scrappa",), primary="scrappa")
        with pytest.raises(RouteRefused) as exc:
            resolve_fetch(table, "crawl4ai")
        assert str(exc.value) == (
            "Fetch provider 'crawl4ai' is not enabled on this server. Available: "
            "scrappa. Retry with one of those, or omit `provider` to use this "
            "server's default route."
        )

    def test_the_refusal_says_nothing_is_configured_rather_than_print_an_empty_list(self):
        with pytest.raises(RouteRefused) as exc:
            resolve_fetch(_fetch_table(built=()), "scrappa")
        assert str(exc.value) == (
            "Fetch provider 'scrappa' is not enabled on this server. No other "
            "fetch provider is configured on this server. Retry with one of those, "
            "or omit `provider` to read the page locally."
        )

    def test_the_walk_excludes_the_primary_because_the_route_already_paid_for_it(self):
        assert fetch_walk(_fetch_table()) == ("crawl4ai", "scrappa")
        assert fetch_walk(_fetch_table(primary="crawl4ai")) == ("scrappa",)

    def test_the_menu_is_the_walk_never_the_primary(self):
        table = _fetch_table(primary="crawl4ai")
        assert provider_names(table) == "crawl4ai, scrappa"
        assert choose_names(table) == "scrappa"
        assert choose_instead(table) == (
            " Other configured fetch providers: scrappa. Retry once with "
            "`provider` set to one of those before concluding the page cannot "
            "be read."
        )

    def test_a_choice_with_no_names_in_it_is_not_a_choice(self):
        """Only the primary is built, so there is nothing left to offer."""
        assert choose_instead(_fetch_table(built=("scrappa",), primary="scrappa")) == ""

    def test_the_origin_is_the_local_reader_or_the_operators_primary(self):
        assert origin(_fetch_table()) == "local fetch"
        assert origin(_fetch_table(built=("scrappa",), primary="scrappa")) == "scrappa"

    def test_the_empty_page_notice_offers_the_menu_only_when_the_walk_is_withheld(self):
        short = (
            "almost no readable text could be extracted (the page may be "
            "JavaScript-rendered); try `search` for its content instead"
        )
        assert empty_notice(_fetch_table(), True) == short
        assert empty_notice(_fetch_table(built=()), False) == short
        assert empty_notice(_fetch_table(), False) == (
            "Almost no readable text came back from the local fetcher. Other "
            "configured fetch providers: crawl4ai, scrappa. A page that extracts "
            "to nothing usually needs a browser, not a second try at the same "
            "reader: retry once with `provider` set to one of those before "
            "concluding the page has no text."
        )

    def test_a_named_primary_is_named_back_in_the_notice(self):
        table = _fetch_table(built=("scrappa", "jina"), primary="scrappa")
        assert empty_notice(table, False).startswith(
            "Almost no readable text came back from `scrappa`."
        )

    def test_the_refetch_notice_names_the_route_that_failed_first(self):
        assert refetched_notice(_fetch_table(), "HTTP 403", "crawl4ai") == (
            "local fetch failed (HTTP 403); refetched via crawl4ai"
        )
        table = _fetch_table(built=("scrappa",), primary="scrappa")
        assert refetched_notice(table, "rate limited", "scrappa") == (
            "scrappa failed (rate limited); refetched via scrappa"
        )
