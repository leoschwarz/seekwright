(** Usage accounting for the dashboard: RAM aggregates plus an optional journal.

    The journal is append-only JSONL, one line per terminal call, read back only by the dashboard at
    start and on refresh.

    Content-free by construction: a line holds counts, money, timing and a provider or fallback
    name, never query text, URLs, hosts, titles or extracted text.

    - Unknown is absent, never 0.0. A money total covers only the lines that carried a price, and
      the count of those travels beside it. A [search] line always carries its figure, so search
      spend is a plain total and not a sample.
    - Per-provider, per-day latency samples stay in RAM.
    - Agent mode's ranking data folds onto the same lines, and invalid citations are attributed to
      the model, never to a provider.
    - The fold of a line into the aggregates and the append of that line to the journal are guarded
      by an [Eio.Mutex].
    - Timestamps are generated from the [now] function injected at {!create}. *)

type log = Log.log

type t
(** The recorder: aggregates, the recent deque, and the optional journal. *)

val create :
  now:(unit -> float) ->
  ?log:log ->
  ?history_path:Eio.Fs.dir_ty Eio.Path.t ->
  ?recent:int ->
  ?keep_days:int ->
  unit ->
  (t, string) result
(** [create ~now ()] counts in memory only. [~history_path] adds the journal. An unwritable
    directory or file returns an [Error] naming the path and fault. [~recent] bounds the deque the
    dashboard shows newest-first; [~keep_days] how far back day buckets survive. *)

val window_days : int
(** The window the dashboard charts: 14 days. *)

val keep_days_default : int
(** The default lifetime of a day bucket: 370 days. *)

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
(** One terminal search: success with a cost, or a named failure. A failure carries [results=0] and
    [cost_usd=0.0]. [error] is the failure class name. *)

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
(** One terminal fetch. [fallback] names the fallback that served it, or [None] for the local
    fetcher and for every failure. [cost_usd] is absent whenever nothing was billed. *)

type answer_metrics = {
  model : string option;
  depth : string;
  searches : int;
  results : int;
  fetched : int;
  material_chars : int;
  prompt_tokens : int option;
  completion_tokens : int option;
  answer_chars : int;
  cited : int;
  cited_invalid : int;
  sources : int;
  model_cost_usd : float option;
  ms : int;
}
(** One terminal [answer] call's figures. [sources] is a count of distinct URLs cited;
    [prompt_tokens] and [completion_tokens] are [None] when the model reported none,
    [model_cost_usd] when nothing was priced. *)

val answer_metric_fields : answer_metrics -> (string * Yojson.Safe.t) list
(** The same figures as named fields, in the journal's order. The log line and the journal line take
    their shared vocabulary from here, so the two sinks cannot spell an answer metric differently.
*)

val answer_metric_keys : string list
(** The field names alone — what the surface manifest prints for the [answer] line kind. *)

val record_answer : t -> run:string -> answer_metrics -> ?error:string -> unit -> unit
(** One terminal [answer] call: one line per call, content-free. *)

val spend : t -> float
(** Everything this process has been billed for and the journal recorded: priced search money plus
    the money the fetch rungs charged, unrounded. An unpriced call adds nothing, which is why
    [Agent] reads it as a lower bound on a call's spend. *)

val snapshot : t -> Yojson.Safe.t
(** The whole dashboard state, as the JSON the page reads. Costs are rounded to six decimal places.
    [endpoints] is the windowed per-provider series and [answers] is agent mode's ranking data (see
    [citation_rows]). Every money figure is null rather than 0.0 when nothing was priced. *)

val iso_utc_full : float -> string
(** [iso_utc_full secs] produces ISO 8601 UTC timestamp: [YYYY-MM-DDThh:mm:ss.uuuuuu+00:00]. *)

val iso_utc_seconds : float -> string
(** [iso_utc_seconds secs] produces second-resolution ISO 8601 UTC timestamp:
    [YYYY-MM-DDThh:mm:ss+00:00]. *)

val utc_date : float -> string
(** [utc_date secs] is the UTC calendar day [YYYY-MM-DD], the day-bucket key. *)
