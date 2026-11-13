(** See usage.mli — port of [src/seekwright/usage.py].

    Two things about the port are worth stating here rather than in the
    interface, because they are properties of the {i implementation}:

    The journal line is a [Yojson.Safe.t] [`Assoc] value, and its key order is
    the on-disk order — Python declares each line kind as a dataclass whose
    fields {i are} the journal's keys, and the append-only format keeps that
    order for readers that print a line rather than parse one. Every line kind is
    therefore built in one place, in the declared order, and the two keys that
    may be absent ([cost_usd] on an unpriced fetch, and the [run]/[step] pair)
    are left out rather than written as [null].

    Reading a line back is tolerant in exactly Python's way: every figure is read
    by name with a type test, so a key a newer writer added is ignored, a key an
    older writer never sent contributes nothing, and a value of the wrong type
    contributes nothing rather than folding as zero. {!truthy}, {!counted} and
    {!money} are those three tests, and the [ms] guard in {!apply} is the one
    place Python's [isinstance(ms, int)] lets a JSON [true] through.

    The aggregates are association lists, not [Map]s, in the two places Python's
    dict order is load-bearing: {!remember_run} evicts the {i oldest} run, which
    a keyed map would get wrong. Elsewhere the order is decided by a total sort
    key, so the insertion order never reaches a figure. *)

type log =
  Config.log_level -> string -> (string * Yojson.Safe.t) list -> unit

(* The window the dashboard charts: two weeks, long enough to show a weekly
   rhythm. *)
let window_days = 14

(* The quantiles the metrics contract reports, as (field, quantile) pairs so the
   read-time pass and the null-when-empty rule stay in one place. *)
let percentiles : (string * float) list = [ ("p50_ms", 0.50); ("p95_ms", 0.95) ]

(* The cap on runs held waiting for their [answer] line, so a journal from a
   process that died mid-call cannot grow the map without bound on backfill. *)
let runs_max = 256

let keep_days_default = 370
let recent_default = 100

(* {1 The clock} *)

(* Days since 1970-01-01 and back: Howard Hinnant's civil-date arithmetic. The
   stdlib's date functions are not in scope without [unix], and walking ~20 000
   days is not what a serving path should do; these are closed-form, and
   [test_usage.ml] pins the two ends the buckets need. *)
let days_from_civil (y : int) (m : int) (d : int) : int =
  let y = if m <= 2 then y - 1 else y in
  let era = (if y >= 0 then y else y - 399) / 400 in
  let yoe = y - (era * 400) in
  let doy = ((153 * (m + (if m > 2 then -3 else 9))) + 2) / 5 + d - 1 in
  let doe = (yoe * 365) + (yoe / 4) - (yoe / 100) + doy in
  (era * 146097) + doe - 719468

let civil_from_days (z : int) : int * int * int =
  let z = z + 719468 in
  let era = (if z >= 0 then z else z - 146096) / 146097 in
  let doe = z - (era * 146097) in
  let yoe = (doe - (doe / 1460) + (doe / 36524) - (doe / 146096)) / 365 in
  let y = yoe + (era * 400) in
  let doy = doe - ((365 * yoe) + (yoe / 4) - (yoe / 100)) in
  let mp = ((5 * doy) + 2) / 153 in
  let d = doy - (((153 * mp) + 2) / 5) + 1 in
  let m = if mp < 10 then mp + 3 else mp - 9 in
  let y = if m <= 2 then y + 1 else y in
  (y, m, d)

let date_of_days (days : int) : string =
  let (y, m, d) = civil_from_days days in
  Printf.sprintf "%04d-%02d-%02d" y m d

(* [YYYY-MM-DD] -> days since the epoch, the form the day buckets are keyed on
   and pruned by (string comparison on that key is the prune rule). *)
let date_of_string (date : string) : int option =
  let digit i = match date.[i] with '0' .. '9' -> true | _ -> false in
  if String.length date <> 10 || not (digit 0 && digit 1 && digit 2 && digit 3)
  || date.[4] <> '-' || not (digit 5 && digit 6) || date.[7] <> '-'
  || not (digit 8 && digit 9)
  then None
  else
    Some
      (days_from_civil
         (int_of_string (String.sub date 0 4))
         (int_of_string (String.sub date 5 2))
         (int_of_string (String.sub date 8 2)))

(* Floor division, so a pre-epoch instant (a journal line carrying a 1960s
   timestamp) lands in the day {i before} rather than in 1970. *)
let days_of_secs (secs : float) : float = Float.floor (secs /. 86400.)

let utc_date (secs : float) : string = date_of_days (int_of_float (days_of_secs secs))

let civil_of (secs : float) : int * int * int * int * int * int * float =
  let days = int_of_float (days_of_secs secs) in
  let sod = secs -. (days_of_secs secs *. 86400.) in
  let (y, m, d) = civil_from_days days in
  let whole = Float.to_int sod in
  (y, m, d, whole / 3600, (whole / 60) mod 60, whole mod 60, sod -. Float.of_int whole)

(* Python's [isoformat()] omits the microsecond field when it is zero, and the
   [ts] strings a reader compares against [since] are those exact strings, so the
   omission is part of the format rather than a detail. *)
let iso_utc_full (secs : float) : string =
  let (y, m, d, hh, mm, ss, frac) = civil_of secs in
  let micros = Float.to_int (Float.floor (frac *. 1_000_000.)) in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02d%s+00:00" y m d hh mm ss
    (if micros = 0 then "" else Printf.sprintf ".%06d" micros)

let iso_utc_seconds (secs : float) : string =
  let (y, m, d, hh, mm, ss, _) = civil_of secs in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02d+00:00" y m d hh mm ss

(* {1 Parsing a journal timestamp} *)

let digits (s : string) (i : int) (n : int) : int option =
  if i < 0 || n <= 0 || i + n > String.length s then None
  else
    let sub = String.sub s i n in
    if String.for_all (fun c -> c >= '0' && c <= '9') sub then Some (int_of_string sub)
    else None

(* [datetime.fromisoformat(ts).astimezone(UTC)] for the shapes a journal line
   carries: the date, optionally a time, optionally an offset. A timestamp with
   no offset is read as UTC — Python reads it as {i local} time, which in this
   deployment's container is UTC; the divergence is only reachable by an operator
   who hand-writes an offset-free line and runs the server elsewhere. *)
let parse_offset (s : string) (i : int) : (int * float) option =
  let l = String.length s in
  if i >= l then None
  else if s.[i] = 'Z' || s.[i] = 'z' then Some (i + 1, 0.)
  else
    let sign = match s.[i] with '+' -> 1 | '-' -> -1 | _ -> 0 in
    if sign = 0 then None
    else
      match (digits s (i + 1) 2, digits s (i + 4) 2, digits s (i + 3) 2) with
      | Some h, Some mi, _ when s.[i + 3] = ':' ->
        Some (i + 6, float_of_int (sign * ((h * 60) + mi) * 60))
      | _, _, Some hi ->
        (* ±HHMM, the form [isoformat] never writes but [fromisoformat] accepts. *)
        Some (i + 5, float_of_int (sign * (((hi / 100) * 60) + (hi mod 100)) * 60))
      | _ -> None

(* The fractional part of a timestamp: Python reads at most six digits after the
   point and ignores the rest of a longer run. A point with no digits after it is
   a line [fromisoformat] rejects. *)
let parse_fraction (ts : string) : (float * int) option =
  let l = String.length ts in
  if l > 19 && ts.[19] = '.' then begin
    let rec run i =
      if i < l && i - 19 <= 6 && ts.[i] >= '0' && ts.[i] <= '9' then run (i + 1) else i
    in
    let stop = run 20 in
    let n = stop - 20 in
    match digits ts 20 n with
    | Some v -> Some ((float_of_int v /. (10. ** float_of_int n)), stop)
    | None -> None
  end
  else Some (0., 19)

(* [Some (seconds_of_day, index_after)] for [ts]'s clock at [11], whether or not
  it carries seconds — [fromisoformat] accepts [HH:MM] too. *)
let parse_clock (ts : string) : (float * int) option =
  match (digits ts 11 2, digits ts 14 2) with
  | Some hh, Some mi -> begin
    match digits ts 17 2 with
    | None -> Some (float_of_int ((hh * 60) + mi) *. 60., 16)
    | Some ss -> begin
      match parse_fraction ts with
      | Some (frac, stop) -> Some (float_of_int ((hh * 3600) + (mi * 60) + ss) +. frac, stop)
      | None -> None
    end
  end
  | _ -> None

let parse_utc (ts : string) : float option =
  match (digits ts 0 4, digits ts 5 2, digits ts 8 2) with
  | Some y, Some mo, Some dy ->
    let days = float_of_int (days_from_civil y mo dy) *. 86400. in
    let l = String.length ts in
    if l = 10 then Some days
    else if l < 11 || (ts.[10] <> 'T' && ts.[10] <> 't' && ts.[10] <> ' ') then None
    else begin
      match parse_clock ts with
      | None -> None
      | Some (clock, after) ->
        if after >= l then Some (days +. clock)
        else (
          match parse_offset ts after with
          | Some (_, offset) -> Some (days +. clock -. offset)
          | None -> None)
    end
  | _ -> None

(* {1 Reading a line} *)

(* A journal line's field, and [Null] for a key that is not there: Python's
   [entry.get(key)], which is how a line written before a key existed folds. *)
let get (key : string) (entry : Yojson.Safe.t) : Yojson.Safe.t =
  match entry with
  | `Assoc fields -> (try List.assoc key fields with Not_found -> `Null)
  | _ -> `Null

(* Python truthiness, which is what the two boolean-ish reads below ask for. The
   distinction matters once: a line that wrote ["fell_back": "no"] is true. *)
let truthy (value : Yojson.Safe.t) : bool =
  match value with
  | `Null -> false
  | `Bool b -> b
  | `Int n -> n <> 0
  | `Intlit s -> s <> "0"
  | `Float f -> f <> 0.
  | `String s -> s <> ""
  | `List xs -> xs <> []
  | `Assoc fields -> fields <> []

(* An integer figure read off a journal line, or [None] when it is not one.
   [Bool] is excluded even though Python counts it an [int]: a line that wrote
   [true] where a count belongs is not a count of one. *)
let counted (value : Yojson.Safe.t) : int option =
  match value with `Int n -> Some n | _ -> None

(* A dollar figure read off a journal line, or [None] when it is not one. [None]
   means {b unknown}, never zero: folding an unpriced line as [0.0] would invent a
   price the journal never carried. *)
let money (value : Yojson.Safe.t) : float option =
  match value with
  | `Int n -> Some (float_of_int n)
  | `Float f -> Some f
  | _ -> None

(* The one read {!apply_search} makes that {!money} does not: Python tests
   [isinstance(cost, (int, float))] without excluding [bool], so a line that wrote
   [true] where a price belongs folds as one dollar. Kept apart so the [bool]
   exclusion above stays honest about which reads make it. *)
let cost_field (value : Yojson.Safe.t) : float =
  match value with
  | `Int n -> float_of_int n
  | `Float f -> f
  | `Bool b -> if b then 1. else 0.
  | _ -> 0.

(* The [ms] guard's type test: Python's [isinstance(ms, int)] accepts a JSON
   [true] and rejects a JSON [12.0], and the arithmetic below then adds one
   millisecond for that [true]. Reproduced, not tidied away. *)
let elapsed_field (value : Yojson.Safe.t) : int option =
  match value with
  | `Int n -> Some n
  | `Bool b -> Some (if b then 1 else 0)
  | _ -> None

(* Python's [round(x, 6)]: correct rounding of the binary value, ties to even,
   which is what [%.6f] does. Scaling and adding a half would add a second
   rounding error of its own. *)
let round6 (x : float) : Yojson.Safe.t = `Float (float_of_string (Printf.sprintf "%.6f" x))

(* Python's [int(x)] on a non-negative quotient: truncate, do not round. *)
let trunc_int (x : float) : int = Float.to_int x

(* {1 Aggregates} *)

type day_totals = {
  mutable searches : int;
  mutable fetches : int;
  mutable answers : int;
  mutable errors : int;
  mutable cost_usd : float;
  (* Summed only over the answers that carried a price, so [priced_answers] at
     zero means the day's model spend is unknown, not free. *)
  mutable model_cost_usd : float;
  mutable priced_answers : int;
  (* The same shape one section over, with [priced_fetches] as the sample size. *)
  mutable fetch_cost_usd : float;
  mutable priced_fetches : int;
}

(* One search provider's totals; searches only — a fetch has no provider.
   [retrieved]/[cited] are agent mode's ranking data, from [answer] calls alone:
   results this provider contributed to a retrieval walk, and the citations
   credited to it. Both are zero on a provider that has only served plain
   searches. *)
type provider_totals = {
  mutable calls : int;
  mutable errors : int;
  mutable cost_usd : float;
  mutable ms_sum : int;
  mutable last_used : string option;
  mutable retrieved : int;
  mutable cited : int;
}

(* One provider's terminal searches for one UTC day, plus its latency sample.
   [calls]/[errors]/[fell_back_calls]/[cost_usd] count every terminal line of that
   day, so the exclusions the latency population makes stay visible beside it.
   [samples_ms] holds only that population — successful, non-fell-back searches —
   because a percentile is not decomposable.

   [first_seen]/[last_seen] ship verbatim, as the journal wrote them;
   [first_at]/[last_at] are the same instants parsed, which is what orders them:
   timestamp {i strings} would rank two offsets wrongly. *)
type provider_day = {
  mutable calls : int;
  mutable errors : int;
  mutable fell_back_calls : int;
  mutable cost_usd : float;
  mutable samples_ms : int list;
  mutable first_seen : string option;
  mutable last_seen : string option;
  mutable first_at : float option;
  mutable last_at : float option;
}

(* The model's own figures, one home each, attributed to the model.
   [cited_invalid] is here and in no provider row: an invented citation is a
   property of the prose, not of the result set. [token_calls]/[priced_calls] are
   the sample sizes under the token and money totals, so a partial total is
   visible as partial. *)
type answer_totals = {
  mutable calls : int;
  mutable errors : int;
  mutable cited : int;
  mutable cited_invalid : int;
  mutable sources : int;
  mutable answer_chars : int;
  mutable prompt_tokens : int;
  mutable completion_tokens : int;
  mutable token_calls : int;
  mutable model_cost_usd : float;
  mutable priced_calls : int;
  mutable ms_sum : int;
  mutable models : string list;
}

(* run id -> [(provider, results)], held only until that run's [answer] line
   folds. An association list rather than a [Map] because Python's dict is
   insertion-ordered and eviction is oldest-first — {!remember_run} pops the first
   key, which a keyed map would get wrong. *)
type t = {
  now : unit -> float;
  log : log option;
  process_started_at : string;
  recent_max : int;
  mutable recent : Yojson.Safe.t list;
  keep_days : int;
  journal_path : Eio.Fs.dir_ty Eio.Path.t option;
  (* The path as an operator would write it: what the snapshot's [journal.path]
     and the journal-failure sentence name. *)
  journal_native : string option;
  mutable journal_failed : bool;
  mutable since : string option;
  mutable current_day : string option;
  mutable days : (string * day_totals) list;
  mutable providers : (string * provider_totals) list;
  (* Kept beside [providers] rather than inside it: the lifetime totals keep
     counting days the day buckets have pruned, and only this structure is
     windowed. *)
  mutable provider_days : (string * (string * provider_day) list) list;
  mutable searches : int;
  mutable fetches : int;
  mutable errors : int;
  mutable fallbacks : int;
  mutable search_cost_usd : float;
  mutable fetch_pages_via_fallback : int;
  mutable fetch_cost_usd : float;
  mutable priced_fetches : int;
  answers : answer_totals;
  mutable runs : (string * (string * int) list) list;
}

let day_totals () : day_totals =
  {
    searches = 0;
    fetches = 0;
    answers = 0;
    errors = 0;
    cost_usd = 0.;
    model_cost_usd = 0.;
    priced_answers = 0;
    fetch_cost_usd = 0.;
    priced_fetches = 0;
  }

let provider_totals () : provider_totals =
  {
    calls = 0;
    errors = 0;
    cost_usd = 0.;
    ms_sum = 0;
    last_used = None;
    retrieved = 0;
    cited = 0;
  }

let provider_day () : provider_day =
  {
    calls = 0;
    errors = 0;
    fell_back_calls = 0;
    cost_usd = 0.;
    samples_ms = [];
    first_seen = None;
    last_seen = None;
    first_at = None;
    last_at = None;
  }

let answer_totals () : answer_totals =
  {
    calls = 0;
    errors = 0;
    cited = 0;
    cited_invalid = 0;
    sources = 0;
    answer_chars = 0;
    prompt_tokens = 0;
    completion_tokens = 0;
    token_calls = 0;
    model_cost_usd = 0.;
    priced_calls = 0;
    ms_sum = 0;
    models = [];
  }

(* The dict [setdefault] of these aggregates: the entry for [key], created at the
   {i end} so insertion order survives, with the list it now belongs to — the
   caller writes that back, because an association list has no in-place slot. *)
let ensure (key : string) (make : unit -> 'a) (fields : (string * 'a) list) :
    'a * (string * 'a) list =
  match List.assoc_opt key fields with
  | Some found -> (found, fields)
  | None ->
    let created = make () in
    (created, fields @ [(key, created)])

(* The deque's front trim. *)
let rec drop_first (n : int) (xs : 'a list) : 'a list =
  match (n, xs) with
  | (0, xs) -> xs
  | (_, []) -> []
  | (n, _ :: xs) -> drop_first (n - 1) xs

(* Python's ``d[key] = value``: replaces in place, and appends when the key is new,
   so the first write of a fresh key is not silently dropped. The association list
   keeps insertion order, which is what makes {!remember_run}'s oldest-first eviction
   and the snapshot's row order come out as Python's do. *)
let set (key : string) (value : 'a) (fields : (string * 'a) list) : (string * 'a) list =
  if List.mem_assoc key fields then
    List.map (fun (k, v) -> (k, if k = key then value else v)) fields
  else fields @ [(key, value)]

let emit (t : t) (level : Config.log_level) (name : string) fields =
  match t.log with Some f -> f level name fields | None -> ()

(* Nearest-rank percentile of the latency sample, or null when empty:
   [sorted_ms[ceil(q * n) - 1]], clamped to the last index, with no interpolation,
   so the result is always a value some call actually recorded. *)
let nearest_rank (samples : int list) (quantile : float) : Yojson.Safe.t =
  if samples = [] then `Null
  else
    let ordered = List.sort Int.compare samples in
    let n = List.length ordered in
    let index =
      max 0
        (min (trunc_int (Float.ceil (quantile *. float_of_int n)) - 1) (n - 1))
    in
    `Int (List.nth ordered index)

(* Sum one provider's per-day buckets into its window rollup row. Each pass is
   parenthesised: a bare [match] as a statement in a sequence lets its last
   branch swallow the statements that follow it, because [|] binds looser than [;]. *)
let fold_days (buckets : (string * provider_day) list) : provider_day =
  let merged = provider_day () in
  List.iter
    (fun ((_, totals) : string * provider_day) ->
      merged.calls <- merged.calls + totals.calls;
      merged.errors <- merged.errors + totals.errors;
      merged.fell_back_calls <- merged.fell_back_calls + totals.fell_back_calls;
      merged.cost_usd <- merged.cost_usd +. totals.cost_usd;
      merged.samples_ms <- merged.samples_ms @ totals.samples_ms;
      (match totals.first_at with
      | Some at when at < Option.value ~default:Float.infinity merged.first_at ->
        merged.first_at <- Some at;
        merged.first_seen <- totals.first_seen
      | _ -> ());
      (match totals.last_at with
      | Some at when at > Option.value ~default:Float.neg_infinity merged.last_at ->
        merged.last_at <- Some at;
        merged.last_seen <- totals.last_seen
      | _ -> ()))
    buckets;
  merged

(* {1 The line schema} *)

(* The journal's line schema: the one place its keys are declared, so a misnamed
   key is a compile error, not a line that changes shape. The tuple order {b is}
   the on-disk key order.

   Two keys stay out of the file rather than being written as null: a fetch line's
   [cost_usd] when nothing was billed, and the [run]/[step] pair on a line that
   belongs to no [answer] call, which would otherwise change the shape the
   journal's readers already parse. *)
let run_fields (run : string option) (step : int option) =
  match run with
  | None -> []
  | Some r -> [("run", `String r); ("step", (match step with Some s -> `Int s | None -> `Null))]

let search_line (ts : string) ~(provider : string) (ms : int) (cost_usd : float)
    (results : int) (fell_back : bool) (error : string option) (run : string option)
    (step : int option) : Yojson.Safe.t =
  `Assoc
    ([
       ("ts", `String ts);
       ("tool", `String "search");
       ("provider", `String provider);
       ("ms", `Int ms);
       ("cost_usd", `Float cost_usd);
       ("results", `Int results);
       ("fell_back", `Bool fell_back);
       ("error", (match error with Some e -> `String e | None -> `Null));
     ]
    @ run_fields run step)

let fetch_line (ts : string) (ms : int) (chars : int) (fallback : string option)
    (cost_usd : float option) (error : string option) (run : string option)
    (step : int option) : Yojson.Safe.t =
  (* A priced fetch writes [cost_usd] after [error], where the writer that added
     it conditionally always put it. *)
  `Assoc
    ([
       ("ts", `String ts);
       ("tool", `String "fetch");
       ("ms", `Int ms);
       ("chars", `Int chars);
       ("fallback", (match fallback with Some f -> `String f | None -> `Null));
       ("error", (match error with Some e -> `String e | None -> `Null));
     ]
    @ (match cost_usd with Some c -> [("cost_usd", `Float c)] | None -> [])
    @ run_fields run step)

(* All seventeen keys are always written: [answer] is the one line kind whose
   optional figures are meaningful as nulls, because the snapshot tells unknown
   from absent by the sample-size counts beside them. *)
let answer_line (ts : string) (run : string) (model : string option) (depth : string)
    (searches : int) (results : int) (fetched : int) (material_chars : int)
    (prompt_tokens : int option) (completion_tokens : int option) (answer_chars : int)
    (cited : int) (cited_invalid : int) (sources : int) (model_cost_usd : float option)
    (ms : int) (error : string option) : Yojson.Safe.t =
  let opt_int = function Some n -> `Int n | None -> `Null in
  let opt_float = function Some f -> `Float f | None -> `Null in
  `Assoc
    [
      ("ts", `String ts);
      ("tool", `String "answer");
      ("run", `String run);
      ("model", (match model with Some m -> `String m | None -> `Null));
      ("depth", `String depth);
      ("searches", `Int searches);
      ("results", `Int results);
      ("fetched", `Int fetched);
      ("material_chars", `Int material_chars);
      ("prompt_tokens", opt_int prompt_tokens);
      ("completion_tokens", opt_int completion_tokens);
      ("answer_chars", `Int answer_chars);
      ("cited", `Int cited);
      ("cited_invalid", `Int cited_invalid);
      ("sources", `Int sources);
      ("model_cost_usd", opt_float model_cost_usd);
      ("ms", `Int ms);
      ("error", (match error with Some e -> `String e | None -> `Null));
    ]

(* {1 The folding} *)

let remember_run (t : t) (run : string) (provider : string) (results : int) : unit =
  (* The [run] id is the whole join: retrieval lines are written before the
     [answer] line of the same call, and the entry is consumed when the answer
     line arrives. The cap bounds a journal whose process died mid-call, whose
     run-tagged lines have no answer line; eviction is oldest-first, which is also
     the order a run stops being relevant in. *)
  let runs =
    if List.mem_assoc run t.runs || List.length t.runs < runs_max then t.runs
    else List.tl t.runs
  in
  let counts = Option.value ~default:[] (List.assoc_opt run runs) in
  let counts =
    match List.assoc_opt provider counts with
    | Some n -> set provider (n + results) counts
    | None -> counts @ [(provider, results)]
  in
  t.runs <- set run counts runs

let apply_search (t : t) (entry : Yojson.Safe.t) (bucket : day_totals) (day : string)
    (ts : string) (moment : float) (ms : int) (error : string option) : unit =
  let cost_usd = cost_field (get "cost_usd" entry) in
  let fell_back = truthy (get "fell_back" entry) in
  let results = Option.value ~default:0 (counted (get "results" entry)) in
  t.searches <- t.searches + 1;
  t.search_cost_usd <- t.search_cost_usd +. cost_usd;
  if fell_back then t.fallbacks <- t.fallbacks + 1;
  bucket.searches <- bucket.searches + 1;
  bucket.cost_usd <- bucket.cost_usd +. cost_usd;
  match get "provider" entry with
  | `String provider ->
    let totals, providers = ensure provider provider_totals t.providers in
    t.providers <- providers;
    totals.calls <- totals.calls + 1;
    totals.cost_usd <- totals.cost_usd +. cost_usd;
    totals.ms_sum <- totals.ms_sum + ms;
    totals.last_used <- Some ts;
    if error <> None then totals.errors <- totals.errors + 1;
    let by_day, owner = ensure provider (fun () -> []) t.provider_days in
    t.provider_days <- owner;
    let day_totals, by_day = ensure day provider_day by_day in
    t.provider_days <- set provider by_day t.provider_days;
    day_totals.calls <- day_totals.calls + 1;
    day_totals.cost_usd <- day_totals.cost_usd +. cost_usd;
    if error <> None then day_totals.errors <- day_totals.errors + 1;
    if fell_back then day_totals.fell_back_calls <- day_totals.fell_back_calls + 1;
    (* The latency population: a terminal failure's [ms] is the configured timeout
       and a fell-back success's is the whole ladder walk, so neither is a property
       of the provider that answered. *)
    (match error with
    | None when not fell_back -> day_totals.samples_ms <- day_totals.samples_ms @ [ms]
    | _ -> ());
    (match day_totals.first_at with
    | None ->
      day_totals.first_at <- Some moment;
      day_totals.first_seen <- Some ts
    | Some at when moment < at ->
      day_totals.first_at <- Some moment;
      day_totals.first_seen <- Some ts
    | _ -> ());
    (match day_totals.last_at with
    | None ->
      day_totals.last_at <- Some moment;
      day_totals.last_seen <- Some ts
    | Some at when moment > at ->
      day_totals.last_at <- Some moment;
      day_totals.last_seen <- Some ts
    | _ -> ());
    (* The ranking data's join key: a run-carrying step is one retrieval of an
       [answer] call, and its [answer] line credits the citations back to whoever
       contributed. A plain search carries no run. *)
    (match get "run" entry with
    | `String run when results > 0 ->
      totals.retrieved <- totals.retrieved + results;
      remember_run t run provider results
    | _ -> ())
  | _ -> ()

let apply_answer (t : t) (entry : Yojson.Safe.t) (bucket : day_totals) (ms : int)
    (error : string option) : unit =
  (* Read by key and tolerant of a key the writer did not send: a missing figure is
     {b absent} from the aggregate rather than zero in it, and
     [priced_calls]/[token_calls] carry the sample size so a partial total is
     visible as partial. *)
  let totals = t.answers in
  totals.calls <- totals.calls + 1;
  bucket.answers <- bucket.answers + 1;
  if error <> None then totals.errors <- totals.errors + 1;
  totals.ms_sum <- totals.ms_sum + ms;
  (match get "model" entry with
  | `String model when not (List.mem model totals.models) ->
    totals.models <- totals.models @ [model]
  | _ -> ());
  let cited = Option.value ~default:0 (counted (get "cited" entry)) in
  totals.cited <- totals.cited + cited;
  totals.cited_invalid
    <- totals.cited_invalid + Option.value ~default:0 (counted (get "cited_invalid" entry));
  totals.sources <- totals.sources + Option.value ~default:0 (counted (get "sources" entry));
  totals.answer_chars
    <- totals.answer_chars + Option.value ~default:0 (counted (get "answer_chars" entry));
  let prompt = counted (get "prompt_tokens" entry) in
  let completion = counted (get "completion_tokens" entry) in
  (match (prompt, completion) with
  | None, None -> ()
  | _ ->
    totals.token_calls <- totals.token_calls + 1;
    totals.prompt_tokens <- totals.prompt_tokens + Option.value ~default:0 prompt;
    totals.completion_tokens <- totals.completion_tokens + Option.value ~default:0 completion);
  (* Absent here means the prices were unset when the line was written: summed as
     nothing, counted as unpriced, so the snapshot reports the cost as unknown
     rather than free. *)
  (match money (get "model_cost_usd" entry) with
  | Some cost ->
    totals.model_cost_usd <- totals.model_cost_usd +. cost;
    totals.priced_calls <- totals.priced_calls + 1;
    bucket.model_cost_usd <- bucket.model_cost_usd +. cost;
    bucket.priced_answers <- bucket.priced_answers + 1
  | None -> ());
  (* Every provider that contributed results to this run is credited with the
     run's citation count, once per run. *)
  match get "run" entry with
  | `String run ->
    let contributors = List.assoc_opt run t.runs in
    t.runs <- List.remove_assoc run t.runs;
    (match contributors with
    | Some counts when counts <> [] && cited <> 0 ->
      List.iter
        (fun (name, _) ->
          match List.assoc_opt name t.providers with
          | Some row -> row.cited <- row.cited + cited
          | None -> ())
        counts
    | _ -> ())
  | _ -> ()

let apply_fetch (t : t) (entry : Yojson.Safe.t) (bucket : day_totals)
    (error : string option) : unit =
  t.fetches <- t.fetches + 1;
  bucket.fetches <- bucket.fetches + 1;
  (* Pages a fallback served, not fallback {i attempts}: only a success carries a
     name, and only a named success is the counted figure. *)
  (match (error, get "fallback" entry) with
  | None, `String _ -> t.fetch_pages_via_fallback <- t.fetch_pages_via_fallback + 1
  | _ -> ());
  (* Read the way every optional figure is: a line without the key contributes
     nothing and counts nothing, so [priced_fetches] separates a total over every
     page from one over some. [money] maps a missing key to [None], never to 0.0. *)
  match money (get "cost_usd" entry) with
  | Some cost ->
    t.fetch_cost_usd <- t.fetch_cost_usd +. cost;
    t.priced_fetches <- t.priced_fetches + 1;
    bucket.fetch_cost_usd <- bucket.fetch_cost_usd +. cost;
    bucket.priced_fetches <- bucket.priced_fetches + 1
  | None -> ()

(* Prune day buckets older than [keep_days] when the UTC date changes. Only
   meaningful across a long-lived process; a restart rebuilds the window from the
   journal and the same rule trims it. The per-provider day buckets are pruned with
   the global ones, while the lifetime totals in [providers] are deliberately left
   alone. *)
let roll (t : t) (day : string) : unit =
  if t.current_day <> Some day then begin
    t.current_day <- Some day;
    match date_of_string (utc_date (t.now ())) with
    | None -> ()
    | Some today ->
      let cutoff = date_of_days (today - t.keep_days) in
      let keep key = key >= cutoff in
      t.days <- List.filter (fun (key, _) -> keep key) t.days;
      t.provider_days
        <- List.filter_map
             (fun (provider, by_day) ->
               let by_day = List.filter (fun (key, _) -> keep key) by_day in
               if by_day = [] then None else Some (provider, by_day))
             t.provider_days
  end

(* An [error] field a journal line may carry: absent ([Null]) or a message. A line
   that wrote a number or an object there is not a line this reader understands. *)
let is_error_field (value : Yojson.Safe.t) : bool =
  match value with `Null | `String _ -> true | _ -> false

(* Fold one journal-shaped value into the aggregates and the recent deque.
   [false] means "not a well-formed entry", so backfill can count it and a live
   record (always well-formed) can ignore the result. *)
let fold_entry (t : t) (entry : Yojson.Safe.t) : bool =
    let tool_name = match get "tool" entry with `String s -> s | _ -> "" in
    let error_value = get "error" entry in
    let error_str =
      match error_value with `String e -> Some e | _ -> None
    in
    let known_tool = List.mem tool_name ["search"; "fetch"; "answer"] in
    (* [ms] must be a count, [error] either absent or a message, [ts] a timestamp
       this parser knows: anything else is a line backfill counts as skipped. *)
    match (get "ts" entry, elapsed_field (get "ms" entry)) with
    | `String ts, Some ms -> if not (known_tool && is_error_field error_value) then false else begin
      match parse_utc ts with
      | None -> false
      | Some moment ->
        let day = utc_date moment in
        roll t day;
        let bucket, days = ensure day day_totals t.days in
        t.days <- days;
        if error_str <> None then begin
          t.errors <- t.errors + 1;
          bucket.errors <- bucket.errors + 1
        end;
        (match tool_name with
        | "search" -> apply_search t entry bucket day ts moment ms error_str
        | "fetch" -> apply_fetch t entry bucket error_str
        | _ -> apply_answer t entry bucket ms error_str);
        (* A bounded deque, newest kept: the list is oldest-first and the snapshot
           shows it the other way round. *)
        let recent = t.recent @ [entry] in
        t.recent
          <- drop_first (max 0 (List.length recent - t.recent_max)) recent;
        (match t.since with
        | None -> t.since <- Some ts
        | Some since when ts < since -> t.since <- Some ts
        | _ -> ());
        true
    end
    | _ -> false

(* [get] answers [Null] for anything that is not an object, so a non-object line
   falls through [fold_entry] as an unreadable entry rather than an exception. *)
let apply (t : t) (entry : Yojson.Safe.t) : bool =
  match entry with `Assoc _ -> fold_entry t entry | _ -> false

(* {1 The journal} *)

(* The journal's own path is operator configuration, not content: the snapshot
   may report it (the operator needs to find the file), but a log line does not.
   A failure is therefore a constant [stage] and a bounded [reason]
   classification — [Log.classify_exn] never carries the exception payload. *)

(* Fold an existing journal into the aggregates. A missing file is fine —
   construction created it. A line that will not parse is skipped and counted
   rather than fatal: a torn write from a previous crash must not take down a
   server. The count is logged once so a growing number is visible. *)
let backfill (t : t) (path : Eio.Fs.dir_ty Eio.Path.t) : unit =
  if not (Eio.Path.is_file path) then ()
  else begin
    let skipped = ref 0 in
    List.iter
      (fun raw ->
        let line = String.trim raw in
        if line = "" then ()
        else
          match (try Ok (Yojson.Safe.from_string line) with Yojson.Json_error _ -> Error ()) with
          | Error () -> incr skipped
          | Ok entry -> if not (apply t entry) then incr skipped)
      (String.split_on_char '\n' (Eio.Path.load path));
    if !skipped > 0 then emit t Config.Log_warning "dashboard.journal_skipped" [ ("skipped", `Int !skipped) ]
  end

(* Append one line to the journal, or give up for the process. A broken volume must
   not fail a search the caller is paying for, and it must not log once per call:
   the first failure is reported and the writer is switched off for the life of the
   process. The RAM aggregates keep working.

   Open-append-close per record, as Python does: a long-lived handle would have to
   be closed on shutdown, and the recorder owns no such hook. *)
let append (t : t) (entry : Yojson.Safe.t) : unit =
  match t.journal_path with
  | None -> ()
  | Some path ->
    if t.journal_failed then ()
    else
      match
        Eio.Path.with_open_out ~append:true
          ~create:(`If_missing 0o644)
          path (fun flow -> Eio.Flow.copy_string (Yojson.Safe.to_string entry ^ "\n") flow)
      with
      | () -> ()
      | exception exn ->
        t.journal_failed <- true;
        emit t Config.Log_warning "dashboard.journal_error"
          [
            ("stage", `String "append");
            ("reason", `String (Log.classify_exn exn));
          ]

let create ~now ?log ?history_path ?(recent = recent_default) ?(keep_days = keep_days_default)
    () : (t, string) result =
  let t =
    {
      now;
      log;
      process_started_at = iso_utc_full (now ());
      recent_max = recent;
      recent = [];
      keep_days;
      journal_path = history_path;
      journal_native =
        (match history_path with
        | Some path -> (try Some (Eio.Path.native_exn path) with _ -> None)
        | None -> None);
      journal_failed = false;
      since = None;
      current_day = None;
      days = [];
      providers = [];
      provider_days = [];
      searches = 0;
      fetches = 0;
      errors = 0;
      fallbacks = 0;
      search_cost_usd = 0.;
      fetch_pages_via_fallback = 0;
      fetch_cost_usd = 0.;
      priced_fetches = 0;
      answers = answer_totals ();
      runs = [];
    }
  in
  match history_path with
  | None -> Ok t
  | Some path -> (
    let shown = Option.value ~default:"?" t.journal_native in
    (* An unwritable bind mount would boot green and break on the first append, so
       the journal's own open runs at startup and the misconfiguration becomes a
       startup error. The probe writes no bytes. *)
    match Eio.Path.split path with
    | None -> Error (Printf.sprintf "not writable: %s (no file name)" shown)
    | Some (parent, _) ->
      let parent_exists =
        match (try Ok (Eio.Path.kind ~follow:true parent) with _ -> Error ()) with
        | Ok `Directory -> true
        | _ -> false
      in
      if not parent_exists then Error (Printf.sprintf "parent directory does not exist: %s" shown)
      else
        match
          Eio.Path.with_open_out ~append:true
            ~create:(`If_missing 0o644)
            path (fun _flow -> ())
        with
        | () ->
          backfill t path;
          Ok t
        | exception exn ->
          Error
            (Printf.sprintf "not writable: %s (%s)" shown
               (Log.classify_exn exn)))

(* {1 Recording} *)

let record_search (t : t) ~(provider : string) ~(ms : int) ~(cost_usd : float)
    ~(results : int) ~(fell_back : bool) ?error ?run ?step () : unit =
  let entry =
    search_line (iso_utc_full (t.now ())) ~provider ms cost_usd results fell_back error run step
  in
  ignore (apply t entry);
  append t entry

let record_fetch (t : t) ~(ms : int) ~(chars : int) ~(fallback : string option)
    ?cost_usd ?error ?run ?step () : unit =
  let entry = fetch_line (iso_utc_full (t.now ())) ms chars fallback cost_usd error run step in
  ignore (apply t entry);
  append t entry

let record_answer (t : t) ~(run : string) ~(model : string option) ~(depth : string)
    ~(searches : int) ~(results : int) ~(fetched : int) ~(material_chars : int)
    ~(prompt_tokens : int option) ~(completion_tokens : int option)
    ~(answer_chars : int) ~(cited : int) ~(cited_invalid : int) ~(sources : int)
    ~(model_cost_usd : float option) ~(ms : int) ?error () : unit =
  let entry =
    answer_line (iso_utc_full (t.now ())) run model depth searches results fetched material_chars
      prompt_tokens completion_tokens answer_chars cited cited_invalid sources model_cost_usd ms
      error
  in
  ignore (apply t entry);
  append t entry

let search_cost_usd (t : t) : float = t.search_cost_usd

(* {1 The snapshot} *)

(* The last [window_days] UTC day names, oldest first — the axis both the chart and
   the endpoint series draw. *)
let window_dates (today : string) : string list =
  match date_of_string today with
  | None -> []
  | Some days ->
    List.init window_days (fun i -> date_of_days (days - (window_days - 1 - i)))

(* The two orderings the snapshot and the endpoint series share: spend descending,
   name ascending to break a tie. Python's [sorted] is stable, but this key is
   total over unique names, so stability never decides a row. *)
let by_spend (cost : 'a -> float) (pa, ta) (pb, tb) =
  let c = Float.compare (cost tb) (cost ta) in
  if c <> 0 then c else String.compare pa pb

(* One rollup or per-day row: the shared field set plus its own label. The two
   labels are mandatory labelled arguments rather than optionals because their
   type is itself an option — an optional of an option would arrive doubly
   wrapped at every call site. *)
let endpoint_row (totals : provider_day) ~(provider : string option)
    ~(date : string option) () : Yojson.Safe.t =
  let samples = totals.samples_ms in
  let n = List.length samples in
  let label =
    (match provider with Some p -> [("provider", `String p)] | None -> [])
    @ (match date with Some d -> [("date", `String d)] | None -> [])
  in
  `Assoc
    (label
    @ [
        ("calls", `Int totals.calls);
        ("errors", `Int totals.errors);
        ("fell_back_calls", `Int totals.fell_back_calls);
        ("latency_samples", `Int n);
      ]
    @ List.map (fun (name, q) -> (name, nearest_rank samples q)) percentiles
    @ [
        (* Truncating, like the lifetime [avg_ms]; null, never 0, when there is no
           sample — zero reads as "instant". *)
        ( "mean_ms",
          if n = 0 then `Null
          else `Int (trunc_int ((float_of_int (List.fold_left (+) 0 samples)) /. float_of_int n)) );
        ("cost_usd", round6 totals.cost_usd);
        ("cost_per_1k", if totals.calls = 0 then `Null else round6 (totals.cost_usd /. float_of_int totals.calls *. 1000.));
        ("first_seen", (match totals.first_seen with Some s -> `String s | None -> `Null));
        ("last_seen", (match totals.last_seen with Some s -> `String s | None -> `Null));
      ])

(* The per-provider series over the window, computed from the day buckets.
   Read-time on purpose: the percentiles are derived when a caller asks, not
   stored. A provider or a day with no calls is {b absent}, never a zero row,
   because [0 ms] is a claim and absence is not. [latency_samples] carries the
   sample size. *)
let endpoints (t : t) : Yojson.Safe.t =
  let window = window_dates (utc_date (t.now ())) in
  let present_by_day by_day =
    List.filter_map (fun day -> Option.map (fun v -> (day, v)) (List.assoc_opt day by_day)) window
  in
  let rollups =
    List.filter_map
      (fun (provider, by_day) ->
        let present = present_by_day by_day in
        if present = [] then None
        else Some (provider, fold_days present, present))
      t.provider_days
  in
  let rollups =
    List.sort
      (fun (pa, ta, _) (pb, tb, _) ->
        let c = Float.compare tb.cost_usd ta.cost_usd in
        if c <> 0 then c else String.compare pa pb)
      rollups
  in
  `Assoc
    [
      ("window_days", `Int window_days);
      ( "providers",
        `List
          (List.map
             (fun ((provider, totals, days) : string * provider_day * (string * provider_day) list) ->
               match endpoint_row totals ~provider:(Some provider) ~date:None () with
               | `Assoc row ->
                 `Assoc
                   (row
                   @ [
                       ( "days",
                         `List
                           (List.map
                              (fun ((date, day_totals) : string * provider_day) ->
                                endpoint_row day_totals ~provider:None ~date:(Some date) ())
                              days) );
                     ])
               | row -> row)
             rollups) );
    ]

(* Per-provider retrieval and citation totals: the answering-task ranking.

   Only providers that answered a retrieval step of an [answer] call appear —
   absence, never a zero row. Ordered by citations, then results, then name.

   [retrieved] is what the provider contributed to answering calls' material,
   counted as the retrieval line folds. [cited] is the run's citation count
   credited to every provider that contributed results to that run, once per run.
   A run whose process died mid-call keeps its [retrieved] and can never gain a
   [cited]: there is no answer line to credit.

   Exact whenever a run used one provider, which is the ordinary case. A run whose
   steps spanned two providers (a mid-walk fallback that later succeeded) is a
   {b documented over-count}: the journal cannot say which provider's results the
   cited indices named, and over-crediting both reads as "the provider's results
   were in a run whose prose cited this many". *)
let citation_rows (t : t) : Yojson.Safe.t list =
  let present =
    List.filter
      (fun ((_, totals) : string * provider_totals) ->
        totals.retrieved > 0 || totals.cited > 0)
      t.providers
  in
  let present =
    List.sort
      (fun ((pa, a) : string * provider_totals) ((pb, b) : string * provider_totals) ->
        let c = Int.compare b.cited a.cited in
        if c <> 0 then c
        else
          let c = Int.compare b.retrieved a.retrieved in
          if c <> 0 then c else String.compare pa pb)
      present
  in
  List.map
    (fun ((provider, totals) : string * provider_totals) ->
      `Assoc
        [
          ("provider", `String provider);
          ("retrieved", `Int totals.retrieved);
          ("cited", `Int totals.cited);
        ])
    present

let snapshot (t : t) : Yojson.Safe.t =
  let today = utc_date (t.now ()) in
  (* A day with no traffic is a zero row for the counting columns and null for the
     money columns: the chart's axis is the whole window, but an unpriced day has
     no figure to draw. *)
  let days =
    List.map
      (fun date ->
        match List.assoc_opt date t.days with
        | None ->
          `Assoc
            [
              ("date", `String date);
              ("searches", `Int 0);
              ("fetches", `Int 0);
              ("answers", `Int 0);
              ("errors", `Int 0);
              ("cost_usd", `Float 0.);
              ("model_cost_usd", `Null);
              ("fetch_cost_usd", `Null);
            ]
        | Some totals ->
          `Assoc
            [
              ("date", `String date);
              ("searches", `Int totals.searches);
              ("fetches", `Int totals.fetches);
              ("answers", `Int totals.answers);
              ("errors", `Int totals.errors);
              ("cost_usd", round6 totals.cost_usd);
              ("model_cost_usd",
                if totals.priced_answers = 0 then `Null else round6 totals.model_cost_usd);
              ("fetch_cost_usd",
                if totals.priced_fetches = 0 then `Null else round6 totals.fetch_cost_usd);
            ])
      (window_dates today)
  in
  let ordered =
    List.sort (by_spend (fun (totals : provider_totals) -> totals.cost_usd)) t.providers
  in
  let answers = t.answers in
  `Assoc
    [
      ("since", (match t.since with Some s -> `String s | None -> `Null));
      ("process_started_at", `String t.process_started_at);
      ( "totals",
        `Assoc
          [
            ("searches", `Int t.searches);
            ("fetches", `Int t.fetches);
            ("errors", `Int t.errors);
            ("fallbacks", `Int t.fallbacks);
            ("search_cost_usd", round6 t.search_cost_usd);
            ("fetch_pages_via_fallback", `Int t.fetch_pages_via_fallback);
            (* The fetch ladder's money, from the fallbacks' own declared prices;
               null when no page came from a fallback that declares one. *)
            ("fetch_cost_usd", if t.priced_fetches = 0 then `Null else round6 t.fetch_cost_usd);
            ("priced_fetches", `Int t.priced_fetches);
          ] );
      ("days", `List days);
      ( "providers",
        `List
          (List.map
              (fun ((provider, totals) : string * provider_totals) ->
               `Assoc
                 [
                   ("provider", `String provider);
                   ("calls", `Int totals.calls);
                   ("errors", `Int totals.errors);
                   ("cost_usd", round6 totals.cost_usd);
                   ("avg_ms",
                     if totals.calls = 0 then `Int 0
                     else
                       `Int (trunc_int (float_of_int totals.ms_sum /. float_of_int totals.calls)));
                   ("last_used", (match totals.last_used with Some s -> `String s | None -> `Null));
                 ])
             ordered) );
      ( "answers",
        `Assoc
          [
            ("calls", `Int answers.calls);
            ("errors", `Int answers.errors);
            ("cited", `Int answers.cited);
            ("cited_invalid", `Int answers.cited_invalid);
            ("sources", `Int answers.sources);
            ("answer_chars", `Int answers.answer_chars);
            (* The token totals are the honest stand-in for money, and are null when
               the endpoint reported no usage at all — never an estimate. *)
            ("prompt_tokens", if answers.token_calls = 0 then `Null else `Int answers.prompt_tokens);
            ("completion_tokens",
              if answers.token_calls = 0 then `Null else `Int answers.completion_tokens);
            ("token_calls", `Int answers.token_calls);
            ("model_cost_usd",
              if answers.priced_calls = 0 then `Null else round6 answers.model_cost_usd);
            ("priced_calls", `Int answers.priced_calls);
            ("mean_ms",
              if answers.calls = 0 then `Null
              else `Int (trunc_int (float_of_int answers.ms_sum /. float_of_int answers.calls)));
            ("models", `List (List.map (fun m -> `String m) (List.sort String.compare answers.models)));
            ("providers", `List (citation_rows t));
          ] );
      ("endpoints", endpoints t);
      ("recent", `List (List.rev t.recent));
      ( "journal",
        `Assoc
          [
            ("path", (match t.journal_native with Some p -> `String p | None -> `Null));
            ("failed", `Bool t.journal_failed);
          ] );
    ]
