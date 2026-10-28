# Metrics: per-endpoint latency and cost

The contract behind the per-provider speed and cost history: what the journal
holds, what is aggregated from it, over what window, and which three surfaces
publish the result. Read this before changing `usage.py`'s aggregates, adding a
journal key, or touching `GET /dashboard/metrics`, `seekwright --metrics` or the
dashboard's endpoint panel.

The numbers let a caller or the operator compare every enabled provider on how
fast it answers and what it costs, over recent history. Nothing here picks a
provider — the proxy never routes on cost ([architecture.md](../architecture.md),
*Why nothing picks the cheapest*); it reports, and the caller decides.

`[dashboard] history_path` (see [configuration.md](configuration.md)) is the
input. Everything below is derived from that file plus the in-memory counters
the same recorder keeps; no new configuration key is introduced.

## The journal line

One line per **terminal** call, written by `UsageRecorder._append`. Terminal
means the outcome the caller got: a default-route search whose first provider
failed and whose fallback served is **one** line, the fallback that answered.
The failed first attempt appears nowhere in the journal; its failure is on the
health board and in the log stream, per `UsageRecorder`'s docstring.

The table below covers the **`search` and `fetch`** lines — the two kinds the
figures on this page are folded from. `_append` also writes an `answer` line,
whose fields, and the `run`/`step` keys a `search` or `fetch` line carries
inside an `answer` walk, are [agent-mode.md](agent-mode.md)'s contract (*What is
recorded*). The `tool` row's guard admits that third value.

| Field | Type / unit | Written at | Source of the value |
|---|---|---|---|
| `ts` | string, ISO-8601 with UTC offset | `record_search` / `record_fetch` | `datetime.now(UTC).isoformat()`; the UTC **date** of this string is the aggregation day key (`_apply`) |
| `tool` | string literal, `"search"` \| `"fetch"` | `record_search` / `record_fetch` | the recording method called; validated in `_apply` |
| `ms` | integer, **milliseconds** | `record_search` / `record_fetch` | `elapsed_ms(started)`, a `time.monotonic()` delta truncated toward zero; measured in `SearchEngine.search` and, for fetch, in `FetchEngine._finish_served_call`. For a search it spans the **whole dispatch**, including a fallback walk — the clock starts in `SearchEngine.search` and is passed into `_walk_fallbacks` |
| `error` | string \| null — an **exception class name**, never a message | `record_search` / `record_fetch` | `type(exc).__name__` in `SearchEngine.search` (named-provider failure) and in `_walk_fallbacks` (ladder exhausted), forwarded to the recorder as `error=error` (`SearchEngine._record_failure`); `_raise_fetch_failure` on a fetch failure; `null` on success. Validated in `_apply` |
| `provider` | string — a provider *name* from the enabled set | `record_search` | `ProviderResult.provider` on success and the tried name on terminal failure, both recorded in `SearchEngine.search`. **Search lines only**; absent on fetch lines |
| `cost_usd` | float, **US dollars** for that one call | `record_search` / `record_fetch`, where a fetch line's is held out by `usage.py`'s `_entry` | **Search lines:** `float(ProviderResult.cost_usd or 0.0)` in `SearchEngine.search`; `0.0` on every failure (`SearchEngine._record_failure`). **Fetch lines:** the answering fallback's *declared* price for the one call it made — journalled in `FetchEngine._finish_served_call` and derived by `FetchEngine._fallback_cost_usd` off the price that fallback declares, `[fetch] cost_per_1k` having reached it through that fallback's builder (`fetcher._build_scrappa`); `factory._cost` is the same idiom on the search side — and **absent, never `0.0`**, whenever nothing was billed. See *The fetch line's money* below |
| `results` | integer, **count of results** returned | `record_search` | `len(result.results)` in `SearchEngine.search`; `0` on failure (`SearchEngine._record_failure`). Search lines only |
| `fell_back` | boolean | `record_search` | true iff the default-route ladder served the call, set and recorded in `SearchEngine.search`; `false` on the failure path (`SearchEngine._record_failure`). Search lines only |
| `chars` | integer, **characters** of extracted text | `record_fetch` | `len(page.text)` (`FetchEngine._finish_served_call`). Fetch lines only |
| `fallback` | string \| null — a fetch fallback *name* | `record_fetch` | `FetchEngine._finish_served_call`; `null` for the local fetcher **and for every failure**, per `record_fetch`'s docstring. Fetch lines only, and the name the line's `cost_usd` is derived from |

Schema invariants a reader depends on:

- `ms` is an **`int`**, not a float — `_apply` rejects anything else. A line
  with a float `ms` is skipped, not coerced.
- `ms` is truncated to whole milliseconds (`elapsed_ms`), so a sub-millisecond
  call records `0`. Percentiles inherit that floor; a fixture with values below
  1 ms cannot distinguish two providers.
- Every field is content-free by construction: counts, money, timing and a
  provider or fallback *name* (`usage.py`'s module docstring).
  `tests/test_usage.py::test_the_series_is_content_free_and_the_journal_gains_no_field`
  pins the exact key set of a search line, so adding one is a deliberate,
  visible act.

### The fetch line's money

A fetch line carries `cost_usd` **only when a fallback that declares a price
served the page**, and the figure is the price of the one *call* that fallback
made — not of the characters the caller received. A past-end `offset` still
fetched and billed the page, so it is priced like any other served page.

Each fallback declares its own price where the fallback is declared — Scrappa's
`0.30`/1k on `ScrappaFetcher.cost_per_1k`, `None` on the free and self-hosted
fallbacks — and the fallback's builder hands it the `[fetch] cost_per_1k`
correction (`fetcher._build_scrappa`), the same optional-key idiom a provider's
price uses (`factory._cost`). `FetchEngine._fallback_cost_usd` turns the
**answering** fallback's figure into one call's share: a walk served by a
different fallback than the one it tried records the answering one's price, and
a walk answered by a fallback that declares none records no money at all.
Scrappa bills **1 credit per request** on every endpoint at `$0.30`/1k by
default ([`providers.md`](providers.md), "Scrappa — `serp` (+ extraction, for
`fetch`)"), so a page it serves records `0.0003`; a deployment on the `$0.20`
pack sets `0.20` and records `0.0002`. One `[fetch] cost_per_1k` prices every
priced fallback in the ladder, which is the per-fallback override left open in
[configuration.md](configuration.md).

**Absent, never `0.0`.** The key is missing — not zero — when nothing was
billed: the local fetcher (`fallback` is `null`), every failure, and any
fallback that declares no price, since `crawl4ai` is the operator's own renderer
and `jina` is keyless (`Crawl4aiFetcher.cost_per_1k` and `JinaFetcher.cost_per_1k`
are both `None`). A `0.0` there would claim a measured free call and leave the
money total covering pages it knows nothing about. A *declared* price of zero is
the one real zero, and only a fallback that declares one can produce it.

In the aggregate the fetch money is `totals.fetch_cost_usd`, beside
`search_cost_usd` and `fetch_pages_via_fallback`, with `totals.priced_fetches` as
the sample size — the same pair the model figures keep. The `days[]` rows carry
`fetch_cost_usd` under the same rule; both are built by `snapshot`. A ladder
with no priced fallback reports **no price and the page count alone**: `null`,
never `0.0`.

Two caveats belong beside the number rather than in a footnote:

- **Declared, not invoiced.** This is the fallback's published pack rate, the
  same *declared* basis every search `cost_usd` in the tree uses; no surface
  claims to have seen an invoice.
- **It can understate.** Whether `javascript=1` on the scraper costs more than
  one credit is unverified ([`providers.md`](providers.md), "Scrappa — `serp`
  (+ extraction, for `fetch`)"); if it does, this flat per-call figure is low,
  and the fix is a per-fallback multiplier rather than a different source.

### Does the schema have to change for percentiles?

**No.** A percentile needs the provider, the day, the elapsed milliseconds, and
whether that figure is attributable to the provider. All four are already in the
line — `provider`, the date part of `ts`, `ms`, and `fell_back` + `error`. No
field is added, no field changes meaning, and there is no migration.

### Backward and forward compatibility

Lines written by an **older** version stay readable, and lines written by the
new code stay readable by the **older** code, because nothing is added. The read
path enforces this by validating only four keys and defaulting the rest:

- `_apply` requires a `ts` that parses as ISO-8601, a `tool` in
  `{search, fetch}`, an `int` `ms`, and an `error` that is `null` or a string.
  Everything else is read with `.get` and defaulted: in `_apply_search`,
  `cost_usd` → `0.0` and `fell_back` → `False`; in `_apply_fetch`, `fallback` →
  `None`. A missing `provider` still counts the call in the day and totals
  buckets while creating no provider row.
- The **fetch** line's `cost_usd` is the one key whose default is *nothing at
  all*: a line without it folds as an unpriced page (`_apply_fetch`), so a
  journal written before the fetch price landed needs no migration, and an
  older reader simply ignores a key it does not know.
- A key that *left* is not covered by the rule below: a line carrying the
  pre-rename `rung` contributes nothing to `fetch_pages_via_fallback`, since
  this reader asks for `fallback` and finds nothing. Its `ms`, `chars` and
  `error` still fold like any other. Nothing errors and nothing is migrated; no
  journal with the old spelling has shipped.
- A line that will not parse, or that fails those four checks, is skipped and
  counted rather than fatal (`_backfill`).

The standing rule for future changes: **a new journal key must be optional and
defaulted at read time, and must never be added to `_apply`'s required set.**
That is what lets a rolling deploy run two versions against one journal: an
older reader skips a key it does not know.

## The aggregate

One object, produced by the recorder and published verbatim by all three
surfaces. Per provider there is a **window rollup** row carrying the same field
set plus a `days` series. The sketch below is the **shape** — field names,
nesting and types; its numbers are placeholders.

```json
{
  "window_days": 14,
  "providers": [
    {
      "provider": "serper",
      "calls": 120,
      "errors": 3,
      "fell_back_calls": 4,
      "latency_samples": 113,
      "p50_ms": 412,
      "p95_ms": 1890,
      "mean_ms": 640,
      "cost_usd": 0.0421,
      "cost_per_1k": 0.350833,
      "first_seen": "2026-10-03T09:12:44.512000+00:00",
      "last_seen": "2026-10-13T21:58:01.077000+00:00",
      "days": [
        {
          "date": "2026-10-03",
          "calls": 12,
          "errors": 0,
          "fell_back_calls": 0,
          "latency_samples": 12,
          "p50_ms": 401,
          "p95_ms": 1204,
          "mean_ms": 512,
          "cost_usd": 0.0036,
          "cost_per_1k": 0.3,
          "first_seen": "2026-10-03T09:12:44.512000+00:00",
          "last_seen": "2026-10-03T17:40:02.004000+00:00"
        }
      ]
    }
  ]
}
```

`window_days` is the constant `_WINDOW_DAYS` — the number of UTC days the series
covers, ending today. `providers` is the rollup: one entry per provider with at
least one terminal search line in the window. `days` is that provider's per-day
series, **oldest first**, one entry per day in the window with `calls >= 1`.

### Fields

Each field below appears in both the rollup row and the per-day row, with the
same meaning and unit; the per-day row adds `date`, and the rollup row adds
`provider` and `days`.

| Field | Unit | Scope | Source |
|---|---|---|---|
| `date` | UTC calendar date, `YYYY-MM-DD` | per-day rows only | the date part of `ts` (`_apply`) |
| `provider` | identifier (a provider name) | rollup rows only | journal `provider` (written by `record_search`, from `SearchEngine.search`) |
| `calls` | count of terminal search lines | row | journal lines for that provider in scope; the existing per-provider analogue is `_ProviderTotals.calls`, incremented in `_apply_search` |
| `errors` | count of terminal failures | row | lines with `error != null`, counted in `_apply_search` |
| `fell_back_calls` | count of ladder-served successes | row | lines with `fell_back == true`; the in-memory analogue is the `_fallbacks` counter, incremented in `_apply_search` |
| `latency_samples` | count — the size of the latency population | row | lines with `error == null` **and** `fell_back == false` (see *population*) |
| `p50_ms` | integer **milliseconds**, truncated | row | nearest-rank over the sorted `ms` of the latency population; `null` when `latency_samples == 0` |
| `p95_ms` | integer **milliseconds**, truncated | row | same population, `q = 0.95`; `null` when `latency_samples == 0` |
| `mean_ms` | integer **milliseconds**, truncated | row | `int(sum(ms) / latency_samples)`; `null` when `latency_samples == 0`. Same truncating idiom as the existing `avg_ms` in `snapshot` |
| `cost_usd` | float **US dollars**, rounded to 6 dp | row | sum of journal `cost_usd` over **all** lines in scope (accumulated in `_apply_search`); rounding follows `snapshot` |
| `cost_per_1k` | float **US dollars per 1,000 calls**, rounded to 6 dp | row | `cost_usd / calls * 1000` |
| `first_seen` | ISO-8601 UTC timestamp string | row | the earliest `ts` of that provider's lines in scope, verbatim |
| `last_seen` | ISO-8601 UTC timestamp string | row | the latest `ts` of that provider's lines in scope, verbatim |

`first_seen`/`last_seen` are taken over **all** of the provider's terminal
search lines in scope — errored and fell-back included — because they answer
"when was this provider last used", not "when was it last fast". In a rollup
row they are the window's first and last use, not the day's.

`cost_per_1k` is an **observed spend rate**, not the configured price of the same
name: `ProviderConfig.cost_per_1k` (resolved by `factory._cost`) and an adapter's
`cost_per_1k` attribute are what the provider *charges*. Because `calls` counts
every terminal line while a failure is recorded at `cost_usd = 0.0`
(`SearchEngine._record_failure`), it is not a like-for-like comparison:

```
measured $/1k  =  declared $/1k × (billed calls / all terminal calls)
```

A 20% terminal-failure rate therefore reads as "the provider got 20% cheaper".
That disagreement is a price signal only over billed calls, so read `calls`
against `errors` before treating a shortfall as a repricing.

### The latency population

Latency fields are computed over **successful, non-fell-back terminal searches
only** — `error is null and fell_back is false`. Two distinct reasons, one per
exclusion:

- A **terminal failure**'s `ms` is dominated by `policy.provider_timeout_seconds`
  (`PolicyConfig`, 10.0 by default), a constant of the deployment rather than a
  property of the provider. Included, `p95_ms` would mostly measure the timeout.
- A **fell-back success**'s `ms` is the whole ladder walk (`SearchEngine.search`
  starts the clock and records the line), not the answering provider's latency.
  Included, one provider would be charged for another's failure.

Neither exclusion hides anything: `errors` and `fell_back_calls` count exactly
what was left out, and `latency_samples` reports the population size, so a
window too thin to trust is visible on the surface rather than smoothed over.
`calls` is unaffected — it counts every terminal line for that provider — and so
is `cost_usd`, because a failure is recorded at `cost_usd = 0.0` by
construction (`SearchEngine._record_failure`) and a fell-back call really was
billed to the provider that answered.

### Percentile method

Nearest-rank on the ascending-sorted sample, with **no interpolation**:

```
n     = latency_samples
p50_ms = sorted_ms[ceil(0.50 * n) - 1]
p95_ms = sorted_ms[ceil(0.95 * n) - 1]
```

Indices are clamped to `[0, n-1]`. Worked consequences: `n = 1` gives both
percentiles that single value; `n = 2` gives `p50` the lower and `p95` the
higher; `n = 10` gives `p95` the maximum; `n = 20` gives `p95` the second
largest. The result is always a value some call actually recorded, which is the
property wanted: the figure answers "what will this provider cost me in time",
not "what is the smooth distribution". Interpolated quantiles
(`statistics.quantiles` and the linear default of a numeric library) would
return millisecond values no call produced. `sorted()` and `math.ceil` suffice;
no new dependency.

### Rounding and nulls

- Millisecond fields are integers, truncated. `ms` is already an integer, so
  nearest-rank needs no rounding; `mean_ms` truncates.
- Dollar fields round to 6 dp, the existing `snapshot` convention, so a float
  sum never ships binary-tail noise to a page whose point is readability.
- `p50_ms`, `p95_ms` and `mean_ms` are **`null`**, never `0`, when
  `latency_samples == 0`. Zero milliseconds reads as "instant"; absence reads as
  "no samples", and the renderers show a dash. This deliberately differs from
  the older lifetime `avg_ms` in `snapshot`, which reports `0` for a provider
  with no calls — that field predates the rule and is left alone.

### Ordering

- `providers` is sorted by **descending `cost_usd`, then provider name** — the
  same order as the existing `providers` list in the snapshot, so the
  dashboard's two tables line up row for row.
- `days` is **ascending by `date`** (oldest first), matching the `days` array the
  chart already renders from `snapshot`.

## Agent mode's ranking data (`answers`)

The snapshot carries a second aggregate beside `endpoints`, answering a different
question: not how fast or how expensive a provider is, but **how often its
results end up cited in a grounded answer**. It is folded from the `answer`
journal lines and from the `run` id the `search` lines carry. What agent mode
records is [agent-mode.md](agent-mode.md)'s contract; this is the shape the
snapshot publishes, and it is what the dashboard's agent-mode panel reads.

**Lifetime, not windowed.** `answers` and the per-provider rows in it are running
totals since the recorder began — the scope `totals` and `providers` above have,
and the scope a journal backfill rebuilds — where `endpoints` is the last 14 days.
Only the snapshot's top-level `days[]` rows are windowed.

| Field | Unit | What it counts |
|---|---|---|
| `calls` | count | terminal `answer` lines |
| `errors` | count | those recorded with an `error` |
| `cited` | count | valid `[n]` markers in the prose, deduplicated by index |
| `cited_invalid` | count | markers outside the material or not a number — **the model's, never a provider's** |
| `sources` | count | distinct URLs the prose cited (`len(sources)` of the response) |
| `answer_chars` | characters | the prose's length |
| `prompt_tokens` / `completion_tokens` | tokens, or `null` | the endpoint's own `usage` |
| `token_calls` | count | how many `calls` carried token counts — the sample size beside those two totals |
| `model_cost_usd` | dollars, or `null` | computed from those counts at `[agent] cost_per_1k_in`/`_out` |
| `priced_calls` | count | how many `calls` carried a price — the sample size beside that total |
| `mean_ms` | integer milliseconds, or `null` | the mean over `calls`; `null` when there are none |
| `models` | string[] | the model names seen, sorted |
| `providers` | rows | per-provider `{provider, retrieved, cited}`, ordered by citations, then results, then name; a provider with neither is **absent**, never a zero row |

Each row of the snapshot's top-level `days[]` array gains `answers` — that day's
`answer` count — and `model_cost_usd` under the same null rule as the lifetime
figure.

- **An unset model price is `null`, never `0.0`**, at both scopes: with the
  prices unset the line carries no cost, so the aggregate reports `null` rather
  than a free call, and `priced_calls` says how much of `calls` the total covers.
  The token totals have the same shape — `null` when no call reported `usage`,
  with `token_calls` beside them — which is the *counted, not priced* rule in
  `decisions.md`.
- **A run's `cited` is credited to a provider per run, not per citation**: every
  provider that contributed results to an answering run is credited with that
  run's `cited`, once. Exact for the ordinary one-provider run, and a documented
  over-count for a run a mid-walk fallback split across two, which the journal
  cannot resolve without inventing a split. The rule and its reasoning are
  [agent-mode.md](agent-mode.md)'s; `_citation_rows` (`usage.py`) is where it is
  implemented.
- **This section is not in the `endpoints` object.** `seekwright --metrics`,
  `GET /dashboard/metrics` and the endpoint panel publish `endpoints` alone; the
  agent-mode figures ride the snapshot the dashboard page reads
  (`GET /dashboard/data`).

## Window and retention

Three different bounds, which are not the same bound:

| Bound | Where | Value | What it bounds |
|---|---|---|---|
| `_WINDOW_DAYS` | `usage.py` — module constant, **not configurable** | 14 | What any surface reports: 14 zero-filled UTC days ending today (`snapshot` zero-fills them) |
| `keep_days` | `UsageRecorder.__init__` — constructor parameter, **not a config key** and not passed by the server (`build_app_context`) | 370 | In-memory **day** buckets, pruned on a UTC date change (`_roll`) |
| the journal file | `dashboard.history_path` | unbounded | Nothing prunes or rotates it (configuration.md; the journal is append-only by design) |

Consequences worth knowing before reading a number:

- The reported history is the **last 14 days** of the journal, as folded in at
  construction (`_backfill`); older calls stay on disk, unreported.
- `keep_days` prunes `self._days` only — **not** `self._providers`. The lifetime
  per-provider totals (`calls`, `cost_usd`, `avg_ms` in the snapshot's
  `providers`) keep counting days the series has dropped, which is why the two
  objects can disagree after 370 days. Do not read a rollup row as a lifetime
  figure.
- Because the file is never pruned, widening the window is a change to one
  constant rather than a migration, and **resetting history is moving the file
  aside**: nothing in the process would truncate it.

**A partial day** — today, in progress — reports the same shape over what has
landed: `calls` and `cost_usd` are partial sums, the percentiles are over the
partial sample, and there is no projection. The row appears with the day's first
call; read it beside `latency_samples`.

A provider with no calls in a day has **no row** for that day, and a provider
with no calls in the window has no rollup row at all. Absent, not zero: a zero
row would render as `0 ms` and `$0.0000`, which is a claim rather than an
absence. This is the opposite of the global `days` array, which `snapshot`
zero-fills because the chart's axis needs every day present.

Day boundaries are **UTC midnight**, from the date part of `ts` (`_apply`) and
`datetime.now(UTC).date()` (`snapshot`) — not the process's local midnight, so a
container in any timezone buckets the same way.

## Surfaces

All three publish **the same object**, produced in one place: the recorder gains
a method returning the object above, and `snapshot()` carries it under a
top-level `"endpoints"` key. The route and the CLI both read it from the
snapshot, so the terminal and the browser cannot drift: `json.loads` of the CLI's
`--json` output equals the route body, and that body equals
`snapshot()["endpoints"]`, a tested property.

Each surface below is stated as the rules it must hold and the command or route
that produces it. The **contract is the field tables above**: this section fixes
where the values appear and what may not move, never a second copy of the
schema.

### CLI: `seekwright --metrics [--json]`

A flag, not a subcommand: the CLI is a single `argparse` parser with no
subparsers — `cli.py`'s `main` dispatches on `argv[0]` over `_SUBCOMMANDS` — and
`check` is the report-and-exit precedent. `--json` is a companion flag as
`--live` is to `--check`, so `--json` without `--metrics` is a parser error, as
`--live` without `--check` is.

- It reads `dashboard.history_path` by constructing a `UsageRecorder` directly
  and **never imports `server`** (`cli.py`'s module docstring): no providers are
  built, no network call is made, nothing is billed.
- `dashboard.enabled` does **not** gate it — that key gates the HTTP page. With
  `enabled = false` the CLI report is unchanged while `GET /dashboard` and
  `GET /dashboard/metrics` both answer `404`.
- A `history_path` whose parent directory is missing or whose path the process
  cannot write is the same startup error the server raises, reported
  identically: `SystemExit("seekwright: dashboard.history_path: <reason>")`
  (`build_app_context`), exit code 1.
- `--metrics` combined with `--check`, `--live`, `--http`, `--host`, `--port` or
  `--allowed-host` is a parser error: it is a report-and-exit mode and serves
  nothing.
- Exit code is **0** whenever the report was produced — including with no
  journal configured and with an empty window. There is no failure mode that
  makes it non-zero except the bad `history_path` above.

Human-readable text is the **window rollup only** — a header carrying the
window and the journal's state, then one line per provider, ordered by
**descending `cost_usd`** so the table reads as a spend ranking first and a
latency comparison second. The per-day series is not printed: it is what
`--json` and the dashboard panel are for, and 14 rows × N providers is not a
terminal table. The contract is the column **labels and order**
(`_METRIC_COLUMNS`); whitespace is not part of it. A provider whose only calls in
the window failed has `latency_samples: 0` and three `null` percentiles, which
the table prints as em dashes — never as `0`.

The journal line reports `dashboard.history_path`, then one of `ok`, `failed`
(the writer gave up for this process: `UsageRecorder._append` hit an `OSError`
and set `_journal_failed`) or `off — dashboard.history_path unset`. `failed` is
only reachable in a process that tried to append a line, so a `--metrics` run —
which records nothing — reports `ok` or `off` and nothing else. With no journal
the report still prints its header and says `no history` in place of the rows.

`--json` writes the object at the top of *The aggregate* to stdout as one JSON
document. It is **JSON-equal** to the route body below; indentation is the
implementer's choice, the structure is not.

### HTTP: `GET /dashboard/metrics`

- Registered in `_serve_http` beside `/dashboard` and `/dashboard/data`, so
  `enabled = false` leaves it unbuilt and it 404s like any unregistered route.
- It takes the same `_guard` call `dashboard_data` makes, because it carries
  data: a browser must reach it under a name in `--allowed-host`. It must
  **not** be attached to the `/healthz` bypass (`healthz`) — that surface is
  unauthenticated by design and stays secret-free.
- Handler shape: guard first (return the refusal if denied), then
  `_shared is None` → `503 {"status": "stopping"}`, then
  `JSONResponse(_shared.usage.snapshot()["endpoints"])`. The body is one
  unindented line on the wire — `JSONResponse`'s default, not a truncation.
- It reads the in-memory recorder, **never the journal file** (`dashboard_data`'s
  docstring has the same property), so no request here can be answered from
  history.
- No new config key, and no auth beyond the Host allowlist: the bind address
  remains the access control (`AGENTS.md`). A `Host` the allowlist does not name
  gets `421`, and `/healthz` keeps answering its own body unchanged.

`/dashboard/data` gains the same object under its top-level `"endpoints"` key,
which is what the page's panel renders. The change is additive: every existing
key keeps its meaning.

### Dashboard panel

One `<section class="panel">` in `src/seekwright/resources/dashboard.html`,
**immediately after the Providers panel** (`#providers`, in `dashboard.html`)
and before Recent calls (`#recent`), since it decomposes the row above it per
day. Two tables: the rollup, one row per provider, and the series, one row per
provider per day with calls.

The two `<tbody>` ids (`endpoint-rollup`, `endpoint-days`) and the heading are
the contract; a test asserts them statically on the document. Rendering is
client-side from the snapshot's `endpoints` key in the existing poll — the
per-day row writer inside `renderEndpoints`, and `renderProviderCost`, both in
`dashboard.html` — with **no new fetch** and no chart library, matching the
page's self-contained rule (`dashboard.py`'s module docstring). A `null`
percentile renders as an em dash, never as `0`. When `endpoints.providers` is
empty each tbody shows one line saying there is no search history in the window.

The panel differs from the terminal in presentation only: thousands separators,
`$/1k` with a `$` and four decimals, `Last seen` as `YYYY-MM-DD HH:MMZ` rather
than an ISO string, and no absolute `cost usd` column in the rollup.

The page's look and its interaction surface are page-local and read the same
snapshot: one light print-inspired theme declared as `:root` tokens in the file
itself (no stylesheet, no external asset — the self-contained rule above), mono
tabular numerals, and chart marks in the three series hues. Three additions are
presentation only and add no field: error ticks under the traffic bars (one mark
per failed call, scaled to the worst day in the window), an `Err %` column on the
Providers table, and click-to-sort on that table and on the rollup above — a row
with no figure for the sorted column sorts last in **both** directions, since a
`null` percentile is absence and never the fastest row. Recent calls carries a
tool filter that persists in `localStorage`, and every timestamp cell carries the
reader's local time in a tooltip while its visible text stays UTC.

## Non-goals

- **No content.** No query text, no URLs, no hosts, no titles, no extracted
  text. Every new field is a count, a dollar figure, a millisecond figure, a
  provider name or a timestamp, so the journal stays content-free by
  construction (`usage.py`'s module docstring) and
  `tests/test_usage.py::test_the_series_is_content_free_and_the_journal_gains_no_field`
  keeps passing.
- **No cache on the serving path.** Written on the call path, read only at
  construction or at `--metrics` invocation; the route reads memory
  ([architecture.md](../architecture.md), *Deliberate non-features*).
- **No attempt-level metrics.** The journal is terminal-only, so `errors` counts
  terminal failures, not attempts: a first provider that failed and was rescued
  by a fallback is not an error here. Attempt-level failure data stays on the
  health board and in the log stream (`search.fallback*` events).
- **No fetch-fallback pricing without a priced fallback.** A fetch page is priced
  per call from the serving fallback's declared price, and only then: a page
  served locally, by the self-hosted renderer or by the keyless reader carries no
  figure, so for a ladder with no paid fallback the page count is all the surface
  can say. See *The fetch line's money*.
- **No routing automation.** These figures inform the caller; the proxy does not
  pick a provider from them — a price ranking is not a fitness ranking, and only
  the caller knows the task.
- **No Prometheus exposition format.** The route is JSON for a page and for a
  script; `GET /metrics` was rejected as a name because that name promises the
  text exposition format, and a JSON body under it would be a worse contract.
- **No alerting, thresholds, retention policy, or auth** on any of it.
