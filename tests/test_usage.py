"""The usage recorder: aggregation, the JSONL journal, and its failure modes.

The recorder is the dashboard's whole server side, so what is under test is the
arithmetic the page renders and the two properties that make the journal safe to
keep -- content-free lines, and a broken volume that never fails a billed call.
The ladder walk itself belongs to ``tests/fetch/test_fetch_fallback.py``; what reaches
this file is the line it leaves, and the pin that the line names and prices the
fallback that answered rather than the first fallback tried.
"""

from __future__ import annotations

import inspect
import json
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any, cast

import pytest

from seekwright.config import Config, FetchConfig, PolicyConfig, ProviderConfig
from seekwright.engine import FetchEngine
from seekwright.fetcher import FetchedPage
from seekwright.providers.base import ProviderError
from seekwright.usage import _WINDOW_DAYS, UsageRecorder


def _snap(rec: UsageRecorder) -> dict[str, Any]:
    """The snapshot, typed loosely so the tests read like JSON.

    ``snapshot`` is declared ``dict[str, object]`` -- the wire contract -- and
    indexing that directly makes every assertion a fight with the type checker.
    """
    return cast("dict[str, Any]", rec.snapshot())


def _today() -> str:
    return datetime.now(UTC).date().isoformat()


def _ts(day: str, clock: str = "12:00:00") -> str:
    return f"{day}T{clock}+00:00"


# Clears `fetch.min_text_chars`, so a page a stub fallback returns is a page the engine keeps.
PAGE = "x" * 500


def _search_line(
    ts: str,
    *,
    provider: str = "serper",
    ms: int = 10,
    cost_usd: float = 0.001,
    results: int = 1,
    fell_back: bool = False,
    error: str | None = None,
) -> str:
    return json.dumps(
        {
            "ts": ts,
            "tool": "search",
            "provider": provider,
            "ms": ms,
            "cost_usd": cost_usd,
            "results": results,
            "fell_back": fell_back,
            "error": error,
        }
    )


class TestAggregation:
    def test_totals_and_providers_add_up(self):
        rec = UsageRecorder()
        rec.record_search(
            provider="serper", ms=10, cost_usd=0.001, results=3, fell_back=False
        )
        rec.record_search(
            provider="serper", ms=20, cost_usd=0.002, results=1, fell_back=False
        )
        rec.record_search(
            provider="linkup",
            ms=40,
            cost_usd=0.0,
            results=0,
            fell_back=True,
            error="QuotaExhausted",
        )
        rec.record_fetch(ms=5, chars=900, fallback="scrappa")
        rec.record_fetch(ms=6, chars=0, fallback=None, error="FetchBlocked")

        snap = _snap(rec)
        totals = snap["totals"]
        assert totals["searches"] == 3
        assert totals["fetches"] == 2
        assert totals["errors"] == 2
        assert totals["fallbacks"] == 1
        assert totals["search_cost_usd"] == pytest.approx(0.003)
        assert totals["fetch_pages_via_fallback"] == 1

        providers = {p["provider"]: p for p in snap["providers"]}
        assert providers["serper"]["calls"] == 2
        assert providers["serper"]["avg_ms"] == 15
        assert providers["serper"]["cost_usd"] == pytest.approx(0.003)
        assert providers["serper"]["last_used"] is not None
        assert providers["linkup"]["errors"] == 1
        assert providers["linkup"]["cost_usd"] == 0.0

    def test_providers_are_sorted_by_spend_descending(self):
        rec = UsageRecorder()
        rec.record_search(
            provider="cheap", ms=1, cost_usd=0.001, results=1, fell_back=False
        )
        rec.record_search(
            provider="dear", ms=1, cost_usd=0.009, results=1, fell_back=False
        )

        names = [p["provider"] for p in _snap(rec)["providers"]]
        assert names == ["dear", "cheap"]

    def test_a_failed_fetch_is_not_a_fallback_page(self):
        rec = UsageRecorder()
        rec.record_fetch(ms=1, chars=0, fallback="scrappa", error="ProviderError")

        assert _snap(rec)["totals"]["fetch_pages_via_fallback"] == 0


class TestTheFetchLinePrice:
    """The fallback's declared price, and the shape of its absence.

    A fetch line carries money only when a fallback that declares a price served
    the page. Everything else -- the local fetcher, a failure, a free fallback --
    carries no ``cost_usd`` key at all, so the page count stays the sample size
    and the money total is ``null`` until something is priced.
    """

    def test_a_fallback_served_page_carries_its_declared_price(self):
        rec = UsageRecorder()
        rec.record_fetch(ms=5, chars=900, fallback="scrappa", cost_usd=0.0003)

        snap = _snap(rec)
        assert snap["recent"][0]["cost_usd"] == pytest.approx(0.0003)
        assert snap["totals"]["fetch_cost_usd"] == pytest.approx(0.0003)
        assert snap["totals"]["priced_fetches"] == 1
        assert snap["days"][-1]["fetch_cost_usd"] == pytest.approx(0.0003)

    def test_a_local_page_carries_no_price_key(self):
        rec = UsageRecorder()
        rec.record_fetch(ms=5, chars=900, fallback=None)

        snap = _snap(rec)
        assert "cost_usd" not in snap["recent"][0]
        assert snap["totals"]["fetch_cost_usd"] is None
        assert snap["totals"]["priced_fetches"] == 0
        assert snap["days"][-1]["fetch_cost_usd"] is None

    def test_a_failure_carries_no_price_key(self):
        """Nothing was billed, so nothing is recorded -- not even a zero."""
        rec = UsageRecorder()
        rec.record_fetch(ms=5, chars=0, fallback="scrappa", error="ProviderError")

        snap = _snap(rec)
        assert "cost_usd" not in snap["recent"][0]
        assert snap["totals"]["fetch_cost_usd"] is None
        assert snap["totals"]["priced_fetches"] == 0

    def test_a_free_fallback_carries_no_price_key(self):
        """`crawl4ai` and `jina` declare no price: absent, never `0.0`."""
        rec = UsageRecorder()
        rec.record_fetch(ms=5, chars=900, fallback="crawl4ai")
        rec.record_fetch(ms=5, chars=900, fallback="jina")

        snap = _snap(rec)
        assert [set(entry) for entry in snap["recent"]] == [
            {"ts", "tool", "ms", "chars", "fallback", "error"}
        ] * 2
        assert snap["totals"]["fetch_pages_via_fallback"] == 2
        assert snap["totals"]["fetch_cost_usd"] is None

    def test_a_declared_zero_is_a_real_zero(self):
        """A fallback declaring `0.0` records it; an absent price is not a zero."""
        rec = UsageRecorder()
        rec.record_fetch(ms=5, chars=900, fallback="scrappa", cost_usd=0.0)

        snap = _snap(rec)
        assert snap["recent"][0]["cost_usd"] == 0.0
        assert snap["totals"]["fetch_cost_usd"] == 0.0
        assert snap["totals"]["priced_fetches"] == 1

    def test_a_partial_price_sum_says_how_much_of_the_whole_it_covers(self):
        rec = UsageRecorder()
        rec.record_fetch(ms=5, chars=900, fallback="scrappa", cost_usd=0.0003)
        rec.record_fetch(ms=5, chars=900, fallback="jina")
        rec.record_fetch(ms=5, chars=0, fallback=None, error="FetchBlocked")

        totals = _snap(rec)["totals"]
        assert totals["fetches"] == 3
        assert totals["priced_fetches"] == 1
        assert totals["fetch_cost_usd"] == pytest.approx(0.0003)

    def test_a_journal_without_the_key_still_folds(self, tmp_path):
        """An older writer's fetch line has no `cost_usd`: no migration needed."""
        path = tmp_path / "usage.jsonl"
        path.write_text(
            json.dumps(
                {
                    "ts": _ts(_today()),
                    "tool": "fetch",
                    "ms": 12,
                    "chars": 900,
                    "fallback": "scrappa",
                    "error": None,
                }
            )
            + "\n",
            encoding="utf-8",
        )

        snap = _snap(UsageRecorder(history_path=str(path)))
        assert snap["totals"]["fetches"] == 1
        assert snap["totals"]["fetch_pages_via_fallback"] == 1
        assert snap["totals"]["fetch_cost_usd"] is None
        assert snap["totals"]["priced_fetches"] == 0

    def test_a_malformed_price_is_absent_rather_than_a_zero(self, tmp_path):
        """A figure that is not a figure does not fold as a free page."""
        path = tmp_path / "usage.jsonl"
        path.write_text(
            json.dumps(
                {
                    "ts": _ts(_today()),
                    "tool": "fetch",
                    "ms": 12,
                    "chars": 900,
                    "fallback": "scrappa",
                    "error": None,
                    "cost_usd": "free",
                }
            )
            + "\n",
            encoding="utf-8",
        )

        totals = _snap(UsageRecorder(history_path=str(path)))["totals"]
        assert totals["fetch_cost_usd"] is None
        assert totals["priced_fetches"] == 0

    def test_the_price_round_trips_through_the_journal(self, tmp_path):
        path = tmp_path / "usage.jsonl"
        live = UsageRecorder(history_path=str(path))
        live.record_fetch(ms=5, chars=900, fallback="scrappa", cost_usd=0.0003)

        line = json.loads(path.read_text(encoding="utf-8").strip())
        assert line["cost_usd"] == pytest.approx(0.0003)

        rebuilt = _snap(UsageRecorder(history_path=str(path)))
        assert rebuilt["totals"] == _snap(live)["totals"]
        assert rebuilt["days"] == _snap(live)["days"]


class TestTheLadderWalkBillsTheAnsweringFallback:
    """A walk that spends two attempts prices the page at the fallback that answered.

    The figure on the line is read off the fallback object that served the page
    (``FetchEngine._fallback_cost_usd``), never off the ladder's first fallback or
    off the single ``[fetch] cost_per_1k``. That is what keeps the price honest
    once the ladder holds more than one priced fallback.
    """

    class Fallback:
        """One link of the ladder: a name, the price it declares, and whether it answers."""

        def __init__(
            self, name: str, *, cost_per_1k: float | None = None, fails: bool = False
        ) -> None:
            self.name = name
            self.cost_per_1k = cost_per_1k
            self._fails = fails

        async def fetch(
            self, url: str, *, offset: int = 0, max_chars: int | None = None
        ) -> FetchedPage:
            if self._fails:
                raise ProviderError("fetch", "HTTP 403")
            text = PAGE
            return FetchedPage(
                url=url,
                title="A Page",
                text=text,
                content_type="text/html",
                status_code=200,
                truncated=False,
                total_chars=len(text),
            )

        async def aclose(self) -> None:
            return None

    def _engine(self, fallbacks, usage: UsageRecorder) -> FetchEngine:
        cfg = Config(
            providers={"serper": ProviderConfig()},
            policy=PolicyConfig(),
            # The walk sits behind `fetch.auto_fallback` and that default is off;
            # these cases are about what a walk that ran bills, so they ask for it
            # explicitly.
            fetch=FetchConfig(auto_fallback=True),
        )
        # The local reader fails, so every case below reaches the ladder.
        return FetchEngine(cfg, self.Fallback("local", fails=True), fallbacks, usage=usage)

    async def test_a_walk_bills_the_fallback_that_answered(self):
        """Two priced fallbacks, two different figures: the line carries the second one."""
        rec = UsageRecorder()
        tried = self.Fallback("scrappa", cost_per_1k=0.30, fails=True)
        # The shape of a second priced fallback -- its own declared
        # figure, a different one. One `[fetch] cost_per_1k` cannot express both.
        answered = self.Fallback("priced-two", cost_per_1k=1.60)

        await self._engine([tried, answered], rec).fetch("https://example.com/article")

        entry = _snap(rec)["recent"][0]
        assert entry["fallback"] == "priced-two"
        assert entry["cost_usd"] == pytest.approx(0.0016)
        totals = _snap(rec)["totals"]
        assert totals["fetch_pages_via_fallback"] == 1
        assert totals["priced_fetches"] == 1
        assert totals["fetch_cost_usd"] == pytest.approx(0.0016)

    async def test_a_walk_past_a_free_fallback_bills_the_priced_one(self):
        rec = UsageRecorder()
        tried = self.Fallback("jina", fails=True)
        answered = self.Fallback("scrappa", cost_per_1k=0.30)

        await self._engine([tried, answered], rec).fetch("https://example.com/article")

        entry = _snap(rec)["recent"][0]
        assert entry["fallback"] == "scrappa"
        assert entry["cost_usd"] == pytest.approx(0.0003)

    async def test_a_walk_answered_by_a_free_fallback_bills_nothing(self):
        """The priced fallback that was tried and failed is not the one that billed."""
        rec = UsageRecorder()
        tried = self.Fallback("scrappa", cost_per_1k=0.30, fails=True)
        answered = self.Fallback("crawl4ai")

        await self._engine([tried, answered], rec).fetch("https://example.com/article")

        entry = _snap(rec)["recent"][0]
        assert entry["fallback"] == "crawl4ai"
        assert "cost_usd" not in entry
        totals = _snap(rec)["totals"]
        assert totals["fetch_cost_usd"] is None
        assert totals["priced_fetches"] == 0


class TestWindow:
    def test_a_fresh_recorder_zero_fills_fourteen_days_oldest_first(self):
        days = _snap(UsageRecorder())["days"]

        assert len(days) == 14
        assert all(d["searches"] == 0 and d["cost_usd"] == 0.0 for d in days)
        assert days[-1]["date"] == _today()
        assert [d["date"] for d in days] == sorted(d["date"] for d in days)

    def test_todays_calls_land_in_todays_bucket(self):
        rec = UsageRecorder()
        rec.record_search(
            provider="serper", ms=1, cost_usd=0.004, results=2, fell_back=False
        )
        rec.record_fetch(ms=1, chars=10, fallback=None)

        today = _snap(rec)["days"][-1]
        assert today["searches"] == 1
        assert today["fetches"] == 1
        assert today["cost_usd"] == pytest.approx(0.004)

    def test_since_is_the_earliest_timestamp(self):
        assert _snap(UsageRecorder())["since"] is None

        rec = UsageRecorder()
        rec.record_search(
            provider="serper", ms=1, cost_usd=0.0, results=0, fell_back=False
        )
        assert _snap(rec)["since"] is not None


class TestEndpoints:
    """The windowed per-provider latency and cost series the routing reads."""

    def test_percentiles_are_nearest_rank_over_the_sample(self):
        rec = UsageRecorder()
        for ms in range(1, 11):
            rec.record_search(
                provider="serper", ms=ms, cost_usd=0.0, results=1, fell_back=False
            )

        endpoints = _snap(rec)["endpoints"]
        assert endpoints["window_days"] == _WINDOW_DAYS
        (row,) = endpoints["providers"]
        assert row["provider"] == "serper"
        assert row["latency_samples"] == 10
        # ceil(0.5 * 10) - 1 = 4 and ceil(0.95 * 10) - 1 = 9 on 1..10.
        assert (row["p50_ms"], row["p95_ms"], row["mean_ms"]) == (5, 10, 5)

    def test_a_single_sample_is_both_percentiles(self):
        rec = UsageRecorder()
        rec.record_search(
            provider="serper", ms=7, cost_usd=0.0, results=1, fell_back=False
        )

        (row,) = _snap(rec)["endpoints"]["providers"]
        assert (row["p50_ms"], row["p95_ms"], row["mean_ms"]) == (7, 7, 7)

    def test_two_samples_split_into_lower_and_higher(self):
        rec = UsageRecorder()
        rec.record_search(
            provider="serper", ms=20, cost_usd=0.0, results=1, fell_back=False
        )
        rec.record_search(
            provider="serper", ms=10, cost_usd=0.0, results=1, fell_back=False
        )

        (row,) = _snap(rec)["endpoints"]["providers"]
        assert (row["p50_ms"], row["p95_ms"]) == (10, 20)

    def test_failures_and_fallbacks_are_counted_but_not_sampled(self):
        rec = UsageRecorder()
        rec.record_search(
            provider="serper", ms=100, cost_usd=0.001, results=1, fell_back=False
        )
        rec.record_search(
            provider="serper", ms=500, cost_usd=0.002, results=2, fell_back=True
        )
        rec.record_search(
            provider="serper",
            ms=10_000,
            cost_usd=0.0,
            results=0,
            fell_back=False,
            error="ProviderError",
        )

        (row,) = _snap(rec)["endpoints"]["providers"]
        assert row["calls"] == 3
        assert row["errors"] == 1
        assert row["fell_back_calls"] == 1
        assert row["latency_samples"] == 1
        assert (row["p50_ms"], row["p95_ms"], row["mean_ms"]) == (100, 100, 100)
        assert row["cost_usd"] == pytest.approx(0.003)

    def test_a_provider_with_no_sample_reports_nulls_not_zero(self):
        rec = UsageRecorder()
        rec.record_search(
            provider="linkup",
            ms=10_000,
            cost_usd=0.0,
            results=0,
            fell_back=False,
            error="ProviderError",
        )

        (row,) = _snap(rec)["endpoints"]["providers"]
        assert row["calls"] == 1
        assert row["latency_samples"] == 0
        assert row["p50_ms"] is None
        assert row["p95_ms"] is None
        assert row["mean_ms"] is None
        assert row["cost_per_1k"] == 0.0

    def test_cost_per_1k_is_measured_over_the_window(self):
        rec = UsageRecorder()
        rec.record_search(
            provider="serper", ms=10, cost_usd=0.003, results=1, fell_back=False
        )
        rec.record_search(
            provider="serper", ms=20, cost_usd=0.002, results=1, fell_back=False
        )

        (row,) = _snap(rec)["endpoints"]["providers"]
        assert row["cost_usd"] == pytest.approx(0.005)
        assert row["cost_per_1k"] == pytest.approx(2.5)

    def test_providers_are_sorted_by_window_spend_descending(self):
        rec = UsageRecorder()
        rec.record_search(
            provider="cheap", ms=1, cost_usd=0.001, results=1, fell_back=False
        )
        rec.record_search(
            provider="dear", ms=1, cost_usd=0.009, results=1, fell_back=False
        )

        names = [p["provider"] for p in _snap(rec)["endpoints"]["providers"]]
        assert names == ["dear", "cheap"]

    def test_a_fetch_makes_no_endpoint_row(self):
        rec = UsageRecorder()
        rec.record_fetch(ms=5, chars=100, fallback="scrappa")

        assert _snap(rec)["endpoints"] == {
            "window_days": _WINDOW_DAYS,
            "providers": [],
        }

    def test_the_series_is_one_row_per_provider_per_day_oldest_first(self, tmp_path):
        path = tmp_path / "usage.jsonl"
        today = datetime.now(UTC).date()

        def day(offset: int) -> str:
            return (today - timedelta(days=offset)).isoformat()

        path.write_text(
            "\n".join(
                [
                    _search_line(_ts(day(3)), provider="serper", ms=30, cost_usd=0.003),
                    _search_line(_ts(day(1)), provider="serper", ms=10, cost_usd=0.001),
                    _search_line(_ts(day(1)), provider="linkup", ms=50, cost_usd=0.005),
                    _search_line(
                        _ts(today.isoformat()), provider="serper", ms=20, cost_usd=0.002
                    ),
                ]
            )
            + "\n",
            encoding="utf-8",
        )

        endpoints = _snap(UsageRecorder(history_path=str(path)))["endpoints"]
        rows = {p["provider"]: p for p in endpoints["providers"]}
        assert set(rows) == {"serper", "linkup"}
        assert [d["date"] for d in rows["serper"]["days"]] == [
            day(3),
            day(1),
            today.isoformat(),
        ]
        assert [d["calls"] for d in rows["serper"]["days"]] == [1, 1, 1]
        assert [d["date"] for d in rows["linkup"]["days"]] == [day(1)]
        # The rollup is the window, not a lifetime figure.
        assert rows["serper"]["calls"] == 3
        assert rows["serper"]["cost_usd"] == pytest.approx(0.006)
        assert rows["serper"]["cost_per_1k"] == pytest.approx(2.0)

    def test_a_day_outside_the_window_has_no_row(self, tmp_path):
        path = tmp_path / "usage.jsonl"
        today = datetime.now(UTC).date()
        edge = (today - timedelta(days=_WINDOW_DAYS - 1)).isoformat()
        outside = (today - timedelta(days=_WINDOW_DAYS)).isoformat()
        path.write_text(
            "\n".join(
                [
                    _search_line(_ts(edge), provider="edge", ms=10),
                    _search_line(_ts(outside), provider="stale", ms=10),
                ]
            )
            + "\n",
            encoding="utf-8",
        )

        rows = {
            p["provider"]
            for p in _snap(UsageRecorder(history_path=str(path)))["endpoints"][
                "providers"
            ]
        }
        # The window is the last `_WINDOW_DAYS` UTC days ending today, so a
        # provider used only on the day before it is absent, not zero.
        assert rows == {"edge"}

    def test_first_and_last_seen_span_every_line_in_scope(self, tmp_path):
        path = tmp_path / "usage.jsonl"
        today = datetime.now(UTC).date()
        yesterday = (today - timedelta(days=1)).isoformat()
        path.write_text(
            "\n".join(
                [
                    _search_line(_ts(yesterday, "09:00:00"), provider="serper", ms=10),
                    _search_line(
                        _ts(yesterday, "17:00:00"),
                        provider="serper",
                        ms=20,
                        fell_back=True,
                    ),
                    _search_line(
                        _ts(today.isoformat(), "08:00:00"),
                        provider="serper",
                        ms=30,
                        error="ProviderError",
                    ),
                ]
            )
            + "\n",
            encoding="utf-8",
        )

        (row,) = _snap(UsageRecorder(history_path=str(path)))["endpoints"]["providers"]
        assert row["first_seen"] == _ts(yesterday, "09:00:00")
        assert row["last_seen"] == _ts(today.isoformat(), "08:00:00")
        days = {d["date"]: d for d in row["days"]}
        assert days[yesterday]["first_seen"] == _ts(yesterday, "09:00:00")
        assert days[yesterday]["last_seen"] == _ts(yesterday, "17:00:00")

    def test_a_search_line_without_a_provider_makes_no_row(self, tmp_path):
        path = tmp_path / "usage.jsonl"
        path.write_text(
            json.dumps(
                {"ts": _ts(_today()), "tool": "search", "ms": 5, "error": None}
            )
            + "\n",
            encoding="utf-8",
        )

        snap = _snap(UsageRecorder(history_path=str(path)))
        assert snap["endpoints"]["providers"] == []
        assert snap["totals"]["searches"] == 1

    def test_backfill_reproduces_the_live_series(self, tmp_path):
        """A journal written now, folded back in, gives the same series."""
        path = tmp_path / "usage.jsonl"
        live = UsageRecorder(history_path=str(path))
        live.record_search(
            provider="serper", ms=10, cost_usd=0.001, results=1, fell_back=False
        )
        live.record_search(
            provider="serper", ms=500, cost_usd=0.0, results=0, fell_back=True
        )
        live.record_search(
            provider="linkup", ms=20, cost_usd=0.002, results=1, fell_back=False
        )
        live.record_fetch(ms=5, chars=10, fallback=None)

        rebuilt = _snap(UsageRecorder(history_path=str(path)))
        assert rebuilt["endpoints"] == _snap(live)["endpoints"]

    def test_a_line_from_an_older_writer_still_aggregates(self, tmp_path):
        """No key the series reads is new, so an older line needs no migration."""
        path = tmp_path / "usage.jsonl"
        path.write_text(
            json.dumps(
                {
                    "ts": _ts(_today()),
                    "tool": "search",
                    "provider": "serper",
                    "ms": 12,
                    "error": None,
                }
            )
            + "\n",
            encoding="utf-8",
        )

        (row,) = _snap(UsageRecorder(history_path=str(path)))["endpoints"]["providers"]
        assert row["calls"] == 1
        assert row["latency_samples"] == 1
        assert (row["p50_ms"], row["p95_ms"]) == (12, 12)
        # Defaulted at read time, never invented.
        assert row["cost_usd"] == 0.0
        assert row["fell_back_calls"] == 0

    def test_a_line_written_before_the_rename_still_renders(self, tmp_path):
        """The journal is append-only and is *not* migrated, so a line an older
        writer left names `exa_free` -- and the dashboard has to render that
        name rather than drop the row or invent today's spelling for it. That is
        why `usage.py` reads `entry["provider"]` as an opaque string rather than
        a known name."""
        path = tmp_path / "usage.jsonl"
        path.write_text(
            _search_line(_ts(_today()), provider="exa_free") + "\n", encoding="utf-8"
        )

        (row,) = _snap(UsageRecorder(history_path=str(path)))["endpoints"]["providers"]
        assert row["provider"] == "exa_free"
        assert row["calls"] == 1
        assert row["cost_usd"] == 0.001

    def test_the_series_is_content_free_and_the_journal_gains_no_field(self, tmp_path):
        """The percentiles read the journal; they must not widen what it holds."""
        path = tmp_path / "usage.jsonl"
        rec = UsageRecorder(history_path=str(path))
        rec.record_search(
            provider="serper", ms=3, cost_usd=0.001, results=1, fell_back=False
        )
        rec.record_fetch(ms=4, chars=900, fallback="scrappa")

        lines = [
            json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()
        ]
        assert set(lines[0]) == {
            "ts",
            "tool",
            "provider",
            "ms",
            "cost_usd",
            "results",
            "fell_back",
            "error",
        }
        assert set(lines[1]) == {"ts", "tool", "ms", "chars", "fallback", "error"}

        # Neither the new surface nor a journal line can carry caller content:
        # the only recording entry points take names, counts and figures.
        for surface in (lines, _snap(rec)["endpoints"]):
            blob = json.dumps(surface)
            for marker in ("query", "http", "host", "title", "snippet", "url"):
                assert marker not in blob
        for method in (UsageRecorder.record_search, UsageRecorder.record_fetch):
            passed = set(inspect.signature(method).parameters)
            assert not passed & {"query", "url", "host", "title", "text", "snippet"}


class TestRecent:
    def test_the_deque_is_bounded_and_newest_first(self):
        rec = UsageRecorder(recent=2)
        for _ in range(3):
            rec.record_search(
                provider="serper", ms=1, cost_usd=0.0, results=0, fell_back=False
            )

        recent = _snap(rec)["recent"]
        assert len(recent) == 2
        assert recent[0]["ts"] >= recent[1]["ts"]

    def test_entries_carry_the_journal_schema(self):
        rec = UsageRecorder()
        rec.record_fetch(ms=7, chars=42, fallback="crawl4ai")

        (entry,) = _snap(rec)["recent"]
        assert set(entry) == {"ts", "tool", "ms", "chars", "fallback", "error"}
        assert entry["tool"] == "fetch"
        assert entry["fallback"] == "crawl4ai"


class TestJournal:
    def test_round_trip_rebuilds_an_identical_snapshot(self, tmp_path):
        path = tmp_path / "usage.jsonl"
        rec = UsageRecorder(history_path=str(path))
        rec.record_search(
            provider="serper", ms=12, cost_usd=0.001, results=4, fell_back=False
        )
        rec.record_search(
            provider="linkup",
            ms=30,
            cost_usd=0.0,
            results=0,
            fell_back=True,
            error="ProviderError",
        )
        rec.record_fetch(ms=8, chars=1200, fallback="scrappa")

        lines = path.read_text(encoding="utf-8").splitlines()
        assert len(lines) == 3
        assert [json.loads(line)["tool"] for line in lines] == [
            "search",
            "search",
            "fetch",
        ]

        fresh = UsageRecorder(history_path=str(path))
        original = _snap(rec)
        rebuilt = _snap(fresh)
        for key in (
            "since",
            "totals",
            "days",
            "providers",
            "endpoints",
            "recent",
            "journal",
        ):
            assert rebuilt[key] == original[key], key

    def test_the_journal_carries_no_content(self, tmp_path):
        """The property that makes it safe to keep across restarts."""
        path = tmp_path / "usage.jsonl"
        rec = UsageRecorder(history_path=str(path))
        rec.record_search(
            provider="serper", ms=3, cost_usd=0.001, results=1, fell_back=False
        )

        line = path.read_text(encoding="utf-8")
        assert "query" not in line
        assert "http" not in line
        assert set(json.loads(line)) == {
            "ts",
            "tool",
            "provider",
            "ms",
            "cost_usd",
            "results",
            "fell_back",
            "error",
        }

    def test_utc_days_bucket_across_midnight(self, tmp_path):
        path = tmp_path / "usage.jsonl"
        today = datetime.now(UTC).date()
        yesterday = today - timedelta(days=1)
        path.write_text(
            "\n".join(
                [
                    _search_line(_ts(yesterday.isoformat(), "23:59:00")),
                    _search_line(_ts(today.isoformat(), "00:01:00")),
                ]
            )
            + "\n",
            encoding="utf-8",
        )

        days = {
            d["date"]: d
            for d in _snap(UsageRecorder(history_path=str(path)))["days"]
        }
        assert days[yesterday.isoformat()]["searches"] == 1
        assert days[today.isoformat()]["searches"] == 1

    def test_a_missing_file_is_created_at_startup(self, tmp_path):
        path = tmp_path / "usage.jsonl"
        assert not path.exists()
        rec = UsageRecorder(history_path=str(path))
        assert path.is_file()
        assert path.read_text(encoding="utf-8") == ""
        rec.record_fetch(ms=1, chars=1, fallback=None)
        assert len(path.read_text(encoding="utf-8").splitlines()) == 1

    def test_corrupt_lines_are_skipped_and_counted(
        self, tmp_path, log_records: list[Any]
    ):
        path = tmp_path / "usage.jsonl"
        path.write_text(
            "\n".join(
                [
                    _search_line(_ts(_today())),
                    "not json at all",
                    '["a", "list"]',
                    '{"tool": "search"}',
                    "",
                ]
            )
            + "\n",
            encoding="utf-8",
        )

        rec = UsageRecorder(history_path=str(path))

        assert _snap(rec)["totals"]["searches"] == 1
        (event,) = [
            r for r in log_records if r.record["message"] == "dashboard.journal_skipped"
        ]
        assert event.record["extra"]["skipped"] == 3

    def test_append_failure_is_logged_once_then_the_writer_gives_up(
        self, tmp_path, monkeypatch, log_records: list[Any]
    ):
        path = tmp_path / "usage.jsonl"
        rec = UsageRecorder(history_path=str(path))

        def boom(*_args: object, **_kwargs: object) -> None:
            raise OSError("disk full")

        monkeypatch.setattr(Path, "open", boom)
        rec.record_search(
            provider="serper", ms=5, cost_usd=0.001, results=1, fell_back=False
        )
        rec.record_search(
            provider="serper", ms=5, cost_usd=0.001, results=1, fell_back=False
        )

        errors = [
            r for r in log_records if r.record["message"] == "dashboard.journal_error"
        ]
        assert len(errors) == 1
        assert errors[0].record["extra"]["reason"] == "disk full"
        # The broken volume does not stop the aggregates this process holds.
        snap = _snap(rec)
        assert snap["journal"]["failed"] is True
        assert snap["totals"]["searches"] == 2

    def test_a_missing_parent_directory_names_the_path(self, tmp_path):
        missing = tmp_path / "nope" / "usage.jsonl"
        with pytest.raises(ValueError) as exc:
            UsageRecorder(history_path=str(missing))
        assert str(missing) in str(exc.value)
    def test_the_journal_writes_its_keys_in_the_declared_order(self, tmp_path):
        """Field order is part of the append-only format, not an accident.

        `usage.py` now declares each line kind as a dataclass whose fields *are*
        the journal's keys, so a set assertion no longer pins the whole format:
        a line already on disk keeps the order its writer used, and this is the
        read that says which order that was.
        """
        path = tmp_path / "usage.jsonl"
        rec = UsageRecorder(history_path=str(path))
        rec.record_search(
            provider="serper", ms=5, cost_usd=0.001, results=1, fell_back=False
        )
        rec.record_search(
            provider="serper",
            ms=9,
            cost_usd=0.0,
            results=0,
            fell_back=False,
            error="ProviderError",
            run="run-1",
            step=1,
        )
        rec.record_fetch(ms=6, chars=10, fallback=None)
        rec.record_fetch(
            ms=7, chars=20, fallback="scrappa", cost_usd=0.0005, run="run-1", step=2
        )
        rec.record_answer(
            run="run-1",
            model="m",
            depth="brief",
            searches=1,
            results=1,
            fetched=1,
            material_chars=10,
            prompt_tokens=1,
            completion_tokens=1,
            answer_chars=5,
            cited=1,
            cited_invalid=0,
            sources=1,
            model_cost_usd=None,
            ms=3,
        )

        lines = path.read_text(encoding="utf-8").splitlines()
        keys = [list(json.loads(line)) for line in lines]
        plain_search = ["ts", "tool", "provider", "ms", "cost_usd", "results",
                        "fell_back", "error"]
        assert keys[0] == plain_search
        assert keys[1] == plain_search + ["run", "step"]
        plain_fetch = ["ts", "tool", "ms", "chars", "fallback", "error"]
        assert keys[2] == plain_fetch
        # A priced fetch writes `cost_usd` after `error`, where the writer that
        # added it conditionally always put it.
        assert keys[3] == plain_fetch + ["cost_usd", "run", "step"]
        assert keys[4] == [
            "ts",
            "tool",
            "run",
            "model",
            "depth",
            "searches",
            "results",
            "fetched",
            "material_chars",
            "prompt_tokens",
            "completion_tokens",
            "answer_chars",
            "cited",
            "cited_invalid",
            "sources",
            "model_cost_usd",
            "ms",
            "error",
        ]


    def test_an_unwritable_path_is_a_startup_error(self, tmp_path, monkeypatch):
        path = tmp_path / "usage.jsonl"

        def boom(*_args: object, **_kwargs: object) -> None:
            raise PermissionError(13, "Permission denied", str(path))

        monkeypatch.setattr(Path, "open", boom)

        with pytest.raises(ValueError) as exc:
            UsageRecorder(history_path=str(path))

        assert str(path) in str(exc.value)
        assert "Permission denied" in str(exc.value)


class TestPrune:
    def test_day_buckets_older_than_keep_days_are_dropped(self, tmp_path):
        path = tmp_path / "usage.jsonl"
        today = datetime.now(UTC).date()
        old = (today - timedelta(days=5)).isoformat()
        path.write_text(
            "\n".join(
                [
                    _search_line(_ts(old)),
                    _search_line(_ts(today.isoformat())),
                ]
            )
            + "\n",
            encoding="utf-8",
        )

        rec = UsageRecorder(history_path=str(path), keep_days=1)
        assert old not in rec._days
        assert today.isoformat() in rec._days

    def test_a_generous_keep_days_retains_old_buckets(self, tmp_path):
        path = tmp_path / "usage.jsonl"
        today = datetime.now(UTC).date()
        old = (today - timedelta(days=5)).isoformat()
        path.write_text(_search_line(_ts(old)) + "\n", encoding="utf-8")

        rec = UsageRecorder(history_path=str(path), keep_days=370)
        assert old in rec._days


class TestTheAnswerLine:
    """Agent mode's third line kind: accepted here, folded elsewhere.

    This issue owns the *whitelist*: `_apply` returned False for any `tool` that
    was not `search` or `fetch`, and `_backfill` counts a False as
    `dashboard.journal_skipped` -- so an `answer` line was dropped with a warning
    on every restart. What the line's own figures become (model spend, tokens,
    the per-provider citation counts) is the ranking-data work, which reads them
    off this line; here it is only required to be folded, not miscounted.
    """

    @staticmethod
    def _answer_line(ts: str, *, error: str | None = None) -> str:
        return json.dumps(
            {
                "ts": ts,
                "tool": "answer",
                "run": "a1b2c3d4",
                "model": "test-model",
                "depth": "brief",
                "searches": 1,
                "results": 5,
                "fetched": 0,
                "material_chars": 1200,
                "prompt_tokens": 900,
                "completion_tokens": 120,
                "answer_chars": 480,
                "cited": 2,
                "cited_invalid": 1,
                "sources": 2,
                "model_cost_usd": None,
                "ms": 900,
                "error": error,
            }
        )

    def test_it_backfills_rather_than_being_skipped(
        self, tmp_path, log_records: list[Any]
    ):
        path = tmp_path / "usage.jsonl"
        path.write_text(
            "\n".join(
                [_search_line(_ts(_today())), self._answer_line(_ts(_today()))]
            )
            + "\n",
            encoding="utf-8",
        )

        rec = UsageRecorder(history_path=str(path))

        assert [
            r for r in log_records if r.record["message"] == "dashboard.journal_skipped"
        ] == []
        assert [e["tool"] for e in _snap(rec)["recent"]] == ["answer", "search"]
        # A run-carrying search line is still a search: real provider spend.
        assert _snap(rec)["totals"]["searches"] == 1

    def test_a_live_answer_line_is_not_miscounted_as_a_fetch(self, tmp_path):
        """The bug the whitelist widening could have introduced instead."""
        path = tmp_path / "usage.jsonl"
        rec = UsageRecorder(history_path=str(path))

        rec.record_answer(
            run="a1b2c3d4",
            model="test-model",
            depth="brief",
            searches=1,
            results=5,
            fetched=0,
            material_chars=1200,
            prompt_tokens=900,
            completion_tokens=120,
            answer_chars=480,
            cited=2,
            cited_invalid=1,
            sources=2,
            model_cost_usd=None,
            ms=900,
        )

        assert _snap(rec)["totals"]["fetches"] == 0
        assert _snap(rec)["totals"]["searches"] == 0
        assert _snap(rec)["totals"]["errors"] == 0

    def test_an_answer_error_counts_as_an_error(self, tmp_path):
        path = tmp_path / "usage.jsonl"
        rec = UsageRecorder(history_path=str(path))

        rec.record_answer(
            run="a1b2c3d4",
            model="test-model",
            depth="report",
            searches=3,
            results=0,
            fetched=0,
            material_chars=0,
            prompt_tokens=None,
            completion_tokens=None,
            answer_chars=0,
            cited=0,
            cited_invalid=0,
            sources=0,
            model_cost_usd=None,
            ms=40,
            error="AgentFailed",
        )

        assert _snap(rec)["totals"]["errors"] == 1

    def test_the_retrieval_keys_are_additive(self, tmp_path):
        """A plain search line's shape is unchanged; a run-carrying one is tagged."""
        path = tmp_path / "usage.jsonl"
        rec = UsageRecorder(history_path=str(path))

        rec.record_search(
            provider="serper", ms=5, cost_usd=0.001, results=1, fell_back=False
        )
        rec.record_search(
            provider="serper",
            ms=5,
            cost_usd=0.001,
            results=1,
            fell_back=False,
            run="a1b2c3d4",
            step=2,
        )
        rec.record_fetch(ms=5, chars=10, fallback=None)
        rec.record_fetch(ms=5, chars=10, fallback=None, run="a1b2c3d4", step=1)

        lines = [json.loads(line) for line in path.read_text().splitlines()]
        assert "run" not in lines[0] and "step" not in lines[0]
        assert (lines[1]["run"], lines[1]["step"]) == ("a1b2c3d4", 2)
        assert "run" not in lines[2] and "step" not in lines[2]
        assert (lines[3]["run"], lines[3]["step"]) == ("a1b2c3d4", 1)


def _retrieval_line(
    ts: str,
    *,
    run: str = "run-1",
    step: int = 1,
    provider: str = "serper",
    results: int = 5,
    error: str | None = None,
) -> str:
    """A run-carrying ``search`` line, as agent mode's retrieval steps write it."""
    return json.dumps(
        {
            "ts": ts,
            "tool": "search",
            "provider": provider,
            "ms": 20,
            "cost_usd": 0.007,
            "results": results,
            "fell_back": False,
            "error": error,
            "run": run,
            "step": step,
        }
    )


def _answer_line(
    ts: str,
    *,
    run: str = "run-1",
    model: str = "test-model",
    depth: str = "brief",
    searches: int = 1,
    results: int = 5,
    fetched: int = 0,
    material_chars: int = 1200,
    prompt_tokens: int | None = 900,
    completion_tokens: int | None = 120,
    answer_chars: int = 480,
    cited: int = 2,
    cited_invalid: int = 1,
    sources: int = 2,
    model_cost_usd: float | None = 0.0012,
    ms: int = 900,
    error: str | None = None,
) -> str:
    """One ``answer`` line: the spec's journal table, field for field."""
    return json.dumps(
        {
            "ts": ts,
            "tool": "answer",
            "run": run,
            "model": model,
            "depth": depth,
            "searches": searches,
            "results": results,
            "fetched": fetched,
            "material_chars": material_chars,
            "prompt_tokens": prompt_tokens,
            "completion_tokens": completion_tokens,
            "answer_chars": answer_chars,
            "cited": cited,
            "cited_invalid": cited_invalid,
            "sources": sources,
            "model_cost_usd": model_cost_usd,
            "ms": ms,
            "error": error,
        }
    )


class TestAnswerRanking:
    """The `answer` line's fold: the model's figures, and the citation join.

    The ranking data is the point of the section: per-provider `retrieved` and
    `cited`, joined on the `run` the retrieval lines carry. What is pinned here
    is the rule as implemented -- see `UsageRecorder._citation_rows` for why it
    is exact for a one-provider run and a documented over-count otherwise.
    """

    def test_the_model_figures_fold_into_the_answers_section(self):
        rec = UsageRecorder()
        rec.record_answer(
            run="run-1",
            model="test-model",
            depth="brief",
            searches=1,
            results=5,
            fetched=0,
            material_chars=1200,
            prompt_tokens=900,
            completion_tokens=120,
            answer_chars=480,
            cited=2,
            cited_invalid=1,
            sources=2,
            model_cost_usd=0.0012,
            ms=900,
        )

        snap = _snap(rec)
        answers = snap["answers"]
        assert answers["calls"] == 1
        assert answers["errors"] == 0
        assert answers["cited"] == 2
        assert answers["cited_invalid"] == 1
        assert answers["sources"] == 2
        assert answers["answer_chars"] == 480
        assert answers["prompt_tokens"] == 900
        assert answers["completion_tokens"] == 120
        assert answers["token_calls"] == 1
        assert answers["model_cost_usd"] == pytest.approx(0.0012)
        assert answers["priced_calls"] == 1
        assert answers["mean_ms"] == 900
        assert answers["models"] == ["test-model"]
        # An answer is not a search: the model call is not provider spend.
        assert snap["totals"]["searches"] == 0
        assert snap["totals"]["fetches"] == 0
        # The per-day figures the spend view draws.
        assert snap["days"][-1]["answers"] == 1
        assert snap["days"][-1]["model_cost_usd"] == pytest.approx(0.0012)

    def test_a_null_model_cost_is_unknown_never_zero(self):
        """An unset price is unknown, never a free call."""
        rec = UsageRecorder()
        rec.record_answer(
            run="run-1",
            model="test-model",
            depth="brief",
            searches=1,
            results=5,
            fetched=0,
            material_chars=1200,
            prompt_tokens=None,
            completion_tokens=None,
            answer_chars=480,
            cited=0,
            cited_invalid=0,
            sources=0,
            model_cost_usd=None,
            ms=900,
        )

        snap = _snap(rec)
        answers = snap["answers"]
        assert answers["model_cost_usd"] is None
        assert answers["priced_calls"] == 0
        # The token counts are the honest stand-in, and are absent too when the
        # endpoint reported no `usage` -- never a local estimate.
        assert answers["prompt_tokens"] is None
        assert answers["completion_tokens"] is None
        assert answers["token_calls"] == 0
        assert snap["days"][-1]["model_cost_usd"] is None

    def test_a_partial_price_sum_says_how_much_of_the_whole_it_covers(self):
        rec = UsageRecorder()
        for run, cost in (("run-1", None), ("run-2", 0.002)):
            rec.record_answer(
                run=run,
                model="test-model",
                depth="brief",
                searches=1,
                results=5,
                fetched=0,
                material_chars=1200,
                prompt_tokens=100,
                completion_tokens=10,
                answer_chars=10,
                cited=1,
                cited_invalid=0,
                sources=1,
                model_cost_usd=cost,
                ms=100,
            )

        answers = _snap(rec)["answers"]
        assert answers["calls"] == 2
        assert answers["priced_calls"] == 1
        assert answers["model_cost_usd"] == pytest.approx(0.002)
        assert answers["token_calls"] == 2

    def test_per_provider_retrieved_and_cited_come_from_the_run_join(self):
        rec = UsageRecorder()
        # One run, two steps, one provider: retrieved sums, cited is credited
        # once per run.
        rec.record_search(
            provider="serper",
            ms=5,
            cost_usd=0.007,
            results=5,
            fell_back=False,
            run="run-1",
            step=1,
        )
        rec.record_search(
            provider="serper",
            ms=5,
            cost_usd=0.007,
            results=3,
            fell_back=False,
            run="run-1",
            step=2,
        )
        rec.record_answer(
            run="run-1",
            model="test-model",
            depth="report",
            searches=2,
            results=8,
            fetched=0,
            material_chars=2000,
            prompt_tokens=1000,
            completion_tokens=200,
            answer_chars=600,
            cited=3,
            cited_invalid=0,
            sources=3,
            model_cost_usd=None,
            ms=1500,
        )
        # A second run served by another provider, with a citation of its own.
        rec.record_search(
            provider="linkup",
            ms=5,
            cost_usd=0.007,
            results=5,
            fell_back=False,
            run="run-2",
            step=1,
        )
        rec.record_answer(
            run="run-2",
            model="test-model",
            depth="brief",
            searches=1,
            results=5,
            fetched=0,
            material_chars=900,
            prompt_tokens=800,
            completion_tokens=90,
            answer_chars=300,
            cited=1,
            cited_invalid=0,
            sources=1,
            model_cost_usd=None,
            ms=700,
        )

        rows = {row["provider"]: row for row in _snap(rec)["answers"]["providers"]}
        assert rows["serper"] == {"provider": "serper", "retrieved": 8, "cited": 3}
        assert rows["linkup"] == {"provider": "linkup", "retrieved": 5, "cited": 1}
        # Ordered by citations, then results, then name: the ranking it exists for.
        assert [row["provider"] for row in _snap(rec)["answers"]["providers"]] == [
            "serper",
            "linkup",
        ]

    def test_a_failed_step_contributes_no_results_and_no_credit(self):
        rec = UsageRecorder()
        rec.record_search(
            provider="serper",
            ms=5,
            cost_usd=0.007,
            results=5,
            fell_back=False,
            run="run-1",
            step=1,
        )
        rec.record_search(
            provider="linkup",
            ms=5,
            cost_usd=0.0,
            results=0,
            fell_back=True,
            error="ProviderError",
            run="run-1",
            step=2,
        )
        rec.record_answer(
            run="run-1",
            model="test-model",
            depth="report",
            searches=2,
            results=5,
            fetched=0,
            material_chars=1000,
            prompt_tokens=500,
            completion_tokens=50,
            answer_chars=200,
            cited=2,
            cited_invalid=0,
            sources=2,
            model_cost_usd=None,
            ms=400,
        )

        snap = _snap(rec)
        (row,) = snap["answers"]["providers"]
        assert row == {"provider": "serper", "retrieved": 5, "cited": 2}
        # The failed search is still a provider call in the search totals -- it
        # just contributed nothing to the answer, so it has no citation row.
        assert snap["totals"]["searches"] == 2
        assert snap["totals"]["fallbacks"] == 1

    def test_a_plain_search_is_never_part_of_a_run(self):
        rec = UsageRecorder()
        rec.record_search(
            provider="serper", ms=5, cost_usd=0.001, results=5, fell_back=False
        )
        rec.record_answer(
            run="run-1",
            model="test-model",
            depth="brief",
            searches=0,
            results=0,
            fetched=0,
            material_chars=0,
            prompt_tokens=None,
            completion_tokens=None,
            answer_chars=0,
            cited=0,
            cited_invalid=0,
            sources=0,
            model_cost_usd=None,
            ms=5,
            error="AgentFailed",
        )

        snap = _snap(rec)
        assert snap["answers"]["providers"] == []
        assert snap["answers"]["errors"] == 1
        assert snap["totals"]["searches"] == 1

    def test_a_two_provider_run_credits_each_contributor_with_the_run(self):
        """The documented rule, pinned: exact for one provider, shared otherwise.

        A mid-walk fallback that later succeeded leaves two providers' results
        in one run's material, and the journal does not carry the material's
        numbering -- so the run's citation count is credited to each
        contributor rather than split by a guessed ratio.
        """
        rec = UsageRecorder()
        for step, provider, results in ((1, "serper", 5), (2, "linkup", 3)):
            rec.record_search(
                provider=provider,
                ms=5,
                cost_usd=0.007,
                results=results,
                fell_back=False,
                run="run-1",
                step=step,
            )
        rec.record_answer(
            run="run-1",
            model="test-model",
            depth="report",
            searches=2,
            results=8,
            fetched=0,
            material_chars=2000,
            prompt_tokens=900,
            completion_tokens=100,
            answer_chars=400,
            cited=4,
            cited_invalid=0,
            sources=4,
            model_cost_usd=None,
            ms=900,
        )

        rows = {row["provider"]: row for row in _snap(rec)["answers"]["providers"]}
        assert rows["serper"] == {"provider": "serper", "retrieved": 5, "cited": 4}
        assert rows["linkup"] == {"provider": "linkup", "retrieved": 3, "cited": 4}

    def test_an_orphan_run_keeps_its_results_and_gains_no_citation(self, tmp_path):
        """A process that died mid-call: the retrieval stands, the credit cannot."""
        path = tmp_path / "usage.jsonl"
        path.write_text(
            _retrieval_line(_ts(_today()), run="gone", provider="serper") + "\n",
            encoding="utf-8",
        )

        answers = _snap(UsageRecorder(history_path=str(path)))["answers"]

        assert answers["calls"] == 0
        assert answers["providers"] == [
            {"provider": "serper", "retrieved": 5, "cited": 0}
        ]

    def test_cited_invalid_is_the_models_and_never_a_providers(self):
        rec = UsageRecorder()
        rec.record_search(
            provider="serper",
            ms=5,
            cost_usd=0.007,
            results=5,
            fell_back=False,
            run="run-1",
            step=1,
        )
        rec.record_answer(
            run="run-1",
            model="test-model",
            depth="brief",
            searches=1,
            results=5,
            fetched=0,
            material_chars=1000,
            prompt_tokens=900,
            completion_tokens=100,
            answer_chars=400,
            cited=0,
            cited_invalid=2,
            sources=0,
            model_cost_usd=None,
            ms=900,
        )

        snap = _snap(rec)
        assert snap["answers"]["cited_invalid"] == 2
        # The citation row carries the two provider figures and nothing else --
        # an invented citation is a property of the prose, not of the results.
        (row,) = snap["answers"]["providers"]
        assert set(row) == {"provider", "retrieved", "cited"}
        assert set(snap["providers"][0]) == {
            "provider",
            "calls",
            "errors",
            "cost_usd",
            "avg_ms",
            "last_used",
        }

    def test_the_answers_section_round_trips_through_the_journal(self, tmp_path):
        path = tmp_path / "usage.jsonl"
        rec = UsageRecorder(history_path=str(path))
        rec.record_search(
            provider="serper",
            ms=5,
            cost_usd=0.007,
            results=5,
            fell_back=False,
            run="run-1",
            step=1,
        )
        rec.record_fetch(ms=5, chars=900, fallback=None, run="run-1", step=1)
        rec.record_answer(
            run="run-1",
            model="test-model",
            depth="brief",
            searches=1,
            results=5,
            fetched=1,
            material_chars=900,
            prompt_tokens=900,
            completion_tokens=120,
            answer_chars=480,
            cited=2,
            cited_invalid=1,
            sources=2,
            model_cost_usd=0.0012,
            ms=900,
        )

        assert len(path.read_text(encoding="utf-8").splitlines()) == 3
        fresh = UsageRecorder(history_path=str(path))

        original = _snap(rec)
        rebuilt = _snap(fresh)
        for key in ("answers", "days", "providers", "totals", "recent", "endpoints"):
            assert rebuilt[key] == original[key], key

    def test_the_journal_still_carries_no_content_with_an_answer_line(self, tmp_path):
        """The ranking data's whole premise: counts, names and figures only."""
        path = tmp_path / "usage.jsonl"
        rec = UsageRecorder(history_path=str(path))
        rec.record_search(
            provider="serper",
            ms=5,
            cost_usd=0.007,
            results=5,
            fell_back=False,
            run="run-1",
            step=1,
        )
        rec.record_answer(
            run="run-1",
            model="test-model",
            depth="brief",
            searches=1,
            results=5,
            fetched=0,
            material_chars=900,
            prompt_tokens=900,
            completion_tokens=120,
            answer_chars=480,
            cited=2,
            cited_invalid=1,
            sources=2,
            model_cost_usd=None,
            ms=900,
        )

        blob = path.read_text(encoding="utf-8")
        for marker in ("query", "http", "host", "title", "snippet", "url"):
            assert marker not in blob, marker
        # Nor in the aggregate the page reads, which is a second surface.
        surface = json.dumps(_snap(rec)["answers"])
        for marker in ("query", "http", "host", "title", "snippet", "url"):
            assert marker not in surface, marker
        # And no recording entry point could put one there.
        for method in (UsageRecorder.record_answer, UsageRecorder.record_search):
            passed = set(inspect.signature(method).parameters)
            assert not passed & {"query", "url", "host", "title", "text", "snippet"}

    def test_unknown_keys_on_either_line_are_still_tolerated(self, tmp_path):
        """`_apply` reads by key: a writer that adds one is still folded."""
        path = tmp_path / "usage.jsonl"
        retrieval = json.loads(_retrieval_line(_ts(_today())))
        retrieval["future_key"] = {"anything": 1}
        answer = json.loads(_answer_line(_ts(_today())))
        answer["future_key"] = [1, 2, 3]
        path.write_text(
            "\n".join([json.dumps(retrieval), json.dumps(answer)]) + "\n",
            encoding="utf-8",
        )

        rec = UsageRecorder(history_path=str(path))

        snap = _snap(rec)
        assert snap["totals"]["searches"] == 1
        assert snap["answers"]["calls"] == 1
        assert snap["answers"]["providers"] == [
            {"provider": "serper", "retrieved": 5, "cited": 2}
        ]

    def test_a_malformed_figure_is_absent_rather_than_a_zero(self, tmp_path):
        """A count that is not a count does not fold as one."""
        path = tmp_path / "usage.jsonl"
        answer = json.loads(_answer_line(_ts(_today())))
        answer["cited"] = "2"
        answer["model_cost_usd"] = "free"
        answer["prompt_tokens"] = None
        answer["completion_tokens"] = None
        path.write_text(json.dumps(answer) + "\n", encoding="utf-8")

        answers = _snap(UsageRecorder(history_path=str(path)))["answers"]

        assert answers["calls"] == 1
        assert answers["cited"] == 0
        assert answers["model_cost_usd"] is None
        assert answers["priced_calls"] == 0
        assert answers["prompt_tokens"] is None
        assert answers["token_calls"] == 0

    def test_the_existing_snapshot_fields_keep_their_names_and_meanings(self):
        rec = UsageRecorder()
        rec.record_search(
            provider="serper", ms=5, cost_usd=0.001, results=1, fell_back=False
        )
        rec.record_fetch(ms=5, chars=900, fallback="scrappa")

        snap = _snap(rec)
        assert set(snap) == {
            "since",
            "process_started_at",
            "totals",
            "days",
            "providers",
            "answers",
            "endpoints",
            "recent",
            "journal",
        }
        assert set(snap["totals"]) == {
            "searches",
            "fetches",
            "errors",
            "fallbacks",
            "search_cost_usd",
            "fetch_pages_via_fallback",
            "fetch_cost_usd",
            "priced_fetches",
        }
        assert set(snap["providers"][0]) == {
            "provider",
            "calls",
            "errors",
            "cost_usd",
            "avg_ms",
            "last_used",
        }
        # The day fields the answers fold and the fetch price add; the rest are
        # as they were.
        assert set(snap["days"][0]) == {
            "date",
            "searches",
            "fetches",
            "answers",
            "errors",
            "cost_usd",
            "model_cost_usd",
            "fetch_cost_usd",
        }
        assert set(snap["answers"]) == {
            "calls",
            "errors",
            "cited",
            "cited_invalid",
            "sources",
            "answer_chars",
            "prompt_tokens",
            "completion_tokens",
            "token_calls",
            "model_cost_usd",
            "priced_calls",
            "mean_ms",
            "models",
            "providers",
        }
        # An empty section is an empty list and nulls, never a zero row.
        assert snap["answers"]["calls"] == 0
        assert snap["answers"]["model_cost_usd"] is None
        assert snap["answers"]["providers"] == []
        assert snap["answers"]["mean_ms"] is None
        assert snap["answers"]["models"] == []

