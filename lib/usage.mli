(** Usage accounting for the dashboard: RAM aggregates plus an optional journal.

    Port of [src/seekwright/usage.py]. The journal is append-only JSONL, one line
    per terminal call, read back only by the dashboard at start and on refresh.
    Nothing on the serving path reads the file, so it is not a cache returning by
    another name. A spend ceiling is declined; one built later would read this
    journal.

    Content-free by construction: a line holds counts, money, timing and a
    provider or fallback {i name}, never query text, URLs, hosts, titles or
    extracted text.

    Figures and field meanings: [docs/reference/metrics.md]. The invariants:

    - Unknown is {b absent, never [0.0]}. A money total covers only the lines
      that carried a price, and the count of those travels beside it; a fetch
      line's [cost_usd] is {i declared} rather than estimated, so the page count
      stays the sample size.
    - Per-provider, per-day latency samples stay in RAM, because a percentile is
      not foldable into a running total; nothing about that series reaches the
      journal.
    - Agent mode's ranking data ([retrieved]/[cited]) folds onto the same lines,
      and [cited_invalid] is attributed to the model, never to a provider.

    Python confines this to one event loop: plain attributes, no locks. The
    OCaml port serves every MCP and REST call on its own Eio fiber, so several
    operations do reach one recorder at once and the confinement is explicit
    instead of assumed:

    - The fold of a line into the aggregates and the append of that line to the
      journal are {b one critical section}, guarded by an [Eio.Mutex] owned by
      the recorder. [apply] never suspends, and [append] does, so the guard is
      what makes the aggregate order, the journal order and a dashboard read
      agree — and what keeps two fibers from interleaving inside one JSON line.
      A frozen mutex is used, not [Stdlib.Mutex], because a waiting fiber must
      park rather than block the domain the holder's append needs.
    - {!snapshot} takes the same guard. The fold itself is already yield-free,
      so a read could not observe it halfway today; the guard states that as a
      property rather than as a consequence of where the suspension points
      happen to be, and it is what will keep the promise if a fold ever grows
      one.
    - {!t} is still one domain's value. A recorder is not shared across Eio
      domains: the guard is a fiber lock, not a cross-domain lock, and nothing
      in the serving path spawns a second domain for a call. A later worker
      domain would need a real lock at the boundary, which is exactly what the
      absence of one here records.

    Python reads its clock from the loop and the process wall clock; OCaml's
    stdlib has neither, so the wall clock is {i injected} at {!create}. Every
    timestamp this module writes, and every day bucket it computes, comes from
    that one function, which is what makes the window tests pinable instead of
    calendar-dependent.

    Event-loop discipline for the log: like the rest of the package, a constant
    dotted event name and every value as a named field. The sink is the caller's
    (P8 wires it to stderr); a recorder built without one stays silent, which is
    also what the Python tests' [log_records] fixture replaces here. *)

(* The sink type is [Log]'s, aliased here — style review M1. The level is
   [Config]'s because that is the vocabulary [logging.level] in the file spells. *)
type log = Log.log

(** One UTC day's counts, summed as records land — the aggregate the chart
    draws. Declared in the interface only so {!window_days} and the snapshot
    contract can be stated; {!snapshot} is the way to read it. *)

type t
(** The recorder: aggregates, the recent deque, and the optional journal. *)

val create
  :  now:(unit -> float) ->
  ?log:log ->
  ?history_path:Eio.Fs.dir_ty Eio.Path.t ->
  ?recent:int ->
  ?keep_days:int ->
  unit ->
  (t, string) result
(** [create ~now ()] counts in memory only. [~history_path] adds the journal,
    and with it the two startup checks Python makes before a server is ready to
    serve: the parent directory exists, and the file opens for append. An
    unwritable bind mount would otherwise boot green and break on the first
    append; the probe writes no bytes. The existing journal is then folded into
  the aggregates ([_backfill]). A [history_path] that fails either check is an
  [Error] carrying the whole operator-facing sentence, where Python raises
  [ValueError] — the CLI (P8) prints it and exits 1.

  [~recent] bounds the deque the dashboard shows newest-first; [~keep_days] how
  far back day buckets survive ({!keep_days_default} is Python's default). *)

val window_days : int
(** The window the dashboard charts: two weeks, long enough to show a weekly
    rhythm. The Python name is [_WINDOW_DAYS]; the tests name it, so it is
    public here. *)

val keep_days_default : int
(** The default lifetime of a day bucket: [370], a year plus its leap day. *)

(** {1 Recording}

    Each [record_*] folds the line into the aggregates and appends it to the
    journal as one critical section: serialised by the recorder's guard, so
    concurrent fibers cannot interleave inside the fold or inside one JSON
    line. The line is written after the fold, so a dashboard snapshot and the
    file agree on the order the calls landed in. *)

val record_search :
  t ->
  provider:string ->
  ms:int ->
  cost_usd:float ->
  results:int ->
  fell_back:bool ->
  ?error:string ->
  ?run:string ->
  ?step:int ->
  unit ->
  unit
(** One terminal search: success with a cost, or a named failure. A failure
    carries [results=0] and [cost_usd=0.0] — nothing was billed — and [error] is
    the failure {i class name} ([ProviderError], [QuotaExhausted]), never its
    message.

  [run]/[step] are present only when this search is one step of an [answer]
  call's retrieval walk; a plain search belongs to no run, and those two keys are
  omitted from the line rather than nulled. *)

val record_fetch :
  t ->
  ms:int ->
  chars:int ->
  fallback:string option ->
  ?cost_usd:float ->
  ?error:string ->
  ?run:string ->
  ?step:int ->
  unit ->
  unit
(** One terminal fetch. [fallback] names the fallback that served it, or [None]
    for the local fetcher and for every failure. The caller resolves that name to
    the fallback's declared [cost_per_1k] and passes the resulting money as
    [cost_usd].

    [cost_usd] is the declared price of the {b one call} the fallback made — per
    call, not per delivered character, because a past-end [offset] still fetched
    and billed the page. The key is {b absent, never [0.0]}, whenever nothing was
    billed: the local fetcher, every failure, and any fallback that declares no
    price ([crawl4ai], [jina]). Absent keeps the page count the sample size; a
    [0.0] would claim a measured free call. *)

val record_answer :
  t ->
  run:string ->
  model:string option ->
  depth:string ->
  searches:int ->
  results:int ->
  fetched:int ->
  material_chars:int ->
  prompt_tokens:int option ->
  completion_tokens:int option ->
  answer_chars:int ->
  cited:int ->
  cited_invalid:int ->
  sources:int ->
  model_cost_usd:float option ->
  ms:int ->
  ?error:string ->
  unit ->
  unit
(** One terminal [answer] call: one line per call, content-free.

  [sources] is a {b count} — [List.length sources] of the response — never the
  list and never a URL. It can be smaller than [cited]: that deduplicates by
  index, this by URL.

  [prompt_tokens]/[completion_tokens] come from the endpoint's [usage] and are
  absent when it reports none — never a local estimate. [model_cost_usd] follows
  them: with the prices unset it is absent, which reads as "counted, not
  priced". *)

val search_cost_usd : t -> float
(** Search spend so far, unrounded, from the in-memory aggregate. The one
    serving-path reader of these aggregates: agent mode's [max_cost_usd] early
    exit adds each retrieval step's spend to what it has already seen, and a
    rounded figure would let the ceiling fire late. The journal {i file} is still
    never read here. *)

(** {1 Reading} *)

val snapshot : t -> Yojson.Safe.t
(** The whole dashboard state, as the JSON the page reads.

    One consistent read: the snapshot takes the recorder's guard, so it cannot
    see a record whose fold has started but whose journal line has not been
    written. Every field therefore describes the same set of terminal calls,
    whatever the HTTP routes were doing when the request arrived.

    Costs are rounded to six decimals — sub-microdollar — so a float sum never
    ships its binary-tail noise to a page whose point is readability.

  [endpoints] is the windowed per-provider series and [answers] is agent mode's
  ranking data (see {!citation_rows}). Every money figure is [null] rather than
  [0.0] when nothing was priced, with the count that says how much of the whole
  it covers beside it. *)

(** {1 The timestamps this module writes}

    Exported because they are the journal's format, and the engine's
    [retrieved_at] is the same clock spelled with a coarser resolution: one home
    for the UTC civil-date arithmetic rather than two. *)

val iso_utc_full : float -> string
(** [iso_utc_full secs] is [datetime.now(UTC).isoformat()] — [YYYY-MM-DDThh:mm:ss]
    with microseconds when there are any, and [+00:00]. What a line's [ts] and
    [process_started_at] carry. *)

val iso_utc_seconds : float -> string
(** [iso_utc_seconds secs] is the same instant with [timespec="seconds"]: what
    the engines' [retrieved_at] carries. *)

val utc_date : float -> string
(** [utc_date secs] is the UTC calendar day [YYYY-MM-DD], the day-bucket key. *)
