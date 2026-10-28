"""Search and fetch orchestration, kept out of the MCP layer so it is testable.

No cache: both engines ask `router` which name to call and in what order, call
it, record the outcome, and turn a provider exception into a message a model can
act on.
"""

from __future__ import annotations

import base64
import time
from datetime import UTC, datetime
from typing import TYPE_CHECKING, Literal, Never

from . import router
from .config import FREE_PROVIDER_ORDER, FREE_PROVIDERS, Config
from .extractors.base import select_passages
from .fetcher import (
    UNCAPPED,
    ContentFetcher,
    FetchBlocked,
    FetchedImage,
    FetchedPage,
    UrlBlocked,
)
from .health import HealthBoard
from .jsondoc import PathSyntax, parse_path, select_paths
from .logs import bind, elapsed_ms, host_of, query_fields, result_fields, safe
from .models import (
    FetchImage,
    FetchMatch,
    FetchResponse,
    ProviderResult,
    SearchQuery,
    SearchResponse,
)
from .providers.base import ProviderError, QuotaExhausted, SearchProvider
from .sanitize import sanitize_model, sanitize_text

if TYPE_CHECKING:
    from loguru import Logger

    from .usage import UsageRecorder


class SearchFailed(Exception):
    """No result could be produced."""


class SearchRefused(SearchFailed):
    """Refused before any provider was dispatched: nothing billed, caller can act.

    That is the difference the REST projection reports as 400 rather than 502;
    the MCP tool catches :class:`SearchFailed` and is unchanged by it.
    """


class FetchFailed(Exception):
    """A page could not be produced."""


class FetchRefused(FetchFailed):
    """Refused before a page was fetched: contradictory parameters, or a URL guardrail.

    Both are the caller's to fix and neither sent a request. Caught as
    :class:`FetchFailed` by the MCP tool, so the tool is unchanged.
    """


def _now() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds")


class SearchEngine:
    """Dispatch a query to a named provider, or to a declared class of them.

    A named provider is terminal. An unnamed search takes ``default_provider``
    and walks ``search.fallback`` when that fails. ``mode="free"`` is served
    only by providers that cannot bill, and fails rather than escalating.
    Where no default is configured and every reachable name is free, the unnamed
    route walks that free set instead of refusing: there is no price to guess
    at, and one enabled name that can bill restores the refusal verbatim.
    """

    def __init__(
        self,
        config: Config,
        providers: dict[str, SearchProvider],
        health: HealthBoard | None = None,
        usage: UsageRecorder | None = None,
    ) -> None:
        self.config = config
        self.providers = providers
        # A fresh board when none is given (tests, --check); the server passes the
        # shared one so engine and health monitor agree on who is up.
        self.health = health if health is not None else HealthBoard()
        # `None` counts nothing.
        self.usage = usage

    def resolve(
        self, requested: str | None, mode: Literal["free"] | None = None
    ) -> str:
        """Pick the provider to call, or explain why the request can't be served.

        Nothing is inferred from the query. See the class docstring for the route
        rules; every refusal here is :class:`SearchRefused`, raised before any
        dispatch, so nothing was billed.

        ``mode="free"`` resolves to the first fallback of the free walk and never
        consults ``default_provider``: a paid default must not leak into a mode
        whose promise is a ceiling of zero.

        The allow-list is enforced after the enabled check and before the name is
        returned, so an unpermitted ``default_provider`` is refused rather than
        silently served by the ladder configured behind it.
        """
        try:
            return router.resolve_search(self._table, requested, mode)
        except router.RouteRefused as refusal:
            raise SearchRefused(str(refusal)) from None

    @property
    def _table(self) -> router.SearchTable:
        """The routing facts this engine holds *now*, rebuilt on every read.

        Never cached in ``__init__``: ``providers`` and ``config`` are public
        attributes a caller may swap after construction, and a route has to
        come from what the engine holds at the moment it routes. The table is
        plain strings and tuples so that ``router.py`` can read a deployment
        without importing one.
        """
        permitted = self.config.permitted_providers
        return router.SearchTable(
            providers=tuple(self.providers),
            default=self.config.default_provider,
            permitted=None if permitted is None else tuple(permitted),
            fallback=tuple(self.config.search.fallback or ()),
            free_fallback=tuple(self.config.search.free_fallback or ()),
            free=FREE_PROVIDERS,
            free_order=FREE_PROVIDER_ORDER,
            effective=tuple(self.config.effective_providers()),
        )

    async def search(
        self,
        q: SearchQuery,
        *,
        provider: str | None = None,
        mode: Literal["free"] | None = None,
        run: str | None = None,
        step: int | None = None,
    ) -> SearchResponse:
        """Dispatch one query, recording it on the journal and the health board.

        ``run``/``step`` tag this call as one retrieval step of an `answer` call,
        so the journal can tie a provider's results to whether they were cited.
        Absent rather than null on a plain ``search`` line -- the shape the
        journal's readers already parse.
        """
        if provider is not None and mode is not None:
            # Two ways to name a route hides a precedence rule, so neither wins;
            # a refusal (400) not a failure (502), since nothing was billed.
            raise SearchRefused("pass `provider` or `mode`, not both")
        free = mode is not None
        # Both free routes resolve through `router.free_walk` rather than growing a second walk.
        table = self._table
        walking_free = free or (provider is None and router.unnamed_walks_free(table))
        # Resolved once: the first attempt and the fallbacks walked behind it must
        # come from the same list, or a fallback could be tried twice.
        fallbacks = list(router.free_walk(table)) if walking_free else None
        name = self._resolve_or_reject(provider, mode)
        # `provider` stays the first attempt for every event of this call; a
        # substitute is named by `search.fallback` and by the response's `provider`.
        log = bind(
            provider=name,
            max_results=q.max_results,
            **query_fields(self.config.logging, q.query),
        )
        started = time.monotonic()
        fell_back = False
        try:
            result = await self._call(name, q)
        except ProviderError as exc:
            if walking_free:
                # `fallbacks` is the free walk, so this cannot reach a paid name.
                result = await self._walk_fallbacks(
                    name, q, exc, log, started, fallbacks=fallbacks, mode=mode,
                    run=run, step=step,
                )
                fell_back = True
            elif provider is None and self.config.search.fallback:
                result = await self._walk_fallbacks(
                    name, q, exc, log, started, run=run, step=step
                )
                fell_back = True
            else:
                log.bind(
                    ms=elapsed_ms(started),
                    kind=type(exc).__name__,
                    reason=exc.message,
                    retryable=exc.retryable,
                ).warning("search.failed")
                self._record_failure(
                    provider=name,
                    ms=elapsed_ms(started),
                    fell_back=False,
                    error=type(exc).__name__,
                    run=run,
                    step=step,
                )
                raise SearchFailed(
                    f"Search failed - {exc}.{router.retry_advice(isinstance(exc, QuotaExhausted))}"
                ) from exc
        notice = self._compose_notice(result, result.provider)
        # Escaped once: the decision line, the content log and the agent's
        # retrieval material all read this one escaped object.
        sanitized = sanitize_model(result)
        log = self._log_ok(
            log,
            result,
            notice,
            started,
            fell_back=fell_back,
            mode=mode,
            sanitized=sanitized,
        )
        self._log_caps(log, result)
        if self.usage is not None:
            self.usage.record_search(
                provider=result.provider,
                ms=elapsed_ms(started),
                cost_usd=float(result.cost_usd or 0.0),
                results=len(result.results),
                fell_back=fell_back,
                run=run,
                step=step,
            )
        self._log_content(log, result)
        return SearchResponse(
            query=q.query,
            provider=result.provider,
            results=result.results,
            answer=result.answer,
            retrieved_at=_now(),
            notice=notice,
        )

    def _resolve_or_reject(
        self, requested: str | None, mode: Literal["free"] | None = None
    ) -> str:
        """Resolve, or log search.rejected for the operator and re-raise.

        ``permitted`` sits beside ``enabled`` so the operator's line tells the
        two refusals apart: a name this deployment does not serve, and one it
        will not dispatch.
        """
        try:
            name = self.resolve(requested, mode)
        except SearchFailed:
            bind(
                requested=safe(requested, 40),
                # Bound whatever it is, like `mode` on search.ok: otherwise a
                # rejection for `mode="free"` is indistinguishable from none.
                mode=mode,
                enabled=",".join(self.providers),
                permitted=",".join(self.config.permitted_providers or []) or None,
            ).warning("search.rejected")
            raise
        return name

    def _record_failure(
        self,
        *,
        provider: str,
        ms: int,
        fell_back: bool,
        error: str,
        run: str | None = None,
        step: int | None = None,
    ) -> None:
        """Record a terminal search failure: nothing was billed, class named."""
        if self.usage is not None:
            self.usage.record_search(
                provider=provider,
                ms=ms,
                cost_usd=0.0,
                results=0,
                fell_back=fell_back,
                error=error,
                run=run,
                step=step,
            )

    async def _call(self, name: str, q: SearchQuery) -> ProviderResult:
        """Call one provider, recording the outcome on the health board.

        Recorded on *every* dispatch, a named provider included: the board
        describes the provider; substitution is a separate question. A named
        failure still raises, and still counts.
        """
        try:
            result = await self.providers[name].search(q)
        except ProviderError as exc:
            # exc.message, never exc: the exception may carry request headers.
            self.health.record_failure(name, reason=exc.message)
            raise
        self.health.record_success(name, reason="search succeeded")
        return result

    async def _walk_fallbacks(
        self,
        tried: str,
        q: SearchQuery,
        original: ProviderError,
        log: Logger,
        started: float,
        *,
        fallbacks: list[str] | None = None,
        mode: Literal["free"] | None = None,
        run: str | None = None,
        step: int | None = None,
    ) -> ProviderResult:
        """Walk a ladder in walk order; the first result wins.

        The default route's ladder is ``search.fallback``; ``mode="free"`` passes
        its own ``fallbacks`` from ``router.free_walk``, which cannot contain a paid
        name. Each fallback at most once; the tried, unpermitted and open-circuit
        ones are skipped. When every fallback fails the ORIGINAL error raises,
        with the failed fallbacks appended: "serper: rate limited" explains the
        search asked for, a linkup error does not. ``mode`` adds the sentence
        saying why nothing paid was tried.
        """
        failed: list[str] = []
        table = self._table
        ladder = table.fallback if fallbacks is None else fallbacks
        # Who is gated, snapshotted once: the walk records the board only for names it
        # attempts, and each name appears at most once, so a rung ahead of the walk
        # cannot change state under it.
        gated = frozenset(name for name in ladder if self.health.is_open(name))
        for rung in router.fallback_rungs(table, ladder, tried, gated):
            fallback = rung.name
            if rung.status is router.RungStatus.SKIP:
                continue
            if rung.status is router.RungStatus.UNPERMITTED:
                # Warning rather than info, unlike the open-circuit skip below: a
                # gated fallback is dead config the operator should fix.
                log.bind(
                    fallback=fallback,
                    permitted=",".join(self.config.permitted_providers or []),
                ).warning("search.fallback_unpermitted")
                continue
            if rung.status is router.RungStatus.OPEN:
                log.bind(
                    fallback=fallback, until_s=round(self.health.open_for_s(fallback), 1)
                ).info("search.fallback_skipped")
                continue
            fallback_started = time.monotonic()
            try:
                result = await self._call(fallback, q)  # records into the board too
            except ProviderError as exc:
                log.bind(
                    fallback=fallback,
                    reason=exc.message,
                    original_reason=original.message,
                    ms=elapsed_ms(fallback_started),
                ).warning("search.fallback_failed")
                failed.append(fallback)
                continue
            log.bind(
                fallback=fallback, reason=original.message, ms=elapsed_ms(fallback_started)
            ).info("search.fallback")
            result = result.model_copy(
                update={
                    "notice": router.fallback_served_notice(
                        tried, original.message, fallback, result.notice
                    )
                }
            )
            return result
        log.bind(
            ms=elapsed_ms(started),
            kind=type(original).__name__,
            reason=original.message,
            retryable=original.retryable,
        ).warning("search.failed")
        self._record_failure(
            provider=tried,
            ms=elapsed_ms(started),
            fell_back=True,
            error=type(original).__name__,
            run=run,
            step=step,
        )
        raise SearchFailed(
            f"Search failed - {original}.{router.fallback_exhausted_note(failed, mode)}"
            f"{router.retry_advice(isinstance(original, QuotaExhausted))}"
        ) from original

    def _compose_notice(self, result: ProviderResult, name: str) -> str | None:
        """Join the adapter's notice with the zero-results diagnostic; either alone.

        The diagnostic fires on an empty response only -- a nag on every response
        would bury the one that matters -- and names the other enabled providers
        so flaky and truly-empty are told apart."""
        notice = result.notice
        if not result.results and result.answer is None:
            others = [n for n in self.providers if n != name]
            detail = (
                f"No results from {name}."
                + (
                    f" Other enabled providers: {', '.join(others)}."
                    if others
                    else f" {name} is the only enabled provider."
                )
                + " Zero results usually means the phrasing, not an empty web:"
                " retry once on a different provider or rephrase before"
                " concluding the answer does not exist."
            )
            notice = f"{notice}; {detail}" if notice else detail
        return notice

    def _log_ok(
        self,
        log: Logger,
        result: ProviderResult,
        notice: str | None,
        started: float,
        *,
        fell_back: bool,
        mode: Literal["free"] | None,
        sanitized: int,
    ) -> Logger:
        """Emit search.ok: the one line an operator aggregates on, fixed shape.

        cost_usd stays off SearchResponse -- the caller is not the party paying --
        and lands here; reported_cost_usd binds only when upstream reported
        usage, so its absence is meaningful and the diff of the two is the drift
        check. `fell_back` and `mode` are always bound, mirroring fetch.ok, so
        the field set is the same whatever the route. `sanitized` is the count
        of special-token literals escaped on the way out: 0 on the common path,
        a count rather than content, like everything on this line.

        Returns the logger so later content events carry the same bound fields.
        """
        if result._reported_cost_usd is not None:
            log = log.bind(reported_cost_usd=result._reported_cost_usd)
        log.bind(
            ms=elapsed_ms(started),
            results=len(result.results),
            cost_usd=result.cost_usd,
            answer=result.answer is not None,
            notice=notice,
            fell_back=fell_back,
            mode=mode,
            sanitized=sanitized,
        ).info("search.ok")
        return log

    def _log_content(self, log: Logger, result: ProviderResult) -> None:
        """Emit search.result per hit and search.answer for the prose.

        Content rides its own events so search.ok keeps a fixed shape, and one
        record bounds one hit rather than letting max_results set line length."""
        if not self.config.logging.log_content:
            return
        for rank, item in enumerate(result.results, 1):
            log.bind(
                **result_fields(
                    item,
                    rank,
                    snippet_chars=self.config.policy.max_snippet_chars,
                    text_chars=self.config.policy.max_result_text_chars,
                )
            ).info("search.result")
        if result.answer is not None:
            log.bind(
                answer=safe(result.answer, self.config.policy.max_result_text_chars)
            ).info("search.answer")

    def _log_caps(self, log: Logger, result: ProviderResult) -> None:
        """Emit search.cap per hit: the length the policy cap discarded.

        A measurement aid, not a cap change. `max_snippet_chars` and
        `max_result_text_chars` are applied inside the adapter, so a recorded
        round cannot tell two settings apart. This event carries ``uncapped_chars``
        (the length the clip received) and ``chars`` (what the caller got), which
        lets an operator compute over real traffic how often a cap bites and by
        how much. It sits *beside* the clipped value, never inside it.

        Counts only, never on `search.ok`: no text, no URL, no title, so the line
        cannot grow with `max_results`, and the aggregate keeps its field set.
        One event per hit, so the record is a distribution.

        Unconditional, unlike `_log_content`: these are counts, not caller
        content, and running it only under content logging would not measure the
        default deployment. A hit with no capped field is skipped, so the
        population is "hits that carried a snippet or an extract".
        """
        policy = self.config.policy
        for rank, item in enumerate(result.results, 1):
            uncapped = item._uncapped_chars
            if uncapped is None:
                continue
            # A result carries `snippet` or `text`, never both (AGENTS.md), so
            # which one is set names the cap that applied.
            if item.snippet is not None:
                field, cap, chars = (
                    "snippet",
                    policy.max_snippet_chars,
                    len(item.snippet),
                )
            else:
                field, cap, chars = (
                    "text",
                    policy.max_result_text_chars,
                    len(item.text or ""),
                )
            log.bind(
                rank=rank,
                field=field,
                cap=cap,
                chars=chars,
                uncapped_chars=uncapped,
            ).info("search.cap")


class FetchEngine:
    """Page fetching: the primary route first, then a ladder of fallbacks.

    The primary is this server's own reader unless ``fetch.primary`` named a built
    fallback, in which case that fallback leads and the local read is out of the
    unnamed route entirely. The ladder is ``fallbacks`` in config order -- free
    renderer, then paid scraper -- and the order is the whole policy: each
    fallback runs at most once and the paid one last. A caller that names a
    provider is served by that fallback alone; ``resolve`` answers a name that
    cannot serve with the names this server did build.

    The unnamed route walks the ladder minus its primary, and only where the
    route asked for the walk. ``fetch.auto_fallback`` is off, so MCP, REST and CLI
    reads stop at the primary and name the ladder as a choice; the `answer` plan
    passes ``auto_fallback=True``, because a refusal between its steps is a lost
    page rather than a decision someone is there to make.
    """

    def __init__(
        self,
        config: Config,
        fetcher: ContentFetcher,
        fallbacks: list[ContentFetcher] | None = None,
        usage: UsageRecorder | None = None,
    ) -> None:
        self.config = config
        self.fetcher = fetcher
        self.fallbacks = fallbacks or []
        # When a fallback leads the unnamed route the local read is out of it
        # entirely: the operator who set it is saying this server's own IP should
        # not be what the page sees. Membership is checked here; the object is
        # resolved lazily below, so a caller that swaps `engine.fetcher` or
        # `engine.fallbacks` after construction gets a route from what it holds now.
        if config.fetch.primary != "http" and all(
            fallback.name != config.fetch.primary for fallback in self.fallbacks
        ):
            # server.main's pre-flight refuses this config before an engine is
            # built; falling back to the local reader would dial from this
            # server's own IP against the operator's config.
            raise self._unbuilt_primary()
        # `None` counts nothing.
        self.usage = usage

    @property
    def _primary(self) -> ContentFetcher:
        """The unnamed route's first attempt: the local reader, or the named fallback."""
        if self._primary_name is None:
            return self.fetcher
        for fallback in self.fallbacks:
            if fallback.name == self.config.fetch.primary:
                return fallback
        raise self._unbuilt_primary()

    @property
    def _primary_name(self) -> str | None:
        """The primary's journal name; ``None`` when the local reader leads."""
        return (
            None if self.config.fetch.primary == "http" else self.config.fetch.primary
        )

    def _unbuilt_primary(self) -> ValueError:
        """The one sentence for a primary this deployment did not build."""
        return ValueError(
            f"fetch.primary names {self.config.fetch.primary!r}, which this "
            "deployment did not build"
        )

    @property
    def _walk(self) -> list[ContentFetcher]:
        """The ladder the unnamed route walks: the built fallbacks minus the primary.

        Computed rather than stored, so a swap of ``engine.fallbacks`` is
        honoured. The primary is skipped because the route already tried it;
        walking it twice would bill the same name twice. It is taken out by name
        rather than by object identity because a built ladder holds one object
        per name: config dedupes ``fetch.fallback``, and `factory` appends the
        primary to the stack only when it is absent from it.
        """
        walked = frozenset(router.fetch_walk(self._table))
        return [f for f in self.fallbacks if f.name in walked]

    @property
    def _table(self) -> router.FetchTable:
        """The fetch routing facts this engine holds *now*, rebuilt on every read.

        Not built in ``__init__``, for the reason that constructor states: a
        caller that swaps ``engine.fetcher`` or ``engine.fallbacks`` afterwards
        gets a route from what the engine holds now.
        """
        return router.FetchTable(
            built=tuple(f.name for f in self.fallbacks), primary=self._primary_name
        )

    def resolve(self, requested: str | None) -> ContentFetcher | None:
        """Route this page: ``None`` is the local read, a name is that provider.

        Three cases collapse into one refusal, the way ``SearchEngine.resolve``
        collapses its own: a name unknown to the fetch registry, one the
        registry has but this deployment never built for want of a key or URL,
        and one the permission set excluded. All three are refused before
        anything is dispatched, so nothing is billed and the sentence names what
        this server did build. A search-set name like ``serper`` is the first case.

        There is no name for the local fetcher, so ``None`` means the local read.
        The fallback object is returned rather than its name because the
        fallbacks sit in a list: a second name lookup could disagree with the
        object that made the call, which is why ``_fallback_cost_usd`` reads the
        object too.
        """
        if requested is None:
            return None
        try:
            name = router.resolve_fetch(self._table, requested)
        except router.RouteRefused as refusal:
            raise FetchRefused(str(refusal)) from None
        # ``resolve_fetch`` only answers a name it took from this same list, so the
        # lookup cannot miss; the object, not the name, is what the caller bills.
        return next(fallback for fallback in self.fallbacks if fallback.name == name)

    async def fetch(
        self,
        url: str,
        *,
        offset: int = 0,
        query: str | None = None,
        path: str | None = None,
        provider: str | None = None,
        auto_fallback: bool | None = None,
        run: str | None = None,
        step: int | None = None,
    ) -> FetchResponse:
        """Fetch one page, walking the ladder only where the route asks for it.

        ``path`` reads one part of a JSON document instead of the document --
        `jsondoc` states the grammar.

        ``provider`` names one built fallback and routes this page to it alone:
        no default-route attempt first, no walk behind it, because a price named
        is a price paid. Omitting it is the default route -- the local reader
        unless ``fetch.primary`` named a fallback. A name this server did not
        build is refused with the list it did, before anything is dispatched.

        ``auto_fallback`` overrides ``fetch.auto_fallback`` for this call: an
        explicit ``True`` is how the `answer` plan keeps the walk, a refusal
        between its steps being a lost page. It is an argument on this call
        rather than a reading of ``run``/``step`` -- those are observability and
        must not become load-bearing.

        ``run``/``step`` tag this call as one page read of an `answer` call's
        retrieval walk. Absent on a plain ``fetch``, so that line keeps the shape
        its readers already parse.
        """
        if query is not None and offset:
            raise FetchRefused("pass `query` or `offset`, not both")
        if path is not None and (query is not None or offset):
            raise FetchRefused("pass `path`, `query` or `offset`, one at a time")
        # Resolved ahead of any dispatch, as `search` resolves: a name this
        # server cannot serve is refused with the list it can.
        named = self.resolve(provider)
        # The walk belongs to the route as much as to the key: the `answer` plan
        # asks for it per call.
        walk = (
            self.config.fetch.auto_fallback
            if auto_fallback is None
            else auto_fallback
        )
        if path is not None:
            # Syntax first: an unreadable selector should not cost a fetch, let
            # alone a fallback credit.
            try:
                parse_path(path)
            except PathSyntax as exc:
                raise FetchRefused(f"`path` is not readable: {exc}") from exc

        notices: list[str] = []
        # A selection by terms or by structure reads the whole document; the
        # budget bounds the response, not the fetch.
        max_chars = UNCAPPED if query is not None or path is not None else None
        log = self._log_for(url)
        started = time.monotonic()
        page, fallback = await self._fetch_page(
            url,
            offset,
            max_chars,
            log,
            notices,
            started,
            named=named,
            auto_fallback=walk,
            run=run,
            step=step,
        )
        if page.image is not None:
            return self._finish_image(
                url,
                page,
                page.image,
                fallback,
                log,
                notices,
                started,
                run=run,
                step=step,
            )
        # The ladder is finished and this page is the page, so the escape lands
        # here: everything downstream reads the escaped text. An offset taken from
        # escaped text stays valid across a re-fetch; only a cut-boundary token drifts.
        sanitized = 0
        page.text, sanitized = sanitize_text(page.text)
        if page.title is not None:
            page.title, n = sanitize_text(page.title)
            sanitized += n

        # Offset > 0 only: an empty page at offset 0 is the JS-shell case, not a past-end bookmark.
        if not query and offset > 0 and offset >= page.total_chars:
            self._finish_served_call(
                log, page, fallback, started, run=run, step=step, sanitized=sanitized
            )
            return self._past_end_response(url, page, offset)

        empty_page = offset == 0 and self._is_empty(page.text)
        if empty_page:
            log.bind(chars=len(page.text.strip())).info("fetch.empty")
            notices.append(router.empty_notice(self._table, walk))

        matches = self._select(page, query, path, empty_page, notices)

        self._finish_served_call(
            log, page, fallback, started, run=run, step=step, sanitized=sanitized
        )
        self._log_content(log, page, matches)
        return self._response(url, page, offset, matches, notices)

    def _log_for(self, url: str) -> Logger:
        """Build the fetch log: host always, the full URL only when queries are logged.

        A URL a model chose off a third-party page is the same sensitivity class
        as a query, so it rides the same switch; the host always."""
        log = bind(host=host_of(url))
        if self.config.logging.log_queries:
            log = log.bind(url=safe(url, 200))
        return log

    async def _fetch_page(
        self,
        url: str,
        offset: int,
        max_chars: int | None,
        log: Logger,
        notices: list[str],
        started: float,
        *,
        named: ContentFetcher | None = None,
        auto_fallback: bool,
        run: str | None = None,
        step: int | None = None,
    ) -> tuple[FetchedPage, str | None]:
        """Fetch, escalating to the ladder only where the route asked for the walk.

        ``named`` is a fallback ``resolve`` already accepted, served alone: the
        primary is not tried first and the walk is not entered after.
        ``auto_fallback`` is already resolved; off, neither gate below opens -- a
        failed read raises naming the configured providers as a choice, and a
        nearly-empty read is returned to be told about rather than walked past.

        Returns the page and the name of the fallback that served it, or ``None``
        when the local reader did: the caller needs the *name* to journal which
        fallback a page was billed to, not merely the `fell_back` bool. When every
        fallback fails the *original* failure raises -- "scrappa: rate limited"
        explains nothing about the page asked for. The emptiness gate arms at
        offset 0 only: a short window mid-page is a tail, not a symptom; a fetch
        error escalates at any offset."""
        if named is not None:
            return await self._fetch_named(
                named, url, offset, max_chars, log, started, run=run, step=step
            )
        tried: list[str] = []
        try:
            page = await self._primary.fetch(url, offset=offset, max_chars=max_chars)
        except ProviderError as exc:
            if not auto_fallback:
                # The withheld walk is a choice only where the failure left one. A
                # guardrail refusal -- ``FetchBlocked``, so ``UrlBlocked`` and
                # ``RedirectBlocked`` -- names providers that would refuse the same
                # URL: every remote fallback runs ``_validated_remote_target``,
                # applying the SSRF policy unconditionally. Its reason already says
                # what was refused.
                choice = ""
                if not isinstance(exc, FetchBlocked):
                    choice = router.choose_instead(self._table)
                self._raise_fetch_failure(
                    log,
                    exc,
                    started,
                    choice=choice,
                    run=run,
                    step=step,
                )
            escalated = await self._try_fallbacks(
                url,
                notices,
                reason=exc.message,
                log=log,
                offset=offset,
                max_chars=max_chars,
                tried=tried,
            )
            if escalated is None:
                # The walk ran and every member failed, so the caller already had
                # the choice: what it needs is the list of what was tried.
                self._raise_fetch_failure(
                    log,
                    exc,
                    started,
                    also_failed=(
                        f" Fallbacks also failed: {', '.join(tried)}."
                        if tried
                        else ""
                    ),
                    run=run,
                    step=step,
                )
            return escalated
        # An image's empty text is the resource itself, not the JS-shell symptom
        # this gate exists to catch; escalating would bill a renderer and a
        # scraper to look for prose in a photograph. Off, the walk is not entered
        # here either: `fetch` reports the providers rather than a walk nobody asked for.
        if (
            auto_fallback
            and page.image is None
            and offset == 0
            and self._is_empty(page.text)
        ):
            rendered = await self._try_fallbacks(
                url,
                notices,
                reason="almost no readable text",
                log=log,
                offset=offset,
                max_chars=max_chars,
                tried=tried,
            )
            if rendered is not None:
                return rendered
        return page, self._primary_name

    async def _fetch_named(
        self,
        named: ContentFetcher,
        url: str,
        offset: int,
        max_chars: int | None,
        log: Logger,
        started: float,
        *,
        run: str | None = None,
        step: int | None = None,
    ) -> tuple[FetchedPage, str]:
        """Serve the page through the one provider the caller named.

        One attempt, and its name is the fallback the call is journalled to,
        which prices the line. No local fetch fails first and no walk substitutes
        for it, so a caller using ``provider`` as a cost knob is not billed by a
        second name -- `search`'s rule. A ``ProviderError`` carries the name that
        raised it, so the failure sentence already says which provider failed.
        """
        try:
            page = await named.fetch(url, offset=offset, max_chars=max_chars)
        except ProviderError as exc:
            self._raise_fetch_failure(log, exc, started, run=run, step=step)
        return page, named.name

    def _raise_fetch_failure(
        self,
        log: Logger,
        exc: ProviderError,
        started: float,
        *,
        also_failed: str = "",
        choice: str = "",
        run: str | None = None,
        step: int | None = None,
    ) -> Never:
        """Log the failure and raise with model-facing advice.

        Two notes ride after the reason. ``also_failed`` names the members a walk
        ran and lost -- the caller already had the choice. ``choice`` is the
        recovery sentence for a read never walked, and it replaces the generic
        retry advice rather than doubling it: one says wait and retry, the other
        retry on a named provider.

        A guardrail refusal is the SSRF policy working, so it is levelled apart
        (fetch.blocked); this one branch covers every FetchBlocked raise site.
        Only the URL-level refusals (``UrlBlocked``) are refused *before* the
        request -- the rest, ``RedirectBlocked`` included, fired with one in
        flight -- so only they raise :class:`FetchRefused`, which the REST
        projection reports as 400 rather than 502. The message and the log line
        are identical either way."""
        entry = log.bind(ms=elapsed_ms(started), reason=exc.message)
        if isinstance(exc, FetchBlocked):
            entry.info("fetch.blocked")
        else:
            entry.bind(retryable=exc.retryable).warning("fetch.failed")
        if self.usage is not None:
            # Nothing was billed -- neither the local refusals nor the fallback
            # failures that led here cost a credit -- so: no fallback, no chars.
            self.usage.record_fetch(
                ms=elapsed_ms(started),
                chars=0,
                fallback=None,
                error=type(exc).__name__,
                run=run,
                step=step,
            )
        advice = (
            ""
            if choice or not exc.retryable
            else " Retry shortly, or search for the content."
        )
        message = f"Fetch failed - {exc}.{also_failed}{advice}{choice}"
        if isinstance(exc, UrlBlocked):
            raise FetchRefused(message) from exc
        raise FetchFailed(message) from exc

    def _finish_image(
        self,
        url: str,
        page: FetchedPage,
        image: FetchedImage,
        fallback: str | None,
        log: Logger,
        notices: list[str],
        started: float,
        *,
        run: str | None = None,
        step: int | None = None,
    ) -> FetchResponse:
        """The whole path of an image page: journal it, say what it is, hand it over.

        An image has no text to escape, page through or select passages from, so
        it never reaches the text machinery below, and the emptiness gate never
        walks the ladder for one.

        `answer` builds its material out of text, so an image fetched inside an
        `answer` walk is reported to the model rather than carried into a prompt
        that cannot read it -- still journaled, because the call was still made.
        """
        size = len(image.body)
        carried = (
            None
            if run is not None
            else FetchImage(
                byte_count=size, base64=base64.b64encode(image.body).decode("ascii")
            )
        )
        if carried is None:
            notices.append(
                f"{image.media_type} image of {size:,} bytes was fetched: `answer` "
                "builds its material from text, so its bytes are not returned"
            )
        else:
            notices.append(
                f"{image.media_type} image of {size:,} bytes returned as image "
                "bytes: an image has no extracted text for `query`, `path` or "
                "`offset` to address"
            )
        self._finish_served_call(
            log,
            page,
            fallback,
            started,
            run=run,
            step=step,
            sanitized=0,
            image_bytes=size,
        )
        return FetchResponse(
            url=page.url,
            requested_url=url,
            content_type=image.media_type,
            status_code=page.status_code,
            retrieved_at=_now(),
            image=carried,
            notice="; ".join(notices) or None,
        )

    def _past_end_response(
        self, url: str, page: FetchedPage, offset: int
    ) -> FetchResponse:
        """An offset past a known-readable page: empty text and a plain notice.

        Only the body is withheld; this builder bills nothing. The page *was*
        fetched -- and billed when a fallback served it -- so the caller has
        already emitted ``fetch.ok`` and journaled the call before this returns.
        """
        return FetchResponse(
            url=page.url,
            requested_url=url,
            title=page.title,
            text="",
            content_type=page.content_type,
            status_code=page.status_code,
            retrieved_at=_now(),
            total_chars=page.total_chars,
            offset=offset,
            notice=(
                f"offset {offset} is past the end of the page "
                f"({page.total_chars} chars); nothing returned"
            ),
        )

    def _select(
        self,
        page: FetchedPage,
        query: str | None,
        path: str | None,
        empty_page: bool,
        notices: list[str],
    ) -> list[FetchMatch] | None:
        """What the caller asked to be shown: passages, a subtree, or the page.

        An unreadable page outranks a no-match, so an empty page skips selection
        and keeps the shell diagnosis instead of claiming nothing matched.

        A `path` on a page that carries no structure returns the page with a
        notice rather than failing it: the page was already fetched and possibly
        billed, so "this is not one, here it is entire" is what the caller can
        act on -- the `providers.base.ignored_constraints` rule, which says a
        constraint the serving side cannot honour is reported, not dropped.
        """
        if empty_page:
            return None
        budget = self.config.fetch.max_match_chars
        if path is not None:
            # The extraction's own flag, not a reading of the text: a page whose
            # first character happens to be `$` is not a document.
            if not page.path_addressable:
                notices.append(
                    "`path` selects inside a JSON document, and this page is "
                    "not one this server could read; the whole page is returned"
                )
                return None
            spans, dropped = select_paths(page.text, path, max_chars=budget)
        elif query is not None:
            spans, dropped = select_passages(page.text, query, max_chars=budget)
        else:
            return None
        if not spans:
            if path is not None:
                # `dropped` counts sections that matched and were cut, so "nothing
                # matched" must not be said of a document merely over budget.
                notices.append(
                    f"the part of this JSON document that `path` addresses is "
                    f"larger than the selection budget ({budget} chars); ask for "
                    "a narrower `path`, or a slice of an array, as in [0:5], or "
                    "raise fetch.max_match_chars"
                    if dropped
                    else "nothing in this JSON document matches that `path`; fetch "
                    "without `path` to read its structure, where every line names "
                    "the path that addresses it"
                )
            else:
                notices.append(
                    "none of the query terms appear on this page; fetch "
                    "without `query` to read it"
                )
            return []
        matches = [FetchMatch(offset=o, text=t) for o, t in spans]
        if dropped:
            notices.append(
                f"selection budget ({budget} chars) reached; {dropped} more "
                "matching section(s) not returned; raise fetch.max_match_chars "
                "or ask for a narrower `path`, or a slice of an array, as in [0:5]"
                if path is not None
                else f"passage budget ({budget} chars) reached; {dropped} more "
                "matching section(s) not returned; raise fetch.max_match_chars "
                "or fetch with `offset` near a match"
            )
        return matches

    def _finish_served_call(
        self,
        log: Logger,
        page: FetchedPage,
        fallback: str | None,
        started: float,
        *,
        run: str | None = None,
        step: int | None = None,
        sanitized: int,
        image_bytes: int | None = None,
    ) -> None:
        """The shared tail of every served fetch: the fetch.ok line and the journal entry.

        A past-end offset goes through here too: its page was still fetched and
        billed, so the operator's line and the dashboard's fetch counter must see
        the call, and it is priced like any other, because the *call* is what a
        fallback bills.
        """
        self._log_ok(
            log,
            page,
            fallback is not None,
            started,
            sanitized=sanitized,
            image_bytes=image_bytes,
        )
        if self.usage is not None:
            # `chars` counts extracted text, which an image page has none of; the
            # call is what the journal prices, and it was made.
            self.usage.record_fetch(
                ms=elapsed_ms(started),
                chars=len(page.text),
                fallback=fallback,
                cost_usd=self._fallback_cost_usd(fallback),
                run=run,
                step=step,
            )

    def _fallback_cost_usd(self, fallback: str | None) -> float | None:
        """The declared price of the one call ``fallback`` made, or ``None``.

        ``None`` covers both cases where nothing was billed: the local fetcher
        served it, or the fallback cannot bill at all (``crawl4ai`` is the
        operator's own renderer, ``jina`` is keyless). The journal line then
        carries no ``cost_usd`` rather than a ``0.0`` that would read as a
        measured free call.

        Per **call**, not per delivered character: a past-end ``offset`` still
        fetched and billed the page.

        Read off the fallback object rather than re-derived from config: the
        object already resolved ``fetch.cost_per_1k`` when the ladder was built,
        and a second resolution could disagree with it.
        """
        if fallback is None:
            return None
        for candidate in self.fallbacks:
            if candidate.name == fallback:
                rate = candidate.cost_per_1k
                return None if rate is None else rate / 1000.0
        return None

    def _log_ok(
        self,
        log: Logger,
        page: FetchedPage,
        fell_back: bool,
        started: float,
        *,
        sanitized: int,
        image_bytes: int | None = None,
    ) -> None:
        """Emit fetch.ok: the aggregatable line -- counts and flags, never content.

        ``sanitized`` is the page's escape count, always bound like ``fell_back``:
        0 on the common path, a count rather than content. ``fell_back`` is true
        whenever a route other than this server's own reader served, an
        operator-configured primary included. ``bytes`` rides only on an image
        page."""
        entry = log.bind(
            ms=elapsed_ms(started),
            status=page.status_code,
            chars=len(page.text),
            truncated=page.truncated,
            fell_back=fell_back,
            sanitized=sanitized,
        )
        if image_bytes is not None:
            entry = entry.bind(bytes=image_bytes)
        entry.info("fetch.ok")

    def _log_content(
        self, log: Logger, page: FetchedPage, matches: list[FetchMatch] | None
    ) -> None:
        """Emit fetch.content: what the caller got -- the page, or the joined matches.

        Off by default: it is the bulkiest record the process can emit, up to
        fetch.max_text_chars characters on one line."""
        if not self.config.logging.log_content:
            return
        content = page.text if matches is None else "\n\n".join(m.text for m in matches)
        log.bind(
            title=safe(page.title, 200),
            text=safe(content, self.config.fetch.max_text_chars),
        ).info("fetch.content")

    def _response(
        self,
        url: str,
        page: FetchedPage,
        offset: int,
        matches: list[FetchMatch] | None,
        notices: list[str],
    ) -> FetchResponse:
        return FetchResponse(
            url=page.url,
            requested_url=url,
            title=page.title,
            text=None if matches is not None else page.text,
            content_type=page.content_type,
            status_code=page.status_code,
            retrieved_at=_now(),
            truncated=page.truncated,
            total_chars=page.total_chars,
            offset=offset or None,
            matches=matches,
            notice="; ".join(notices) or None,
        )

    def _is_empty(self, text: str) -> bool:
        """Whether an extraction found so little that it counts as nothing.

        The floor of 1 keeps a blank page empty at every setting."""
        return len(text.strip()) < max(self.config.fetch.min_text_chars, 1)

    async def _try_fallbacks(
        self,
        url: str,
        notices: list[str],
        *,
        reason: str,
        log: Logger,
        tried: list[str],
        offset: int = 0,
        max_chars: int | None = None,
    ) -> tuple[FetchedPage, str] | None:
        """Walk the fallbacks in order; the best page found, or None.

        Returns the page *and the name of the fallback that produced it*, so the
        caller can journal which fallback a page is attributable to -- the name
        is what its price derives from (``_fallback_cost_usd``). Never raises: the
        caller keeps the *original* failure. Each fallback runs at most once, and
        the walk continues past an empty fallback page -- the paid-run-last rule.

        ``tried`` is the caller's list, filled with every member reached: reached
        rather than failed, because a walk returning no page had every name on
        it raise, and that is the list the failure sentence reports.
        """
        served: tuple[FetchedPage, str] | None = None
        for fallback in self._walk:
            tried.append(fallback.name)
            started = time.monotonic()
            try:
                candidate = await fallback.fetch(
                    url, offset=offset, max_chars=max_chars
                )
            except ProviderError as exc:
                log.bind(
                    fallback=fallback.name,
                    reason=exc.message,
                    original_reason=reason,
                    ms=elapsed_ms(started),
                ).warning("fetch.fallback_failed")
                # Its failure is the next fallback's reason to exist.
                reason = exc.message
                continue
            log.bind(
                fallback=fallback.name, reason=reason, ms=elapsed_ms(started)
            ).info("fetch.fallback")
            notices.append(
                router.refetched_notice(self._table, reason, fallback.name)
            )
            served = (candidate, fallback.name)
            if not self._is_empty(candidate.text):
                return served
            reason = "almost no readable text"
        return served
