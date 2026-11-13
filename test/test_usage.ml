(* The usage recorder: the aggregation the dashboard renders, the JSONL journal,
   and its failure modes — ported case for case from tests/test_usage.py.

   The clock is injected here rather than read from a loop, so every date bucket
   in this suite is exact: the fixed instant below is the process's whole world,
   and the day names come out of [Usage.utc_date] rather than being written by
   hand. Two cases change shape on the way across, and both are noted where they
   sit: the prune cases read the aggregates through [endpoints] because the
   Python suite reaches into [r._days], and the two "no content" cases read the
   signatures as the [Usage] interface's shape rather than through [inspect]. *)

module Config = Seekwright.Config
module Usage = Seekwright.Usage
module A = Alcotest
open Test_support

(* 2026-01-15T12:00:00Z. The one instant every case shares, so "today" and
   "fourteen days ago" are arithmetic rather than calendar-dependent. *)
let now = 1768478400.
let day = 86400.
let ago n = now -. (float_of_int n *. day)
let today = Usage.utc_date now

(* The recorder wants a clock function; every case gets the same instant. *)
let clock () = now
let ts secs = Usage.iso_utc_full secs

(* {1 Snapshot reads}

   [snapshot] is the wire contract: a [Yojson.Safe.t]. The helpers below are the
   loose typing the Python suite gets from [cast("dict[str, Any]")]. *)
let get key = function
  | `Assoc fields -> (try List.assoc key fields with Not_found -> `Null)
  | _ -> `Null

let items = function `List xs -> xs | _ -> []
let keys json = match json with `Assoc fields -> List.map fst fields | _ -> []
let str = function `String s -> s | `Null -> "" | v -> Yojson.Safe.to_string v
let int = function `Int n -> n | `Float f -> int_of_float f | v -> A.failf "not a count: %s" (Yojson.Safe.to_string v)
let is_null = (( = ) `Null)

let opt_money = function
  | `Int n -> Some (float_of_int n)
  | `Float f -> Some f
  | _ -> None

let json =
  A.testable (fun fmt v -> Format.pp_print_string fmt (Yojson.Safe.to_string v)) ( = )

(* money / no_money: the two halves of the rule that an unknown figure is absent,
   never [0.0]. *)
let money label expected value =
  A.(check (option (float 1e-9)) label (Some expected) (opt_money value))

let no_money label value = A.(check (option (float 1e-9)) label None (opt_money value))

let rows json = items json |> List.map (fun row -> str (get "provider" row))

(* {1 The recorder} *)

let log_of lines =
  fun (_level : Config.log_level) event fields -> lines := (event, fields) :: !lines

let events lines name =
  !lines
  |> List.rev
  |> List.filter_map (fun (event, fields) -> if event = name then Some fields else None)

let recorder ?log ?recent ?keep_days () =
  match Usage.create ~now:clock ?log ?recent ?keep_days () with
  | Ok r -> r
  | Error message -> A.failf "an in-memory recorder cannot fail: %s" message

let search ?ms ?cost ?results ?fell_back ?error ?run ?step ?provider r =
  Usage.record_search r
    ~provider:(Option.value ~default:"serper" provider)
    ~ms:(Option.value ~default:10 ms)
    ~cost_usd:(Option.value ~default:0.001 cost)
    ~results:(Option.value ~default:1 results)
    ~fell_back:(Option.value ~default:false fell_back)
    ?error ?run ?step ()

let fetch ?ms ?chars ?(fallback = None) ?cost_usd ?error ?run ?step r =
  Usage.record_fetch r ~ms:(Option.value ~default:5 ms)
    ~chars:(Option.value ~default:900 chars) ~fallback ?cost_usd ?error ?run ?step ()

let answer ?(run = "run-1") ?(model = Some "test-model") ?(depth = "brief")
    ?(searches = 1) ?(results = 5) ?(fetched = 0) ?(material_chars = 1200)
    ?(prompt_tokens = Some 900) ?(completion_tokens = Some 120) ?(answer_chars = 480)
    ?(cited = 2) ?(cited_invalid = 1) ?(sources = 2) ?(model_cost_usd = Some 0.0012)
    ?(ms = 900) ?error r =
  Usage.record_answer r ~run ~model ~depth ~searches ~results ~fetched ~material_chars
    ~prompt_tokens ~completion_tokens ~answer_chars ~cited ~cited_invalid ~sources
    ~model_cost_usd ~ms ?error ()

(* {1 The journal fixture}

   The Python suite's [tmp_path]: one directory per case under a scratch root,
   so a case's file is a name the failure message can quote. *)
(* The fixture root. Eio paths are built from the process's own filesystem handle,
   which is relative to the working directory, so the fixture is too: the file
   helpers and the recorder then see the same directory. (Eio renders it back as
   [./usage-journal/…] in the two startup-error sentences, which those cases
   assert on by suffix.) *)
let root_parts = [ "usage-journal" ]
let root = String.concat "/" root_parts

let eio_path env parts =
  List.fold_left (fun acc part -> Eio.Path.(acc / part)) (Eio.Stdenv.fs env) parts

let write_file path content =
  let oc = open_out_bin path in
  output_string oc content;
  close_out oc

let lines_of path =
  read_file path |> String.split_on_char '\n'
  |> List.filter (fun line -> line <> "")

let json_lines path = List.map Yojson.Safe.from_string (lines_of path)

let with_journal ?(content = "") name k =
  (try Unix.mkdir root 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let dir = Filename.concat root name in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let file = Filename.concat dir "usage.jsonl" in
  (try Sys.remove file with _ -> ());
  if content <> "" then write_file file content;
  Eio_main.run @@ fun env ->
  let path = eio_path env (root_parts @ [ name; "usage.jsonl" ]) in
  let open_rec ?log ?recent ?keep_days () =
    match Usage.create ~now:clock ?history_path:(Some path) ?log ?recent ?keep_days () with
    | Ok r -> r
    | Error message -> A.failf "the journal did not open: %s" message
  in
  k file open_rec

(* Journal lines as the writers spell them, for the cases that feed a recorder a
   file rather than calls. *)
let jl value = Yojson.Safe.to_string value

let search_line ?(provider = "serper") ?(ms = 10) ?(cost_usd = 0.001) ?(results = 1)
    ?(fell_back = false) ?error ts =
  `Assoc
      [
        ("ts", `String ts);
        ("tool", `String "search");
        ("provider", `String provider);
        ("ms", `Int ms);
        ("cost_usd", `Float cost_usd);
        ("results", `Int results);
        ("fell_back", `Bool fell_back);
        ("error", (match error with Some e -> `String e | None -> `Null));
      ]

(* A run-carrying search line, as agent mode's retrieval steps write it. *)
let retrieval_line ?(run = "run-1") ?(step = 1) ?(provider = "serper") ?(results = 5) ?error ts =
  `Assoc
      [
        ("ts", `String ts);
        ("tool", `String "search");
        ("provider", `String provider);
        ("ms", `Int 20);
        ("cost_usd", `Float 0.007);
        ("results", `Int results);
        ("fell_back", `Bool false);
        ("error", (match error with Some e -> `String e | None -> `Null));
        ("run", `String run);
        ("step", `Int step);
      ]

(* One [answer] line: the metrics page's journal table, field for field. *)
let answer_line ?(run = "run-1") ?(model = `String "test-model") ?(depth = "brief")
    ?(searches = 1) ?(results = 5) ?(fetched = 0) ?(material_chars = 1200)
    ?(prompt_tokens = `Int 900) ?(completion_tokens = `Int 120) ?(answer_chars = 480)
    ?(cited = 2) ?(cited_invalid = 1) ?(sources = 2) ?(model_cost_usd = `Float 0.0012)
    ?(ms = 900) ?(error = `Null) ts =
  `Assoc
      [
        ("ts", `String ts);
        ("tool", `String "answer");
        ("run", `String run);
        ("model", model);
        ("depth", `String depth);
        ("searches", `Int searches);
        ("results", `Int results);
        ("fetched", `Int fetched);
        ("material_chars", `Int material_chars);
        ("prompt_tokens", prompt_tokens);
        ("completion_tokens", completion_tokens);
        ("answer_chars", `Int answer_chars);
        ("cited", `Int cited);
        ("cited_invalid", `Int cited_invalid);
        ("sources", `Int sources);
        ("model_cost_usd", model_cost_usd);
        ("ms", `Int ms);
        ("error", error);
      ]

(* A journal line with extra keys a newer writer might add. *)
let widen extra value =
  match value with `Assoc fields -> `Assoc (fields @ extra) | _ -> value

let journal lines = String.concat "\n" (List.map jl lines) ^ "\n"

(* The clock at [n] days before the fixed instant, at [hour]:00. *)
let day_at n hour = now -. (float_of_int n *. day) +. (float_of_int (hour - 12) *. 3600.)

let check name f = A.test_case name `Quick f

(* {1 The clock}

   The three formatters usage.ml exports because the engines share them, and the
   civil-date arithmetic they are built on: a day bucket is only as good as the
   date maths that names it. *)

let iso_formats_the_instant () =
  A.(check string) "a whole second carries no microsecond field" "2026-01-15T12:00:00+00:00"
    (Usage.iso_utc_full now);
  A.(check string) "and microseconds when there are any" "2026-01-15T12:00:00.500000+00:00"
    (Usage.iso_utc_full (now +. 0.5));
  A.(check string) "retrieved_at spells the same instant to the second"
    "2026-01-15T12:00:00+00:00" (Usage.iso_utc_seconds (now +. 0.5));
  A.(check string) "the day bucket is the UTC calendar day" "2026-01-15" (Usage.utc_date now)

let iso_spans_the_calendar () =
  (* The two ends the buckets need: a leap day, and an instant before the epoch,
     where a truncating division would land the day *after*. *)
  A.(check string) "29 February of a leap year" "2024-02-29T23:59:59+00:00"
    (Usage.iso_utc_seconds 1709251199.);
  A.(check string) "the day rolls at midnight UTC, not before" "2024-03-01"
    (Usage.utc_date 1709251200.);
  A.(check string) "a pre-epoch instant buckets to its own UTC day" "1969-12-31"
    (Usage.utc_date (-1.))

(* {1 Aggregation} *)

let totals_and_providers_add_up () =
  let rec_ = recorder () in
  search ~results:3 rec_;
  search ~ms:20 ~cost:0.002 ~results:1 rec_;
  search ~provider:"linkup" ~ms:40 ~cost:0.0 ~results:0 ~fell_back:true ?error:(Some "QuotaExhausted") rec_;
  fetch ~fallback:(Some "scrappa") rec_;
  fetch ~ms:6 ~chars:0 ?error:(Some "FetchBlocked") rec_;
  let snap = Usage.snapshot rec_ in
  let totals = get "totals" snap in
  A.(check int) "searches" 3 (int (get "searches" totals));
  A.(check int) "fetches" 2 (int (get "fetches" totals));
  A.(check int) "errors" 2 (int (get "errors" totals));
  A.(check int) "fallbacks" 1 (int (get "fallbacks" totals));
  money "search_cost_usd" 0.003 (get "search_cost_usd" totals);
  A.(check int) "fetch pages via fallback" 1 (int (get "fetch_pages_via_fallback" totals));
  let by_name = List.map (fun row -> (str (get "provider" row), row)) (items (get "providers" snap)) in
  let serper = List.assoc "serper" by_name in
  let linkup = List.assoc "linkup" by_name in
  A.(check int) "serper's calls" 2 (int (get "calls" serper));
  A.(check int) "serper's mean" 15 (int (get "avg_ms" serper));
  money "serper's spend" 0.003 (get "cost_usd" serper);
  A.(check bool) "and when it was last used" true (not (is_null (get "last_used" serper)));
  A.(check int) "linkup's errors" 1 (int (get "errors" linkup));
  money "linkup spent nothing" 0.0 (get "cost_usd" linkup)

let providers_are_sorted_by_spend_descending () =
  let rec_ = recorder () in
  search ~provider:"cheap" ~ms:1 ~cost:0.001 rec_;
  search ~provider:"dear" ~ms:1 ~cost:0.009 rec_;
  A.(check (list string)) "the page draws the biggest spender first" [ "dear"; "cheap" ]
    (rows (get "providers" (Usage.snapshot rec_)))

let a_failed_fetch_is_not_a_fallback_page () =
  let rec_ = recorder () in
  fetch ~ms:1 ~chars:0 ~fallback:(Some "scrappa") ?error:(Some "ProviderError") rec_;
  A.(check int) "only a success carries a fallback name, and only that counts" 0
    (int (get "fetch_pages_via_fallback" (get "totals" (Usage.snapshot rec_))))

(* {1 The fetch line's price}

   A fetch line carries money only when a fallback that declares a price served
   the page. Everything else — the local fetcher, a failure, a free fallback —
   carries no [cost_usd] key at all, so the page count stays the sample size and
   the money total is null until something is priced. *)

let a_fallback_served_page_carries_its_declared_price () =
  let rec_ = recorder () in
  fetch ~fallback:(Some "scrappa") ?cost_usd:(Some 0.0003) rec_;
  let snap = Usage.snapshot rec_ in
  money "the line carries it" 0.0003 (get "cost_usd" (List.hd (items (get "recent" snap))));
  money "the lifetime total sums it" 0.0003 (get "fetch_cost_usd" (get "totals" snap));
  A.(check int) "one page was priced" 1 (int (get "priced_fetches" (get "totals" snap)));
  money "the day bucket carries it" 0.0003 (get "fetch_cost_usd" (List.nth (items (get "days" snap)) 13))

let a_local_page_carries_no_price_key () =
  let rec_ = recorder () in
  fetch rec_;
  let snap = Usage.snapshot rec_ in
  A.(check bool) "no key on the line" true
    (not (List.mem "cost_usd" (keys (List.hd (items (get "recent" snap))))));
  no_money "the total is unknown" (get "fetch_cost_usd" (get "totals" snap));
  A.(check int) "over no samples" 0 (int (get "priced_fetches" (get "totals" snap)));
  no_money "and the day bucket's is too" (get "fetch_cost_usd" (List.nth (items (get "days" snap)) 13))

let a_failure_carries_no_price_key () =
  (* Nothing was billed, so nothing is recorded — not even a zero. *)
  let rec_ = recorder () in
  fetch ~chars:0 ~fallback:(Some "scrappa") ?error:(Some "ProviderError") rec_;
  let snap = Usage.snapshot rec_ in
  A.(check bool) "no key on the line" true
    (not (List.mem "cost_usd" (keys (List.hd (items (get "recent" snap))))));
  no_money "the total is unknown" (get "fetch_cost_usd" (get "totals" snap));
  A.(check int) "over no samples" 0 (int (get "priced_fetches" (get "totals" snap)))

let a_free_fallback_carries_no_price_key () =
  (* crawl4ai and jina declare no price: absent, never 0.0. *)
  let rec_ = recorder () in
  fetch ~fallback:(Some "crawl4ai") rec_;
  fetch ~fallback:(Some "jina") rec_;
  let snap = Usage.snapshot rec_ in
  let expected = [ "chars"; "error"; "fallback"; "ms"; "tool"; "ts" ] in
  A.(check (list (list string))) "neither line gained a key"
    [ expected; expected ]
    (List.map (fun entry -> List.sort String.compare (keys entry)) (items (get "recent" snap)));
  A.(check int) "both pages came from a fallback" 2
    (int (get "fetch_pages_via_fallback" (get "totals" snap)));
  no_money "and nothing was billed" (get "fetch_cost_usd" (get "totals" snap))

let a_declared_zero_is_a_real_zero () =
  let rec_ = recorder () in
  fetch ~fallback:(Some "scrappa") ?cost_usd:(Some 0.0) rec_;
  let snap = Usage.snapshot rec_ in
  money "a fallback declaring 0.0 records it" 0.0 (get "cost_usd" (List.hd (items (get "recent" snap))));
  money "and the total says zero, not unknown" 0.0 (get "fetch_cost_usd" (get "totals" snap));
  A.(check int) "counted as a priced call" 1 (int (get "priced_fetches" (get "totals" snap)))

let a_partial_price_sum_says_how_much_it_covers () =
  let rec_ = recorder () in
  fetch ~fallback:(Some "scrappa") ?cost_usd:(Some 0.0003) rec_;
  fetch ~fallback:(Some "jina") rec_;
  fetch ~chars:0 ?error:(Some "FetchBlocked") rec_;
  let totals = get "totals" (Usage.snapshot rec_) in
  A.(check int) "fetches" 3 (int (get "fetches" totals));
  A.(check int) "priced_fetches" 1 (int (get "priced_fetches" totals));
  money "fetch_cost_usd" 0.0003 (get "fetch_cost_usd" totals)

let a_journal_without_the_key_still_folds () =
  (* An older writer's fetch line has no cost_usd: no migration needed. *)
  with_journal ~content:(Yojson.Safe.to_string
    (`Assoc
      [
        ("ts", `String (ts now));
        ("tool", `String "fetch");
        ("ms", `Int 12);
        ("chars", `Int 900);
        ("fallback", `String "scrappa");
        ("error", `Null);
      ])
    ^ "\n")
    "no_price_key"
  @@ fun _file open_rec ->
    let totals = get "totals" (Usage.snapshot (open_rec ())) in
    A.(check int) "fetches" 1 (int (get "fetches" totals));
    A.(check int) "fetch_pages_via_fallback" 1 (int (get "fetch_pages_via_fallback" totals));
    no_money "fetch_cost_usd" (get "fetch_cost_usd" totals);
    A.(check int) "priced_fetches" 0 (int (get "priced_fetches" totals))

let a_malformed_price_is_absent_rather_than_a_zero () =
  (* A figure that is not a figure does not fold as a free page. *)
  with_journal ~content:(Yojson.Safe.to_string
    (`Assoc
      [
        ("ts", `String (ts now));
        ("tool", `String "fetch");
        ("ms", `Int 12);
        ("chars", `Int 900);
        ("fallback", `String "scrappa");
        ("error", `Null);
        ("cost_usd", `String "free");
      ])
    ^ "\n")
    "malformed_price"
  @@ fun _file open_rec ->
    let totals = get "totals" (Usage.snapshot (open_rec ())) in
    no_money "fetch_cost_usd" (get "fetch_cost_usd" totals);
    A.(check int) "priced_fetches" 0 (int (get "priced_fetches" totals))

let the_price_round_trips_through_the_journal () =
  with_journal "price_round_trip" @@ fun file open_rec ->
    let live = open_rec () in
    fetch ~fallback:(Some "scrappa") ?cost_usd:(Some 0.0003) live;
    money "the line on disk carries it" 0.0003
      (get "cost_usd" (List.hd (json_lines file)));
    let rebuilt = Usage.snapshot (open_rec ()) in
    let original = Usage.snapshot live in
    A.(check json) "totals" (get "totals" original) (get "totals" rebuilt);
    A.(check json) "days" (get "days" original) (get "days" rebuilt)

(* {1 The window} *)

let a_fresh_recorder_zero_fills_fourteen_days_oldest_first () =
  let days = items (get "days" (Usage.snapshot (recorder ()))) in
  A.(check int) "the window is two weeks" Usage.window_days (List.length days);
  A.(check bool) "and every day is a zero row" true
    (List.for_all
       (fun day -> int (get "searches" day) = 0 && opt_money (get "cost_usd" day) = Some 0.0)
       days);
  A.(check string) "the last bucket is today" today (str (get "date" (List.nth days 13)));
  A.(check (list string)) "oldest first"
    (List.sort String.compare (List.map (fun d -> str (get "date" d)) days))
    (List.map (fun d -> str (get "date" d)) days)

let todays_calls_land_in_todays_bucket () =
  let rec_ = recorder () in
  search ~ms:1 ~cost:0.004 ~results:2 rec_;
  fetch ~ms:1 ~chars:10 rec_;
  let bucket = List.nth (items (get "days" (Usage.snapshot rec_))) 13 in
  A.(check int) "searches" 1 (int (get "searches" bucket));
  A.(check int) "fetches" 1 (int (get "fetches" bucket));
  money "cost_usd" 0.004 (get "cost_usd" bucket)

let since_is_the_earliest_timestamp () =
  A.(check bool) "an empty recorder has no since" true (is_null (get "since" (Usage.snapshot (recorder ()))));
  let rec_ = recorder () in
  search ~ms:1 ~cost:0.0 ~results:0 rec_;
  A.(check bool) "the first line sets it" true (not (is_null (get "since" (Usage.snapshot rec_))))

(* {1 The endpoint series} *)

let endpoints snap = get "endpoints" snap
let one_endpoint snap =
  match items (get "providers" (endpoints snap)) with
  | [ row ] -> row
  | other -> A.failf "expected one endpoint row, got %d" (List.length other)

let percentiles_are_nearest_rank_over_the_sample () =
  let rec_ = recorder () in
  List.iter (fun ms -> search ~ms ~cost:0.0 rec_) (List.init 10 (fun i -> i + 1));
  let snap = Usage.snapshot rec_ in
  A.(check int) "the window is declared" Usage.window_days
    (int (get "window_days" (endpoints snap)));
  let row = one_endpoint snap in
  A.(check string) "one provider" "serper" (str (get "provider" row));
  A.(check int) "ten samples" 10 (int (get "latency_samples" row));
  (* ceil(0.5 * 10) - 1 = 4 and ceil(0.95 * 10) - 1 = 9 over 1..10. *)
  A.(check (triple int int int)) "p50, p95, mean" (5, 10, 5)
    (int (get "p50_ms" row), int (get "p95_ms" row), int (get "mean_ms" row))

let a_single_sample_is_both_percentiles () =
  let rec_ = recorder () in
  search ~ms:7 ~cost:0.0 rec_;
  let row = one_endpoint (Usage.snapshot rec_) in
  A.(check (triple int int int)) "p50, p95, mean" (7, 7, 7)
    (int (get "p50_ms" row), int (get "p95_ms" row), int (get "mean_ms" row))

let two_samples_split_into_lower_and_higher () =
  let rec_ = recorder () in
  search ~ms:20 ~cost:0.0 rec_;
  search ~ms:10 ~cost:0.0 rec_;
  let row = one_endpoint (Usage.snapshot rec_) in
  A.(check (pair int int)) "nearest rank, not interpolation" (10, 20)
    (int (get "p50_ms" row), int (get "p95_ms" row))

let failures_and_fallbacks_are_counted_but_not_sampled () =
  let rec_ = recorder () in
  search ~ms:100 ~cost:0.001 rec_;
  search ~ms:500 ~cost:0.002 ~results:2 ~fell_back:true rec_;
  search ~ms:10000 ~cost:0.0 ~results:0 ?error:(Some "ProviderError") rec_;
  let row = one_endpoint (Usage.snapshot rec_) in
  A.(check int) "calls" 3 (int (get "calls" row));
  A.(check int) "errors" 1 (int (get "errors" row));
  A.(check int) "fell_back_calls" 1 (int (get "fell_back_calls" row));
  A.(check int) "one sample: the ladder walk and the timeout are not latencies" 1
    (int (get "latency_samples" row));
  A.(check (triple int int int)) "p50, p95, mean" (100, 100, 100)
    (int (get "p50_ms" row), int (get "p95_ms" row), int (get "mean_ms" row));
  money "cost_usd" 0.003 (get "cost_usd" row)

let a_provider_with_no_sample_reports_nulls () =
  let rec_ = recorder () in
  search ~provider:"linkup" ~ms:10000 ~cost:0.0 ~results:0 ?error:(Some "ProviderError") rec_;
  let row = one_endpoint (Usage.snapshot rec_) in
  A.(check int) "calls" 1 (int (get "calls" row));
  A.(check int) "latency_samples" 0 (int (get "latency_samples" row));
  A.(check bool) "p50 is null, not 0 ms" true (is_null (get "p50_ms" row));
  A.(check bool) "p95 too" true (is_null (get "p95_ms" row));
  A.(check bool) "and the mean" true (is_null (get "mean_ms" row));
  money "cost_per_1k is a real zero, because calls is not empty" 0.0 (get "cost_per_1k" row)

let cost_per_1k_is_measured_over_the_window () =
  let rec_ = recorder () in
  search ~cost:0.003 rec_;
  search ~ms:20 ~cost:0.002 rec_;
  let row = one_endpoint (Usage.snapshot rec_) in
  money "cost_usd" 0.005 (get "cost_usd" row);
  money "cost_per_1k" 2.5 (get "cost_per_1k" row)

let endpoints_are_sorted_by_window_spend_descending () =
  let rec_ = recorder () in
  search ~provider:"cheap" ~ms:1 ~cost:0.001 rec_;
  search ~provider:"dear" ~ms:1 ~cost:0.009 rec_;
  A.(check (list string)) "the window ranks its own spend" [ "dear"; "cheap" ]
    (rows (get "providers" (endpoints (Usage.snapshot rec_))))

let a_fetch_makes_no_endpoint_row () =
  let rec_ = recorder () in
  fetch ~ms:5 ~chars:100 ~fallback:(Some "scrappa") rec_;
  A.(check json) "the series has nothing to say about a fetch"
    (`Assoc [ ("window_days", `Int Usage.window_days); ("providers", `List []) ])
    (endpoints (Usage.snapshot rec_))

let the_series_is_one_row_per_provider_per_day_oldest_first () =
  with_journal
    ~content:(journal
      [
        search_line ~ms:30 ~cost_usd:0.003 (ts (ago 3));
        search_line ~ms:10 ~cost_usd:0.001 (ts (ago 1));
        search_line ~provider:"linkup" ~ms:50 ~cost_usd:0.005 (ts (ago 1));
        search_line ~ms:20 ~cost_usd:0.002 (ts now);
      ])
    "series_per_day"
  @@ fun _file open_rec ->
    let series = endpoints (Usage.snapshot (open_rec ())) in
    let by_name = List.map (fun row -> (str (get "provider" row), row)) (items (get "providers" series)) in
    A.(check (list string)) "two providers" [ "linkup"; "serper" ] (List.sort String.compare (List.map fst by_name));
    let serper = List.assoc "serper" by_name in
    A.(check (list string)) "its days, oldest first"
      [ Usage.utc_date (ago 3); Usage.utc_date (ago 1); today ]
      (List.map (fun d -> str (get "date" d)) (items (get "days" serper)));
    A.(check (list int)) "one call each" [ 1; 1; 1 ]
      (List.map (fun d -> int (get "calls" d)) (items (get "days" serper)));
    let linkup = List.assoc "linkup" by_name in
    A.(check (list string)) "linkup only on its own day" [ Usage.utc_date (ago 1) ]
      (List.map (fun d -> str (get "date" d)) (items (get "days" linkup)));
    (* the rollup is the window, not a lifetime figure *)
    A.(check int) "serper's window calls" 3 (int (get "calls" serper));
    money "serper's window spend" 0.006 (get "cost_usd" serper);
    money "and the measured rate" 2.0 (get "cost_per_1k" serper)

let a_day_outside_the_window_has_no_row () =
  let edge = ago (Usage.window_days - 1) and outside = ago Usage.window_days in
  with_journal
    ~content:(journal [ search_line ~provider:"edge" (ts edge); search_line ~provider:"stale" (ts outside) ])
    "outside_window"
  @@ fun _file open_rec ->
    (* the window is the last N UTC days ending today, so a provider used only on
       the day before it is absent, not zero *)
    A.(check (list string)) "only the edge day survives" [ "edge" ]
      (rows (get "providers" (endpoints (Usage.snapshot (open_rec ())))))

let first_and_last_seen_span_every_line_in_scope () =
  with_journal
    ~content:(journal
      [
        search_line (ts (day_at 1 9));
        search_line ~fell_back:true (ts (day_at 1 17));
        search_line ?error:(Some "ProviderError") (ts (day_at 0 8));
      ])
    "first_last_seen"
  @@ fun _file open_rec ->
    let row = one_endpoint (Usage.snapshot (open_rec ())) in
    A.(check string) "first_seen is the earliest line, not the first read"
      (ts (day_at 1 9)) (str (get "first_seen" row));
    A.(check string) "last_seen the latest, across the day boundary"
      (ts (day_at 0 8)) (str (get "last_seen" row));
    let by_date = List.map (fun d -> (str (get "date" d), d)) (items (get "days" row)) in
    let yesterday = List.assoc (Usage.utc_date (ago 1)) by_date in
    A.(check string) "the day row spans its own two lines" (ts (day_at 1 9))
      (str (get "first_seen" yesterday));
    A.(check string) "and its latest line" (ts (day_at 1 17)) (str (get "last_seen" yesterday))

let a_search_line_without_a_provider_makes_no_row () =
  with_journal
    ~content:(Yojson.Safe.to_string
      (`Assoc [ ("ts", `String (ts now)); ("tool", `String "search"); ("ms", `Int 5); ("error", `Null) ])
      ^ "\n")
    "no_provider"
  @@ fun _file open_rec ->
    let snap = Usage.snapshot (open_rec ()) in
    A.(check json) "no endpoint row" (`List []) (get "providers" (endpoints snap));
    A.(check int) "the call is still a search" 1 (int (get "searches" (get "totals" snap)))

let backfill_reproduces_the_live_series () =
  (* a journal written now, folded back in, gives the same series *)
  with_journal "backfill_series" @@ fun _file open_rec ->
    let live = open_rec () in
    search ~ms:10 ~cost:0.001 live;
    search ~ms:500 ~cost:0.0 ~results:0 ~fell_back:true live;
    search ~provider:"linkup" ~ms:20 ~cost:0.002 live;
    fetch ~ms:5 ~chars:10 live;
    A.(check json) "endpoints" (endpoints (Usage.snapshot live))
      (endpoints (Usage.snapshot (open_rec ())))

let a_line_from_an_older_writer_still_aggregates () =
  (* no key the series reads is new, so an older line needs no migration *)
  with_journal
    ~content:(Yojson.Safe.to_string
      (`Assoc
        [
          ("ts", `String (ts now));
          ("tool", `String "search");
          ("provider", `String "serper");
          ("ms", `Int 12);
          ("error", `Null);
        ])
      ^ "\n")
    "older_writer"
  @@ fun _file open_rec ->
    let row = one_endpoint (Usage.snapshot (open_rec ())) in
    A.(check int) "calls" 1 (int (get "calls" row));
    A.(check int) "latency_samples" 1 (int (get "latency_samples" row));
    A.(check (pair int int)) "percentiles" (12, 12) (int (get "p50_ms" row), int (get "p95_ms" row));
    (* defaulted at read time, never invented *)
    money "cost_usd" 0.0 (get "cost_usd" row);
    A.(check int) "fell_back_calls" 0 (int (get "fell_back_calls" row))

let a_line_written_before_the_rename_still_renders () =
  (* The journal is append-only and is *not* migrated, so a line an older writer
     left names [exa_free] — and the dashboard has to render that name rather
     than drop the row or invent today's spelling for it. That is why the reader
     takes [provider] as an opaque string. *)
  with_journal ~content:(journal [ search_line ~provider:"exa_free" (ts now) ]) "before_rename"
  @@ fun _file open_rec ->
    let row = one_endpoint (Usage.snapshot (open_rec ())) in
    A.(check string) "the old name survives" "exa_free" (str (get "provider" row));
    A.(check int) "calls" 1 (int (get "calls" row));
    money "cost_usd" 0.001 (get "cost_usd" row)

let markers = [ "query"; "http"; "host"; "title"; "snippet"; "url" ]

let no_marker label blob =
  List.iter
    (fun marker ->
      A.(check bool) (Printf.sprintf "%s carries no %s" label marker) false
        (contains ~haystack:blob ~needle:marker))
    markers

let the_series_is_content_free_and_the_journal_gains_no_field () =
  (* the percentiles read the journal; they must not widen what it holds *)
  with_journal "content_free_series" @@ fun file open_rec ->
    let rec_ = open_rec () in
    search ~ms:3 rec_;
    fetch ~ms:4 ~fallback:(Some "scrappa") rec_;
    let lines = json_lines file in
    A.(check (list string)) "the search line's keys"
      [ "cost_usd"; "error"; "fell_back"; "ms"; "provider"; "results"; "tool"; "ts" ]
      (List.sort String.compare (keys (List.hd lines)));
    A.(check (list string)) "the fetch line's keys"
      [ "chars"; "error"; "fallback"; "ms"; "tool"; "ts" ]
      (List.sort String.compare (keys (List.nth lines 1)));
    no_marker "the journal" (read_file file);
    no_marker "the series" (Yojson.Safe.to_string (endpoints (Usage.snapshot rec_)))

(* {1 The recent deque} *)

let the_deque_is_bounded_and_newest_first () =
  let rec_ = recorder ~recent:2 () in
  List.iter (fun _n -> search ~ms:1 ~cost:0.0 ~results:0 rec_) [ 1; 2; 3 ];
  let recent = items (get "recent" (Usage.snapshot rec_)) in
  A.(check int) "bounded" 2 (List.length recent);
  A.(check bool) "newest first" true (str (get "ts" (List.hd recent)) >= str (get "ts" (List.nth recent 1)))

let entries_carry_the_journal_schema () =
  let rec_ = recorder () in
  fetch ~ms:7 ~chars:42 ~fallback:(Some "crawl4ai") rec_;
  match items (get "recent" (Usage.snapshot rec_)) with
  | [ entry ] ->
      A.(check (list string)) "the fetch line's keys"
        [ "chars"; "error"; "fallback"; "ms"; "tool"; "ts" ]
        (List.sort String.compare (keys entry));
      A.(check string) "tool" "fetch" (str (get "tool" entry));
      A.(check string) "fallback" "crawl4ai" (str (get "fallback" entry))
  | other -> A.failf "expected one recent entry, got %d" (List.length other)

(* {1 The journal} *)

let round_trip_rebuilds_an_identical_snapshot () =
  with_journal "round_trip" @@ fun file open_rec ->
    let rec_ = open_rec () in
    search ~ms:12 ~cost:0.001 ~results:4 rec_;
    search ~provider:"linkup" ~ms:30 ~cost:0.0 ~results:0 ~fell_back:true ?error:(Some "ProviderError") rec_;
    fetch ~ms:8 ~chars:1200 ~fallback:(Some "scrappa") rec_;
    let lines = lines_of file in
    A.(check int) "one line per call" 3 (List.length lines);
    A.(check (list string)) "in call order" [ "search"; "search"; "fetch" ]
      (List.map (fun line -> str (get "tool" (Yojson.Safe.from_string line))) lines);
    let original = Usage.snapshot rec_ in
    let rebuilt = Usage.snapshot (open_rec ()) in
    List.iter
      (fun key -> A.(check json) key (get key original) (get key rebuilt))
      [ "since"; "totals"; "days"; "providers"; "endpoints"; "recent"; "journal" ]

let the_journal_carries_no_content () =
  (* the property that makes it safe to keep across restarts *)
  with_journal "no_content" @@ fun file open_rec ->
    search ~ms:3 (open_rec ());
    let line = read_file file in
    A.(check (list string)) "and the line's whole shape is counts"
      [ "cost_usd"; "error"; "fell_back"; "ms"; "provider"; "results"; "tool"; "ts" ]
      (List.sort String.compare (keys (Yojson.Safe.from_string (String.trim line))));
    no_marker "the journal line" line

let utc_days_bucket_across_midnight () =
  with_journal
    ~content:(journal
      [
        search_line (ts ((day_at 1 23) +. 3540.));  (* 23:59 yesterday *)
        search_line (ts ((day_at 0 0) +. 60.));  (* 00:01 today *)
      ])
    "across_midnight"
  @@ fun _file open_rec ->
    let by_date = List.map (fun d -> (str (get "date" d), d)) (items (get "days" (Usage.snapshot (open_rec ())))) in
    A.(check int) "the 23:59 line is yesterday's" 1 (int (get "searches" (List.assoc (Usage.utc_date (ago 1)) by_date)));
    A.(check int) "the 00:01 line is today's" 1 (int (get "searches" (List.assoc today by_date)))

let a_missing_file_is_created_at_startup () =
  with_journal "missing_file" @@ fun file open_rec ->
  let rec_ = open_rec () in
  A.(check bool) "startup created it" true (Sys.file_exists file);
  A.(check string) "and wrote no bytes" "" (read_file file);
  fetch ~ms:1 ~chars:1 rec_;
  A.(check int) "the first append is the first line" 1 (List.length (lines_of file))

let corrupt_lines_are_skipped_and_counted () =
  let lines = ref [] in
  with_journal
    ~content:(String.concat "\n"
      [ jl (search_line (ts now)); "not json at all"; "[\"a\", \"list\"]"; "{\"tool\": \"search\"}"; "" ]
      ^ "\n")
    "corrupt"
  @@ fun _file open_rec ->
    let rec_ = open_rec ~log:(log_of lines) () in
    A.(check int) "the good line still folded" 1 (int (get "searches" (get "totals" (Usage.snapshot rec_))));
    match events lines "dashboard.journal_skipped" with
    | [ fields ] -> A.(check int) "and three were counted" 3 (int (List.assoc "skipped" fields))
    | other -> A.failf "expected one skip event, got %d" (List.length other)

let append_failure_is_logged_once_then_the_writer_gives_up () =
  let lines = ref [] in
  with_journal "broken_volume" @@ fun file open_rec ->
    let rec_ = open_rec ~log:(log_of lines) () in
    (* the stand-in for Python's monkeypatched [Path.open]: the volume goes away
       between startup and the first append *)
    Unix.chmod file 0o444;
    search ~ms:5 rec_;
    search ~ms:5 rec_;
    let errors = events lines "dashboard.journal_error" in
    A.(check int) "reported once for the process" 1 (List.length errors);
    let fields = List.hd errors in
    A.(check bool) "with a bounded reason, not a traceback" true
      (List.mem "reason" (List.map fst fields));
    A.(check bool) "and no operator path on the log line" false
      (contains ~haystack:(Yojson.Safe.to_string (`Assoc fields)) ~needle:file);
    let snap = Usage.snapshot rec_ in
    A.(check bool) "the snapshot says the journal broke" true (get "failed" (get "journal" snap) = `Bool true);
    A.(check int) "and the aggregates kept counting" 2 (int (get "searches" (get "totals" snap)));
    Unix.chmod file 0o644

let a_missing_parent_directory_names_the_path () =
  Eio_main.run @@ fun env ->
  match
    Usage.create ~now:clock
      ~history_path:(eio_path env (root_parts @ [ "no-such-dir"; "usage.jsonl" ]))
      ()
  with
  | Ok _ -> A.failf "a journal whose parent does not exist must not open"
  | Error message ->
      A.(check bool) "the sentence names the path the operator wrote" true
        (contains ~haystack:message ~needle:"no-such-dir/usage.jsonl");
      A.(check bool) "and says why" true (contains ~haystack:message ~needle:"parent directory does not exist")

let an_unwritable_path_is_a_startup_error () =
  (try Unix.mkdir root 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let dir = Filename.concat root "unwritable" in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let file = Filename.concat dir "usage.jsonl" in
  (try Sys.remove file with _ -> ());
  Unix.chmod dir 0o555;
  let outcome =
    Eio_main.run @@ fun env ->
    Usage.create ~now:clock ~history_path:(eio_path env (root_parts @ [ "unwritable"; "usage.jsonl" ])) ()
  in
  Unix.chmod dir 0o755;
  match outcome with
  | Ok _ -> A.failf "an unwritable journal must not open"
  | Error message ->
      A.(check bool) "the sentence names the path" true (contains ~haystack:message ~needle:"usage.jsonl");
      A.(check bool) "and says it is not writable" true (contains ~haystack:message ~needle:"not writable")

let the_journal_writes_its_keys_in_the_declared_order () =
  (* Field order is part of the append-only format, not an accident: a line
     already on disk keeps the order its writer used, and this is the read that
     says which order that was. *)
  with_journal "key_order" @@ fun file open_rec ->
    let rec_ = open_rec () in
    search ~ms:5 rec_;
    search ~ms:9 ~cost:0.0 ~results:0 ?error:(Some "ProviderError") ?run:(Some "run-1") ?step:(Some 1) rec_;
    fetch ~ms:6 ~chars:10 rec_;
    fetch ~ms:7 ~chars:20 ~fallback:(Some "scrappa") ?cost_usd:(Some 0.0005) ?run:(Some "run-1") ?step:(Some 2) rec_;
    answer ~run:"run-1" ~model_cost_usd:None  rec_;
    let plain_search = [ "ts"; "tool"; "provider"; "ms"; "cost_usd"; "results"; "fell_back"; "error" ] in
    let plain_fetch = [ "ts"; "tool"; "ms"; "chars"; "fallback"; "error" ] in
    let key_list i = keys (List.nth (json_lines file) i) in
    A.(check (list string)) "a plain search line" plain_search (key_list 0);
    A.(check (list string)) "a run-carrying one adds the pair at the end"
      (plain_search @ [ "run"; "step" ])
      (key_list 1);
    A.(check (list string)) "a plain fetch line" plain_fetch (key_list 2);
    (* a priced fetch writes cost_usd after error, where the writer that added it
       conditionally always put it *)
    A.(check (list string)) "a priced, run-carrying fetch"
      (plain_fetch @ [ "cost_usd"; "run"; "step" ])
      (key_list 3);
    A.(check (list string)) "the answer line writes all seventeen keys, always"
      [
        "ts"; "tool"; "run"; "model"; "depth"; "searches"; "results"; "fetched";
        "material_chars"; "prompt_tokens"; "completion_tokens"; "answer_chars"; "cited";
        "cited_invalid"; "sources"; "model_cost_usd"; "ms"; "error";
      ]
      (key_list 4)

(* {1 Pruning}

   The Python suite reads [r._days]; the aggregates are private here, so the
   prune shows through where it is observable: a day bucket that was pruned has
   no row in the endpoint series. *)

let day_buckets_older_than_keep_days_are_dropped () =
  with_journal
    ~content:(journal [ search_line (ts (ago 5)); search_line (ts now) ])
    "prune"
  @@ fun _file open_rec ->
    let row = one_endpoint (Usage.snapshot (open_rec ~keep_days:1 ())) in
    A.(check (list string)) "the five-day-old bucket is gone" [ today ]
      (List.map (fun d -> str (get "date" d)) (items (get "days" row)));
    A.(check int) "and its call is out of the window rollup" 1 (int (get "calls" row))

let a_generous_keep_days_retains_old_buckets () =
  with_journal ~content:(journal [ search_line (ts (ago 5)) ]) "keep"
  @@ fun _file open_rec ->
    let row = one_endpoint (Usage.snapshot (open_rec ~keep_days:Usage.keep_days_default ())) in
    A.(check (list string)) "the old bucket survives" [ Usage.utc_date (ago 5) ]
      (List.map (fun d -> str (get "date" d)) (items (get "days" row)))

(* {1 The answer line: accepted here, folded in the section below}

   The [answer] line's whitelist is what this group pins: a reader that refused
   any tool but search and fetch dropped it with a warning on every restart. *)

let an_answer_line_backfills_rather_than_being_skipped () =
  let lines = ref [] in
  with_journal
    ~content:(journal [ search_line (ts now); answer_line (ts now) ])
    "answer_backfill"
  @@ fun _file open_rec ->
    let rec_ = open_rec ~log:(log_of lines) () in
    A.(check int) "nothing was skipped" 0 (List.length (events lines "dashboard.journal_skipped"));
    A.(check (list string)) "both lines are in the recent deque, newest first"
      [ "answer"; "search" ]
      (List.map (fun entry -> str (get "tool" entry)) (items (get "recent" (Usage.snapshot rec_))));
    (* a run-carrying search line is still a search: real provider spend *)
    A.(check int) "searches" 1 (int (get "searches" (get "totals" (Usage.snapshot rec_))))

let a_live_answer_line_is_not_miscounted_as_a_fetch () =
  (* the bug the whitelist widening could have introduced instead *)
  let rec_ = recorder () in
  answer ~fetched:1  rec_;
  let totals = get "totals" (Usage.snapshot rec_) in
  A.(check int) "fetches" 0 (int (get "fetches" totals));
  A.(check int) "searches" 0 (int (get "searches" totals));
  A.(check int) "errors" 0 (int (get "errors" totals))

let an_answer_error_counts_as_an_error () =
  let rec_ = recorder () in
  answer ~depth:"report" ~searches:3 ~results:0 ~material_chars:0 ~prompt_tokens:None
    ~completion_tokens:None ~answer_chars:0 ~cited:0 ~cited_invalid:0 ~sources:0
    ~model_cost_usd:None ~ms:40 ?error:(Some "AgentFailed")  rec_;
  A.(check int) "errors" 1 (int (get "errors" (get "totals" (Usage.snapshot rec_))))

let the_retrieval_keys_are_additive () =
  (* a plain search line's shape is unchanged; a run-carrying one is tagged *)
  with_journal "retrieval_keys" @@ fun file open_rec ->
    let rec_ = open_rec () in
    search rec_;
    search ?run:(Some "a1b2c3d4") ?step:(Some 2) rec_;
    fetch rec_;
    fetch ?run:(Some "a1b2c3d4") ?step:(Some 1) rec_;
    let lines = json_lines file in
    let plain i =
      A.(check bool) "no run key" true (not (List.mem "run" (keys (List.nth lines i))));
      A.(check bool) "no step key" true (not (List.mem "step" (keys (List.nth lines i))))
    in
    plain 0;
    plain 2;
    A.(check (pair string int)) "the tagged search" ("a1b2c3d4", 2)
      (str (get "run" (List.nth lines 1)), int (get "step" (List.nth lines 1)));
    A.(check (pair string int)) "the tagged fetch" ("a1b2c3d4", 1)
      (str (get "run" (List.nth lines 3)), int (get "step" (List.nth lines 3)))

(* {1 The answer line's fold: the model's figures, and the citation join} *)

let answers snap = get "answers" snap

let the_model_figures_fold_into_the_answers_section () =
  let rec_ = recorder () in
  answer ~model_cost_usd:(Some 0.0012) rec_;
  let snap = Usage.snapshot rec_ in
  let a = answers snap in
  A.(check int) "calls" 1 (int (get "calls" a));
  A.(check int) "errors" 0 (int (get "errors" a));
  A.(check int) "cited" 2 (int (get "cited" a));
  A.(check int) "cited_invalid" 1 (int (get "cited_invalid" a));
  A.(check int) "sources" 2 (int (get "sources" a));
  A.(check int) "answer_chars" 480 (int (get "answer_chars" a));
  A.(check int) "prompt_tokens" 900 (int (get "prompt_tokens" a));
  A.(check int) "completion_tokens" 120 (int (get "completion_tokens" a));
  A.(check int) "token_calls" 1 (int (get "token_calls" a));
  money "model_cost_usd" 0.0012 (get "model_cost_usd" a);
  A.(check int) "priced_calls" 1 (int (get "priced_calls" a));
  A.(check int) "mean_ms" 900 (int (get "mean_ms" a));
  A.(check (list string)) "models" [ "test-model" ] (List.map str (items (get "models" a)));
  (* an answer is not a search: the model call is not provider spend *)
  A.(check int) "searches" 0 (int (get "searches" (get "totals" snap)));
  A.(check int) "fetches" 0 (int (get "fetches" (get "totals" snap)));
  (* the per-day figures the spend view draws *)
  let bucket = List.nth (items (get "days" snap)) (Usage.window_days - 1) in
  A.(check int) "the day's answers" 1 (int (get "answers" bucket));
  money "the day's model spend" 0.0012 (get "model_cost_usd" bucket)

let a_null_model_cost_is_unknown_never_zero () =
  let rec_ = recorder () in
  answer ~prompt_tokens:None ~completion_tokens:None ~cited:0 ~cited_invalid:0 ~sources:0
    ~model_cost_usd:None  rec_;
  let snap = Usage.snapshot rec_ in
  let a = answers snap in
  no_money "model_cost_usd" (get "model_cost_usd" a);
  A.(check int) "priced_calls" 0 (int (get "priced_calls" a));
  (* the token counts are the honest stand-in, and absent too when the endpoint
     reported no usage — never a local estimate *)
  A.(check bool) "prompt_tokens" true (is_null (get "prompt_tokens" a));
  A.(check bool) "completion_tokens" true (is_null (get "completion_tokens" a));
  A.(check int) "token_calls" 0 (int (get "token_calls" a));
  let bucket = List.nth (items (get "days" snap)) (Usage.window_days - 1) in
  no_money "the day's model spend" (get "model_cost_usd" bucket)

let a_partial_answer_price_sum_says_how_much_it_covers () =
  let rec_ = recorder () in
  List.iter
    (fun (run, cost) ->
      answer ~run ~prompt_tokens:(Some 100) ~completion_tokens:(Some 10) ~answer_chars:10
        ~cited:1 ~cited_invalid:0 ~sources:1 ~model_cost_usd:cost ~ms:100  rec_)
    [ ("run-1", None); ("run-2", Some 0.002) ];
  let a = answers (Usage.snapshot rec_) in
  A.(check int) "calls" 2 (int (get "calls" a));
  A.(check int) "priced_calls" 1 (int (get "priced_calls" a));
  money "model_cost_usd" 0.002 (get "model_cost_usd" a);
  A.(check int) "token_calls" 2 (int (get "token_calls" a))

let citation_rows snap =
  items (get "providers" (answers snap))
  |> List.map (fun row ->
       ( str (get "provider" row),
         (int (get "retrieved" row), int (get "cited" row)),
         List.sort String.compare (keys row) ))

let per_provider_retrieved_and_cited_come_from_the_run_join () =
  let rec_ = recorder () in
  (* one run, two steps, one provider: retrieved sums, cited is credited once *)
  search ~ms:5 ~cost:0.007 ~results:5 ?run:(Some "run-1") ?step:(Some 1) rec_;
  search ~ms:5 ~cost:0.007 ~results:3 ?run:(Some "run-1") ?step:(Some 2) rec_;
  answer ~run:"run-1" ~depth:"report" ~searches:2 ~results:8 ~material_chars:2000
    ~prompt_tokens:(Some 1000) ~completion_tokens:(Some 200) ~answer_chars:600 ~cited:3
    ~sources:3 ~model_cost_usd:None ~ms:1500  rec_;
  (* a second run served by another provider, with a citation of its own *)
  search ~provider:"linkup" ~ms:5 ~cost:0.007 ~results:5 ?run:(Some "run-2") ?step:(Some 1) rec_;
  answer ~run:"run-2" ~searches:1 ~results:5 ~material_chars:900 ~prompt_tokens:(Some 800)
    ~completion_tokens:(Some 90) ~answer_chars:300 ~cited:1 ~sources:1 ~model_cost_usd:None
    ~ms:700  rec_;
  let by_name = List.map (fun (name, figures, _) -> (name, figures)) (citation_rows (Usage.snapshot rec_)) in
  A.(check (pair int int) "serper: retrieved and cited" (8, 3) (List.assoc "serper" by_name));
  A.(check (pair int int) "linkup" (5, 1) (List.assoc "linkup" by_name));
  (* ordered by citations, then results, then name: the ranking it exists for *)
  A.(check (list string)) "the ranking" [ "serper"; "linkup" ]
    (List.map (fun (name, _, _) -> name) (citation_rows (Usage.snapshot rec_)))

let a_failed_step_contributes_no_results_and_no_credit () =
  let rec_ = recorder () in
  search ~ms:5 ~cost:0.007 ~results:5 ?run:(Some "run-1") ?step:(Some 1) rec_;
  search ~provider:"linkup" ~ms:5 ~cost:0.0 ~results:0 ~fell_back:true ?error:(Some "ProviderError")
    ?run:(Some "run-1") ?step:(Some 2) rec_;
  answer ~run:"run-1" ~depth:"report" ~searches:2 ~results:5 ~material_chars:1000
    ~prompt_tokens:(Some 500) ~completion_tokens:(Some 50) ~answer_chars:200 ~cited:2
    ~sources:2 ~model_cost_usd:None ~ms:400  rec_;
  let snap = Usage.snapshot rec_ in
  (match citation_rows snap with
  | [ (name, figures, _) ] ->
      A.(check (pair string (pair int int)) "only the provider that answered"
        ("serper", (5, 2))
        (name, figures))
  | other -> A.failf "expected one citation row, got %d" (List.length other));
  (* the failed search is still a provider call in the search totals — it just
     contributed nothing to the answer, so it has no citation row *)
  A.(check int) "searches" 2 (int (get "searches" (get "totals" snap)));
  A.(check int) "fallbacks" 1 (int (get "fallbacks" (get "totals" snap)))

let a_plain_search_is_never_part_of_a_run () =
  let rec_ = recorder () in
  search ~ms:5 ~results:5 rec_;
  answer ~searches:0 ~results:0 ~material_chars:0 ~prompt_tokens:None ~completion_tokens:None
    ~answer_chars:0 ~cited:0 ~cited_invalid:0 ~sources:0 ~model_cost_usd:None ~ms:5
    ?error:(Some "AgentFailed")  rec_;
  let snap = Usage.snapshot rec_ in
  A.(check json) "no citation row for a search that belonged to no run" (`List [])
    (get "providers" (answers snap));
  A.(check int) "answers.errors" 1 (int (get "errors" (answers snap)));
  A.(check int) "searches" 1 (int (get "searches" (get "totals" snap)))

let a_two_provider_run_credits_each_contributor () =
  (* The documented rule, pinned: exact for one provider, shared otherwise. A
     mid-walk fallback that later succeeded leaves two providers' results in one
     run's material, and the journal does not carry the material's numbering — so
     the run's citation count is credited to each contributor rather than split
     by a guessed ratio. *)
  let rec_ = recorder () in
  List.iter
    (fun (step, provider, results) ->
      search ~provider ~ms:5 ~cost:0.007 ~results ?run:(Some "run-1") ?step:(Some step) rec_)
    [ (1, "serper", 5); (2, "linkup", 3) ];
  answer ~run:"run-1" ~depth:"report" ~searches:2 ~results:8 ~material_chars:2000
    ~prompt_tokens:(Some 900) ~completion_tokens:(Some 100) ~answer_chars:400 ~cited:4
    ~sources:4 ~model_cost_usd:None ~ms:900  rec_;
  let by_name = List.map (fun (name, figures, _) -> (name, figures)) (citation_rows (Usage.snapshot rec_)) in
  A.(check (pair int int) "serper is credited with the run" (5, 4) (List.assoc "serper" by_name));
  A.(check (pair int int) "and so is linkup" (3, 4) (List.assoc "linkup" by_name))

let an_orphan_run_keeps_its_results_and_gains_no_citation () =
  (* a process that died mid-call: the retrieval stands, the credit cannot *)
  with_journal ~content:(journal [ retrieval_line ~run:"gone" (ts now) ]) "orphan_run"
  @@ fun _file open_rec ->
    let a = answers (Usage.snapshot (open_rec ())) in
    A.(check int) "no answer call was counted" 0 (int (get "calls" a));
    A.(check json) "and the citation row shows the retrieval with no credit"
      (`List [ `Assoc [ ("provider", `String "serper"); ("retrieved", `Int 5); ("cited", `Int 0) ] ])
      (get "providers" a)

let cited_invalid_is_the_models_and_never_a_providers () =
  let rec_ = recorder () in
  search ~ms:5 ~cost:0.007 ~results:5 ?run:(Some "run-1") ?step:(Some 1) rec_;
  answer ~cited:0 ~cited_invalid:2 ~sources:0 ~model_cost_usd:None rec_;
  let snap = Usage.snapshot rec_ in
  A.(check int) "the model owns the invented citations" 2 (int (get "cited_invalid" (answers snap)));
  (* the citation row carries the two provider figures and nothing else *)
  (match citation_rows snap with
  | [ (_, _, row_keys) ] ->
      A.(check (list string)) "the citation row's fields" [ "cited"; "provider"; "retrieved" ] row_keys
  | other -> A.failf "expected one citation row, got %d" (List.length other));
  A.(check (list string)) "the provider row is unchanged"
    [ "avg_ms"; "calls"; "cost_usd"; "errors"; "last_used"; "provider" ]
    (List.sort String.compare (keys (List.hd (items (get "providers" snap)))))

let the_answers_section_round_trips_through_the_journal () =
  with_journal "answers_round_trip" @@ fun file open_rec ->
    let rec_ = open_rec () in
    search ~ms:5 ~cost:0.007 ~results:5 ?run:(Some "run-1") ?step:(Some 1) rec_;
    fetch ~ms:5 ~chars:900 ?run:(Some "run-1") ?step:(Some 1) rec_;
    answer ~fetched:1  rec_;
    A.(check int) "three lines" 3 (List.length (lines_of file));
    let original = Usage.snapshot rec_ in
    let rebuilt = Usage.snapshot (open_rec ()) in
    List.iter
      (fun key -> A.(check json) key (get key original) (get key rebuilt))
      [ "answers"; "days"; "providers"; "totals"; "recent"; "endpoints" ]

let the_journal_still_carries_no_content_with_an_answer_line () =
  (* the ranking data's whole premise: counts, names and figures only *)
  with_journal "answer_no_content" @@ fun file open_rec ->
    let rec_ = open_rec () in
    search ~ms:5 ~cost:0.007 ~results:5 ?run:(Some "run-1") ?step:(Some 1) rec_;
    answer ~sources:2  rec_;
    no_marker "the journal" (read_file file);
    (* nor in the aggregate the page reads, which is a second surface *)
    no_marker "the answers section" (Yojson.Safe.to_string (answers (Usage.snapshot rec_)))

let unknown_keys_on_either_line_are_still_tolerated () =
  (* the reader reads by key: a writer that adds one is still folded *)
  with_journal
    ~content:(journal
      [
        widen [ ("future_key", `Assoc [ ("anything", `Int 1) ]) ] (retrieval_line (ts now));
        widen [ ("future_key", `List [ `Int 1; `Int 2; `Int 3 ]) ] (answer_line (ts now));
      ])
    "unknown_keys"
  @@ fun _file open_rec ->
    let snap = Usage.snapshot (open_rec ()) in
    A.(check int) "the retrieval folded" 1 (int (get "searches" (get "totals" snap)));
    A.(check int) "the answer folded" 1 (int (get "calls" (answers snap)));
    A.(check json) "and the join worked"
      (`List [ `Assoc [ ("provider", `String "serper"); ("retrieved", `Int 5); ("cited", `Int 2) ] ])
      (get "providers" (answers snap))

let a_malformed_figure_is_absent_rather_than_a_zero () =
  (* a count that is not a count does not fold as one *)
  with_journal
    ~content:(journal
      [
        (* the same seventeen keys, with three figures that are not figures *)
        `Assoc
          [
            ("ts", `String (ts now));
            ("tool", `String "answer");
            ("run", `String "run-1");
            ("model", `String "test-model");
            ("depth", `String "brief");
            ("searches", `Int 1);
            ("results", `Int 5);
            ("fetched", `Int 0);
            ("material_chars", `Int 1200);
            ("prompt_tokens", `Null);
            ("completion_tokens", `Null);
            ("answer_chars", `Int 480);
            ("cited", `String "2");
            ("cited_invalid", `Int 1);
            ("sources", `Int 2);
            ("model_cost_usd", `String "free");
            ("ms", `Int 900);
            ("error", `Null);
          ];
      ])
    "malformed_figure"
  @@ fun _file open_rec ->
    let a = answers (Usage.snapshot (open_rec ())) in
    A.(check int) "the call still counted" 1 (int (get "calls" a));
    A.(check int) "the count did not" 0 (int (get "cited" a));
    no_money "model_cost_usd" (get "model_cost_usd" a);
    A.(check int) "priced_calls" 0 (int (get "priced_calls" a));
    A.(check bool) "prompt_tokens" true (is_null (get "prompt_tokens" a));
    A.(check int) "token_calls" 0 (int (get "token_calls" a))

let the_snapshot_fields_keep_their_names_and_meanings () =
  let rec_ = recorder () in
  search ~ms:5 ~results:1 rec_;
  fetch ~ms:5 ~fallback:(Some "scrappa") rec_;
  let snap = Usage.snapshot rec_ in
  let sorted = List.sort String.compare in
  A.(check (list string)) "the snapshot's own keys"
    (sorted [ "since"; "process_started_at"; "totals"; "days"; "providers"; "answers";
              "endpoints"; "recent"; "journal" ])
    (sorted (keys snap));
  A.(check (list string)) "totals"
    (sorted [ "searches"; "fetches"; "errors"; "fallbacks"; "search_cost_usd";
              "fetch_pages_via_fallback"; "fetch_cost_usd"; "priced_fetches" ])
    (sorted (keys (get "totals" snap)));
  A.(check (list string)) "providers"
    (sorted [ "provider"; "calls"; "errors"; "cost_usd"; "avg_ms"; "last_used" ])
    (sorted (keys (List.hd (items (get "providers" snap)))));
  (* the day fields the answers fold and the fetch price add; the rest are as they were *)
  A.(check (list string)) "days"
    (sorted [ "date"; "searches"; "fetches"; "answers"; "errors"; "cost_usd";
              "model_cost_usd"; "fetch_cost_usd" ])
    (sorted (keys (List.hd (items (get "days" snap)))));
  A.(check (list string)) "answers"
    (sorted [ "calls"; "errors"; "cited"; "cited_invalid"; "sources"; "answer_chars";
              "prompt_tokens"; "completion_tokens"; "token_calls"; "model_cost_usd";
              "priced_calls"; "mean_ms"; "models"; "providers" ])
    (sorted (keys (answers snap)));
  (* an empty section is an empty list and nulls, never a zero row *)
  let a = answers snap in
  A.(check int) "answers.calls" 0 (int (get "calls" a));
  no_money "answers.model_cost_usd" (get "model_cost_usd" a);
  A.(check json) "answers.providers" (`List []) (get "providers" a);
  A.(check bool) "answers.mean_ms" true (is_null (get "mean_ms" a));
  A.(check (list string)) "answers.models" [] (List.map str (items (get "models" a)))

let search_cost_is_the_serving_paths_figure () =
  (* agent mode's ceiling adds every step's spend, so this figure is unrounded:
     six decimals would let the ceiling fire late. *)
  let rec_ = recorder () in
  List.iter (fun _n -> search ~ms:1 ~cost:0.0000004 ~results:0 rec_) [ 1; 2; 3 ];
  A.(check (float 1e-12) "unrounded" 0.0000012 (Usage.search_cost_usd rec_));
  A.(check json) "and the snapshot is the rounded one" (`Float 0.000001)
    (get "search_cost_usd" (get "totals" (Usage.snapshot rec_)))

let tests =
  [
    ( "clock",
      [
        check "the three formatters spell one instant three ways" iso_formats_the_instant;
        check "the day maths spans a leap day and the epoch" iso_spans_the_calendar;
      ] );
    ( "aggregation",
      [
        check "totals and providers add up" totals_and_providers_add_up;
        check "providers are sorted by spend descending" providers_are_sorted_by_spend_descending;
        check "a failed fetch is not a fallback page" a_failed_fetch_is_not_a_fallback_page;
      ] );
    ( "the fetch line's price",
      [
        check "a fallback-served page carries its declared price"
          a_fallback_served_page_carries_its_declared_price;
        check "a local page carries no price key" a_local_page_carries_no_price_key;
        check "a failure carries no price key" a_failure_carries_no_price_key;
        check "a free fallback carries no price key" a_free_fallback_carries_no_price_key;
        check "a declared zero is a real zero" a_declared_zero_is_a_real_zero;
        check "a partial price sum says how much of the whole it covers"
          a_partial_price_sum_says_how_much_it_covers;
        check "a journal without the key still folds" a_journal_without_the_key_still_folds;
        check "a malformed price is absent rather than a zero" a_malformed_price_is_absent_rather_than_a_zero;
        check "the price round-trips through the journal" the_price_round_trips_through_the_journal;
      ] );
    ( "window",
      [
        check "a fresh recorder zero-fills fourteen days, oldest first"
          a_fresh_recorder_zero_fills_fourteen_days_oldest_first;
        check "today's calls land in today's bucket" todays_calls_land_in_todays_bucket;
        check "since is the earliest timestamp" since_is_the_earliest_timestamp;
      ] );
    ( "endpoints",
      [
        check "percentiles are nearest rank over the sample" percentiles_are_nearest_rank_over_the_sample;
        check "a single sample is both percentiles" a_single_sample_is_both_percentiles;
        check "two samples split into lower and higher" two_samples_split_into_lower_and_higher;
        check "failures and fallbacks are counted but not sampled"
          failures_and_fallbacks_are_counted_but_not_sampled;
        check "a provider with no sample reports nulls, not zero"
          a_provider_with_no_sample_reports_nulls;
        check "cost_per_1k is measured over the window" cost_per_1k_is_measured_over_the_window;
        check "providers are sorted by window spend descending"
          endpoints_are_sorted_by_window_spend_descending;
        check "a fetch makes no endpoint row" a_fetch_makes_no_endpoint_row;
        check "one row per provider per day, oldest first"
          the_series_is_one_row_per_provider_per_day_oldest_first;
        check "a day outside the window has no row" a_day_outside_the_window_has_no_row;
        check "first_seen and last_seen span every line in scope"
          first_and_last_seen_span_every_line_in_scope;
        check "a search line without a provider makes no row" a_search_line_without_a_provider_makes_no_row;
        check "backfill reproduces the live series" backfill_reproduces_the_live_series;
        check "a line from an older writer still aggregates" a_line_from_an_older_writer_still_aggregates;
        check "a line written before the rename still renders" a_line_written_before_the_rename_still_renders;
        check "the series is content-free and the journal gains no field"
          the_series_is_content_free_and_the_journal_gains_no_field;
      ] );
    ( "recent",
      [
        check "the deque is bounded and newest first" the_deque_is_bounded_and_newest_first;
        check "entries carry the journal schema" entries_carry_the_journal_schema;
      ] );
    ( "journal",
      [
        check "a round trip rebuilds an identical snapshot" round_trip_rebuilds_an_identical_snapshot;
        check "the journal carries no content" the_journal_carries_no_content;
        check "utc days bucket across midnight" utc_days_bucket_across_midnight;
        check "a missing file is created at startup" a_missing_file_is_created_at_startup;
        check "corrupt lines are skipped and counted" corrupt_lines_are_skipped_and_counted;
        check "an append failure is logged once, then the writer gives up"
          append_failure_is_logged_once_then_the_writer_gives_up;
        check "a missing parent directory names the path" a_missing_parent_directory_names_the_path;
        check "an unwritable path is a startup error" an_unwritable_path_is_a_startup_error;
        check "the journal writes its keys in the declared order"
          the_journal_writes_its_keys_in_the_declared_order;
      ] );
    ( "prune",
      [
        check "day buckets older than keep_days are dropped" day_buckets_older_than_keep_days_are_dropped;
        check "a generous keep_days retains old buckets" a_generous_keep_days_retains_old_buckets;
      ] );
    ( "the answer line",
      [
        check "an answer line backfills rather than being skipped"
          an_answer_line_backfills_rather_than_being_skipped;
        check "a live answer line is not miscounted as a fetch" a_live_answer_line_is_not_miscounted_as_a_fetch;
        check "an answer error counts as an error" an_answer_error_counts_as_an_error;
        check "the retrieval keys are additive" the_retrieval_keys_are_additive;
      ] );
    ( "answer ranking",
      [
        check "the model figures fold into the answers section"
          the_model_figures_fold_into_the_answers_section;
        check "a null model cost is unknown, never zero" a_null_model_cost_is_unknown_never_zero;
        check "a partial price sum says how much of the whole it covers"
          a_partial_answer_price_sum_says_how_much_it_covers;
        check "per-provider retrieved and cited come from the run join"
          per_provider_retrieved_and_cited_come_from_the_run_join;
        check "a failed step contributes no results and no credit"
          a_failed_step_contributes_no_results_and_no_credit;
        check "a plain search is never part of a run" a_plain_search_is_never_part_of_a_run;
        check "a two-provider run credits each contributor with the run"
          a_two_provider_run_credits_each_contributor;
        check "an orphan run keeps its results and gains no citation"
          an_orphan_run_keeps_its_results_and_gains_no_citation;
        check "cited_invalid is the model's, never a provider's" cited_invalid_is_the_models_and_never_a_providers;
        check "the answers section round-trips through the journal"
          the_answers_section_round_trips_through_the_journal;
        check "the journal still carries no content with an answer line"
          the_journal_still_carries_no_content_with_an_answer_line;
        check "unknown keys on either line are still tolerated" unknown_keys_on_either_line_are_still_tolerated;
        check "a malformed figure is absent rather than a zero" a_malformed_figure_is_absent_rather_than_a_zero;
        check "the snapshot's fields keep their names and meanings"
          the_snapshot_fields_keep_their_names_and_meanings;
      ] );
    ( "cost",
      [ check "search_cost_usd is unrounded, for the serving path" search_cost_is_the_serving_paths_figure ]
    );
  ]

let () = A.run "usage" tests
