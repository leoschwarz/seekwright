"""Usage accounting for the dashboard: RAM aggregates plus an optional journal.

The journal is append-only JSONL, one line per terminal call, read back only by
the dashboard at start and on refresh. Nothing on the serving path reads the
file, so it is not a cache returning by another name. ROADMAP §5 declines the
ceiling a ledger was reserved for.

Content-free by construction: a line holds counts, money, timing and a provider
or fallback *name*, never query text, URLs, hosts, titles or extracted text.

Figures and field meanings: ``docs/reference/metrics.md``. The invariants:

- Unknown is **absent, never ``0.0``**. A money total covers only the lines that
  carried a price, and the count of those travels beside it; a fetch line's
  ``cost_usd`` is *declared* rather than estimated, so the page count stays the
  sample size.
- Per-provider, per-day latency samples stay in RAM, because a percentile is not
  foldable into a running total; nothing about that series reaches the journal.
- Agent mode's ranking data (``retrieved``/``cited``) folds onto the same lines,
  and ``cited_invalid`` is attributed to the model, never to a provider.

Event-loop-confined like `HealthBoard`: plain attributes, no locks. Log
discipline matches the rest of the package -- a constant dotted event name, and
every value through `bind()`.
"""

from __future__ import annotations

import json
import math
from collections import deque
from collections.abc import Iterable
from dataclasses import dataclass, field, fields
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any, Literal

from .logs import bind

# The window the dashboard charts: two weeks, long enough to show a weekly rhythm.
_WINDOW_DAYS = 14

# The quantiles the metrics contract reports, as (field, quantile) pairs so the
# read-time pass and the null-when-empty rule stay in one place.
_PERCENTILES = (("p50_ms", 0.50), ("p95_ms", 0.95))

# The cap on runs held waiting for their `answer` line, so a journal from a
# process that died mid-call cannot grow the map without bound on backfill.
_RUNS_MAX = 256


def _counted(value: object) -> int | None:
    """An integer figure read off a journal line, or None when it is not one.

    ``bool`` is excluded even though it is an ``int``: a line that wrote
    ``true`` where a count belongs is not a count of one.
    """
    if isinstance(value, bool) or not isinstance(value, int):
        return None
    return value


def _money(value: object) -> float | None:
    """A dollar figure read off a journal line, or None when it is not one.

    None means **unknown**, never zero: folding an unpriced line as ``0.0``
    would invent a price the journal never carried.
    """
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value)


@dataclass
class _DayTotals:
    """One UTC day's counts, summed as records land."""

    searches: int = 0
    fetches: int = 0
    answers: int = 0
    errors: int = 0
    cost_usd: float = 0.0
    # Summed only over the answers that carried a price, so `priced_answers` at zero means the day's model spend is unknown, not free.
    model_cost_usd: float = 0.0
    priced_answers: int = 0
    # The same shape one section over, with `priced_fetches` as the sample size.
    fetch_cost_usd: float = 0.0
    priced_fetches: int = 0


@dataclass
class _ProviderTotals:
    """One search provider's totals; searches only -- a fetch has no provider.

    ``retrieved``/``cited`` are agent mode's ranking data, from ``answer`` calls
    alone: results this provider contributed to a retrieval walk, and the
    citations credited to it (see ``UsageRecorder._citation_rows``). Both are
    zero on a provider that has only served plain searches.
    """

    calls: int = 0
    errors: int = 0
    cost_usd: float = 0.0
    ms_sum: int = 0
    last_used: str | None = None
    retrieved: int = 0
    cited: int = 0


@dataclass
class _AnswerTotals:
    """The model's own figures, one home each, attributed to the model.

    ``cited_invalid`` is here and in no provider row: an invented citation is a
    property of the prose, not of the result set.

    ``token_calls``/``priced_calls`` are the sample sizes under the token and
    money totals, so a partial total is visible as partial.
    """

    calls: int = 0
    errors: int = 0
    cited: int = 0
    cited_invalid: int = 0
    sources: int = 0
    answer_chars: int = 0
    prompt_tokens: int = 0
    completion_tokens: int = 0
    token_calls: int = 0
    model_cost_usd: float = 0.0
    priced_calls: int = 0
    ms_sum: int = 0
    models: set[str] = field(default_factory=set)


@dataclass
class _ProviderDayTotals:
    """One provider's terminal searches for one UTC day, plus its latency sample.

    ``calls``/``errors``/``fell_back_calls``/``cost_usd`` count every terminal
    line of that day, so the exclusions the latency population makes stay
    visible beside it. ``samples_ms`` holds only that population -- successful,
    non-fell-back searches -- because a percentile is not decomposable: the
    milliseconds are kept per day and sorted at read time.

    ``first_seen``/``last_seen`` ship verbatim, as the journal wrote them;
    ``first_at``/``last_at`` are the same instants parsed, which is what orders
    them -- timestamp *strings* would rank two offsets wrongly.
    """

    calls: int = 0
    errors: int = 0
    fell_back_calls: int = 0
    cost_usd: float = 0.0
    samples_ms: list[int] = field(default_factory=list)
    first_seen: str | None = None
    last_seen: str | None = None
    first_at: datetime | None = None
    last_at: datetime | None = None


def _nearest_rank(samples: list[int], quantile: float) -> int | None:
    """Nearest-rank percentile of the latency sample, or None when empty.

    ``sorted_ms[ceil(q * n) - 1]``, clamped to the last index, with no
    interpolation: the result is always a value some call actually recorded.
    """
    if not samples:
        return None
    ordered = sorted(samples)
    index = min(max(math.ceil(quantile * len(ordered)) - 1, 0), len(ordered) - 1)
    return ordered[index]


def _fold(days: Iterable[_ProviderDayTotals]) -> _ProviderDayTotals:
    """Sum one provider's per-day buckets into its window rollup row."""
    merged = _ProviderDayTotals()
    for totals in days:
        merged.calls += totals.calls
        merged.errors += totals.errors
        merged.fell_back_calls += totals.fell_back_calls
        merged.cost_usd += totals.cost_usd
        merged.samples_ms.extend(totals.samples_ms)
        if totals.first_at is not None and (
            merged.first_at is None or totals.first_at < merged.first_at
        ):
            merged.first_at = totals.first_at
            merged.first_seen = totals.first_seen
        if totals.last_at is not None and (
            merged.last_at is None or totals.last_at > merged.last_at
        ):
            merged.last_at = totals.last_at
            merged.last_seen = totals.last_seen
    return merged


# The journal's line schema: the one place its keys are declared, so a misnamed key is a type error, not a line that changes shape.
# Field order **is** the on-disk key order; `_apply_*` read by name, so a key an older line lacks is absent rather than an error.
@dataclass
class _SearchLine:
    """One terminal search: what it cost, what it returned, how long it took."""

    ts: str
    tool: Literal["search"]
    provider: str
    ms: int
    cost_usd: float
    results: int
    fell_back: bool
    error: str | None
    run: str | None = None
    step: int | None = None


@dataclass
class _FetchLine:
    """One terminal fetch: the page's length and the fallback that served it."""

    ts: str
    tool: Literal["fetch"]
    ms: int
    chars: int
    fallback: str | None
    error: str | None
    cost_usd: float | None = None
    run: str | None = None
    step: int | None = None


@dataclass
class _AnswerLine:
    """One terminal ``answer`` call: the model's figures and its citations."""

    ts: str
    tool: Literal["answer"]
    run: str
    model: str | None
    depth: str
    searches: int
    results: int
    fetched: int
    material_chars: int
    prompt_tokens: int | None
    completion_tokens: int | None
    answer_chars: int
    cited: int
    cited_invalid: int
    sources: int
    model_cost_usd: float | None
    ms: int
    error: str | None


def _entry(line: _SearchLine | _FetchLine | _AnswerLine) -> dict[str, Any]:
    """Turn a declared line into the dict `_append` writes and `_apply` folds.

    Two keys stay out of the file rather than being written as null. A fetch
    line's ``cost_usd`` when nothing was billed: absent, never ``0.0``, so the
    page count stays the sample size. And the ``run``/``step`` pair on a line
    that belongs to no ``answer`` call, which would otherwise change the shape
    the journal's readers already parse.
    """
    entry: dict[str, Any] = {
        declared.name: getattr(line, declared.name) for declared in fields(line)
    }
    if isinstance(line, _FetchLine) and line.cost_usd is None:
        entry.pop("cost_usd")
    if line.run is None:
        entry.pop("run", None)
        entry.pop("step", None)
    return entry


class UsageRecorder:
    """Aggregate every terminal call, and optionally journal it to a file.

    Terminal outcomes only. A default-route search whose first provider failed
    and whose fallback served is one record -- the fallback that answered --
    because the dashboard is about what was spent and returned. The log stream
    and the health board hold the intermediate failure.
    """

    def __init__(
        self,
        *,
        history_path: str | None = None,
        recent: int = 100,
        keep_days: int = 370,
    ) -> None:
        self.process_started_at = datetime.now(UTC).isoformat()
        self._recent: deque[dict[str, Any]] = deque(maxlen=recent)
        self._keep_days = keep_days
        self._journal_path = Path(history_path) if history_path is not None else None
        self._journal_failed = False
        self._since: str | None = None
        self._current_day: str | None = None
        self._days: dict[str, _DayTotals] = {}
        self._providers: dict[str, _ProviderTotals] = {}
        # Kept beside `_providers` rather than inside it: the lifetime totals keep counting days the day buckets have pruned,
        # and only this structure is windowed.
        self._provider_days: dict[str, dict[str, _ProviderDayTotals]] = {}
        self._searches = 0
        self._fetches = 0
        self._errors = 0
        self._fallbacks = 0
        self._search_cost_usd = 0.0
        self._fetch_pages_via_fallback = 0
        # Fetch spend and its sample size: a total over the priced fetch lines alone is visible as partial.
        self._fetch_cost_usd = 0.0
        self._priced_fetches = 0
        self._answers = _AnswerTotals()
        # run id -> {provider: results}, held only until that run's `answer`
        # line folds (see `_remember_run`). Bounded by `_RUNS_MAX`.
        self._runs: dict[str, dict[str, int]] = {}
        if self._journal_path is not None:
            if not self._journal_path.parent.exists():
                raise ValueError(
                    f"parent directory does not exist: {self._journal_path}"
                )
            # An unwritable bind mount would boot green and break on the first append, so the journal's own open runs at
            # startup and the misconfiguration becomes a startup error. The probe writes no bytes.
            try:
                with self._journal_path.open("a", encoding="utf-8"):
                    pass
            except OSError as exc:
                raise ValueError(
                    f"not writable: {self._journal_path} ({exc})"
                ) from exc
            self._backfill(self._journal_path)

    def record_search(
        self,
        *,
        provider: str,
        ms: int,
        cost_usd: float,
        results: int,
        fell_back: bool,
        error: str | None = None,
        run: str | None = None,
        step: int | None = None,
    ) -> None:
        """Record one terminal search: success with a cost, or a named failure.

        A failure carries ``results=0`` and ``cost_usd=0.0`` -- nothing was
        billed -- and ``error`` is the exception *class name*, never the
        exception's message.

        ``run``/``step`` are present only when this search is one step of an
        ``answer`` call's retrieval walk; a plain search belongs to no run, and
        the keys are omitted rather than nulled.
        """
        entry = _entry(
            _SearchLine(
                ts=datetime.now(UTC).isoformat(),
                tool="search",
                provider=provider,
                ms=ms,
                cost_usd=cost_usd,
                results=results,
                fell_back=fell_back,
                error=error,
                run=run,
                step=step,
            )
        )
        self._apply(entry)
        self._append(entry)

    def record_fetch(
        self,
        *,
        ms: int,
        chars: int,
        fallback: str | None,
        cost_usd: float | None = None,
        error: str | None = None,
        run: str | None = None,
        step: int | None = None,
    ) -> None:
        """Record one terminal fetch.

        ``fallback`` names the fallback that served it, or ``None`` for the
        local fetcher and for every failure. The caller resolves that name to
        the fallback's declared ``cost_per_1k`` and passes the resulting money
        as ``cost_usd``.

        ``cost_usd`` is the declared price of the **one call** the fallback
        made -- per call, not per delivered character, because a past-end
        ``offset`` still fetched and billed the page. The key is **absent,
        never ``0.0``**, whenever nothing was billed: the local fetcher, every
        failure, and any fallback that declares no price (``crawl4ai``,
        ``jina``). Absent keeps the page count the sample size; a ``0.0`` would
        claim a measured free call.

        ``run``/``step`` mean what they do on a search line.
        """
        entry = _entry(
            _FetchLine(
                ts=datetime.now(UTC).isoformat(),
                tool="fetch",
                ms=ms,
                chars=chars,
                fallback=fallback,
                error=error,
                cost_usd=cost_usd,
                run=run,
                step=step,
            )
        )
        self._apply(entry)
        self._append(entry)

    def record_answer(
        self,
        *,
        run: str,
        model: str | None,
        depth: str,
        searches: int,
        results: int,
        fetched: int,
        material_chars: int,
        prompt_tokens: int | None,
        completion_tokens: int | None,
        answer_chars: int,
        cited: int,
        cited_invalid: int,
        sources: int,
        model_cost_usd: float | None,
        ms: int,
        error: str | None = None,
    ) -> None:
        """Record one terminal ``answer`` call: one line per call, content-free.

        ``sources`` is a **count** -- ``len(sources)`` of the response -- never
        the list and never a URL. It can be smaller than ``cited``: that
        deduplicates by index, this by URL.

        ``prompt_tokens``/``completion_tokens`` come from the endpoint's
        ``usage`` and are ``None`` when it reports none -- never a local
        estimate. ``model_cost_usd`` follows them: with the prices unset it is
        ``None``, which reads as "counted, not priced".
        """
        entry = _entry(
            _AnswerLine(
                ts=datetime.now(UTC).isoformat(),
                tool="answer",
                run=run,
                model=model,
                depth=depth,
                searches=searches,
                results=results,
                fetched=fetched,
                material_chars=material_chars,
                prompt_tokens=prompt_tokens,
                completion_tokens=completion_tokens,
                answer_chars=answer_chars,
                cited=cited,
                cited_invalid=cited_invalid,
                sources=sources,
                model_cost_usd=model_cost_usd,
                ms=ms,
                error=error,
            )
        )
        self._apply(entry)
        self._append(entry)

    def search_cost_usd(self) -> float:
        """Search spend so far, unrounded, from the in-memory aggregate.

        The one serving-path reader of these aggregates: agent mode's
        `max_cost_usd` early exit adds each retrieval step's spend to what it has
        already seen, and a rounded figure would let the ceiling fire late. The
        journal *file* is still never read here.
        """
        return self._search_cost_usd

    def snapshot(self) -> dict[str, object]:
        """The whole dashboard state, serialised verbatim as JSON.

        Costs are rounded to six decimals -- sub-microdollar -- so a float sum
        never ships its binary-tail noise to a page whose point is readability.

        ``endpoints`` is the windowed per-endpoint series (see ``_endpoints``)
        and ``answers`` is agent mode's ranking data (see ``_citation_rows``).
        Every money figure is ``null`` rather than ``0.0`` when nothing was
        priced, with the count that says how much of the whole it covers
        beside it.
        """
        days: list[dict[str, object]] = []
        today = datetime.now(UTC).date()
        for offset in range(_WINDOW_DAYS - 1, -1, -1):
            date = (today - timedelta(days=offset)).isoformat()
            totals = self._days.get(date)
            days.append(
                {
                    "date": date,
                    "searches": totals.searches if totals else 0,
                    "fetches": totals.fetches if totals else 0,
                    "answers": totals.answers if totals else 0,
                    "errors": totals.errors if totals else 0,
                    "cost_usd": round(totals.cost_usd, 6) if totals else 0.0,
                    "model_cost_usd": (
                        round(totals.model_cost_usd, 6)
                        if totals and totals.priced_answers
                        else None
                    ),
                    # The fetch money column, same rule: a day served only by fallbacks that declare no price reports no figure.
                    "fetch_cost_usd": (
                        round(totals.fetch_cost_usd, 6)
                        if totals and totals.priced_fetches
                        else None
                    ),
                }
            )

        ordered = sorted(
            self._providers.items(), key=lambda item: (-item[1].cost_usd, item[0])
        )
        providers = [
            {
                "provider": name,
                "calls": totals.calls,
                "errors": totals.errors,
                "cost_usd": round(totals.cost_usd, 6),
                "avg_ms": int(totals.ms_sum / totals.calls) if totals.calls else 0,
                "last_used": totals.last_used,
            }
            for name, totals in ordered
        ]

        return {
            "since": self._since,
            "process_started_at": self.process_started_at,
            "totals": {
                "searches": self._searches,
                "fetches": self._fetches,
                "errors": self._errors,
                "fallbacks": self._fallbacks,
                "search_cost_usd": round(self._search_cost_usd, 6),
                "fetch_pages_via_fallback": self._fetch_pages_via_fallback,
                # The fetch ladder's money, from the fallbacks' own declared prices; ``null`` when no page came from a
                # fallback that declares one.
                "fetch_cost_usd": (
                    round(self._fetch_cost_usd, 6) if self._priced_fetches else None
                ),
                "priced_fetches": self._priced_fetches,
            },
            "days": days,
            "providers": providers,
            "answers": {
                "calls": self._answers.calls,
                "errors": self._answers.errors,
                "cited": self._answers.cited,
                "cited_invalid": self._answers.cited_invalid,
                "sources": self._answers.sources,
                "answer_chars": self._answers.answer_chars,
                "prompt_tokens": (
                    self._answers.prompt_tokens if self._answers.token_calls else None
                ),
                "completion_tokens": (
                    self._answers.completion_tokens
                    if self._answers.token_calls
                    else None
                ),
                "token_calls": self._answers.token_calls,
                "model_cost_usd": (
                    round(self._answers.model_cost_usd, 6)
                    if self._answers.priced_calls
                    else None
                ),
                "priced_calls": self._answers.priced_calls,
                "mean_ms": (
                    int(self._answers.ms_sum / self._answers.calls)
                    if self._answers.calls
                    else None
                ),
                "models": sorted(self._answers.models),
                "providers": self._citation_rows(),
            },
            "endpoints": self._endpoints(),
            "recent": [dict(entry) for entry in reversed(self._recent)],
            "journal": {
                "path": str(self._journal_path) if self._journal_path else None,
                "failed": self._journal_failed,
            },
        }

    def _endpoints(self) -> dict[str, object]:
        """The per-provider series over the window, computed from the day buckets.

        Read-time on purpose: the percentiles are derived when a caller asks,
        not stored. The window is the last ``_WINDOW_DAYS`` UTC days ending
        today -- the same axis the chart draws -- and a provider or a day with
        no calls is **absent**, never a zero row, because ``0 ms`` is a claim
        and absence is not. ``latency_samples`` carries the sample size.
        """
        today = datetime.now(UTC).date()
        window = [
            (today - timedelta(days=offset)).isoformat()
            for offset in range(_WINDOW_DAYS - 1, -1, -1)
        ]

        rollups: list[tuple[str, _ProviderDayTotals, list[dict[str, object]]]] = []
        for provider, by_day in self._provider_days.items():
            present = [day for day in window if day in by_day]
            if not present:
                continue
            rollups.append(
                (
                    provider,
                    _fold(by_day[day] for day in present),
                    [self._endpoint_row(by_day[day], date=day) for day in present],
                )
            )
        rollups.sort(key=lambda item: (-item[1].cost_usd, item[0]))

        providers: list[dict[str, object]] = []
        for provider, totals, days in rollups:
            row = self._endpoint_row(totals, provider=provider)
            row["days"] = days
            providers.append(row)
        return {"window_days": _WINDOW_DAYS, "providers": providers}

    def _endpoint_row(
        self,
        totals: _ProviderDayTotals,
        *,
        provider: str | None = None,
        date: str | None = None,
    ) -> dict[str, object]:
        """One rollup or per-day row: the shared field set plus its own label."""
        samples = totals.samples_ms
        row: dict[str, object] = {}
        if provider is not None:
            row["provider"] = provider
        if date is not None:
            row["date"] = date
        row["calls"] = totals.calls
        row["errors"] = totals.errors
        row["fell_back_calls"] = totals.fell_back_calls
        row["latency_samples"] = len(samples)
        for name, quantile in _PERCENTILES:
            row[name] = _nearest_rank(samples, quantile)
        # Truncating, like the lifetime `avg_ms`; ``None``, never 0, when there is no sample -- zero reads as "instant".
        row["mean_ms"] = int(sum(samples) / len(samples)) if samples else None
        row["cost_usd"] = round(totals.cost_usd, 6)
        row["cost_per_1k"] = (
            round(totals.cost_usd / totals.calls * 1000, 6) if totals.calls else None
        )
        row["first_seen"] = totals.first_seen
        row["last_seen"] = totals.last_seen
        return row

    def _citation_rows(self) -> list[dict[str, object]]:
        """Per-provider retrieval and citation totals: the answering-task ranking.

        Only providers that answered a retrieval step of an ``answer`` call
        appear -- absence, never a zero row. Ordered by citations, then results,
        then name.

        ``retrieved`` is what the provider contributed to answering calls'
        material, counted as the retrieval line folds. ``cited`` is the run's
        citation count credited to every provider that contributed results to
        that run, once per run. A run whose process died mid-call keeps its
        ``retrieved`` and can never gain a ``cited``: there is no answer line to
        credit.

        Exact whenever a run used one provider, which is the ordinary case. A
        run whose steps spanned two providers (a mid-walk fallback that later
        succeeded) is a **documented over-count**: the journal cannot say which
        provider's results the cited indices named, and over-crediting both
        reads as "the provider's results were in a run whose prose cited this
        many".
        """
        present = [
            (name, totals)
            for name, totals in self._providers.items()
            if totals.retrieved or totals.cited
        ]
        present.sort(key=lambda item: (-item[1].cited, -item[1].retrieved, item[0]))
        return [
            {
                "provider": name,
                "retrieved": totals.retrieved,
                "cited": totals.cited,
            }
            for name, totals in present
        ]

    def _backfill(self, path: Path) -> None:
        """Fold an existing journal into the aggregates.

        A missing file is fine -- construction created it. A line that will not
        parse is skipped and counted rather than fatal: a torn write from a
        previous crash must not take down a server. The count is logged once so
        a growing number is visible.
        """
        if not path.is_file():
            return
        skipped = 0
        for raw in path.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                skipped += 1
                continue
            if not self._apply(entry):
                skipped += 1
        if skipped:
            bind(skipped=skipped).warning("dashboard.journal_skipped")

    def _apply(self, entry: object) -> bool:
        """Fold one journal-shaped dict into the aggregates and the recent deque.

        Returns False for anything that is not a well-formed entry, so backfill
        can count it and a live record (always well-formed) can ignore the
        result.
        """
        if not isinstance(entry, dict):
            return False
        ts = entry.get("ts")
        tool = entry.get("tool")
        ms = entry.get("ms")
        error = entry.get("error")
        if (
            not isinstance(ts, str)
            or tool not in ("search", "fetch", "answer")
            or not isinstance(ms, int)
            or (error is not None and not isinstance(error, str))
        ):
            return False
        try:
            moment = datetime.fromisoformat(ts).astimezone(UTC)
        except ValueError:
            return False
        day = moment.date().isoformat()

        self._roll(day)
        bucket = self._days.setdefault(day, _DayTotals())
        if error is not None:
            self._errors += 1
            bucket.errors += 1
        if tool == "search":
            self._apply_search(entry, bucket, day, ts, moment, ms, error)
        elif tool == "fetch":
            self._apply_fetch(entry, bucket, error)
        else:
            # `answer` folds its own figures here -- model spend, token and citation counts, the per-provider retrieved/cited join;
            # the generic tail below is what it shares with the other two kinds.
            self._apply_answer(entry, bucket, ms, error)
        self._recent.append(entry)
        if self._since is None or ts < self._since:
            self._since = ts
        return True

    def _apply_search(
        self,
        entry: dict[str, Any],
        bucket: _DayTotals,
        day: str,
        ts: str,
        moment: datetime,
        ms: int,
        error: str | None,
    ) -> None:
        cost = entry.get("cost_usd")
        cost_usd = float(cost) if isinstance(cost, (int, float)) else 0.0
        provider = entry.get("provider")
        fell_back = bool(entry.get("fell_back"))
        results = _counted(entry.get("results")) or 0

        self._searches += 1
        self._search_cost_usd += cost_usd
        if fell_back:
            self._fallbacks += 1
        bucket.searches += 1
        bucket.cost_usd += cost_usd

        if not isinstance(provider, str):
            return
        totals = self._providers.setdefault(provider, _ProviderTotals())
        totals.calls += 1
        totals.cost_usd += cost_usd
        totals.ms_sum += ms
        totals.last_used = ts
        if error is not None:
            totals.errors += 1

        days = self._provider_days.setdefault(provider, {})
        day_totals = days.get(day)
        if day_totals is None:
            day_totals = days[day] = _ProviderDayTotals()
        day_totals.calls += 1
        day_totals.cost_usd += cost_usd
        if error is not None:
            day_totals.errors += 1
        if fell_back:
            day_totals.fell_back_calls += 1
        # The latency population: a terminal failure's `ms` is the configured timeout and a fell-back success's is the whole ladder
        # walk, so neither is a property of the provider that answered.
        if error is None and not fell_back:
            day_totals.samples_ms.append(ms)
        if day_totals.first_at is None or moment < day_totals.first_at:
            day_totals.first_at = moment
            day_totals.first_seen = ts
        if day_totals.last_at is None or moment > day_totals.last_at:
            day_totals.last_at = moment
            day_totals.last_seen = ts

        # The ranking data's join key: a run-carrying step is one retrieval of an `answer` call,
        # and its `answer` line credits the citations back to whoever contributed. A plain search carries no run.
        run = entry.get("run")
        if isinstance(run, str) and results > 0:
            totals.retrieved += results
            self._remember_run(run, provider, results)

    def _remember_run(self, run: str, provider: str, results: int) -> None:
        """Hold one run's provider->results map until its ``answer`` line folds.

        The ``run`` id is the whole join: retrieval lines are written before the
        ``answer`` line of the same call, and the entry is consumed when the
        answer line arrives. The cap bounds a journal whose process died
        mid-call, whose run-tagged lines have no answer line. Eviction is
        oldest-first, which is also the order a run stops being relevant in.
        """
        if run not in self._runs and len(self._runs) >= _RUNS_MAX:
            self._runs.pop(next(iter(self._runs)))
        counts = self._runs.setdefault(run, {})
        counts[provider] = counts.get(provider, 0) + results

    def _apply_answer(
        self, entry: dict[str, Any], bucket: _DayTotals, ms: int, error: str | None
    ) -> None:
        """Fold one ``answer`` line: the model's figures and the citation join.

        Read by key and tolerant of a key the writer did not send: a missing
        figure is **absent** from the aggregate rather than zero in it, and
        ``priced_calls``/``token_calls`` carry the sample size so a partial
        total is visible as partial.

        Every provider that contributed results to this run is credited with
        the run's citation count, once per run (see ``_citation_rows``).
        """
        totals = self._answers
        totals.calls += 1
        bucket.answers += 1
        if error is not None:
            totals.errors += 1
        totals.ms_sum += ms

        model = entry.get("model")
        if isinstance(model, str):
            totals.models.add(model)

        cited = _counted(entry.get("cited")) or 0
        totals.cited += cited
        totals.cited_invalid += _counted(entry.get("cited_invalid")) or 0
        totals.sources += _counted(entry.get("sources")) or 0
        totals.answer_chars += _counted(entry.get("answer_chars")) or 0

        prompt = _counted(entry.get("prompt_tokens"))
        completion = _counted(entry.get("completion_tokens"))
        if prompt is not None or completion is not None:
            totals.token_calls += 1
            totals.prompt_tokens += prompt or 0
            totals.completion_tokens += completion or 0

        # `None` here means the prices were unset when the line was written: summed as nothing, counted as unpriced,
        # so the snapshot reports the cost as unknown rather than free.
        cost = _money(entry.get("model_cost_usd"))
        if cost is not None:
            totals.model_cost_usd += cost
            totals.priced_calls += 1
            bucket.model_cost_usd += cost
            bucket.priced_answers += 1

        run = entry.get("run")
        if isinstance(run, str):
            contributors = self._runs.pop(run, None)
            if contributors and cited:
                for name in contributors:
                    row = self._providers.get(name)
                    if row is not None:
                        row.cited += cited

    def _apply_fetch(
        self, entry: dict[str, Any], bucket: _DayTotals, error: str | None
    ) -> None:
        fallback = entry.get("fallback")

        self._fetches += 1
        bucket.fetches += 1
        # Pages a fallback served, not fallback *attempts*: only a success carries a
        # name, and only a named success is the counted figure.
        if error is None and isinstance(fallback, str):
            self._fetch_pages_via_fallback += 1

        # Read the way every optional figure is: a line without the key contributes nothing and counts nothing, so `priced_fetches`
        # separates a total over every page from one over some. `_money` maps a missing key to `None`, never to 0.0.
        cost = _money(entry.get("cost_usd"))
        if cost is not None:
            self._fetch_cost_usd += cost
            self._priced_fetches += 1
            bucket.fetch_cost_usd += cost
            bucket.priced_fetches += 1

    def _append(self, entry: dict[str, Any]) -> None:
        """Append one line to the journal, or give up for the process.

        A broken volume must not fail a search the caller is paying for, and it
        must not log once per call: the first `OSError` is reported and the
        writer is switched off for the life of the process. The RAM aggregates
        keep working.
        """
        if self._journal_path is None or self._journal_failed:
            return
        try:
            # Open-append-close per record: a long-lived handle would have to be
            # closed on shutdown, and the context owns no such hook.
            with self._journal_path.open("a", encoding="utf-8") as handle:
                handle.write(json.dumps(entry, default=str) + "\n")
        except OSError as exc:
            self._journal_failed = True
            bind(path=str(self._journal_path), reason=str(exc)).warning(
                "dashboard.journal_error"
            )

    def _roll(self, day: str) -> None:
        """Prune day buckets older than ``keep_days`` when the UTC date changes.

        Only meaningful across a long-lived process; a restart rebuilds the
        window from the journal and the same rule trims it. The per-provider
        day buckets are pruned with the global ones, while the lifetime totals in
        ``_providers`` are deliberately left alone.
        """
        if day == self._current_day:
            return
        self._current_day = day
        cutoff = (datetime.now(UTC).date() - timedelta(days=self._keep_days)).isoformat()
        for stale in [key for key in self._days if key < cutoff]:
            del self._days[stale]
        for provider in list(self._provider_days):
            by_day = self._provider_days[provider]
            for stale in [key for key in by_day if key < cutoff]:
                del by_day[stale]
            if not by_day:
                del self._provider_days[provider]
