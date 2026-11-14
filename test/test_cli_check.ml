(* The [--check] report's pure parts — port of [tests/test_cli.py]'s
   [TestCheckStreams] and the inert/unsupported-feature reporting: what the
   report says about a config, without dialling anything. The full report
   needs a network, so this suite drives the pieces the report is built
   from — the default-route line, the transitional-feature list, and the
   fetch and agent blocks through the [emit] callback. *)

module Config = Seekwright.Config

let load text =
  let path = "test_cli_check_fixture.toml" in
  let ch = open_out path in
  output_string ch text;
  close_out ch;
  Unix.putenv "SEEKWRIGHT_CONFIG" path;
  let result =
    match Config.load None with
    | Ok config -> `Config config
    | Error message -> `Error message
  in
  Unix.putenv "SEEKWRIGHT_CONFIG" "";
  (match Sys.file_exists path with true -> Sys.remove path | false -> ());
  result

let lines ?cache_stats config =
  let out = ref [] in
  let n1 =
    Cli_check.report_fetch ?cache_stats (fun line -> out := !out @ [ line ]) config 0
  in
  let n2 = Cli_check.report_agent (fun line -> out := !out @ [ line ]) config n1 in
  (n2, !out)

(* {1 The default route line} *)

let test_default_named () =
  match load {|
default_provider = "exa"

[providers.exa]
enabled = true
|} with
  | `Config config ->
      Alcotest.(check string) "named" "exa" (Cli_check.default_route_line config)
  | `Error m -> Alcotest.failf "fixture: %s" m

let test_no_default_billed () =
  (* Two enabled names and no [default_provider]: the config refuses to pick,
     because picking for the caller is cost-guessing. One name alone would not
     test this — the config resolves a lone enabled name into the default. *)
  match load {|
[providers]
[providers.exa]
enabled = true
[providers.parallel]
enabled = true
|} with
  | `Config config ->
      Alcotest.(check string) "must name a provider" "none (callers must pass provider)"
        (Cli_check.default_route_line config)
  | `Error m -> Alcotest.failf "fixture: %s" m

let test_no_default_all_free () =
  (* the empty set is the keyless set, and a keyless-only deployment walks
     the free set instead of demanding a provider — the same route decision
     [router.py]'s guard pins, seen from the report's side. *)
  match load {|
[providers]
[providers."exa:free"]
enabled = true
[providers."parallel:free"]
enabled = true
[providers.freeserp]
enabled = true
|} with
  | `Config config ->
      Alcotest.(check string) "free walk" "none (a bare search walks the free set)"
        (Cli_check.default_route_line config)
  | `Error m -> Alcotest.failf "fixture: %s" m

(* {1 Transitional features — the inert-key report} *)

let transitional text =
  match load text with
  | `Config config -> Cli_check.transitional_features config
  | `Error m -> Alcotest.failf "fixture: %s" m

let feature_names rows = List.map fst rows

let test_cache_dir_is_no_longer_inert () =
  (* F7 landed the consumer: [cache_dir] builds a written root and page entries,
     so it leaves the transitional list. The row that says so is the measured one
     in the fetch block, pinned below. *)
  let rows =
    transitional
      {|
[fetch]
enabled = true
cache_dir = "/var/cache/seekwright"
|}
  in
  Alcotest.(check (list string)) "nothing is inert here" [] (feature_names rows)

let test_requested_fallback_routes_aggregated () =
  let rows =
    transitional
      {|
[fetch]
enabled = true
primary = "jina"
fallback = ["crawl4ai", "jina"]
|}
  in
  Alcotest.(check (list string)) "fallback is named" [ "fallback" ] (feature_names rows);
  match rows with
  | [ (_, detail) ] ->
      (* the ladder and the primary are named once each, sorted, deduped *)
      Alcotest.(check bool) "the routes are spelled out" true
        (try
           ignore (Str.search_forward (Str.regexp_string "crawl4ai, jina") detail 0);
           true
         with Not_found -> false)
  | _ -> Alcotest.fail "one row expected"

let test_crawl4ai_url_alone_asks_for_a_route () =
  let rows =
    transitional
      {|
[fetch]
enabled = true
crawl4ai_url = "http://renderer:11235"
|}
  in
  match rows with
  | [ ("fallback", detail) ] ->
      Alcotest.(check bool) "the configured endpoint is itself a route" true
        (try
           ignore (Str.search_forward (Str.regexp_string "fetch.crawl4ai_url") detail 0);
           true
         with Not_found -> false)
  | other -> Alcotest.failf "expected one fallback row, got %d" (List.length other)

let test_disabled_fetch_reports_nothing () =
  let rows =
    transitional
      {|
[fetch]
enabled = false
cache_dir = "/var/cache/seekwright"
|}
  in
  Alcotest.(check int) "a disabled fetch configures nothing" 0 (List.length rows)

(* {1 The fetch and agent blocks} *)

let test_fetch_block_states_the_private_address_stance () =
  match load {|
[fetch]
enabled = true
|} with
  | `Config config ->
      let problems, out = lines config in
      Alcotest.(check int) "no problems on the default fetch config" 0 problems;
      Alcotest.(check bool) "the reader is stated" true
        (List.mem "  primary   http (the local reader)" out);
      Alcotest.(check bool) "blocked by default" true
        (try
           ignore
             (List.find
                (fun line ->
                  try
                    ignore (Str.search_forward (Str.regexp_string "private addresses blocked") line 0);
                    true
                  with Not_found -> false)
                out);
           true
         with Not_found -> false)
  | `Error m -> Alcotest.failf "fixture: %s" m

let test_unbuildable_primary_counts_a_problem () =
  match load {|
[fetch]
enabled = true
primary = "tavily"
|} with
  | `Config config ->
      let problems, out = lines config in
      Alcotest.(check int) "the row counts" 1 problems;
      Alcotest.(check bool) "and says what it is" true
        (try
           ignore
             (List.find
                (fun line ->
                  try
                    ignore (Str.search_forward (Str.regexp_string "primary   tavily unsupported on this port") line 0);
                    true
                  with Not_found -> false)
                out);
           true
         with Not_found -> false)
  | `Error m -> Alcotest.failf "fixture: %s" m

(* A row that mentions a phrase anywhere in the block. *)
let mentions phrase out =
  List.exists
    (fun line ->
      try
        ignore (Str.search_forward (Str.regexp_string phrase) line 0);
        true
      with Not_found -> false)
    out

let test_unset_cache_says_off () =
  match load
    {|
[fetch]
enabled = true
|}
  with
  | `Config config ->
      let problems, out = lines config in
      Alcotest.(check int) "an unset cache is not a problem" 0 problems;
      Alcotest.(check bool) "the row says off" true (List.mem "  cache     off" out)
  | `Error m -> Alcotest.failf "fixture: %s" m

let test_cache_row_carries_measured_figures () =
  (* The cap and the ttl are configured; the entry count and the body bytes are
     measured off the directory. [report_fetch] takes the measurement as an
     argument precisely so this suite can hand it a number without a filesystem,
     and the pin is that the row prints that number rather than a restatement of
     the ceiling. *)
  match load
    {|
[fetch]
enabled = true
cache_dir = "/var/cache/seekwright"
cache_max_bytes = 268435456
cache_ttl_seconds = 300
|}
  with
  | `Config config ->
      let problems, out = lines ~cache_stats:(Ok (Some (3, 1_234))) config in
      Alcotest.(check int) "measured entries are not a problem" 0 problems;
      Alcotest.(check bool) "the row names the directory, the cap and the ttl" true
        (mentions "cache     /var/cache/seekwright (256 MiB cap, ttl 300s)" out);
      Alcotest.(check bool) "and the figures it measured" true
        (mentions "3 entries, 1.2 KiB" out);
      let problems, out = lines ~cache_stats:(Ok (Some (0, 0))) config in
      Alcotest.(check int) "an empty directory reads as zero, not as a refusal" 0 problems;
      Alcotest.(check bool) "and says zero" true (mentions "0 entries, 0 B" out)
  | `Error m -> Alcotest.failf "fixture: %s" m

let test_unopenable_cache_dir_counts_a_problem () =
  (* The server refuses to start on a [cache_dir] it cannot create or open, so
     the diagnosis counts it: an operator whose config names a read-only mount
     has to learn that from [--check], not from a startup failure. *)
  match load
    {|
[fetch]
enabled = true
cache_dir = "/var/cache/seekwright"
|}
  with
  | `Config config ->
      let problems, out =
        lines ~cache_stats:(Error "/var/cache/seekwright: permission denied") config
      in
      Alcotest.(check int) "the refusal counts" 1 problems;
      Alcotest.(check bool) "and names the reason" true
        (mentions "cache     /var/cache/seekwright" out
          && mentions "UNAVAILABLE: /var/cache/seekwright: permission denied" out)
  | `Error m -> Alcotest.failf "fixture: %s" m

let test_agent_incomplete_counts_a_problem () =
  match load {|
[agent]
enabled = true
model = "m"
|} with
  | `Config config ->
      let problems, out = lines config in
      Alcotest.(check int) "one problem" 1 problems;
      Alcotest.(check bool) "names what is missing" true
        (try
           ignore
             (List.find
                (fun line ->
                  try
                    ignore (Str.search_forward (Str.regexp_string "enabled but incomplete") line 0);
                    true
                  with Not_found -> false)
                out);
           true
         with Not_found -> false)
  | `Error m -> Alcotest.failf "fixture: %s" m

let test_agent_off_is_quiet () =
  match load {||} with
  | `Config config ->
      let problems, out = lines config in
      Alcotest.(check int) "nothing to report" 0 problems;
      Alcotest.(check bool) "disabled in config" true (List.mem "  disabled in config" out)
  | `Error m -> Alcotest.failf "fixture: %s" m

let () =
  Alcotest.run "cli check"
    [
      ( "default route",
        [
          Alcotest.test_case "a configured default" `Quick test_default_named;
          Alcotest.test_case "no default, a billed name enabled" `Quick test_no_default_billed;
          Alcotest.test_case "no default, all free" `Quick test_no_default_all_free;
        ] );
      ( "inert features",
        [
          Alcotest.test_case "cache_dir is not an inert key any more" `Quick test_cache_dir_is_no_longer_inert;
          Alcotest.test_case "the requested routes are aggregated" `Quick test_requested_fallback_routes_aggregated;
          Alcotest.test_case "a configured crawl4ai url is a route" `Quick test_crawl4ai_url_alone_asks_for_a_route;
          Alcotest.test_case "a disabled fetch reports nothing" `Quick test_disabled_fetch_reports_nothing;
        ] );
      ( "report blocks",
        [
          Alcotest.test_case "the fetch block states the SSRF stance" `Quick test_fetch_block_states_the_private_address_stance;
          Alcotest.test_case "an unbuildable primary counts a problem" `Quick test_unbuildable_primary_counts_a_problem;
          Alcotest.test_case "an unset cache says off" `Quick test_unset_cache_says_off;
          Alcotest.test_case "the cache row carries measured figures" `Quick test_cache_row_carries_measured_figures;
          Alcotest.test_case "an unopenable cache dir counts a problem" `Quick test_unopenable_cache_dir_counts_a_problem;
          Alcotest.test_case "half-configured agent mode counts a problem" `Quick test_agent_incomplete_counts_a_problem;
          Alcotest.test_case "agent off is quiet" `Quick test_agent_off_is_quiet;
        ] );
    ]
